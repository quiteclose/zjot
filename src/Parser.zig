const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const Attr = node_mod.Attr;
const SourcePos = node_mod.SourcePos;
const CellAlign = node_mod.CellAlign;
const attrs_mod = @import("attributes.zig");
const BlockAttrs = attrs_mod.BlockAttrs;
const inline_mod = @import("inline.zig");
const LineMap = @import("LineMap.zig");
const leaf = @import("leaf.zig");
const FenceInfo = leaf.FenceInfo;
const Marker = leaf.Marker;
const ListKind = leaf.ListKind;
const OrderedStyles = leaf.OrderedStyles;
const document = @import("document.zig");
const Definitions = document.Definitions;
const FootnoteDef = document.FootnoteDef;

const Parser = @This();

/// What parsing can fail with: only allocation. Named so the recursive functions can
/// state it; `root.render` adds the writer's error.
pub const Error = Allocator.Error;

a: Allocator,
/// The document's line index, shared by every parser over it.
doc: LineIndex,
/// This parser's window onto the document: `lines[i]` is document line `first + i` with
/// the enclosing containers' prefixes removed, `start[i]` how many bytes they removed
/// (none when `start` is empty, as in the root).
first: usize = 0,
lines: []const []const u8 = &.{},
start: []const u32 = &.{},
pos: usize = 0,
defs: *Definitions,
/// While a child parses a div's content: the line of the div's closing fence, where this
/// parser stands (`tryFencedDiv`); the child's blocks end past it or on it.
closing_fence: ?usize = null,
track_pos: bool = false,
/// Whether blank lines separate the block `nextBlock` last returned from the one before
/// it (list tightness); a blank first line precedes no block and does not count. A div's
/// closing fence counts as one, as djot.js (which emits a blank line event after it).
blank_before: bool = false,
fence_closed: bool = false,
/// Where the document ends (`inputEnd`).
doc_end: SourcePos = .{ .line = 1, .col = 1, .offset = 0 },
/// The root parser's position after the last block `nextBlock` returned (`trailing`).
after_block: usize = 0,
/// The parser whose container this one parses the content of, suspended at the line that
/// stopped the container; null in the root. A block that ends with this parser's window
/// ends where djot.js closes it, which depends on the lines after the window as the
/// enclosing parser sees them: lists and items at that stop (`containerEnd`,
/// `stopBefore`), block quotes and tables at the first blank line (`endAtBlank`), a
/// paragraph ending in a hard break at the next byte (`afterNewline`).
enclosing: ?*const Parser = null,

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

pub fn init(a: Allocator, input: []const u8, defs: *Definitions) !Parser {
    return initIndexed(a, input, try indexLines(a, input), defs);
}

/// Where the input ended.
pub fn endPos(self: *const Parser) SourcePos {
    return self.doc_end;
}

/// Whether lines followed the last block (blank lines, definitions, attributes), which
/// carry djot.js's events to the input's end.
pub fn trailing(self: *const Parser) bool {
    return self.pos > self.after_block;
}

/// A parser over the whole document, whose index was built elsewhere so it can outlive
/// what the parser allocates from `a`.
pub fn initIndexed(a: Allocator, input: []const u8, index: LineIndex, defs: *Definitions) Parser {
    return .{ .a = a, .doc = index, .lines = index.lines, .defs = defs, .doc_end = inputEnd(index, input) };
}

/// The lines of a container as the parser of its content will see them: each a slice of
/// the enclosing parser's line with the container's prefix removed (a blank line keeps
/// what the prefix leaves, which a code block preserves, as djot.js), consecutive from
/// line `first` of the enclosing parser's window.
const Window = struct {
    first: usize,
    lines: std.ArrayList([]const u8) = .empty,
    start: std.ArrayList(u32) = .empty,

    /// Line `line_idx` of `p` without its first `strip` bytes.
    fn add(self: *Window, p: *const Parser, line_idx: usize, strip: usize) !void {
        try self.addSlice(p, line_idx, strip, p.lines[line_idx][strip..]);
    }

    /// `content`, from line `line_idx` of `p`, `strip` bytes in.
    fn addSlice(self: *Window, p: *const Parser, line_idx: usize, strip: usize, content: []const u8) !void {
        std.debug.assert(line_idx == self.first + self.lines.items.len);
        try self.lines.append(p.a, content);
        try self.start.append(p.a, p.startOf(line_idx) + @as(u32, @intCast(strip)));
    }

    fn pop(self: *Window) void {
        _ = self.lines.pop();
        _ = self.start.pop();
    }
};

/// A parser over the content of a container this parser stopped at the end of; `a` holds
/// what it allocates (footnote content outlives the block).
fn child(self: *const Parser, a: Allocator, w: Window) Parser {
    return .{
        .a = a,
        .doc = self.doc,
        .first = self.first + w.first,
        .lines = w.lines.items,
        .start = w.start.items,
        .defs = self.defs,
        .track_pos = self.track_pos,
        .doc_end = self.doc_end,
        .enclosing = self,
    };
}

fn startOf(self: *const Parser, line_idx: usize) u32 {
    return if (line_idx < self.start.len) self.start[line_idx] else 0;
}

/// The position of 1-based `col` on window line `line_idx`; col 0 is the end of the
/// previous line (its newline), whatever this line strips. Past the last line lies the
/// window's end.
fn makePos(self: *const Parser, line_idx: usize, col: u32) SourcePos {
    if (line_idx >= self.lines.len) return self.windowEnd();
    const doc_line = self.first + line_idx;
    const line: u32 = @intCast(doc_line + 1);
    if (col == 0) return .{ .line = line, .col = 0, .offset = self.doc.offsets[doc_line] -| 1 };
    const start = self.startOf(line_idx);
    return .{ .line = line, .col = col + start, .offset = self.doc.offsets[doc_line] + start + col - 1 };
}

/// Where this window ends: the newline of its last line (col 0 of the line after it), or
/// the document's end when it holds the last line.
fn windowEnd(self: *const Parser) SourcePos {
    const after = self.first + self.lines.len;
    if (after >= self.doc.lines.len) return self.doc_end;
    return .{ .line = @intCast(after + 1), .col = 0, .offset = self.doc.offsets[after] -| 1 };
}

/// The index, in the enclosing parser's window, of the line after this one's.
fn afterInEnclosing(self: *const Parser) usize {
    return self.first + self.lines.len - self.enclosing.?.first;
}

/// Where a block that ran to this window's end ends: where the enclosing container
/// stopped, or the document's end.
fn enclosingEnd(self: *const Parser) SourcePos {
    return if (self.enclosing) |p| p.containerEnd() else self.doc_end;
}

fn parseBlocks(self: *Parser) Error![]const Node {
    var children: std.ArrayList(Node) = .empty;
    while (try self.nextBlock()) |n| try children.append(self.a, n);
    return children.toOwnedSlice(self.a);
}

/// The next block, or null at the end of the window. Definitions are recorded in `defs`
/// as they are met and never returned, so a caller may drop each block before asking for
/// the next.
pub fn nextBlock(self: *Parser) Error!?Node {
    var pending_attrs: ?BlockAttrs = null;
    const after_fence = self.fence_closed;
    self.fence_closed = false;
    self.blank_before = false;

    while (self.pos < self.lines.len) {
        const line = self.lines[self.pos];

        if (leaf.isBlank(line)) {
            if (self.pos > 0) self.blank_before = true;
            self.pos += 1;
            pending_attrs = null;
            continue;
        }

        if (try self.tryBlockAttr()) |ba| {
            pending_attrs = leaf.mergeBlockAttrs(self.a, pending_attrs, ba) catch ba;
            continue;
        }
        // A block attribute that opened but could not close is text, read without
        // attributes, as djot.js reparses it.
        const failed_attr = try attrs_mod.opensAttr(self.a, line);

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
        } else if (try self.tryList(.bullet)) |bl| {
            node = bl;
        } else if (try self.tryList(.ordered)) |ol| {
            node = ol;
        } else if (try self.tryTable()) |tbl| {
            node = tbl;
        } else {
            node = try self.parseParagraph(failed_attr);
        }

        if (pending_attrs) |ba| node = try inline_mod.applyBlockAttrsToNode(self.a, node, ba);
        if (after_fence) self.blank_before = true;
        self.after_block = self.pos;
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
        if (try attrs_mod.parseAttrsFromStr(self.a, trimmed)) |ba| return .{ .attrs = ba, .lines = 1 };
    }

    const indent = leaf.indentOf(line);
    var full_text: std.ArrayList(u8) = .empty;
    try full_text.appendSlice(self.a, trimmed);
    var lines_consumed: usize = 1;

    while (pos + lines_consumed < self.lines.len) {
        const next = self.lines[pos + lines_consumed];
        if (leaf.isBlank(next)) break;
        const next_indent = leaf.indentOf(next);
        if (next_indent <= indent) break;
        try full_text.append(self.a, '\n');
        try full_text.appendSlice(self.a, std.mem.trim(u8, next, " \t"));
        lines_consumed += 1;

        if (try attrs_mod.parseAttrsFromStr(self.a, full_text.items)) |ba| {
            return .{ .attrs = ba, .lines = lines_consumed };
        }
    }

    return null;
}

/// `literal_first_line`: the first line was a failed block attribute; no inline attribute
/// is read from it.
fn parseParagraph(self: *Parser, literal_first_line: bool) !Node {
    const para_start_line = self.pos;
    var text_lines: std.ArrayList([]const u8) = .empty;
    while (self.pos < self.lines.len) {
        const line = self.lines[self.pos];
        if (leaf.isBlank(line)) break;
        try text_lines.append(self.a, std.mem.trimStart(u8, line, " \t"));
        self.pos += 1;
    }

    const attrs_from: usize = if (literal_first_line) text_lines.items[0].len else 0;
    var para = Node{ .tag = .para, .children = try self.parseInlinesFrom(text_lines.items, para_start_line, attrs_from) };
    if (self.track_pos) {
        para.start_pos = self.makePos(para_start_line, self.contentCol(para_start_line));
        para.end_pos = self.leafEnd(para.children, self.pos - 1);
    }
    return para;
}

/// Where a paragraph or heading whose last line is `last_line` ends, as djot.js: one past
/// its last non-blank character (the line's newline, col 0 of the next line, unless
/// whitespace trails it), or one past a hard break that ends it.
fn leafEnd(self: *const Parser, children: []const Node, last_line: usize) SourcePos {
    if (children.len > 0 and children[children.len - 1].tag == .hard_break) return self.afterNewline(last_line + 1);
    return self.afterContent(last_line);
}

/// One past the last non-blank character of `line_idx`: the line's newline (col 0 of the
/// next line) unless whitespace trails it.
fn afterContent(self: *const Parser, line_idx: usize) SourcePos {
    const line = self.lines[line_idx];
    const content = std.mem.trimEnd(u8, line, " \t").len;
    if (content == line.len) return self.makePos(line_idx + 1, 0);
    return self.makePos(line_idx, @intCast(content + 1));
}

/// The first byte of `line_idx`: its newline when it is empty, the enclosing parser's
/// next byte or the document's end past this parser's input.
fn afterNewline(self: *const Parser, line_idx: usize) SourcePos {
    if (line_idx >= self.lines.len) return if (self.enclosing) |p| p.afterNewline(self.afterInEnclosing()) else self.doc_end;
    if (self.lines[line_idx].len == 0) return self.makePos(line_idx + 1, 0);
    return self.makePos(line_idx, 1);
}

/// Parses the inline content of `slices`, each a slice of its line, taken from the
/// consecutive lines starting at `first_line`; positioned when positions are tracked.
fn parseInlinesAt(self: *Parser, slices: []const []const u8, first_line: usize) ![]const Node {
    return self.parseInlinesFrom(slices, first_line, 0);
}

/// As `parseInlinesAt`, reading no inline attribute before joined offset `attrs_from`.
fn parseInlinesFrom(self: *Parser, slices: []const []const u8, first_line: usize, attrs_from: usize) ![]const Node {
    const src = try inline_mod.joinLines(self.a, slices);
    if (src.len == 0) return &.{};
    const map: ?LineMap = if (self.track_pos) try self.buildInlineLineMap(slices, first_line) else null;
    return inline_mod.parseInlineContent(self.a, src, map, attrs_from);
}

fn contentCol(self: *const Parser, line_idx: usize) u32 {
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
    const hashes = leaf.headingLevel(trimmed) orelse return null;
    const start_line = self.pos;

    self.pos += 1;
    var content_lines: std.ArrayList([]const u8) = .empty;
    const after_hashes = std.mem.trim(u8, trimmed[hashes..], " \t");
    if (after_hashes.len > 0) try content_lines.append(self.a, after_hashes);
    const first_content_line = if (after_hashes.len > 0) start_line else start_line + 1;

    while (self.pos < self.lines.len) {
        const next = self.lines[self.pos];
        if (leaf.isBlank(next)) break;
        if (leaf.isThematicBreak(next) or leaf.isCodeFence(next) != null or
            leaf.startsBlockQuote(next) or leaf.isFencedDivStart(next) != null)
            break;
        if (leaf.parseBulletMarker(next) != null or leaf.parseOrderedMarker(next) != null) break;
        if (try attrs_mod.tryParseBlockAttr(self.a, next) != null or leaf.definitionLabel(next) != null) break;
        const next_trimmed = std.mem.trimStart(u8, next, " ");
        const next_hashes = leaf.countLeadingChar(next_trimmed, '#');
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
    self.defs.headings_parsed += 1;
    return node;
}

fn tryThematicBreak(self: *Parser) ?Node {
    const line = self.lines[self.pos];
    if (!leaf.isThematicBreak(line)) return null;
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
    const fence_info = leaf.isCodeFence(line) orelse return null;
    const open_line = self.pos;
    self.pos += 1;

    var content: std.ArrayList(u8) = .empty;
    var closed_at: ?usize = null;
    while (self.pos < self.lines.len) {
        const l = self.lines[self.pos];
        self.pos += 1;
        if (leaf.isClosingCodeFence(l, fence_info)) {
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
        // A fenced block ends on its closing fence; unclosed, where its container does.
        node.end_pos = if (closed_at) |l| self.fenceEnd(l) else self.containerEnd();
    }
    return node;
}

fn tryBlockQuote(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    if (!leaf.startsBlockQuote(line)) return null;
    const start_line = self.pos;
    const start_col: u32 = @intCast(leaf.countIndent(line) + 1);

    var w = Window{ .first = start_line };
    var paragraph = OpenParagraph{};
    while (self.pos < self.lines.len) {
        const l = self.lines[self.pos];
        if (leaf.startsBlockQuote(l)) {
            const inner = leaf.stripBlockQuotePrefix(l);
            try w.addSlice(self, self.pos, l.len - inner.len, inner);
            try paragraph.feed(self.a, inner);
            self.pos += 1;
        } else if (!leaf.isBlank(l) and paragraph.open and !try self.isBlockStartAt(self.pos)) {
            try w.add(self, self.pos, 0);
            try paragraph.feed(self.a, l);
            self.pos += 1;
        } else {
            break;
        }
    }

    var inner_parser = self.child(self.a, w);
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
    const div_info = leaf.isFencedDivStart(line) orelse return null;
    const open_line = self.pos;
    const close = try self.divClose(open_line, div_info.fence);
    var w = Window{ .first = open_line + 1 };
    for (open_line + 1..close orelse self.lines.len) |i| try w.add(self, i, 0);
    // The child's blocks end at the fence; this parser stands on it meanwhile.
    self.pos = close orelse self.lines.len;
    self.closing_fence = close;
    var inner_parser = self.child(self.a, w);
    const blocks = try inner_parser.parseBlocks();
    self.closing_fence = null;
    var node = Node{ .tag = .div, .children = blocks };
    if (div_info.class) |cls| node.attrs = try self.a.dupe(Attr, &.{.{ .key = "class", .value = cls }});
    if (self.track_pos) {
        node.start_pos = self.makePos(open_line, self.contentCol(open_line));
        // Closed, a div ends on its fence; unclosed, where the enclosing container does.
        node.end_pos = if (close) |l| self.fenceEnd(l) else self.containerEnd();
    }
    if (close != null) self.pos += 1;
    self.fence_closed = close != null;
    return node;
}

/// The closing fence of the div opened with `fence` on `open_line`, or null when the div
/// runs to the end of the window: as djot.js, the first line after it of at least as many
/// colons and nothing else, indented or not, that no code block holds (an open paragraph
/// makes a code fence text, so the paragraph tracker decides what a code block holds).
/// Nested divs do not count: the first fitting fence closes the outermost div.
fn divClose(self: *Parser, open_line: usize, fence: []const u8) !?usize {
    var paragraph = OpenParagraph{};
    var i = open_line + 1;
    while (i < self.lines.len) : (i += 1) {
        const line = self.lines[i];
        if (paragraph.fence == null and leaf.closesDiv(line, fence)) return i;
        try paragraph.feed(self.a, line);
    }
    return null;
}

fn tryRefDef(self: *Parser, pending_attrs: ?BlockAttrs) !?void {
    const def = leaf.definitionLabel(self.lines[self.pos]) orelse return null;
    if (def.is_footnote) return null;
    const label = def.label;
    var dest_text = def.rest;

    self.pos += 1;
    var dest_parts: std.ArrayList([]const u8) = .empty;
    if (dest_text.len > 0) try dest_parts.append(self.a, dest_text);
    while (self.pos < self.lines.len) {
        const next = self.lines[self.pos];
        if (leaf.isBlank(next)) break;
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

    const da = self.defs.a;
    try self.defs.ref_defs.put(da, try da.dupe(u8, label), .{
        .url = try da.dupe(u8, dest_text),
        .attrs = if (pending_attrs) |ba| try ba.dupe(da) else null,
    });
    return {};
}

fn tryFootnoteDef(self: *Parser) !?void {
    const def = leaf.definitionLabel(self.lines[self.pos]) orelse return null;
    if (!def.is_footnote) return null;
    const label = def.label;
    const rest = def.rest;
    const def_line = self.pos;
    const headings_before = self.defs.headings_parsed;
    self.pos += 1;

    var w = Window{ .first = if (rest.len > 0) def_line else def_line + 1 };
    var paragraph = OpenParagraph{};
    // The first indented line sets the content indent; deeper lines keep the rest, as
    // in a list item (`collectItemContent`).
    var content_indent: ?usize = null;
    if (rest.len > 0) {
        try w.addSlice(self, def_line, def.rest_col, rest);
        try paragraph.feed(self.a, rest);
    }
    while (self.pos < self.lines.len) {
        const l = self.lines[self.pos];
        if (leaf.isBlank(l)) {
            var lookahead = self.pos + 1;
            while (lookahead < self.lines.len and leaf.isBlank(self.lines[lookahead])) : (lookahead += 1) {}
            if (lookahead < self.lines.len and
                self.lines[lookahead].len > 0 and
                (self.lines[lookahead][0] == ' ' or self.lines[lookahead][0] == '\t'))
            {
                try w.add(self, self.pos, @min(content_indent orelse l.len, l.len));
                try paragraph.feed(self.a, "");
                self.pos += 1;
            } else break;
        } else if (l[0] == ' ' or l[0] == '\t') {
            const indent = leaf.countIndent(l);
            const strip = @min(indent, content_indent orelse indent);
            if (content_indent == null) content_indent = indent;
            try w.add(self, self.pos, strip);
            try paragraph.feed(self.a, l[strip..]);
            self.pos += 1;
        } else if (paragraph.open and !try self.isBlockStartAt(self.pos)) {
            // An unindented line continues an open paragraph, as in a list item.
            try w.add(self, self.pos, 0);
            try paragraph.feed(self.a, l);
            self.pos += 1;
        } else break;
    }

    // The footnote's blocks are rendered at the end of the document, so they are parsed
    // with the definitions' allocator rather than the current block's, and positioned
    // like any container's.
    const da = self.defs.a;
    var inner_parser = self.child(da, w);
    const stored = try da.create(FootnoteDef);
    stored.* = .{ .blocks = try inner_parser.parseBlocks() };
    if (self.track_pos) {
        stored.start_pos = self.makePos(def_line, self.contentCol(def_line));
        stored.end_pos = self.definitionEnd();
    }
    const key = try da.dupe(u8, label);
    try self.defs.footnote_defs.put(da, key, stored);
    try self.defs.footnote_log.append(da, .{ .label = key, .def = stored, .headings_before = headings_before });
    return {};
}

/// An item's lines after its marker, as one window, and whether blank lines ended it.
const ItemContent = struct {
    window: Window,
    trailing_blank: bool,
};

/// Collects an item's lines: `first_rest` is the first line's content, starting at
/// column `first_col`; `content_col` is where continuation lines are expected. After the
/// first line come lines indented past the list's marker (content), unindented text
/// continuing an open paragraph (lazy) and blank lines, up to a line that is none of
/// these. Content lines all lose the same prefix: the content column, or less when one is
/// indented less (a sublist's marker may sit anywhere past this list's marker, as
/// djot.js), so a sublist's items and their content keep their relative indentation.
fn collectItemContent(self: *Parser, content_col: usize, first_col: usize, list_indent: usize, first_rest: []const u8) !ItemContent {
    const Kind = enum { first, content, lazy, blank };
    var kinds: std.ArrayList(Kind) = .empty;
    const first_line = self.pos;
    try kinds.append(self.a, .first);
    self.pos += 1;
    var strip = content_col;
    var paragraph = OpenParagraph{};
    try paragraph.feed(self.a, first_rest);

    while (self.pos < self.lines.len) {
        const next = self.lines[self.pos];
        if (leaf.isBlank(next)) {
            try kinds.append(self.a, .blank);
            try paragraph.feed(self.a, "");
            self.pos += 1;
            continue;
        }
        // A marker at or left of this list's ends the item, lazy or not.
        if (leaf.parseBulletMarker(next)) |m| if (m.indent <= list_indent) break;
        if (leaf.parseOrderedMarker(next)) |m| if (m.indent <= list_indent) break;
        const next_indent = leaf.countIndent(next);
        if (next_indent > list_indent) {
            try kinds.append(self.a, .content);
            strip = @min(strip, next_indent);
            try paragraph.feed(self.a, next[@min(next_indent, content_col)..]);
            self.pos += 1;
            continue;
        }
        if (paragraph.open and !(try self.isBlockStartAt(self.pos))) {
            try kinds.append(self.a, .lazy);
            try paragraph.feed(self.a, std.mem.trimStart(u8, next, " \t"));
            self.pos += 1;
            continue;
        }
        break;
    }

    var trailing_blank = false;
    while (kinds.items[kinds.items.len - 1] == .blank) {
        _ = kinds.pop();
        trailing_blank = true;
    }
    var w = Window{ .first = first_line };
    for (kinds.items, first_line..) |kind, line_idx| {
        const line = self.lines[line_idx];
        switch (kind) {
            // A bare marker's line is shorter than its content column.
            .first => try w.addSlice(self, line_idx, @min(first_col, line.len), first_rest),
            .content => try w.add(self, line_idx, strip),
            .lazy => try w.add(self, line_idx, line.len - std.mem.trimStart(u8, line, " \t").len),
            .blank => try w.add(self, line_idx, @min(strip, line.len)),
        }
    }
    return .{ .window = w, .trailing_blank = trailing_blank };
}

const ItemBlocks = struct {
    blocks: []const Node,
    /// A blank line separated two of the blocks, which makes the list loose.
    loose: bool,
};

fn isList(node: Node) bool {
    return switch (node.tag) {
        .bullet_list, .ordered_list, .task_list, .definition_list => true,
        else => false,
    };
}

fn parseItemContent(self: *Parser, content: *const ItemContent) !ItemBlocks {
    var blocks: std.ArrayList(Node) = .empty;
    var loose = false;
    var parser = self.child(self.a, content.window);
    while (try parser.nextBlock()) |block| {
        // As djot.js, a blank line belongs to the innermost list open when it came, and
        // makes it loose unless a list follows it: a blank after a sublist is the
        // sublist's, discarded when it closes; one before a sublist is reset by its start.
        const after_list = blocks.items.len > 0 and isList(blocks.items[blocks.items.len - 1]);
        if (parser.blank_before and !after_list and !isList(block)) loose = true;
        try blocks.append(self.a, block);
    }
    // A blank followed only by definitions counts too: they are events, not blocks.
    const after_list = blocks.items.len > 0 and isList(blocks.items[blocks.items.len - 1]);
    if (parser.blank_before and !after_list) loose = true;
    return .{ .blocks = try blocks.toOwnedSlice(self.a), .loose = loose };
}

/// Where a container ends, as djot.js: where the next block's content starts on the line
/// the parser stopped at, or that line's newline when it is blank (a block quote stops
/// there); past the enclosing div's closing fence when that stopped it; at the end of
/// this window, where the enclosing parser stopped, or the document's end.
fn containerEnd(self: *const Parser) SourcePos {
    if (self.pos >= self.lines.len) return self.enclosingEnd();
    const line = self.lines[self.pos];
    if (leaf.isBlank(line) or self.closing_fence == self.pos) return self.makePos(self.pos + 1, 0);
    return self.makePos(self.pos, @intCast(leaf.countIndent(line) + 1));
}

/// Where a footnote definition ends, as djot.js: where the next block's content starts,
/// blank lines skipped, or where this parser's input ends.
fn definitionEnd(self: *const Parser) SourcePos {
    var next = self.pos;
    while (next < self.lines.len and leaf.isBlank(self.lines[next])) : (next += 1) {}
    if (next >= self.lines.len) return self.enclosingEnd();
    return self.makePos(next, @intCast(leaf.countIndent(self.lines[next]) + 1));
}

/// Where an item ends, as djot.js: one position before `containerEnd` (the character
/// before the stop line's content, or col 0, the previous line's end, when it has none),
/// on the closing fence's last character, or where the enclosing parser's items end.
fn stopBefore(self: *const Parser) SourcePos {
    if (self.pos >= self.lines.len) return if (self.enclosing) |p| p.stopBefore() else self.doc_end;
    const line = self.lines[self.pos];
    if (self.closing_fence == self.pos) return self.fenceEnd(self.pos);
    if (leaf.isBlank(line)) return self.makePos(self.pos, 0);
    const stop = self.containerEnd();
    return .{ .line = stop.line, .col = stop.col - 1, .offset = stop.offset - 1 };
}

/// Where a block quote or table ends, as djot.js: on the newline of the blank line at
/// `line_idx` that follows it, in this parser or the enclosing one; else at `containerEnd`.
fn endAtBlank(self: *const Parser, line_idx: usize) SourcePos {
    if (line_idx >= self.lines.len) return if (self.enclosing) |p| p.endAtBlank(self.afterInEnclosing()) else self.containerEnd();
    if (leaf.isBlank(self.lines[line_idx])) return self.makePos(line_idx + 1, 0);
    return self.containerEnd();
}

/// The last fence character of the code or div fence on `line_idx`; what follows it does
/// not count.
fn fenceEnd(self: *const Parser, line_idx: usize) SourcePos {
    const line = self.lines[line_idx];
    const rest = std.mem.trimStart(u8, line, " \t");
    const run = leaf.countLeadingChar(rest, rest[0]);
    return self.makePos(line_idx, @intCast(line.len - rest.len + run));
}

/// A bullet or ordered list: consecutive items whose markers continue the first one's
/// (bullets: the same character, task or plain alike; ordered: a shared number style).
fn tryList(self: *Parser, comptime kind: ListKind) !?Node {
    const first = leaf.parseMarker(kind, self.lines[self.pos]) orelse return null;
    const list_indent = first.indent;
    const list_start_line = self.pos;
    // A task item after plain items, or the reverse, starts a new list, as djot.js.
    const list_is_task = kind == .bullet and leaf.isTaskItem(first.rest);
    var styles = OrderedStyles{ .possible = first.styles, .n = first.n_styles };

    var items: std.ArrayList(Node) = .empty;
    var is_tight = true;
    var saw_blank_between = false;

    while (self.pos < self.lines.len) {
        const m = leaf.parseMarker(kind, self.lines[self.pos]) orelse break;
        if (m.indent != list_indent) break;
        switch (kind) {
            .bullet => if (m.bullet != first.bullet or leaf.isTaskItem(m.rest) != list_is_task) break,
            .ordered => if (m.delim != first.delim or !styles.accept(m, items.items.len == 0)) break,
        }

        const item_start_line = self.pos;
        // A task item's content starts after the checkbox and the space that follows
        // it, as djot.js; a bare checkbox opens no paragraph.
        var first_rest = m.rest;
        var first_col = m.content_col;
        if (list_is_task) {
            const after_box = std.mem.trimStart(u8, m.rest[@min(4, m.rest.len)..], " \t");
            first_col += m.rest.len - after_box.len;
            first_rest = after_box;
        }
        const content = try self.collectItemContent(m.content_col, first_col, list_indent, first_rest);
        const parsed = try self.parseItemContent(&content);
        const inner_blocks = parsed.blocks;
        // Blank lines between items make the list loose, unless a sublist absorbs them: the
        // one ending the item before, or the one this item starts with, as djot.js.
        const starts_with_list = inner_blocks.len > 0 and isList(inner_blocks[0]);
        const ends_with_list = inner_blocks.len > 0 and isList(inner_blocks[inner_blocks.len - 1]);
        if (parsed.loose or (saw_blank_between and !starts_with_list)) is_tight = false;
        saw_blank_between = content.trailing_blank and !ends_with_list;
        try items.append(self.a, .{
            .tag = if (list_is_task) .task_list_item else .list_item,
            .children = inner_blocks,
            .checked = if (list_is_task) m.rest[1] != ' ' else null,
            .start_pos = if (self.track_pos) self.makePos(item_start_line, @intCast(list_indent + 1)) else null,
            .end_pos = if (self.track_pos) self.stopBefore() else null,
        });
    }

    var list = Node{
        .tag = switch (kind) {
            .bullet => if (list_is_task) .task_list else .bullet_list,
            .ordered => .ordered_list,
        },
        .children = try items.toOwnedSlice(self.a),
        .tight = is_tight,
        .start_pos = if (self.track_pos) self.makePos(list_start_line, @intCast(list_indent + 1)) else null,
        .end_pos = if (self.track_pos) self.containerEnd() else null,
    };
    switch (kind) {
        .bullet => list.style = switch (first.bullet) {
            '+' => "+",
            '*' => "*",
            else => "-",
        },
        .ordered => {
            list.list_style = styles.possible[0] orelse .decimal;
            list.start = leaf.getListStart(first.marker_text, list.list_style.?);
        },
    }
    return list;
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

        var w = Window{ .first = item_line };
        var paragraph = OpenParagraph{};
        try w.add(self, item_line, content_indent);
        try paragraph.feed(self.a, first_content);

        while (self.pos < self.lines.len) {
            const next = self.lines[self.pos];
            if (leaf.isBlank(next)) {
                const first_blank = self.pos;
                self.pos += 1;
                while (self.pos < self.lines.len and leaf.isBlank(self.lines[self.pos])) self.pos += 1;
                if (self.pos >= self.lines.len) break;
                const peek = self.lines[self.pos];
                if (leaf.countIndent(peek) >= content_indent) {
                    for (first_blank..self.pos) |blank| {
                        try w.add(self, blank, @min(content_indent, self.lines[blank].len));
                        try paragraph.feed(self.a, "");
                    }
                    continue;
                }
                break;
            }
            const ni = leaf.countIndent(next);
            if (ni >= content_indent) {
                try w.add(self, self.pos, content_indent);
                try paragraph.feed(self.a, next[content_indent..]);
                self.pos += 1;
            } else if ((ni > marker_indent and ni < content_indent) or
                (paragraph.open and !try self.isBlockStartAt(self.pos)))
            {
                // Under-indented lines, and unindented ones while a paragraph (the
                // term, or a definition's paragraph) is open, continue it lazily.
                const lazy = std.mem.trimStart(u8, next, " \t");
                try w.add(self, self.pos, next.len - lazy.len);
                try paragraph.feed(self.a, lazy);
                self.pos += 1;
            } else {
                break;
            }
        }

        var inner_parser = self.child(self.a, w);
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
        list.start_pos = self.makePos(list_start_line, @intCast(leaf.countIndent(line) + 1));
        list.end_pos = self.containerEnd();
    }
    return list;
}

fn tryTable(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    if (!leaf.isTableRow(line)) return null;
    const start_line = self.pos;

    var raw_rows: std.ArrayList([]const u8) = .empty;
    while (self.pos < self.lines.len) {
        const l = self.lines[self.pos];
        if (!leaf.isTableRow(l)) break;
        try raw_rows.append(self.a, l);
        self.pos += 1;
    }

    var aligns: std.ArrayList([]const CellAlign) = .empty;
    var head_above: std.ArrayList(bool) = .empty;
    for (raw_rows.items) |r| {
        if (leaf.isTableSep(r)) {
            try aligns.append(self.a, try leaf.parseSepAligns(self.a, r));
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
        while (look < self.lines.len and leaf.isBlank(self.lines[look])) : (look += 1) {}
        if (look >= self.lines.len) break;
        if (leaf.captionContent(self.lines[look])) |first| {
            cap_lines.items.len = 0;
            cap_line = look;
            self.pos = look;
            try cap_lines.append(self.a, first);
            self.pos += 1;
            while (self.pos < self.lines.len) {
                const l = self.lines[self.pos];
                if (leaf.isBlank(l)) break;
                if (leaf.isTableRow(l)) break;
                try cap_lines.append(self.a, std.mem.trim(u8, l, " \t"));
                self.pos += 1;
            }
        } else break;
    }

    // djot.js gives every table a caption, empty when there is none; a caption whose
    // marker line is empty starts on that line's newline and holds the lines after it.
    const bare_marker = cap_lines.items.len > 0 and cap_lines.items[0].len == 0;
    const cap_slices = if (bare_marker) cap_lines.items[1..] else cap_lines.items;
    var caption = Node{ .tag = .caption, .children = try self.parseInlinesAt(cap_slices, if (bare_marker) cap_line + 1 else cap_line) };
    if (self.track_pos and cap_lines.items.len > 0) {
        caption.start_pos = self.captionStart(cap_line);
        caption.end_pos = if (cap_slices.len == 0) caption.start_pos else self.afterContent(self.pos - 1);
    }
    var table = Node{ .tag = .table };
    if (self.track_pos) {
        table.start_pos = self.makePos(start_line, self.contentCol(start_line));
        // As djot.js: where a caption on the line after the rows starts; else at the blank
        // line that follows the rows, or where the next block starts.
        table.end_pos = if (rows_end < self.lines.len and leaf.captionContent(self.lines[rows_end]) != null)
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

/// Where the caption on `line_idx` starts: its text, or the line's newline when it has none.
fn captionStart(self: *const Parser, line_idx: usize) SourcePos {
    const line = self.lines[line_idx];
    const content = leaf.captionContent(line).?;
    if (content.len == 0) return self.makePos(line_idx + 1, 0);
    return self.makePos(line_idx, @intCast(@intFromPtr(content.ptr) - @intFromPtr(line.ptr) + 1));
}

fn parseTableRowWithAlign(self: *Parser, line: []const u8, line_idx: usize, col_aligns: []const CellAlign, is_head: bool) ![]const Node {
    var cells: std.ArrayList(Node) = .empty;
    const cell_strs = try leaf.rowCells(self.a, line);
    for (cell_strs, 0..) |cell, col| {
        const cell_text = std.mem.trim(u8, cell, " \t");
        var node = Node{ .tag = .cell, .children = try self.parseInlinesAt(&.{cell_text}, line_idx), .head = is_head };
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

/// Whether the line at `pos` starts a block other than a paragraph, so a container's
/// lazy paragraph continuation stops there. The set is djot.js's: every block start,
/// definitions and attribute blocks included.
fn isBlockStartAt(self: *Parser, pos: usize) !bool {
    if (try isBlockStartLine(self.a, self.lines[pos])) return true;
    return (try self.blockAttrAt(pos)) != null;
}

/// `isBlockStartAt` for a line on its own: everything but an attribute block that
/// continues over the following lines.
fn isBlockStartLine(a: Allocator, line: []const u8) !bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (leaf.headingLevel(trimmed) != null) return true;
    if (leaf.startsBlockQuote(line)) return true;
    if (leaf.isCodeFence(line) != null) return true;
    if (leaf.parseBulletMarker(line) != null) return true;
    if (leaf.parseOrderedMarker(line) != null) return true;
    if (leaf.isThematicBreak(trimmed)) return true;
    if (trimmed[0] == ':' and trimmed.len > 1 and (trimmed[1] == ' ' or trimmed[1] == '\t')) return true;
    if (leaf.definitionLabel(line) != null) return true;
    if (leaf.isTableRow(line)) return true;
    if (leaf.isFencedDivStart(line) != null) return true;
    return try attrs_mod.tryParseBlockAttr(a, line) != null;
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
    /// The fence lengths of the open divs, outermost first, as the parser sees them.
    div_fences: std.ArrayList(usize) = .empty,
    quote: ?*OpenParagraph = null,
    in_quote: bool = false,

    fn feed(self: *OpenParagraph, a: Allocator, line: []const u8) !void {
        if (self.in_quote) {
            const q = self.quote.?;
            if (leaf.isBlank(line)) {
                self.in_quote = false;
                self.open = false;
                return;
            }
            if (leaf.startsBlockQuote(line)) {
                try q.feed(a, leaf.stripBlockQuotePrefix(line));
                self.open = q.open;
                return;
            }
            if (q.open and !try isBlockStartLine(a, line)) {
                try q.feed(a, line);
                self.open = q.open;
                return;
            }
            // The nested quote has ended; this line is ours.
            self.in_quote = false;
            self.open = false;
        }
        if (self.fence) |f| {
            if (leaf.isClosingCodeFence(line, f)) self.fence = null;
            return;
        }
        if (leaf.isBlank(line)) {
            self.open = false;
            self.heading = false;
            return;
        }
        if (self.open and !(self.heading and try endsHeading(a, line))) {
            // A closing fence ends the paragraph with its div; an opener is text here.
            if (leaf.isFencedDivStart(line)) |div| if (div.class == null) {
                if (self.closingDiv(div.fence.len)) |depth| {
                    self.div_fences.items.len = depth;
                    self.open = false;
                    self.heading = false;
                }
            };
            return;
        }
        self.open = false;
        self.heading = false;
        if (leaf.isFencedDivStart(line)) |div| {
            if (div.class == null) {
                if (self.closingDiv(div.fence.len)) |depth| {
                    self.div_fences.items.len = depth;
                    return;
                }
            }
            try self.div_fences.append(a, div.fence.len);
            return;
        }
        if (leaf.isCodeFence(line)) |f| {
            self.fence = f;
            return;
        }
        if (leaf.startsBlockQuote(line)) {
            const q = self.quote orelse try a.create(OpenParagraph);
            q.* = .{};
            try q.feed(a, leaf.stripBlockQuotePrefix(line));
            self.quote = q;
            self.in_quote = true;
            self.open = q.open;
            return;
        }
        if (leaf.definitionLabel(line)) |def| {
            self.open = def.is_footnote and def.rest.len > 0;
            return;
        }
        if (leaf.isThematicBreak(line) or leaf.isTableRow(line) or try attrs_mod.tryParseBlockAttr(a, line) != null) return;
        self.open = true;
        self.heading = leaf.headingLevel(std.mem.trimStart(u8, line, " \t")) != null;
    }

    /// The depth a bare fence of `len` colons closes to: that of the outermost open div
    /// whose fence it fits, as `tryFencedDiv` (`divClose`); null when it opens a div.
    fn closingDiv(self: *const OpenParagraph, len: usize) ?usize {
        for (self.div_fences.items, 0..) |fence, depth| {
            if (fence <= len) return depth;
        }
        return null;
    }

    /// What `tryHeading` stops at.
    fn endsHeading(a: Allocator, line: []const u8) !bool {
        return leaf.isThematicBreak(line) or leaf.isCodeFence(line) != null or leaf.startsBlockQuote(line) or
            leaf.isFencedDivStart(line) != null or leaf.parseBulletMarker(line) != null or
            leaf.parseOrderedMarker(line) != null or try attrs_mod.tryParseBlockAttr(a, line) != null or
            leaf.definitionLabel(line) != null;
    }
};

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

    var p = try Parser.init(block_fba.allocator(), input, &defs);
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
