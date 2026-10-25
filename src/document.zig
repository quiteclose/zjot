//! Document-level concerns, kept apart from the block parser by lifetime: what one
//! block needs from the rest of the document (`Survey`, `Resolver`) and the section
//! structure that headings imply (`Sections`). A consumer walks the blocks once to
//! survey and once to resolve and render, so the two walks need not hold the same
//! nodes; everything that crosses from one walk to the other lives in the allocator
//! the consumer keeps for the document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const Tag = node_mod.Tag;
const SourcePos = node_mod.SourcePos;
const inline_mod = @import("inline.zig");
const Parser = @import("Parser.zig");
const Definitions = Parser.Definitions;

/// What a block needs from the rest of the document: generated heading ids and the
/// implicit link targets that top-level headings provide. Ids follow djot.js: every
/// heading gets one, wherever it sits; in document order, each generated id avoids
/// every id seen so far, explicit ones included, and an explicit id is used as written.
/// Built by visiting every block and, as they are met, the footnote definitions, so a
/// footnote's headings take their place in the sequence where the definition stands.
/// Read through `Resolver`.
pub const Survey = struct {
    a: Allocator,
    ids_used: std.StringArrayHashMapUnmanaged(void) = .{},
    /// Generated heading ids in visiting order; `Resolver` hands them out by ordinal.
    heading_ids: std.ArrayList([]const u8) = .empty,
    /// The same for each footnote's headings, by label; handed out as its endnote is written.
    footnote_heading_ids: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .{},
    visited_footnotes: usize = 0,
    current_footnote: ?[]const u8 = null,
    /// Heading text to "#id" for top-level headings; a later heading with the same text wins.
    auto_refs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    /// The next suffix to try for each base id already taken, so a repeated heading
    /// text costs one lookup instead of a search from `-1` (quadratic over a document).
    next_suffix: std.StringArrayHashMapUnmanaged(usize) = .{},
    scratch: std.ArrayList(u8) = .empty,

    pub fn visit(self: *Survey, block: Node) !void {
        try self.visitNode(block, null);
    }

    /// Visits the footnote definitions recorded since the last call, in the order they
    /// were met, so their heading ids are generated where the definitions stand.
    pub fn visitFootnotes(self: *Survey, defs: *const Definitions) !void {
        while (self.visited_footnotes < defs.footnote_defs.count()) : (self.visited_footnotes += 1) {
            const label = defs.footnote_defs.keys()[self.visited_footnotes];
            const ids = try self.footnote_heading_ids.getOrPut(self.a, label);
            if (!ids.found_existing) ids.value_ptr.* = .empty;
            self.current_footnote = label;
            defer self.current_footnote = null;
            for (defs.footnote_defs.values()[self.visited_footnotes].blocks) |block| try self.visitNode(block, .footnote);
        }
    }

    fn visitNode(self: *Survey, node: Node, parent: ?Tag) !void {
        if (node.id) |id| try self.ids_used.put(self.a, try self.a.dupe(u8, id), {});
        if (node.tag == .heading) {
            const text = try inline_mod.getPlainText(self.a, node);
            const id = node.id orelse blk: {
                const generated = try self.generateId(text);
                if (self.current_footnote) |label| {
                    try self.footnote_heading_ids.getPtr(label).?.append(self.a, generated);
                } else {
                    try self.heading_ids.append(self.a, generated);
                }
                break :blk generated;
            };
            if (parent == null) {
                const dest = try std.fmt.allocPrint(self.a, "#{s}", .{id});
                try self.auto_refs.put(self.a, try inline_mod.normalizeLabel(self.a, text), dest);
            }
        }
        for (node.children) |child| try self.visitNode(child, node.tag);
    }

    fn generateId(self: *Survey, text: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        var prev_hyphen = true;
        for (text) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                try buf.append(self.a, c);
                prev_hyphen = false;
            } else if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '-' or c == '_') {
                if (!prev_hyphen and buf.items.len > 0) {
                    try buf.append(self.a, '-');
                    prev_hyphen = true;
                }
            }
        }
        while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') _ = buf.pop();

        var base_id = try buf.toOwnedSlice(self.a);
        if (base_id.len == 0) {
            base_id = try std.fmt.allocPrint(self.a, "s-{d}", .{self.ids_used.count() + 1});
        }

        if (!self.ids_used.contains(base_id)) {
            try self.ids_used.put(self.a, base_id, {});
            return base_id;
        }

        // Ids are only ever added, so the first free suffix is never below the last
        // one handed out for this base; the search resumes there. Candidates are built
        // in a scratch buffer and only the accepted one is kept.
        const next = try self.next_suffix.getOrPut(self.a, base_id);
        if (!next.found_existing) next.value_ptr.* = 1;
        var counter = next.value_ptr.*;
        while (true) : (counter += 1) {
            self.scratch.clearRetainingCapacity();
            try self.scratch.appendSlice(self.a, base_id);
            try self.scratch.append(self.a, '-');
            var digits: [20]u8 = undefined;
            try self.scratch.appendSlice(self.a, try std.fmt.bufPrint(&digits, "{d}", .{counter}));
            if (!self.ids_used.contains(self.scratch.items)) {
                const id = try self.a.dupe(u8, self.scratch.items);
                try self.ids_used.put(self.a, id, {});
                next.value_ptr.* = counter + 1;
                return id;
            }
        }
    }
};

/// Resolves one block against the document: generated ids by ordinal, reference
/// links by label. The resolved tree lives in the allocator passed per block.
pub const Resolver = struct {
    defs: *const Definitions,
    survey: *Survey,
    next_heading: usize = 0,
    /// While an endnote is written: its footnote's generated heading ids, in order.
    footnote_ids: ?[]const []const u8 = null,
    next_footnote_id: usize = 0,

    pub fn resolve(self: *Resolver, ba: Allocator, block: Node) !Node {
        return self.resolveNode(ba, block);
    }

    fn resolveNode(self: *Resolver, ba: Allocator, node: Node) !Node {
        var n = node;
        if (n.tag == .heading and n.id == null) {
            if (self.footnote_ids) |ids| {
                n.id = ids[self.next_footnote_id];
                self.next_footnote_id += 1;
            } else {
                n.id = self.survey.heading_ids.items[self.next_heading];
                self.next_heading += 1;
            }
        }
        if ((n.tag == .link or n.tag == .image) and n.destination == null) {
            if (n.reference) |ref| {
                const raw_label = if (ref.len > 0) ref else (inline_mod.getPlainText(ba, n) catch "");
                const label = inline_mod.normalizeLabel(ba, raw_label) catch raw_label;
                if (self.defs.ref_defs.get(label)) |def| {
                    n.destination = def.url;
                    if (def.attrs) |attrs| n = inline_mod.mergeRefAttrs(n, attrs, ba);
                } else if (self.survey.auto_refs.get(label)) |dest| {
                    n.destination = dest;
                }
            }
        }
        if (n.children.len > 0) {
            const children = try ba.alloc(Node, n.children.len);
            for (n.children, children) |child, *out| out.* = try self.resolveNode(ba, child);
            n.children = children;
        }
        return n;
    }

    /// The footnote definition `label`, resolved like any block (heading ids where the
    /// definition stands, links by label); without blocks when nothing defines it.
    pub fn footnote(self: *Resolver, ba: Allocator, label: []const u8) !Node {
        const def = self.defs.footnote_defs.get(label) orelse return .{ .tag = .footnote, .text = label };
        self.footnote_ids = if (self.survey.footnote_heading_ids.get(label)) |ids| ids.items else &.{};
        defer self.footnote_ids = null;
        self.next_footnote_id = 0;
        const blocks = try ba.alloc(Node, def.blocks.len);
        for (def.blocks, blocks) |block, *out| out.* = try self.resolveNode(ba, block);
        return .{ .tag = .footnote, .text = label, .children = blocks, .start_pos = def.start_pos, .end_pos = def.end_pos };
    }
};

/// The section structure as events, so a consumer can write around headings without
/// building a tree. A heading closes every open section of its level or deeper, opens its own,
/// and moves its id and attributes onto it. Open levels strictly increase, so the
/// stack is at most six deep and one block yields at most eight events.
pub const Sections = struct {
    levels: [6]u8 = undefined,
    depth: usize = 0,
    events: [8]Event = undefined,
    /// Where every section ends when positions are wanted: djot.js closes them all at
    /// the end of the document, whatever heading or input end closed them.
    doc_end: ?SourcePos = null,

    pub const Event = union(enum) {
        /// A section node without children; its id and attributes came from the heading that follows.
        open: Node,
        close,
        block: Node,
    };

    /// The events for one block, valid until the next call.
    pub fn feed(self: *Sections, block: Node) []const Event {
        if (block.tag != .heading) {
            self.events[0] = .{ .block = block };
            return self.events[0..1];
        }
        var n: usize = 0;
        while (self.depth > 0 and self.levels[self.depth - 1] >= block.level) {
            self.depth -= 1;
            self.events[n] = .close;
            n += 1;
        }
        self.levels[self.depth] = block.level;
        self.depth += 1;
        var heading = block;
        heading.id = null;
        heading.attrs = &.{};
        heading.classes = null;
        self.events[n] = .{ .open = .{
            .tag = .section,
            .level = block.level,
            .id = block.id,
            .attrs = block.attrs,
            .classes = block.classes,
            .start_pos = block.start_pos,
            .end_pos = self.doc_end,
        } };
        self.events[n + 1] = .{ .block = heading };
        return self.events[0 .. n + 2];
    }

    /// Closes whatever is still open; valid until the next call.
    pub fn finish(self: *Sections) []const Event {
        var n: usize = 0;
        while (self.depth > 0) : (self.depth -= 1) {
            self.events[n] = .close;
            n += 1;
        }
        return self.events[0..n];
    }
};

test "heading ids: the next free suffix per base, found without a search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var survey = Survey{ .a = arena.allocator() };
    try std.testing.expectEqualStrings("x", try survey.generateId("x"));
    try survey.ids_used.put(survey.a, "x-2", {}); // an explicit id in the way
    try std.testing.expectEqualStrings("x-1", try survey.generateId("x"));
    try std.testing.expectEqualStrings("x-3", try survey.generateId("x"));
    var i: usize = 4;
    while (i < 10_000) : (i += 1) _ = try survey.generateId("x");
    try std.testing.expectEqualStrings("x-10000", try survey.generateId("x"));
    try std.testing.expectEqualStrings("y", try survey.generateId("y"));
}

test "sections: a heading closes deeper and equal levels, then opens its own" {
    var sections = Sections{};
    const h = struct {
        fn at(level: u8) Node {
            return .{ .tag = .heading, .level = level, .id = "x" };
        }
    };
    try std.testing.expectEqual(@as(usize, 2), sections.feed(h.at(1)).len); // open, block
    try std.testing.expectEqual(@as(usize, 1), sections.feed(.{ .tag = .para }).len);
    try std.testing.expectEqual(@as(usize, 2), sections.feed(h.at(3)).len); // nests under 1
    const back_to_two = sections.feed(h.at(2)); // closes 3, not 1
    try std.testing.expectEqual(@as(usize, 3), back_to_two.len);
    try std.testing.expect(back_to_two[0] == .close);
    try std.testing.expect(back_to_two[1] == .open);
    try std.testing.expect(back_to_two[1].open.tag == .section);
    try std.testing.expect(back_to_two[2].block.id == null); // moved onto the section
    try std.testing.expectEqual(@as(usize, 2), sections.finish().len); // closes 2 and 1
}
