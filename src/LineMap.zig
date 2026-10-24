const std = @import("std");
const Allocator = std.mem.Allocator;
const SourcePos = @import("node.zig").SourcePos;

/// Maps byte offsets in joined inline text back to source positions. Built by the
/// block parser when it joins a block's content lines (`Parser.buildInlineLineMap`),
/// used by the inline parser to position each node as it is made.
segments: []const Segment = &.{},

const LineMap = @This();

pub const Segment = struct {
    joined_start: u32,
    orig_line: u32,
    orig_col: u32,
    orig_offset: u32,
};

/// Resolve a byte offset in the joined text to a source position. The newline joining
/// two lines is col 0 of the line after it, where djot.js puts a soft or hard break.
pub fn resolve(self: LineMap, joined_offset: u32) SourcePos {
    if (self.segments.len == 0) return .{ .line = 1, .col = 1, .offset = joined_offset };

    // The last segment starting at or before the offset; the first starts at 0.
    var lo: usize = 0;
    var hi: usize = self.segments.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (self.segments[mid].joined_start <= joined_offset) lo = mid + 1 else hi = mid;
    }
    const best = lo - 1;

    if (best + 1 < self.segments.len and joined_offset + 1 == self.segments[best + 1].joined_start) {
        const next = self.segments[best + 1];
        return .{ .line = next.orig_line, .col = 0, .offset = next.orig_offset - next.orig_col };
    }

    const seg = self.segments[best];
    const delta = joined_offset - seg.joined_start;
    return .{
        .line = seg.orig_line,
        .col = seg.orig_col + delta,
        .offset = seg.orig_offset + delta,
    };
}
