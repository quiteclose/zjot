//! The block parser as a container stack, the shape of djot.js's `block.js`: one pass over
//! the lines. Each line is run against the open containers from the outermost in
//! (`continues`), then against the block starts while the innermost matched container
//! holds blocks (`tryOpen`); what remains is lazy text for an open paragraph or heading, a
//! blank line, or text for the innermost container. A container closes when a line neither
//! continues it nor is lazy text for it, and its `Node` ends where the parser stands;
//! `nextBlock` returns each top-level block's tree as it closes. Built beside `Parser.zig`
//! behind `-Dparser=stack`; so far: paragraphs, headings, thematic breaks, block
//! attributes, block quotes, lists, definition lists, fenced divs, footnotes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const Attr = node_mod.Attr;
const SourcePos = node_mod.SourcePos;
const attrs_mod = @import("attributes.zig");
const BlockAttrs = attrs_mod.BlockAttrs;
const inline_mod = @import("inline.zig");
const LineMap = @import("LineMap.zig");
const leaf = @import("leaf.zig");
const document = @import("document.zig");
const Definitions = document.Definitions;
const FootnoteDef = document.FootnoteDef;
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
/// Open footnotes: their content is allocated for the document, not the block.
footnote_depth: usize = 0,
/// Set by a start or continuation that took the whole line (a fence): nothing else
/// on it is read.
finished_line: bool = false,
/// The top-level block the current line closed, for `nextBlock` to return.
done: ?Node = null,
/// Lines consumed, and the line the last top-level block ended on.
line_count: u32 = 0,
last_block_line: u32 = 0,

const Kind = enum { para, heading, thematic_break, attributes, block_quote, list, list_item, footnote, div };

/// What a container holds: blocks, list items, inline content, nothing, or attribute text.
const Content = enum { block, items, inlines, none, attributes };

/// What a list's items share, read off their markers (djot.js's list styles).
const ListStyle = union(enum) {
    bullet: u8,
    task,
    definition,
    ordered: struct { styles: leaf.OrderedStyles, delim: leaf.Delim },
};

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
        block_quote: void,
        /// `blanklines` and `tight` as `parse.js` keeps them: a blank line marks the list
        /// and the next event that is not a blank line, a list start or a list or item end
        /// makes it loose.
        list: struct { style: ListStyle, indent: usize, marker: [32]u8, marker_len: u8, blanklines: bool = false, tight: bool = true },
        list_item: struct { indent: usize, checked: ?bool },
        footnote: struct { label: []const u8, indent: usize, headings_before: usize },
        /// `end`: the closing fence's last colon, once met.
        div: struct { fence_len: usize, class: ?[]const u8, end: ?SourcePos = null },
    },

    fn content(self: Container) Content {
        return switch (self.data) {
            .para, .heading => .inlines,
            .thematic_break => .none,
            .attributes => .attributes,
            .block_quote, .list_item, .footnote, .div => .block,
            .list => .items,
        };
    }

    fn isList(self: Container) bool {
        return self.data == .list;
    }
};

/// Where the parser stands when a container closes.
const Stand = struct {
    /// The current position: the next block's content, or a blank line's newline.
    pos: SourcePos,
    /// One position before `pos` (djot.js ends list items there); `pos` itself at the end.
    before: SourcePos,
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
        return self.at(self.i);
    }

    /// The position of byte `i` of the line.
    fn at(self: Cursor, i: usize) SourcePos {
        return .{ .line = self.line.pos.line, .col = @intCast(i + 1), .offset = self.line.pos.offset + @as(u32, @intCast(i)) };
    }

    /// One position before `pos`: the byte before it, or col 0 (the previous line's
    /// newline) at the line's start.
    fn before(self: Cursor) SourcePos {
        if (self.i == 0) return .{ .line = self.line.pos.line, .col = 0, .offset = self.line.pos.offset -| 1 };
        return self.at(self.i - 1);
    }

    fn stand(self: Cursor) Stand {
        return .{ .pos = self.pos(), .before = self.before(), .line_first = if (self.line.bytes.len == 0) self.line.eol else self.line.pos };
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
            try self.closeFrom(0, .{ .pos = end, .before = end, .line_first = end, .eof = true });
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

/// The allocator for nodes: the document's inside a footnote, whose content outlives
/// the block, else the block's.
fn nodeAllocator(self: *const Block) Allocator {
    return if (self.footnote_depth > 0) self.defs.a else self.a;
}

/// Whether the container at depth `n` (none when `n` is 0) holds blocks or items, so
/// starts are tried after it.
fn holdsBlocks(self: *const Block, n: usize) bool {
    if (n == 0) return true;
    return switch (self.stack.items[n - 1].content()) {
        .block, .items => true,
        else => false,
    };
}

fn parseLine(self: *Block, line: Line) Error!void {
    var cur = Cursor{ .line = line };
    self.finished_line = false;
    // Open containers continue from the outermost in; the first that does not ends it.
    var matched: usize = 0;
    for (self.stack.items) |*c| {
        cur.skipSpace();
        if (!try self.continues(c, &cur)) break;
        matched += 1;
    }
    if (self.finished_line) {
        // A closing code fence: the containers above its block close, and the line is done.
        return self.closeFrom(matched, cur.stand());
    }
    // New containers open while the innermost matched one holds blocks or items.
    cur.skipSpace();
    var new_starts = false;
    while (!cur.atEol() and self.holdsBlocks(matched)) {
        if (!try self.tryOpen(&cur, matched)) break;
        matched = self.stack.items.len;
        new_starts = true;
        if (self.finished_line) return;
        cur.skipSpace();
    }
    // The rest of the line: lazy text continues an open paragraph or heading that no
    // longer matched, when nothing opened and the line is not blank; otherwise the
    // containers that did not match close here.
    cur.skipSpace();
    const blank = cur.atEol();
    const lazy = !blank and !new_starts and matched < self.stack.items.len and self.tip().content() == .inlines;
    if (!lazy) try self.closeFrom(matched, cur.stand());
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
        .block_quote => {
            if (!leaf.startsBlockQuote(cur.rest())) return false;
            cur.i += 1;
            return true;
        },
        .list => |*l| {
            if (cur.atEol() or cur.indent > l.indent) return true;
            // A marker of the list's style continues it, whatever its indent (djot.js),
            // narrowing an ordered list's possible styles.
            const m = listMarker(cur.rest()) orelse return false;
            return switch (l.style) {
                .bullet => |ch| m.style == .bullet and m.style.bullet == ch,
                .task => m.style == .task,
                .definition => m.style == .definition,
                .ordered => |*o| m.style == .ordered and m.style.ordered.delim == o.delim and o.styles.accept(m.ordered.?, false),
            };
        },
        .list_item => |it| return cur.atEol() or cur.indent > it.indent,
        .footnote => |f| return cur.atEol() or cur.indent > f.indent,
        .div => |*dv| {
            // A bare fence of at least as many colons closes the div, ending it on its
            // last colon; the rest of the line is blank.
            const r = cur.rest();
            if (leaf.countLeadingChar(r, ':') >= dv.fence_len and leaf.isBlank(std.mem.trimStart(u8, r, ":"))) {
                dv.end = cur.at(cur.i + leaf.countLeadingChar(r, ':') - 1);
                cur.i = cur.line.bytes.len;
                return false;
            }
            return true;
        },
    }
}

/// A list marker at the start of a line's content: the style it gives the list, how many
/// bytes it and the space after it take, and a task item's state.
const Marker = struct {
    style: ListStyle,
    advance: usize,
    checked: ?bool = null,
    /// An ordered marker's text, for the list's start number.
    text: []const u8 = "",
    ordered: ?leaf.Marker = null,
};

fn listMarker(r: []const u8) ?Marker {
    if (leaf.parseBulletMarker(r)) |m| {
        if (leaf.isTaskItem(m.rest)) return .{ .style = .task, .advance = r.len - m.rest.len + 3, .checked = m.rest[1] != ' ' };
        return .{ .style = .{ .bullet = m.bullet }, .advance = r.len - m.rest.len };
    }
    if (r.len >= 1 and r[0] == ':' and (r.len == 1 or r[1] == ' ' or r[1] == '\t')) return .{ .style = .definition, .advance = @min(2, r.len) };
    if (leaf.parseOrderedMarker(r)) |m| return .{
        .style = .{ .ordered = .{ .styles = .{ .possible = m.styles, .n = m.n_styles }, .delim = m.delim } },
        .advance = r.len - m.rest.len,
        .text = m.marker_text,
        .ordered = m,
    };
    return null;
}

/// Tries the block starts at `cur`, in djot.js's order; on one, closes the containers
/// above `matched`, pushes the new one and moves `cur` past its marker. After a list,
/// only its item can open.
fn tryOpen(self: *Block, cur: *Cursor, matched: usize) Error!bool {
    const r = cur.rest();
    const stand = cur.stand();
    if (matched > 0 and self.stack.items[matched - 1].content() == .items) {
        const m = listMarker(r).?; // the list opened on, or continued by, this marker
        try self.closeFrom(matched, stand);
        try self.push(.{ .list_item = .{ .indent = cur.indent, .checked = m.checked } }, cur.pos());
        cur.i += m.advance;
        return true;
    }
    if (leaf.startsBlockQuote(r)) {
        try self.closeFrom(matched, stand);
        try self.push(.block_quote, cur.pos());
        cur.i += 1;
        return true;
    }
    if (leaf.headingLevel(r)) |level| {
        try self.closeFrom(matched, stand);
        try self.push(.{ .heading = .{ .level = @intCast(level) } }, cur.pos());
        self.tip().leaf_end = afterContent(cur.line);
        cur.i += level;
        return true;
    }
    if (leaf.definitionLabel(r)) |def| if (def.is_footnote and (r.len == def.rest_col or r[def.rest_col - 1] == ' ' or r[def.rest_col - 1] == '\t')) {
        try self.closeFrom(matched, stand);
        try self.push(.{ .footnote = .{
            .label = try self.defs.a.dupe(u8, def.label),
            .indent = cur.indent,
            .headings_before = self.defs.headings_parsed,
        } }, cur.pos());
        self.footnote_depth += 1;
        cur.i += def.rest_col;
        return true;
    };
    if (leaf.isThematicBreak(r)) {
        try self.closeFrom(matched, stand);
        try self.push(.{ .thematic_break = .{ .end = cur.line.eol } }, cur.pos());
        cur.i = cur.line.bytes.len;
        return true;
    }
    if (listMarker(r)) |m| {
        try self.closeFrom(matched, stand);
        var list: @FieldType(@FieldType(Container, "data"), "list") = .{ .style = m.style, .indent = cur.indent, .marker = undefined, .marker_len = 0 };
        if (m.text.len <= list.marker.len) {
            @memcpy(list.marker[0..m.text.len], m.text);
            list.marker_len = @intCast(m.text.len);
        }
        try self.push(.{ .list = list }, cur.pos());
        return true; // the item opens on the same marker next
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
    if (leaf.isFencedDivStart(r)) |dv| if (divClass(dv.class)) {
        try self.closeFrom(matched, stand);
        try self.push(.{ .div = .{
            .fence_len = dv.fence.len,
            .class = if (dv.class) |cls| try self.nodeAllocator().dupe(u8, cls) else null,
        } }, cur.pos());
        cur.i = cur.line.bytes.len;
        self.finished_line = true;
        return true;
    };
    return false;
}

/// A div opener's class is one word, as djot.js (`[\w_-]*` to the end of the line).
fn divClass(class: ?[]const u8) bool {
    for (class orelse return true) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

fn push(self: *Block, data: @FieldType(Container, "data"), start: SourcePos) Error!void {
    self.listEvent(data == .list, data == .list_item);
    try self.stack.append(self.da, .{
        .start = start,
        .children = self.spare_lists.pop() orelse .empty,
        .data = data,
    });
}

/// The innermost list a tightness event reaches: the tip, or the list the tip's item is
/// in (`parse.js` looks no deeper).
fn listNode(self: *Block) ?*Container {
    const n = self.stack.items.len;
    if (n > 0 and self.stack.items[n - 1].isList()) return &self.stack.items[n - 1];
    if (n > 1 and self.stack.items[n - 2].isList()) return &self.stack.items[n - 2];
    return null;
}

/// `parse.js`'s rule on every event but a blank line: after blank lines, anything but a
/// list start or a list or item end makes the list loose, and anything but an item
/// boundary clears the blank lines seen.
fn listEvent(self: *Block, is_list: bool, is_item: bool) void {
    const ln = self.listNode() orelse return;
    const l = &ln.data.list;
    if (!is_list and !is_item and l.blanklines) l.tight = false;
    if (!is_item) l.blanklines = false;
}

/// A blank line: it marks the innermost list for tightness, and block attributes do not
/// survive one (see the `zjot.test` header).
fn blankLine(self: *Block) void {
    if (self.listNode()) |ln| ln.data.list.blanklines = true;
    if (self.stack.items.len > 0) self.tip().pending_attrs = null else self.pending_attrs = null;
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
fn leafLineMap(self: *Block, a: Allocator) Error!LineMap {
    const segs = try a.alloc(LineMap.Segment, self.leaf_slices.items.len);
    var joined: u32 = 0;
    for (self.leaf_slices.items, self.leaf_starts.items, segs) |slice, start, *seg| {
        seg.* = .{ .joined_start = joined, .orig_line = start.line, .orig_col = start.col, .orig_offset = start.offset };
        joined += @intCast(slice.len + 1);
    }
    return .{ .segments = segs, .total = joined - 1, .end = self.leaf_last_eol };
}

/// The inline content of the open leaf, which empties the leaf buffers.
fn leafInlines(self: *Block, attrs_from: usize) Error![]const Node {
    defer self.dropLeaf();
    const a = self.nodeAllocator();
    const src = try inline_mod.joinLines(a, self.leaf_slices.items);
    if (src.len == 0) return &.{};
    const map: ?LineMap = if (self.track_pos) try self.leafLineMap(a) else null;
    return inline_mod.parseInlineContent(a, src, map, attrs_from);
}

fn dropLeaf(self: *Block) void {
    self.leaf_slices.clearRetainingCapacity();
    self.leaf_starts.clearRetainingCapacity();
    _ = self.copies.reset(.retain_capacity);
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

/// Closes the containers from depth `from` up, innermost first.
fn closeFrom(self: *Block, from: usize, stand: Stand) Error!void {
    while (self.stack.items.len > from) try self.close(stand);
}

/// Closes the tip: its node, ending where the parser stands, joins its parent's
/// children, or is the top-level block `nextBlock` returns; a footnote is recorded.
fn close(self: *Block, stand: Stand) Error!void {
    self.listEvent(self.tip().isList(), self.tip().data == .list_item);
    var c = self.stack.pop().?;
    defer {
        c.children.clearRetainingCapacity();
        self.spare_lists.append(self.da, c.children) catch {}; // a spare list is only a saving
    }
    const a = self.nodeAllocator();
    const pos = self.track_pos;
    const node: Node = switch (c.data) {
        .para => |p| try self.leafNode(c, .para, p.attrs_from, stand),
        .heading => |h| blk: {
            var n = try self.leafNode(c, .heading, 0, stand);
            n.level = h.level;
            self.defs.headings_parsed += 1;
            break :blk n;
        },
        .thematic_break => |tb| .{
            .tag = .thematic_break,
            .start_pos = if (pos) c.start else null,
            .end_pos = if (pos) tb.end else null,
        },
        .attributes => |at| {
            if (at.attrs) |attrs| {
                // Waits for the next block in the container it was written in.
                const slot = if (self.stack.items.len > 0) &self.tip().pending_attrs else &self.pending_attrs;
                slot.* = if (slot.*) |existing| try existing.merge(attrs, self.a) else attrs;
                self.dropLeaf();
                return;
            }
            // Never completed: its lines are a paragraph (djot.js reparses them).
            const first = self.leaf_slices.items[0];
            const attrs_from: usize = if (try attrs_mod.opensAttr(self.a, first)) first.len else 0;
            return self.closeAs(try self.leafNode(c, .para, attrs_from, stand), stand);
        },
        .block_quote => .{
            .tag = .block_quote,
            .children = try a.dupe(Node, c.children.items),
            .start_pos = if (pos) c.start else null,
            .end_pos = if (pos) stand.pos else null,
        },
        .list => |l| blk: {
            var n = Node{
                .tag = switch (l.style) {
                    .bullet => .bullet_list,
                    .task => .task_list,
                    .definition => .definition_list,
                    .ordered => .ordered_list,
                },
                .children = try a.dupe(Node, c.children.items),
                .tight = l.tight,
                .start_pos = if (pos) c.start else null,
                .end_pos = if (pos) stand.pos else null,
            };
            switch (l.style) {
                .bullet => |ch| n.style = switch (ch) {
                    '+' => "+",
                    '*' => "*",
                    else => "-",
                },
                .ordered => |o| {
                    n.list_style = o.styles.possible[0] orelse .decimal;
                    n.start = leaf.getListStart(l.marker[0..l.marker_len], n.list_style.?);
                },
                else => {},
            }
            break :blk n;
        },
        .list_item => |it| blk: {
            const in_definition_list = self.tip().data.list.style == .definition;
            var n = Node{
                .tag = if (in_definition_list) .definition_list_item else if (it.checked != null) .task_list_item else .list_item,
                .checked = it.checked,
                .start_pos = if (pos) c.start else null,
                .end_pos = if (pos) stand.before else null,
            };
            if (in_definition_list) {
                // The first paragraph is the term; the rest is the definition.
                const items = c.children.items;
                const has_term = items.len > 0 and items[0].tag == .para;
                const pair = try a.alloc(Node, 2);
                pair[0] = .{ .tag = .term, .children = if (has_term) items[0].children else &.{} };
                pair[1] = .{ .tag = .definition, .children = try a.dupe(Node, if (has_term) items[1..] else items) };
                n.children = pair;
            } else n.children = try a.dupe(Node, c.children.items);
            break :blk n;
        },
        .footnote => |f| {
            // Recorded for the document, where its content was allocated; the block
            // attributes before it are dropped.
            self.footnote_depth -= 1;
            const da = self.defs.a;
            const stored = try da.create(FootnoteDef);
            stored.* = .{
                .blocks = try da.dupe(Node, c.children.items),
                .start_pos = if (pos) c.start else null,
                .end_pos = if (pos) stand.pos else null,
            };
            try self.defs.footnote_defs.put(da, f.label, stored);
            try self.defs.footnote_log.append(da, .{ .label = f.label, .def = stored, .headings_before = f.headings_before });
            if (self.stack.items.len > 0) self.tip().pending_attrs = null else self.pending_attrs = null;
            return;
        },
        .div => |dv| .{
            .tag = .div,
            .children = try a.dupe(Node, c.children.items),
            .attrs = if (dv.class) |cls| try a.dupe(Attr, &.{.{ .key = "class", .value = cls }}) else &.{},
            .start_pos = if (pos) c.start else null,
            // Closed, a div ends on its fence; unclosed, where its container does.
            .end_pos = if (pos) (dv.end orelse stand.pos) else null,
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
        const n = if (parent.pending_attrs) |ba| try inline_mod.applyBlockAttrsToNode(self.nodeAllocator(), node, ba) else node;
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
