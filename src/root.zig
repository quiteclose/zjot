const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const html = @import("html.zig");
const ast = @import("ast.zig");
const Node = @import("node.zig").Node;

pub fn toHtml(a: Allocator, input: []const u8) ![]const u8 {
    // All intermediate allocations (AST, child arrays, joined text) go into
    // an arena that is freed in one shot. Only the final output string is
    // duped onto the caller's allocator so it outlives the arena.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var defs = Parser.Definitions{ .a = aa };
    var parser = Parser.init(aa, input, &defs);
    const doc = try parser.parseDoc();
    var out: std.ArrayList(u8) = .empty;
    try html.renderNode(aa, &out, doc);
    const result = try out.toOwnedSlice(aa);
    return a.dupe(u8, result);
}

pub fn toAst(a: Allocator, input: []const u8) ![]const u8 {
    return toAstOpts(a, input, false);
}

pub fn toAstOpts(a: Allocator, input: []const u8, sourcepos: bool) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var defs = Parser.Definitions{ .a = aa };
    var parser = Parser.init(aa, input, &defs);
    parser.track_pos = sourcepos;
    const doc = try parser.parseDoc();
    var out: std.ArrayList(u8) = .empty;
    try ast.renderAstNode(aa, &out, doc, 0, true);
    const result = try out.toOwnedSlice(aa);
    return a.dupe(u8, result);
}

test {
    _ = @import("test_runner.zig");
    _ = Parser;
}
