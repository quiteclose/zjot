//! CLI: renders a Djot document from FILE or stdin as HTML or AST.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zjot = @import("zjot");

var out_buf: [4096]u8 = undefined;
var err_buf: [256]u8 = undefined;

const Options = struct {
    mode: enum { html, ast } = .html,
    sourcepos: bool = false,
    file_path: ?[]const u8 = null,
};

const Command = union(enum) {
    render: Options,
    help,
    unknown_option: []const u8,
};

/// Pure: no allocation, no IO. `args` excludes the program name.
fn parseArgs(args: []const [:0]const u8) Command {
    var opts: Options = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--ast")) {
            opts.mode = .ast;
        } else if (std.mem.eql(u8, arg, "--sourcepos")) {
            opts.sourcepos = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (arg.len > 0 and arg[0] == '-') {
            return .{ .unknown_option = arg };
        } else {
            opts.file_path = arg;
        }
    }
    return .{ .render = opts };
}

pub fn main(init: std.process.Init) !u8 {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = switch (parseArgs(if (argv.len == 0) argv else argv[1..])) {
        .render => |o| o,
        .help => {
            try printOut(init.io, usage);
            return 0;
        },
        .unknown_option => |arg| {
            try printErr(init.io, "zjot: unknown option: {s}\n", .{arg});
            return 1;
        },
    };

    const a = init.gpa;
    const input = readInput(init.io, a, opts.file_path) catch |err| switch (err) {
        error.FileNotFound => {
            try printErr(init.io, "zjot: file not found: {s}\n", .{opts.file_path.?});
            return 1;
        },
        else => return err,
    };
    defer a.free(input);

    const output = switch (opts.mode) {
        .html => try zjot.toHtml(a, input),
        .ast => try zjot.toAstOpts(a, input, opts.sourcepos),
    };
    defer a.free(output);

    try printOut(init.io, output);
    return 0;
}

fn readInput(io: std.Io, a: Allocator, file_path: ?[]const u8) ![]u8 {
    if (file_path) |path| {
        return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, a, .unlimited);
    }
    var stdin_buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().reader(io, &stdin_buf);
    return r.interface.allocRemaining(a, .unlimited);
}

fn printOut(io: std.Io, bytes: []const u8) !void {
    var w = std.Io.File.stdout().writer(io, &out_buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var w = std.Io.File.stderr().writer(io, &err_buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

const usage =
    \\Usage: zjot [OPTIONS] [FILE]
    \\
    \\Parse Djot markup and produce output.
    \\
    \\If FILE is omitted, reads from stdin.
    \\
    \\Options:
    \\  --ast         Output AST instead of HTML
    \\  --sourcepos   Include source positions in AST output
    \\  -h, --help    Show this help message
    \\
;

test "parseArgs" {
    try std.testing.expectEqual(.help, parseArgs(&.{"-h"}));
    try std.testing.expectEqual(.help, parseArgs(&.{"--help"}));
    try std.testing.expectEqualStrings("--bogus", parseArgs(&.{"--bogus"}).unknown_option);

    const defaults = parseArgs(&.{}).render;
    try std.testing.expectEqual(.html, defaults.mode);
    try std.testing.expect(!defaults.sourcepos);
    try std.testing.expectEqual(null, defaults.file_path);

    const r = parseArgs(&.{ "--ast", "--sourcepos", "doc.dj" }).render;
    try std.testing.expectEqual(.ast, r.mode);
    try std.testing.expect(r.sourcepos);
    try std.testing.expectEqualStrings("doc.dj", r.file_path.?);
}
