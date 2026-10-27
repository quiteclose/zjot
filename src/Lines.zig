//! The line source: the input one line at a time with each line's position, from a
//! resident slice or from a `std.Io.Reader`. A line is its bytes without the newline and
//! without the one carriage return a CRLF ending puts before it; its position is where it
//! starts. The newline
//! after the last line yields no empty line, so line counts match the visible content,
//! and `end` says where the input ended, as djot.js reports it: on its final newline, or
//! one past the last character when there is none. The counts are 64-bit, and an input of
//! 2^64 bytes or lines is `error.InputTooLarge`, the one size limit; a position is 32-bit
//! (`SourcePos`) and saturates past 4 GiB of input, that many lines, or a line that long,
//! which only `--sourcepos` output can show.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SourcePos = @import("node.zig").SourcePos;

/// `eol`: the line's newline, as col 0 of the line after it (djot.js's position for a
/// newline), or the input's end when the line has none.
pub const Line = struct {
    bytes: []const u8,
    pos: SourcePos,
    eol: SourcePos,
    /// Whether a newline ended it: only the input's last line can lack one.
    newline: bool,
    /// The offset of the newline before the line, one less than its start, kept rather
    /// than derived: a start past the ceiling reads as the ceiling, as a start exactly
    /// there does, and only the count knows which (the first line's is 0).
    newline_before: u32,

    pub fn newlineBefore(self: Line) u32 {
        return self.newline_before;
    }
};

pub const Lines = union(enum) {
    slice: Slice,
    reader: Reader,

    pub const Error = error{ OutOfMemory, ReadFailed, InputTooLarge };

    /// Over resident input: zero-copy lines that stay valid for the document.
    const Slice = struct { rest: []const u8, count: Count = .{} };

    /// Over a reader: a line is valid until the next call. A line longer than the
    /// reader's buffer is streamed into `spill`.
    const Reader = struct { r: *std.Io.Reader, spill: std.Io.Writer.Allocating, count: Count = .{} };

    /// The running counters, from which positions and the end are made.
    const Count = struct {
        /// Lines yielded so far.
        line: u64 = 0,
        /// Bytes consumed so far, newlines and carriage returns included.
        offset: u64 = 0,
        /// The last line's bytes, carriage return stripped.
        last_len: u64 = 0,
        /// Whether the input consumed so far ends with a newline (empty input does).
        newline: bool = true,

        fn take(self: *Count, raw: []const u8, newline: bool) error{InputTooLarge}!Line {
            // The one carriage return a CRLF ending puts before the newline goes; one at the
            // end of the input, with no newline after it, is content like any other.
            const bytes = if (newline and raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            self.line = std.math.add(u64, self.line, 1) catch return error.InputTooLarge;
            const pos: SourcePos = .{ .line = sat(self.line), .col = 1, .offset = sat(self.offset) };
            const newline_before = sat(self.offset -| 1);
            self.offset = std.math.add(u64, self.offset, @as(u64, raw.len) + @intFromBool(newline)) catch return error.InputTooLarge;
            self.last_len = bytes.len;
            self.newline = newline;
            return .{ .bytes = bytes, .pos = pos, .eol = self.end(), .newline = newline, .newline_before = newline_before };
        }

        fn end(self: Count) SourcePos {
            if (self.newline) return .{ .line = sat(self.line +| 1), .col = 0, .offset = sat(self.offset -| 1) };
            return .{ .line = sat(self.line), .col = sat(self.last_len + 1), .offset = sat(self.offset) };
        }

        /// A count as a position's 32-bit field: the largest value once past it.
        fn sat(v: u64) u32 {
            return std.math.lossyCast(u32, v);
        }
    };

    pub fn fromSlice(input: []const u8) Lines {
        return .{ .slice = .{ .rest = input } };
    }

    /// `a` holds the spill buffer; `deinit` frees it. The reader needs a buffer: a line is
    /// read through it (`takeDelimiterInclusive`), and `streamDelimiter` asserts one.
    pub fn fromReader(a: Allocator, r: *std.Io.Reader) Lines {
        std.debug.assert(r.buffer.len > 0);
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
                    return try s.count.take(s.rest[0..nl], true);
                }
                defer s.rest = s.rest[s.rest.len..];
                return try s.count.take(s.rest, false);
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
                        return try rd.count.take(rest, false);
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
                        return try rd.count.take(rd.spill.written(), newline);
                    },
                };
                return try rd.count.take(taken[0 .. taken.len - 1], true);
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

test "positions saturate past 4 GiB of input and that many lines" {
    const max = std.math.maxInt(u32);
    var count: Lines.Count = .{ .line = max - 1, .offset = max - 2 };
    const l = try count.take("abc", true);
    try std.testing.expectEqual(SourcePos{ .line = max, .col = 1, .offset = max - 2 }, l.pos);
    try std.testing.expectEqual(@as(u32, max - 3), l.newlineBefore());
    try std.testing.expectEqual(SourcePos{ .line = max, .col = 0, .offset = max }, l.eol);
    const next = try count.take("", false);
    try std.testing.expectEqual(SourcePos{ .line = max, .col = 1, .offset = max }, next.pos);
    try std.testing.expectEqual(@as(u32, max), next.newlineBefore()); // not max - 1: the newline is past the ceiling too
    // A line starting exactly at the ceiling has its newline one before it, which a
    // start that reads the same for having passed the ceiling does not.
    var at_ceiling: Lines.Count = .{ .line = 1, .offset = max };
    const at = try at_ceiling.take("x", true);
    try std.testing.expectEqual(@as(u32, max), at.pos.offset);
    try std.testing.expectEqual(@as(u32, max - 1), at.newlineBefore());
    var past: Lines.Count = .{ .line = 1, .offset = @as(u64, max) + 1 };
    try std.testing.expectEqual(@as(u32, max), (try past.take("x", true)).newlineBefore());
    try std.testing.expectEqual(SourcePos{ .line = max, .col = 1, .offset = max }, count.end());
    try std.testing.expectEqual(@as(u64, max) + 2, count.offset); // the count itself goes on
}

test "an input of 2^64 bytes or lines is error.InputTooLarge" {
    const max = std.math.maxInt(u64);
    var lines: Lines.Count = .{ .line = max - 1 };
    const last = try lines.take("", true); // the last line there can be
    try std.testing.expectEqual(SourcePos{ .line = std.math.maxInt(u32), .col = 0, .offset = 0 }, last.eol);
    try std.testing.expectError(error.InputTooLarge, lines.take("", true));
    var bytes: Lines.Count = .{ .offset = max - 3 };
    try std.testing.expectError(error.InputTooLarge, bytes.take("abc", true)); // four with the newline
    _ = try bytes.take("abc", false); // three: the last bytes there can be
    try std.testing.expectEqual(max, bytes.offset);
}

/// Every line of `input` through `lines`, with the end, for comparison.
const Taken = struct { lines: []const Line, end: SourcePos };

fn takeAll(a: Allocator, lines: *Lines) !Taken {
    var list: std.ArrayList(Line) = .empty;
    while (try lines.next()) |line| try list.append(a, .{ .bytes = try a.dupe(u8, line.bytes), .pos = line.pos, .eol = line.eol, .newline = line.newline, .newline_before = line.newline_before });
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
        try std.testing.expectEqual(e.eol, l.eol);
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
        .{ .input = "a\r", .lines = &.{"a\r"}, .offsets = &.{0}, .end = .{ .line = 1, .col = 3, .offset = 2 } },
        .{ .input = "a\r\r\nb", .lines = &.{ "a\r", "b" }, .offsets = &.{ 0, 4 }, .end = .{ .line = 2, .col = 2, .offset = 5 } },
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
        // A line's eol is col 0 of the next line, and the last line's is the input's end.
        for (from_slice.lines, 0..) |line, i| {
            if (i + 1 < from_slice.lines.len) {
                const next = from_slice.lines[i + 1];
                try std.testing.expectEqual(SourcePos{ .line = next.pos.line, .col = 0, .offset = next.pos.offset - 1 }, line.eol);
            } else try std.testing.expectEqual(c.end, line.eol);
        }
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

test "both backends agree over the corpus, and the end is djot.js's" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
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
            // Lines and offsets reproduce the input; the end is on the final newline, or
            // one past the last character when there is none.
            var offset: u32 = 0;
            for (from_slice.lines) |line| {
                try std.testing.expectEqual(offset, line.pos.offset);
                const nl = std.mem.indexOfScalarPos(u8, input, offset, '\n') orelse input.len;
                const raw = input[offset..nl];
                try std.testing.expectEqualStrings(if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw, line.bytes);
                offset = line.eol.offset + 1;
            }
            const n: u32 = @intCast(from_slice.lines.len);
            if (input.len == 0 or input[input.len - 1] == '\n') {
                try std.testing.expectEqual(SourcePos{ .line = n + 1, .col = 0, .offset = @intCast(input.len -| 1) }, from_slice.end);
            } else {
                try std.testing.expectEqual(SourcePos{ .line = n, .col = @intCast(from_slice.lines[n - 1].bytes.len + 1), .offset = @intCast(input.len) }, from_slice.end);
            }
        }
        try std.testing.expect(seen > 0);
    }
}
