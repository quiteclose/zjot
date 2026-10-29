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
/// How deep blocks and inline elements nest at most: a node's depth in its block's tree,
/// the top-level block at 1, a footnote definition a level where it stands with its blocks
/// under it. The parser alone checks it (no node is made past it: no container, no row,
/// cell or term, and a leaf's inlines are counted from the leaf's depth); `Ids` walks a
/// definition from where it stands (`takeDue`), so no walk recurses deeper. The tree
/// walkers (`Ids.assignNode`, the resolver, the renderers) recurse once per level, and a
/// Debug build's 16 MiB stack holds about 1250 of the largest frames; djot.js fails near
/// 1400.
pub const max_nesting = 1000;

pub const Logged = struct {
    headings_before: usize,
    ids_before: usize,
    /// A footnote definition's depth where it stands (its blocks one under), for `Ids` to
    /// walk it from there; an id read off a node has none.
    depth: usize = 0,
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
    /// an id read off a node is registered, so each takes its place where it stands, as
    /// djot.js registers in source order; `finish` takes what is left at the end. Each
    /// entry is looked at once as it comes due.
    ///
    /// A definition is taken where it stands: `depth` is the depth of the nodes the walk
    /// is between, and a definition is taken there only when it stands at that depth, so
    /// its blocks are walked from no deeper than the source nests them. The walk calls this
    /// before and after every child, so it passes each definition's depth after the
    /// definition and before anything that stands after it; a claim (`depth` null) finds
    /// every due definition taken, since what stands after one below its depth is reached
    /// only through containers that open after it. Two nodes are written out of their
    /// source order, and each follows a pass where what stood before it stands: a table's
    /// caption (at the table's depth) and a definition item's term (at the definition's).
    fn takeDue(self: *Ids, depth: ?usize) Error!void {
        const log = self.defs.log.items;
        while (self.cursor < log.len) {
            const entry = log[self.cursor];
            if (entry.headings_before > self.assigned_headings or entry.ids_before > self.assigned_ids) break;
            switch (entry.what) {
                .footnote => |closed| {
                    const def = closed orelse break; // still open: what follows is inside it
                    if (depth) |d| if (d != entry.depth) break;
                    std.debug.assert(depth != null);
                    self.cursor += 1;
                    try self.assignDef(def, entry.depth);
                },
                .id => |id| {
                    self.cursor += 1;
                    try self.register(id);
                },
            }
        }
    }

    /// A definition's own id (the block attributes written before it, which djot.js
    /// registers where they stand), then its blocks, one under its `depth`, which the
    /// parser built for it alone.
    fn assignDef(self: *Ids, def: *FootnoteDef, depth: usize) Error!void {
        if (def.attrs) |attrs| {
            if (attrs.id) |id| try self.claim(id);
        }
        _ = try self.assignChildren(@constCast(def.blocks), depth + 1, self.defs.a);
    }

    /// An explicit id on a node, reached: what stands before it in the source takes its
    /// place first.
    fn claim(self: *Ids, id: []const u8) Error!void {
        try self.takeDue(null);
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
    pub fn finish(self: *Ids) Error!void {
        try self.takeDue(1);
        const log = self.defs.log.items;
        while (self.cursor < log.len) {
            const entry = log[self.cursor];
            self.cursor += 1;
            switch (entry.what) {
                .footnote => |closed| try self.assignDef(closed.?, entry.depth),
                .id => |id| try self.register(id),
            }
        }
    }

    /// Sets every heading's id in `block` and claims its implicit reference, assigning
    /// the footnote definitions that stand among its headings where they stand. Writes
    /// into the tree, which the parser built for this block alone. Returns whether the
    /// block holds a link or image by reference, which the definitions may still change
    /// until the input ends (what `Resolver.resolve` fills in).
    pub const Error = Allocator.Error;

    /// `a` is the block's own allocator, for a generated id's place on its node.
    pub fn assign(self: *Ids, block: *Node, a: Allocator) Error!bool {
        // What is due stands before this block in the source.
        try self.takeDue(1);
        return self.assignNode(block, 1, a);
    }

    /// `nodes`, at `depth`, with what is due taken before and after each.
    fn assignChildren(self: *Ids, nodes: []Node, depth: usize, a: Allocator) Error!bool {
        var by_reference = false;
        for (nodes) |*child| {
            try self.takeDue(depth);
            if (try self.assignNode(child, depth, a)) by_reference = true;
        }
        try self.takeDue(depth);
        return by_reference;
    }

    fn assignNode(self: *Ids, n: *Node, depth: usize, a: Allocator) Error!bool {
        std.debug.assert(depth <= max_nesting); // the parser refuses anything deeper
        if (n.id()) |id| try self.claim(id);
        var by_reference = switch (n.data) {
            // An empty label resolves to nothing, so nothing waits for it (`Resolver`).
            .link, .image => |l| l.destination == null and if (l.reference) |r| r.len > 0 else false,
            else => false,
        };
        if (n.data == .heading) {
            // Its inline ids come first, as the parser counted them (djot.js registers an
            // attribute's id as it is read, the heading's own as the heading ends).
            for (@constCast(n.children())) |*child| {
                if (try self.assignNode(child, depth + 1, a)) by_reference = true;
            }
            try self.takeDue(null);
            self.assigned_headings += 1;
            _ = self.scratch.reset(.retain_capacity);
            const text = try inline_mod.getPlainText(self.scratch.allocator(), n.*);
            if (n.id() == null) n.* = try n.withId(a, try self.generate(text));
            const label = try inline_mod.normalizeLabel(self.scratch.allocator(), text);
            if (!self.auto_refs.contains(label)) {
                const dest = try std.fmt.allocPrint(self.a, "#{s}", .{n.id().?});
                try self.auto_refs.put(self.gpa, try self.a.dupe(u8, label), dest);
            }
            return by_reference;
        }
        // A definition written first in an item stands before the paragraph after it,
        // which the item's close made its term and which is walked first.
        if (n.data == .definition_list_item) try self.takeDue(depth + 2);
        // A table holds its caption first, as it is written, but the caption stands after
        // the rows in the source, where the parser counted its ids: the rows claim theirs first.
        if (n.data == .table and n.data.table.len > 0) {
            const t = @constCast(n.data.table);
            for (t[1..]) |*row| {
                if (try self.assignNode(row, depth + 1, a)) by_reference = true;
            }
            // What stood between the table and its caption stands at the table's depth.
            try self.takeDue(depth);
            if (try self.assignNode(&t[0], depth + 1, a)) by_reference = true;
            return by_reference;
        }
        if (try self.assignChildren(@constCast(n.children()), depth + 1, a)) by_reference = true;
        return by_reference;
    }

    /// djot.js's id separators: `[]~!@#$%^&*(){}`,.<>\|=+/?` and whitespace.
    fn isIdSeparator(c: u8) bool {
        return switch (c) {
            '[', ']', '~', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '{', '}', '`', ',', '.', '<', '>', '\\', '|', '=', '+', '/', '?', ' ', '\t', '\n', '\r' => true,
            else => false,
        };
    }

    /// The length of the separator at `i` of `text`, 0 when none: djot.js's punctuation
    /// set and what JavaScript's `\s` matches (`inline.jsSpaceLen`).
    fn separatorLen(text: []const u8, i: usize) usize {
        if (isIdSeparator(text[i])) return 1;
        return inline_mod.jsSpaceLen(text, i);
    }

    /// As djot.js's `getUniqueIdentifier`: a run of separators (its punctuation set and
    /// whitespace) becomes one `-`, none at either end; every other byte stays, `_`, `:`,
    /// `-` and non-ASCII included.
    fn generate(self: *Ids, text: []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        var separated = false;
        var i: usize = 0;
        while (i < text.len) {
            const n = separatorLen(text, i);
            if (n > 0) {
                separated = true;
                i += n;
            } else {
                if (separated and buf.items.len > 0) try buf.append(self.a, '-');
                separated = false;
                try buf.append(self.a, text[i]);
                i += 1;
            }
        }

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
/// `ba` is the block's allocator, for what the labels and merged attributes need, and a
/// footnote definition's content is resolved on the definitions' own, as it lives there.
pub const Resolver = struct {
    defs: *const Definitions,
    ids: *const Ids,

    pub fn resolve(self: *const Resolver, ba: Allocator, block: *Node) !void {
        return self.resolveNode(ba, block);
    }

    fn resolveNode(self: *const Resolver, ba: Allocator, n: *Node) Allocator.Error!void {
        switch (n.data) {
            // Keyed as parsed: normalized, an empty `[]` already the link's text. A label
            // that is empty still resolves to nothing, as djot.js tests the label's truth.
            .link, .image => |*l| if (l.destination == null) if (l.reference) |label| if (label.len > 0) {
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
        for (@constCast(def.blocks)) |*block| try self.resolveNode(self.defs.a, block);
        const n = try (Node{ .data = .{ .footnote = .{ .label = label, .children = def.blocks } } }).withSpan(ba, def.start_pos, def.end_pos);
        return if (def.attrs) |attrs| try inline_mod.applyBlockAttrsToNode(ba, n, attrs) else n;
    }
};

/// The section structure as events, so a consumer can write around headings without
/// building a tree. A heading closes every open section of its level or deeper, opens its own,
/// and moves its id onto it, and its written attributes only when they hold an id (djot.js
/// moves `attributes` with the id in them, and the generated id alone). Open levels strictly increase, so the
/// stack is at most six deep and one block yields at most eight events. A section's
/// positions are the consumer's to give: it starts where its heading does, and ends where
/// the heading that closes it ends, as djot.js (`parse.js` pops sections at the
/// `-heading` event), or at the document's end.
pub const Sections = struct {
    levels: [6]u8 = undefined,
    depth: usize = 0,
    events: [8]Event = undefined,

    pub const Event = union(enum) {
        /// A section node without children or positions; its id and attributes came from
        /// the heading that follows, its positions are the consumer's to give.
        open: Node,
        close,
        block: Node,
    };

    /// The events for one block, valid until the next call. The marks a heading's id and
    /// attributes move into (the section's and the heading copy's) are made on `a`, the
    /// block's allocator: a consumer keeping the section past the block copies them.
    pub fn feed(self: *Sections, a: Allocator, block: Node) Allocator.Error![]const Event {
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
        const explicit = for (block.attrs()) |attr| {
            if (std.mem.eql(u8, attr.key, "id") and attr.value.len > 0) break true;
        } else false;
        const heading = try block.withMarks(a, null, if (explicit) &.{} else block.attrs());
        const section = try (Node{ .data = .{ .section = .{ .level = level } } }).withMarks(a, block.id(), if (explicit) block.attrs() else &.{});
        self.events[n] = .{ .open = section };
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sections = Sections{};
    const h = struct {
        fn at(level: u8) Node {
            return .{ .data = .{ .heading = .{ .level = level } }, .marks = &Node.Marks{ .id = "x" } };
        }
    };
    try std.testing.expectEqual(@as(usize, 2), (try sections.feed(arena.allocator(), h.at(1))).len); // open, block
    try std.testing.expectEqual(@as(usize, 1), (try sections.feed(arena.allocator(), .{ .data = .{ .para = &.{} } })).len);
    try std.testing.expectEqual(@as(usize, 2), (try sections.feed(arena.allocator(), h.at(3))).len); // nests under 1
    const back_to_two = try sections.feed(arena.allocator(), h.at(2)); // closes 3, not 1
    try std.testing.expectEqual(@as(usize, 3), back_to_two.len);
    try std.testing.expect(back_to_two[0] == .close);
    try std.testing.expect(back_to_two[1] == .open);
    try std.testing.expect(back_to_two[1].open.data == .section);
    try std.testing.expect(back_to_two[2].block.id() == null); // moved onto the section
    try std.testing.expectEqual(@as(usize, 2), sections.finish().len); // closes 2 and 1
}
