//! Library root: renders Djot to HTML or to the AST text format, block by block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const Parser = switch (build_options.parser) {
    .windows => @import("Parser.zig"),
    .stack => @import("Block.zig"),
};
const document = @import("document.zig");
const html = @import("html.zig");
const ast = @import("ast.zig");
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
/// link is buffered to the end. What lives for the whole call is the line index, the
/// definitions (footnote content included), the ids, and the blocks waiting. Output
/// already written stays written if a later block fails.
pub fn render(a: Allocator, input: []const u8, w: *std.Io.Writer, opts: RenderOpts) !void {
    var doc_arena = std.heap.ArenaAllocator.init(a);
    defer doc_arena.deinit();
    const da = doc_arena.allocator();

    var defs = document.Definitions{ .a = da };
    var ids = document.Ids{ .a = da, .defs = &defs };
    var out = Output{
        .a = a,
        .w = w,
        .mode = opts.mode,
        // Only the AST prints a section's end, on its opening line.
        .hold_sections = opts.mode == .ast and opts.sourcepos,
        .resolver = .{ .defs = &defs, .ids = &ids },
        .footnotes = .{ .a = da },
        .scratch = std.heap.ArenaAllocator.init(a),
    };
    defer out.deinit();
    try out.root();

    var parser = try Parser.init(da, input, &defs);
    parser.track_pos = opts.sourcepos;
    var last_end: ?SourcePos = null;
    var last_is_div = false;
    while (true) {
        // Each block is parsed into the arena `Output` hands out and then owns.
        parser.a = try out.blockAllocator();
        const block = try parser.nextBlock() orelse break;
        try out.block(try ids.assign(parser.a, block));
        last_end = block.end_pos;
        last_is_div = block.tag == .div;
    }
    try ids.assignFootnotes();
    // Where djot.js ends the sections still open at the end: at its last block event,
    // which is the last top-level block's end, except that a div's closing fence and
    // whatever follows the last block (blank lines, definitions, attributes) emit events
    // to the input's end.
    const sections_end = if (last_end == null or last_is_div or parser.trailing()) parser.endPos() else last_end;
    try out.finish(sections_end);
}

/// Writes the section events as output in order, each block rendered on its own: at once
/// when nothing in it can still change, else from a queue that drains from the front as
/// its entries become ready. A block's nodes live in an arena the queue owns until the
/// block is written; the arena of a block written at once serves the next block.
const Output = struct {
    a: Allocator,
    w: *std.Io.Writer,
    mode: Mode,
    /// Whether a section open waits for the heading that closes it, which gives its end.
    hold_sections: bool,
    resolver: document.Resolver,
    footnotes: html.Footnotes,
    sections: document.Sections = .{},
    queue: std.ArrayList(Pending) = .empty,
    /// The entries before `head` have been written.
    head: usize = 0,
    /// Queue indices of the section opens awaiting their end (`hold_sections`), innermost
    /// last. Valid because a held entry keeps the queue from being emptied and compacted.
    open_sections: std.ArrayList(usize) = .empty,
    /// The arena the next block is parsed into.
    incoming: ?*std.heap.ArenaAllocator = null,
    /// For rendering what has no block arena: the root and the section opens.
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
        for (self.queue.items[self.head..]) |p| if (p.arena) |arena| self.destroy(arena);
        self.queue.deinit(self.a);
        self.open_sections.deinit(self.a);
        if (self.incoming) |arena| self.destroy(arena);
        self.scratch.deinit();
    }

    fn destroy(self: *Output, arena: *std.heap.ArenaAllocator) void {
        arena.deinit();
        self.a.destroy(arena);
    }

    /// The allocator for the next block, which `block` then takes.
    fn blockAllocator(self: *Output) !Allocator {
        if (self.incoming == null) {
            const arena = try self.a.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(self.a);
            self.incoming = arena;
        }
        return self.incoming.?.allocator();
    }

    /// Returns a written block's arena for the next block, or frees it when one is waiting.
    fn recycle(self: *Output, arena: *std.heap.ArenaAllocator) void {
        if (self.incoming == null) {
            _ = arena.reset(.retain_capacity);
            self.incoming = arena;
        } else self.destroy(arena);
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

    /// Takes `node`, parsed into the arena `blockAllocator` gave, with its section events.
    fn block(self: *Output, node: Node) !void {
        const events = self.sections.feed(node);
        try self.queue.ensureUnusedCapacity(self.a, events.len);
        if (self.hold_sections) try self.open_sections.ensureUnusedCapacity(self.a, 1);
        const arena = self.incoming.?;
        self.incoming = null;
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
            .block => |b| self.queue.appendAssumeCapacity(.{
                .event = event,
                .arena = arena,
                .wait = if (document.Resolver.touches(b)) .references else .none,
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
            if (pending.arena) |arena| self.recycle(arena);
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
        // The footnotes follow the document, each resolved and written in its own arena.
        var n: usize = 0;
        while (self.footnoteLabel(n)) |label| : (n += 1) {
            const ba = try self.blockAllocator();
            try self.footnote(ba, n + 1, try self.resolver.footnote(ba, label));
            _ = self.incoming.?.reset(.retain_capacity);
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
    var ids = document.Ids{ .a = da, .defs = &defs };
    var out = Output{ .a = a, .w = &written.writer, .mode = .html, .hold_sections = false, .resolver = .{ .defs = &defs, .ids = &ids }, .footnotes = .{ .a = da }, .scratch = std.heap.ArenaAllocator.init(a) };
    defer out.deinit();
    var parser = try Parser.init(da, input, &defs);

    const expect = [_][]const u8{
        "<p>one</p>\n", // written at once
        "<p>one</p>\n", // held: a later definition may still change the link
        "<p>one</p>\n", // behind the held block
    };
    for (expect) |so_far| {
        parser.a = try out.blockAllocator();
        try out.block(try ids.assign(parser.a, (try parser.nextBlock()).?));
        try std.testing.expectEqualStrings(so_far, written.written());
    }
    try std.testing.expectEqual(null, try parser.nextBlock()); // the definition
    try out.finish(null);
    try std.testing.expectEqualStrings("<p>one</p>\n<p>two <a href=\"/u\">x</a></p>\n<p>three</p>\n", written.written());
}

test {
    _ = @import("test_runner.zig");
    _ = @import("Lines.zig");
    _ = @import("Parser.zig");
    _ = Parser;
    _ = document;
}
