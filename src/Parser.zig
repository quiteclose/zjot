const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const Tag = node_mod.Tag;
const Attr = node_mod.Attr;
const SourcePos = node_mod.SourcePos;
const CellAlign = node_mod.CellAlign;
const attrs_mod = @import("attributes.zig");
const BlockAttrs = attrs_mod.BlockAttrs;
const inline_mod = @import("inline.zig");
const LineMap = @import("LineMap.zig");

const Parser = @This();

/// What block-level syntax defines for the whole document: reference link definitions
/// and footnote definitions. A block anywhere may use a definition from anywhere, so
/// they outlive any one block: everything stored here is allocated from `a`, which the
/// caller keeps for the document, whatever allocator the blocks themselves use.
/// Shared by pointer with sub-parsers so a definition inside a container is seen.
pub const Definitions = struct {
    a: Allocator,
    ref_defs: std.StringArrayHashMapUnmanaged(RefDef) = .{},
    footnote_defs: std.StringArrayHashMapUnmanaged(FootnoteDef) = .{},
    /// Set by a consumer that parses the input a second time: definitions are then
    /// consumed from the input but not recorded again.
    sealed: bool = false,
};

/// A footnote definition's blocks and, when positions are tracked, its span: from its
/// label to where the next block starts, as djot.js.
pub const FootnoteDef = struct {
    blocks: []const Node,
    start_pos: ?SourcePos = null,
    end_pos: ?SourcePos = null,
};

pub const RefDef = struct {
    url: []const u8,
    attrs: ?BlockAttrs = null,
};

a: Allocator,
input: []const u8,
lines: []const []const u8 = &.{},
line_offsets: []const u32 = &.{},
pos: usize = 0,
defs: *Definitions,
end_marker: ?[]const u8 = null,
/// The line of the closing fence that ended the last `nextBlock` call, when one did.
closing_fence: ?usize = null,
track_pos: bool = false,
/// Pass one: parse only the inlines the survey reads. Heading text makes ids and implicit
/// references, and an inline attribute may claim an id (`[x]{#Foo}` before `# Foo` gives
/// the heading `Foo-1`, as djot.js); every other block's inlines are parsed once, in pass two.
survey_only: bool = false,
/// Where this parser's input ends in the document: the document's end for the root
/// (`inputEnd`), the line after its last line for a sub-parser (`positionSubParser`).
/// Set whenever positions are tracked.
input_end: ?SourcePos = null,
/// For a sub-parser, where the enclosing parser's structure stopped (`containerEnd`
/// there), where an item ends there (`stopBefore`), and the newline of the blank line
/// after this parser's last line, when there is one. A block that ends with this
/// parser's input ends at one of these, as djot.js closes containers at the line that
/// fails to continue them: lists and items at the stop, block quotes and tables at the
/// first blank line. Null in the root, where the input's end serves.
stop: ?SourcePos = null,
stop_before: ?SourcePos = null,
blank_after: ?SourcePos = null,
/// For a sub-parser, the first byte after its input in the enclosing parser
/// (`afterNewline`): where a paragraph ending in a hard break ends.
after_input: ?SourcePos = null,
base_offset: u32 = 0,
base_line: u32 = 1,
col_offsets: []const u32 = &.{},
/// Per line, the bytes stripped from this and earlier lines of the enclosing item that
/// the inner text does not contain; added to byte offsets, not to columns.
offset_adjust: []const u32 = &.{},

/// The line index of an input: one slice per line and each line's byte offset. A
/// streaming consumer builds it once and keeps it for the document while the
/// parser's own allocations come and go per block.
pub const LineIndex = struct {
    lines: []const []const u8 = &.{},
    offsets: []const u32 = &.{},
};

pub fn indexLines(a: Allocator, input: []const u8) !LineIndex {
    // Sized exactly: the index is the largest thing a streaming consumer keeps.
    // A trailing newline would produce an empty final line; it is not counted, so
    // line counts match the visible content.
    var count = std.mem.count(u8, input, "\n") + 1;
    if (input.len == 0 or input[input.len - 1] == '\n') count -= 1;
    const lines = try a.alloc([]const u8, count);
    const offsets = try a.alloc(u32, count);
    var offset: u32 = 0;
    var it = std.mem.splitScalar(u8, input, '\n');
    for (lines, offsets) |*line, *line_offset| {
        // CRLF input: the line is indexed without its carriage return; offsets keep it.
        const raw = it.next().?;
        line.* = std.mem.trimEnd(u8, raw, "\r");
        line_offset.* = offset;
        offset += @intCast(raw.len + 1);
    }
    return .{ .lines = lines, .offsets = offsets };
}

/// Where the input ends, as djot.js reports it: on its final newline, or one past the
/// last character of the last line when there is none.
pub fn inputEnd(index: LineIndex, input: []const u8) SourcePos {
    const n: u32 = @intCast(index.lines.len);
    if (input.len == 0 or input[input.len - 1] == '\n')
        return .{ .line = n + 1, .col = 0, .offset = @intCast(input.len -| 1) };
    return .{ .line = n, .col = @intCast(index.lines[n - 1].len + 1), .offset = @intCast(input.len) };
}

pub fn init(a: Allocator, input: []const u8, defs: *Definitions) Parser {
    // OOM here leaves lines empty; parseBlocks sees nothing and returns an empty doc.
    const index = indexLines(a, input) catch LineIndex{};
    return initIndexed(a, input, index, defs);
}

/// A parser over an index built elsewhere, so the index can outlive what the parser
/// allocates from `a`.
pub fn initIndexed(a: Allocator, input: []const u8, index: LineIndex, defs: *Definitions) Parser {
    return .{ .a = a, .input = input, .lines = index.lines, .line_offsets = index.offsets, .defs = defs };
}

/// The position of 1-based `col` on `line_idx`; col 0 is the end of the previous line
/// (its newline), whatever this line strips. Past the last line lies only the input's end.
fn makePos(self: *Parser, line_idx: usize, col: u32) SourcePos {
    if (line_idx >= self.lines.len) return self.input_end.?;
    const col_adj: u32 = if (line_idx < self.col_offsets.len) self.col_offsets[line_idx] else 0;
    const off_adj = self.offsetAdjustAt(line_idx);
    const line_offset = self.line_offsets[line_idx];
    const line = self.base_line + @as(u32, @intCast(line_idx));
    if (col == 0) {
        // Before this line's own stripped bytes.
        const offset = if (line_offset > 0) line_offset - 1 + off_adj - col_adj else 0;
        return .{ .line = line, .col = 0, .offset = self.base_offset + offset };
    }
    return .{ .line = line, .col = col + col_adj, .offset = self.base_offset + line_offset + col - 1 + off_adj };
}

fn parseBlocks(self: *Parser) anyerror![]const Node {
    return self.parseBlocksUntil(null);
}

fn parseBlocksUntil(self: *Parser, end_marker: ?[]const u8) anyerror![]const Node {
    const prev_marker = self.end_marker;
    self.end_marker = end_marker;
    defer self.end_marker = prev_marker;
    var children: std.ArrayList(Node) = .empty;
    while (try self.nextBlock()) |n| try children.append(self.a, n);
    return children.toOwnedSlice(self.a);
}

/// The next block, or null at the end of the input or at the closing fence of the
/// enclosing div. Definitions are recorded in `defs` as they are met and never
/// returned, so a caller may drop each block before asking for the next.
pub fn nextBlock(self: *Parser) anyerror!?Node {
    var pending_attrs: ?BlockAttrs = null;
    self.closing_fence = null;

    while (self.pos < self.lines.len) {
        const line = self.lines[self.pos];

        if (isBlank(line)) {
            self.pos += 1;
            pending_attrs = null;
            continue;
        }

        if (self.isClosingFence(line)) {
            self.closing_fence = self.pos;
            self.pos += 1;
            return null;
        }

        if (try self.tryBlockAttr()) |ba| {
            pending_attrs = mergeBlockAttrs(self.a, pending_attrs, ba) catch ba;
            continue;
        }
        // A block attribute that opened but could not close is text, read without
        // attributes, as djot.js reparses it.
        const failed_attr = attrs_mod.opensAttr(self.a, line);

        var node: Node = undefined;

        if (try self.tryHeading()) |h| {
            node = h;
        } else if (self.tryThematicBreak()) |tb| {
            node = tb;
        } else if (try self.tryCodeBlock()) |cb| {
            node = cb;
        } else if (try self.tryBlockQuote()) |bq| {
            node = bq;
        } else if (try self.tryFencedDiv()) |fd| {
            node = fd;
        } else if (try self.tryRefDef(pending_attrs)) |_| {
            pending_attrs = null;
            continue;
        } else if (try self.tryFootnoteDef()) |_| {
            pending_attrs = null;
            continue;
        } else if (try self.tryDefinitionList()) |dl| {
            node = dl;
        } else if (try self.tryBulletList()) |bl| {
            node = bl;
        } else if (try self.tryOrderedList()) |ol| {
            node = ol;
        } else if (try self.tryTable()) |tbl| {
            node = tbl;
        } else {
            node = try self.parseParagraph(failed_attr);
        }

        if (pending_attrs) |ba| node = inline_mod.applyBlockAttrsToNode(node, ba);
        return node;
    }

    return null;
}

fn tryBlockAttr(self: *Parser) !?BlockAttrs {
    const found = (try self.blockAttrAt(self.pos)) orelse return null;
    self.pos += found.lines;
    return found.attrs;
}

/// The block attribute starting at `pos`, which may continue over indented lines.
fn blockAttrAt(self: *Parser, pos: usize) !?struct { attrs: BlockAttrs, lines: usize } {
    const line = self.lines[pos];
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 1 or trimmed[0] != '{') return null;

    if (trimmed[trimmed.len - 1] == '}') {
        if (attrs_mod.parseAttrsFromStr(self.a, trimmed)) |ba| return .{ .attrs = ba, .lines = 1 };
    }

    const indent = indentOf(line);
    var full_text: std.ArrayList(u8) = .empty;
    try full_text.appendSlice(self.a, trimmed);
    var lines_consumed: usize = 1;

    while (pos + lines_consumed < self.lines.len) {
        const next = self.lines[pos + lines_consumed];
        if (isBlank(next)) break;
        const next_indent = indentOf(next);
        if (next_indent <= indent) break;
        try full_text.append(self.a, '\n');
        try full_text.appendSlice(self.a, std.mem.trim(u8, next, " \t"));
        lines_consumed += 1;

        if (attrs_mod.parseAttrsFromStr(self.a, full_text.items)) |ba| {
            return .{ .attrs = ba, .lines = lines_consumed };
        }
    }

    return null;
}

fn isClosingFence(self: *const Parser, line: []const u8) bool {
    const marker = self.end_marker orelse return false;
    return countLeadingChar(line, ':') >= marker.len and isBlank(std.mem.trimStart(u8, line, ":"));
}

/// `literal_first_line`: the first line was a failed block attribute; no inline attribute
/// is read from it.
fn parseParagraph(self: *Parser, literal_first_line: bool) !Node {
    const para_start_line = self.pos;
    var text_lines: std.ArrayList([]const u8) = .empty;
    while (self.pos < self.lines.len) {
        const line = self.lines[self.pos];
        if (isBlank(line)) break;
        if (self.isClosingFence(line)) break;
        try text_lines.append(self.a, std.mem.trimStart(u8, line, " \t"));
        self.pos += 1;
    }

    const attrs_from: usize = if (literal_first_line) text_lines.items[0].len else 0;
    var para = Node{ .tag = .para, .children = try self.parseBodyInlines(text_lines.items, para_start_line, attrs_from) };
    if (self.track_pos) {
        para.start_pos = self.makePos(para_start_line, self.contentCol(para_start_line));
        para.end_pos = self.leafEnd(para.children, self.pos - 1);
    }
    return para;
}

/// Where a paragraph or heading whose last line is `last_line` ends, as djot.js: one past
/// its last non-blank character (the line's newline, col 0 of the next line, unless
/// whitespace trails it), or one past a hard break that ends it.
fn leafEnd(self: *Parser, children: []const Node, last_line: usize) SourcePos {
    if (children.len > 0 and children[children.len - 1].tag == .hard_break) return self.afterNewline(last_line + 1);
    return self.afterContent(last_line);
}

/// One past the last non-blank character of `line_idx`: the line's newline (col 0 of the
/// next line) unless whitespace trails it.
fn afterContent(self: *Parser, line_idx: usize) SourcePos {
    const line = self.lines[line_idx];
    const content = std.mem.trimEnd(u8, line, " \t").len;
    if (content == line.len) return self.makePos(line_idx + 1, 0);
    return self.makePos(line_idx, @intCast(content + 1));
}

/// The first byte of `line_idx`: its newline when it is empty, the enclosing parser's
/// next byte or the document's end past this parser's input.
fn afterNewline(self: *Parser, line_idx: usize) SourcePos {
    if (line_idx >= self.lines.len) return self.after_input orelse self.input_end.?;
    if (self.lines[line_idx].len == 0) return self.makePos(line_idx + 1, 0);
    return self.makePos(line_idx, 1);
}

/// Parses the inline content of `slices`, each a slice of its line, taken from the
/// consecutive lines starting at `first_line`; positioned when positions are tracked.
fn parseInlinesAt(self: *Parser, slices: []const []const u8, first_line: usize) ![]const Node {
    return self.parseInlinesFrom(slices, first_line, 0);
}

/// The inlines of a block whose text the survey never reads (paragraphs, captions, cells):
/// in pass one, none unless a `{` may open an inline attribute; see `survey_only`.
fn parseBodyInlines(self: *Parser, slices: []const []const u8, first_line: usize, attrs_from: usize) ![]const Node {
    if (self.survey_only) {
        for (slices) |slice| {
            if (std.mem.indexOfScalar(u8, slice, '{') != null) break;
        } else return &.{};
    }
    return self.parseInlinesFrom(slices, first_line, attrs_from);
}

/// As `parseInlinesAt`, reading no inline attribute before joined offset `attrs_from`.
fn parseInlinesFrom(self: *Parser, slices: []const []const u8, first_line: usize, attrs_from: usize) ![]const Node {
    const src = try inline_mod.joinLines(self.a, slices);
    if (src.len == 0) return &.{};
    const map: ?LineMap = if (self.track_pos) try self.buildInlineLineMap(slices, first_line) else null;
    return inline_mod.parseInlineContent(self.a, src, map, attrs_from);
}

fn contentCol(self: *Parser, line_idx: usize) u32 {
    if (line_idx >= self.lines.len) return 1;
    const full_line = self.lines[line_idx];
    const trimmed = std.mem.trimStart(u8, full_line, " \t");
    return @intCast(full_line.len - trimmed.len + 1);
}

/// The map from the joined `slices` back to their lines, which start at `start_line`;
/// each slice's column is where it lies in its line.
fn buildInlineLineMap(self: *Parser, slices: []const []const u8, start_line: usize) !LineMap {
    var segs: std.ArrayList(LineMap.Segment) = .empty;
    var joined_pos: u32 = 0;
    for (slices, 0..) |line, i| {
        const orig_line_idx = start_line + i;
        const orig = self.lines[orig_line_idx];
        std.debug.assert(@intFromPtr(line.ptr) >= @intFromPtr(orig.ptr) and @intFromPtr(line.ptr) + line.len <= @intFromPtr(orig.ptr) + orig.len);
        const col: u32 = @intCast(@intFromPtr(line.ptr) - @intFromPtr(orig.ptr) + 1);
        const pos_val = self.makePos(orig_line_idx, col);
        try segs.append(self.a, .{
            .joined_start = joined_pos,
            .orig_line = pos_val.line,
            .orig_col = pos_val.col,
            .orig_offset = pos_val.offset,
        });
        joined_pos += @intCast(line.len + 1);
    }
    return .{ .segments = try segs.toOwnedSlice(self.a), .total = joined_pos - 1, .end = self.makePos(start_line + slices.len, 0) };
}

fn tryHeading(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const hashes = headingLevel(trimmed) orelse return null;
    const start_line = self.pos;

    self.pos += 1;
    var content_lines: std.ArrayList([]const u8) = .empty;
    const after_hashes = std.mem.trim(u8, trimmed[hashes..], " \t");
    if (after_hashes.len > 0) try content_lines.append(self.a, after_hashes);
    const first_content_line = if (after_hashes.len > 0) start_line else start_line + 1;

    while (self.pos < self.lines.len) {
        const next = self.lines[self.pos];
        if (isBlank(next)) break;
        if (isThematicBreak(next) or isCodeFence(next) != null or
            startsBlockQuote(next) or isFencedDivStart(next) != null)
            break;
        if (parseBulletMarker(next) != null or parseOrderedMarker(next) != null) break;
        if (attrs_mod.tryParseBlockAttr(self.a, next) != null or definitionLabel(next) != null) break;
        const next_trimmed = std.mem.trimStart(u8, next, " ");
        const next_hashes = countLeadingChar(next_trimmed, '#');
        if (next_hashes == hashes and next_hashes < next_trimmed.len and
            (next_trimmed[next_hashes] == ' ' or next_trimmed[next_hashes] == '\t'))
        {
            try content_lines.append(self.a, std.mem.trim(u8, next_trimmed[next_hashes..], " \t"));
        } else if (next_hashes > 0 and next_hashes <= 6 and next_hashes != hashes and
            (next_hashes >= next_trimmed.len or next_trimmed[next_hashes] == ' ' or next_trimmed[next_hashes] == '\t'))
        {
            break;
        } else {
            try content_lines.append(self.a, next);
        }
        self.pos += 1;
    }

    var node = Node{ .tag = .heading, .level = @intCast(hashes), .children = try self.parseInlinesAt(content_lines.items, first_content_line) };
    if (self.track_pos) {
        node.start_pos = self.makePos(start_line, self.contentCol(start_line));
        node.end_pos = self.leafEnd(node.children, self.pos - 1);
    }
    return node;
}

fn tryThematicBreak(self: *Parser) ?Node {
    const line = self.lines[self.pos];
    if (!isThematicBreak(line)) return null;
    var node = Node{ .tag = .thematic_break };
    if (self.track_pos) {
        node.start_pos = self.makePos(self.pos, self.contentCol(self.pos));
        node.end_pos = self.makePos(self.pos + 1, 0);
    }
    self.pos += 1;
    return node;
}

fn tryCodeBlock(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    const fence_info = isCodeFence(line) orelse return null;
    const open_line = self.pos;
    self.pos += 1;

    var content: std.ArrayList(u8) = .empty;
    var closed_at: ?usize = null;
    while (self.pos < self.lines.len) {
        const l = self.lines[self.pos];
        self.pos += 1;
        if (isClosingCodeFence(l, fence_info)) {
            closed_at = self.pos - 1;
            break;
        }
        var stripped = l;
        var indent_remaining = fence_info.indent;
        while (indent_remaining > 0 and stripped.len > 0 and stripped[0] == ' ') {
            stripped = stripped[1..];
            indent_remaining -= 1;
        }
        try content.appendSlice(self.a, stripped);
        try content.append(self.a, '\n');
    }

    const lang = fence_info.lang;
    var node = Node{ .tag = .code_block, .text = try content.toOwnedSlice(self.a), .lang = lang };
    if (lang != null and lang.?[0] == '=') {
        node.tag = .raw_block;
        node.lang = lang.?[1..];
    }
    if (self.track_pos) {
        node.start_pos = self.makePos(open_line, @intCast(fence_info.indent + 1));
        // A fenced block ends on its closing fence; unclosed, at the end of the input.
        node.end_pos = if (closed_at) |l| self.fenceEnd(l) else self.makePos(self.pos, 0);
    }
    return node;
}

fn tryBlockQuote(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    if (!startsBlockQuote(line)) return null;
    const start_line = self.pos;
    const start_col: u32 = @intCast(countIndent(line) + 1);

    var inner_lines: std.ArrayList([]const u8) = .empty;
    var orig_lines: std.ArrayList(usize) = .empty;
    var col_offsets: std.ArrayList(u32) = .empty;
    var paragraph = OpenParagraph{};
    while (self.pos < self.lines.len) {
        const l = self.lines[self.pos];
        if (startsBlockQuote(l)) {
            const inner = stripBlockQuotePrefix(l);
            try inner_lines.append(self.a, inner);
            try orig_lines.append(self.a, self.pos);
            try col_offsets.append(self.a, @intCast(l.len - inner.len));
            try paragraph.feed(self.a, inner);
            self.pos += 1;
        } else if (!isBlank(l) and paragraph.open and !self.isClosingFence(l) and
            !try self.isBlockStartAt(self.pos))
        {
            try inner_lines.append(self.a, l);
            try orig_lines.append(self.a, self.pos);
            try col_offsets.append(self.a, 0);
            try paragraph.feed(self.a, l);
            self.pos += 1;
        } else {
            break;
        }
    }

    const inner_text = try inline_mod.joinLines(self.a, inner_lines.items);
    var inner_parser = self.childParser(inner_text);
    try self.positionSubParser(&inner_parser, orig_lines.items, col_offsets.items);
    const inner_blocks = try inner_parser.parseBlocks();
    var node = Node{ .tag = .block_quote, .children = inner_blocks };
    if (self.track_pos) {
        node.start_pos = self.makePos(start_line, start_col);
        node.end_pos = self.endAtBlank(self.pos);
    }
    return node;
}

fn tryFencedDiv(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    const div_info = isFencedDivStart(line) orelse return null;
    const open_line = self.pos;
    self.pos += 1;
    const blocks = try self.parseBlocksUntil(div_info.fence);
    var node = Node{ .tag = .div, .children = blocks };
    if (div_info.class) |cls| node.classes = cls;
    if (self.track_pos) {
        node.start_pos = self.makePos(open_line, self.contentCol(open_line));
        node.end_pos = if (self.closing_fence) |l| self.fenceEnd(l) else self.makePos(self.pos, 0);
    }
    return node;
}

/// `rest_col` is the number of bytes before `rest` on its line.
const DefinitionLabel = struct { label: []const u8, rest: []const u8, rest_col: u32, is_footnote: bool };

/// `[label]:` or `[^label]:` opening a reference or footnote definition: space
/// indentation only, a label of at least one character, and what follows the colon.
fn definitionLabel(line: []const u8) ?DefinitionLabel {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (trimmed.len < 4 or trimmed[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, trimmed[1..], ']') orelse return null;
    if (close + 2 >= trimmed.len or trimmed[close + 2] != ':') return null;
    const label = trimmed[1 .. close + 1];
    const is_footnote = label.len > 0 and label[0] == '^';
    if (is_footnote and label.len < 2) return null;
    const after_colon = trimmed[close + 3 ..];
    const rest = std.mem.trim(u8, after_colon, " \t");
    const rest_lead = after_colon.len - std.mem.trimStart(u8, after_colon, " \t").len;
    return .{
        .label = if (is_footnote) label[1..] else label,
        .rest = rest,
        .rest_col = @intCast(line.len - after_colon.len + rest_lead),
        .is_footnote = is_footnote,
    };
}

fn tryRefDef(self: *Parser, pending_attrs: ?BlockAttrs) !?void {
    const def = definitionLabel(self.lines[self.pos]) orelse return null;
    if (def.is_footnote) return null;
    const label = def.label;
    var dest_text = def.rest;

    self.pos += 1;
    var dest_parts: std.ArrayList([]const u8) = .empty;
    if (dest_text.len > 0) try dest_parts.append(self.a, dest_text);
    while (self.pos < self.lines.len) {
        const next = self.lines[self.pos];
        if (isBlank(next)) break;
        if (next.len == 0 or (next[0] != ' ' and next[0] != '\t')) break;
        const next_trimmed = std.mem.trimStart(u8, next, " ");
        if (next_trimmed.len > 0 and next_trimmed[0] == '[') break;
        try dest_parts.append(self.a, std.mem.trim(u8, next, " \t"));
        self.pos += 1;
    }

    if (dest_parts.items.len == 0) {
        dest_text = "";
    } else if (dest_parts.items.len == 1) {
        dest_text = dest_parts.items[0];
    } else {
        var buf: std.ArrayList(u8) = .empty;
        for (dest_parts.items) |part| try buf.appendSlice(self.a, part);
        dest_text = try buf.toOwnedSlice(self.a);
    }

    if (self.defs.sealed) return {};
    const da = self.defs.a;
    try self.defs.ref_defs.put(da, try da.dupe(u8, label), .{
        .url = try da.dupe(u8, dest_text),
        .attrs = if (pending_attrs) |ba| try ba.dupe(da) else null,
    });
    return {};
}

fn tryFootnoteDef(self: *Parser) !?void {
    const def = definitionLabel(self.lines[self.pos]) orelse return null;
    if (!def.is_footnote) return null;
    const label = def.label;
    const rest = def.rest;
    const def_line = self.pos;
    self.pos += 1;

    var content_lines: std.ArrayList([]const u8) = .empty;
    var orig_lines: std.ArrayList(usize) = .empty;
    var col_offsets: std.ArrayList(u32) = .empty;
    var paragraph = OpenParagraph{};
    // The first indented line sets the content indent; deeper lines keep the rest, as
    // in a list item (`collectItemContent`).
    var content_indent: ?usize = null;
    if (rest.len > 0) {
        try content_lines.append(self.a, rest);
        try orig_lines.append(self.a, self.pos - 1);
        try col_offsets.append(self.a, def.rest_col);
        try paragraph.feed(self.a, rest);
    }
    while (self.pos < self.lines.len) {
        const l = self.lines[self.pos];
        if (isBlank(l)) {
            var lookahead = self.pos + 1;
            while (lookahead < self.lines.len and isBlank(self.lines[lookahead])) : (lookahead += 1) {}
            if (lookahead < self.lines.len and
                self.lines[lookahead].len > 0 and
                (self.lines[lookahead][0] == ' ' or self.lines[lookahead][0] == '\t'))
            {
                try content_lines.append(self.a, "");
                try orig_lines.append(self.a, self.pos);
                try col_offsets.append(self.a, 0);
                try paragraph.feed(self.a, "");
                self.pos += 1;
            } else break;
        } else if (l[0] == ' ' or l[0] == '\t') {
            const indent = countIndent(l);
            const strip = @min(indent, content_indent orelse indent);
            if (content_indent == null) content_indent = indent;
            try content_lines.append(self.a, l[strip..]);
            try orig_lines.append(self.a, self.pos);
            try col_offsets.append(self.a, @intCast(strip));
            try paragraph.feed(self.a, l[strip..]);
            self.pos += 1;
        } else if (paragraph.open and !try self.isBlockStartAt(self.pos)) {
            // An unindented line continues an open paragraph, as in a list item.
            try content_lines.append(self.a, l);
            try orig_lines.append(self.a, self.pos);
            try col_offsets.append(self.a, 0);
            try paragraph.feed(self.a, l);
            self.pos += 1;
        } else break;
    }

    if (self.defs.sealed) return {};
    // The footnote's blocks are rendered at the end of the document, so they are
    // parsed with the definitions' allocator rather than the current block's; they are
    // positioned like any container's, which is why pass one tracks positions too.
    const da = self.defs.a;
    const inner_text = try inline_mod.joinLines(da, content_lines.items);
    var inner_parser = Parser.init(da, inner_text, self.defs);
    try self.positionSubParser(&inner_parser, orig_lines.items, col_offsets.items);
    var stored = FootnoteDef{ .blocks = try inner_parser.parseBlocks() };
    if (self.track_pos) {
        stored.start_pos = self.makePos(def_line, self.contentCol(def_line));
        stored.end_pos = self.definitionEnd();
    }
    try self.defs.footnote_defs.put(da, try da.dupe(u8, label), stored);
    return {};
}

const ItemContent = struct {
    para_lines: std.ArrayList([]const u8),
    block_lines: std.ArrayList([]const u8),
    item_saw_blank: bool,
    /// For each collected line: the line it came from and the bytes stripped before it.
    para_orig_lines: std.ArrayList(usize),
    para_col_offsets: std.ArrayList(u32),
    block_orig_lines: std.ArrayList(usize),
    block_col_offsets: std.ArrayList(u32),
};

/// Collects an item's lines: `first_rest` is the first line's content, starting at
/// column `first_col`; `content_col` is where continuation lines must start.
fn collectItemContent(self: *Parser, content_col: usize, first_col: usize, list_indent: usize, first_rest: []const u8) !ItemContent {
    var content = ItemContent{
        .para_lines = .empty,
        .block_lines = .empty,
        .item_saw_blank = false,
        .para_orig_lines = .empty,
        .para_col_offsets = .empty,
        .block_orig_lines = .empty,
        .block_col_offsets = .empty,
    };

    try content.para_lines.append(self.a, first_rest);
    try content.para_orig_lines.append(self.a, self.pos);
    // A bare marker's line is shorter than its content column.
    try content.para_col_offsets.append(self.a, @intCast(@min(first_col, self.lines[self.pos].len)));
    self.pos += 1;
    var para_open = first_rest.len > 0;

    while (self.pos < self.lines.len and !content.item_saw_blank) {
        const next = self.lines[self.pos];
        if (isBlank(next)) {
            content.item_saw_blank = true;
            self.pos += 1;
            continue;
        }
        if (parseBulletMarker(next)) |m| {
            if (m.indent <= list_indent) break;
        }
        if (parseOrderedMarker(next)) |m| {
            if (m.indent <= list_indent) break;
        }
        const next_indent = countIndent(next);
        // An unindented line is lazy text for an open paragraph; an empty item has none.
        if (next_indent <= list_indent and (!para_open or try self.isBlockStartAt(self.pos))) break;
        const strip: u32 = if (next_indent >= content_col) @intCast(content_col) else @intCast(next_indent);
        try content.para_lines.append(self.a, next[strip..]);
        try content.para_orig_lines.append(self.a, self.pos);
        try content.para_col_offsets.append(self.a, strip);
        para_open = true;
        self.pos += 1;
    }

    var paragraph = OpenParagraph{};
    while (self.pos < self.lines.len and content.item_saw_blank) {
        const next = self.lines[self.pos];
        if (isBlank(next)) {
            try content.block_lines.append(self.a, "");
            try content.block_orig_lines.append(self.a, self.pos);
            try content.block_col_offsets.append(self.a, 0);
            try paragraph.feed(self.a, "");
            self.pos += 1;
            continue;
        }
        const next_indent = countIndent(next);
        if (next_indent > list_indent) {
            const is_marker = parseBulletMarker(next) != null or parseOrderedMarker(next) != null;
            const strip = if (is_marker)
                @min(next_indent, list_indent + 1)
            else
                @min(next_indent, content_col);
            try content.block_lines.append(self.a, next[strip..]);
            try content.block_orig_lines.append(self.a, self.pos);
            try content.block_col_offsets.append(self.a, @intCast(strip));
            try paragraph.feed(self.a, next[strip..]);
            self.pos += 1;
            continue;
        }
        if (paragraph.open and !(try self.isBlockStartAt(self.pos))) {
            const lazy = std.mem.trimStart(u8, next, " \t");
            try content.block_lines.append(self.a, lazy);
            try content.block_orig_lines.append(self.a, self.pos);
            try content.block_col_offsets.append(self.a, @intCast(next.len - lazy.len));
            try paragraph.feed(self.a, lazy);
            self.pos += 1;
            continue;
        }
        break;
    }

    while (content.block_lines.items.len > 0 and isBlank(content.block_lines.items[content.block_lines.items.len - 1])) {
        _ = content.block_lines.pop();
        _ = content.block_orig_lines.pop();
        _ = content.block_col_offsets.pop();
    }

    return content;
}

fn parseItemContent(self: *Parser, content: *const ItemContent) ![]const Node {
    var inner_blocks: std.ArrayList(Node) = .empty;

    const para_text = try inline_mod.joinLines(self.a, content.para_lines.items);
    if (para_text.len > 0) {
        var para_parser = self.childParser(para_text);
        try self.positionSubParser(&para_parser, content.para_orig_lines.items, content.para_col_offsets.items);
        const blocks = try para_parser.parseBlocks();
        for (blocks) |b| try inner_blocks.append(self.a, b);
    }

    if (content.block_lines.items.len > 0) {
        const block_text = try inline_mod.joinLines(self.a, content.block_lines.items);
        var block_parser = self.childParser(block_text);
        try self.positionSubParser(&block_parser, content.block_orig_lines.items, content.block_col_offsets.items);
        const blocks = try block_parser.parseBlocks();
        for (blocks) |b| try inner_blocks.append(self.a, b);
    }

    return inner_blocks.toOwnedSlice(self.a);
}

/// Where a container ends, as djot.js: where the next block's content starts on the line
/// the parser stopped at, or that line's newline when it is blank (a block quote stops
/// there); past the enclosing div's closing fence when that stopped it; at the end of
/// this parser's input, where the enclosing parser stopped, or the document's end.
fn containerEnd(self: *Parser) SourcePos {
    if (self.pos >= self.lines.len) return self.stop orelse self.input_end.?;
    const line = self.lines[self.pos];
    if (isBlank(line) or self.isClosingFence(line)) return self.makePos(self.pos + 1, 0);
    return self.makePos(self.pos, @intCast(countIndent(line) + 1));
}

/// Where a footnote definition ends, as djot.js: where the next block's content starts,
/// blank lines skipped, or where this parser's input ends.
fn definitionEnd(self: *Parser) SourcePos {
    var next = self.pos;
    while (next < self.lines.len and isBlank(self.lines[next])) : (next += 1) {}
    if (next >= self.lines.len) return self.stop orelse self.input_end.?;
    return self.makePos(next, @intCast(countIndent(self.lines[next]) + 1));
}

/// Where an item ends, as djot.js: one position before `containerEnd` (the character
/// before the stop line's content, or col 0, the previous line's end, when it has none),
/// on the closing fence's last character, or where the enclosing parser's items end.
fn stopBefore(self: *Parser) SourcePos {
    if (self.pos >= self.lines.len) return self.stop_before orelse self.input_end.?;
    const line = self.lines[self.pos];
    if (self.isClosingFence(line)) return self.fenceEnd(self.pos);
    if (isBlank(line)) return self.makePos(self.pos, 0);
    const stop = self.containerEnd();
    return .{ .line = stop.line, .col = stop.col - 1, .offset = stop.offset - 1 };
}

/// Where a block quote or table ends, as djot.js: on the newline of the blank line at
/// `line_idx` that follows it, in this parser or the enclosing one; else at `containerEnd`.
fn endAtBlank(self: *Parser, line_idx: usize) SourcePos {
    if (line_idx >= self.lines.len) return self.blank_after orelse self.containerEnd();
    if (isBlank(self.lines[line_idx])) return self.makePos(line_idx + 1, 0);
    return self.containerEnd();
}

/// The last fence character of the code or div fence on `line_idx`; what follows it does
/// not count.
fn fenceEnd(self: *Parser, line_idx: usize) SourcePos {
    const line = self.lines[line_idx];
    const rest = std.mem.trimStart(u8, line, " ");
    const run = countLeadingChar(rest, rest[0]);
    return self.makePos(line_idx, @intCast(line.len - rest.len + run));
}

/// Bytes the enclosing containers stripped from this parser's lines up to `line_idx`,
/// which the joined text no longer contains; past the last line, all of them.
fn offsetAdjustAt(self: *const Parser, line_idx: usize) u32 {
    if (self.offset_adjust.len == 0) return 0;
    return self.offset_adjust[@min(line_idx, self.offset_adjust.len - 1)];
}

/// Gives a sub-parser over joined container lines the positions of the lines they came
/// from: `orig_lines` is each line's index here, `col_offsets` the bytes stripped from
/// its start. Columns add the stripped bytes of their own line, this parser's included;
/// byte offsets add those of every line so far, at every level.
/// A parser over a container's re-joined content, in the same pass as this one. The
/// footnote sub-parser is not one: its blocks are stored, so they are parsed in full.
fn childParser(self: *Parser, text: []const u8) Parser {
    var child = Parser.init(self.a, text, self.defs);
    child.survey_only = self.survey_only;
    return child;
}

fn positionSubParser(self: *Parser, sub: *Parser, orig_lines: []const usize, col_offsets: []const u32) !void {
    if (!self.track_pos or orig_lines.len == 0) return;
    sub.track_pos = true;
    const first_orig = orig_lines[0];
    const first_col_off = col_offsets[0];
    sub.base_line = self.base_line + @as(u32, @intCast(first_orig));
    sub.base_offset = self.makePos(first_orig, first_col_off + 1).offset;
    const last_orig = orig_lines[orig_lines.len - 1];
    sub.input_end = self.makePos(last_orig + 1, 0);
    sub.stop = self.containerEnd();
    sub.stop_before = self.stopBefore();
    sub.blank_after = if (last_orig + 1 < self.lines.len and isBlank(self.lines[last_orig + 1])) self.makePos(last_orig + 2, 0) else null;
    sub.after_input = self.afterNewline(last_orig + 1);
    const cols = try self.a.alloc(u32, col_offsets.len);
    const adjust = try self.a.alloc(u32, col_offsets.len);
    var stripped: u32 = 0;
    for (col_offsets, orig_lines, cols, adjust) |strip, orig, *col, *adj| {
        col.* = strip + (if (orig < self.col_offsets.len) self.col_offsets[orig] else 0);
        stripped += strip;
        adj.* = stripped - first_col_off + (self.offsetAdjustAt(orig) - self.offsetAdjustAt(first_orig));
    }
    sub.col_offsets = cols;
    sub.offset_adjust = adjust;
}

fn updateListTightness(is_tight: *bool, saw_blank_between: *bool, content: *const ItemContent, inner_blocks: []const Node) void {
    if (content.item_saw_blank and content.block_lines.items.len > 0) {
        // A blank line before anything but a sublist makes the list loose, as djot.js;
        // only the block right after the blank counts, a definition list is a list
        // there too, and a definition, which leaves no block behind, counts as "anything".
        const lead: usize = if (content.para_lines.items.len > 0 and content.para_lines.items[0].len > 0) 1 else 0;
        if (inner_blocks.len <= lead) {
            is_tight.* = false;
        } else switch (inner_blocks[lead].tag) {
            .bullet_list, .ordered_list, .task_list, .definition_list => {},
            else => is_tight.* = false,
        }
    }
    if (content.item_saw_blank and content.block_lines.items.len == 0) saw_blank_between.* = true;
}

fn tryBulletList(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    const first_info = parseBulletMarker(line) orelse return null;
    const list_indent = first_info.indent;
    const marker_char = first_info.marker;
    const list_start_line = self.pos;

    // A task item after plain items, or the reverse, starts a new list, as djot.js.
    const list_is_task = isTaskItem(first_info.rest);

    var items: std.ArrayList(Node) = .empty;
    var is_tight = true;
    var saw_blank_between = false;

    while (self.pos < self.lines.len) {
        const cur = self.lines[self.pos];
        const cur_li = parseBulletMarker(cur) orelse break;
        if (cur_li.indent != list_indent or cur_li.marker != marker_char) break;
        const is_task = isTaskItem(cur_li.rest);
        if (is_task != list_is_task) break;

        if (saw_blank_between) is_tight = false;
        saw_blank_between = false;

        const item_start_line = self.pos;
        // A task item's content starts after the checkbox and the space that follows
        // it, as djot.js; a bare checkbox opens no paragraph.
        var first_rest = cur_li.rest;
        var first_col = cur_li.content_col;
        if (is_task) {
            const after_box = std.mem.trimStart(u8, cur_li.rest[@min(4, cur_li.rest.len)..], " \t");
            first_col += cur_li.rest.len - after_box.len;
            first_rest = after_box;
        }
        const task_checked = is_task and cur_li.rest[1] != ' ';
        const content = try self.collectItemContent(cur_li.content_col, first_col, list_indent, first_rest);

        const inner_blocks = try self.parseItemContent(&content);
        const item_sp = if (self.track_pos) self.makePos(item_start_line, @intCast(list_indent + 1)) else null;
        const item_ep = if (self.track_pos) self.stopBefore() else null;

        if (is_task) {
            try items.append(self.a, .{ .tag = .task_list_item, .children = inner_blocks, .checked = task_checked, .start_pos = item_sp, .end_pos = item_ep });
        } else {
            try items.append(self.a, .{ .tag = .list_item, .children = inner_blocks, .start_pos = item_sp, .end_pos = item_ep });
        }

        updateListTightness(&is_tight, &saw_blank_between, &content, inner_blocks);
    }

    const list_tag: Tag = if (list_is_task) .task_list else .bullet_list;
    const list_sp = if (self.track_pos) self.makePos(list_start_line, @intCast(list_indent + 1)) else null;
    const list_ep = if (self.track_pos) self.containerEnd() else null;
    const marker_str: []const u8 = switch (marker_char) {
        '-' => "-",
        '+' => "+",
        '*' => "*",
        else => "-",
    };
    return .{
        .tag = list_tag,
        .children = try items.toOwnedSlice(self.a),
        .tight = is_tight,
        .style = marker_str,
        .start_pos = list_sp,
        .end_pos = list_ep,
    };
}

fn tryOrderedList(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    const first_info = parseOrderedMarker(line) orelse return null;
    const list_indent = first_info.indent;
    const list_start_line = self.pos;

    var possible_styles: [2]?ListStyle = first_info.styles;
    var n_possible: u2 = first_info.n_styles;

    var items: std.ArrayList(Node) = .empty;
    var is_tight = true;
    var saw_blank_between = false;

    while (self.pos < self.lines.len) {
        const cur = self.lines[self.pos];
        const cur_ol = parseOrderedMarker(cur) orelse break;
        if (cur_ol.indent != list_indent) break;

        var compatible = false;
        for (0..cur_ol.n_styles) |si| {
            const s = cur_ol.styles[si] orelse continue;
            for (0..n_possible) |pi| {
                if (possible_styles[pi] == s) {
                    compatible = true;
                    break;
                }
            }
            if (compatible) break;
        }
        if (!compatible and items.items.len > 0) break;

        if (items.items.len > 0) {
            var new_styles: [2]?ListStyle = .{ null, null };
            var new_n: u2 = 0;
            for (0..n_possible) |pi| {
                const ps = possible_styles[pi] orelse continue;
                for (0..cur_ol.n_styles) |si| {
                    if (cur_ol.styles[si] == ps) {
                        new_styles[new_n] = ps;
                        new_n += 1;
                        break;
                    }
                }
            }
            if (new_n > 0) {
                possible_styles = new_styles;
                n_possible = new_n;
            }
        }

        if (saw_blank_between and items.items.len > 0) is_tight = false;
        saw_blank_between = false;

        const item_start_line = self.pos;
        const content = try self.collectItemContent(cur_ol.content_col, cur_ol.content_col, list_indent, cur_ol.rest);
        const inner_blocks = try self.parseItemContent(&content);

        const item_sp = if (self.track_pos) self.makePos(item_start_line, @intCast(list_indent + 1)) else null;
        const item_ep = if (self.track_pos) self.stopBefore() else null;
        try items.append(self.a, .{ .tag = .list_item, .children = inner_blocks, .start_pos = item_sp, .end_pos = item_ep });

        updateListTightness(&is_tight, &saw_blank_between, &content, inner_blocks);
    }

    const final_style = possible_styles[0] orelse .decimal;
    const resolved_start = getListStart(first_info.marker_text, final_style);
    var ol_attrs: std.ArrayList(Attr) = .empty;
    if (resolved_start != 1) {
        var start_buf: [20]u8 = undefined;
        const start_str = std.fmt.bufPrint(&start_buf, "{}", .{resolved_start}) catch "1";
        try ol_attrs.append(self.a, .{ .key = "start", .value = try self.a.dupe(u8, start_str) });
    }
    if (final_style.htmlType()) |t| {
        try ol_attrs.append(self.a, .{ .key = "type", .value = t });
    }
    const list_sp = if (self.track_pos) self.makePos(list_start_line, @intCast(list_indent + 1)) else null;
    const list_ep = if (self.track_pos) self.containerEnd() else null;
    return .{
        .tag = .ordered_list,
        .children = try items.toOwnedSlice(self.a),
        .tight = is_tight,
        .attrs = try ol_attrs.toOwnedSlice(self.a),
        .start_pos = list_sp,
        .end_pos = list_ep,
    };
}

fn tryDefinitionList(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (trimmed.len < 2 or trimmed[0] != ':' or (trimmed[1] != ' ' and trimmed[1] != '\t')) return null;
    const list_start_line = self.pos;

    var items: std.ArrayList(Node) = .empty;

    while (self.pos < self.lines.len) {
        const cur = self.lines[self.pos];
        const cur_trimmed = std.mem.trimStart(u8, cur, " ");
        if (cur_trimmed.len < 2 or cur_trimmed[0] != ':' or (cur_trimmed[1] != ' ' and cur_trimmed[1] != '\t')) break;

        const marker_indent = @as(usize, @intCast(cur.len - cur_trimmed.len));
        const content_indent = marker_indent + 2;
        const first_content = cur_trimmed[2..];
        const item_line = self.pos;
        self.pos += 1;

        // Each collected line with the line it came from and the bytes stripped before it.
        var content_lines: std.ArrayList([]const u8) = .empty;
        var orig_lines: std.ArrayList(usize) = .empty;
        var col_offsets: std.ArrayList(u32) = .empty;
        var paragraph = OpenParagraph{};
        try content_lines.append(self.a, first_content);
        try orig_lines.append(self.a, item_line);
        try col_offsets.append(self.a, @intCast(content_indent));
        try paragraph.feed(self.a, first_content);

        while (self.pos < self.lines.len) {
            const next = self.lines[self.pos];
            if (isBlank(next)) {
                const first_blank = self.pos;
                self.pos += 1;
                while (self.pos < self.lines.len and isBlank(self.lines[self.pos])) self.pos += 1;
                if (self.pos >= self.lines.len) break;
                const peek = self.lines[self.pos];
                if (countIndent(peek) >= content_indent) {
                    for (first_blank..self.pos) |blank| {
                        try content_lines.append(self.a, "");
                        try orig_lines.append(self.a, blank);
                        try col_offsets.append(self.a, 0);
                        try paragraph.feed(self.a, "");
                    }
                    continue;
                }
                break;
            }
            const ni = countIndent(next);
            if (ni >= content_indent) {
                try content_lines.append(self.a, next[content_indent..]);
                try orig_lines.append(self.a, self.pos);
                try col_offsets.append(self.a, @intCast(content_indent));
                try paragraph.feed(self.a, next[content_indent..]);
                self.pos += 1;
            } else if ((ni > marker_indent and ni < content_indent) or
                (paragraph.open and !try self.isBlockStartAt(self.pos)))
            {
                // Under-indented lines, and unindented ones while a paragraph (the
                // term, or a definition's paragraph) is open, continue it lazily.
                const lazy = std.mem.trimStart(u8, next, " \t");
                try content_lines.append(self.a, lazy);
                try orig_lines.append(self.a, self.pos);
                try col_offsets.append(self.a, @intCast(next.len - lazy.len));
                try paragraph.feed(self.a, lazy);
                self.pos += 1;
            } else {
                break;
            }
        }

        const content_text = try inline_mod.joinLines(self.a, content_lines.items);
        var inner_parser = self.childParser(content_text);
        try self.positionSubParser(&inner_parser, orig_lines.items, col_offsets.items);
        const all_blocks = try inner_parser.parseBlocks();

        var term_node: Node = undefined;
        var def_blocks: []const Node = &.{};
        if (all_blocks.len > 0 and all_blocks[0].tag == .para) {
            term_node = .{ .tag = .term, .children = all_blocks[0].children };
            def_blocks = all_blocks[1..];
        } else {
            term_node = .{ .tag = .term, .children = &.{} };
            def_blocks = all_blocks;
        }

        var item_children: std.ArrayList(Node) = .empty;
        try item_children.append(self.a, term_node);
        try item_children.append(self.a, .{ .tag = .definition, .children = def_blocks });
        var item = Node{ .tag = .definition_list_item, .children = try item_children.toOwnedSlice(self.a) };
        if (self.track_pos) {
            item.start_pos = self.makePos(item_line, @intCast(marker_indent + 1));
            item.end_pos = self.stopBefore();
        }
        try items.append(self.a, item);
    }

    if (items.items.len == 0) return null;
    var list = Node{ .tag = .definition_list, .children = try items.toOwnedSlice(self.a) };
    if (self.track_pos) {
        list.start_pos = self.makePos(list_start_line, @intCast(countIndent(line) + 1));
        list.end_pos = self.containerEnd();
    }
    return list;
}

fn tryTable(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    if (!isTableRow(line)) return null;
    const start_line = self.pos;

    var raw_rows: std.ArrayList([]const u8) = .empty;
    while (self.pos < self.lines.len) {
        const l = self.lines[self.pos];
        if (!isTableRow(l)) break;
        try raw_rows.append(self.a, l);
        self.pos += 1;
    }

    var aligns: std.ArrayList([]const CellAlign) = .empty;
    var head_above: std.ArrayList(bool) = .empty;
    for (raw_rows.items) |r| {
        if (isTableSep(r)) {
            try aligns.append(self.a, try parseSepAligns(self.a, r));
            try head_above.append(self.a, true);
        } else {
            try aligns.append(self.a, &.{});
            try head_above.append(self.a, false);
        }
    }

    var is_head_row: std.ArrayList(bool) = .empty;
    for (raw_rows.items, 0..) |_, idx| {
        if (head_above.items[idx]) {
            try is_head_row.append(self.a, false);
        } else {
            const next_is_sep = (idx + 1 < head_above.items.len and head_above.items[idx + 1]);
            try is_head_row.append(self.a, next_is_sep);
        }
    }

    var rows: std.ArrayList(Node) = .empty;
    var current_aligns: []const CellAlign = &.{};
    for (raw_rows.items, 0..) |r, idx| {
        if (head_above.items[idx]) {
            current_aligns = aligns.items[idx];
            continue;
        }
        const effective_aligns = if (is_head_row.items[idx])
            (if (idx + 1 < aligns.items.len) aligns.items[idx + 1] else current_aligns)
        else
            current_aligns;
        const line_idx = start_line + idx;
        const cells = try self.parseTableRowWithAlign(r, line_idx, effective_aligns, is_head_row.items[idx]);
        var row = Node{ .tag = .row, .children = cells, .head = is_head_row.items[idx] };
        if (self.track_pos) {
            row.start_pos = self.makePos(line_idx, self.contentCol(line_idx));
            row.end_pos = self.afterContent(line_idx);
        }
        try rows.append(self.a, row);
    }
    const rows_end = self.pos;

    // The last caption after the rows wins, as djot.js.
    var cap_lines: std.ArrayList([]const u8) = .empty;
    var cap_line: usize = rows_end;
    while (self.pos < self.lines.len) {
        var look = self.pos;
        while (look < self.lines.len and isBlank(self.lines[look])) : (look += 1) {}
        if (look >= self.lines.len) break;
        if (captionContent(self.lines[look])) |first| {
            cap_lines.items.len = 0;
            cap_line = look;
            self.pos = look;
            try cap_lines.append(self.a, first);
            self.pos += 1;
            while (self.pos < self.lines.len) {
                const l = self.lines[self.pos];
                if (isBlank(l)) break;
                if (isTableRow(l)) break;
                try cap_lines.append(self.a, std.mem.trim(u8, l, " \t"));
                self.pos += 1;
            }
        } else break;
    }

    // djot.js gives every table a caption, empty when there is none; a caption whose
    // marker line is empty starts on that line's newline and holds the lines after it.
    const bare_marker = cap_lines.items.len > 0 and cap_lines.items[0].len == 0;
    const cap_slices = if (bare_marker) cap_lines.items[1..] else cap_lines.items;
    var caption = Node{ .tag = .caption, .children = try self.parseBodyInlines(cap_slices, if (bare_marker) cap_line + 1 else cap_line, 0) };
    if (self.track_pos and cap_lines.items.len > 0) {
        caption.start_pos = self.captionStart(cap_line);
        caption.end_pos = if (cap_slices.len == 0) caption.start_pos else self.afterContent(self.pos - 1);
    }
    var table = Node{ .tag = .table };
    if (self.track_pos) {
        table.start_pos = self.makePos(start_line, self.contentCol(start_line));
        // As djot.js: where a caption on the line after the rows starts; else at the blank
        // line that follows the rows, or where the next block starts.
        table.end_pos = if (rows_end < self.lines.len and captionContent(self.lines[rows_end]) != null)
            self.captionStart(rows_end)
        else
            self.endAtBlank(rows_end);
    }
    var table_children: std.ArrayList(Node) = .empty;
    try table_children.append(self.a, caption);
    for (rows.items) |r| try table_children.append(self.a, r);
    table.children = try table_children.toOwnedSlice(self.a);
    return table;
}

/// The text of a caption line (`^ ` and what follows, trimmed), or null for any other line.
fn captionContent(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len > 1 and t[0] == '^' and t[1] == ' ') return std.mem.trim(u8, t[2..], " \t");
    return null;
}

/// Where the caption on `line_idx` starts: its text, or the line's newline when it has none.
fn captionStart(self: *Parser, line_idx: usize) SourcePos {
    const line = self.lines[line_idx];
    const content = captionContent(line).?;
    if (content.len == 0) return self.makePos(line_idx + 1, 0);
    return self.makePos(line_idx, @intCast(@intFromPtr(content.ptr) - @intFromPtr(line.ptr) + 1));
}

fn parseTableRowWithAlign(self: *Parser, line: []const u8, line_idx: usize, col_aligns: []const CellAlign, is_head: bool) ![]const Node {
    var cells: std.ArrayList(Node) = .empty;
    const trimmed = std.mem.trim(u8, line, " \t");
    var content = trimmed;
    if (content.len > 0 and content[0] == '|') content = content[1..];
    if (content.len > 0 and content[content.len - 1] == '|') content = content[0 .. content.len - 1];

    const cell_strs = try splitTableCells(self.a, content);
    for (cell_strs, 0..) |cell, col| {
        const cell_text = std.mem.trim(u8, cell, " \t");
        var node = Node{ .tag = .cell, .children = try self.parseBodyInlines(&.{cell_text}, line_idx, 0), .head = is_head };
        if (col < col_aligns.len) node.cell_align = col_aligns[col];
        if (self.track_pos) {
            // A cell runs from its leading pipe to the next one, inclusive.
            const open_col: u32 = @intCast(@intFromPtr(cell.ptr) - @intFromPtr(line.ptr));
            node.start_pos = self.makePos(line_idx, open_col);
            node.end_pos = self.makePos(line_idx, open_col + @as(u32, @intCast(cell.len)) + 1);
        }
        try cells.append(self.a, node);
    }
    return cells.toOwnedSlice(self.a);
}

// --- Utility functions ---

pub fn isBlank(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

/// Whether the line at `pos` starts a block other than a paragraph, so a container's
/// lazy paragraph continuation stops there. The set is djot.js's: every block start,
/// definitions and attribute blocks included.
fn isBlockStartAt(self: *Parser, pos: usize) !bool {
    if (isBlockStartLine(self.a, self.lines[pos])) return true;
    return (try self.blockAttrAt(pos)) != null;
}

/// `isBlockStartAt` for a line on its own: everything but an attribute block that
/// continues over the following lines.
fn isBlockStartLine(a: Allocator, line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (headingLevel(trimmed) != null) return true;
    if (startsBlockQuote(line)) return true;
    if (isCodeFence(line) != null) return true;
    if (parseBulletMarker(line) != null) return true;
    if (parseOrderedMarker(line) != null) return true;
    if (isThematicBreak(trimmed)) return true;
    if (trimmed[0] == ':' and trimmed.len > 1 and (trimmed[1] == ' ' or trimmed[1] == '\t')) return true;
    if (definitionLabel(line) != null) return true;
    if (isTableRow(line)) return true;
    if (isFencedDivStart(line) != null) return true;
    return attrs_mod.tryParseBlockAttr(a, line) != null;
}

/// Visual indent width. Tabs count as 4 spaces per the djot spec.
/// See also `countIndent` which counts only space characters.
fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            n += 1;
        } else if (c == '\t') {
            n += 4;
        } else break;
    }
    return n;
}

fn countIndent(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') : (n += 1) {}
    return n;
}

fn countLeadingChar(line: []const u8, char: u8) usize {
    for (line, 0..) |c, i| {
        if (c != char) return i;
    }
    return line.len;
}

fn isThematicBreak(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    var count: usize = 0;
    for (trimmed) |c| {
        if (c == ' ') continue;
        if (c != '*' and c != '-') return false;
        count += 1;
    }
    return count >= 3;
}

const FenceInfo = struct { len: usize, char: u8, lang: ?[]const u8, indent: usize };

fn isClosingCodeFence(line: []const u8, fence: FenceInfo) bool {
    const rest = std.mem.trimStart(u8, line, " ");
    const run = countLeadingChar(rest, fence.char);
    return run >= fence.len and isBlank(std.mem.trimStart(u8, rest[run..], &[_]u8{fence.char}));
}

/// Whether the lines collected so far into a container leave a paragraph (or a heading,
/// which also takes continuation lines) open, which is what an unindented line may
/// lazily continue. It follows the parser's own rules: nothing interrupts a paragraph; a
/// heading ends at what `tryHeading` stops at; a blank line closes either; after that a
/// code block, thematic break, table row, reference definition, empty footnote
/// definition or attribute line starts closed. A div fence met outside a paragraph opens
/// a div and a bare one closes the innermost div and whatever it held (fence lengths are
/// not matched; djot.js does not either). A block quote met outside a paragraph gets a
/// tracker of its own over its stripped lines, and a line that is not a quote line ends
/// it unless it is lazy text for the quote's open paragraph. List items are read as text
/// (their fences and rules are recognised whatever the indent).
const OpenParagraph = struct {
    open: bool = false,
    heading: bool = false,
    fence: ?FenceInfo = null,
    divs: usize = 0,
    quote: ?*OpenParagraph = null,
    in_quote: bool = false,

    fn feed(self: *OpenParagraph, a: Allocator, line: []const u8) !void {
        if (self.in_quote) {
            const q = self.quote.?;
            if (isBlank(line)) {
                self.in_quote = false;
                self.open = false;
                return;
            }
            if (startsBlockQuote(line)) {
                try q.feed(a, stripBlockQuotePrefix(line));
                self.open = q.open;
                return;
            }
            if (q.open and !isBlockStartLine(a, line)) {
                try q.feed(a, line);
                self.open = q.open;
                return;
            }
            // The nested quote has ended; this line is ours.
            self.in_quote = false;
            self.open = false;
        }
        if (self.fence) |f| {
            if (isClosingCodeFence(line, f)) self.fence = null;
            return;
        }
        if (isBlank(line)) {
            self.open = false;
            self.heading = false;
            return;
        }
        if (self.open and !(self.heading and endsHeading(a, line))) {
            if (isFencedDivStart(line)) |div| {
                if (self.divs > 0 and div.class == null) {
                    self.divs -= 1;
                    self.open = false;
                    self.heading = false;
                }
            }
            return;
        }
        self.open = false;
        self.heading = false;
        if (isFencedDivStart(line)) |div| {
            if (self.divs > 0 and div.class == null) self.divs -= 1 else self.divs += 1;
            return;
        }
        if (isCodeFence(line)) |f| {
            self.fence = f;
            return;
        }
        if (startsBlockQuote(line)) {
            const q = self.quote orelse try a.create(OpenParagraph);
            q.* = .{};
            try q.feed(a, stripBlockQuotePrefix(line));
            self.quote = q;
            self.in_quote = true;
            self.open = q.open;
            return;
        }
        if (definitionLabel(line)) |def| {
            self.open = def.is_footnote and def.rest.len > 0;
            return;
        }
        if (isThematicBreak(line) or isTableRow(line) or attrs_mod.tryParseBlockAttr(a, line) != null) return;
        self.open = true;
        self.heading = headingLevel(std.mem.trimStart(u8, line, " \t")) != null;
    }

    /// What `tryHeading` stops at.
    fn endsHeading(a: Allocator, line: []const u8) bool {
        return isThematicBreak(line) or isCodeFence(line) != null or startsBlockQuote(line) or
            isFencedDivStart(line) != null or parseBulletMarker(line) != null or
            parseOrderedMarker(line) != null or attrs_mod.tryParseBlockAttr(a, line) != null or
            definitionLabel(line) != null;
    }
};

fn isCodeFence(line: []const u8) ?FenceInfo {
    var indent: usize = 0;
    var rest = line;
    while (rest.len > 0 and rest[0] == ' ') {
        indent += 1;
        rest = rest[1..];
    }
    if (rest.len < 3) return null;

    const fence_char = rest[0];
    if (fence_char != '`' and fence_char != '~') return null;
    const fence_len = countLeadingChar(rest, fence_char);
    if (fence_len < 3) return null;
    const after_fence = std.mem.trim(u8, rest[fence_len..], " \t");

    if (fence_char == '`') {
        if (after_fence.len > 0) {
            if (std.mem.indexOfScalar(u8, after_fence, ' ') != null) return null;
            var bi: usize = 0;
            while (bi < after_fence.len) : (bi += 1) {
                if (after_fence[bi] == '`') {
                    const back_run = countLeadingChar(after_fence[bi..], '`');
                    if (back_run >= fence_len) return null;
                    bi += back_run;
                }
            }
        }
    }
    return .{ .len = fence_len, .char = fence_char, .lang = if (after_fence.len > 0) after_fence else null, .indent = indent };
}

/// One to six `#` followed by a space, a tab or the end of the line.
fn headingLevel(trimmed: []const u8) ?usize {
    const hashes = countLeadingChar(trimmed, '#');
    if (hashes == 0 or hashes > 6) return null;
    if (hashes < trimmed.len and trimmed[hashes] != ' ' and trimmed[hashes] != '\t') return null;
    return hashes;
}

fn startsBlockQuote(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (trimmed.len == 0) return false;
    if (trimmed[0] != '>') return false;
    if (trimmed.len == 1) return true;
    return trimmed[1] == ' ' or trimmed[1] == '\t';
}

fn stripBlockQuotePrefix(line: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (trimmed.len == 0) return "";
    if (trimmed[0] != '>') return line;
    if (trimmed.len == 1) return "";
    if (trimmed[1] == ' ' or trimmed[1] == '\t') return trimmed[2..];
    return trimmed[1..];
}

const DivInfo = struct { fence: []const u8, class: ?[]const u8 };

fn isFencedDivStart(line: []const u8) ?DivInfo {
    const trimmed = std.mem.trimStart(u8, line, " ");
    const colons = countLeadingChar(trimmed, ':');
    if (colons < 3) return null;
    const after = std.mem.trim(u8, trimmed[colons..], " \t");
    return .{ .fence = trimmed[0..colons], .class = if (after.len > 0) after else null };
}

fn mergeBlockAttrs(a: Allocator, existing: ?BlockAttrs, new_attrs: BlockAttrs) !BlockAttrs {
    if (existing) |ex| return ex.merge(new_attrs, a);
    return new_attrs;
}

const BulletInfo = struct { rest: []const u8, indent: usize, content_col: usize, marker: u8 };

/// Whether an item's first line opens with a checkbox: `[ ]`, `[x]` or `[X]` followed by
/// whitespace or nothing.
fn isTaskItem(rest: []const u8) bool {
    if (rest.len < 3 or rest[0] != '[' or rest[2] != ']') return false;
    if (rest[1] != ' ' and rest[1] != 'x' and rest[1] != 'X') return false;
    return rest.len == 3 or rest[3] == ' ' or rest[3] == '\t';
}

fn parseBulletMarker(line: []const u8) ?BulletInfo {
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') : (indent += 1) {}
    const trimmed = line[indent..];
    if (trimmed.len < 1) return null;
    if (trimmed[0] != '-' and trimmed[0] != '+' and trimmed[0] != '*') return null;
    // The marker alone on its line starts an empty item.
    if (trimmed.len > 1 and trimmed[1] != ' ' and trimmed[1] != '\t') return null;
    if (trimmed[0] == '-' or trimmed[0] == '*') {
        if (isThematicBreak(line)) return null;
    }
    const rest = if (trimmed.len > 1) trimmed[2..] else "";
    return .{ .rest = rest, .indent = indent, .content_col = indent + 2, .marker = trimmed[0] };
}

const ListStyle = enum {
    decimal,
    lower_alpha,
    upper_alpha,
    lower_roman,
    upper_roman,

    fn htmlType(self: ListStyle) ?[]const u8 {
        return switch (self) {
            .decimal => null,
            .lower_alpha => "a",
            .upper_alpha => "A",
            .lower_roman => "i",
            .upper_roman => "I",
        };
    }
};

const OrderedInfo = struct {
    rest: []const u8,
    indent: usize,
    content_col: usize,
    start: usize,
    style: ListStyle,
    styles: [2]?ListStyle,
    n_styles: u2,
    marker_text: []const u8,
};

fn parseOrderedMarker(line: []const u8) ?OrderedInfo {
    var indent: usize = 0;
    while (indent < line.len and line[indent] == ' ') : (indent += 1) {}
    const trimmed = line[indent..];
    if (trimmed.len < 2) return null;

    var paren_open = false;
    var start: usize = 0;
    if (trimmed[0] == '(') {
        paren_open = true;
        start = 1;
    }
    const after_paren = trimmed[start..];
    if (after_paren.len == 0) return null;

    var i: usize = 0;
    while (i < after_paren.len and std.ascii.isDigit(after_paren[i])) : (i += 1) {}
    if (i > 0 and i < after_paren.len) {
        const delim = after_paren[i];
        if ((!paren_open and (delim == '.' or delim == ')')) or (paren_open and delim == ')')) {
            const marker_len = start + i + 1;
            const num = std.fmt.parseInt(usize, after_paren[0..i], 10) catch 1;
            return finishMarker(trimmed, indent, marker_len, num, .decimal, .decimal, after_paren[0..i]);
        }
    }

    if (after_paren.len >= 2) {
        const c = after_paren[0];
        if (std.ascii.isLower(c)) {
            const delim = after_paren[1];
            if ((!paren_open and (delim == '.' or delim == ')')) or (paren_open and delim == ')')) {
                const marker_len = start + 2;
                if (isRomanLower(c)) {
                    return finishMarker(trimmed, indent, marker_len, romanToNumber(&.{c}), .lower_roman, .lower_alpha, after_paren[0..1]);
                } else {
                    return finishMarker(trimmed, indent, marker_len, @as(usize, c - 'a') + 1, .lower_alpha, .lower_alpha, after_paren[0..1]);
                }
            }
        }
        if (std.ascii.isUpper(c)) {
            const delim = after_paren[1];
            if ((!paren_open and (delim == '.' or delim == ')')) or (paren_open and delim == ')')) {
                const marker_len = start + 2;
                if (isRomanUpper(c)) {
                    return finishMarker(trimmed, indent, marker_len, romanToNumber(&.{c}), .upper_roman, .upper_alpha, after_paren[0..1]);
                } else {
                    return finishMarker(trimmed, indent, marker_len, @as(usize, c - 'A') + 1, .upper_alpha, .upper_alpha, after_paren[0..1]);
                }
            }
        }
        if (isRomanLower(c)) {
            var j: usize = 0;
            while (j < after_paren.len and isRomanLower(after_paren[j])) : (j += 1) {}
            if (j > 1 and j < after_paren.len) {
                const delim = after_paren[j];
                if ((!paren_open and (delim == '.' or delim == ')')) or (paren_open and delim == ')')) {
                    const marker_len = start + j + 1;
                    const num = romanToNumber(after_paren[0..j]);
                    return finishMarker(trimmed, indent, marker_len, num, .lower_roman, .lower_roman, after_paren[0..j]);
                }
            }
        }
        if (isRomanUpper(c)) {
            var j: usize = 0;
            while (j < after_paren.len and isRomanUpper(after_paren[j])) : (j += 1) {}
            if (j > 1 and j < after_paren.len) {
                const delim = after_paren[j];
                if ((!paren_open and (delim == '.' or delim == ')')) or (paren_open and delim == ')')) {
                    const marker_len = start + j + 1;
                    const num = romanToNumber(after_paren[0..j]);
                    return finishMarker(trimmed, indent, marker_len, num, .upper_roman, .upper_roman, after_paren[0..j]);
                }
            }
        }
    }

    return null;
}

fn finishMarker(trimmed: []const u8, indent: usize, marker_len: usize, num: usize, style1: ListStyle, style2: ListStyle, marker_text: []const u8) ?OrderedInfo {
    if (marker_len >= trimmed.len) {
        return .{ .rest = "", .indent = indent, .content_col = indent + marker_len + 1, .start = num, .style = style1, .styles = .{ style1, if (style1 != style2) style2 else null }, .n_styles = if (style1 != style2) 2 else 1, .marker_text = marker_text };
    }
    if (trimmed[marker_len] != ' ' and trimmed[marker_len] != '\t') return null;
    return .{ .rest = trimmed[marker_len + 1 ..], .indent = indent, .content_col = indent + marker_len + 1, .start = num, .style = style1, .styles = .{ style1, if (style1 != style2) style2 else null }, .n_styles = if (style1 != style2) 2 else 1, .marker_text = marker_text };
}

fn getListStart(marker_text: []const u8, style: ListStyle) usize {
    return switch (style) {
        .decimal => std.fmt.parseInt(usize, marker_text, 10) catch 1,
        .lower_alpha => if (marker_text.len == 1) @as(usize, marker_text[0] - 'a') + 1 else 1,
        .upper_alpha => if (marker_text.len == 1) @as(usize, marker_text[0] - 'A') + 1 else 1,
        .lower_roman => romanToNumber(marker_text),
        .upper_roman => romanToNumber(marker_text),
    };
}

fn isRomanLower(c: u8) bool {
    return switch (c) {
        'i', 'v', 'x', 'l', 'c', 'd', 'm' => true,
        else => false,
    };
}

fn isRomanUpper(c: u8) bool {
    return switch (c) {
        'I', 'V', 'X', 'L', 'C', 'D', 'M' => true,
        else => false,
    };
}

fn romanToNumber(s: []const u8) usize {
    var total: usize = 0;
    var prev: usize = 0;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        const n: usize = switch (s[i]) {
            'i', 'I' => 1,
            'v', 'V' => 5,
            'x', 'X' => 10,
            'l', 'L' => 50,
            'c', 'C' => 100,
            'd', 'D' => 500,
            'm', 'M' => 1000,
            else => 0,
        };
        if (n < prev) {
            total -|= n;
        } else {
            total += n;
        }
        prev = n;
    }
    return if (total > 0) total else 1;
}

/// Advance past a backtick run and its matching closing run.
/// Returns the index past the closing backticks, or past end of text if no close found.
fn skipBacktickSpan(text: []const u8, start: usize) usize {
    var run: usize = 0;
    var j = start;
    while (j < text.len and text[j] == '`') : (j += 1) run += 1;
    var k = j;
    while (k < text.len) {
        if (text[k] == '`') {
            var r2: usize = 0;
            var m = k;
            while (m < text.len and text[m] == '`') : (m += 1) r2 += 1;
            if (r2 == run) return m;
            k = m;
        } else {
            k += 1;
        }
    }
    return text.len;
}

/// A table row starts and ends with an unescaped pipe outside verbatim, as djot.js.
fn isTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 2 or trimmed[0] != '|') return false;
    var i: usize = 0;
    var ends_with_pipe = false;
    while (i < trimmed.len) {
        if (trimmed[i] == '\\' and i + 1 < trimmed.len) {
            i += 2;
        } else if (trimmed[i] == '`') {
            i = skipBacktickSpan(trimmed, i);
        } else {
            ends_with_pipe = trimmed[i] == '|' and i == trimmed.len - 1;
            i += 1;
        }
    }
    return ends_with_pipe;
}

fn isTableSep(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t|");
    for (trimmed) |c| {
        if (c != '-' and c != ':' and c != '|' and c != ' ') return false;
    }
    return trimmed.len > 0;
}

fn parseSepAligns(a: Allocator, line: []const u8) ![]const CellAlign {
    var result: std.ArrayList(CellAlign) = .empty;
    const trimmed = std.mem.trim(u8, line, " \t");
    var content = trimmed;
    if (content.len > 0 and content[0] == '|') content = content[1..];
    if (content.len > 0 and content[content.len - 1] == '|') content = content[0 .. content.len - 1];

    var cell_iter = std.mem.splitScalar(u8, content, '|');
    while (cell_iter.next()) |cell| {
        const c = std.mem.trim(u8, cell, " \t");
        if (c.len == 0) {
            try result.append(a, .default);
            continue;
        }
        const left_colon = c[0] == ':';
        const right_colon = c[c.len - 1] == ':';
        if (left_colon and right_colon) {
            try result.append(a, .center);
        } else if (right_colon) {
            try result.append(a, .right);
        } else if (left_colon) {
            try result.append(a, .left);
        } else {
            try result.append(a, .default);
        }
    }
    return result.toOwnedSlice(a);
}

fn splitTableCells(a: Allocator, content: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var cell_start: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 2;
        } else if (content[i] == '`') {
            i = skipBacktickSpan(content, i);
        } else if (content[i] == '|') {
            try result.append(a, content[cell_start..i]);
            cell_start = i + 1;
            i += 1;
        } else {
            i += 1;
        }
    }
    try result.append(a, content[cell_start..]);
    return result.toOwnedSlice(a);
}

test "CRLF input is indexed without carriage returns; offsets count them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const index = try indexLines(arena.allocator(), "-\r\n- b\r\n");
    try std.testing.expectEqualStrings("-", index.lines[0]);
    try std.testing.expectEqualStrings("- b", index.lines[1]);
    try std.testing.expectEqual(@as(u32, 3), index.offsets[1]);
}

test "definitions outlive the block that defined them" {
    const input =
        \\> {.c}
        \\> [x]: /u
        \\
        \\[^n]: note
        \\
        \\a
    ;
    const block_mem = try std.testing.allocator.alloc(u8, 1 << 16);
    defer std.testing.allocator.free(block_mem);
    var block_fba = std.heap.FixedBufferAllocator.init(block_mem);
    var doc_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer doc_arena.deinit();
    var defs = Definitions{ .a = doc_arena.allocator() };

    var p = Parser.init(block_fba.allocator(), input, &defs);
    while (try p.nextBlock()) |_| {}
    // Whatever a definition still shares with the block allocator is now garbage.
    @memset(block_mem, 0xff);

    const x = defs.ref_defs.get("x").?;
    try std.testing.expectEqualStrings("/u", x.url);
    try std.testing.expectEqualStrings("class", x.attrs.?.attrs[0].key);
    try std.testing.expectEqualStrings("c", x.attrs.?.attrs[0].value);
    const note = defs.footnote_defs.get("n").?;
    try std.testing.expectEqualStrings("note", note.blocks[0].children[0].text);
}
