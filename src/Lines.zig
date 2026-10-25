//! The line source: the input one line at a time with each line's position, from a
//! resident slice or from a `std.Io.Reader`. A line is its bytes without the newline and
//! without a carriage return before it; its position is where it starts. The newline
//! after the last line yields no empty line, so line counts match the visible content,
//! and `end` says where the input ended, as djot.js reports it: on its final newline, or
//! one past the last character when there is none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SourcePos = @import("node.zig").SourcePos;

pub const Line = struct { bytes: []const u8, pos: SourcePos };

pub const Lines = union(enum) {
    slice: Slice,
    reader: Reader,

    pub const Error = error{ OutOfMemory, ReadFailed };

    /// Over resident input: zero-copy lines that stay valid for the document.
    const Slice = struct { rest: []const u8, count: Count = .{} };

    /// Over a reader: a line is valid until the next call. A line longer than the
    /// reader's buffer is streamed into `spill`.
    const Reader = struct { r: *std.Io.Reader, spill: std.Io.Writer.Allocating, count: Count = .{} };

    /// The running counters, from which positions and the end are made.
    const Count = struct {
        /// Lines yielded so far.
        line: u32 = 0,
        /// Bytes consumed so far, newlines and carriage returns included.
        offset: u32 = 0,
        /// The last line's bytes, carriage return stripped.
        last_len: u32 = 0,
        /// Whether the input consumed so far ends with a newline (empty input does).
        newline: bool = true,

        fn take(self: *Count, raw: []const u8, newline: bool) Line {
            const bytes = std.mem.trimEnd(u8, raw, "\r");
            self.line += 1;
            const pos: SourcePos = .{ .line = self.line, .col = 1, .offset = self.offset };
            self.offset += @intCast(raw.len + @intFromBool(newline));
            self.last_len = @intCast(bytes.len);
            self.newline = newline;
            return .{ .bytes = bytes, .pos = pos };
        }

        fn end(self: Count) SourcePos {
            if (self.newline) return .{ .line = self.line + 1, .col = 0, .offset = self.offset -| 1 };
            return .{ .line = self.line, .col = self.last_len + 1, .offset = self.offset };
        }
    };

    pub fn fromSlice(input: []const u8) Lines {
        return .{ .slice = .{ .rest = input } };
    }

    /// `a` holds the spill buffer; `deinit` frees it.
    pub fn fromReader(a: Allocator, r: *std.Io.Reader) Lines {
        return .{ .reader = .{ .r = r, .spill = .init(a) } };
    }

    pub fn deinit(self: *Lines) void {
        switch (self.*) {
            .slice => {},
            .reader => |*rd| rd.spill.deinit(),
        }
    }

    /// Whether a line's bytes stay valid after the next call.
    pub fn stable(self: Lines) bool {
        return self == .slice;
    }

    /// The next line, or null at the end of the input.
    pub fn next(self: *Lines) Error!?Line {
        switch (self.*) {
            .slice => |*s| {
                if (s.rest.len == 0) return null;
                if (std.mem.indexOfScalar(u8, s.rest, '\n')) |nl| {
                    defer s.rest = s.rest[nl + 1 ..];
                    return s.count.take(s.rest[0..nl], true);
                }
                defer s.rest = s.rest[s.rest.len..];
                return s.count.take(s.rest, false);
            },
            .reader => |*rd| {
                const r = rd.r;
                const taken = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
                    error.ReadFailed => return error.ReadFailed,
                    // The input ends without a newline: what is buffered is the last line.
                    error.EndOfStream => {
                        const rest = r.buffered();
                        if (rest.len == 0) return null;
                        r.toss(rest.len);
                        return rd.count.take(rest, false);
                    },
                    // Longer than the buffer: streamed up to the newline, or to the end.
                    error.StreamTooLong => {
                        rd.spill.clearRetainingCapacity();
                        const newline = if (r.streamDelimiter(&rd.spill.writer, '\n')) |_| true else |e| switch (e) {
                            error.EndOfStream => false,
                            error.ReadFailed => return error.ReadFailed,
                            error.WriteFailed => return error.OutOfMemory,
                        };
                        if (newline) r.toss(1);
                        return rd.count.take(rd.spill.written(), newline);
                    },
                };
                return rd.count.take(taken[0 .. taken.len - 1], true);
            },
        }
    }

    /// Where the input ended; meaningful once `next` has returned null.
    pub fn end(self: Lines) SourcePos {
        return switch (self) {
            inline else => |b| b.count.end(),
        };
    }
};

/// Every line of `input` through `lines`, with the end, for comparison.
const Taken = struct { lines: []const Line, end: SourcePos };

fn takeAll(a: Allocator, lines: *Lines) !Taken {
    var list: std.ArrayList(Line) = .empty;
    while (try lines.next()) |line| try list.append(a, .{ .bytes = try a.dupe(u8, line.bytes), .pos = line.pos });
    return .{ .lines = try list.toOwnedSlice(a), .end = lines.end() };
}

/// Through a reader whose buffer holds `buffer_len` bytes, so longer lines spill.
fn takeAllBuffered(a: Allocator, input: []const u8, buffer: []u8) !Taken {
    var fixed = std.Io.Reader.fixed(input);
    var limited = fixed.limited(.unlimited, buffer);
    var lines = Lines.fromReader(a, &limited.interface);
    defer lines.deinit();
    return takeAll(a, &lines);
}

fn expectSame(expected: Taken, actual: Taken) !void {
    try std.testing.expectEqual(expected.lines.len, actual.lines.len);
    for (expected.lines, actual.lines) |e, l| {
        try std.testing.expectEqualStrings(e.bytes, l.bytes);
        try std.testing.expectEqual(e.pos, l.pos);
    }
    try std.testing.expectEqual(expected.end, actual.end);
}

test "lines, positions and the end: CRLF, no final newline, empty input, both backends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { input: []const u8, lines: []const []const u8, offsets: []const u32, end: SourcePos };
    const cases = [_]Case{
        .{ .input = "", .lines = &.{}, .offsets = &.{}, .end = .{ .line = 1, .col = 0, .offset = 0 } },
        .{ .input = "\n", .lines = &.{""}, .offsets = &.{0}, .end = .{ .line = 2, .col = 0, .offset = 0 } },
        .{ .input = "a\nbc\n", .lines = &.{ "a", "bc" }, .offsets = &.{ 0, 2 }, .end = .{ .line = 3, .col = 0, .offset = 4 } },
        .{ .input = "a\nbc", .lines = &.{ "a", "bc" }, .offsets = &.{ 0, 2 }, .end = .{ .line = 2, .col = 3, .offset = 4 } },
        .{ .input = "-\r\n- b\r\n", .lines = &.{ "-", "- b" }, .offsets = &.{ 0, 3 }, .end = .{ .line = 3, .col = 0, .offset = 7 } },
        .{ .input = "a\r", .lines = &.{"a"}, .offsets = &.{0}, .end = .{ .line = 1, .col = 2, .offset = 2 } },
        .{ .input = "\n\nx", .lines = &.{ "", "", "x" }, .offsets = &.{ 0, 1, 2 }, .end = .{ .line = 3, .col = 2, .offset = 3 } },
    };
    var buffer: [16]u8 = undefined;
    for (cases) |c| {
        var slice = Lines.fromSlice(c.input);
        const from_slice = try takeAll(a, &slice);
        try std.testing.expect(slice.stable());
        try std.testing.expectEqual(c.lines.len, from_slice.lines.len);
        for (c.lines, c.offsets, from_slice.lines, 1..) |bytes, offset, line, n| {
            try std.testing.expectEqualStrings(bytes, line.bytes);
            try std.testing.expectEqual(SourcePos{ .line = @intCast(n), .col = 1, .offset = offset }, line.pos);
        }
        try std.testing.expectEqual(c.end, from_slice.end);
        try expectSame(from_slice, try takeAllBuffered(a, c.input, &buffer));
    }
}

test "a line longer than the reader's buffer spills, with or without a final newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "0123456789abcdefghijklmnopqrstuvwxyz";
    var buffer: [16]u8 = undefined;
    for ([_][]const u8{ long ++ "\nshort\n" ++ long ++ "\n", "short\n" ++ long, long ++ "\r\n" ++ long ++ long }) |input| {
        var slice = Lines.fromSlice(input);
        const buffered = try takeAllBuffered(a, input, &buffer);
        try std.testing.expect(buffered.lines.len >= 2);
        try expectSame(try takeAll(a, &slice), buffered);
    }
}

test "both backends agree with the line index over the corpus" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Parser = @import("Parser.zig");
    var buffer: [16]u8 = undefined;
    for ([_][]const u8{ "test/cli", "test/tools/corpus" }) |dir_name| {
        var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_name, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        var seen: usize = 0;
        while (try it.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".dj")) continue;
            seen += 1;
            const input = try dir.readFileAlloc(io, entry.name, a, .limited(1 << 20));
            var slice = Lines.fromSlice(input);
            const from_slice = try takeAll(a, &slice);
            try expectSame(from_slice, try takeAllBuffered(a, input, &buffer));
            const index = try Parser.indexLines(a, input);
            try std.testing.expectEqual(index.lines.len, from_slice.lines.len);
            for (index.lines, index.offsets, from_slice.lines) |bytes, offset, line| {
                try std.testing.expectEqualStrings(bytes, line.bytes);
                try std.testing.expectEqual(offset, line.pos.offset);
            }
            try std.testing.expectEqual(Parser.inputEnd(index, input), from_slice.end);
        }
        try std.testing.expect(seen > 0);
    }
}
