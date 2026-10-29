//! Maps byte offsets in joined inline text back to source positions. Built by the block
//! parser when it joins a leaf's content lines and positions are tracked
//! (`Parser.leafLineMap`, `--sourcepos`), used by the inline parser to position each node
//! as it is made.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SourcePos = @import("node.zig").SourcePos;

/// One per joined line, in order, the first at 0.
segments: []const Segment = &.{},
/// The length of the joined text, and the position just past it (the newline after the
/// last line, or the document's end), where a hard break ending the block sits. Offsets
/// in the joined text are indexes, not positions: they do not saturate.
total: usize = 0,
end: SourcePos = .{ .line = 1, .col = 1, .offset = 0 },

const LineMap = @This();

pub const Segment = struct {
    joined_start: usize,
    orig_line: u32,
    orig_col: u32,
    orig_offset: u32,
    /// Where the join before this segment resolves: the end of the content line before it
    /// (col 0 of the line after that one), as the line source placed it, which is this
    /// line's start only when no line was skipped between (a heading's bare `#` line is).
    /// Kept rather than derived, since a saturated offset cannot be subtracted from.
    join_line: u32,
    join_offset: u32,
};

/// Resolve a byte offset in the joined text to a source position. The newline joining
/// two lines is col 0 of the line after it, where djot.js puts a soft or hard break.
pub fn resolve(self: LineMap, joined_offset: usize) SourcePos {
    if (self.segments.len == 0) return .{ .line = 1, .col = 1, .offset = std.math.lossyCast(u32, joined_offset) };
    if (joined_offset >= self.total) return self.end;

    // The last segment starting at or before the offset; the first starts at 0.
    var lo: usize = 0;
    var hi: usize = self.segments.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (self.segments[mid].joined_start <= joined_offset) lo = mid + 1 else hi = mid;
    }
    const best = lo - 1;

    if (best + 1 < self.segments.len and joined_offset +| 1 == self.segments[best + 1].joined_start) {
        const next = self.segments[best + 1];
        return .{ .line = next.join_line, .col = 0, .offset = next.join_offset };
    }

    const seg = self.segments[best];
    const delta: u64 = joined_offset - seg.joined_start;
    return .{
        .line = seg.orig_line,
        .col = std.math.lossyCast(u32, seg.orig_col + delta),
        .offset = std.math.lossyCast(u32, seg.orig_offset + delta),
    };
}

test "the join between lines resolves to the newline the line source placed, past the ceiling too" {
    const max = std.math.maxInt(u32);
    const map: LineMap = .{ .segments = &.{
        .{ .joined_start = 0, .orig_line = 1, .orig_col = 1, .orig_offset = 10, .join_line = 1, .join_offset = 9 },
        .{ .joined_start = 4, .orig_line = 2, .orig_col = 3, .orig_offset = max, .join_line = 2, .join_offset = max },
    }, .total = 7, .end = .{ .line = 3, .col = 0, .offset = max } };
    try std.testing.expectEqual(SourcePos{ .line = 1, .col = 2, .offset = 11 }, map.resolve(1));
    try std.testing.expectEqual(SourcePos{ .line = 2, .col = 0, .offset = max }, map.resolve(3)); // not max - 3
    try std.testing.expectEqual(SourcePos{ .line = 2, .col = 4, .offset = max }, map.resolve(5));
}

test "an offset in the joined text is an index: past 4 GiB it still finds its line, and the position saturates" {
    if (@sizeOf(usize) < 8) return error.SkipZigTest;
    const max = std.math.maxInt(u32);
    const far: usize = 1 << 33;
    const map: LineMap = .{ .segments = &.{
        .{ .joined_start = 0, .orig_line = 1, .orig_col = 1, .orig_offset = 0, .join_line = 1, .join_offset = 0 },
        .{ .joined_start = far, .orig_line = 2, .orig_col = 3, .orig_offset = max, .join_line = 2, .join_offset = max },
    }, .total = far + 5, .end = .{ .line = 3, .col = 0, .offset = max } };
    try std.testing.expectEqual(SourcePos{ .line = 1, .col = max, .offset = max }, map.resolve(far - 2));
    try std.testing.expectEqual(SourcePos{ .line = 2, .col = 0, .offset = max }, map.resolve(far - 1));
    try std.testing.expectEqual(SourcePos{ .line = 2, .col = 5, .offset = max }, map.resolve(far + 2));
    try std.testing.expectEqual(SourcePos{ .line = 3, .col = 0, .offset = max }, map.resolve(far + 5));
}
