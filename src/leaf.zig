//! The leaf parsers' bodies: what one line, or the lines of one leaf block, say on their
//! own, with no document or container state. Block starts (`headingLevel`, `isCodeFence`,
//! `startsBlockQuote`, `definitionLabel`, the list markers, ...), table rows and cells,
//! fences and the whitespace helpers. The block parser decides where each applies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const CellAlign = node_mod.CellAlign;
const ListStyle = node_mod.ListStyle;

fn isBlank(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

/// Leading spaces and tabs, one column each, as djot.js's `skipSpace`.
fn countIndent(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) : (n += 1) {}
    return n;
}

pub fn countLeadingChar(line: []const u8, char: u8) usize {
    for (line, 0..) |c, i| {
        if (c != char) return i;
    }
    return line.len;
}

pub fn isThematicBreak(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    var count: usize = 0;
    for (trimmed) |c| {
        if (c == ' ') continue;
        if (c != '*' and c != '-') return false;
        count += 1;
    }
    return count >= 3;
}

pub const FenceInfo = struct { len: usize, char: u8, lang: ?[]const u8, indent: usize };

pub fn isClosingCodeFence(line: []const u8, fence: FenceInfo) bool {
    const rest = std.mem.trimStart(u8, line, " ");
    const run = countLeadingChar(rest, fence.char);
    return run >= fence.len and isBlank(std.mem.trimStart(u8, rest[run..], &[_]u8{fence.char}));
}

pub fn isCodeFence(line: []const u8) ?FenceInfo {
    var indent: usize = 0;
    var rest = line;
    while (rest.len > 0 and rest[0] == ' ') {
        indent += 1;
        rest = rest[1..];
    }
    if (rest.len < 3) return null;

    const fence_char = rest[0];
    if (fence_char != '`' and fence_char != '~') return null;
    const fence_len = countLeadingChar(rest, fence_char);
    if (fence_len < 3) return null;
    const after_fence = std.mem.trim(u8, rest[fence_len..], " \t");

    if (fence_char == '`') {
        if (after_fence.len > 0) {
            if (std.mem.indexOfScalar(u8, after_fence, ' ') != null) return null;
            var bi: usize = 0;
            while (bi < after_fence.len) : (bi += 1) {
                if (after_fence[bi] == '`') {
                    const back_run = countLeadingChar(after_fence[bi..], '`');
                    if (back_run >= fence_len) return null;
                    bi += back_run;
                }
            }
        }
    }
    return .{ .len = fence_len, .char = fence_char, .lang = if (after_fence.len > 0) after_fence else null, .indent = indent };
}

/// One to six `#` followed by a space, a tab or the end of the line.
pub fn headingLevel(trimmed: []const u8) ?usize {
    const hashes = countLeadingChar(trimmed, '#');
    if (hashes == 0 or hashes > 6) return null;
    if (hashes < trimmed.len and trimmed[hashes] != ' ' and trimmed[hashes] != '\t') return null;
    return hashes;
}

pub fn startsBlockQuote(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (trimmed.len == 0) return false;
    if (trimmed[0] != '>') return false;
    if (trimmed.len == 1) return true;
    return trimmed[1] == ' ' or trimmed[1] == '\t';
}

pub const DivInfo = struct { fence: []const u8, class: ?[]const u8 };

pub fn isFencedDivStart(line: []const u8) ?DivInfo {
    const trimmed = std.mem.trimStart(u8, line, " ");
    const colons = countLeadingChar(trimmed, ':');
    if (colons < 3) return null;
    const after = std.mem.trim(u8, trimmed[colons..], " \t");
    return .{ .fence = trimmed[0..colons], .class = if (after.len > 0) after else null };
}

/// Whether `line` is a bare fence of at least `fence_len` colons, which closes a div.
pub fn closesDiv(line: []const u8, fence_len: usize) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return countLeadingChar(trimmed, ':') >= fence_len and isBlank(std.mem.trimStart(u8, trimmed, ":"));
}

/// `rest_col` is the number of bytes before `rest` on its line.
pub const DefinitionLabel = struct { label: []const u8, rest: []const u8, rest_col: u32, is_footnote: bool };

/// `[label]:` or `[^label]:` opening a reference or footnote definition: space
/// indentation only, a label of at least one character (as written, `^` included), and
/// what follows the colon.
pub fn definitionLabel(line: []const u8) ?DefinitionLabel {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (trimmed.len < 4 or trimmed[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, trimmed[1..], ']') orelse return null;
    if (close + 2 >= trimmed.len or trimmed[close + 2] != ':') return null;
    const label = trimmed[1 .. close + 1];
    const is_footnote = label.len > 0 and label[0] == '^';
    if (is_footnote and label.len < 2) return null;
    const after_colon = trimmed[close + 3 ..];
    const rest = std.mem.trim(u8, after_colon, " \t");
    const rest_lead = after_colon.len - std.mem.trimStart(u8, after_colon, " \t").len;
    return .{
        .label = label,
        .rest = rest,
        .rest_col = @intCast(line.len - after_colon.len + rest_lead),
        .is_footnote = is_footnote,
    };
}

/// Advance past a backtick run and its matching closing run.
/// Returns the index past the closing backticks, or past end of text if no close found.
fn skipBacktickSpan(text: []const u8, start: usize) usize {
    var run: usize = 0;
    var j = start;
    while (j < text.len and text[j] == '`') : (j += 1) run += 1;
    var k = j;
    while (k < text.len) {
        if (text[k] == '`') {
            var r2: usize = 0;
            var m = k;
            while (m < text.len and text[m] == '`') : (m += 1) r2 += 1;
            if (r2 == run) return m;
            k = m;
        } else {
            k += 1;
        }
    }
    return text.len;
}

/// A table row starts and ends with an unescaped pipe outside verbatim, as djot.js.
pub fn isTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 2 or trimmed[0] != '|') return false;
    var i: usize = 0;
    var ends_with_pipe = false;
    while (i < trimmed.len) {
        if (trimmed[i] == '\\' and i + 1 < trimmed.len) {
            i += 2;
        } else if (trimmed[i] == '`') {
            i = skipBacktickSpan(trimmed, i);
        } else {
            ends_with_pipe = trimmed[i] == '|' and i == trimmed.len - 1;
            i += 1;
        }
    }
    return ends_with_pipe;
}

pub fn isTableSep(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t|");
    for (trimmed) |c| {
        if (c != '-' and c != ':' and c != '|' and c != ' ') return false;
    }
    return trimmed.len > 0;
}

pub fn parseSepAligns(a: Allocator, line: []const u8) ![]const CellAlign {
    var result: std.ArrayList(CellAlign) = .empty;
    const trimmed = std.mem.trim(u8, line, " \t");
    var content = trimmed;
    if (content.len > 0 and content[0] == '|') content = content[1..];
    if (content.len > 0 and content[content.len - 1] == '|') content = content[0 .. content.len - 1];

    var cell_iter = std.mem.splitScalar(u8, content, '|');
    while (cell_iter.next()) |cell| {
        const c = std.mem.trim(u8, cell, " \t");
        if (c.len == 0) {
            try result.append(a, .default);
            continue;
        }
        const left_colon = c[0] == ':';
        const right_colon = c[c.len - 1] == ':';
        if (left_colon and right_colon) {
            try result.append(a, .center);
        } else if (right_colon) {
            try result.append(a, .right);
        } else if (left_colon) {
            try result.append(a, .left);
        } else {
            try result.append(a, .default);
        }
    }
    return result.toOwnedSlice(a);
}

fn splitTableCells(a: Allocator, content: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var cell_start: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 2;
        } else if (content[i] == '`') {
            i = skipBacktickSpan(content, i);
        } else if (content[i] == '|') {
            try result.append(a, content[cell_start..i]);
            cell_start = i + 1;
            i += 1;
        } else {
            i += 1;
        }
    }
    try result.append(a, content[cell_start..]);
    return result.toOwnedSlice(a);
}

/// The cells of a table row: what lies between its outer pipes, split at the unescaped
/// pipes outside verbatim.
pub fn rowCells(a: Allocator, line: []const u8) ![]const []const u8 {
    var content = std.mem.trim(u8, line, " \t");
    if (content.len > 0 and content[0] == '|') content = content[1..];
    if (content.len > 0 and content[content.len - 1] == '|') content = content[0 .. content.len - 1];
    return splitTableCells(a, content);
}

/// The number styles an ordered list may still be, narrowed by each item's marker, as
/// djot.js (`1.` is decimal; `i.` is roman or alpha until a later item decides).
pub const OrderedStyles = struct {
    possible: [2]?ListStyle,
    n: u2,

    /// Whether `m` continues the list: its styles share one with the list's, which then
    /// narrow to the shared ones. The first item is always accepted.
    pub fn accept(self: *OrderedStyles, m: Marker, first: bool) bool {
        var shared: [2]?ListStyle = .{ null, null };
        var n_shared: u2 = 0;
        for (0..self.n) |pi| {
            const ps = self.possible[pi] orelse continue;
            for (0..m.n_styles) |si| {
                if (m.styles[si] == ps) {
                    shared[n_shared] = ps;
                    n_shared += 1;
                    break;
                }
            }
        }
        if (first) return true;
        if (n_shared == 0) return false;
        self.possible = shared;
        self.n = n_shared;
        return true;
    }
};

/// A list marker opening an item: where its content starts, and what the list reads to
/// accept the next item (the bullet character; an ordered marker's text and the number
/// styles it may be).
pub const Marker = struct {
    rest: []const u8,
    indent: usize,
    content_col: usize,
    bullet: u8 = 0,
    marker_text: []const u8 = "",
    styles: [2]?ListStyle = .{ null, null },
    n_styles: u2 = 0,
    delim: Delim = .period,
};

/// How an ordered marker is written: `1.`, `1)` or `(1)`; a list keeps one, as djot.js.
pub const Delim = enum { period, paren, parens };

fn delimKind(paren_open: bool, delim: u8) Delim {
    return if (paren_open) .parens else if (delim == ')') .paren else .period;
}

/// Whether an item's first line opens with a checkbox: `[ ]`, `[x]` or `[X]` followed by
/// whitespace or nothing.
pub fn isTaskItem(rest: []const u8) bool {
    if (rest.len < 3 or rest[0] != '[' or rest[2] != ']') return false;
    if (rest[1] != ' ' and rest[1] != 'x' and rest[1] != 'X') return false;
    return rest.len == 3 or rest[3] == ' ' or rest[3] == '\t';
}

pub fn parseBulletMarker(line: []const u8) ?Marker {
    const indent = countIndent(line);
    const trimmed = line[indent..];
    if (trimmed.len < 1) return null;
    if (trimmed[0] != '-' and trimmed[0] != '+' and trimmed[0] != '*') return null;
    // The marker alone on its line starts an empty item.
    if (trimmed.len > 1 and trimmed[1] != ' ' and trimmed[1] != '\t') return null;
    if (trimmed[0] == '-' or trimmed[0] == '*') {
        if (isThematicBreak(line)) return null;
    }
    const rest = if (trimmed.len > 1) trimmed[2..] else "";
    return .{ .rest = rest, .indent = indent, .content_col = indent + 2, .bullet = trimmed[0] };
}

pub fn parseOrderedMarker(line: []const u8) ?Marker {
    const indent = countIndent(line);
    const trimmed = line[indent..];
    if (trimmed.len < 2) return null;

    var paren_open = false;
    var start: usize = 0;
    if (trimmed[0] == '(') {
        paren_open = true;
        start = 1;
    }
    const after_paren = trimmed[start..];
    if (after_paren.len == 0) return null;

    var i: usize = 0;
    while (i < after_paren.len and std.ascii.isDigit(after_paren[i])) : (i += 1) {}
    if (i > 0 and i < after_paren.len) {
        const delim = after_paren[i];
        if ((!paren_open and (delim == '.' or delim == ')')) or (paren_open and delim == ')')) {
            const marker_len = start + i + 1;
            return finishMarker(trimmed, indent, marker_len, .decimal, .decimal, after_paren[0..i], delimKind(paren_open, delim));
        }
    }

    if (after_paren.len >= 2) {
        const c = after_paren[0];
        if (std.ascii.isLower(c)) {
            const delim = after_paren[1];
            if ((!paren_open and (delim == '.' or delim == ')')) or (paren_open and delim == ')')) {
                const marker_len = start + 2;
                if (isRomanLower(c)) {
                    return finishMarker(trimmed, indent, marker_len, .lower_roman, .lower_alpha, after_paren[0..1], delimKind(paren_open, delim));
                } else {
                    return finishMarker(trimmed, indent, marker_len, .lower_alpha, .lower_alpha, after_paren[0..1], delimKind(paren_open, delim));
                }
            }
        }
        if (std.ascii.isUpper(c)) {
            const delim = after_paren[1];
            if ((!paren_open and (delim == '.' or delim == ')')) or (paren_open and delim == ')')) {
                const marker_len = start + 2;
                if (isRomanUpper(c)) {
                    return finishMarker(trimmed, indent, marker_len, .upper_roman, .upper_alpha, after_paren[0..1], delimKind(paren_open, delim));
                } else {
                    return finishMarker(trimmed, indent, marker_len, .upper_alpha, .upper_alpha, after_paren[0..1], delimKind(paren_open, delim));
                }
            }
        }
        if (isRomanLower(c)) {
            var j: usize = 0;
            while (j < after_paren.len and isRomanLower(after_paren[j])) : (j += 1) {}
            if (j > 1 and j < after_paren.len) {
                const delim = after_paren[j];
                if ((!paren_open and (delim == '.' or delim == ')')) or (paren_open and delim == ')')) {
                    const marker_len = start + j + 1;
                    return finishMarker(trimmed, indent, marker_len, .lower_roman, .lower_roman, after_paren[0..j], delimKind(paren_open, delim));
                }
            }
        }
        if (isRomanUpper(c)) {
            var j: usize = 0;
            while (j < after_paren.len and isRomanUpper(after_paren[j])) : (j += 1) {}
            if (j > 1 and j < after_paren.len) {
                const delim = after_paren[j];
                if ((!paren_open and (delim == '.' or delim == ')')) or (paren_open and delim == ')')) {
                    const marker_len = start + j + 1;
                    return finishMarker(trimmed, indent, marker_len, .upper_roman, .upper_roman, after_paren[0..j], delimKind(paren_open, delim));
                }
            }
        }
    }

    return null;
}

fn finishMarker(trimmed: []const u8, indent: usize, marker_len: usize, style1: ListStyle, style2: ListStyle, marker_text: []const u8, delim: Delim) ?Marker {
    if (marker_len < trimmed.len and trimmed[marker_len] != ' ' and trimmed[marker_len] != '\t') return null;
    return .{
        .rest = if (marker_len < trimmed.len) trimmed[marker_len + 1 ..] else "",
        .indent = indent,
        .content_col = indent + marker_len + 1,
        .marker_text = marker_text,
        .styles = .{ style1, if (style1 != style2) style2 else null },
        .n_styles = if (style1 != style2) 2 else 1,
        .delim = delim,
    };
}

/// The number an ordered marker starts at; 64 bits on every target, as djot.js's number.
pub fn getListStart(marker_text: []const u8, style: ListStyle) u64 {
    return switch (style) {
        .decimal => std.fmt.parseInt(u64, marker_text, 10) catch 1,
        .lower_alpha => if (marker_text.len == 1) @as(u64, marker_text[0] - 'a') + 1 else 1,
        .upper_alpha => if (marker_text.len == 1) @as(u64, marker_text[0] - 'A') + 1 else 1,
        .lower_roman => romanToNumber(marker_text),
        .upper_roman => romanToNumber(marker_text),
    };
}

fn isRomanLower(c: u8) bool {
    return switch (c) {
        'i', 'v', 'x', 'l', 'c', 'd', 'm' => true,
        else => false,
    };
}

fn isRomanUpper(c: u8) bool {
    return switch (c) {
        'I', 'V', 'X', 'L', 'C', 'D', 'M' => true,
        else => false,
    };
}

fn romanToNumber(s: []const u8) usize {
    var total: usize = 0;
    var prev: usize = 0;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        const n: usize = switch (s[i]) {
            'i', 'I' => 1,
            'v', 'V' => 5,
            'x', 'X' => 10,
            'l', 'L' => 50,
            'c', 'C' => 100,
            'd', 'D' => 500,
            'm', 'M' => 1000,
            else => 0,
        };
        if (n < prev) {
            total -|= n;
        } else {
            total += n;
        }
        prev = n;
    }
    return if (total > 0) total else 1;
}
