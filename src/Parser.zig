//! The block parser: a container stack, the shape of djot.js's `block.js`, in one pass
//! over the lines. Each line is run against the open containers from the outermost in
//! (`continues`), then against the block starts while the innermost matched container
//! holds blocks (`tryOpen`); what remains is lazy text for an open paragraph or heading, a
//! blank line, or text for the innermost container. A container closes when a line neither
//! continues it nor is lazy text for it, and its `Node` ends where the parser stands;
//! `nextBlock` returns each top-level block's tree as it closes, never generating ids or
//! resolving references, which the document does. Definitions are recorded as they close.

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
const document = @import("document.zig");
const Definitions = document.Definitions;
const FootnoteDef = document.FootnoteDef;
const lines_mod = @import("Lines.zig");
const Lines = lines_mod.Lines;
const Line = lines_mod.Line;

const Parser = @This();

pub const Error = Allocator.Error || error{ ReadFailed, InputTooLarge, TooDeep };

/// A top-level block and the arena its nodes live in, which the consumer gives back
/// through `recycle` once the block is written. `last` is where the block's last event
/// stands, as djot.js counts them: its end, or its caption's.
pub const Block = struct { node: Node, arena: *std.heap.ArenaAllocator, last: ?SourcePos };

/// The block arenas come from here.
gpa: Allocator,
/// The arena of the block being built, and its allocator. The parser swaps in a fresh
/// one the moment a top-level block closes, so whatever opens on the line that closed
/// it lives with the next block, never in an arena the consumer may already own.
arena: *std.heap.ArenaAllocator,
a: Allocator,
/// A written block's arena, reused for the next block.
spare: ?*std.heap.ArenaAllocator = null,
/// The document's arena, for what the definitions keep. The parser's own buffers (the
/// stack, the open leaf's lines, spare children lists) grow on `gpa`, so a buffer
/// outgrown is freed rather than left in the arena for the document.
da: Allocator,
defs: *Definitions,
track_pos: bool = false,
lines: Lines,
stack: std.ArrayList(Container) = .empty,
/// Block attributes waiting for the next top-level block.
pending_attrs: ?BlockAttrs = null,
/// For the held top-level table (`CaptionLog`); a container keeps its own table's.
caption_log: ?CaptionLog = null,
/// The lines of the open leaf, which is always the tip, so one set of buffers serves.
leaf_slices: std.ArrayList([]const u8) = .empty,
leaf_starts: std.ArrayList(LeafStart) = .empty,
/// The newline of the open leaf's last line, where its `LineMap` ends.
leaf_last_eol: SourcePos = undefined,
/// Whether the open leaf's last line ended in a newline: only the input's last line may not.
leaf_last_newline: bool = true,
/// Children lists of closed containers, reused by the next ones pushed.
spare_lists: std.ArrayList(std.ArrayList(Node)) = .empty,
/// Open footnotes: their content is allocated for the document, not the block.
footnote_depth: usize = 0,
/// Set by a start or continuation that took the whole line (a fence): nothing else
/// on it is read.
finished_line: bool = false,
/// Whether the blank line being parsed was taken by a block attribute it failed: then it
/// is the paragraph's, and no blank line for the list around (djot.js), so not loosening.
blank_taken: bool = false,
/// The block `nextBlock` returns once the current line is parsed.
done: ?Block = null,
/// A closed top-level table, kept until a block follows it or the input ends: a caption
/// before that joins it, as djot.js attaches a caption to the previous node, blank lines,
/// definitions and attributes between notwithstanding. Also the second of two blocks
/// closed on one line (a block attribute that failed and became a paragraph, after a
/// table), returned by the next call.
pending: ?Block = null,
/// Lines consumed, and the line the last top-level block ended on.
line_count: u64 = 0,
last_block_line: u64 = 0,

const Kind = enum { para, heading, thematic_break, attributes, block_quote, list, list_item, footnote, div, code_block, table, caption, reference_definition };

/// What a container holds: blocks, list items, inline content, verbatim text, table
/// cells, nothing, or attribute text.
const Content = enum { block, items, inlines, text, cells, none, attributes };

/// What a list's items share, read off their markers (djot.js's list styles).
const ListStyle = union(enum) {
    bullet: u8,
    task,
    definition,
    ordered: struct { styles: leaf.OrderedStyles, delim: node_mod.Delim },
};

/// Where the log stood, and the counts, as the last caption joined a table: a caption
/// replacing it logs the replaced one's ids there, where they were counted.
const CaptionLog = struct { index: usize, headings_before: usize, ids_before: usize };

const Container = struct {
    start: SourcePos,
    children: std.ArrayList(Node),
    /// Parser attributes waiting for this container's next child block.
    pending_attrs: ?BlockAttrs = null,
    /// For a table among the children (`CaptionLog`).
    caption_log: ?CaptionLog = null,
    /// For a leaf: one past the last non-blank character of its last line (djot.js ends
    /// paragraphs and headings there, trailing whitespace excluded).
    leaf_end: SourcePos = undefined,
    data: union(Kind) {
        /// `attrs_from`: no inline attribute is read before this joined offset (a failed
        /// block attribute's first line is text, as djot.js reparses it).
        para: struct { attrs_from: usize = 0, converted: bool = false },
        heading: struct {
            level: u8,
            /// The first bare `#` line after the heading's last content line, where the
            /// heading ends when that content ends in a hard break (djot.js: one past it).
            bare_at: ?SourcePos = null,
        },
        thematic_break: struct { end: SourcePos },
        /// `attrs`: parsed when the lines so far form a complete block attribute.
        attributes: struct {
            indent: usize,
            attrs: ?BlockAttrs = null,
            /// Fed each line as written, as djot.js's container keeps its parser.
            parser: *attrs_mod.AttrParser,
            /// How the lines so far failed, if they did: right at a line end, where a blank
            /// line next makes the paragraph (djot.js) and counts as the list's blank line;
            /// or elsewhere, where only a line not indented past the opener does.
            failed: enum { no, eol, elsewhere } = .no,
        },
        block_quote: void,
        /// `blanklines` and `tight` as `parse.js` keeps them: a blank line marks the list
        /// and the next event that is not a blank line, a list start or a list or item end
        /// makes it loose.
        list: struct { style: ListStyle, indent: usize, marker: [32]u8, marker_len: u8, blanklines: bool = false, tight: bool = true },
        list_item: struct { indent: usize, checked: ?bool },
        /// `log_index`: its entry in `Definitions.log`, made as it opened.
        footnote: struct { label: []const u8, indent: usize, log_index: usize },
        /// `end`: the closing fence's last colon, once met.
        div: struct { fence_len: usize, class: ?[]const u8, end: ?SourcePos = null },
        /// `indent`: the fence's column, which content lines lose (deeper indentation
        /// stays); `end`: the closing fence's last character, once met.
        code_block: struct { fence: leaf.FenceInfo, indent: usize, lang: ?[]const u8, end: ?SourcePos = null },
        /// `aligns`: the last separator row's, for the rows that follow.
        table: struct { aligns: []const CellAlign = &.{} },
        caption: void,
        reference_definition: struct { label: []const u8, indent: usize },
    },

    fn content(self: Container) Content {
        return switch (self.data) {
            .para, .heading, .caption => .inlines,
            .thematic_break, .reference_definition => .none,
            .attributes => .attributes,
            .block_quote, .list_item, .footnote, .div => .block,
            .list => .items,
            .code_block => .text,
            .table => .cells,
        };
    }

    /// Whether the container becomes a node of its parent (a definition, an attribute
    /// block and a caption do not), which is what ends a held table's wait.
    fn makesNode(self: Container) bool {
        return switch (self.data) {
            .attributes, .footnote, .caption, .reference_definition => false,
            else => true,
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
    /// Whether the current line belongs to the block closing (its closing fence).
    inclusive: bool = false,
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
        // Saturating past 4 GiB, as the line source's positions (a line that long is in memory anyway).
        return .{ .line = self.line.pos.line, .col = std.math.lossyCast(u32, i + 1), .offset = self.line.pos.offset +| std.math.lossyCast(u32, i) };
    }

    /// One position before `pos`: the byte before it, or col 0 (the previous line's
    /// newline) at the line's start.
    fn before(self: Cursor) SourcePos {
        if (self.i == 0) return .{ .line = self.line.pos.line, .col = 0, .offset = self.line.newlineBefore() };
        return self.at(self.i - 1);
    }

    fn stand(self: Cursor) Stand {
        return .{ .pos = self.pos(), .before = self.before(), .line_first = if (self.line.bytes.len == 0) self.line.eol else self.line.pos };
    }
};

/// `gpa` backs the block arenas; `da` is the document's arena, for the parser's own
/// buffers and what definitions keep.
pub fn init(gpa: Allocator, da: Allocator, lines: Lines, defs: *Definitions) Allocator.Error!Parser {
    const arena = try newArena(gpa);
    return .{ .gpa = gpa, .arena = arena, .a = arena.allocator(), .da = da, .defs = defs, .lines = lines };
}

pub fn deinit(self: *Parser) void {
    self.lines.deinit();
    for (self.stack.items) |*c| c.children.deinit(self.gpa);
    self.stack.deinit(self.gpa);
    self.leaf_slices.deinit(self.gpa);
    self.leaf_starts.deinit(self.gpa);
    for (self.spare_lists.items) |*l| l.deinit(self.gpa);
    self.spare_lists.deinit(self.gpa);
    self.destroy(self.arena);
    if (self.spare) |spare| self.destroy(spare);
    if (self.pending) |p| self.destroy(p.arena);
    if (self.done) |d| self.destroy(d.arena);
}

fn newArena(gpa: Allocator) Allocator.Error!*std.heap.ArenaAllocator {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    return arena;
}

fn destroy(self: *Parser, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    self.gpa.destroy(arena);
}

/// Takes a written block's arena back for the next block, or frees it when one is spare.
pub fn recycle(self: *Parser, arena: *std.heap.ArenaAllocator) void {
    if (self.spare == null) {
        _ = arena.reset(.retain_capacity);
        self.spare = arena;
    } else self.destroy(arena);
}

/// Where the input ended; meaningful once `nextBlock` has returned null.
pub fn endPos(self: *const Parser) SourcePos {
    return self.lines.end();
}

/// Whether lines followed the last top-level block (blank lines, definitions,
/// attributes), which carry djot.js's events to the input's end.
pub fn trailing(self: *const Parser) bool {
    return self.line_count > self.last_block_line;
}

/// The next top-level block, or null at the end of the input. Definitions are recorded
/// in `defs` as they close and never returned.
pub fn nextBlock(self: *Parser) Error!?Block {
    while (self.done == null) {
        const line = (try self.lines.next()) orelse {
            const end = self.lines.end();
            try self.closeFrom(0, .{ .pos = end, .before = end, .line_first = end, .eof = true });
            self.flush();
            break;
        };
        self.line_count += 1;
        try self.parseLine(line);
    }
    defer self.done = null;
    return self.done;
}

/// The pending block's wait is over: it is the block to return, once the one already
/// due has been.
fn flush(self: *Parser) void {
    if (self.done != null) return;
    if (self.pending) |p| {
        self.done = p;
        self.pending = null;
    }
}

fn tip(self: *Parser) *Container {
    return &self.stack.items[self.stack.items.len - 1];
}

/// The allocator for nodes: the document's inside a footnote, whose content outlives
/// the block, else the block's.
fn nodeAllocator(self: *const Parser) Allocator {
    return if (self.footnote_depth > 0) self.defs.a else self.a;
}

/// Whether the container at depth `n` (none when `n` is 0) holds blocks or items, so
/// starts are tried after it.
fn holdsBlocks(self: *const Parser, n: usize) bool {
    if (n == 0) return true;
    return switch (self.stack.items[n - 1].content()) {
        .block, .items => true,
        else => false,
    };
}

fn parseLine(self: *Parser, line: Line) Error!void {
    var cur = Cursor{ .line = line };
    self.finished_line = false;
    self.blank_taken = false;
    // Open containers continue from the outermost in; the first that does not ends it.
    var matched: usize = 0;
    for (self.stack.items) |*c| {
        cur.skipSpace();
        if (!try self.continues(c, &cur)) break;
        matched += 1;
    }
    if (self.finished_line) {
        // A closing code fence: the containers above its block close, and the line is done.
        var stand = cur.stand();
        stand.inclusive = true;
        return self.closeFrom(matched, stand);
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
            if (!new_starts and !self.blank_taken) self.blankLine();
        } else {
            try self.push(.{ .para = .{} }, cur.pos());
        }
    }
    if (self.stack.items.len > 0) switch (self.tip().content()) {
        .inlines => if (!blank) try self.addLeafLine(cur),
        .text => try self.addCodeLine(cur),
        else => {},
    };
}

/// Whether the line at `cur` continues `c`, moving `cur` past the prefix it consumes.
fn continues(self: *Parser, c: *Container, cur: *Cursor) Error!bool {
    switch (c.data) {
        .para => return !cur.atEol(),
        .heading => |*h| {
            const r = cur.rest();
            const hashes = leaf.countLeadingChar(r, '#');
            if (hashes != h.level or (hashes < r.len and r[hashes] != ' ' and r[hashes] != '\t')) return false;
            // A bare marker line adds no text: the heading ends where its text does, or
            // after a hard break at the first such line.
            if (h.bare_at == null and leaf.isBlank(r[hashes..])) h.bare_at = cur.line.pos;
            cur.i += hashes;
            return true;
        },
        .thematic_break => return false,
        .attributes => |*at| {
            if (at.attrs != null) return false;
            // Failed at its line end, a blank line makes it a paragraph that ends here, and
            // the line is the list's blank line too (djot.js converts on the failing line).
            if (at.failed == .eol and cur.atEol()) {
                c.data = .{ .para = .{ .attrs_from = try self.failedAttrsFrom(), .converted = true } };
                return false;
            }
            // Lines indented past the opener keep the attribute going until it parses.
            if (cur.indent > at.indent) { // a blank line indented past the opener keeps it going too (djot.js)
                // Stored with its trailing tab, content should it become a paragraph.
                try self.addLeafSlice(std.mem.trimStart(u8, cur.rest(), " \t"), cur.pos(), cur.line);
                // A kept blank line ends the paragraph this may become at its first byte
                // (djot.js: one past the newline before it, its own a dropped soft break).
                c.leaf_end = if (cur.atEol()) cur.line.pos else afterContent(cur.line);
                const line = self.leaf_slices.items[self.leaf_slices.items.len - 1];
                switch (at.failed) {
                    // Failed, djot.js's parser is stuck: the lines gather until one not
                    // indented past the opener; failed at a line end, until the blank line
                    // next, which a line that is not blank forfeits.
                    .elsewhere => {},
                    .eol => at.failed = .elsewhere,
                    // Fed as written, trailing blanks included, as djot.js feeds the line;
                    // what follows a `}` on its line is ignored, as there.
                    .no => switch (try at.parser.feedLine(line)) {
                        .complete => at.attrs = try at.parser.finish(),
                        .unfinished => {},
                        // Failing with nothing but blanks left on the line, the line makes
                        // the paragraph at once; failing on the line end, the next blank
                        // line does (djot.js).
                        .failed_at => |p| if (p == line.len) {
                            at.failed = .eol;
                        } else if (leaf.isBlank(line[p + 1 ..])) {
                            c.data = .{ .para = .{ .attrs_from = try self.failedAttrsFrom(), .converted = true } };
                        } else {
                            at.failed = .elsewhere;
                        },
                    },
                }
                cur.i = cur.line.bytes.len;
                return true;
            }
            // It never parsed: its lines are a paragraph, and this line continues it or
            // not as a paragraph's would; a blank line that ends it here was the attribute's
            // (djot.js converts on it and fires no blank line for the list around).
            c.data = .{ .para = .{ .attrs_from = try self.failedAttrsFrom(), .converted = true } };
            self.blank_taken = cur.atEol();
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
                .ordered => |o| m.style == .ordered and m.style.ordered.delim == o.delim and o.styles.matches(m.ordered.?),
            };
        },
        .list_item => |it| return cur.atEol() or cur.indent > it.indent,
        .footnote => |f| return cur.atEol() or cur.indent > f.indent,
        .div => |*dv| {
            // A code block's lines are its own, whatever they look like (djot.js #109).
            if (self.tip().data == .code_block) return true;
            // A bare fence of at least as many colons closes the div, ending it on its
            // last colon; the rest of the line is blank.
            const r = cur.rest();
            if (leaf.closesDiv(r, dv.fence_len)) {
                dv.end = cur.at(cur.i + leaf.countLeadingChar(r, ':') - 1);
                cur.i = cur.line.bytes.len;
                return false;
            }
            return true;
        },
        .code_block => |*cb| {
            // The closing fence ends the block on its last character and takes the line.
            const r = cur.rest();
            if (leaf.isClosingCodeFence(r, cb.fence)) {
                cb.end = cur.at(cur.i + leaf.countLeadingChar(r, cb.fence.char) - 1);
                cur.i = cur.line.bytes.len;
                self.finished_line = true;
                return false;
            }
            return true;
        },
        .table => {
            if (!leaf.isTableRow(cur.rest())) return false;
            try self.tableRow(c, cur);
            return true;
        },
        .caption => return !cur.atEol(),
        .reference_definition => |rd| {
            // A deeper-indented line holding one word continues the destination.
            const r = cur.rest();
            if (cur.atEol() or cur.indent <= rd.indent or std.mem.indexOfAny(u8, r, " \t") != null) return false;
            try self.addLeafSlice(r, cur.pos(), cur.line);
            cur.i = cur.line.bytes.len;
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
fn tryOpen(self: *Parser, cur: *Cursor, matched: usize) Error!bool {
    const r = cur.rest();
    const stand = cur.stand();
    if (matched > 0 and self.stack.items[matched - 1].content() == .items) {
        const m = listMarker(r).?; // the list opened on, or continued by, this marker
        try self.closeFrom(matched, stand);
        // An item joining an ordered list narrows the styles it may still be (djot.js).
        switch (self.tip().data.list.style) {
            .ordered => |*o| _ = o.styles.accept(m.ordered.?, false),
            else => {},
        }
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
    if (r.len > 1 and r[0] == '^' and (r[1] == ' ' or r[1] == '\t')) {
        // The containers before it close where its text starts (djot.js moves past the
        // marker first), so a table ends at its caption.
        cur.i += 1;
        cur.skipSpace();
        try self.closeFrom(matched, cur.stand());
        try self.push(.caption, cur.pos());
        self.tip().leaf_end = cur.pos();
        return true;
    }
    if (leaf.definitionLabel(r)) |def| {
        const spaced = r.len == def.rest_col or r[def.rest_col - 1] == ' ' or r[def.rest_col - 1] == '\t';
        if (def.is_footnote and spaced) {
            try self.closeFrom(matched, stand);
            // Logged as it opens, with the counts before it; its own id, in the block
            // attributes waiting for it, counts next (djot.js registers it where it is
            // written), then its content's.
            const label = try self.defs.a.dupe(u8, try inline_mod.normalizeLabel(self.a, def.label[1..])); // as a reference's
            try self.defs.log.append(self.defs.gpa, .{
                .headings_before = self.defs.headings_parsed,
                .ids_before = self.defs.ids_parsed,
                .what = .{ .footnote = null },
            });
            if (self.attrsSlot().*) |ba| {
                if (ba.id != null) self.defs.ids_parsed += 1;
            }
            try self.push(.{ .footnote = .{
                .label = label,
                .indent = cur.indent,
                .log_index = self.defs.log.items.len - 1,
            } }, cur.pos());
            self.footnote_depth += 1;
            cur.i += def.rest_col;
            return true;
        }
        // A reference definition's destination is one word, to the end of the line
        // (`[^n]:x`, no space after the colon, is one, labelled `^n`, as djot.js).
        if (std.mem.indexOfAny(u8, def.rest, " \t") == null and def.rest_col + def.rest.len == r.len) {
            try self.closeFrom(matched, stand);
            // The label as djot.js keys it: trimmed, each run of whitespace one space.
            try self.push(.{ .reference_definition = .{ .label = try self.defs.a.dupe(u8, try inline_mod.normalizeLabel(self.a, def.label)), .indent = cur.indent } }, cur.pos());
            if (def.rest.len > 0) try self.addLeafSlice(def.rest, cur.at(cur.i + def.rest_col), cur.line);
            cur.i = cur.line.bytes.len;
            return true;
        }
    }
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
    if (leaf.isTableRow(r)) {
        try self.closeFrom(matched, stand);
        try self.push(.{ .table = .{} }, cur.pos());
        try self.tableRow(self.tip(), cur);
        return true;
    }
    // A block attribute opens only when its first line parses so far or completes at its
    // `}`; a line that fails, text after the `}` included, is a paragraph (djot.js).
    if (r[0] == '{') {
        // Decided on a parser of its own, on the arena of the block the line stands in:
        // what opens lives with the block after `closeFrom`, which may be the next one.
        var probe = attrs_mod.AttrParser.init(self.nodeAllocator(), r);
        const opens = switch (try probe.feedLine(r)) {
            .unfinished => true,
            .complete => |p| leaf.isBlank(r[p + 1 ..]),
            .failed_at => false,
        };
        if (opens) {
            try self.closeFrom(matched, stand);
            // The container's parser is fed the leaf's copy of the line, which the
            // attributes keep slices of; both live on the arena of the block they open.
            const a = self.nodeAllocator();
            const text = try self.leafCopy(r);
            const parser = try a.create(attrs_mod.AttrParser);
            parser.* = attrs_mod.AttrParser.init(a, text);
            const fed = try parser.feedLine(text);
            try self.push(.{ .attributes = .{ .indent = cur.indent, .parser = parser } }, cur.pos());
            try self.addOwnedLeafSlice(text, cur.pos(), cur.line); // trailing blanks stay: content if this fails
            self.tip().leaf_end = afterContent(cur.line);
            // Complete on one line, or kept open for the indented lines that may follow.
            if (fed == .complete) self.tip().data.attributes.attrs = try parser.finish();
            cur.i = cur.line.bytes.len;
            return true;
        }
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
    if (leaf.isCodeFence(r)) |fence| {
        try self.closeFrom(matched, stand);
        try self.push(.{ .code_block = .{
            .fence = fence,
            .indent = cur.indent,
            .lang = if (fence.lang) |lang| try self.nodeAllocator().dupe(u8, lang) else null,
        } }, cur.pos());
        cur.i = cur.line.bytes.len;
        self.finished_line = true;
        return true;
    }
    return false;
}

/// A table row at `cur`, which takes the line: a separator sets the aligns of the rows
/// to come and makes the row before it a head row; any other row's cells run from
/// pipe to pipe, read with the aligns set so far.
fn tableRow(self: *Parser, c: *Container, cur: *Cursor) Error!void {
    const a = self.nodeAllocator();
    const r = cur.rest();
    defer {
        cur.i = cur.line.bytes.len;
        self.finished_line = true;
    }
    if (leaf.isTableSep(r)) {
        const aligns = try leaf.parseSepAligns(a, r);
        c.data.table.aligns = aligns;
        if (c.children.items.len > 0) {
            const row = &c.children.items[c.children.items.len - 1].data.row;
            row.head = true;
            // The cells were made for this row alone, so they are this parser's to change.
            for (@constCast(row.children), 0..) |*cell, i| {
                cell.data.cell.head = true;
                cell.data.cell.cell_align = if (i < aligns.len) aligns[i] else .default;
            }
        }
        return;
    }
    const strs = try leaf.rowCells(a, r);
    const cells = try a.alloc(Node, strs.len);
    for (strs, cells, 0..) |str, *cell, i| {
        // Trailing spaces go, a tab stays, as djot.js's row parser has it.
        const text = trimEndKeepingEscape(std.mem.trimStart(u8, str, " \t"), " ");
        // Where the cell's text and its pipes lie on the line.
        const idx = cur.i + (@intFromPtr(str.ptr) - @intFromPtr(r.ptr));
        const text_idx = idx + (@intFromPtr(text.ptr) - @intFromPtr(str.ptr));
        if (text.len > 0) try self.addLeafSlice(text, cur.at(text_idx), cur.line);
        cell.* = .{
            .data = .{
                .cell = .{
                    .children = try self.leafInlines(a, 0, false), // no line end follows a cell
                    .cell_align = if (i < c.data.table.aligns.len) c.data.table.aligns[i] else .default,
                },
            },
            .start_pos = if (self.track_pos) cur.at(idx - 1) else null,
            .end_pos = if (self.track_pos) cur.at(idx + str.len) else null,
        };
    }
    try c.children.append(self.gpa, .{
        .data = .{ .row = .{ .children = cells } },
        .start_pos = if (self.track_pos) cur.pos() else null,
        .end_pos = if (self.track_pos) afterBlanks(cur.line, " \t") else null, // a row's trailing tab is not content
    });
}

/// The line at `cur` as the open code block's next line: it loses the fence's
/// indentation and keeps the rest, blank lines included.
fn addCodeLine(self: *Parser, cur: Cursor) Error!void {
    const keep = cur.indent -| self.tip().data.code_block.indent;
    try self.addLeafSlice(cur.line.bytes[cur.i - keep ..], cur.at(cur.i - keep), cur.line);
}

/// A div opener's class is one word, as djot.js (`[\w_-]*` to the end of the line).
fn divClass(class: ?[]const u8) bool {
    for (class orelse return true) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return false;
    }
    return true;
}

fn push(self: *Parser, data: @FieldType(Container, "data"), start: SourcePos) Error!void {
    self.listEvent(data == .list, data == .list_item);
    const c = Container{
        .start = start,
        .children = self.spare_lists.pop() orelse .empty,
        .data = data,
    };
    if (c.makesNode()) {
        if (self.attrsSlot().*) |ba| {
            if (ba.id) |id| try self.countOpeningId(id, data == .para);
        }
        if (self.stack.items.len == 0) self.flush();
    }
    try self.stack.append(self.gpa, c);
}

/// Counts the explicit id waiting for a block that opens, before its content, where
/// djot.js registers it (`Definitions.ids_parsed`); the block's node carries it, and
/// `Ids` registers it there. A paragraph opening a definition list item is its term,
/// whose node the item's close discards with the id (djot.js keeps the term's inlines,
/// not its attributes), so that one is logged where it stands, as an id read off no node.
fn countOpeningId(self: *Parser, id: []const u8, para: bool) Error!void {
    if (para and self.opensTerm()) return self.looseId(id);
    self.defs.ids_parsed += 1;
}

/// Whether a paragraph opening now is the first child of a definition list's item: its
/// term, once the item closes.
fn opensTerm(self: *Parser) bool {
    const s = self.stack.items;
    if (s.len < 2) return false;
    const item = s[s.len - 1];
    return item.data == .list_item and item.children.items.len == 0 and s[s.len - 2].data == .list and s[s.len - 2].data.list.style == .definition;
}

/// Registers `id`, read off any node, where it stands: counted now and logged with the
/// counts before it, so `Ids` takes it there (`Definitions.log`).
fn looseId(self: *Parser, id: []const u8) Error!void {
    try self.defs.log.append(self.defs.gpa, .{
        .headings_before = self.defs.headings_parsed,
        .ids_before = self.defs.ids_parsed,
        .what = .{ .id = try self.defs.a.dupe(u8, id) },
    });
    self.defs.ids_parsed += 1;
}

/// Keeps the explicit ids on `node` and its descendants registered as the node is
/// dropped, logged where they are counted now (the caller uncounted them first).
fn looseIds(self: *Parser, node: Node) Error!void {
    if (node.id) |id| try self.looseId(id);
    for (node.children()) |child| try self.looseIds(child);
}

/// The explicit ids among `nodes` and their descendants.
/// Every id in `node`'s tree, in tree order.
fn collectIds(gpa: Allocator, node: Node, ids: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (node.id) |id| try ids.append(gpa, id);
    for (node.children()) |child| try collectIds(gpa, child, ids);
}

/// The ids in `nodes`' trees, which `boundLeaf` has walked.
fn countIds(nodes: []const Node) usize {
    var n: usize = 0;
    for (nodes) |node| {
        if (node.id != null) n += 1;
        n += countIds(node.children());
    }
    return n;
}

/// The first walk over a leaf's fresh inlines, and the only one before `Ids.assign` bounds
/// the block: deeper than `document.max_nesting` is `error.TooDeep` here, before any
/// walker recurses into it. Counts the explicit ids, and reads the label of a link written
/// `[text][]` off its text once what stands below it is known to be bounded.
fn boundLeaf(a: Allocator, nodes: []Node, depth: usize) Error!usize {
    if (depth > document.max_nesting) return error.TooDeep;
    var n: usize = 0;
    for (nodes) |*node| {
        if (node.id != null) n += 1;
        n += try boundLeaf(a, @constCast(node.children()), depth + 1);
        try inline_mod.labelOwnText(a, node);
    }
    return n;
}

/// The innermost list a tightness event reaches: the tip, or the list the tip's item is
/// in (`parse.js` looks no deeper).
fn listNode(self: *Parser) ?*Container {
    const n = self.stack.items.len;
    if (n > 0 and self.stack.items[n - 1].isList()) return &self.stack.items[n - 1];
    if (n > 1 and self.stack.items[n - 2].isList()) return &self.stack.items[n - 2];
    return null;
}

/// `parse.js`'s rule on every event but a blank line: after blank lines, anything but a
/// list start or a list or item end makes the list loose, and anything but an item
/// boundary clears the blank lines seen.
fn listEvent(self: *Parser, is_list: bool, is_item: bool) void {
    const ln = self.listNode() orelse return;
    const l = &ln.data.list;
    if (!is_list and !is_item and l.blanklines) l.tight = false;
    if (!is_item) l.blanklines = false;
}

/// A blank line: it marks the innermost list for tightness, and block attributes do not
/// survive one (see the `zjot.test` header).
fn blankLine(self: *Parser) void {
    if (self.listNode()) |ln| ln.data.list.blanklines = true;
    self.attrsSlot().* = null;
}

/// Where the record of the last caption to join a table lives: with the container the
/// table is a child of, or with the parser for the held top-level table.
fn captionLogSlot(self: *Parser) *?CaptionLog {
    return if (self.stack.items.len > 0) &self.tip().caption_log else &self.caption_log;
}

/// Where block attributes wait: with the innermost open container, or with the parser
/// for the next top-level block.
fn attrsSlot(self: *Parser) *?BlockAttrs {
    return if (self.stack.items.len > 0) &self.tip().pending_attrs else &self.pending_attrs;
}

/// A block attribute that never parsed is a paragraph: its lines are read without inline
/// attributes when the first opened one, as djot.js reparses every line it fed the
/// attribute parser (`reparseAttributes`).
fn failedAttrsFrom(self: *Parser) Error!usize {
    const slices = self.leaf_slices.items;
    if (!try attrs_mod.opensAttr(self.nodeAllocator(), slices[0])) return 0;
    var joined: usize = slices.len - 1; // the newlines between
    for (slices) |s| joined += s.len;
    return joined;
}

/// The rest of the line at `cur` as the open leaf's next line.
fn addLeafLine(self: *Parser, cur: Cursor) Error!void {
    // Trailing blanks stay: before a soft break they are content, and at the block's end
    // the inline parser trims the spaces, as djot.js.
    const text = cur.rest();
    try self.addLeafSlice(text, cur.pos(), cur.line);
    self.tip().leaf_end = afterContent(cur.line);
    if (self.tip().data == .heading) self.tip().data.heading.bare_at = null;
}

/// Where a leaf line's content starts, and the newline before the line, which the line
/// source places (its `LineMap` segment keeps it for the join, rather than subtract it).
const LeafStart = struct { pos: SourcePos, join: SourcePos };

fn addLeafSlice(self: *Parser, text: []const u8, start: SourcePos, line: Line) Error!void {
    return self.addOwnedLeafSlice(try self.leafCopy(text), start, line);
}

/// `text` where the leaf can keep it: itself when the lines are stable, else a copy.
fn leafCopy(self: *Parser, text: []const u8) Error![]const u8 {
    return if (self.lines.stable()) text else try self.nodeAllocator().dupe(u8, text);
}

fn addOwnedLeafSlice(self: *Parser, slice: []const u8, start: SourcePos, line: Line) Error!void {
    try self.leaf_slices.append(self.gpa, slice);
    // The join before this line is the end of the content line before it (a heading's
    // bare `#` line between adds nothing, and djot.js breaks at the first newline).
    const join = if (self.leaf_slices.items.len == 1) line.eol else self.leaf_last_eol;
    try self.leaf_starts.append(self.gpa, .{ .pos = start, .join = join });
    self.leaf_last_eol = line.eol;
    self.leaf_last_newline = line.newline;
}

/// Where the open leaf's inline content is read from: `joined_start` of each line in the
/// text `joinLines` makes, and the position it came from.
fn leafLineMap(self: *Parser, a: Allocator) Error!LineMap {
    const segs = try a.alloc(LineMap.Segment, self.leaf_slices.items.len);
    var joined: usize = 0;
    for (self.leaf_slices.items, self.leaf_starts.items, segs) |slice, start, *seg| {
        seg.* = .{ .joined_start = joined, .orig_line = start.pos.line, .orig_col = start.pos.col, .orig_offset = start.pos.offset, .join_line = start.join.line, .join_offset = start.join.offset };
        joined += slice.len + 1;
    }
    return .{ .segments = segs, .total = joined - 1, .end = self.leaf_last_eol };
}

/// The inline content of the open leaf, which empties the leaf buffers.
/// `text` without its trailing `blanks`, except one right after a backslash: that one is
/// escaped, a hard break or a non-breaking space, not trailing blank.
fn trimEndKeepingEscape(text: []const u8, blanks: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, blanks);
    return if (trimmed.len < text.len and trimmed.len > 0 and trimmed[trimmed.len - 1] == '\\') text[0 .. trimmed.len + 1] else trimmed;
}

fn leafInlines(self: *Parser, a: Allocator, attrs_from: usize, ends_line: bool) Error![]const Node {
    defer self.dropLeaf();
    const src = try inline_mod.joinLines(a, self.leaf_slices.items);
    if (src.len == 0) return &.{};
    const map: ?LineMap = if (self.track_pos) try self.leafLineMap(a) else null;
    var dropped: std.ArrayList([]const u8) = .empty;
    const nodes = try inline_mod.parseInlineContent(a, src, map, attrs_from, &dropped, ends_line);
    // An inline attribute attached to no node, or an id a later attribute overrode, was
    // registered all the same (djot.js); among one leaf's explicit ids the order cannot
    // show, so these go first.
    for (dropped.items) |id| try self.looseId(id);
    self.defs.ids_parsed += try boundLeaf(a, @constCast(nodes), 1);
    return nodes;
}

fn dropLeaf(self: *Parser) void {
    self.leaf_slices.clearRetainingCapacity();
    self.leaf_starts.clearRetainingCapacity();
}

/// One past the last non-blank character of `line`: its newline unless whitespace trails.
fn afterContent(line: Line) SourcePos {
    return afterBlanks(line, " "); // spaces, not tabs, as djot.js: a trailing tab is content
}

/// Where `line`'s content ends with `blanks` stripped from its end: its newline when
/// there are none, else one past the last other byte.
fn afterBlanks(line: Line, blanks: []const u8) SourcePos {
    const trimmed = std.mem.trimEnd(u8, line.bytes, blanks).len;
    if (trimmed == line.bytes.len) return line.eol;
    const content = std.math.lossyCast(u32, trimmed);
    return .{ .line = line.pos.line, .col = content +| 1, .offset = line.pos.offset +| content };
}

/// Where a paragraph or heading ends, as djot.js: after its last non-blank character, or
/// one past a hard break that ends it.
fn leafEnd(c: Container, children: []const Node, stand: Stand) SourcePos {
    // A caption ends one before where the parser stands as it closes, whatever closed it
    // (djot.js: `pos - 1` of the closing line); a paragraph or heading after its last
    // content byte, or past a hard break ending it, at the next line's first byte.
    if (c.data == .caption) return stand.before;
    if (children.len > 0 and children[children.len - 1].data == .hard_break) {
        return if (c.data == .heading) (c.data.heading.bare_at orelse stand.line_first) else stand.line_first;
    }
    return c.leaf_end;
}

/// Closes the containers from depth `from` up, innermost first.
fn closeFrom(self: *Parser, from: usize, stand: Stand) Error!void {
    while (self.stack.items.len > from) try self.close(stand);
}

/// Closes the tip: its node, ending where the parser stands, joins its parent's
/// children, or is the top-level block `nextBlock` returns; a footnote is recorded.
fn close(self: *Parser, stand: Stand) Error!void {
    self.listEvent(self.tip().isList(), self.tip().data == .list_item);
    var c = self.stack.pop().?;
    defer {
        c.children.clearRetainingCapacity();
        self.spare_lists.append(self.gpa, c.children) catch c.children.deinit(self.gpa); // a spare list is only a saving
    }
    const a = self.nodeAllocator();
    const pos = self.track_pos;
    const node: Node = switch (c.data) {
        .para => |p| blk: {
            // A failed attribute block that a line turned into a paragraph takes the
            // attributes waiting before it, as one closed as such does (below).
            if (p.converted) {
                if (self.attrsSlot().*) |ba| {
                    if (ba.id) |id| try self.countOpeningId(id, true);
                }
            }
            break :blk try self.leafNode(a, c, .para, 0, p.attrs_from, stand);
        },
        .heading => |h| blk: {
            // Its inline ids count first, then the heading (djot.js registers an attribute's
            // id as it is read, the heading's own as the heading ends).
            const n = try self.leafNode(a, c, .heading, h.level, 0, stand);
            self.defs.headings_parsed += 1;
            break :blk n;
        },
        .thematic_break => |tb| .{
            .data = .thematic_break,
            .start_pos = if (pos) c.start else null,
            .end_pos = if (pos) tb.end else null,
        },
        .attributes => |at| {
            if (at.attrs) |attrs| {
                // Waits for the next block in the container it was written in.
                const slot = self.attrsSlot();
                if (slot.*) |existing| {
                    // An id a later line's overrides, an empty one included, was still read
                    // (djot.js registers it).
                    if (existing.id != null and attrs.writesId()) try self.looseId(existing.id.?);
                }
                slot.* = if (slot.*) |existing| try existing.merge(attrs, self.nodeAllocator()) else attrs;
                self.dropLeaf();
                return;
            }
            // Never completed: its lines are a paragraph (djot.js reparses them), which
            // takes the attributes waiting before it without having been pushed.
            if (self.attrsSlot().*) |ba| {
                if (ba.id) |id| try self.countOpeningId(id, true);
            }
            const attrs_from = try self.failedAttrsFrom();
            return self.closeAs(try self.leafNode(self.nodeAllocator(), c, .para, 0, attrs_from, stand), stand);
        },
        .block_quote => .{
            .data = .{ .block_quote = try a.dupe(Node, c.children.items) },
            .start_pos = if (pos) c.start else null,
            .end_pos = if (pos) stand.pos else null,
        },
        .list => |l| blk: {
            const children = try a.dupe(Node, c.children.items);
            const data: node_mod.Payload = switch (l.style) {
                .bullet => |ch| .{ .bullet_list = .{ .marker = ch, .tight = l.tight, .children = children } },
                .task => .{ .task_list = .{ .tight = l.tight, .children = children } },
                .definition => .{ .definition_list = children },
                .ordered => |o| ordered: {
                    const style = o.styles.possible[0] orelse .decimal;
                    break :ordered .{ .ordered_list = .{
                        .style = style,
                        .delim = o.delim,
                        .start = leaf.getListStart(l.marker[0..l.marker_len], style),
                        .tight = l.tight,
                        .children = children,
                    } };
                },
            };
            break :blk .{
                .data = data,
                .start_pos = if (pos) c.start else null,
                .end_pos = if (pos) stand.pos else null,
            };
        },
        .list_item => |it| blk: {
            const items = c.children.items;
            const data: node_mod.Payload = if (self.tip().data.list.style == .definition) definition: {
                // The first paragraph is the term; the rest is the definition.
                const has_term = items.len > 0 and items[0].data == .para;
                const pair = try a.alloc(Node, 2);
                pair[0] = .{ .data = .{ .term = if (has_term) items[0].data.para else &.{} } };
                pair[1] = .{ .data = .{ .definition = try a.dupe(Node, if (has_term) items[1..] else items) } };
                break :definition .{ .definition_list_item = pair };
            } else if (it.checked) |checked|
                .{ .task_list_item = .{ .checked = checked, .children = try a.dupe(Node, items) } }
            else
                .{ .list_item = try a.dupe(Node, items) };
            break :blk .{
                .data = data,
                .start_pos = if (pos) c.start else null,
                .end_pos = if (pos) stand.before else null,
            };
        },
        .footnote => |f| {
            // Recorded for the document, where its content was allocated, with the block
            // attributes waiting before it (djot.js puts them on the footnote).
            self.footnote_depth -= 1;
            const da = self.defs.a;
            const slot = self.attrsSlot();
            const stored = try da.create(FootnoteDef);
            stored.* = .{
                .blocks = try da.dupe(Node, c.children.items),
                .attrs = if (slot.*) |ba| try ba.dupe(da) else null,
                .start_pos = if (pos) c.start else null,
                .end_pos = if (pos) stand.pos else null,
            };
            slot.* = null;
            try self.defs.footnote_defs.put(self.defs.gpa, f.label, stored);
            self.defs.log.items[f.log_index].what = .{ .footnote = stored };
            return;
        },
        .div => |dv| .{
            .data = .{ .div = try a.dupe(Node, c.children.items) },
            .attrs = if (dv.class) |cls| try a.dupe(Attr, &.{.{ .key = "class", .value = cls }}) else &.{},
            .start_pos = if (pos) c.start else null,
            // Closed, a div ends on its fence; unclosed, where its container does.
            .end_pos = if (pos) (dv.end orelse stand.pos) else null,
        },
        .code_block => |cb| blk: {
            const text = try self.leafText(a);
            const raw = cb.lang != null and cb.lang.?[0] == '=';
            break :blk .{
                .data = if (raw) .{ .raw_block = .{ .format = cb.lang.?[1..], .text = text } } else .{ .code_block = .{ .lang = cb.lang, .text = text } },
                .start_pos = if (pos) c.start else null,
                // Closed, it ends on its fence; unclosed, where its container does.
                .end_pos = if (pos) (cb.end orelse stand.pos) else null,
            };
        },
        .table => blk: {
            // djot.js gives every table a caption, empty until one follows it.
            const children = try a.alloc(Node, c.children.items.len + 1);
            children[0] = .{ .data = .{ .caption = &.{} } };
            @memcpy(children[1..], c.children.items);
            break :blk .{
                .data = .{ .table = children },
                .start_pos = if (pos) c.start else null,
                .end_pos = if (pos) stand.pos else null,
            };
        },
        .caption => {
            // Joins the table before it, if that is what stands before it, with the block
            // attributes waiting; else it is dropped, as djot.js. Its nodes live where the
            // table's do.
            const table: ?*Node = if (self.stack.items.len > 0) blk: {
                const siblings = self.tip().children.items;
                break :blk if (siblings.len > 0 and siblings[siblings.len - 1].data == .table) &siblings[siblings.len - 1] else null;
            } else if (self.pending) |*p| (if (p.node.data == .table) &p.node else null) else null;
            const t = table orelse {
                // Dropped, but the ids it holds were read (djot.js registers every id it
                // reads): the waiting attributes', taken as it opened, then its content's.
                const slot = self.attrsSlot();
                if (slot.*) |ba| {
                    if (ba.id) |id| try self.looseId(id);
                }
                slot.* = null;
                const n = try self.leafNode(self.nodeAllocator(), c, .caption, 0, 0, stand);
                self.defs.ids_parsed -= countIds(&.{n});
                try self.looseIds(n);
                return;
            };
            // A caption this one replaces is dropped with the ids counted on it as it
            // closed, which stay registered where they were counted (djot.js registers
            // every id it reads): logged into their place in the log, behind whatever
            // stood between the two captions (a definition can), with the counts of then.
            if (countIds(t.data.table[0..1]) > 0) {
                const at = self.captionLogSlot().*.?;
                var ids: std.ArrayList([]const u8) = .empty;
                defer ids.deinit(self.gpa);
                try collectIds(self.gpa, t.data.table[0], &ids);
                for (ids.items, 0..) |id, i| {
                    try self.defs.log.insert(self.defs.gpa, at.index + i, .{
                        .headings_before = at.headings_before,
                        .ids_before = at.ids_before + i,
                        .what = .{ .id = try self.defs.a.dupe(u8, id) },
                    });
                }
            }
            self.captionLogSlot().* = .{ .index = self.defs.log.items.len, .headings_before = self.defs.headings_parsed, .ids_before = self.defs.ids_parsed };
            const ta = if (self.stack.items.len > 0) a else self.pending.?.arena.allocator();
            var n = try self.leafNode(ta, c, .caption, 0, 0, stand);
            // At the top the attributes were parsed into the next block's arena, which the
            // waiting table outlives, so they are copied into the table's.
            const slot = self.attrsSlot();
            if (slot.*) |ba| {
                if (ba.id != null) self.defs.ids_parsed += 1;
                n = try inline_mod.applyBlockAttrsToNode(ta, n, if (self.stack.items.len == 0) try ba.dupe(ta) else ba);
            }
            slot.* = null;
            @constCast(t.data.table)[0] = n; // the placeholder, made with the table
            if (self.stack.items.len == 0) {
                self.pending.?.last = n.end_pos;
                self.last_block_line = if (stand.eof) self.line_count else self.line_count - 1;
            }
            return;
        },
        .reference_definition => |rd| {
            // Recorded for the document, with the block attributes waiting before it.
            const da = self.defs.a;
            const url = try std.mem.concat(da, u8, self.leaf_slices.items);
            self.dropLeaf();
            const slot = self.attrsSlot();
            // An empty label defines nothing (djot.js parses the line and stores no entry).
            if (rd.label.len > 0) try self.defs.ref_defs.put(self.defs.gpa, rd.label, .{ .url = url, .attrs = if (slot.*) |ba| try ba.dupe(da) else null });
            // Its id is registered where it is written, off any node (djot.js).
            if (slot.*) |ba| {
                if (ba.id) |id| try self.looseId(id);
            }
            slot.* = null;
            return;
        },
    };
    try self.closeAs(node, stand);
}

/// The open code block's text: its lines, each with its newline, which empties the
/// buffers. The input's last line may have none, and then the text has none (djot.js).
fn leafText(self: *Parser, a: Allocator) Error![]const u8 {
    defer self.dropLeaf();
    const text = try inline_mod.joinLinesTerminated(a, self.leaf_slices.items);
    return if (self.leaf_last_newline or text.len == 0) text else text[0 .. text.len - 1];
}

/// A paragraph, heading (of `level`) or caption over the open leaf's inlines.
fn leafNode(self: *Parser, a: Allocator, c: Container, tag: node_mod.Tag, level: u8, attrs_from: usize, stand: Stand) Error!Node {
    const children = try self.leafInlines(a, attrs_from, true);
    return .{
        .data = switch (tag) {
            .para => .{ .para = children },
            .heading => .{ .heading = .{ .level = level, .children = children } },
            .caption => .{ .caption = children },
            else => unreachable,
        },
        .start_pos = if (self.track_pos) c.start else null,
        .end_pos = if (self.track_pos) leafEnd(c, children, stand) else null,
    };
}

/// `node`, with the block attributes waiting for it, joins its parent or is done.
fn closeAs(self: *Parser, node: Node, stand: Stand) Error!void {
    if (self.stack.items.len > 0) {
        const parent = self.tip();
        const n = if (parent.pending_attrs) |ba| try inline_mod.applyBlockAttrsToNode(self.nodeAllocator(), node, ba) else node;
        parent.pending_attrs = null;
        try parent.children.append(self.gpa, n);
    } else {
        const n = if (self.pending_attrs) |ba| try inline_mod.applyBlockAttrsToNode(self.a, node, ba) else node;
        self.pending_attrs = null;
        // A block attribute that failed and became a paragraph never flushed the block
        // before it when it opened; it does so now. A table waits for a caption; any
        // other block is returned at once, or next if one is already due.
        self.flush();
        std.debug.assert(self.pending == null);
        // The block takes its arena with it; what opens from here on is the next block's,
        // made first, so that failing leaves every arena owned once.
        const next = self.spare orelse try newArena(self.gpa);
        self.spare = null;
        const block = Block{ .node = n, .arena = self.arena, .last = n.end_pos };
        if (n.data == .table or self.done != null) self.pending = block else self.done = block;
        self.arena = next;
        self.a = next.allocator();
        // The block ended on the line before the one that closed it, unless that line was
        // its own (a closing fence) or the last.
        self.last_block_line = if (stand.eof or stand.inclusive) self.line_count else self.line_count - 1;
    }
}
