//! The block parser as a container stack, the shape of djot.js's `block.js`: one pass over
//! the lines. Each line is run against the open containers from the outermost in
//! (`continues`), then against the block starts while the innermost matched container
//! holds blocks (`tryOpen`); what remains is lazy text for an open paragraph or heading, a
//! blank line, or text for the innermost container. A container closes when a line neither
//! continues it nor is lazy text for it, and its `Node` ends where the parser stands;
//! `nextBlock` returns each top-level block's tree as it closes. Built beside `Parser.zig`
//! behind `-Dparser=stack`; so far: paragraphs, headings, thematic breaks, block attributes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const SourcePos = node_mod.SourcePos;
const attrs_mod = @import("attributes.zig");
const BlockAttrs = attrs_mod.BlockAttrs;
const inline_mod = @import("inline.zig");
const LineMap = @import("LineMap.zig");
const leaf = @import("leaf.zig");
const Definitions = @import("document.zig").Definitions;
const lines_mod = @import("Lines.zig");
const Lines = lines_mod.Lines;
const Line = lines_mod.Line;

const Block = @This();

pub const Error = Allocator.Error || error{ReadFailed};

/// The nodes of the block being built; the consumer sets it per block.
a: Allocator,
/// The parser's own state across blocks: the stack and its buffers. An arena the
/// consumer keeps for the document; nothing is freed before it.
da: Allocator,
defs: *Definitions,
track_pos: bool = false,
lines: Lines,
stack: std.ArrayList(Container) = .empty,
/// Block attributes waiting for the next top-level block.
pending_attrs: ?BlockAttrs = null,
/// The lines of the open leaf, which is always the tip, so one set of buffers serves.
leaf_slices: std.ArrayList([]const u8) = .empty,
leaf_starts: std.ArrayList(SourcePos) = .empty,
/// The newline of the open leaf's last line, where its `LineMap` ends.
leaf_last_eol: SourcePos = undefined,
/// Copies of an unstable source's lines for the open leaf; reset when it closes.
copies: std.heap.ArenaAllocator,
/// Children lists of closed containers, reused by the next ones pushed.
spare_lists: std.ArrayList(std.ArrayList(Node)) = .empty,
/// The top-level block the current line closed, for `nextBlock` to return.
done: ?Node = null,
/// Lines consumed, and the line the last top-level block ended on.
line_count: u32 = 0,
last_block_line: u32 = 0,

const Kind = enum { para, heading, thematic_break, attributes };

/// What a container holds: blocks, inline content, nothing, or attribute text.
const Content = enum { block, inlines, none, attributes };

const Container = struct {
    start: SourcePos,
    children: std.ArrayList(Node),
    /// Block attributes waiting for this container's next child block.
    pending_attrs: ?BlockAttrs = null,
    /// For a leaf: one past the last non-blank character of its last line (djot.js ends
    /// paragraphs and headings there, trailing whitespace excluded).
    leaf_end: SourcePos = undefined,
    data: union(Kind) {
        /// `attrs_from`: no inline attribute is read before this joined offset (a failed
        /// block attribute's first line is text, as djot.js reparses it).
        para: struct { attrs_from: usize = 0 },
        heading: struct { level: u8 },
        thematic_break: struct { end: SourcePos },
        /// `attrs`: parsed when the lines so far form a complete block attribute.
        attributes: struct { indent: usize, attrs: ?BlockAttrs = null },
    },

    fn content(self: Container) Content {
        return switch (self.data) {
            .para, .heading => .inlines,
            .thematic_break => .none,
            .attributes => .attributes,
        };
    }
};

/// Where the parser stands when a container closes.
const Stand = struct {
    /// The current position: the next block's content, or a blank line's newline.
    pos: SourcePos,
    /// The first byte of the current line (its newline when it is empty), where a block
    /// ending in a hard break ends; the input's end at the end.
    line_first: SourcePos,
    eof: bool = false,
};

/// A position on the current line.
const Cursor = struct {
    line: Line,
    i: usize = 0,
    /// Columns before `i` after `skipSpace`, as djot.js's `indent`.
    indent: usize = 0,

    fn skipSpace(self: *Cursor) void {
        const b = self.line.bytes;
        while (self.i < b.len and (b[self.i] == ' ' or b[self.i] == '\t')) self.i += 1;
        self.indent = self.i;
    }

    fn rest(self: Cursor) []const u8 {
        return self.line.bytes[self.i..];
    }

    fn atEol(self: Cursor) bool {
        return self.i >= self.line.bytes.len;
    }

    fn pos(self: Cursor) SourcePos {
        if (self.atEol()) return self.line.eol;
        return .{ .line = self.line.pos.line, .col = @intCast(self.i + 1), .offset = self.line.pos.offset + @as(u32, @intCast(self.i)) };
    }

    fn lineFirst(self: Cursor) SourcePos {
        return if (self.line.bytes.len == 0) self.line.eol else self.line.pos;
    }
};

pub fn init(da: Allocator, input: []const u8, defs: *Definitions) Allocator.Error!Block {
    return .{ .a = da, .da = da, .defs = defs, .lines = Lines.fromSlice(input), .copies = .init(da) };
}

/// Where the input ended; meaningful once `nextBlock` has returned null.
pub fn endPos(self: *const Block) SourcePos {
    return self.lines.end();
}

/// Whether lines followed the last top-level block (blank lines, definitions,
/// attributes), which carry djot.js's events to the input's end.
pub fn trailing(self: *const Block) bool {
    return self.line_count > self.last_block_line;
}

/// The next top-level block, or null at the end of the input. Definitions are recorded
/// in `defs` as they close and never returned.
pub fn nextBlock(self: *Block) Error!?Node {
    while (self.done == null) {
        const line = (try self.lines.next()) orelse {
            if (self.stack.items.len == 0) return null;
            const end = self.lines.end();
            try self.closeFrom(0, .{ .pos = end, .line_first = end, .eof = true });
            break;
        };
        self.line_count += 1;
        try self.parseLine(line);
    }
    defer self.done = null;
    return self.done;
}

fn tip(self: *Block) *Container {
    return &self.stack.items[self.stack.items.len - 1];
}

/// Whether the container at depth `n` (none when `n` is 0) holds blocks, so block
/// starts are tried after it.
fn holdsBlocks(self: *const Block, n: usize) bool {
    return n == 0 or self.stack.items[n - 1].content() == .block;
}

fn parseLine(self: *Block, line: Line) Error!void {
    var cur = Cursor{ .line = line };
    // Open containers continue from the outermost in; the first that does not ends it.
    var matched: usize = 0;
    for (self.stack.items) |*c| {
        cur.skipSpace();
        if (!try self.continues(c, &cur)) break;
        matched += 1;
    }
    // New containers open while the innermost matched one holds blocks.
    cur.skipSpace();
    var new_starts = false;
    while (!cur.atEol() and self.holdsBlocks(matched)) {
        if (!try self.tryOpen(&cur, matched)) break;
        matched = self.stack.items.len;
        new_starts = true;
        cur.skipSpace();
    }
    // The rest of the line: lazy text continues an open paragraph or heading that no
    // longer matched, when nothing opened and the line is not blank; otherwise the
    // containers that did not match close here.
    cur.skipSpace();
    const blank = cur.atEol();
    const lazy = !blank and !new_starts and matched < self.stack.items.len and self.tip().content() == .inlines;
    if (!lazy) try self.closeFrom(matched, .{ .pos = cur.pos(), .line_first = cur.lineFirst() });
    if (self.holdsBlocks(self.stack.items.len)) {
        if (blank) {
            if (!new_starts) self.blankLine();
        } else {
            try self.push(.{ .para = .{} }, cur.pos());
        }
    }
    if (self.stack.items.len > 0 and self.tip().content() == .inlines and !blank) try self.addLeafLine(cur);
}

/// Whether the line at `cur` continues `c`, moving `cur` past the prefix it consumes.
fn continues(self: *Block, c: *Container, cur: *Cursor) Error!bool {
    switch (c.data) {
        .para => return !cur.atEol(),
        .heading => |h| {
            const r = cur.rest();
            const hashes = leaf.countLeadingChar(r, '#');
            if (hashes != h.level or (hashes < r.len and r[hashes] != ' ' and r[hashes] != '\t')) return false;
            cur.i += hashes;
            c.leaf_end = afterContent(cur.line);
            return true;
        },
        .thematic_break => return false,
        .attributes => |*at| {
            if (at.attrs != null) return false;
            // Lines indented past the opener keep the attribute going until it parses.
            if (!cur.atEol() and cur.indent > at.indent) {
                try self.addLeafSlice(std.mem.trim(u8, cur.rest(), " \t"), cur.pos(), cur.line);
                c.leaf_end = afterContent(cur.line);
                at.attrs = try attrs_mod.parseAttrsFromStr(self.a, try inline_mod.joinLines(self.a, self.leaf_slices.items));
                cur.i = cur.line.bytes.len;
                return true;
            }
            // It never parsed: its lines are a paragraph, the first read without inline
            // attributes when it opened one, and this line continues it or not as a
            // paragraph's would.
            const first = self.leaf_slices.items[0];
            c.data = .{ .para = .{ .attrs_from = if (try attrs_mod.opensAttr(self.a, first)) first.len else 0 } };
            return !cur.atEol();
        },
    }
}

/// Tries the block starts at `cur`, in djot.js's order; on one, closes the containers
/// above `matched`, pushes the new one and moves `cur` past its marker.
fn tryOpen(self: *Block, cur: *Cursor, matched: usize) Error!bool {
    const r = cur.rest();
    const stand = Stand{ .pos = cur.pos(), .line_first = cur.lineFirst() };
    if (leaf.headingLevel(r)) |level| {
        try self.closeFrom(matched, stand);
        try self.push(.{ .heading = .{ .level = @intCast(level) } }, cur.pos());
        self.tip().leaf_end = afterContent(cur.line);
        cur.i += level;
        return true;
    }
    if (leaf.isThematicBreak(r)) {
        try self.closeFrom(matched, stand);
        try self.push(.{ .thematic_break = .{ .end = cur.line.eol } }, cur.pos());
        cur.i = cur.line.bytes.len;
        return true;
    }
    if (r[0] == '{') {
        try self.closeFrom(matched, stand);
        try self.push(.{ .attributes = .{ .indent = cur.indent } }, cur.pos());
        const text = std.mem.trimEnd(u8, r, " \t");
        try self.addLeafSlice(text, cur.pos(), cur.line);
        self.tip().leaf_end = afterContent(cur.line);
        // Complete on one line, or kept open for the indented lines that may follow.
        if (text[text.len - 1] == '}') self.tip().data.attributes.attrs = try attrs_mod.parseAttrsFromStr(self.a, text);
        cur.i = cur.line.bytes.len;
        return true;
    }
    return false;
}

fn push(self: *Block, data: @FieldType(Container, "data"), start: SourcePos) Error!void {
    try self.stack.append(self.da, .{
        .start = start,
        .children = self.spare_lists.pop() orelse .empty,
        .data = data,
    });
}

/// The rest of the line at `cur` as the open leaf's next line.
fn addLeafLine(self: *Block, cur: Cursor) Error!void {
    const text = switch (self.tip().data) {
        .heading => std.mem.trimEnd(u8, cur.rest(), " \t"),
        else => cur.rest(),
    };
    try self.addLeafSlice(text, cur.pos(), cur.line);
    self.tip().leaf_end = afterContent(cur.line);
}

fn addLeafSlice(self: *Block, text: []const u8, start: SourcePos, line: Line) Error!void {
    const slice = if (self.lines.stable()) text else try self.copies.allocator().dupe(u8, text);
    try self.leaf_slices.append(self.da, slice);
    try self.leaf_starts.append(self.da, start);
    self.leaf_last_eol = line.eol;
}

/// Where the open leaf's inline content is read from: `joined_start` of each line in the
/// text `joinLines` makes, and the position it came from.
fn leafLineMap(self: *Block) Error!LineMap {
    const segs = try self.a.alloc(LineMap.Segment, self.leaf_slices.items.len);
    var joined: u32 = 0;
    for (self.leaf_slices.items, self.leaf_starts.items, segs) |slice, start, *seg| {
        seg.* = .{ .joined_start = joined, .orig_line = start.line, .orig_col = start.col, .orig_offset = start.offset };
        joined += @intCast(slice.len + 1);
    }
    return .{ .segments = segs, .total = joined - 1, .end = self.leaf_last_eol };
}

/// The inline content of the open leaf, which empties the leaf buffers.
fn leafInlines(self: *Block, attrs_from: usize) Error![]const Node {
    defer {
        self.leaf_slices.clearRetainingCapacity();
        self.leaf_starts.clearRetainingCapacity();
        _ = self.copies.reset(.retain_capacity);
    }
    const src = try inline_mod.joinLines(self.a, self.leaf_slices.items);
    if (src.len == 0) return &.{};
    const map: ?LineMap = if (self.track_pos) try self.leafLineMap() else null;
    return inline_mod.parseInlineContent(self.a, src, map, attrs_from);
}

/// One past the last non-blank character of `line`: its newline unless whitespace trails.
fn afterContent(line: Line) SourcePos {
    const content: u32 = @intCast(std.mem.trimEnd(u8, line.bytes, " \t").len);
    if (content == line.bytes.len) return line.eol;
    return .{ .line = line.pos.line, .col = content + 1, .offset = line.pos.offset + content };
}

/// Where a paragraph or heading ends, as djot.js: after its last non-blank character, or
/// one past a hard break that ends it.
fn leafEnd(c: Container, children: []const Node, stand: Stand) SourcePos {
    if (children.len > 0 and children[children.len - 1].tag == .hard_break) return stand.line_first;
    return c.leaf_end;
}

/// A blank line: block attributes do not survive one (see the `zjot.test` header).
fn blankLine(self: *Block) void {
    if (self.stack.items.len > 0) self.tip().pending_attrs = null else self.pending_attrs = null;
}

/// Closes the containers from depth `from` up, innermost first.
fn closeFrom(self: *Block, from: usize, stand: Stand) Error!void {
    while (self.stack.items.len > from) try self.close(stand);
}

/// Closes the tip: its node, ending where the parser stands, joins its parent's
/// children, or is the top-level block `nextBlock` returns.
fn close(self: *Block, stand: Stand) Error!void {
    var c = self.stack.pop().?;
    defer {
        c.children.clearRetainingCapacity();
        self.spare_lists.append(self.da, c.children) catch {}; // a spare list is only a saving
    }
    const node: Node = switch (c.data) {
        .para => |p| try self.leafNode(c, .para, p.attrs_from, stand),
        .heading => |h| blk: {
            var n = try self.leafNode(c, .heading, 0, stand);
            n.level = h.level;
            break :blk n;
        },
        .thematic_break => |tb| .{
            .tag = .thematic_break,
            .start_pos = if (self.track_pos) c.start else null,
            .end_pos = if (self.track_pos) tb.end else null,
        },
        .attributes => |at| {
            if (at.attrs) |attrs| {
                // Waits for the next block in the container it was written in.
                const slot = if (self.stack.items.len > 0) &self.tip().pending_attrs else &self.pending_attrs;
                slot.* = if (slot.*) |existing| try existing.merge(attrs, self.a) else attrs;
                self.leaf_slices.clearRetainingCapacity();
                self.leaf_starts.clearRetainingCapacity();
                _ = self.copies.reset(.retain_capacity);
                return;
            }
            // Never completed: its lines are a paragraph (djot.js reparses them).
            const first = self.leaf_slices.items[0];
            const attrs_from: usize = if (try attrs_mod.opensAttr(self.a, first)) first.len else 0;
            return self.closeAs(try self.leafNode(c, .para, attrs_from, stand), stand);
        },
    };
    try self.closeAs(node, stand);
}

fn leafNode(self: *Block, c: Container, tag: node_mod.Tag, attrs_from: usize, stand: Stand) Error!Node {
    const children = try self.leafInlines(attrs_from);
    return .{
        .tag = tag,
        .children = children,
        .start_pos = if (self.track_pos) c.start else null,
        .end_pos = if (self.track_pos) leafEnd(c, children, stand) else null,
    };
}

/// `node`, with the block attributes waiting for it, joins its parent or is done.
fn closeAs(self: *Block, node: Node, stand: Stand) Error!void {
    if (self.stack.items.len > 0) {
        const parent = self.tip();
        const n = if (parent.pending_attrs) |ba| try inline_mod.applyBlockAttrsToNode(self.a, node, ba) else node;
        parent.pending_attrs = null;
        try parent.children.append(self.da, n);
    } else {
        const n = if (self.pending_attrs) |ba| try inline_mod.applyBlockAttrsToNode(self.a, node, ba) else node;
        self.pending_attrs = null;
        self.done = n;
        // The block ended on the line before the one that closed it, or on the last.
        self.last_block_line = if (stand.eof) self.line_count else self.line_count - 1;
    }
}
