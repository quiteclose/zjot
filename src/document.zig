//! Document-level concerns, kept apart from the block parser by lifetime: what block
//! syntax defines for the whole document (`Definitions`), what one block needs from the
//! rest of it (`Ids`, `Resolver`) and the section structure that headings imply
//! (`Sections`). The input is read once: each block gets its ids as it arrives, and a
//! block that refers to a definition is resolved when the definitions are final.
//! Everything that outlives a block lives in the allocator the consumer keeps for the
//! document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const SourcePos = node_mod.SourcePos;
const inline_mod = @import("inline.zig");
const BlockAttrs = @import("attributes.zig").BlockAttrs;

/// What block-level syntax defines for the whole document: reference link definitions
/// and footnote definitions. A block anywhere may use a definition from anywhere, so
/// they outlive any one block: everything stored here is allocated from `a`, which the
/// caller keeps for the document, whatever allocator the blocks themselves use.
/// Shared by pointer with child parsers so a definition inside a container is seen.
pub const Definitions = struct {
    a: Allocator,
    ref_defs: std.StringArrayHashMapUnmanaged(RefDef) = .{},
    /// By label, the definition that stands: a label defined again replaces the earlier
    /// (djot.js).
    footnote_defs: std.StringArrayHashMapUnmanaged(*FootnoteDef) = .{},
    /// Every footnote definition in document order, a label defined again appearing
    /// again with its new blocks, so `Ids` assigns each where it stands.
    footnote_log: std.ArrayList(LoggedFootnote) = .empty,
    /// Headings parsed so far, footnote content included: where a footnote stands among
    /// them (`LoggedFootnote.headings_before`).
    headings_parsed: usize = 0,
};

/// A footnote definition's blocks and, when positions are tracked, its span: from its
/// label to where the next block starts, as djot.js.
pub const FootnoteDef = struct {
    blocks: []const Node,
    start_pos: ?SourcePos = null,
    end_pos: ?SourcePos = null,
};

/// `headings_before`: the headings parsed before the definition started, so `Ids` assigns
/// its headings after those and before the next, as djot.js's event order has it.
pub const LoggedFootnote = struct { label: []const u8, def: *FootnoteDef, headings_before: usize };

pub const RefDef = struct {
    url: []const u8,
    attrs: ?BlockAttrs = null,
};

/// Generated heading ids and the implicit link targets that headings provide, assigned to
/// each top-level block as it arrives and to each footnote definition where it stands, in
/// document order. As djot.js: every heading gets an id when it closes, each generated id
/// avoiding every id seen so far, explicit ones included; the first heading with a text
/// claims it as an implicit reference (djot.js also skips a label a definition has, which
/// a definition wins anyway). Nothing later changes an id, so a block's ids are final when
/// the block is.
pub const Ids = struct {
    a: Allocator,
    defs: *const Definitions,
    ids_used: std.StringArrayHashMapUnmanaged(void) = .{},
    /// Normalized heading text to "#id".
    auto_refs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    /// The next suffix to try for each base id already taken, so a repeated heading
    /// text costs one lookup instead of a search from `-1` (quadratic over a document).
    next_suffix: std.StringArrayHashMapUnmanaged(usize) = .{},
    scratch: std.ArrayList(u8) = .empty,
    /// Headings assigned so far, in the parser's count (`Definitions.headings_parsed`).
    assigned_headings: usize = 0,
    assigned_footnotes: usize = 0,

    /// Assigns the footnote definitions logged but not yet assigned that stand before the
    /// next heading: the ones no more headings were parsed before than have been assigned.
    /// Their trees are rebuilt in the definitions' allocator. Called before each heading
    /// and after each block, so after the last block it assigns every definition left.
    pub fn assignFootnotes(self: *Ids) Allocator.Error!void {
        const log = self.defs.footnote_log.items;
        while (self.assigned_footnotes < log.len and log[self.assigned_footnotes].headings_before <= self.assigned_headings) {
            const def = log[self.assigned_footnotes].def;
            self.assigned_footnotes += 1;
            const blocks = try self.defs.a.alloc(Node, def.blocks.len);
            for (def.blocks, blocks) |block, *out| out.* = try self.assignNode(self.defs.a, block);
            def.blocks = blocks;
        }
    }

    /// `block` with every heading's id set and its implicit reference claimed, the
    /// footnote definitions that stand among its headings assigned where they stand; the
    /// tree is rebuilt in `a` along the way.
    pub fn assign(self: *Ids, a: Allocator, block: Node) !Node {
        const assigned = try self.assignNode(a, block);
        try self.assignFootnotes();
        return assigned;
    }

    fn assignNode(self: *Ids, a: Allocator, node: Node) Allocator.Error!Node {
        var n = node;
        if (n.id) |id| try self.ids_used.put(self.a, try self.a.dupe(u8, id), {});
        if (n.tag == .heading) {
            try self.assignFootnotes();
            self.assigned_headings += 1;
            const text = try inline_mod.getPlainText(a, n);
            if (n.id == null) n.id = try self.generate(text);
            const label = try inline_mod.normalizeLabel(a, text);
            if (!self.auto_refs.contains(label)) {
                const dest = try std.fmt.allocPrint(self.a, "#{s}", .{n.id.?});
                try self.auto_refs.put(self.a, try self.a.dupe(u8, label), dest);
            }
        }
        if (n.children.len > 0) {
            const children = try a.alloc(Node, n.children.len);
            for (n.children, children) |child, *out| out.* = try self.assignNode(a, child);
            n.children = children;
        }
        return n;
    }

    fn generate(self: *Ids, text: []const u8) ![]const u8 {
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
            try self.scratch.appendSlice(self.a, std.fmt.bufPrint(&digits, "{d}", .{counter}) catch unreachable); // 20 digits hold any usize
            if (!self.ids_used.contains(self.scratch.items)) {
                const id = try self.a.dupe(u8, self.scratch.items);
                try self.ids_used.put(self.a, id, {});
                next.value_ptr.* = counter + 1;
                return id;
            }
        }
    }
};

/// Resolves one block against the definitions, once they are final: a link or image
/// written by reference takes a definition's destination and attributes, else the target
/// the heading with that text claimed. The resolved tree lives in the allocator passed
/// per block.
pub const Resolver = struct {
    defs: *const Definitions,
    ids: *const Ids,

    /// Whether `resolve` would change `node`: it holds a link or image by reference, which
    /// a definition may still change until the input ends.
    pub fn touches(node: Node) bool {
        if ((node.tag == .link or node.tag == .image) and node.reference != null and node.destination == null) return true;
        for (node.children) |child| if (touches(child)) return true;
        return false;
    }

    pub fn resolve(self: *const Resolver, ba: Allocator, block: Node) !Node {
        return self.resolveNode(ba, block);
    }

    fn resolveNode(self: *const Resolver, ba: Allocator, node: Node) !Node {
        var n = node;
        if ((n.tag == .link or n.tag == .image) and n.destination == null) {
            if (n.reference) |ref| {
                const raw_label = if (ref.len > 0) ref else (inline_mod.getPlainText(ba, n) catch "");
                const label = inline_mod.normalizeLabel(ba, raw_label) catch raw_label;
                if (self.defs.ref_defs.get(label)) |def| {
                    n.destination = def.url;
                    if (def.attrs) |attrs| n = try inline_mod.mergeRefAttrs(n, attrs, ba);
                } else if (self.ids.auto_refs.get(label)) |dest| {
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

    /// The footnote definition `label`, its links resolved; without blocks when nothing
    /// defines it.
    pub fn footnote(self: *const Resolver, ba: Allocator, label: []const u8) !Node {
        const def = self.defs.footnote_defs.get(label) orelse return .{ .tag = .footnote, .text = label };
        const blocks = try ba.alloc(Node, def.blocks.len);
        for (def.blocks, blocks) |block, *out| out.* = try self.resolveNode(ba, block);
        return .{ .tag = .footnote, .text = label, .children = blocks, .start_pos = def.start_pos, .end_pos = def.end_pos };
    }
};

/// The section structure as events, so a consumer can write around headings without
/// building a tree. A heading closes every open section of its level or deeper, opens its own,
/// and moves its id and attributes onto it. Open levels strictly increase, so the
/// stack is at most six deep and one block yields at most eight events. A section's end
/// is the consumer's to fill in when it closes: where the heading that closes it ends, as
/// djot.js (`parse.js` pops sections at the `-heading` event), or the document's end.
pub const Sections = struct {
    levels: [6]u8 = undefined,
    depth: usize = 0,
    events: [8]Event = undefined,

    pub const Event = union(enum) {
        /// A section node without children or end; its id and attributes came from the heading that follows.
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
        self.events[n] = .{ .open = .{
            .tag = .section,
            .level = block.level,
            .id = block.id,
            .attrs = block.attrs,
            .start_pos = block.start_pos,
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
    const defs = Definitions{ .a = arena.allocator() };
    var ids = Ids{ .a = arena.allocator(), .defs = &defs };
    try std.testing.expectEqualStrings("x", try ids.generate("x"));
    try ids.ids_used.put(ids.a, "x-2", {}); // an explicit id in the way
    try std.testing.expectEqualStrings("x-1", try ids.generate("x"));
    try std.testing.expectEqualStrings("x-3", try ids.generate("x"));
    var i: usize = 4;
    while (i < 10_000) : (i += 1) _ = try ids.generate("x");
    try std.testing.expectEqualStrings("x-10000", try ids.generate("x"));
    try std.testing.expectEqualStrings("y", try ids.generate("y"));
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
