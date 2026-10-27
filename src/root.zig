//! Library root: renders Djot to HTML or to the AST text format, block by block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const document = @import("document.zig");
const html = @import("html.zig");
const ast = @import("ast.zig");
const Lines = @import("Lines.zig").Lines;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
const SourcePos = @import("node.zig").SourcePos;

pub const Mode = enum { html, ast };

pub const RenderOpts = struct {
    mode: Mode = .html,
    /// Source positions in the AST output; HTML has none.
    sourcepos: bool = false,
};

/// How deep blocks and inline elements nest at most; deeper is `error.TooDeep`.
pub const max_nesting = document.max_nesting;

/// Renders `input` to `w` one block at a time, reading the input once. Each block is
/// parsed into an arena of its own, given its heading ids, and written as soon as nothing
/// in it can still change: a block holding a reference-style link waits for the input's
/// end, since a later definition replaces an earlier one (djot.js), and under `--ast
/// --sourcepos` a section waits for the heading that closes it, which gives its end. The
/// blocks behind a waiting one are rendered as they arrive and their text waits with it,
/// so the output after the first reference-style link is buffered to the end. What lives
/// for the whole call is the definitions (footnote content included), the ids, the trees
/// of the blocks waiting and the text of those behind them. Output already written stays
/// written if a later block fails. A document nested more than `max_nesting` levels deep
/// is `error.TooDeep`.
pub fn render(a: Allocator, input: []const u8, w: *std.Io.Writer, opts: RenderOpts) !void {
    return renderLines(a, Lines.fromSlice(input), w, opts);
}

/// As `render`, over what `r` yields: the input need not be resident. A line is read into
/// the reader's buffer (one longer than it spills into a buffer of its own), and only what
/// the parser keeps of it outlives the next line, so memory follows the blocks, not the
/// document. A reader without a buffer cannot be read a line at a time:
/// `error.UnbufferedReader`. A read failure is `error.ReadFailed`; the reader says why. An
/// input of 2^64 bytes or lines is `error.InputTooLarge`.
pub fn renderReader(a: Allocator, r: *std.Io.Reader, w: *std.Io.Writer, opts: RenderOpts) !void {
    if (r.buffer.len == 0) return error.UnbufferedReader;
    return renderLines(a, Lines.fromReader(a, r), w, opts);
}

fn renderLines(a: Allocator, lines: Lines, w: *std.Io.Writer, opts: RenderOpts) !void {
    var doc_arena = std.heap.ArenaAllocator.init(a);
    defer doc_arena.deinit();
    const da = doc_arena.allocator();

    var defs = document.Definitions{ .a = da, .gpa = a };
    defer defs.deinit();
    var ids = document.Ids{ .a = da, .gpa = a, .defs = &defs, .scratch = std.heap.ArenaAllocator.init(a) };
    defer ids.deinit();
    var parser = try Parser.init(a, da, lines, &defs);
    defer parser.deinit();
    parser.track_pos = opts.sourcepos;
    var out = Output{
        .a = a,
        .w = w,
        .mode = opts.mode,
        // Only the AST prints a section's end, on its opening line.
        .hold_sections = opts.mode == .ast and opts.sourcepos,
        .parser = &parser,
        .resolver = .{ .defs = &defs, .ids = &ids },
        .footnotes = .{ .a = da },
        .scratch = std.heap.ArenaAllocator.init(a),
    };
    defer out.deinit();
    try out.root();

    var last_end: ?SourcePos = null;
    while (try parser.nextBlock()) |block| {
        var node = block.node;
        const by_reference = ids.assign(&node) catch |err| {
            parser.recycle(block.arena); // `out.block` owns it from here on, failing or not
            return err;
        };
        try out.block(node, block.arena, by_reference);
        last_end = block.last;
    }
    try ids.finish();
    // Where djot.js ends the sections still open at the end: at its last block event,
    // which is the last top-level block's end, except that whatever follows the last
    // block (blank lines, a div's closing fence, definitions, attributes) emits events
    // to the input's end.
    const sections_end = if (last_end == null or parser.trailing()) parser.endPos() else last_end;
    try out.finish(sections_end);
}

/// Writes the section events as output in order, each block rendered on its own: at once
/// when nothing in it can still change, else from a queue that drains from the front as
/// its entries become ready. An entry that waits for nothing itself but stands behind one
/// that does is rendered as it arrives and keeps only its text, so what a wait costs is
/// the waiting block's tree and the output behind it. A block holding a link by reference
/// waits in the arena the parser built it in, given back once it is rendered; a section
/// open waiting for its end keeps copies of what it borrowed from its heading. In HTML,
/// footnotes are numbered in document order whatever waits.
const Output = struct {
    a: Allocator,
    w: *std.Io.Writer,
    mode: Mode,
    /// Whether a section open waits for the heading that closes it, which gives its end.
    hold_sections: bool,
    parser: *Parser,
    resolver: document.Resolver,
    footnotes: html.Footnotes,
    sections: document.Sections = .{},
    queue: std.ArrayList(Pending) = .empty,
    /// The entries before `head` have been written.
    head: usize = 0,
    /// How many entries from `head` on wait for something; while any does, the entries
    /// added behind them are rendered on arrival.
    waiting: usize = 0,
    /// Queue indices of the section opens awaiting their end (`hold_sections`), innermost
    /// last. Valid because a held entry keeps the queue from being emptied and compacted.
    open_sections: std.ArrayList(usize) = .empty,
    /// For rendering what has no arena of its own: the root, section opens, footnotes.
    scratch: std.heap.ArenaAllocator,
    /// AST output: the nesting at the queue's tail, which each entry records as it is
    /// added, since it may be rendered before or after its neighbours.
    indent: usize = 0,

    const Pending = struct {
        wait: enum { none, references, section_end },
        indent: usize,
        what: union(enum) {
            /// Rendered already; owned.
            text: []u8,
            /// A section open awaiting its end, with its own copies of id and attributes.
            section: *HeldSection,
            /// A block in its arena: holding a link by reference, or about to be written.
            block: struct { node: *Node, arena: *std.heap.ArenaAllocator },
            close,
        },
    };

    /// A section open's node with its own copies of the id and attributes it borrows from
    /// its heading, which outlive the heading's arena: `bytes` holds the text, `attrs`
    /// the pairs.
    const HeldSection = struct { node: Node, bytes: []u8, attrs: []node_mod.Attr };

    fn deinit(self: *Output) void {
        for (self.queue.items[self.head..]) |p| self.drop(p);
        self.queue.deinit(self.a);
        self.open_sections.deinit(self.a);
        self.scratch.deinit();
    }

    /// Frees what a written or abandoned entry owns.
    fn drop(self: *Output, p: Pending) void {
        switch (p.what) {
            .text => |text| self.a.free(text),
            .section => |section| self.freeSection(section),
            .block => |b| self.parser.recycle(b.arena),
            .close => {},
        }
    }

    fn root(self: *Output) !void {
        if (self.mode != .ast) return;
        // The AST format names the document and nests every block under it.
        defer _ = self.scratch.reset(.retain_capacity);
        var buf: std.ArrayList(u8) = .empty;
        try ast.renderAstNode(self.scratch.allocator(), &buf, .{ .data = .{ .section = .{} } }, 0, true);
        try self.w.writeAll(buf.items);
        self.indent = 2;
    }

    /// Takes `node`, built in `arena`, with its section events; `by_reference` says it
    /// holds a link by reference, which waits for the definitions.
    fn block(self: *Output, node: Node, arena: *std.heap.ArenaAllocator, by_reference: bool) !void {
        // The arena is the queue's once its block is in; until then a failure returns it.
        var owned = false;
        errdefer if (!owned) self.parser.recycle(arena);
        const events = self.sections.feed(node);
        try self.queue.ensureUnusedCapacity(self.a, events.len);
        if (self.hold_sections) try self.open_sections.ensureUnusedCapacity(self.a, 1);
        for (events) |event| {
            var pending = Pending{ .wait = .none, .indent = self.indent, .what = .close };
            switch (event) {
                .close => {
                    if (self.mode == .ast) self.indent -= 2;
                    // The heading closing a section gives its end.
                    if (self.hold_sections) self.endSection(node.end_pos);
                },
                .open => |section| {
                    if (self.hold_sections) {
                        self.open_sections.appendAssumeCapacity(self.queue.items.len);
                        pending.wait = .section_end;
                        pending.what = .{ .section = try self.ownSection(section) };
                    } else {
                        var open = HeldSection{ .node = section, .bytes = &.{}, .attrs = &.{} };
                        const text = try self.renderText(.{ .section = &open }, pending.indent);
                        pending.what = .{ .text = text };
                    }
                    if (self.mode == .ast) self.indent += 2;
                },
                .block => |b| {
                    const copy = try arena.allocator().create(Node);
                    copy.* = b;
                    pending.what = .{ .block = .{ .node = copy, .arena = arena } };
                    if (by_reference) {
                        pending.wait = .references;
                        // Its footnotes take their numbers now, in document order.
                        if (self.mode == .html) try self.numberFootnotes(b);
                    } else if (self.waiting > 0) {
                        // Behind a waiting entry: rendered now, so its tree can go. (The
                        // text is made before the union is reassigned: the result
                        // location would otherwise alias what is being read.)
                        const text = try self.renderText(pending.what, pending.indent);
                        pending.what = .{ .text = text };
                        self.parser.recycle(arena);
                    }
                    owned = true;
                },
            }
            self.queue.appendAssumeCapacity(pending);
            if (pending.wait != .none) self.waiting += 1;
        }
        try self.drain(false);
    }

    fn endSection(self: *Output, end: ?SourcePos) void {
        const pending = &self.queue.items[self.open_sections.pop().?];
        pending.what.section.node.end_pos = end;
        pending.wait = .none;
        self.waiting -= 1;
    }

    /// `label` as the array index JavaScript orders an object's keys by first: the canonical
    /// decimal of an integer below 2^32 - 1, no sign or leading zero; null for any other key.
    fn jsArrayIndex(label: []const u8) ?u32 {
        if (label.len == 0 or label.len > 10 or (label.len > 1 and label[0] == '0')) return null;
        var v: u64 = 0;
        for (label) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
        }
        return if (v < 4294967295) @intCast(v) else null;
    }

    /// Numbers the footnote references the HTML renderer will write, in its order: an
    /// image's children are its alt text, where a reference is plain text.
    fn numberFootnotes(self: *Output, node: Node) !void {
        if (node.data == .image) return;
        if (node.data == .footnote_reference) _ = try self.footnotes.number(node.data.footnote_reference);
        for (node.children()) |child| try self.numberFootnotes(child);
    }

    /// `section` with its own copies of its id and attributes; `freeSection` takes them back.
    fn ownSection(self: *Output, section: Node) !*HeldSection {
        const held = try self.a.create(HeldSection);
        errdefer self.a.destroy(held);
        var total: usize = if (section.id) |id| id.len else 0;
        for (section.attrs) |attr| total += attr.key.len + attr.value.len;
        const bytes = try self.a.alloc(u8, total);
        errdefer self.a.free(bytes);
        const attrs = try self.a.alloc(node_mod.Attr, section.attrs.len);
        held.* = .{ .node = section, .bytes = bytes, .attrs = attrs };
        var p: usize = 0;
        if (section.id) |id| {
            @memcpy(bytes[p..][0..id.len], id);
            held.node.id = bytes[p..][0..id.len];
            p += id.len;
        }
        for (section.attrs, attrs) |attr, *copy| {
            @memcpy(bytes[p..][0..attr.key.len], attr.key);
            copy.key = bytes[p..][0..attr.key.len];
            p += attr.key.len;
            @memcpy(bytes[p..][0..attr.value.len], attr.value);
            copy.value = bytes[p..][0..attr.value.len];
            p += attr.value.len;
        }
        held.node.attrs = attrs;
        return held;
    }

    fn freeSection(self: *Output, held: *HeldSection) void {
        self.a.free(held.bytes);
        self.a.free(held.attrs);
        self.a.destroy(held);
    }

    /// Writes the entries at the front of the queue that are ready: those waiting for
    /// nothing and, once the input has ended (`final`), those waiting for the definitions.
    fn drain(self: *Output, final: bool) !void {
        while (self.head < self.queue.items.len) : (self.head += 1) {
            const pending = self.queue.items[self.head];
            switch (pending.wait) {
                .none => {},
                .references => {
                    if (!final) break;
                    self.waiting -= 1;
                },
                .section_end => break,
            }
            switch (pending.what) {
                .text => |text| try self.w.writeAll(text),
                .close => if (self.mode == .html) try self.w.writeAll(html.section_close),
                .section, .block => try self.w.writeAll(try self.render(pending.what, pending.indent, pending.wait == .references)),
            }
            self.drop(pending);
        }
        if (self.head == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= self.queue.items.len - self.head) {
            // The written prefix is at least half the queue: its slots are taken back, so
            // a section open that waits for its closing heading (`--ast --sourcepos`)
            // keeps the queue the size of what waits, not of every block written before
            // it. Each move is no longer than what was written since the last.
            const rest = self.queue.items.len - self.head;
            std.mem.copyForwards(Pending, self.queue.items[0..rest], self.queue.items[self.head..]);
            self.queue.shrinkRetainingCapacity(rest);
            for (self.open_sections.items) |*index| index.* -= self.head;
            self.head = 0;
        }
    }

    /// `what` rendered, as text owned by the caller.
    fn renderText(self: *Output, what: @FieldType(Pending, "what"), indent: usize) ![]u8 {
        return switch (what) {
            .text => |text| text,
            .close => try self.a.dupe(u8, if (self.mode == .html) html.section_close else ""),
            else => try self.a.dupe(u8, try self.render(what, indent, false)),
        };
    }

    /// A section open rendered into scratch, or a block into its own arena (resolved
    /// first when it waited for the definitions); valid until the next call or the
    /// arena's return.
    fn render(self: *Output, what: @FieldType(Pending, "what"), indent: usize, resolve: bool) ![]const u8 {
        _ = self.scratch.reset(.retain_capacity);
        const sa = self.scratch.allocator();
        var buf: std.ArrayList(u8) = .empty;
        switch (what) {
            .section => |held| switch (self.mode) {
                .html => try html.renderSectionOpen(sa, &buf, held.node),
                .ast => try ast.renderAstNode(sa, &buf, held.node, indent, false),
            },
            .block => |b| {
                const ba = b.arena.allocator();
                if (resolve) try self.resolver.resolve(ba, b.node);
                switch (self.mode) {
                    .html => {
                        var renderer = html.Renderer{ .a = ba, .out = &buf, .footnotes = &self.footnotes };
                        try renderer.render(b.node.*);
                    },
                    .ast => try ast.renderAstNode(ba, &buf, b.node.*, indent, false),
                }
            },
            .text, .close => unreachable,
        }
        return buf.items;
    }

    /// Closes the sections still open, ending at `sections_end`, writes what waited for
    /// the definitions, then the footnotes.
    fn finish(self: *Output, sections_end: ?SourcePos) !void {
        const events = self.sections.finish();
        try self.queue.ensureUnusedCapacity(self.a, events.len);
        for (events) |_| {
            self.queue.appendAssumeCapacity(.{ .wait = .none, .indent = self.indent, .what = .close });
            if (self.mode == .ast) self.indent -= 2;
            if (self.hold_sections) self.endSection(sections_end);
        }
        try self.drain(true);
        // Once the body has referenced a note (djot.js writes endnotes only then), every
        // definition's references take their numbers before any endnote is written, in the
        // order djot.js walks its definitions object: labels that are array indexes first,
        // ascending, then the rest as they closed. A note first referenced inside another
        // is numbered by where its definition stands in that walk, and one referenced only
        // from a definition nothing references gets an endnote all the same.
        if (self.mode == .html and self.footnotes.order.count() > 0) {
            const labels = self.resolver.defs.footnote_defs.keys();
            const defs = self.resolver.defs.footnote_defs.values();
            var indexes: std.ArrayList(usize) = .empty;
            defer indexes.deinit(self.a);
            for (labels, 0..) |label, i| if (jsArrayIndex(label) != null) try indexes.append(self.a, i);
            std.mem.sort(usize, indexes.items, labels, struct {
                fn lessThan(ls: []const []const u8, x: usize, y: usize) bool {
                    return jsArrayIndex(ls[x]).? < jsArrayIndex(ls[y]).?;
                }
            }.lessThan);
            for (indexes.items) |i| for (defs[i].blocks) |node| try self.numberFootnotes(node);
            for (labels, defs) |label, def| if (jsArrayIndex(label) == null) for (def.blocks) |node| try self.numberFootnotes(node);
        }
        // The footnotes follow the document, each resolved and written in scratch.
        var n: usize = 0;
        while (self.footnoteLabel(n)) |label| : (n += 1) {
            defer _ = self.scratch.reset(.retain_capacity);
            const sa = self.scratch.allocator();
            try self.footnote(sa, n + 1, try self.resolver.footnote(sa, label));
        }
        if (self.mode == .html and self.footnotes.order.count() > 0) try self.w.writeAll(html.endnotes_close);
    }

    /// The label of the `n`-th footnote to write after the document, if there is one: in
    /// HTML the `n`-th referenced (writing an endnote may reference more), in the AST the
    /// `n`-th defined, since the AST prints every definition, as djot.js's JSON holds them.
    fn footnoteLabel(self: *Output, n: usize) ?[]const u8 {
        const labels = switch (self.mode) {
            .html => self.footnotes.order.keys(),
            .ast => self.resolver.defs.footnote_defs.keys(),
        };
        return if (n < labels.len) labels[n] else null;
    }

    /// Footnote `n` (1-based), resolved: endnote `n` in HTML, a `footnote` block in the AST.
    fn footnote(self: *Output, a: Allocator, n: usize, note: Node) !void {
        var buf: std.ArrayList(u8) = .empty;
        switch (self.mode) {
            .html => {
                if (n == 1) try buf.appendSlice(a, html.endnotes_open);
                var renderer = html.Renderer{ .a = a, .out = &buf, .footnotes = &self.footnotes };
                try renderer.renderEndnote(n, note.children());
            },
            .ast => try ast.renderAstNode(a, &buf, note, self.indent, false),
        }
        try self.w.writeAll(buf.items);
    }
};

pub fn toHtml(a: Allocator, input: []const u8) ![]const u8 {
    return renderAlloc(a, input, .{});
}

pub fn toAst(a: Allocator, input: []const u8) ![]const u8 {
    return toAstOpts(a, input, false);
}

pub fn toAstOpts(a: Allocator, input: []const u8, sourcepos: bool) ![]const u8 {
    return renderAlloc(a, input, .{ .mode = .ast, .sourcepos = sourcepos });
}

/// `render` into an owned slice. Only the output is kept on `a` past the call.
fn renderAlloc(a: Allocator, input: []const u8, opts: RenderOpts) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    render(a, input, &out.writer, opts) catch |err| switch (err) {
        // An allocating writer fails only when it cannot grow.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return out.toOwnedSlice();
}

test "nesting deeper than max_nesting levels is error.TooDeep, before any walker recurses into it" {
    const a = std.testing.allocator;
    var written = std.Io.Writer.Allocating.init(a);
    defer written.deinit();
    // The paragraph and its text are two levels under the quotes.
    try std.testing.expectError(error.TooDeep, render(a, ("> " ** (max_nesting - 1)) ++ "x\n", &written.writer, .{}));
    written.clearRetainingCapacity();
    // Inline nesting is caught as the leaf's ids are counted, before any walker.
    try std.testing.expectError(error.TooDeep, render(a, ("[" ** max_nesting) ++ "x" ++ ("]{.c}" ** max_nesting) ++ "\n", &written.writer, .{}));
    written.clearRetainingCapacity();
    // A collapsed reference's label is read off its text only once the text is bounded.
    try std.testing.expectError(error.TooDeep, render(a, ("[" ** max_nesting) ++ "x" ++ ("]{.c}" ** (max_nesting - 1)) ++ "][]\n", &written.writer, .{}));
    written.clearRetainingCapacity();
    // A footnote definition's blocks nest where the definition stands: each heading after
    // an inner definition brings that definition due and re-enters the walk, on one budget.
    const chain = try nestedDefinitions(a, max_nesting + 2);
    defer a.free(chain);
    try std.testing.expectError(error.TooDeep, render(a, chain, &written.writer, .{}));
    written.clearRetainingCapacity();
    const short = try nestedDefinitions(a, 8);
    defer a.free(short);
    try render(a, short, &written.writer, .{});
    try std.testing.expect(written.written().len > 0);
    written.clearRetainingCapacity();
    try render(a, ("> " ** (max_nesting - 2)) ++ "x\n", &written.writer, .{});
    try std.testing.expect(written.written().len > 0);
}

/// `n` footnote definitions each nested in the one before, each but the innermost followed
/// (inside its parent) by a heading, and the outermost referenced from the body.
fn nestedDefinitions(a: std.mem.Allocator, n: usize) ![]u8 {
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    for (0..n) |i| {
        try out.writer.splatByteAll(' ', i);
        try out.writer.print("[^n{d}]:\n\n", .{i});
    }
    var i = n - 1;
    while (i > 0) : (i -= 1) {
        try out.writer.splatByteAll(' ', i - 1);
        try out.writer.print("# h{d}\n\n", .{i - 1});
    }
    try out.writer.writeAll("[^n0]\n");
    return out.toOwnedSlice();
}

test "a block is written as it arrives unless a reference-style link holds it" {
    const a = std.testing.allocator;
    var doc_arena = std.heap.ArenaAllocator.init(a);
    defer doc_arena.deinit();
    const da = doc_arena.allocator();
    var written = std.Io.Writer.Allocating.init(a);
    defer written.deinit();

    const input = "one\n\ntwo [x][r]\n\nthree\n\n[r]: /u\n";
    var defs = document.Definitions{ .a = da, .gpa = a };
    defer defs.deinit();
    var ids = document.Ids{ .a = da, .gpa = a, .defs = &defs, .scratch = std.heap.ArenaAllocator.init(a) };
    defer ids.deinit();
    var parser = try Parser.init(a, da, Lines.fromSlice(input), &defs);
    defer parser.deinit();
    var out = Output{ .a = a, .w = &written.writer, .mode = .html, .hold_sections = false, .parser = &parser, .resolver = .{ .defs = &defs, .ids = &ids }, .footnotes = .{ .a = da }, .scratch = std.heap.ArenaAllocator.init(a) };
    defer out.deinit();

    // The first paragraph is written at once; the second waits for the definitions (a
    // later one may still change its link) and the third waits behind it.
    const first = blk: {
        var block = (try parser.nextBlock()).?;
        try out.block(block.node, block.arena, try ids.assign(&block.node));
        break :blk written.written().len;
    };
    try std.testing.expect(first > 0);
    for (0..2) |_| {
        var block = (try parser.nextBlock()).?;
        try out.block(block.node, block.arena, try ids.assign(&block.node));
        try std.testing.expectEqual(first, written.written().len);
    }
    try std.testing.expectEqual(null, try parser.nextBlock()); // the definition
    try out.finish(null);
    const whole = try toHtml(a, input);
    defer a.free(whole);
    try std.testing.expectEqualStrings(whole, written.written());
}

test "renderReader with a 16-byte buffer matches render over every fixture, in both modes" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buffer: [16]u8 = undefined;
    for ([_][]const u8{ "test/cli", "test/tools/corpus" }) |dir_name| {
        var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_name, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".dj")) continue;
            const input = try dir.readFileAlloc(io, entry.name, a, .limited(1 << 20));
            for ([_]RenderOpts{ .{}, .{ .mode = .ast, .sourcepos = true } }) |opts| {
                var resident = std.Io.Writer.Allocating.init(a);
                try render(a, input, &resident.writer, opts);
                var fixed = std.Io.Reader.fixed(input);
                var limited = fixed.limited(.unlimited, &buffer);
                var streamed = std.Io.Writer.Allocating.init(a);
                try renderReader(a, &limited.interface, &streamed.writer, opts);
                try std.testing.expectEqualStrings(resident.written(), streamed.written());
            }
        }
    }
}

test {
    _ = @import("test_runner.zig");
    _ = @import("Lines.zig");
    _ = @import("LineMap.zig");
    _ = Parser;
    _ = document;
}
