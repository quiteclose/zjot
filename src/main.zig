const std = @import("std");
const zjot = @import("zjot");

var out_buf: [4096]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    // parse command line args
    const config = try Config.fromArgs(init.io, init.gpa, init.minimal.args);
    defer config.deinit(init.gpa);

    // convert to output format
    const output = switch (config.mode) {
        .html => try zjot.toHtml(init.gpa, config.input),
        .ast => try zjot.toAstOpts(init.gpa, config.input, config.sourcepos),
    };
    defer init.gpa.free(output);

    // write to stdout
    try printOut(init.io, "{s}\n", .{output});
}

const Config = struct {
    // before any library functions have been applied, but after all IO is complete
    mode: enum { html, ast } = .html,
    sourcepos: bool = false,
    input: []const u8 = undefined,

    pub fn fromArgs(io: std.Io, gpa: std.mem.Allocator, args: std.process.Args) !Config {
        var config: Config = .{};
        var file_path: ?[]const u8 = null;
        var args_iter = try args.iterateAllocator(gpa);

        std.debug.assert(args_iter.skip() == true);
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--ast")) {
                config.mode = .ast;
            } else if (std.mem.eql(u8, arg, "--sourcepos")) {
                config.sourcepos = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try printOut(io, "{s}\n", .{usage});
                std.process.exit(0);
            } else if (arg.len > 0 and arg[0] == '-') {
                try printErr(io, "zjot: unknown option: {s}\n", .{arg});
                std.process.exit(1);
            } else {
                file_path = arg;
            }
        }

        config.input =
            if (file_path) |path|
                std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, gpa, .unlimited) catch |err| switch (err) {
                    error.FileNotFound => {
                        try printErr(io, "zjot: file not found: {s}\n", .{path});
                        std.process.exit(1);
                    },
                    else => return err,
                }
            else blk: {
                var stdin_buf: [4096]u8 = undefined;
                var r = std.Io.File.stdin().reader(io, &stdin_buf);
                break :blk try r.interface.allocRemaining(gpa, .unlimited);
            };

        return config;
    }

    pub fn deinit(self: Config, gpa: std.mem.Allocator) void {
        gpa.free(self.input);
    }
};

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var w = std.Io.File.stderr().writer(io, &out_buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var w = std.Io.File.stdout().writer(io, &out_buf);
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
;
