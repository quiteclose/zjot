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
/// caller keeps for the document, whatever allocator the blocks themselves use. The maps
/// and the log grow on `gpa`, which frees a table outgrown; `deinit` frees them.
pub const Definitions = struct {
    a: Allocator,
    gpa: Allocator,
    ref_defs: std.StringArrayHashMapUnmanaged(RefDef) = .{},
    /// By label, the definition that stands: a label defined again replaces the earlier
    /// (djot.js).
    footnote_defs: std.StringArrayHashMapUnmanaged(*FootnoteDef) = .{},
    /// Every footnote definition (a label defined again appearing again with its new
    /// blocks) and every explicit id read off a node, in source order, so `Ids` takes
    /// each where it stands (`Logged`).
    log: std.ArrayList(Logged) = .empty,
    /// Headings parsed so far, footnote content included: where a log entry stands among
    /// them (`Logged.headings_before`).
    headings_parsed: usize = 0,
    /// Explicit ids parsed so far, on blocks (counted before the block's content, where
    /// djot.js registers a block attribute) and on inline nodes (as a leaf closes),
    /// footnote content included, the ones read off a node among them: the ids `Ids`
    /// claims, in its order (`Logged.ids_before`).
    ids_parsed: usize = 0,

    pub fn deinit(self: *Definitions) void {
        self.ref_defs.deinit(self.gpa);
        self.footnote_defs.deinit(self.gpa);
        self.log.deinit(self.gpa);
    }
};

/// A footnote definition's blocks, the block attributes written before it, and, when
/// positions are tracked, its span: from its label to where the next block starts, as djot.js.
pub const FootnoteDef = struct {
    blocks: []const Node,
    attrs: ?BlockAttrs = null,
    start_pos: ?SourcePos = null,
    end_pos: ?SourcePos = null,
};

/// What `Ids` takes where it stands in the source: a footnote definition, whose blocks are
/// assigned there, or an explicit id read off a node, registered there (a replaced
/// caption's, a reference definition's, one a later attribute line on the same block
/// overrode: djot.js registers every id it reads, whether it lands or not). Logged as it
/// starts, with the headings and explicit ids parsed before it, so the log is in source
/// order and what is due is a prefix of it, as djot.js's event order has it. A definition's
/// `footnote` is null while its content is parsed and set as it closes.
pub const Logged = struct {
    headings_before: usize,
    ids_before: usize,
    what: union(enum) { footnote: ?*FootnoteDef, id: []const u8 },
};

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
    /// For the ids and labels kept, which the document's nodes point at.
    a: Allocator,
    /// For the maps, freed by `deinit`.
    gpa: Allocator,
    defs: *const Definitions,
    ids_used: std.StringArrayHashMapUnmanaged(void) = .{},
    /// Normalized heading text to "#id".
    auto_refs: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    /// The next suffix to try for each base id already taken, so a repeated heading
    /// text costs one lookup instead of a search from `-1` (quadratic over a document).
    next_suffix: std.StringArrayHashMapUnmanaged(usize) = .{},
    /// For a heading's text and label while its id is made, and the candidate ids tried.
    scratch: std.heap.ArenaAllocator,
    /// Headings assigned so far, in the parser's count (`Definitions.headings_parsed`).
    assigned_headings: usize = 0,
    /// Explicit ids claimed so far, in the parser's count (`Definitions.ids_parsed`).
    assigned_ids: usize = 0,
    /// The log's first entry not yet taken: those before it are.
    cursor: usize = 0,

    pub fn deinit(self: *Ids) void {
        self.ids_used.deinit(self.gpa);
        self.auto_refs.deinit(self.gpa);
        self.next_suffix.deinit(self.gpa);
        self.scratch.deinit();
    }

    /// Takes the log's entries that are due: the log is in source order, so those due are
    /// a prefix of it, up to the first definition still open or the first standing after a
    /// heading or an explicit id not yet assigned (no more headings and explicit ids were
    /// parsed before a due one than have been assigned). A definition's blocks are assigned,
    /// an id read off a node is registered. Called before each block, each heading and each
    /// explicit id, so a definition's headings and an id read off a node take their place
    /// where they stand, as djot.js registers in source order; `finish` takes what is left
    /// at the end. Each entry is looked at once as it comes due, however many headings a
    /// document's definitions hold.
    pub fn assignDue(self: *Ids) Allocator.Error!void {
        const log = self.defs.log.items;
        while (self.cursor < log.len) {
            const entry = log[self.cursor];
            if (entry.headings_before > self.assigned_headings or entry.ids_before > self.assigned_ids) break;
            switch (entry.what) {
                .footnote => |closed| {
                    const def = closed orelse break; // still open: what follows is inside it
                    self.cursor += 1;
                    try self.assignDef(def);
                },
                .id => |id| {
                    self.cursor += 1;
                    try self.register(id);
                },
            }
        }
    }

    /// A definition's own id (the block attributes written before it, which djot.js
    /// registers where they stand), then its blocks, which the parser built for it alone.
    fn assignDef(self: *Ids, def: *FootnoteDef) Allocator.Error!void {
        if (def.attrs) |attrs| {
            if (attrs.id) |id| try self.claim(id);
        }
        for (@constCast(def.blocks)) |*block| _ = try self.assignNode(block);
    }

    /// An explicit id on a node, reached: what stands before it in the source takes its
    /// place first.
    fn claim(self: *Ids, id: []const u8) Allocator.Error!void {
        try self.assignDue();
        try self.register(id);
    }

    /// Counts and keeps an explicit id.
    fn register(self: *Ids, id: []const u8) Allocator.Error!void {
        self.assigned_ids += 1;
        const seen = try self.ids_used.getOrPut(self.gpa, id);
        if (!seen.found_existing) seen.key_ptr.* = try self.a.dupe(u8, id);
    }

    /// After the last block: every entry left, in log order, whatever the counts say (every
    /// definition has closed, so none may be left).
    pub fn finish(self: *Ids) Allocator.Error!void {
        try self.assignDue();
        const log = self.defs.log.items;
        while (self.cursor < log.len) {
            const entry = log[self.cursor];
            self.cursor += 1;
            switch (entry.what) {
                .footnote => |closed| try self.assignDef(closed.?),
                .id => |id| try self.register(id),
            }
        }
    }

    /// Sets every heading's id in `block` and claims its implicit reference, assigning
    /// the footnote definitions that stand among its headings where they stand. Writes
    /// into the tree, which the parser built for this block alone. Returns whether the
    /// block holds a link or image by reference, which the definitions may still change
    /// until the input ends (what `Resolver.resolve` fills in).
    pub fn assign(self: *Ids, block: *Node) Allocator.Error!bool {
        // What is due stands before this block in the source.
        try self.assignDue();
        return self.assignNode(block);
    }

    fn assignNode(self: *Ids, n: *Node) Allocator.Error!bool {
        if (n.id) |id| try self.claim(id);
        var by_reference = switch (n.data) {
            .link, .image => |l| l.reference != null and l.destination == null,
            else => false,
        };
        if (n.data == .heading) {
            try self.assignDue();
            self.assigned_headings += 1;
            _ = self.scratch.reset(.retain_capacity);
            const text = try inline_mod.getPlainText(self.scratch.allocator(), n.*);
            if (n.id == null) n.id = try self.generate(text);
            const label = try inline_mod.normalizeLabel(self.scratch.allocator(), text);
            if (!self.auto_refs.contains(label)) {
                const dest = try std.fmt.allocPrint(self.a, "#{s}", .{n.id.?});
                try self.auto_refs.put(self.gpa, try self.a.dupe(u8, label), dest);
            }
        }
        // A table holds its caption first, as it is written, but the caption stands after
        // the rows in the source, where the parser counted its ids: the rows claim theirs first.
        if (n.data == .table and n.data.table.len > 0) {
            const t = @constCast(n.data.table);
            for (t[1..]) |*row| {
                if (try self.assignNode(row)) by_reference = true;
            }
            if (try self.assignNode(&t[0])) by_reference = true;
            return by_reference;
        }
        for (@constCast(n.children())) |*child| {
            if (try self.assignNode(child)) by_reference = true;
        }
        return by_reference;
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

        var base_id: []const u8 = try buf.toOwnedSlice(self.a);
        // No text: `s-1`, `s-2`, ..., the first free, as djot.js (never `s` itself).
        const empty = base_id.len == 0;
        if (empty) base_id = "s";

        if (!empty and !self.ids_used.contains(base_id)) {
            try self.ids_used.put(self.gpa, base_id, {});
            return base_id;
        }

        // Ids are only ever added, so the first free suffix is never below the last
        // one handed out for this base; the search resumes there. Candidates are built
        // in scratch and only the accepted one is kept.
        const next = try self.next_suffix.getOrPut(self.gpa, base_id);
        if (!next.found_existing) next.value_ptr.* = 1;
        var counter = next.value_ptr.*;
        while (true) : (counter += 1) {
            const candidate = try std.fmt.allocPrint(self.scratch.allocator(), "{s}-{d}", .{ base_id, counter });
            if (!self.ids_used.contains(candidate)) {
                const id = try self.a.dupe(u8, candidate);
                try self.ids_used.put(self.gpa, id, {});
                next.value_ptr.* = counter + 1;
                return id;
            }
        }
    }
};

/// Resolves one block against the definitions, once they are final: a link or image
/// written by reference takes a definition's destination and attributes, else the target
/// the heading with that text claimed. Writes into the tree, which is the block's alone;
/// `ba` is the block's allocator, for what the labels and merged attributes need.
pub const Resolver = struct {
    defs: *const Definitions,
    ids: *const Ids,

    pub fn resolve(self: *const Resolver, ba: Allocator, block: *Node) !void {
        return self.resolveNode(ba, block);
    }

    fn resolveNode(self: *const Resolver, ba: Allocator, n: *Node) Allocator.Error!void {
        switch (n.data) {
            .link, .image => |*l| if (l.destination == null) if (l.reference) |ref| {
                const raw_label = if (ref.len > 0) ref else (inline_mod.getPlainText(ba, n.*) catch "");
                const label = inline_mod.normalizeLabel(ba, raw_label) catch raw_label;
                if (self.defs.ref_defs.get(label)) |def| {
                    l.destination = def.url;
                    if (def.attrs) |attrs| n.* = try inline_mod.mergeRefAttrs(n.*, attrs, ba);
                } else if (self.ids.auto_refs.get(label)) |dest| {
                    l.destination = dest;
                }
            },
            else => {},
        }
        for (@constCast(n.children())) |*child| try self.resolveNode(ba, child);
    }

    /// The footnote definition `label`, its links resolved; without blocks when nothing
    /// defines it.
    pub fn footnote(self: *const Resolver, ba: Allocator, label: []const u8) !Node {
        const def = self.defs.footnote_defs.get(label) orelse return .{ .data = .{ .footnote = .{ .label = label } } };
        for (@constCast(def.blocks)) |*block| try self.resolveNode(ba, block);
        const n = Node{ .data = .{ .footnote = .{ .label = label, .children = def.blocks } }, .start_pos = def.start_pos, .end_pos = def.end_pos };
        return if (def.attrs) |attrs| try inline_mod.applyBlockAttrsToNode(ba, n, attrs) else n;
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
        if (block.data != .heading) {
            self.events[0] = .{ .block = block };
            return self.events[0..1];
        }
        const level = block.data.heading.level;
        var n: usize = 0;
        while (self.depth > 0 and self.levels[self.depth - 1] >= level) {
            self.depth -= 1;
            self.events[n] = .close;
            n += 1;
        }
        self.levels[self.depth] = level;
        self.depth += 1;
        var heading = block;
        heading.id = null;
        heading.attrs = &.{};
        self.events[n] = .{ .open = .{
            .data = .{ .section = .{ .level = level } },
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
    const defs = Definitions{ .a = arena.allocator(), .gpa = std.testing.allocator };
    var ids = Ids{ .a = arena.allocator(), .gpa = std.testing.allocator, .defs = &defs, .scratch = .init(std.testing.allocator) };
    defer ids.deinit();
    try std.testing.expectEqualStrings("x", try ids.generate("x"));
    try ids.ids_used.put(ids.gpa, "x-2", {}); // an explicit id in the way
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
            return .{ .data = .{ .heading = .{ .level = level } }, .id = "x" };
        }
    };
    try std.testing.expectEqual(@as(usize, 2), sections.feed(h.at(1)).len); // open, block
    try std.testing.expectEqual(@as(usize, 1), sections.feed(.{ .data = .{ .para = &.{} } }).len);
    try std.testing.expectEqual(@as(usize, 2), sections.feed(h.at(3)).len); // nests under 1
    const back_to_two = sections.feed(h.at(2)); // closes 3, not 1
    try std.testing.expectEqual(@as(usize, 3), back_to_two.len);
    try std.testing.expect(back_to_two[0] == .close);
    try std.testing.expect(back_to_two[1] == .open);
    try std.testing.expect(back_to_two[1].open.data == .section);
    try std.testing.expect(back_to_two[2].block.id == null); // moved onto the section
    try std.testing.expectEqual(@as(usize, 2), sections.finish().len); // closes 2 and 1
}
