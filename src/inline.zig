//! Inline parsing using an opener stack. Handles emphasis, links, images,
//! smart quotes, super/subscript, insert/delete/mark, math, verbatim,
//! raw spans, symbols, autolinks, and inline attributes. Every node is made
//! with the span of source it came from; given a `LineMap`, the span becomes
//! the node's document position as it is made.

const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const Node = node_mod.Node;
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
/// the document position of the source it came from; without, none does. No inline
/// attribute is read before `attrs_from` (the text of a failed block attribute). An id read
/// but attached to no node, or overridden by a later attribute's, goes to `dropped`: djot.js
/// registers it all the same.
pub fn parseInlineContent(a: Allocator, src: []const u8, map: ?LineMap, attrs_from: usize, dropped: *std.ArrayList([]const u8)) Allocator.Error![]const Node {
    var sc = Scanner{ .a = a, .src = src, .map = map, .attrs_from = attrs_from, .dropped = dropped };
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
    attrs_from: usize = 0,
    dropped: *std.ArrayList([]const u8),
    items: std.ArrayList(InlineItem) = .empty,
    openers: std.ArrayList(OpenerInfo) = .empty,

    fn positioned(sc: *const Scanner, node: Node, start: usize, end: usize) Node {
        const map = sc.map orelse return node;
        var n = node;
        n.start_pos = map.resolve(start);
        n.end_pos = map.resolve(end);
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
        const node = Node{ .data = .{ .str = slice } };
        if (slice.len == 0 or !sc.within(slice)) return node;
        const start = @intFromPtr(slice.ptr) - @intFromPtr(sc.src.ptr);
        return sc.positioned(node, start, start + slice.len - 1);
    }

    fn setText(sc: *const Scanner, node: *Node, slice: []const u8) void {
        node.data.str = slice;
        if (!sc.within(slice)) return; // a curly quote keeps the position it was given
        const fresh = sc.strNode(slice);
        node.start_pos = fresh.start_pos;
        node.end_pos = fresh.end_pos;
    }

    /// Extends the text node `last` by `slice` when the two are contiguous in `src` and
    /// `last` carries no attributes: djot.js reports such text as one `str`.
    fn extendStr(sc: *const Scanner, last: *Node, slice: []const u8) bool {
        if (last.data != .str) return false;
        const sofar = last.data.str;
        if (sofar.ptr + sofar.len != slice.ptr) return false;
        if (last.id != null or last.attrs.len > 0) return false;
        last.data.str = sofar.ptr[0 .. sofar.len + slice.len];
        if (sc.map) |m| if (sc.within(last.data.str)) {
            last.end_pos = m.resolve(@intFromPtr(sofar.ptr) - @intFromPtr(sc.src.ptr) + sofar.len + slice.len - 1);
        };
        return true;
    }

    /// Appends text from `src`, extending the previous text node when it can. An open
    /// bracket is left alone: its opener points at it.
    fn text(sc: *Scanner, slice: []const u8) !void {
        const n_items = sc.items.items.len;
        const open_bracket = sc.openers.items.len > 0 and sc.openers.items[sc.openers.items.len - 1].item_idx + 1 == n_items;
        if (n_items > 0 and !open_bracket) {
            switch (sc.items.items[n_items - 1]) {
                .node => |*n| if (sc.extendStr(n, slice)) return,
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
                        // A backslash ending the block is a hard break on its newline, as djot.js.
                        sc.stripTrailingSpacesFromLastStr();
                        try sc.emit(.{ .data = .hard_break }, pos + 1, pos + 1);
                        pos += 1;
                    } else {
                        const next = src[pos + 1];
                        if (next == '\n') {
                            sc.stripTrailingSpacesFromLastStr();
                            try sc.emit(.{ .data = .hard_break }, pos + 1, pos + 1);
                            pos += 2;
                        } else if (next == ' ' or next == '\t') {
                            var skip = pos + 1;
                            while (skip < src.len and (src[skip] == ' ' or src[skip] == '\t')) skip += 1;
                            if (skip >= src.len or src[skip] == '\n') {
                                // A hard break, at the input's end too (djot.js ends its
                                // subject with a newline); it spans from the backslash on.
                                sc.stripTrailingSpacesFromLastStr();
                                try sc.emit(.{ .data = .hard_break }, pos + 1, skip);
                                pos = @min(skip + 1, src.len);
                            } else if (next == ' ') {
                                try sc.emit(.{ .data = .non_breaking_space }, pos + 1, pos + 1);
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
                        var node = Node{ .data = .{ .verbatim = content } };
                        var next_pos = after_close;
                        if (after_close + 1 < src.len and src[after_close] == '{' and src[after_close + 1] == '=') {
                            if (std.mem.indexOfScalarPos(u8, src, after_close, '}')) |fe| {
                                const format = src[after_close + 2 .. fe];
                                if (format.len > 0 and std.mem.indexOfScalar(u8, format, ' ') == null) {
                                    node = .{ .data = .{ .raw_inline = .{ .format = format, .text = content } } };
                                    next_pos = fe + 1;
                                }
                            }
                        }
                        // A raw inline ends on its closing ticks, before the format, as djot.js.
                        try sc.emit(node, pos, after_close - 1);
                        pos = next_pos;
                    } else {
                        try sc.emit(.{ .data = .{ .verbatim = trimVerbatimContent(src[after..]) } }, pos, src.len - 1);
                        pos = src.len;
                    }
                    text_start = pos;
                },
                '\n' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    try sc.emit(.{ .data = .soft_break }, pos, pos);
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
                    if (if (pos >= sc.attrs_from) try attrs.parseInlineAttrs(sc.a, src, pos) else null) |parsed| {
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
                    if (footnoteRefEnd(src, pos)) |close| {
                        try sc.emit(.{ .data = .{ .footnote_reference = try normalizeLabel(sc.a, src[pos + 2 .. close]) } }, pos, close);
                        pos = close + 1;
                        text_start = pos;
                        continue;
                    }
                    // The bracket is an item of its own: the opener's index points at it.
                    try sc.openers.append(sc.a, .{ .char = '[', .item_idx = sc.items.items.len, .src_pos = pos });
                    try sc.items.append(sc.a, .{ .node = sc.strNode(src[pos .. pos + 1]) });
                    pos += 1;
                    text_start = pos;
                },
                '!' => {
                    // `![^a]` is `!` and a footnote reference: djot.js decides an image at
                    // the closing bracket, where the reference has already matched.
                    if (pos + 1 < src.len and src[pos + 1] == '[' and footnoteRefEnd(src, pos + 1) == null) {
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
                        // `^}` closes a marked opener or is text; it never closes a bare `^`.
                        if (!try sc.handleBracedClose(c, pos)) try sc.text(src[pos .. pos + 2]);
                        pos += 2;
                        text_start = pos;
                        continue;
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
                            const content = src[content_start..close_pos];
                            try sc.emit(.{ .data = if (dollar_count == 2) .{ .display_math = content } else .{ .inline_math = content } }, pos, close_pos + tick_len - 1);
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
                    if (try sc.handleSymbol(&pos)) {
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
                        try sc.emit(.{ .data = .ellipsis }, pos, pos + 2);
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

    /// Before a line break: spaces and tabs go (djot.js); at the paragraph's end
    /// (`trimTrailingWhitespace`) only spaces do, a trailing tab being content there.
    fn stripTrailingSpacesFromLastStr(sc: *Scanner) void {
        if (sc.items.items.len == 0) return;
        switch (sc.items.items[sc.items.items.len - 1]) {
            .node => |*n| {
                if (n.data == .str) {
                    sc.setText(n, std.mem.trimEnd(u8, n.data.str, " \t"));
                    if (n.data.str.len == 0) _ = sc.items.pop();
                }
            },
            else => {},
        }
    }

    fn trimTrailingWhitespace(sc: *Scanner) void {
        while (sc.items.items.len > 0) {
            switch (sc.items.items[sc.items.items.len - 1]) {
                .node => |*n| {
                    if (n.data == .str) {
                        sc.setText(n, std.mem.trimEnd(u8, n.data.str, " "));
                        if (n.data.str.len == 0) {
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

    /// The innermost marked opener `{X` for `char`, when something follows it: an empty
    /// one closes nothing and ends the search, as djot.js (`{_a {__} b_}` keeps the first
    /// `{_` open and makes the inner `_}` text).
    fn markedOpener(sc: *const Scanner, char: u8) ?usize {
        var i = sc.openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = sc.openers.items[i];
            if (op.char == char and op.marked) return if (op.item_idx + 1 < sc.items.items.len) i else null;
        }
        return null;
    }

    /// Closes the marked opener `{X` with `X}` at `p` as a node of `tag` spanning both
    /// braces; false when no opener with content is there to close.
    fn closeMarked(sc: *Scanner, char: u8, tag: Tag, p: usize) !bool {
        const i = sc.markedOpener(char) orelse return false;
        const op = sc.openers.items[i];
        const children = try sc.collectChildren(op.item_idx);
        try sc.emit(inlineContainer(tag, children), op.src_pos, p + 1);
        sc.openers.items.len = i;
        return true;
    }

    fn handleBracedClose(sc: *Scanner, char: u8, p: usize) !bool {
        const tag: Tag = switch (char) {
            '-' => .delete,
            '+' => .insert,
            '=' => .mark,
            '~' => .subscript,
            '^' => .superscript,
            else => .span,
        };
        return sc.closeMarked(char, tag, p);
    }

    fn applyInlineAttrs(sc: *Scanner, ba: BlockAttrs) !void {
        if (ba.id == null and ba.attrs.len == 0) return;
        try sc.items.append(sc.a, .{ .pending_attrs = ba });
    }

    fn handleEmphDelimiter(sc: *Scanner, pos: *usize, char: u8, marked: bool) !void {
        const src = sc.src;
        const p = pos.*;

        if (!marked and p + 1 < src.len and src[p + 1] == '}') {
            if (!try sc.closeMarked(char, if (char == '*') .strong else .emph, p)) try sc.text(src[p .. p + 2]);
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
                        try sc.emit(inlineContainer(tag, children), op.src_pos, p);
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
                const is_image = op.char == '!';
                // djot.js starts an image on its bracket, not its `!`.
                const start = if (is_image) op.src_pos + 1 else op.src_pos;
                const next = p + 1;

                if (next < src.len and src[next] == '(') {
                    if (findMatchingParen(src, next)) |close_paren| {
                        const children = try sc.collectChildren(op.item_idx);
                        const raw_dest = src[next + 1 .. close_paren];
                        const dest = processUrl(sc.a, raw_dest) catch raw_dest;
                        try sc.emit(linkNode(is_image, .{ .children = children, .destination = dest }), start, close_paren);
                        pos.* = close_paren + 1;
                        sc.openers.items.len = i;
                        return;
                    }
                } else if (next < src.len and src[next] == '[') {
                    if (findMatchingBracket(src, next)) |close_ref| {
                        const children = try sc.collectChildren(op.item_idx);
                        // An empty `[]` stands for the link's text (djot.js's `getStringContent`);
                        // any other label, blanks only included, is keyed as written.
                        const raw_label = src[next + 1 .. close_ref];
                        const ref_label = if (raw_label.len == 0)
                            try normalizeLabel(sc.a, try getPlainText(sc.a, .{ .data = .{ .span = children } }))
                        else
                            try normalizeLabel(sc.a, try unescapeLabel(sc.a, raw_label));
                        try sc.emit(linkNode(is_image, .{ .children = children, .reference = ref_label }), start, close_ref);
                        pos.* = close_ref + 1;
                        sc.openers.items.len = i;
                        return;
                    }
                } else if (next < src.len and src[next] == '{') {
                    // A span, with the attributes when they parse; else the brace is text
                    // (djot.js). An image's `!` is text before it.
                    const children = try sc.collectChildren(op.item_idx);
                    if (is_image) try sc.items.append(sc.a, .{ .node = sc.strNode(src[op.src_pos .. op.src_pos + 1]) });
                    const span_node = Node{ .data = .{ .span = children } };
                    if (try attrs.parseInlineAttrs(sc.a, src, next)) |parsed| {
                        try sc.emit(try applyBlockAttrsToNode(sc.a, span_node, parsed.attrs), start, p);
                        pos.* = parsed.end;
                    } else {
                        try sc.emit(span_node, start, p);
                        pos.* = next;
                    }
                    sc.openers.items.len = i;
                    return;
                }

                // No link or image closes here: the `]` is text, and the bracket stays
                // open for a later one, text itself should none come. After `](` or `][`
                // the openers inside the pair are done with (`[x_y](x_` has no emphasis);
                // after a bare `]` they stay (`[_a]_` has), as djot.js.
                const clears = next < src.len and (src[next] == '(' or src[next] == '[');
                try sc.text(src[p .. p + 1]);
                pos.* = p + 1;
                if (clears) sc.openers.items.len = i + 1;
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
            try sc.emit(.{ .data = .{ .url = content } }, p, end);
            pos.* = end + 1;
            return true;
        }

        if (std.mem.indexOfScalar(u8, content, '@') != null and
            std.mem.indexOfScalar(u8, content, ' ') == null)
        {
            try sc.emit(.{ .data = .{ .email = content } }, p, end);
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
                    try sc.emit(inlineContainer(tag, children), op.src_pos, p);
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

    fn handleSymbol(sc: *Scanner, pos: *usize) !bool {
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
        try sc.emit(.{ .data = .{ .symb = name } }, p, end);
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
                3 => try sc.emit(.{ .data = .em_dash }, at, at + 2),
                2 => try sc.emit(.{ .data = .en_dash }, at, at + 1),
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
            if (!try sc.closeMarked(char, if (char == '"') .double_quoted else .single_quoted, p)) {
                const curly: []const u8 = if (char == '\'') "\u{2019}" else "\u{201d}";
                try sc.emit(.{ .data = .{ .str = curly } }, p, p + 1);
            }
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
                        try sc.emit(inlineContainer(tag, children), op.src_pos, p);
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
            try sc.emit(.{ .data = .{ .str = curly } }, p, p);
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
            return sc.positioned(.{ .data = .{ .str = curly } }, op.src_pos, op.src_pos + @as(usize, if (op.marked) 1 else 0));
        }
        const len: usize = if (op.marked) 2 else 1;
        return sc.strNode(sc.src[op.src_pos .. op.src_pos + len]);
    }

    /// Appends a node, joining text to the previous node when it can: an opener that did
    /// not close leaves text djot.js reports as one `str`.
    fn appendNode(sc: *const Scanner, nodes: *std.ArrayList(Node), node: Node) !void {
        if (node.data == .str and nodes.items.len > 0 and sc.extendStr(&nodes.items[nodes.items.len - 1], node.data.str)) return;
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

    /// An attribute attached to nothing: its id was read all the same.
    fn dropId(sc: *Scanner, ba: BlockAttrs) !void {
        if (ba.id) |id| try sc.dropped.append(sc.a, id);
    }

    fn applyAttrsToResolved(sc: *Scanner, nodes: *std.ArrayList(Node), ba: BlockAttrs) !void {
        if (nodes.items.len == 0) return sc.dropId(ba);
        const last = &nodes.items[nodes.items.len - 1];
        switch (last.data) {
            .str => |last_text| {
                if (last_text.len == 0) return sc.dropId(ba);
                var word_start = last_text.len;
                while (word_start > 0 and last_text[word_start - 1] != ' ' and
                    last_text[word_start - 1] != '\t' and last_text[word_start - 1] != '\n')
                {
                    word_start -= 1;
                }
                if (word_start == last_text.len) return sc.dropId(ba);

                var gather_start = nodes.items.len - 1;
                if (word_start == 0) {
                    while (gather_start > 0) {
                        const prev = nodes.items[gather_start - 1];
                        if (prev.data != .str) break;
                        const pt = prev.data.str;
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
                        const first_text = nodes.items[gather_start].data.str;
                        try span_children.append(sc.a, sc.strNode(first_text[word_start..]));
                        for (nodes.items[gather_start + 1 ..]) |n| try span_children.append(sc.a, n);
                    } else {
                        for (nodes.items[gather_start..]) |n| try span_children.append(sc.a, n);
                    }
                } else {
                    try span_children.append(sc.a, sc.strNode(last_text[word_start..]));
                }

                const kids = try span_children.toOwnedSlice(sc.a);
                var span_node = Node{ .data = .{ .span = kids }, .start_pos = kids[0].start_pos, .end_pos = kids[kids.len - 1].end_pos };
                span_node = try applyBlockAttrsToNode(sc.a, span_node, ba);

                if (word_start > 0 and gather_start < nodes.items.len - 1) {
                    sc.setText(&nodes.items[gather_start], nodes.items[gather_start].data.str[0..word_start]);
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
            .url,
            .email,
            .inline_math,
            .display_math,
            .footnote_reference,
            .symb,
            => {
                if (last.id) |old| {
                    if (ba.id != null) try sc.dropped.append(sc.a, old);
                }
                nodes.items[nodes.items.len - 1] = try applyLaterAttrsToNode(sc.a, last.*, ba);
            },
            else => try sc.dropId(ba),
        }
    }
};

/// A block attribute applied to the block after it. A block with attributes of its own
/// (a div's class) keeps them after the block attribute's, classes joined, as djot.js:
/// `{.x}` before `::: y` gives `class="x y"`.
pub fn applyBlockAttrsToNode(a: Allocator, node: Node, ba: BlockAttrs) !Node {
    var result = node;
    if (node.attrs.len > 0 and ba.attrs.len > 0) {
        const merged = try ba.merge(.{ .attrs = node.attrs }, a);
        result.attrs = merged.attrs;
    } else if (ba.attrs.len > 0) {
        result.attrs = ba.attrs;
    }
    if (ba.id) |id| result.id = id;
    return result;
}

/// A later inline attribute applied to a node that has one: the first keeps its places,
/// the later's values win and its classes join after, as djot.js's attribute object
/// (`[x]{#i .c}{.d}` gives `id="i" class="c d"`).
fn applyLaterAttrsToNode(a: Allocator, node: Node, ba: BlockAttrs) !Node {
    const merged = try (BlockAttrs{ .id = node.id, .attrs = node.attrs }).merge(ba, a);
    var result = node;
    result.attrs = merged.attrs;
    result.id = merged.id;
    return result;
}

/// Where a footnote reference opening at `pos` (`[^`) ends: its first `]`, with a label of
/// at least one byte on the line between, as djot.js's `[^\]]+`; `[^]` is text.
fn footnoteRefEnd(src: []const u8, pos: usize) ?usize {
    if (pos + 1 >= src.len or src[pos + 1] != '^') return null;
    const close = std.mem.indexOfScalarPos(u8, src, pos + 2, ']') orelse return null;
    if (close == pos + 2 or std.mem.indexOfScalar(u8, src[pos + 2 .. close], '\n') != null) return null;
    return close;
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

/// Whether a backslash before `c` escapes it: any ASCII punctuation (djot.js's
/// `pattPunctuation`).
fn isEscapable(c: u8) bool {
    return switch (c) {
        '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '"', '\'', '~', '^', ':', '<', '>', '$', '%', '=', '&', ',', '/', ';', '?', '@' => true,
        else => false,
    };
}

/// Where an escaped line end starting at `i` (the byte after the backslash) ends: the
/// newline after any spaces and tabs, as djot.js's `[ \t]*\n`.
fn escapedLineEnd(raw: []const u8, i: usize) ?usize {
    var j = i;
    while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
    return if (j < raw.len and raw[j] == '\n') j else null;
}

/// Whether the backslash at `i` goes in a label or destination: before punctuation, a
/// space (`\ ` is a space there, djot.js) or a line end.
fn backslashGoes(raw: []const u8, i: usize) bool {
    if (i + 1 >= raw.len) return false;
    return isEscapable(raw[i + 1]) or raw[i + 1] == ' ' or escapedLineEnd(raw, i + 1) != null;
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

/// The `)` closing the destination opened at `pos`, by depth; an escaped byte does not
/// count (`processUrl` unescapes it).
fn findMatchingParen(src: []const u8, pos: usize) ?usize {
    if (pos >= src.len or src[pos] != '(') return null;
    var depth: usize = 1;
    var i = pos + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\') {
            i += 1;
            continue;
        }
        if (src[i] == '(') depth += 1;
        if (src[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// The `]` closing the bracket at `pos`, by depth; an escaped byte does not count.
fn findMatchingBracket(src: []const u8, pos: usize) ?usize {
    if (pos >= src.len or src[pos] != '[') return null;
    var depth: usize = 1;
    var i = pos + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\') {
            i += 1;
            continue;
        }
        if (src[i] == '[') depth += 1;
        if (src[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// A reference label as djot.js keys it: a backslash before an escapable byte goes.
fn unescapeLabel(a: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out = try std.ArrayList(u8).initCapacity(a, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and backslashGoes(raw, i)) i += 1;
        out.appendAssumeCapacity(raw[i]);
    }
    return out.items;
}

fn processUrl(a: Allocator, raw: []const u8) ![]const u8 {
    const needs_processing = std.mem.indexOfScalar(u8, raw, '\n') != null or
        std.mem.indexOfScalar(u8, raw, '\\') != null;
    if (!needs_processing) return raw;
    var buf: std.ArrayList(u8) = .empty;
    var kept: usize = 0; // up to here the bytes came from escapes: never trimmed
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\n') {
            // A line end joins the lines, the next line's indent dropped (djot.js).
            i += 1;
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
        } else if (raw[i] == '\\' and escapedLineEnd(raw, i + 1) != null) {
            // An escaped line end takes the blanks before it too, as djot.js trims the
            // text before a hard break (an escaped space stays); the blanks after the
            // backslash stay, and the newline takes the line-end branch.
            while (buf.items.len > kept and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) buf.items.len -= 1;
            i += 1;
        } else if (raw[i] == '\\' and backslashGoes(raw, i)) {
            try buf.append(a, raw[i + 1]);
            i += 2;
            kept = buf.items.len;
        } else {
            try buf.append(a, raw[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(a);
}
pub fn normalizeLabel(a: Allocator, raw: []const u8) ![]const u8 {
    // As djot.js keys labels: trimmed, each run of whitespace one space; `raw` itself
    // when it is so already.
    const needs_normalization = (raw.len > 0 and (raw[0] == ' ' or raw[raw.len - 1] == ' ')) or for (raw, 0..) |c, i| {
        if (c == '\n' or c == '\r' or c == '\t' or (c == ' ' and i + 1 < raw.len and raw[i + 1] == ' ')) break true;
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

/// The string content of a node, as djot.js's `getStringContent`: every node's text
/// (a symbol's alias and a footnote reference's label excepted, as the djot.js suite has
/// it for heading ids), a newline for each break, children otherwise. Heading ids and
/// reference labels are made from it.
pub fn getPlainText(a: Allocator, node: Node) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try addPlainText(a, &buf, node);
    return buf.toOwnedSlice(a);
}

fn addPlainText(a: Allocator, buf: *std.ArrayList(u8), node: Node) !void {
    switch (node.data) {
        .symb, .footnote_reference => {},
        .soft_break, .hard_break => try buf.append(a, '\n'),
        else => if (node.text().len > 0) {
            try buf.appendSlice(a, node.text());
        } else for (node.children()) |child| {
            try addPlainText(a, buf, child);
        },
    }
}

/// A container inline of `tag` over `children`.
fn inlineContainer(tag: Tag, children: []const Node) Node {
    return .{ .data = switch (tag) {
        .emph => .{ .emph = children },
        .strong => .{ .strong = children },
        .span => .{ .span = children },
        .mark => .{ .mark = children },
        .superscript => .{ .superscript = children },
        .subscript => .{ .subscript = children },
        .insert => .{ .insert = children },
        .delete => .{ .delete = children },
        .double_quoted => .{ .double_quoted = children },
        .single_quoted => .{ .single_quoted = children },
        else => unreachable,
    } };
}

fn linkNode(is_image: bool, link: node_mod.Link) Node {
    return .{ .data = if (is_image) .{ .image = link } else .{ .link = link } };
}

/// `lines` joined by newlines: a block's text for the inline parser.
pub fn joinLines(a: Allocator, lines: []const []const u8) ![]const u8 {
    return join(a, lines, false);
}

/// `lines` each followed by a newline: a code block's text.
pub fn joinLinesTerminated(a: Allocator, lines: []const []const u8) ![]const u8 {
    return join(a, lines, true);
}

fn join(a: Allocator, lines: []const []const u8, terminated: bool) ![]const u8 {
    if (lines.len == 0) return "";
    var total: usize = if (terminated) lines.len else lines.len - 1;
    for (lines) |line| total += line.len;
    const buf = try a.alloc(u8, total);
    var p: usize = 0;
    for (lines, 0..) |line, idx| {
        if (idx > 0) {
            buf[p] = '\n';
            p += 1;
        }
        @memcpy(buf[p..][0..line.len], line);
        p += line.len;
    }
    if (terminated) buf[p] = '\n';
    return buf;
}

/// A reference link's attributes with its definition's, as djot.js: the definition's that
/// the link does not set come first, then the link's own in their order; nothing joins.
pub fn mergeRefAttrs(node: Node, ref_attrs: BlockAttrs, a: Allocator) !Node {
    var result = node;
    if (result.id == null) result.id = ref_attrs.id;
    if (ref_attrs.attrs.len == 0) return result;
    if (result.attrs.len == 0) {
        result.attrs = ref_attrs.attrs;
        return result;
    }
    var merged: std.ArrayList(@import("node.zig").Attr) = .empty;
    for (ref_attrs.attrs) |ra| {
        const overridden = for (result.attrs) |na| {
            if (std.mem.eql(u8, ra.key, na.key)) break true;
        } else false;
        if (!overridden) try merged.append(a, ra);
    }
    for (result.attrs) |na| try merged.append(a, na);
    result.attrs = try merged.toOwnedSlice(a);
    return result;
}
