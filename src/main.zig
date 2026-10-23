//! CLI: renders a Djot document from FILE or stdin as HTML or AST.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zjot = @import("zjot");

const Options = struct {
    mode: enum { html, ast } = .html,
    sourcepos: bool = false,
    file_path: ?[]const u8 = null,
};

const Command = union(enum) {
    render: Options,
    help,
    unknown_option: []const u8,
    extra_argument: []const u8,
    empty_argument,
    sourcepos_without_ast,
};

/// Pure: no allocation, no IO. `args` excludes the program name.
/// `-` means stdin anywhere, including after `--`; a file named `-` is `./-`.
fn parseArgs(args: []const [:0]const u8) Command {
    var opts: Options = .{};
    var have_input = false;
    var options_done = false;
    for (args) |arg| {
        if (!options_done and std.mem.eql(u8, arg, "--")) {
            options_done = true;
        } else if (!options_done and std.mem.eql(u8, arg, "--ast")) {
            opts.mode = .ast;
        } else if (!options_done and std.mem.eql(u8, arg, "--sourcepos")) {
            opts.sourcepos = true;
        } else if (!options_done and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            return .help;
        } else if (!options_done and arg.len > 1 and arg[0] == '-') {
            return .{ .unknown_option = arg };
        } else if (arg.len == 0) {
            return .empty_argument;
        } else if (have_input) {
            return .{ .extra_argument = arg };
        } else {
            have_input = true;
            opts.file_path = if (std.mem.eql(u8, arg, "-")) null else arg;
        }
    }
    if (opts.sourcepos and opts.mode != .ast) return .sourcepos_without_ast;
    return .{ .render = opts };
}

pub fn main(init: std.process.Init) !u8 {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = switch (parseArgs(if (argv.len == 0) argv else argv[1..])) {
        .render => |o| o,
        .help => return printOut(init.io, usage),
        .unknown_option => |arg| {
            try printErr(init.io, "zjot: unknown option: {s}\n", .{arg});
            return 1;
        },
        .extra_argument => |arg| {
            try printErr(init.io, "zjot: unexpected argument: {s}\n", .{arg});
            return 1;
        },
        .empty_argument => {
            try printErr(init.io, "zjot: empty argument\n", .{});
            return 1;
        },
        .sourcepos_without_ast => {
            try printErr(init.io, "zjot: --sourcepos requires --ast\n", .{});
            return 1;
        },
    };

    const a = init.gpa;
    const input = readInput(init.io, a, opts.file_path) catch |err| switch (err) {
        error.FileNotFound => {
            try printErr(init.io, "zjot: file not found: {s}\n", .{opts.file_path.?});
            return 1;
        },
        error.OutOfMemory => return err,
        else => |e| {
            try printErr(init.io, "zjot: {s}: {t}\n", .{ opts.file_path orelse "stdin", e });
            return 1;
        },
    };
    defer a.free(input);

    const output = switch (opts.mode) {
        .html => try zjot.toHtml(a, input),
        .ast => try zjot.toAstOpts(a, input, opts.sourcepos),
    };
    defer a.free(output);

    return printOut(init.io, output);
}

fn readInput(io: std.Io, a: Allocator, file_path: ?[]const u8) ![]u8 {
    if (file_path) |path| {
        return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, a, .unlimited);
    }
    var stdin_buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().reader(io, &stdin_buf);
    return r.interface.allocRemaining(a, .unlimited);
}

/// Writes to stdout and returns the exit code: a failed write (a closed pipe, a full
/// disk) is reported in one line rather than as an error trace.
fn printOut(io: std.Io, bytes: []const u8) !u8 {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(bytes) catch return writeFailed(io);
    w.interface.flush() catch return writeFailed(io);
    return 0;
}

fn writeFailed(io: std.Io) !u8 {
    try printErr(io, "zjot: stdout: write failed\n", .{});
    return 1;
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

const usage =
    \\Usage: zjot [OPTIONS] [--] [FILE]
    \\
    \\Parse Djot markup and produce output.
    \\
    \\If FILE is omitted or is -, reads from stdin. -- ends the options.
    \\
    \\Options:
    \\  --ast         Output AST instead of HTML
    \\  --sourcepos   Include source positions in AST output (requires --ast)
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

    try std.testing.expectEqual(null, parseArgs(&.{"-"}).render.file_path);
    try std.testing.expectEqual(null, parseArgs(&.{ "--", "-" }).render.file_path);
    try std.testing.expectEqualStrings("-x.dj", parseArgs(&.{ "--", "-x.dj" }).render.file_path.?);
    try std.testing.expectEqualStrings("b.dj", parseArgs(&.{ "a.dj", "b.dj" }).extra_argument);
    try std.testing.expectEqual(.sourcepos_without_ast, parseArgs(&.{"--sourcepos"}));
    try std.testing.expectEqual(.empty_argument, parseArgs(&.{""}));
    try std.testing.expectEqual(.empty_argument, parseArgs(&.{ "--", "" }));
}
