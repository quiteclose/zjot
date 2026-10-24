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
    footnote_defs: std.StringArrayHashMapUnmanaged([]const Node) = .{},
    /// Set by a consumer that parses the input a second time: definitions are then
    /// consumed from the input but not recorded again.
    sealed: bool = false,
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
track_pos: bool = false,
base_offset: u32 = 0,
base_line: u32 = 1,
col_offsets: []const u32 = &.{},

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
        line.* = it.next().?;
        line_offset.* = offset;
        offset += @intCast(line.*.len + 1);
    }
    return .{ .lines = lines, .offsets = offsets };
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

fn makePos(self: *Parser, line_idx: usize, col: u32) SourcePos {
    const col_adj: u32 = if (line_idx < self.col_offsets.len) self.col_offsets[line_idx] else 0;
    const display_col = col + col_adj;
    // col is 1-based in djot sourcepos. col==0 means "end of previous line"
    // (e.g. a closing fence), so the byte offset points one before this line.
    const offset = if (line_idx < self.line_offsets.len) blk: {
        if (col == 0) {
            break :blk if (self.line_offsets[line_idx] > 0) self.line_offsets[line_idx] - 1 else 0;
        }
        break :blk self.line_offsets[line_idx] + col - 1;
    } else if (self.line_offsets.len > 0)
        self.line_offsets[self.line_offsets.len - 1] + @as(u32, @intCast(self.lines[self.lines.len - 1].len))
    else
        0;
    return .{
        .line = self.base_line + @as(u32, @intCast(line_idx)),
        .col = display_col,
        .offset = self.base_offset + offset,
    };
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

    while (self.pos < self.lines.len) {
        const line = self.lines[self.pos];

        if (isBlank(line)) {
            self.pos += 1;
            pending_attrs = null;
            continue;
        }

        if (self.isClosingFence(line)) {
            self.pos += 1;
            return null;
        }

        if (try self.tryBlockAttr()) |ba| {
            pending_attrs = mergeBlockAttrs(self.a, pending_attrs, ba) catch ba;
            continue;
        }

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
            node = try self.parseParagraph();
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

fn parseParagraph(self: *Parser) !Node {
    const para_start_line = self.pos;
    var text_lines: std.ArrayList([]const u8) = .empty;
    while (self.pos < self.lines.len) {
        const line = self.lines[self.pos];
        if (isBlank(line)) break;
        if (self.isClosingFence(line)) break;
        try text_lines.append(self.a, std.mem.trimStart(u8, line, " \t"));
        self.pos += 1;
    }

    const src = try inline_mod.joinLines(self.a, text_lines.items);
    const inlines = if (src.len > 0) try inline_mod.parseInlineContent(self.a, src) else &.{};

    var para = Node{ .tag = .para, .children = inlines };
    if (self.track_pos) {
        const first_col = self.contentCol(para_start_line);
        para.start_pos = self.makePos(para_start_line, first_col);
        para.end_pos = self.makePos(self.pos, 0);
        const line_map = try self.buildInlineLineMap(text_lines.items, para_start_line);
        applyInlinePositions(inlines, src, line_map);
    }
    return para;
}

fn contentCol(self: *Parser, line_idx: usize) u32 {
    if (line_idx >= self.lines.len) return 1;
    const full_line = self.lines[line_idx];
    const trimmed = std.mem.trimStart(u8, full_line, " \t");
    return @intCast(full_line.len - trimmed.len + 1);
}

fn buildInlineLineMap(self: *Parser, text_lines: []const []const u8, start_line: usize) !LineMap {
    var segs: std.ArrayList(LineMap.Segment) = .empty;
    var joined_pos: u32 = 0;
    for (text_lines, 0..) |line, i| {
        const orig_line_idx = start_line + i;
        const col = self.contentCol(orig_line_idx);
        const pos_val = self.makePos(orig_line_idx, col);
        try segs.append(self.a, .{
            .joined_start = joined_pos,
            .orig_line = pos_val.line,
            .orig_col = pos_val.col,
            .orig_offset = pos_val.offset,
        });
        joined_pos += @intCast(line.len + 1);
    }
    return .{ .segments = try segs.toOwnedSlice(self.a) };
}

/// Sets source positions on str nodes using pointer arithmetic against
/// the joined source text. O(1) per node via LineMap, no string searching.
fn applyInlinePositions(nodes: []const Node, src: []const u8, line_map: LineMap) void {
    const src_start = @intFromPtr(src.ptr);
    const src_end = src_start + src.len;
    for (nodes) |*node_const| {
        const node = @constCast(node_const);
        if (node.tag == .str and node.text.len > 0) {
            const text_ptr = @intFromPtr(node.text.ptr);
            if (text_ptr >= src_start and text_ptr < src_end) {
                const offset: u32 = @intCast(text_ptr - src_start);
                node.start_pos = line_map.resolve(offset);
                const end_offset: u32 = offset + @as(u32, @intCast(node.text.len)) - 1;
                node.end_pos = line_map.resolve(end_offset);
            }
        }
    }
}

fn tryHeading(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const hashes = headingLevel(trimmed) orelse return null;

    self.pos += 1;
    var content_lines: std.ArrayList([]const u8) = .empty;
    const after_hashes = std.mem.trim(u8, trimmed[hashes..], " \t");
    if (after_hashes.len > 0) try content_lines.append(self.a, after_hashes);

    while (self.pos < self.lines.len) {
        const next = self.lines[self.pos];
        if (isBlank(next)) break;
        if (isThematicBreak(next) or isCodeFence(next) != null or
            startsBlockQuote(next) or isFencedDivStart(next) != null)
            break;
        if (parseBulletMarker(next) != null or parseOrderedMarker(next) != null) break;
        if (attrs_mod.tryParseBlockAttr(self.a, next) != null) break;
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

    const inlines = try inline_mod.parseInlines(self.a, content_lines.items);
    return .{ .tag = .heading, .level = @intCast(hashes), .children = inlines };
}

fn tryThematicBreak(self: *Parser) ?Node {
    const line = self.lines[self.pos];
    if (!isThematicBreak(line)) return null;
    self.pos += 1;
    return .{ .tag = .thematic_break };
}

fn tryCodeBlock(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    const fence_info = isCodeFence(line) orelse return null;
    self.pos += 1;

    var content: std.ArrayList(u8) = .empty;
    while (self.pos < self.lines.len) {
        const l = self.lines[self.pos];
        self.pos += 1;
        if (isClosingCodeFence(l, fence_info)) break;
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
    if (lang != null and lang.?[0] == '=') {
        return .{ .tag = .raw_block, .text = try content.toOwnedSlice(self.a), .lang = lang.?[1..] };
    }
    return .{ .tag = .code_block, .text = try content.toOwnedSlice(self.a), .lang = lang };
}

fn tryBlockQuote(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    if (!startsBlockQuote(line)) return null;

    var inner_lines: std.ArrayList([]const u8) = .empty;
    var paragraph = OpenParagraph{};
    while (self.pos < self.lines.len) {
        const l = self.lines[self.pos];
        if (startsBlockQuote(l)) {
            const inner = stripBlockQuotePrefix(l);
            try inner_lines.append(self.a, inner);
            try paragraph.feed(self.a, inner);
            self.pos += 1;
        } else if (!isBlank(l) and paragraph.open and !self.isClosingFence(l) and
            !try self.isBlockStartAt(self.pos))
        {
            try inner_lines.append(self.a, l);
            try paragraph.feed(self.a, l);
            self.pos += 1;
        } else {
            break;
        }
    }

    const inner_text = try inline_mod.joinLines(self.a, inner_lines.items);
    var inner_parser = Parser.init(self.a, inner_text, self.defs);
    const inner_blocks = try inner_parser.parseBlocks();
    return .{ .tag = .block_quote, .children = inner_blocks };
}

fn tryFencedDiv(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    const div_info = isFencedDivStart(line) orelse return null;
    self.pos += 1;
    const blocks = try self.parseBlocksUntil(div_info.fence);
    var node = Node{ .tag = .div, .children = blocks };
    if (div_info.class) |cls| node.classes = cls;
    return node;
}

const DefinitionLabel = struct { label: []const u8, rest: []const u8, is_footnote: bool };

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
    return .{
        .label = if (is_footnote) label[1..] else label,
        .rest = std.mem.trim(u8, trimmed[close + 3 ..], " \t"),
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
    self.pos += 1;

    var content_lines: std.ArrayList([]const u8) = .empty;
    var paragraph = OpenParagraph{};
    // The first indented line sets the content indent; deeper lines keep the rest, as
    // in a list item (`collectItemContent`).
    var content_indent: ?usize = null;
    if (rest.len > 0) {
        try content_lines.append(self.a, rest);
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
                try paragraph.feed(self.a, "");
                self.pos += 1;
            } else break;
        } else if (l[0] == ' ' or l[0] == '\t') {
            const indent = countIndent(l);
            const strip = @min(indent, content_indent orelse indent);
            if (content_indent == null) content_indent = indent;
            try content_lines.append(self.a, l[strip..]);
            try paragraph.feed(self.a, l[strip..]);
            self.pos += 1;
        } else if (paragraph.open and !try self.isBlockStartAt(self.pos)) {
            // An unindented line continues an open paragraph, as in a list item.
            try content_lines.append(self.a, l);
            try paragraph.feed(self.a, l);
            self.pos += 1;
        } else break;
    }

    if (self.defs.sealed) return {};
    // The footnote's blocks are rendered at the end of the document, so they are
    // parsed with the definitions' allocator rather than the current block's.
    const da = self.defs.a;
    const inner_text = try inline_mod.joinLines(da, content_lines.items);
    var inner_parser = Parser.init(da, inner_text, self.defs);
    const inner_blocks = try inner_parser.parseBlocks();
    try self.defs.footnote_defs.put(da, try da.dupe(u8, label), inner_blocks);
    return {};
}

const ItemContent = struct {
    para_lines: std.ArrayList([]const u8),
    block_lines: std.ArrayList([]const u8),
    item_saw_blank: bool,
    para_orig_lines: std.ArrayList(usize),
    para_col_offsets: std.ArrayList(u32),
};

fn collectItemContent(self: *Parser, content_col: usize, list_indent: usize, first_rest: []const u8) !ItemContent {
    var content = ItemContent{
        .para_lines = .empty,
        .block_lines = .empty,
        .item_saw_blank = false,
        .para_orig_lines = .empty,
        .para_col_offsets = .empty,
    };

    try content.para_lines.append(self.a, first_rest);
    try content.para_orig_lines.append(self.a, self.pos);
    try content.para_col_offsets.append(self.a, @intCast(content_col));
    self.pos += 1;

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
        if (next_indent <= list_indent and try self.isBlockStartAt(self.pos)) break;
        const strip: u32 = if (next_indent >= content_col) @intCast(content_col) else @intCast(next_indent);
        try content.para_lines.append(self.a, next[strip..]);
        try content.para_orig_lines.append(self.a, self.pos);
        try content.para_col_offsets.append(self.a, strip);
        self.pos += 1;
    }

    var paragraph = OpenParagraph{};
    while (self.pos < self.lines.len and content.item_saw_blank) {
        const next = self.lines[self.pos];
        if (isBlank(next)) {
            try content.block_lines.append(self.a, "");
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
            try paragraph.feed(self.a, next[strip..]);
            self.pos += 1;
            continue;
        }
        if (paragraph.open and !(try self.isBlockStartAt(self.pos))) {
            const lazy = std.mem.trimStart(u8, next, " \t");
            try content.block_lines.append(self.a, lazy);
            try paragraph.feed(self.a, lazy);
            self.pos += 1;
            continue;
        }
        break;
    }

    while (content.block_lines.items.len > 0 and isBlank(content.block_lines.items[content.block_lines.items.len - 1])) _ = content.block_lines.pop();

    return content;
}

fn parseItemContent(self: *Parser, content: *const ItemContent) ![]const Node {
    var inner_blocks: std.ArrayList(Node) = .empty;

    const para_text = try inline_mod.joinLines(self.a, content.para_lines.items);
    if (para_text.len > 0) {
        var para_parser = Parser.init(self.a, para_text, self.defs);
        if (self.track_pos and content.para_orig_lines.items.len > 0) {
            para_parser.track_pos = true;
            const first_orig = content.para_orig_lines.items[0];
            const first_col_off = content.para_col_offsets.items[0];
            para_parser.base_line = self.base_line + @as(u32, @intCast(first_orig));
            para_parser.base_offset = self.base_offset +
                (if (first_orig < self.line_offsets.len) self.line_offsets[first_orig] else 0) +
                first_col_off;
            para_parser.col_offsets = content.para_col_offsets.items;
        }
        const blocks = try para_parser.parseBlocks();
        for (blocks) |b| try inner_blocks.append(self.a, b);
    }

    if (content.block_lines.items.len > 0) {
        const block_text = try inline_mod.joinLines(self.a, content.block_lines.items);
        var block_parser = Parser.init(self.a, block_text, self.defs);
        const blocks = try block_parser.parseBlocks();
        for (blocks) |b| try inner_blocks.append(self.a, b);
    }

    return inner_blocks.toOwnedSlice(self.a);
}

fn updateListTightness(is_tight: *bool, saw_blank_between: *bool, content: *const ItemContent, inner_blocks: []const Node) void {
    if (content.item_saw_blank and content.block_lines.items.len > 0) {
        // A blank line before anything but a sublist makes the list loose, as djot.js;
        // a definition, which leaves no block behind, counts as "anything".
        const lead: usize = if (content.para_lines.items.len > 0 and content.para_lines.items[0].len > 0) 1 else 0;
        if (inner_blocks.len <= lead) is_tight.* = false;
        for (inner_blocks[@min(lead, inner_blocks.len)..]) |b| {
            switch (b.tag) {
                .bullet_list, .ordered_list, .task_list => {},
                else => is_tight.* = false,
            }
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

    var items: std.ArrayList(Node) = .empty;
    var is_tight = true;
    var saw_blank_between = false;

    while (self.pos < self.lines.len) {
        const cur = self.lines[self.pos];
        const cur_li = parseBulletMarker(cur) orelse break;
        if (cur_li.indent != list_indent or cur_li.marker != marker_char) break;

        if (saw_blank_between) is_tight = false;
        saw_blank_between = false;

        const item_start_line = self.pos;
        var content = try self.collectItemContent(cur_li.content_col, list_indent, cur_li.rest);

        var is_task = false;
        var task_checked = false;
        if (content.para_lines.items.len > 0) {
            const first_line = content.para_lines.items[0];
            if (std.mem.startsWith(u8, first_line, "[ ] ") or
                std.mem.startsWith(u8, first_line, "[x] ") or
                std.mem.startsWith(u8, first_line, "[X] "))
            {
                is_task = true;
                task_checked = first_line[1] != ' ';
                content.para_lines.items[0] = first_line[4..];
            }
        }

        const inner_blocks = try self.parseItemContent(&content);
        const item_sp = if (self.track_pos) self.makePos(item_start_line, @intCast(list_indent + 1)) else null;
        const item_ep = if (self.track_pos) blk: {
            const ep_col: u32 = if (self.pos >= self.lines.len) 0 else 1;
            break :blk self.makePos(self.pos, ep_col);
        } else null;

        if (is_task) {
            try items.append(self.a, .{ .tag = .task_list_item, .children = inner_blocks, .checked = task_checked, .start_pos = item_sp, .end_pos = item_ep });
        } else {
            try items.append(self.a, .{ .tag = .list_item, .children = inner_blocks, .start_pos = item_sp, .end_pos = item_ep });
        }

        updateListTightness(&is_tight, &saw_blank_between, &content, inner_blocks);
    }

    var has_task = false;
    for (items.items) |item| {
        if (item.tag == .task_list_item) {
            has_task = true;
            break;
        }
    }

    const list_tag: Tag = if (has_task) .task_list else .bullet_list;
    const list_sp = if (self.track_pos) self.makePos(list_start_line, @intCast(list_indent + 1)) else null;
    const list_ep = if (self.track_pos) self.makePos(self.pos, 0) else null;
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
        const content = try self.collectItemContent(cur_ol.content_col, list_indent, cur_ol.rest);
        const inner_blocks = try self.parseItemContent(&content);

        const item_sp = if (self.track_pos) self.makePos(item_start_line, @intCast(list_indent + 1)) else null;
        const item_ep = if (self.track_pos) blk: {
            const ep_col: u32 = if (self.pos >= self.lines.len) 0 else 1;
            break :blk self.makePos(self.pos, ep_col);
        } else null;
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
    const list_ep = if (self.track_pos) self.makePos(self.pos, 0) else null;
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

    var items: std.ArrayList(Node) = .empty;

    while (self.pos < self.lines.len) {
        const cur = self.lines[self.pos];
        const cur_trimmed = std.mem.trimStart(u8, cur, " ");
        if (cur_trimmed.len < 2 or cur_trimmed[0] != ':' or (cur_trimmed[1] != ' ' and cur_trimmed[1] != '\t')) break;

        const marker_indent = @as(usize, @intCast(cur.len - cur_trimmed.len));
        const content_indent = marker_indent + 2;
        const first_content = cur_trimmed[2..];
        self.pos += 1;

        var content_lines: std.ArrayList([]const u8) = .empty;
        var paragraph = OpenParagraph{};
        try content_lines.append(self.a, first_content);
        try paragraph.feed(self.a, first_content);

        while (self.pos < self.lines.len) {
            const next = self.lines[self.pos];
            if (isBlank(next)) {
                self.pos += 1;
                var blanks: usize = 1;
                while (self.pos < self.lines.len and isBlank(self.lines[self.pos])) {
                    self.pos += 1;
                    blanks += 1;
                }
                if (self.pos >= self.lines.len) break;
                const peek = self.lines[self.pos];
                if (countIndent(peek) >= content_indent) {
                    var b: usize = 0;
                    while (b < blanks) : (b += 1) {
                        try content_lines.append(self.a, "");
                        try paragraph.feed(self.a, "");
                    }
                    continue;
                }
                break;
            }
            const ni = countIndent(next);
            if (ni >= content_indent) {
                try content_lines.append(self.a, next[content_indent..]);
                try paragraph.feed(self.a, next[content_indent..]);
                self.pos += 1;
            } else if ((ni > marker_indent and ni < content_indent) or
                (paragraph.open and !try self.isBlockStartAt(self.pos)))
            {
                // Under-indented lines, and unindented ones while a paragraph (the
                // term, or a definition's paragraph) is open, continue it lazily.
                const lazy = std.mem.trimStart(u8, next, " \t");
                try content_lines.append(self.a, lazy);
                try paragraph.feed(self.a, lazy);
                self.pos += 1;
            } else {
                break;
            }
        }

        const content_text = try inline_mod.joinLines(self.a, content_lines.items);
        var inner_parser = Parser.init(self.a, content_text, self.defs);
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
        try items.append(self.a, .{ .tag = .definition_list_item, .children = try item_children.toOwnedSlice(self.a) });
    }

    if (items.items.len == 0) return null;
    return .{ .tag = .definition_list, .children = try items.toOwnedSlice(self.a) };
}

fn tryTable(self: *Parser) !?Node {
    const line = self.lines[self.pos];
    if (!isTableRow(line)) return null;

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
        const cells = try self.parseTableRowWithAlign(r, effective_aligns, is_head_row.items[idx]);
        try rows.append(self.a, .{ .tag = .row, .children = cells });
    }

    var cap_lines: std.ArrayList([]const u8) = .empty;
    while (self.pos < self.lines.len) {
        var look = self.pos;
        while (look < self.lines.len and isBlank(self.lines[look])) : (look += 1) {}
        if (look >= self.lines.len) break;
        const t = std.mem.trimStart(u8, self.lines[look], " \t");
        if (t.len > 1 and t[0] == '^' and t[1] == ' ') {
            cap_lines.items.len = 0;
            self.pos = look;
            try cap_lines.append(self.a, std.mem.trim(u8, t[2..], " \t"));
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

    var table_children: std.ArrayList(Node) = .empty;
    if (cap_lines.items.len > 0) {
        const cap_inlines = try inline_mod.parseInlines(self.a, cap_lines.items);
        try table_children.append(self.a, .{ .tag = .caption, .children = cap_inlines });
    }
    for (rows.items) |r| try table_children.append(self.a, r);

    return .{ .tag = .table, .children = try table_children.toOwnedSlice(self.a) };
}

fn parseTableRowWithAlign(self: *Parser, line: []const u8, col_aligns: []const CellAlign, is_head: bool) ![]const Node {
    var cells: std.ArrayList(Node) = .empty;
    const trimmed = std.mem.trim(u8, line, " \t");
    var content = trimmed;
    if (content.len > 0 and content[0] == '|') content = content[1..];
    if (content.len > 0 and content[content.len - 1] == '|') content = content[0 .. content.len - 1];

    const cell_strs = try splitTableCells(self.a, content);
    for (cell_strs, 0..) |cell, col| {
        const cell_text = std.mem.trim(u8, cell, " \t");
        const inlines = try inline_mod.parseInlines(self.a, &.{cell_text});
        var node = Node{ .tag = .cell, .children = inlines, .head = is_head };
        if (col < col_aligns.len) node.cell_align = col_aligns[col];
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
            parseOrderedMarker(line) != null or attrs_mod.tryParseBlockAttr(a, line) != null;
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

fn isTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 1 or trimmed[0] != '|') return false;
    var pipes: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == '\\' and i + 1 < trimmed.len) {
            i += 2;
        } else if (trimmed[i] == '`') {
            i = skipBacktickSpan(trimmed, i);
        } else {
            if (trimmed[i] == '|') pipes += 1;
            i += 1;
        }
    }
    return pipes >= 2;
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
    try std.testing.expectEqualStrings("note", note[0].children[0].text);
}
