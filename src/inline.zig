//! Inline parsing using an opener stack. Handles emphasis, links, images,
//! smart quotes, super/subscript, insert/delete/mark, math, verbatim,
//! raw spans, symbols, autolinks, and inline attributes. Every node is made
//! with the span of source it came from; given a `LineMap`, the span becomes
//! the node's document position as it is made.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("node.zig").Node;
const Tag = @import("node.zig").Tag;
const attrs = @import("attributes.zig");
const BlockAttrs = attrs.BlockAttrs;
const LineMap = @import("LineMap.zig");

const InlineItem = union(enum) {
    node: Node,
    opener: OpenerInfo,
    pending_attrs: BlockAttrs,
};

const OpenerInfo = struct {
    char: u8,
    item_idx: usize,
    /// Where the opener starts in the source: the `{` of a marked one.
    src_pos: usize,
    marked: bool = false,
};

/// Parses `src`, one paragraph's worth of joined lines. With `map`, every node carries
/// the document position of the source it came from; without, none does.
pub fn parseInlineContent(a: Allocator, src: []const u8, map: ?LineMap) anyerror![]const Node {
    var sc = Scanner{ .a = a, .src = src, .map = map };
    try sc.run();
    return sc.resolveItems(sc.items.items);
}

/// The scanner's state over one run of joined text. Nodes enter `items` through `emit`
/// (a span of `src`, both ends inclusive) or `text` (a slice of `src`), so no node is
/// made without the source it came from.
const Scanner = struct {
    a: Allocator,
    src: []const u8,
    map: ?LineMap,
    items: std.ArrayList(InlineItem) = .empty,
    openers: std.ArrayList(OpenerInfo) = .empty,

    fn positioned(sc: *const Scanner, node: Node, start: usize, end: usize) Node {
        const map = sc.map orelse return node;
        var n = node;
        n.start_pos = map.resolve(@intCast(start));
        n.end_pos = map.resolve(@intCast(end));
        return n;
    }

    fn emit(sc: *Scanner, node: Node, start: usize, end: usize) !void {
        try sc.items.append(sc.a, .{ .node = sc.positioned(node, start, end) });
    }

    fn within(sc: *const Scanner, slice: []const u8) bool {
        const p = @intFromPtr(slice.ptr);
        const s = @intFromPtr(sc.src.ptr);
        return p >= s and p + slice.len <= s + sc.src.len;
    }

    /// A text node over a slice of `src`, positioned by where the slice lies; a slice
    /// from elsewhere (a curly quote) gets no position.
    fn strNode(sc: *const Scanner, slice: []const u8) Node {
        const node = Node{ .tag = .str, .text = slice };
        if (slice.len == 0 or !sc.within(slice)) return node;
        const start = @intFromPtr(slice.ptr) - @intFromPtr(sc.src.ptr);
        return sc.positioned(node, start, start + slice.len - 1);
    }

    fn setText(sc: *const Scanner, node: *Node, slice: []const u8) void {
        const fresh = sc.strNode(slice);
        node.text = slice;
        node.start_pos = fresh.start_pos;
        node.end_pos = fresh.end_pos;
    }

    /// Appends text from `src`, extending the previous text node when the two are
    /// contiguous in it. An open bracket is left alone: its opener points at it.
    fn text(sc: *Scanner, slice: []const u8) !void {
        const n_items = sc.items.items.len;
        const open_bracket = sc.openers.items.len > 0 and sc.openers.items[sc.openers.items.len - 1].item_idx + 1 == n_items;
        if (n_items > 0 and !open_bracket) {
            switch (sc.items.items[n_items - 1]) {
                .node => |*n| if (n.tag == .str and n.text.ptr + n.text.len == slice.ptr) {
                    sc.setText(n, n.text.ptr[0 .. n.text.len + slice.len]);
                    return;
                },
                else => {},
            }
        }
        try sc.items.append(sc.a, .{ .node = sc.strNode(slice) });
    }

    fn run(sc: *Scanner) !void {
        const src = sc.src;
        var pos: usize = 0;
        var text_start: usize = 0;

        while (pos < src.len) {
            const c = src[pos];
            switch (c) {
                '\\' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    if (pos + 1 >= src.len) {
                        try sc.text(src[pos .. pos + 1]);
                        pos += 1;
                    } else {
                        const next = src[pos + 1];
                        if (next == '\n') {
                            sc.stripTrailingSpacesFromLastStr();
                            try sc.emit(.{ .tag = .hard_break }, pos + 1, pos + 1);
                            pos += 2;
                        } else if (next == ' ' or next == '\t') {
                            var skip = pos + 1;
                            while (skip < src.len and (src[skip] == ' ' or src[skip] == '\t')) skip += 1;
                            if (skip < src.len and src[skip] == '\n') {
                                sc.stripTrailingSpacesFromLastStr();
                                try sc.emit(.{ .tag = .hard_break }, skip, skip);
                                pos = skip + 1;
                            } else if (next == ' ') {
                                try sc.emit(.{ .tag = .non_breaking_space }, pos + 1, pos + 1);
                                pos += 2;
                            } else {
                                try sc.text(src[pos .. pos + 1]);
                                pos += 1;
                            }
                        } else if (isEscapable(next)) {
                            try sc.text(src[pos + 1 .. pos + 2]);
                            pos += 2;
                        } else {
                            try sc.text(src[pos .. pos + 1]);
                            pos += 1;
                        }
                    }
                    text_start = pos;
                },
                '`' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    const tick_len = countRunAt(src, pos, '`');
                    const after = pos + tick_len;
                    if (findClosingTicks(src, after, tick_len)) |close_pos| {
                        const content = trimVerbatimContent(src[after..close_pos]);
                        const after_close = close_pos + tick_len;
                        var node = Node{ .tag = .verbatim, .text = content };
                        var next_pos = after_close;
                        if (after_close + 1 < src.len and src[after_close] == '{' and src[after_close + 1] == '=') {
                            if (std.mem.indexOfScalarPos(u8, src, after_close, '}')) |fe| {
                                const format = src[after_close + 2 .. fe];
                                if (format.len > 0 and std.mem.indexOfScalar(u8, format, ' ') == null) {
                                    node = .{ .tag = .raw_inline, .text = content, .lang = format };
                                    next_pos = fe + 1;
                                }
                            }
                        }
                        // A raw inline ends on its closing ticks, before the format, as djot.js.
                        try sc.emit(node, pos, after_close - 1);
                        pos = next_pos;
                    } else {
                        try sc.emit(.{ .tag = .verbatim, .text = trimVerbatimContent(src[after..]) }, pos, src.len - 1);
                        pos = src.len;
                    }
                    text_start = pos;
                },
                '\n' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    try sc.emit(.{ .tag = .soft_break }, pos, pos);
                    pos += 1;
                    text_start = pos;
                },
                '*', '_' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    try sc.handleEmphDelimiter(&pos, c, false);
                    text_start = pos;
                },
                '{' => {
                    if (pos + 1 < src.len) {
                        const next = src[pos + 1];
                        if (next == '_' or next == '*') {
                            if (pos > text_start) try sc.text(src[text_start..pos]);
                            pos += 1;
                            try sc.handleEmphDelimiter(&pos, next, true);
                            text_start = pos;
                            continue;
                        } else if (next == '+' or next == '-' or next == '=' or next == '~' or next == '^') {
                            if (pos > text_start) try sc.text(src[text_start..pos]);
                            try sc.handleBracedSpan(&pos);
                            text_start = pos;
                            continue;
                        } else if (next == '\'' or next == '"') {
                            if (pos > text_start) try sc.text(src[text_start..pos]);
                            pos += 1;
                            try sc.handleSmartQuote(&pos, next, true);
                            text_start = pos;
                            continue;
                        }
                    }
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    if (attrs.parseInlineAttrs(sc.a, src, pos)) |parsed| {
                        try sc.applyInlineAttrs(parsed.attrs);
                        pos = parsed.end;
                    } else {
                        try sc.text(src[pos .. pos + 1]);
                        pos += 1;
                    }
                    text_start = pos;
                },
                '[' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    if (pos + 1 < src.len and src[pos + 1] == '^') {
                        if (findMatchingBracket(src, pos)) |close| {
                            try sc.emit(.{ .tag = .footnote_reference, .text = src[pos + 2 .. close] }, pos, close);
                            pos = close + 1;
                            text_start = pos;
                            continue;
                        }
                    }
                    // The bracket is an item of its own: the opener's index points at it.
                    try sc.openers.append(sc.a, .{ .char = '[', .item_idx = sc.items.items.len, .src_pos = pos });
                    try sc.items.append(sc.a, .{ .node = sc.strNode(src[pos .. pos + 1]) });
                    pos += 1;
                    text_start = pos;
                },
                '!' => {
                    if (pos + 1 < src.len and src[pos + 1] == '[') {
                        if (pos > text_start) try sc.text(src[text_start..pos]);
                        try sc.openers.append(sc.a, .{ .char = '!', .item_idx = sc.items.items.len, .src_pos = pos });
                        try sc.items.append(sc.a, .{ .node = sc.strNode(src[pos .. pos + 2]) });
                        pos += 2;
                        text_start = pos;
                    } else {
                        pos += 1;
                    }
                },
                ']' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    try sc.handleCloseBracket(&pos);
                    text_start = pos;
                },
                '<' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    if (!try sc.handleAutolink(&pos)) {
                        try sc.text(src[pos .. pos + 1]);
                        pos += 1;
                    }
                    text_start = pos;
                },
                '^', '~' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    if (pos + 1 < src.len and src[pos + 1] == '}') {
                        if (try sc.handleBracedClose(c, pos)) {
                            pos += 2;
                            text_start = pos;
                            continue;
                        }
                    }
                    try sc.handleSuperSubscript(&pos, c, if (c == '^') .superscript else .subscript);
                    text_start = pos;
                },
                '$' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    var dollar_count: usize = 1;
                    if (pos + 1 < src.len and src[pos + 1] == '$') dollar_count = 2;
                    const tick_start = pos + dollar_count;
                    if (tick_start < src.len and src[tick_start] == '`') {
                        const tick_len = countRunAt(src, tick_start, '`');
                        const content_start = tick_start + tick_len;
                        if (findClosingTicks(src, content_start, tick_len)) |close_pos| {
                            const tag: Tag = if (dollar_count == 2) .display_math else .inline_math;
                            try sc.emit(.{ .tag = tag, .text = src[content_start..close_pos] }, pos, close_pos + tick_len - 1);
                            pos = close_pos + tick_len;
                            text_start = pos;
                            continue;
                        }
                    }
                    try sc.text(src[pos .. pos + dollar_count]);
                    pos += dollar_count;
                    text_start = pos;
                },
                ':' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    if (sc.handleSymbol(&pos)) {
                        text_start = pos;
                    } else {
                        pos += 1;
                        text_start = pos - 1;
                    }
                },
                '"', '\'' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    try sc.handleSmartQuote(&pos, c, false);
                    text_start = pos;
                },
                '-', '+', '=' => {
                    if (pos + 1 < src.len and src[pos + 1] == '}') {
                        if (pos > text_start) try sc.text(src[text_start..pos]);
                        if (!try sc.handleBracedClose(c, pos)) try sc.text(src[pos .. pos + 2]);
                        pos += 2;
                        text_start = pos;
                    } else if (c == '-' and pos + 1 < src.len and src[pos + 1] == '-') {
                        if (pos > text_start) try sc.text(src[text_start..pos]);
                        var dash_count: usize = 0;
                        var dp = pos;
                        while (dp < src.len and src[dp] == '-') : (dp += 1) dash_count += 1;
                        if (dp < src.len and src[dp] == '}' and dash_count >= 2) {
                            dash_count -= 1;
                            dp -= 1;
                        }
                        try sc.emitDashes(pos, dash_count);
                        pos = dp;
                        text_start = pos;
                    } else {
                        pos += 1;
                    }
                },
                '.' => {
                    if (pos + 2 < src.len and src[pos + 1] == '.' and src[pos + 2] == '.') {
                        if (pos > text_start) try sc.text(src[text_start..pos]);
                        try sc.emit(.{ .tag = .ellipsis }, pos, pos + 2);
                        pos += 3;
                        text_start = pos;
                    } else {
                        pos += 1;
                    }
                },
                else => {
                    pos += 1;
                },
            }
        }

        if (pos > text_start) try sc.text(src[text_start..pos]);
        sc.trimTrailingWhitespace();
    }

    fn stripTrailingSpacesFromLastStr(sc: *Scanner) void {
        if (sc.items.items.len == 0) return;
        switch (sc.items.items[sc.items.items.len - 1]) {
            .node => |*n| {
                if (n.tag == .str) {
                    sc.setText(n, std.mem.trimEnd(u8, n.text, " \t"));
                    if (n.text.len == 0) _ = sc.items.pop();
                }
            },
            else => {},
        }
    }

    fn trimTrailingWhitespace(sc: *Scanner) void {
        while (sc.items.items.len > 0) {
            switch (sc.items.items[sc.items.items.len - 1]) {
                .node => |*n| {
                    if (n.tag == .str) {
                        sc.setText(n, std.mem.trimEnd(u8, n.text, " \t"));
                        if (n.text.len == 0) {
                            _ = sc.items.pop();
                            continue;
                        }
                    }
                    break;
                },
                else => break,
            }
        }
    }

    /// `X}` closing the marked opener `{X`; the node spans both braces.
    fn handleBracedClose(sc: *Scanner, char: u8, p: usize) !bool {
        var i = sc.openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = sc.openers.items[i];
            if (op.char == char and op.marked) {
                if (op.item_idx + 1 < sc.items.items.len) {
                    const tag: Tag = switch (char) {
                        '-' => .delete,
                        '+' => .insert,
                        '=' => .mark,
                        '~' => .subscript,
                        '^' => .superscript,
                        else => .span,
                    };
                    const children = try sc.collectChildren(op.item_idx);
                    try sc.emit(.{ .tag = tag, .children = children }, op.src_pos, p + 1);
                    sc.openers.items.len = i;
                    return true;
                }
            }
        }
        return false;
    }

    fn applyInlineAttrs(sc: *Scanner, ba: BlockAttrs) !void {
        if (ba.id == null and ba.classes == null and ba.attrs.len == 0) return;
        try sc.items.append(sc.a, .{ .pending_attrs = ba });
    }

    fn handleEmphDelimiter(sc: *Scanner, pos: *usize, char: u8, marked: bool) !void {
        const src = sc.src;
        const p = pos.*;

        if (!marked and p + 1 < src.len and src[p + 1] == '}') {
            var i = sc.openers.items.len;
            while (i > 0) {
                i -= 1;
                const op = sc.openers.items[i];
                if (op.char == char and op.marked) {
                    if (op.item_idx + 1 < sc.items.items.len) {
                        const tag: Tag = if (char == '*') .strong else .emph;
                        const children = try sc.collectChildren(op.item_idx);
                        try sc.emit(.{ .tag = tag, .children = children }, op.src_pos, p + 1);
                        sc.openers.items.len = i;
                        pos.* = p + 2;
                        return;
                    }
                }
            }
            try sc.text(src[p .. p + 2]);
            pos.* = p + 2;
            return;
        }

        const can_close = canCloseDelim(src, p) and !marked;
        if (can_close) {
            var i = sc.openers.items.len;
            while (i > 0) {
                i -= 1;
                const op = sc.openers.items[i];
                if (op.char == char and op.marked == marked) {
                    if (op.item_idx + 1 < sc.items.items.len) {
                        const tag: Tag = if (char == '*') .strong else .emph;
                        const children = try sc.collectChildren(op.item_idx);
                        try sc.emit(.{ .tag = tag, .children = children }, op.src_pos, p);
                        sc.openers.items.len = i;
                        pos.* = p + 1;
                        return;
                    }
                    break;
                }
            }
        }

        const can_open = marked or canOpenDelim(src, p);
        if (can_open) {
            const opener = OpenerInfo{ .char = char, .item_idx = sc.items.items.len, .src_pos = if (marked) p - 1 else p, .marked = marked };
            try sc.openers.append(sc.a, opener);
            try sc.items.append(sc.a, .{ .opener = opener });
            pos.* = p + 1;
            return;
        }

        try sc.text(src[p .. p + 1]);
        pos.* = p + 1;
    }

    fn handleBracedSpan(sc: *Scanner, pos: *usize) !void {
        const p = pos.*;
        const opener = OpenerInfo{ .char = sc.src[p + 1], .item_idx = sc.items.items.len, .src_pos = p, .marked = true };
        try sc.openers.append(sc.a, opener);
        try sc.items.append(sc.a, .{ .opener = opener });
        pos.* = p + 2;
    }

    fn handleCloseBracket(sc: *Scanner, pos: *usize) !void {
        const src = sc.src;
        const p = pos.*;
        var i = sc.openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = sc.openers.items[i];
            if (op.char == '[' or op.char == '!') {
                const children = try sc.collectChildren(op.item_idx);
                const is_image = op.char == '!';
                // djot.js starts an image on its bracket, not its `!`.
                const start = if (is_image) op.src_pos + 1 else op.src_pos;
                pos.* = p + 1;

                if (pos.* < src.len and src[pos.*] == '(') {
                    if (findMatchingParen(src, pos.*)) |close_paren| {
                        const raw_dest = src[pos.* + 1 .. close_paren];
                        const dest = processUrl(sc.a, raw_dest) catch raw_dest;
                        const tag: Tag = if (is_image) .image else .link;
                        try sc.emit(.{ .tag = tag, .children = children, .destination = dest }, start, close_paren);
                        pos.* = close_paren + 1;
                        sc.openers.items.len = i;
                        return;
                    }
                } else if (pos.* < src.len and src[pos.*] == '[') {
                    if (findMatchingBracket(src, pos.*)) |close_ref| {
                        const ref_label = src[pos.* + 1 .. close_ref];
                        const tag: Tag = if (is_image) .image else .link;
                        try sc.emit(.{ .tag = tag, .children = children, .reference = ref_label }, start, close_ref);
                        pos.* = close_ref + 1;
                        sc.openers.items.len = i;
                        return;
                    }
                } else if (pos.* < src.len and src[pos.*] == '{') {
                    if (attrs.parseInlineAttrs(sc.a, src, pos.*)) |parsed| {
                        const span_node = applyBlockAttrsToNode(.{ .tag = .span, .children = children }, parsed.attrs);
                        try sc.emit(span_node, start, p);
                        pos.* = parsed.end;
                        sc.openers.items.len = i;
                        return;
                    }
                }

                var restored: std.ArrayList(InlineItem) = .empty;
                const bracket_len: usize = if (is_image) 2 else 1;
                try restored.append(sc.a, .{ .node = sc.strNode(src[op.src_pos .. op.src_pos + bracket_len]) });
                for (children) |child| try restored.append(sc.a, .{ .node = child });
                try restored.append(sc.a, .{ .node = sc.strNode(src[p .. p + 1]) });
                sc.items.items.len = op.item_idx;
                for (restored.items) |item| try sc.items.append(sc.a, item);
                sc.openers.items.len = i;
                return;
            }
        }

        try sc.text(src[p .. p + 1]);
        pos.* = p + 1;
    }

    fn handleAutolink(sc: *Scanner, pos: *usize) !bool {
        const src = sc.src;
        const p = pos.*;
        const rest = src[p + 1 ..];
        const close = std.mem.indexOfScalar(u8, rest, '>') orelse return false;
        const content = rest[0..close];
        const end = p + 1 + close;

        if (std.mem.startsWith(u8, content, "http://") or
            std.mem.startsWith(u8, content, "https://") or
            std.mem.startsWith(u8, content, "ftp://"))
        {
            try sc.emit(.{ .tag = .url, .text = content }, p, end);
            pos.* = end + 1;
            return true;
        }

        if (std.mem.indexOfScalar(u8, content, '@') != null and
            std.mem.indexOfScalar(u8, content, ' ') == null)
        {
            try sc.emit(.{ .tag = .email, .text = content }, p, end);
            pos.* = end + 1;
            return true;
        }

        return false;
    }

    fn handleSuperSubscript(sc: *Scanner, pos: *usize, char: u8, tag: Tag) !void {
        const p = pos.*;
        var i = sc.openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = sc.openers.items[i];
            if (op.char == char) {
                if (op.item_idx + 1 < sc.items.items.len) {
                    const children = try sc.collectChildren(op.item_idx);
                    try sc.emit(.{ .tag = tag, .children = children }, op.src_pos, p);
                    sc.openers.items.len = i;
                    pos.* = p + 1;
                    return;
                }
            }
        }

        if (canOpenDelim(sc.src, p)) {
            const opener = OpenerInfo{ .char = char, .item_idx = sc.items.items.len, .src_pos = p };
            try sc.openers.append(sc.a, opener);
            try sc.items.append(sc.a, .{ .opener = opener });
            pos.* = p + 1;
            return;
        }

        try sc.text(sc.src[p .. p + 1]);
        pos.* = p + 1;
    }

    fn handleSymbol(sc: *Scanner, pos: *usize) bool {
        const src = sc.src;
        const p = pos.*;
        const start = p + 1;
        if (start >= src.len) return false;
        const end = std.mem.indexOfScalarPos(u8, src, start, ':') orelse return false;
        if (end == start) return false;
        const name = src[start..end];
        for (name) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '+') return false;
        }
        sc.emit(.{ .tag = .symb, .text = name }, p, end) catch return false;
        pos.* = end + 1;
        return true;
    }

    /// Converts the run of `count` hyphens at `start` into em-dashes (---) and en-dashes (--).
    /// Strategy: if divisible by 3, all em; if divisible by 2, all en;
    /// otherwise prefer em-dashes first, then en-dashes for the remainder.
    fn emitDashes(sc: *Scanner, start: usize, count: usize) !void {
        if (count <= 1) {
            if (count == 1) try sc.text(sc.src[start .. start + 1]);
            return;
        }
        const all_em = count % 3 == 0;
        const all_en = count % 2 == 0;
        var remaining = count;
        var at = start;
        while (remaining > 0) {
            const width: usize = if (all_em)
                3
            else if (all_en)
                2
            else if (remaining >= 3 and (remaining % 2 != 0 or remaining > 4))
                3
            else if (remaining >= 2)
                2
            else
                1;
            switch (width) {
                3 => try sc.emit(.{ .tag = .em_dash }, at, at + 2),
                2 => try sc.emit(.{ .tag = .en_dash }, at, at + 1),
                else => try sc.text(sc.src[at .. at + 1]),
            }
            remaining -= width;
            at += width;
        }
    }

    fn handleSmartQuote(sc: *Scanner, pos: *usize, char: u8, marked: bool) !void {
        const src = sc.src;
        const p = pos.*;

        if (!marked and p + 1 < src.len and src[p + 1] == '}') {
            var i = sc.openers.items.len;
            while (i > 0) {
                i -= 1;
                const op = sc.openers.items[i];
                if (op.char == char and op.marked) {
                    if (op.item_idx + 1 < sc.items.items.len) {
                        const tag: Tag = if (char == '"') .double_quoted else .single_quoted;
                        const children = try sc.collectChildren(op.item_idx);
                        try sc.emit(.{ .tag = tag, .children = children }, op.src_pos, p + 1);
                        sc.openers.items.len = i;
                        pos.* = p + 2;
                        return;
                    }
                    break;
                }
            }
            const curly: []const u8 = if (char == '\'') "\u{2019}" else "\u{201d}";
            try sc.emit(.{ .tag = .str, .text = curly }, p, p + 1);
            pos.* = p + 2;
            return;
        }

        const can_close = !marked and p > 0 and src[p - 1] != ' ' and src[p - 1] != '\t' and
            src[p - 1] != '\n' and src[p - 1] != '\r';
        const can_open = if (marked)
            true
        else if (p + 1 < src.len and src[p + 1] != ' ' and src[p + 1] != '\t' and
            src[p + 1] != '\n' and src[p + 1] != '\r')
            (if (char == '\'') canOpenSingleQuote(src, p) else true)
        else
            false;

        if (can_close) {
            var i = sc.openers.items.len;
            while (i > 0) {
                i -= 1;
                const op = sc.openers.items[i];
                if (op.char == char and !op.marked) {
                    if (op.item_idx + 1 < sc.items.items.len) {
                        const tag: Tag = if (char == '"') .double_quoted else .single_quoted;
                        const children = try sc.collectChildren(op.item_idx);
                        try sc.emit(.{ .tag = tag, .children = children }, op.src_pos, p);
                        sc.openers.items.len = i;
                        pos.* = p + 1;
                        return;
                    }
                    break;
                }
            }
        }

        if (can_open) {
            const opener = OpenerInfo{ .char = char, .item_idx = sc.items.items.len, .src_pos = if (marked) p - 1 else p, .marked = marked };
            try sc.openers.append(sc.a, opener);
            try sc.items.append(sc.a, .{ .opener = opener });
        } else {
            // Can't open or close: emit a typographic quote as literal text.
            // Single quote becomes right curly (') for apostrophe contexts;
            // double quote becomes left curly (") as the more common standalone form.
            const curly: []const u8 = if (char == '\'') "\u{2019}" else "\u{201c}";
            try sc.emit(.{ .tag = .str, .text = curly }, p, p);
        }
        pos.* = p + 1;
    }

    /// The nodes after the opener at `opener_idx`, which are removed from `items`.
    fn collectChildren(sc: *Scanner, opener_idx: usize) ![]const Node {
        var children: std.ArrayList(Node) = .empty;
        for (sc.items.items[opener_idx + 1 ..]) |item| {
            switch (item) {
                .node => |n| try sc.appendNode(&children, n),
                .opener => |op| try sc.appendNode(&children, sc.openerNode(op)),
                .pending_attrs => |pa| try sc.applyAttrsToResolved(&children, pa),
            }
        }
        sc.items.items.len = opener_idx;
        return children.toOwnedSlice(sc.a);
    }

    /// The text of an opener that never closed.
    fn openerNode(sc: *const Scanner, op: OpenerInfo) Node {
        if (op.char == '\'' or op.char == '"') {
            const curly: []const u8 = if (op.marked)
                (if (op.char == '\'') "\u{2018}" else "\u{201c}")
            else
                (if (op.char == '\'') "\u{2019}" else "\u{201c}");
            return sc.positioned(.{ .tag = .str, .text = curly }, op.src_pos, op.src_pos + @as(usize, if (op.marked) 1 else 0));
        }
        const len: usize = if (op.marked) 2 else 1;
        return sc.strNode(sc.src[op.src_pos .. op.src_pos + len]);
    }

    /// Appends a node, joining it to the previous one when both are text contiguous in
    /// `src`, as djot.js reports one `str` for text an opener did not divide.
    fn appendNode(sc: *const Scanner, nodes: *std.ArrayList(Node), node: Node) !void {
        if (node.tag == .str and nodes.items.len > 0) {
            const last = &nodes.items[nodes.items.len - 1];
            if (last.tag == .str and last.text.ptr + last.text.len == node.text.ptr and
                last.id == null and last.classes == null and last.attrs.len == 0)
            {
                last.text = last.text.ptr[0 .. last.text.len + node.text.len];
                last.end_pos = node.end_pos;
                return;
            }
        }
        try nodes.append(sc.a, node);
    }

    fn resolveItems(sc: *Scanner, items: []const InlineItem) ![]const Node {
        var nodes: std.ArrayList(Node) = .empty;
        for (items) |item| {
            switch (item) {
                .node => |n| try sc.appendNode(&nodes, n),
                .opener => |op| try sc.appendNode(&nodes, sc.openerNode(op)),
                .pending_attrs => |pa| try sc.applyAttrsToResolved(&nodes, pa),
            }
        }
        return nodes.toOwnedSlice(sc.a);
    }

    fn applyAttrsToResolved(sc: *const Scanner, nodes: *std.ArrayList(Node), ba: BlockAttrs) !void {
        if (nodes.items.len == 0) return;
        const last = &nodes.items[nodes.items.len - 1];
        switch (last.tag) {
            .str => {
                const last_text = last.text;
                if (last_text.len == 0) return;
                var word_start = last_text.len;
                while (word_start > 0 and last_text[word_start - 1] != ' ' and
                    last_text[word_start - 1] != '\t' and last_text[word_start - 1] != '\n')
                {
                    word_start -= 1;
                }
                if (word_start == last_text.len) return;

                var gather_start = nodes.items.len - 1;
                if (word_start == 0) {
                    while (gather_start > 0) {
                        const prev = nodes.items[gather_start - 1];
                        if (prev.tag != .str) break;
                        const pt = prev.text;
                        if (pt.len == 0) break;
                        const last_ch = pt[pt.len - 1];
                        if (last_ch == ' ' or last_ch == '\t' or last_ch == '\n') break;
                        gather_start -= 1;
                        var ws = pt.len;
                        while (ws > 0 and pt[ws - 1] != ' ' and pt[ws - 1] != '\t' and pt[ws - 1] != '\n') ws -= 1;
                        if (ws > 0) {
                            word_start = ws;
                            break;
                        }
                    }
                }

                var span_children: std.ArrayList(Node) = .empty;
                if (gather_start < nodes.items.len - 1 or word_start > 0) {
                    if (word_start > 0) {
                        const first_text = nodes.items[gather_start].text;
                        try span_children.append(sc.a, sc.strNode(first_text[word_start..]));
                        for (nodes.items[gather_start + 1 ..]) |n| try span_children.append(sc.a, n);
                    } else {
                        for (nodes.items[gather_start..]) |n| try span_children.append(sc.a, n);
                    }
                } else {
                    try span_children.append(sc.a, sc.strNode(last_text[word_start..]));
                }

                const kids = try span_children.toOwnedSlice(sc.a);
                var span_node = Node{ .tag = .span, .children = kids, .start_pos = kids[0].start_pos, .end_pos = kids[kids.len - 1].end_pos };
                span_node = applyBlockAttrsToNode(span_node, ba);

                if (word_start > 0 and gather_start < nodes.items.len - 1) {
                    sc.setText(&nodes.items[gather_start], nodes.items[gather_start].text[0..word_start]);
                    nodes.items.len = gather_start + 1;
                    try nodes.append(sc.a, span_node);
                } else if (word_start > 0) {
                    sc.setText(last, last_text[0..word_start]);
                    try nodes.append(sc.a, span_node);
                } else {
                    nodes.items.len = gather_start;
                    try nodes.append(sc.a, span_node);
                }
            },
            .span,
            .link,
            .image,
            .emph,
            .strong,
            .verbatim,
            .mark,
            .superscript,
            .subscript,
            .insert,
            .delete,
            .double_quoted,
            .single_quoted,
            => {
                nodes.items[nodes.items.len - 1] = applyBlockAttrsToNode(last.*, ba);
            },
            else => {},
        }
    }
};

pub fn applyBlockAttrsToNode(node: Node, ba: BlockAttrs) Node {
    var result = node;
    if (ba.id) |id| result.id = id;
    if (ba.classes) |cls| result.classes = cls;
    if (ba.attrs.len > 0) result.attrs = ba.attrs;
    return result;
}

fn canOpenDelim(src: []const u8, pos: usize) bool {
    if (pos + 1 >= src.len) return false;
    const next = src[pos + 1];
    return next != ' ' and next != '\t' and next != '\n' and next != '\r';
}

fn canCloseDelim(src: []const u8, pos: usize) bool {
    if (pos == 0) return false;
    const prev = src[pos - 1];
    return prev != ' ' and prev != '\t' and prev != '\n' and prev != '\r';
}

fn canOpenSingleQuote(src: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    const prev = src[pos - 1];
    return prev == ' ' or prev == '\t' or prev == '\n' or prev == '\r' or
        prev == '"' or prev == '\'' or prev == '-' or prev == '(' or prev == '[';
}

fn isEscapable(c: u8) bool {
    return switch (c) {
        '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '"', '\'', '~', '^', ':', '<', '>', '$', '%', '=' => true,
        else => false,
    };
}

fn countRunAt(src: []const u8, pos: usize, char: u8) usize {
    var count: usize = 0;
    var i = pos;
    while (i < src.len and src[i] == char) : (i += 1) count += 1;
    return count;
}

fn findClosingTicks(src: []const u8, start: usize, count: usize) ?usize {
    var i = start;
    while (i < src.len) {
        if (src[i] == '`') {
            const run = countRunAt(src, i, '`');
            if (run == count) return i;
            i += run;
        } else {
            i += 1;
        }
    }
    return null;
}

fn trimVerbatimContent(raw: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = raw.len;
    if (raw.len >= 2 and raw[0] == ' ' and raw[1] == '`') start = 1;
    if (end > start + 1 and raw[end - 1] == ' ' and raw[end - 2] == '`') end -= 1;
    return raw[start..end];
}

fn findMatchingParen(src: []const u8, pos: usize) ?usize {
    if (pos >= src.len or src[pos] != '(') return null;
    var depth: usize = 1;
    var i = pos + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '(') depth += 1;
        if (src[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findMatchingBracket(src: []const u8, pos: usize) ?usize {
    if (pos >= src.len or src[pos] != '[') return null;
    var depth: usize = 1;
    var i = pos + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '[') depth += 1;
        if (src[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn processUrl(a: Allocator, raw: []const u8) ![]const u8 {
    const needs_processing = std.mem.indexOfScalar(u8, raw, '\n') != null or
        std.mem.indexOfScalar(u8, raw, '\\') != null;
    if (!needs_processing) return raw;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\n') {
            i += 1;
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
        } else if (raw[i] == '\\' and i + 1 < raw.len and isEscapable(raw[i + 1])) {
            try buf.append(a, raw[i + 1]);
            i += 2;
        } else {
            try buf.append(a, raw[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(a);
}
pub fn normalizeLabel(a: Allocator, raw: []const u8) ![]const u8 {
    const needs_normalization = for (raw) |c| {
        if (c == '\n' or c == '\r' or c == '\t') break true;
    } else false;
    if (!needs_normalization) return raw;
    var buf: std.ArrayList(u8) = .empty;
    var in_ws = false;
    for (raw) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!in_ws and buf.items.len > 0) {
                try buf.append(a, ' ');
                in_ws = true;
            }
        } else {
            try buf.append(a, c);
            in_ws = false;
        }
    }
    const items = buf.items;
    if (items.len > 0 and items[items.len - 1] == ' ') buf.items.len -= 1;
    return buf.toOwnedSlice(a);
}

pub fn getPlainText(a: Allocator, node: Node) ![]const u8 {
    if (node.text.len > 0) return node.text;
    var buf: std.ArrayList(u8) = .empty;
    for (node.children) |child| {
        switch (child.tag) {
            .str => try buf.appendSlice(a, child.text),
            .soft_break => try buf.append(a, ' '),
            else => {
                if (child.children.len > 0) {
                    const sub = try getPlainText(a, child);
                    try buf.appendSlice(a, sub);
                }
            },
        }
    }
    return buf.toOwnedSlice(a);
}

pub fn joinLines(a: Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";
    var total: usize = 0;
    for (lines, 0..) |line, idx| {
        if (idx > 0) total += 1;
        total += line.len;
    }
    var buf = try a.alloc(u8, total);
    var p: usize = 0;
    for (lines, 0..) |line, idx| {
        if (idx > 0) {
            buf[p] = '\n';
            p += 1;
        }
        @memcpy(buf[p..][0..line.len], line);
        p += line.len;
    }
    return buf;
}

pub fn mergeRefAttrs(node: Node, ref_attrs: BlockAttrs, a: Allocator) Node {
    var result = node;
    if (result.id == null) result.id = ref_attrs.id;
    if (ref_attrs.classes) |ref_cls| {
        if (result.classes) |existing| {
            result.classes = std.fmt.allocPrint(a, "{s} {s}", .{ ref_cls, existing }) catch existing;
        } else {
            result.classes = ref_cls;
        }
    }
    if (ref_attrs.attrs.len > 0) {
        if (result.attrs.len == 0) {
            result.attrs = ref_attrs.attrs;
        } else {
            var merged: std.ArrayList(@import("node.zig").Attr) = .empty;
            for (ref_attrs.attrs) |ra| {
                var overridden = false;
                for (result.attrs) |na| {
                    if (std.mem.eql(u8, ra.key, na.key)) {
                        overridden = true;
                        break;
                    }
                }
                if (!overridden) merged.append(a, ra) catch {};
            }
            for (result.attrs) |na| merged.append(a, na) catch {};
            result.attrs = merged.toOwnedSlice(a) catch result.attrs;
        }
    }
    return result;
}
