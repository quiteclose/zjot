//! Library root: renders Djot to HTML or to the AST text format, block by block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const document = @import("document.zig");
const html = @import("html.zig");
const ast = @import("ast.zig");
const Node = @import("node.zig").Node;

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
    var defs = Parser.Definitions{ .a = da };
    var survey = document.Survey{ .a = da };
    {
        var parser = Parser.initIndexed(ba, input, index, &defs);
        while (try parser.nextBlock()) |block| {
            // Definitions met before this block come first in the id sequence.
            try survey.visitFootnotes(&defs);
            try survey.visit(block);
            _ = block_arena.reset(.retain_capacity);
        }
        try survey.visitFootnotes(&defs);
    }
    defs.sealed = true;

    var resolver = document.Resolver{ .a = da, .defs = &defs, .survey = &survey };
    var parser = Parser.initIndexed(ba, input, index, &defs);
    parser.track_pos = opts.sourcepos;
    if (opts.sourcepos) parser.input_end = Parser.inputEnd(index, input);
    var sections = document.Sections{ .doc_end = parser.input_end };
    var out = Emitter{ .w = w, .mode = opts.mode };
    try out.root(ba);
    while (try parser.nextBlock()) |block| {
        const resolved = try resolver.resolve(ba, block);
        for (sections.feed(resolved)) |event| try out.emit(ba, event);
        _ = block_arena.reset(.retain_capacity);
    }
    for (sections.finish()) |event| try out.emit(ba, event);
    if (try resolver.footnoteSection(ba)) |endnotes| try out.emit(ba, .{ .block = endnotes });
}

/// Writes section events as output, one rendered block per write, so nothing larger
/// than a block is buffered.
const Emitter = struct {
    w: *std.Io.Writer,
    mode: Mode,
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
            .html => try html.renderNode(a, &buf, node),
            .ast => try ast.renderAstNode(a, &buf, node, self.indent, is_root),
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

test {
    _ = @import("test_runner.zig");
    _ = Parser;
    _ = document;
}
