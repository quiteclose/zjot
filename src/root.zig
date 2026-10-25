//! Library root: renders Djot to HTML or to the AST text format, block by block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const leaf = @import("leaf.zig");
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

/// Renders `input` to `w` one block at a time. Nodes live in an arena that is reset
/// after every block; what lives for the whole call is the line index, the definitions
/// (all footnote content included) and the heading survey, so memory tracks the input
/// and the largest block rather than the document's structure. The input is parsed
/// twice, because djot lets a block refer to a later one: the first pass surveys
/// (heading ids, implicit references, definitions), the second resolves each block and
/// writes it. Output already written stays written if a later block fails.
pub fn render(a: Allocator, input: []const u8, w: *std.Io.Writer, opts: RenderOpts) !void {
    var doc_arena = std.heap.ArenaAllocator.init(a);
    defer doc_arena.deinit();
    const da = doc_arena.allocator();
    var block_arena = std.heap.ArenaAllocator.init(a);
    defer block_arena.deinit();
    const ba = block_arena.allocator();

    const index = try Parser.indexLines(da, input);
    var defs = document.Definitions{ .a = da };
    var survey = document.Survey{ .a = da };
    // Where djot.js ends the sections still open at the end: at its last block event,
    // which is the last top-level block's end, except that trailing blank lines and a
    // div's closing fence emit events to the input's end. Pass one tracks positions to
    // find it (and the closing heading of every other section), and so that footnote
    // content, stored then, carries them.
    var sections_end: ?SourcePos = null;
    {
        var parser = Parser.initIndexed(ba, input, index, &defs);
        parser.survey_only = true;
        parser.track_pos = opts.sourcepos;
        var last_is_div = false;
        while (try parser.nextBlock()) |block| {
            // Definitions met before this block come first in the id sequence.
            try survey.visitFootnotes(&defs);
            try survey.visit(block);
            sections_end = block.end_pos;
            last_is_div = block.tag == .div;
            _ = block_arena.reset(.retain_capacity);
        }
        try survey.visitFootnotes(&defs);
        const last_line_blank = index.lines.len > 0 and leaf.isBlank(index.lines[index.lines.len - 1]);
        if (opts.sourcepos and (sections_end == null or last_is_div or last_line_blank)) sections_end = parser.doc_end;
        survey.endOpenSections(sections_end);
    }
    defs.sealed = true;

    var resolver = document.Resolver{ .defs = &defs, .survey = &survey };
    var parser = Parser.initIndexed(ba, input, index, &defs);
    parser.track_pos = opts.sourcepos;
    var sections = document.Sections{ .ends = survey.section_ends.items };
    var out = Emitter{ .w = w, .mode = opts.mode, .footnotes = .{ .a = da } };
    try out.root(ba);
    while (try parser.nextBlock()) |block| {
        const resolved = try resolver.resolve(ba, block);
        for (sections.feed(resolved)) |event| try out.emit(ba, event);
        _ = block_arena.reset(.retain_capacity);
    }
    for (sections.finish()) |event| try out.emit(ba, event);
    // The footnotes follow the document, each resolved and written in its own block arena.
    var n: usize = 0;
    while (out.footnoteLabel(&defs, n)) |label| : (n += 1) {
        try out.footnote(ba, n + 1, try resolver.footnote(ba, label));
        _ = block_arena.reset(.retain_capacity);
    }
    try out.finish();
}

/// Writes section events as output, one rendered block per write, so nothing larger
/// than a block is buffered.
const Emitter = struct {
    w: *std.Io.Writer,
    mode: Mode,
    footnotes: html.Footnotes,
    indent: usize = 0,

    fn root(self: *Emitter, a: Allocator) !void {
        if (self.mode != .ast) return;
        // The AST format names the document and nests every block under it.
        try self.write(a, .{ .tag = .section }, true);
        self.indent = 2;
    }

    fn emit(self: *Emitter, a: Allocator, event: document.Sections.Event) !void {
        switch (event) {
            .open => |section| switch (self.mode) {
                .html => {
                    var buf: std.ArrayList(u8) = .empty;
                    try html.renderSectionOpen(a, &buf, section);
                    try self.w.writeAll(buf.items);
                },
                .ast => {
                    try self.write(a, section, false);
                    self.indent += 2;
                },
            },
            .close => switch (self.mode) {
                .html => try self.w.writeAll(html.section_close),
                .ast => self.indent -= 2,
            },
            .block => |block| try self.write(a, block, false),
        }
    }

    fn write(self: *Emitter, a: Allocator, node: Node, is_root: bool) !void {
        var buf: std.ArrayList(u8) = .empty;
        switch (self.mode) {
            .html => {
                var renderer = html.Renderer{ .a = a, .out = &buf, .footnotes = &self.footnotes };
                try renderer.render(node);
            },
            .ast => try ast.renderAstNode(a, &buf, node, self.indent, is_root),
        }
        try self.w.writeAll(buf.items);
    }

    /// The label of the `n`-th footnote to write after the document, if there is one: in
    /// HTML the `n`-th referenced (writing an endnote may reference more), in the AST the
    /// `n`-th defined, since the AST prints every definition, as djot.js's JSON holds them.
    fn footnoteLabel(self: *Emitter, defs: *const document.Definitions, n: usize) ?[]const u8 {
        const labels = switch (self.mode) {
            .html => self.footnotes.order.keys(),
            .ast => defs.footnote_defs.keys(),
        };
        return if (n < labels.len) labels[n] else null;
    }

    /// Footnote `n` (1-based), resolved: endnote `n` in HTML, a `footnote` block in the AST.
    fn footnote(self: *Emitter, a: Allocator, n: usize, note: Node) !void {
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

    fn finish(self: *Emitter) !void {
        if (self.mode == .html and self.footnotes.order.count() > 0) try self.w.writeAll(html.endnotes_close);
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

test {
    _ = @import("test_runner.zig");
    _ = Parser;
    _ = document;
}
