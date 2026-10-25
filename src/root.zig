//! Library root: renders Djot to HTML or to the AST text format, block by block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const document = @import("document.zig");
const html = @import("html.zig");
const ast = @import("ast.zig");
const Lines = @import("Lines.zig").Lines;
const Node = @import("node.zig").Node;
const SourcePos = @import("node.zig").SourcePos;

pub const Mode = enum { html, ast };

pub const RenderOpts = struct {
    mode: Mode = .html,
    /// Source positions in the AST output; HTML has none.
    sourcepos: bool = false,
};

/// Renders `input` to `w` one block at a time, reading the input once. Each block is
/// parsed into an arena of its own, given its heading ids, and written as soon as nothing
/// in it can still change: a block holding a reference-style link waits for the input's
/// end, since a later definition replaces an earlier one (djot.js), and under `--ast
/// --sourcepos` a section waits for the heading that closes it, which gives its end. The
/// blocks behind a waiting one wait with it, so the output after the first reference-style
/// link is buffered to the end. What lives for the whole call is the definitions
/// (footnote content included), the ids, and the blocks waiting. Output already written
/// stays written if a later block fails.
pub fn render(a: Allocator, input: []const u8, w: *std.Io.Writer, opts: RenderOpts) !void {
    var doc_arena = std.heap.ArenaAllocator.init(a);
    defer doc_arena.deinit();
    const da = doc_arena.allocator();

    var defs = document.Definitions{ .a = da };
    var ids = document.Ids{ .a = da, .defs = &defs, .scratch = std.heap.ArenaAllocator.init(a) };
    defer ids.scratch.deinit();
    var parser = try Parser.init(a, da, Lines.fromSlice(input), &defs);
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
        const by_reference = try ids.assign(&node);
        try out.block(node, block.arena, by_reference);
        last_end = node.end_pos;
    }
    try ids.assignFootnotes();
    // Where djot.js ends the sections still open at the end: at its last block event,
    // which is the last top-level block's end, except that whatever follows the last
    // block (blank lines, a div's closing fence, definitions, attributes) emits events
    // to the input's end.
    const sections_end = if (last_end == null or parser.trailing()) parser.endPos() else last_end;
    try out.finish(sections_end);
}

/// Writes the section events as output in order, each block rendered on its own: at once
/// when nothing in it can still change, else from a queue that drains from the front as
/// its entries become ready. A block's nodes live in the arena the parser built it in,
/// which the queue keeps until the block is written and then gives back.
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
    /// Queue indices of the section opens awaiting their end (`hold_sections`), innermost
    /// last. Valid because a held entry keeps the queue from being emptied and compacted.
    open_sections: std.ArrayList(usize) = .empty,
    /// For rendering what has no block arena: the root, the section opens, the footnotes.
    scratch: std.heap.ArenaAllocator,
    /// AST output: the current nesting.
    indent: usize = 0,

    const Pending = struct {
        event: document.Sections.Event,
        /// A block's arena; section opens and closes have none.
        arena: ?*std.heap.ArenaAllocator,
        wait: enum { none, references, section_end },
    };

    fn deinit(self: *Output) void {
        for (self.queue.items[self.head..]) |p| if (p.arena) |arena| self.parser.recycle(arena);
        self.queue.deinit(self.a);
        self.open_sections.deinit(self.a);
        self.scratch.deinit();
    }

    fn root(self: *Output) !void {
        if (self.mode != .ast) return;
        // The AST format names the document and nests every block under it.
        defer _ = self.scratch.reset(.retain_capacity);
        var buf: std.ArrayList(u8) = .empty;
        try ast.renderAstNode(self.scratch.allocator(), &buf, .{ .tag = .section }, 0, true);
        try self.w.writeAll(buf.items);
        self.indent = 2;
    }

    /// Takes `node`, built in `arena`, with its section events; `by_reference` says it
    /// holds a link by reference, which waits for the definitions.
    fn block(self: *Output, node: Node, arena: *std.heap.ArenaAllocator, by_reference: bool) !void {
        const events = self.sections.feed(node);
        try self.queue.ensureUnusedCapacity(self.a, events.len);
        if (self.hold_sections) try self.open_sections.ensureUnusedCapacity(self.a, 1);
        for (events) |event| switch (event) {
            .close => {
                self.queue.appendAssumeCapacity(.{ .event = event, .arena = null, .wait = .none });
                // The heading closing a section gives its end.
                if (self.hold_sections) self.endSection(node.end_pos);
            },
            .open => {
                if (self.hold_sections) self.open_sections.appendAssumeCapacity(self.queue.items.len);
                self.queue.appendAssumeCapacity(.{ .event = event, .arena = null, .wait = if (self.hold_sections) .section_end else .none });
            },
            .block => self.queue.appendAssumeCapacity(.{
                .event = event,
                .arena = arena,
                .wait = if (by_reference) .references else .none,
            }),
        };
        try self.drain(false);
    }

    fn endSection(self: *Output, end: ?SourcePos) void {
        const pending = &self.queue.items[self.open_sections.pop().?];
        pending.event.open.end_pos = end;
        pending.wait = .none;
    }

    /// Writes the entries at the front of the queue that are ready: those waiting for
    /// nothing and, once the input has ended (`final`), those waiting for the definitions.
    fn drain(self: *Output, final: bool) !void {
        while (self.head < self.queue.items.len) : (self.head += 1) {
            const pending = self.queue.items[self.head];
            switch (pending.wait) {
                .none => {},
                .references => if (!final) break,
                .section_end => break,
            }
            try self.emit(pending);
            if (pending.arena) |arena| self.parser.recycle(arena);
        }
        if (self.head == self.queue.items.len) {
            self.queue.clearRetainingCapacity();
            self.head = 0;
        }
    }

    fn emit(self: *Output, pending: Pending) !void {
        switch (pending.event) {
            .open => |section| {
                defer _ = self.scratch.reset(.retain_capacity);
                const sa = self.scratch.allocator();
                var buf: std.ArrayList(u8) = .empty;
                switch (self.mode) {
                    .html => try html.renderSectionOpen(sa, &buf, section),
                    .ast => {
                        try ast.renderAstNode(sa, &buf, section, self.indent, false);
                        self.indent += 2;
                    },
                }
                try self.w.writeAll(buf.items);
            },
            .close => switch (self.mode) {
                .html => try self.w.writeAll(html.section_close),
                .ast => self.indent -= 2,
            },
            .block => |b| {
                const ba = pending.arena.?.allocator();
                const node = if (pending.wait == .references) try self.resolver.resolve(ba, b) else b;
                try self.write(ba, node);
            },
        }
    }

    fn write(self: *Output, a: Allocator, node: Node) !void {
        var buf: std.ArrayList(u8) = .empty;
        switch (self.mode) {
            .html => {
                var renderer = html.Renderer{ .a = a, .out = &buf, .footnotes = &self.footnotes };
                try renderer.render(node);
            },
            .ast => try ast.renderAstNode(a, &buf, node, self.indent, false),
        }
        try self.w.writeAll(buf.items);
    }

    /// Closes the sections still open, ending at `sections_end`, writes what waited for
    /// the definitions, then the footnotes.
    fn finish(self: *Output, sections_end: ?SourcePos) !void {
        const events = self.sections.finish();
        try self.queue.ensureUnusedCapacity(self.a, events.len);
        for (events) |event| {
            self.queue.appendAssumeCapacity(.{ .event = event, .arena = null, .wait = .none });
            if (self.hold_sections) self.endSection(sections_end);
        }
        try self.drain(true);
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
                try renderer.renderEndnote(n, note.children);
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

test "a block is written as it arrives unless a reference-style link holds it" {
    const a = std.testing.allocator;
    var doc_arena = std.heap.ArenaAllocator.init(a);
    defer doc_arena.deinit();
    const da = doc_arena.allocator();
    var written = std.Io.Writer.Allocating.init(a);
    defer written.deinit();

    const input = "one\n\ntwo [x][r]\n\nthree\n\n[r]: /u\n";
    var defs = document.Definitions{ .a = da };
    var ids = document.Ids{ .a = da, .defs = &defs, .scratch = std.heap.ArenaAllocator.init(a) };
    defer ids.scratch.deinit();
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

test {
    _ = @import("test_runner.zig");
    _ = @import("Lines.zig");
    _ = Parser;
    _ = document;
}
