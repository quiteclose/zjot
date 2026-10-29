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
    /// The opener of the same kind below this one, if any (`Scanner.tops`).
    prev_same: ?usize = null,
    /// A bracket whose `](` or `][` has come: djot.js's `explicit_link` or
    /// `reference_link`, closed by the `)` or `]` the forward pass comes to.
    link: ?LinkOpen = null,

    /// Whether a closer at `p` would make an empty pair: the delimiters touch in the
    /// source (djot.js's `opener.endpos === pos - 1`), whatever stood between them made
    /// no text (`{_{}_}` is an empty emphasis, `{__}` none).
    fn touches(op: OpenerInfo, p: usize) bool {
        return op.src_pos + @intFromBool(op.marked) + 1 == p;
    }
};

const LinkOpen = struct {
    reference: bool,
    /// The item of the `](` or `][`: the link's text is the items before it, and the
    /// items from it on are the destination or label, which is read off `src` instead.
    item_idx: usize,
    /// Where its `]` is in `src`.
    src_pos: usize,
    /// `Scanner.dropped` as it was then: an id read in the destination or label is
    /// text once the link closes, which djot.js does not register.
    dropped_len: usize,
};

/// Parses `src`, one paragraph's worth of joined lines. With `map`, every node carries
/// the document position of the source it came from; without, none does. No inline
/// attribute is read before `attrs_from` (the text of a failed block attribute). An id read
/// but attached to no node, or overridden by a later attribute's, goes to `dropped`: djot.js
/// registers it all the same.
/// `ends_line` says whether a line end follows `src` (a table cell's does not), which is
/// where a backslash ending it is a hard break (djot.js ends a block's subject with a
/// newline, a cell's not).
/// `a` is for what the nodes keep; `scratch` for the scanner's working lists, which the
/// caller may reset once the nodes are returned (`dropped` grows on it too).
pub fn parseInlineContent(a: Allocator, scratch: Allocator, src: []const u8, map: ?LineMap, attrs_from: usize, dropped: *std.ArrayList([]const u8), ends_line: bool) Allocator.Error![]const Node {
    var sc = Scanner{ .a = a, .scratch = scratch, .src = src, .map = map, .attrs_from = attrs_from, .dropped = dropped, .ends_line = ends_line };
    try sc.run();
    return sc.resolveItems(sc.items.items);
}

/// The scanner's state over one run of joined text. Nodes enter `items` through `emit`
/// (a span of `src`, both ends inclusive) or `text` (a slice of `src`), so no node is
/// made without the source it came from.
const Scanner = struct {
    a: Allocator,
    scratch: Allocator,
    src: []const u8,
    map: ?LineMap,
    attrs_from: usize = 0,
    dropped: *std.ArrayList([]const u8),
    ends_line: bool,
    items: std.ArrayList(InlineItem) = .empty,
    openers: std.ArrayList(OpenerInfo) = .empty,
    /// The nearest open opener of each kind (its char, marked or not), chained down
    /// through `OpenerInfo.prev_same`, as djot.js keys its openers by kind: a closer
    /// finds its opener, or learns there is none, without walking the openers of other
    /// kinds above it, which a line of unmatched openers would make quadratic. Small, as
    /// it is cleared for every leaf.
    tops: [kinds]?usize = .{null} ** kinds,
    /// Set at a `](` and cleared when a link closes on its `)`, as djot.js's
    /// `destination`, which a destination never closed leaves set: while set, `(` and
    /// `)` pair up, and a `)` with no `(` to pair closes the nearest bracket's link when
    /// that bracket is an explicit link.
    destination: bool = false,
    /// Where each `(` read in the destination stands, unpaired so far: djot.js's `(`
    /// openers, which a match over them clears as it clears every opener inside it.
    parens: std.ArrayList(usize) = .empty,
    /// No footnote reference opens before here (`footnoteRefEnd`).
    no_footnote_before: usize = 0,

    const kinds = 22;

    /// An opener's kind: one of the eleven chars that open, marked or not.
    fn kind(char: u8, marked: bool) usize {
        const c: usize = switch (char) {
            '[' => 0,
            '!' => 1,
            '*' => 2,
            '_' => 3,
            '~' => 4,
            '^' => 5,
            '+' => 6,
            '-' => 7,
            '=' => 8,
            '\'' => 9,
            '"' => 10,
            else => unreachable,
        };
        return c * 2 + @intFromBool(marked);
    }

    fn pushOpener(sc: *Scanner, opener: OpenerInfo) !void {
        var op = opener;
        const top = &sc.tops[kind(op.char, op.marked)];
        op.prev_same = top.*;
        top.* = sc.openers.items.len;
        try sc.openers.append(sc.scratch, op);
    }

    fn topOpener(sc: *const Scanner, char: u8, marked: bool) ?usize {
        return sc.tops[kind(char, marked)];
    }

    /// Drops the openers from `len` up, each kind's top falling back to the one below,
    /// and the parens from where the lowest of them starts.
    fn truncateOpeners(sc: *Scanner, len: usize) void {
        if (len < sc.openers.items.len) sc.dropParens(sc.openers.items[len].src_pos);
        while (sc.openers.items.len > len) {
            const op = sc.openers.pop().?;
            sc.tops[kind(op.char, op.marked)] = op.prev_same;
        }
    }

    /// Drops the parens read at or after `from`.
    fn dropParens(sc: *Scanner, from: usize) void {
        while (sc.parens.items.len > 0 and sc.parens.items[sc.parens.items.len - 1] >= from) _ = sc.parens.pop();
    }

    fn positioned(sc: *const Scanner, node: Node, start: usize, end: usize) Node {
        const map = sc.map orelse return node;
        var n = node;
        n.start_pos = map.resolve(start);
        n.end_pos = map.resolve(end);
        return n;
    }

    fn emit(sc: *Scanner, node: Node, start: usize, end: usize) !void {
        try sc.items.append(sc.scratch, .{ .node = sc.positioned(node, start, end) });
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
        try sc.items.append(sc.scratch, .{ .node = sc.strNode(slice) });
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
                        // A backslash ending the block is a hard break on its newline, as
                        // djot.js; ending a cell, which has none, it is text.
                        if (sc.ends_line) {
                            sc.trimLastText(pos, " \t");
                            try sc.emit(.{ .data = .hard_break }, pos + 1, pos + 1);
                        } else {
                            try sc.text(src[pos .. pos + 1]);
                        }
                        pos += 1;
                    } else {
                        const next = src[pos + 1];
                        if (next == '\n') {
                            sc.trimLastText(pos, " \t");
                            try sc.emit(.{ .data = .hard_break }, pos + 1, pos + 1);
                            pos += 2;
                        } else if (next == ' ' or next == '\t') {
                            var skip = pos + 1;
                            while (skip < src.len and (src[skip] == ' ' or src[skip] == '\t')) skip += 1;
                            if ((skip < src.len and src[skip] == '\n') or (skip >= src.len and sc.ends_line)) {
                                // A hard break, at the input's end too (djot.js ends its
                                // subject with a newline); it spans from the backslash on.
                                sc.trimLastText(pos, " \t");
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
                        if (rawFormatEnd(src, after_close)) |fe| {
                            node = .{ .data = .{ .raw_inline = .{ .format = src[after_close + 2 .. fe], .text = content } } };
                            next_pos = fe + 1;
                        }
                        // A raw inline ends on its closing ticks, before the format, as djot.js.
                        try sc.emit(node, pos, after_close - 1);
                        pos = next_pos;
                    } else {
                        const rest = sc.unclosedRest(after);
                        try sc.emit(.{ .data = .{ .verbatim = trimVerbatimContent(rest) } }, pos, after + rest.len - 1);
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
                // One rule for the four matched delimiters (djot.js's `betweenMatched`).
                '*', '_', '~', '^' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    try sc.handleEmphDelimiter(&pos, c, false);
                    text_start = pos;
                },
                '{' => {
                    if (pos + 1 < src.len) {
                        const next = src[pos + 1];
                        if (next == '_' or next == '*' or next == '~' or next == '^') {
                            if (pos > text_start) try sc.text(src[text_start..pos]);
                            pos += 1;
                            try sc.handleEmphDelimiter(&pos, next, true);
                            text_start = pos;
                            continue;
                        } else if (next == '+' or next == '-' or next == '=') {
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
                    if (sc.footnoteRefEnd(pos)) |close| {
                        try sc.emit(.{ .data = .{ .footnote_reference = try normalizeLabel(sc.a, src[pos + 2 .. close]) } }, pos, close);
                        pos = close + 1;
                        text_start = pos;
                        continue;
                    }
                    // The bracket is an item of its own: the opener's index points at it.
                    try sc.pushOpener(.{ .char = '[', .item_idx = sc.items.items.len, .src_pos = pos });
                    try sc.items.append(sc.scratch, .{ .node = sc.strNode(src[pos .. pos + 1]) });
                    pos += 1;
                    text_start = pos;
                },
                '!' => {
                    // `![^a]` is `!` and a footnote reference: djot.js decides an image at
                    // the closing bracket, where the reference has already matched.
                    if (pos + 1 < src.len and src[pos + 1] == '[' and sc.footnoteRefEnd(pos + 1) == null) {
                        if (pos > text_start) try sc.text(src[text_start..pos]);
                        try sc.pushOpener(.{ .char = '!', .item_idx = sc.items.items.len, .src_pos = pos });
                        try sc.items.append(sc.scratch, .{ .node = sc.strNode(src[pos .. pos + 2]) });
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
                '(' => {
                    if (sc.destination) try sc.parens.append(sc.scratch, pos);
                    pos += 1;
                },
                ')' => {
                    if (sc.destination and sc.parens.pop() == null) {
                        if (pos > text_start) try sc.text(src[text_start..pos]);
                        try sc.handleCloseParen(&pos);
                        text_start = pos;
                    } else {
                        pos += 1;
                    }
                },
                '<' => {
                    if (pos > text_start) try sc.text(src[text_start..pos]);
                    if (!try sc.handleAutolink(&pos)) {
                        try sc.text(src[pos .. pos + 1]);
                        pos += 1;
                    }
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
                            try sc.emit(mathNode(dollar_count, trimVerbatimContent(src[content_start..close_pos])), pos, close_pos + tick_len - 1);
                            pos = close_pos + tick_len;
                        } else {
                            // Unclosed, math to the end, as an unclosed verbatim (djot.js).
                            const rest = sc.unclosedRest(content_start);
                            try sc.emit(mathNode(dollar_count, trimVerbatimContent(rest)), pos, content_start + rest.len - 1);
                            pos = src.len;
                        }
                        text_start = pos;
                        continue;
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
        sc.trimLastText(src.len, " ");
    }

    /// Drops `blanks` from the end of the last text node when it ends at `end` of `src`,
    /// before a line break (spaces and tabs) or at the paragraph's end (spaces only, a
    /// trailing tab being content there): djot.js trims its last match only when that
    /// match is text, so the spaces before an empty attribute or a comment, which make no
    /// node, stay.
    fn trimLastText(sc: *Scanner, end: usize, blanks: []const u8) void {
        if (sc.items.items.len == 0) return;
        switch (sc.items.items[sc.items.items.len - 1]) {
            .node => |*n| if (n.data == .str and sc.within(n.data.str) and
                @intFromPtr(n.data.str.ptr) + n.data.str.len == @intFromPtr(sc.src.ptr) + end)
            {
                sc.setText(n, std.mem.trimEnd(u8, n.data.str, blanks));
                if (n.data.str.len == 0) _ = sc.items.pop();
            },
            else => {},
        }
    }

    /// The text from `from` to the end, the span an unclosed verbatim or math takes: at a
    /// paragraph's end its trailing spaces go, as text's would (djot.js trims the last
    /// match before the closing newline; a cell has none).
    fn unclosedRest(sc: *const Scanner, from: usize) []const u8 {
        const rest = sc.src[from..];
        return if (sc.ends_line) std.mem.trimEnd(u8, rest, " ") else rest;
    }

    /// The innermost marked opener `{X` for `char`, when its pair with the closer at `p`
    /// is not empty: an empty one closes nothing and ends the search, as djot.js
    /// (`{_a {__} b_}` keeps the first `{_` open and makes the inner `_}` text).
    fn markedOpener(sc: *const Scanner, char: u8, p: usize) ?usize {
        const i = sc.topOpener(char, true) orelse return null;
        return if (sc.openers.items[i].touches(p)) null else i;
    }

    /// Closes the marked opener `{X` with `X}` at `p` as a node of `tag` spanning both
    /// braces; false when no opener is there to close, or its pair would be empty.
    fn closeMarked(sc: *Scanner, char: u8, tag: Tag, p: usize) !bool {
        const i = sc.markedOpener(char, p) orelse return false;
        if (sc.outsideLink(i)) return false;
        const op = sc.openers.items[i];
        const children = try sc.collectChildren(op.item_idx);
        try sc.emit(inlineContainer(tag, children), op.src_pos, p + 1);
        sc.truncateOpeners(i);
        return true;
    }

    fn handleBracedClose(sc: *Scanner, char: u8, p: usize) !bool {
        const tag: Tag = switch (char) {
            '-' => .delete,
            '+' => .insert,
            '=' => .mark,
            else => .span,
        };
        return sc.closeMarked(char, tag, p);
    }

    /// The node a matched delimiter makes: djot.js's `betweenMatched` annotations.
    fn matchedTag(char: u8) Tag {
        return switch (char) {
            '*' => .strong,
            '_' => .emph,
            '~' => .subscript,
            else => .superscript,
        };
    }

    fn applyInlineAttrs(sc: *Scanner, ba: BlockAttrs) !void {
        if (ba.id == null and ba.attrs.len == 0) return;
        // Attributes written one after another apply as one object, as djot.js's would
        // one key at a time: an id the later overrides was read all the same.
        if (sc.items.items.len > 0) if (sc.items.items[sc.items.items.len - 1] == .pending_attrs) {
            const prev = &sc.items.items[sc.items.items.len - 1].pending_attrs;
            if (prev.id) |old| if (ba.writesId()) try sc.dropped.append(sc.scratch, old);
            try prev.apply(ba, sc.a);
            return;
        };
        try sc.items.append(sc.scratch, .{ .pending_attrs = ba });
    }

    fn handleEmphDelimiter(sc: *Scanner, pos: *usize, char: u8, marked: bool) !void {
        const src = sc.src;
        const p = pos.*;

        if (!marked and p + 1 < src.len and src[p + 1] == '}') {
            if (!try sc.closeMarked(char, matchedTag(char), p)) try sc.text(src[p .. p + 2]);
            pos.* = p + 2;
            return;
        }

        const can_close = canCloseDelim(src, p) and !marked;
        if (can_close) if (sc.topOpener(char, marked)) |i| {
            const op = sc.openers.items[i];
            if (!op.touches(p)) { // an empty pair closes nothing
                if (sc.outsideLink(i)) {
                    try sc.text(src[p .. p + 1]);
                    pos.* = p + 1;
                    return;
                }
                const children = try sc.collectChildren(op.item_idx);
                try sc.emit(inlineContainer(matchedTag(char), children), op.src_pos, p);
                sc.truncateOpeners(i);
                pos.* = p + 1;
                return;
            }
        };

        const can_open = marked or canOpenDelim(src, p);
        if (can_open) {
            const opener = OpenerInfo{ .char = char, .item_idx = sc.items.items.len, .src_pos = if (marked) p - 1 else p, .marked = marked };
            try sc.pushOpener(opener);
            try sc.items.append(sc.scratch, .{ .opener = opener });
            pos.* = p + 1;
            return;
        }

        try sc.text(src[p .. p + 1]);
        pos.* = p + 1;
    }

    fn handleBracedSpan(sc: *Scanner, pos: *usize) !void {
        const p = pos.*;
        const opener = OpenerInfo{ .char = sc.src[p + 1], .item_idx = sc.items.items.len, .src_pos = p, .marked = true };
        try sc.pushOpener(opener);
        try sc.items.append(sc.scratch, .{ .opener = opener });
        pos.* = p + 2;
    }

    /// Where a footnote reference opening at `pos` (`[^`) ends: its first `]`, with a label
    /// of at least one byte on the line between, as djot.js's `[^\]]+` over the line; `[^]`
    /// is text. A scan that meets the line's end or the input's first has shown every `[^`
    /// before that point to fail too, which is kept, so a line of them is linear.
    fn footnoteRefEnd(sc: *Scanner, pos: usize) ?usize {
        const src = sc.src;
        if (pos + 1 >= src.len or src[pos + 1] != '^' or pos < sc.no_footnote_before) return null;
        var close = pos + 2;
        while (close < src.len and src[close] != ']' and src[close] != '\n') : (close += 1) {}
        if (close >= src.len or src[close] == '\n') {
            sc.no_footnote_before = close;
            return null;
        }
        return if (close == pos + 2) null else close;
    }

    /// The nearest bracket opener of either kind.
    fn nearestBracket(sc: *const Scanner) ?usize {
        const b = sc.topOpener('[', false) orelse return sc.topOpener('!', false);
        const e = sc.topOpener('!', false) orelse return b;
        return @max(b, e);
    }

    /// Whether a closer is kept from the opener at `i`: inside an open destination, an
    /// opener before the link's bracket, which djot.js after 0.3.2 does not match there and
    /// its suite expects (`*[a](b*)` is `*` and a link). The closer is then text, and
    /// opens nothing.
    fn outsideLink(sc: *const Scanner, i: usize) bool {
        if (!sc.destination) return false;
        const b = sc.nearestBracket() orelse return false;
        const open = sc.openers.items[b].link orelse return false;
        return !open.reference and i < b;
    }

    /// Closes the link or image the bracket opener `i` began, on the `)` or `]` at `end`:
    /// its text is the items before its `](` or `][`, and those from it on go.
    fn closeLink(sc: *Scanner, i: usize, link: node_mod.Link, end: usize) !void {
        const op = sc.openers.items[i];
        const open = op.link.?;
        sc.items.items.len = open.item_idx;
        sc.dropped.items.len = open.dropped_len;
        var l = link;
        l.children = try sc.collectChildren(op.item_idx);
        const is_image = op.char == '!';
        // djot.js starts an image on its bracket, not its `!`.
        try sc.emit(linkNode(is_image, l), if (is_image) op.src_pos + 1 else op.src_pos, end);
        sc.truncateOpeners(i);
    }

    fn handleCloseBracket(sc: *Scanner, pos: *usize) !void {
        const src = sc.src;
        const p = pos.*;
        const i = sc.nearestBracket() orelse {
            try sc.text(src[p .. p + 1]);
            pos.* = p + 1;
            return;
        };
        const op = sc.openers.items[i];
        const next = p + 1;

        if (op.link) |open| if (open.reference) {
            // The label as written: `keyLabel` keys it once the leaf is bounded, for the
            // links that survive it (a label holding links drops them, and keying each
            // would read every label inside another again).
            try sc.closeLink(i, .{ .reference = src[open.src_pos + 2 .. p] }, p);
            pos.* = p + 1;
            return;
        };

        if (next < src.len and (src[next] == '(' or src[next] == '[')) {
            // The link closes where the destination or label does, as the pass comes to
            // it; what follows until then is read as any text. The openers inside the
            // link's text are done with (`[x_y](x_` has no emphasis), parens among them.
            sc.truncateOpeners(i + 1);
            sc.dropParens(op.src_pos);
            sc.openers.items[i].link = .{ .reference = src[next] == '[', .item_idx = sc.items.items.len, .src_pos = p, .dropped_len = sc.dropped.items.len };
            try sc.items.append(sc.scratch, .{ .node = sc.strNode(src[p .. p + 2]) });
            if (src[next] == '(') {
                sc.destination = true;
                sc.parens.clearRetainingCapacity();
            }
            pos.* = p + 2;
            return;
        }

        if (next < src.len and src[next] == '{') {
            // A span, with the attributes when they parse; else the brace is text
            // (djot.js). An image's `!` is text before it.
            const is_image = op.char == '!';
            const children = try sc.collectChildren(op.item_idx);
            if (is_image) try sc.items.append(sc.scratch, .{ .node = sc.strNode(src[op.src_pos .. op.src_pos + 1]) });
            const span_node = Node{ .data = .{ .span = children } };
            const start = if (is_image) op.src_pos + 1 else op.src_pos;
            if (try attrs.parseInlineAttrs(sc.a, src, next)) |parsed| {
                try sc.emit(try applyBlockAttrsToNode(sc.a, span_node, parsed.attrs), start, p);
                pos.* = parsed.end;
            } else {
                try sc.emit(span_node, start, p);
                pos.* = next;
            }
            sc.truncateOpeners(i);
            return;
        }

        // A bare `]` is text, and the openers inside stay (`[_a]_` has emphasis), as djot.js.
        try sc.text(src[p .. p + 1]);
        pos.* = p + 1;
    }

    /// A `)` in a destination with no `(` of its own to pair: it closes the link of the
    /// nearest bracket when that bracket is an explicit link, as djot.js, and is text
    /// otherwise.
    fn handleCloseParen(sc: *Scanner, pos: *usize) !void {
        const p = pos.*;
        if (sc.nearestBracket()) |i| if (sc.openers.items[i].link) |open| if (!open.reference) {
            const raw_dest = sc.src[open.src_pos + 2 .. p];
            try sc.closeLink(i, .{ .destination = try processUrl(sc.a, raw_dest) }, p);
            sc.destination = false;
            pos.* = p + 1;
            return;
        };
        try sc.text(sc.src[p .. p + 1]);
        pos.* = p + 1;
    }

    /// An autolink, as djot.js's `<([^<>\s]+)>`: an email when an `@` follows a byte other
    /// than `:`, else a URL when a letter is followed by `:`; text otherwise. The scan
    /// stops at the first blank or `<`, so a run of `<` without `>` is linear.
    fn handleAutolink(sc: *Scanner, pos: *usize) !bool {
        const src = sc.src;
        const p = pos.*;
        var end = p + 1;
        while (end < src.len and src[end] != '>') : (end += 1) {
            if (src[end] == '<' or jsSpaceLen(src, end) > 0) return false;
        }
        if (end >= src.len or end == p + 1) return false;
        const content = src[p + 1 .. end];
        const is_email = for (content[1..], 1..) |c, i| {
            if (c == '@' and content[i - 1] != ':') break true;
        } else false;
        const is_url = !is_email and for (content[1..], 1..) |c, i| {
            if (c == ':' and std.ascii.isAlphabetic(content[i - 1])) break true;
        } else false;
        if (!is_email and !is_url) return false;
        try sc.emit(.{ .data = if (is_email) .{ .email = content } else .{ .url = content } }, p, end);
        pos.* = end + 1;
        return true;
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
                const curly: []const u8 = if (char == '\'') right_single else right_double;
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

        if (can_close) if (sc.topOpener(char, false)) |i| {
            const op = sc.openers.items[i];
            if (!op.touches(p)) {
                if (sc.outsideLink(i)) {
                    try sc.emit(.{ .data = .{ .str = if (char == '\'') right_single else left_double } }, p, p);
                    pos.* = p + 1;
                    return;
                }
                const tag: Tag = if (char == '"') .double_quoted else .single_quoted;
                const children = try sc.collectChildren(op.item_idx);
                try sc.emit(inlineContainer(tag, children), op.src_pos, p);
                sc.truncateOpeners(i);
                pos.* = p + 1;
                return;
            }
        };

        if (can_open) {
            const opener = OpenerInfo{ .char = char, .item_idx = sc.items.items.len, .src_pos = if (marked) p - 1 else p, .marked = marked };
            try sc.pushOpener(opener);
            try sc.items.append(sc.scratch, .{ .opener = opener });
        } else {
            // Can't open or close: emit a typographic quote as literal text.
            // Single quote becomes right curly (') for apostrophe contexts;
            // double quote becomes left curly (") as the more common standalone form.
            const curly: []const u8 = if (char == '\'') right_single else left_double;
            try sc.emit(.{ .data = .{ .str = curly } }, p, p);
        }
        pos.* = p + 1;
    }

    /// The nodes after the opener at `opener_idx`, which are removed from `items`. The
    /// list is sized by its items, each of which makes at most one node (an attribute
    /// that splits a word into text and span counts for the span), and filled in place
    /// on `a`: no growth, no copy.
    fn collectChildren(sc: *Scanner, opener_idx: usize) ![]const Node {
        var children: std.ArrayList(Node) = .initBuffer(try sc.a.alloc(Node, sc.items.items.len - opener_idx - 1));
        for (sc.items.items[opener_idx + 1 ..]) |item| {
            switch (item) {
                .node => |n| try sc.appendNode(&children, n),
                .opener => |op| try sc.appendOpener(&children, op),
                .pending_attrs => |pa| try sc.applyAttrsToResolved(&children, pa),
            }
        }
        sc.items.items.len = opener_idx;
        return children.items;
    }

    /// The text of an opener that never closed.
    fn openerNode(sc: *const Scanner, op: OpenerInfo) Node {
        if (op.char == '\'' or op.char == '"') {
            const curly: []const u8 = if (op.marked)
                (if (op.char == '\'') left_single else left_double)
            else
                (if (op.char == '\'') right_single else left_double);
            return sc.positioned(.{ .data = .{ .str = curly } }, op.src_pos, op.src_pos + @as(usize, if (op.marked) 1 else 0));
        }
        const len: usize = if (op.marked) 2 else 1;
        return sc.strNode(sc.src[op.src_pos .. op.src_pos + len]);
    }

    /// Appends the text of an opener that never closed. A marked one starts a text node of
    /// its own, as djot.js's open marker breaks the run of text before it; the text after
    /// it joins it (in a cell djot.js joins no text at all, AST difference 12).
    fn appendOpener(sc: *const Scanner, nodes: *std.ArrayList(Node), op: OpenerInfo) !void {
        const node = sc.openerNode(op);
        if (op.marked) nodes.appendAssumeCapacity(node) else try sc.appendNode(nodes, node);
    }

    /// Appends a node, joining text to the previous node when it can: an opener that did
    /// not close leaves text djot.js reports as one `str`.
    fn appendNode(sc: *const Scanner, nodes: *std.ArrayList(Node), node: Node) !void {
        if (node.data == .str and nodes.items.len > 0 and sc.extendStr(&nodes.items[nodes.items.len - 1], node.data.str)) return;
        nodes.appendAssumeCapacity(node);
    }

    /// The items as nodes, sized and filled as `collectChildren` fills its list.
    fn resolveItems(sc: *Scanner, items: []const InlineItem) ![]const Node {
        var nodes: std.ArrayList(Node) = .initBuffer(try sc.a.alloc(Node, items.len));
        for (items) |item| {
            switch (item) {
                .node => |n| try sc.appendNode(&nodes, n),
                .opener => |op| try sc.appendOpener(&nodes, op),
                .pending_attrs => |pa| try sc.applyAttrsToResolved(&nodes, pa),
            }
        }
        return nodes.items;
    }

    /// An attribute attached to nothing: its id was read all the same.
    fn dropId(sc: *Scanner, ba: BlockAttrs) !void {
        if (ba.id) |id| try sc.dropped.append(sc.scratch, id);
    }

    fn applyAttrsToResolved(sc: *Scanner, nodes: *std.ArrayList(Node), ba: BlockAttrs) !void {
        if (nodes.items.len == 0) return sc.dropId(ba);
        const last = &nodes.items[nodes.items.len - 1];
        switch (last.data) {
            // The last word of the text node, as djot.js splits it off: no text across
            // another node is gathered. A smart quote is not text there, and takes the
            // attribute itself.
            .str => |last_text| if (isSmartQuote(last_text)) {
                try sc.attachToLast(nodes, ba);
            } else {
                // After the last blank of any kind JavaScript's `\s` counts (djot.js's
                // `[^\s]+$`), found forward since a blank may be several bytes.
                var word_start: usize = 0;
                var i: usize = 0;
                while (i < last_text.len) {
                    const n = jsSpaceLen(last_text, i);
                    i += @max(n, 1);
                    if (n > 0) word_start = i;
                }
                if (word_start == last_text.len) return sc.dropId(ba);
                const kids = try sc.a.alloc(Node, 1);
                kids[0] = sc.strNode(last_text[word_start..]);
                const span_node = try applyBlockAttrsToNode(sc.a, .{ .data = .{ .span = kids }, .start_pos = kids[0].start_pos, .end_pos = kids[0].end_pos }, ba);
                if (word_start > 0) {
                    sc.setText(last, last_text[0..word_start]);
                    nodes.appendAssumeCapacity(span_node);
                } else {
                    last.* = span_node;
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
            => try sc.attachToLast(nodes, ba),
            else => try sc.dropId(ba),
        }
    }

    fn attachToLast(sc: *Scanner, nodes: *std.ArrayList(Node), ba: BlockAttrs) !void {
        const last = &nodes.items[nodes.items.len - 1];
        if (last.id) |old| {
            if (ba.writesId()) try sc.dropped.append(sc.scratch, old);
        }
        last.* = try applyLaterAttrsToNode(sc.a, last.*, ba);
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

/// Where a raw format opening at `pos` (`{=`) ends: its `}`, with one or more bytes
/// between other than blanks (JavaScript's `\s`), braces and backticks, as djot.js's
/// `\{=[^\s{}`]+\}`.
fn rawFormatEnd(src: []const u8, pos: usize) ?usize {
    if (pos + 1 >= src.len or src[pos] != '{' or src[pos + 1] != '=') return null;
    var i = pos + 2;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '}' => return if (i > pos + 2) i else null,
            '{', '`' => return null,
            else => if (jsSpaceLen(src, i) > 0) return null,
        }
    }
    return null;
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
/// The length of the JavaScript `\s` character at `i` of `text`, 0 when none: the ASCII
/// blanks (tab to carriage return, space) and, in UTF-8, U+00A0, U+1680, U+2000 to
/// U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF.
pub fn jsSpaceLen(text: []const u8, i: usize) usize {
    const c = text[i];
    if (c == ' ' or (c >= 0x09 and c <= 0x0D)) return 1;
    const rest = text[i..];
    if (rest.len >= 2 and c == 0xC2 and rest[1] == 0xA0) return 2;
    if (rest.len >= 3) {
        if (c == 0xE1 and rest[1] == 0x9A and rest[2] == 0x80) return 3;
        if (c == 0xE2 and rest[1] == 0x80 and ((rest[2] >= 0x80 and rest[2] <= 0x8A) or rest[2] == 0xA8 or rest[2] == 0xA9 or rest[2] == 0xAF)) return 3;
        if (c == 0xE2 and rest[1] == 0x81 and rest[2] == 0x9F) return 3;
        if (c == 0xE3 and rest[1] == 0x80 and rest[2] == 0x80) return 3;
        if (c == 0xEF and rest[1] == 0xBB and rest[2] == 0xBF) return 3;
    }
    return 0;
}

/// `raw` with the JavaScript `\s` characters at either end dropped (JavaScript's `trim`).
fn jsTrim(raw: []const u8) []const u8 {
    var start: usize = 0;
    while (start < raw.len) {
        const n = jsSpaceLen(raw, start);
        if (n == 0) break;
        start += n;
    }
    var end: usize = raw.len;
    while (end > start) {
        const n = for (1..4) |k| {
            if (end >= start + k and jsSpaceLen(raw, end - k) == k) break k;
        } else 0;
        if (n == 0) break;
        end -= n;
    }
    return raw[start..end];
}

pub fn normalizeLabel(a: Allocator, raw: []const u8) ![]const u8 {
    // As djot.js keys labels: JavaScript's `trim`, then each run of space, tab, CR and LF
    // one space; `raw` itself when it is so already.
    const trimmed = jsTrim(raw);
    const needs_collapse = for (trimmed, 0..) |c, i| {
        if (c == '\n' or c == '\r' or c == '\t' or (c == ' ' and i + 1 < trimmed.len and trimmed[i + 1] == ' ')) break true;
    } else false;
    if (!needs_collapse) return trimmed;
    var buf: std.ArrayList(u8) = .empty;
    var in_ws = false;
    for (trimmed) |c| {
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
    try addPlainText(a, &buf, node, false);
    return buf.toOwnedSlice(a);
}

/// As `getPlainText`, with a footnote reference's label, as djot.js keys a `[]` label
/// (the heading-id exclusion is deliberate difference 2).
pub fn getLabelText(a: Allocator, node: Node) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try addPlainText(a, &buf, node, true);
    return buf.toOwnedSlice(a);
}

/// Keys a link or image written by reference: the scanner leaves its label as written,
/// and here it is keyed as djot.js keys it (escapes dropped, then `normalizeLabel`). An
/// empty `[]` stands for the link's text (djot.js's `getStringContent`), as
/// `getLabelText` reads it; any other label, blanks only included, is keyed as written.
/// The parser calls this once per node from its first walk over the leaf, after the walk
/// has bounded what stands below the node, so the text is never read deeper than
/// `max_nesting`; nothing reads the link before that walk.
pub fn keyLabel(a: Allocator, node: *Node) Allocator.Error!void {
    switch (node.data) {
        .link, .image => |*l| if (l.destination == null) if (l.reference) |raw| {
            l.reference = try normalizeLabel(a, if (raw.len == 0)
                try getLabelText(a, .{ .data = .{ .span = l.children } })
            else
                try unescapeLabel(a, raw));
        },
        else => {},
    }
}

/// The quotes smart punctuation makes, one slice each, so that the text behind a node is
/// known to be the source's `'` or `"` and not a curly quote written as such.
const left_single = "\u{2018}";
const right_single = "\u{2019}";
const left_double = "\u{201c}";
const right_double = "\u{201d}";

fn isSmartQuote(text: []const u8) bool {
    return text.ptr == left_single.ptr or text.ptr == right_single.ptr or
        text.ptr == left_double.ptr or text.ptr == right_double.ptr;
}

fn addPlainText(a: Allocator, buf: *std.ArrayList(u8), node: Node, footnote_labels: bool) !void {
    switch (node.data) {
        .symb => {},
        .footnote_reference => |label| if (footnote_labels) try buf.appendSlice(a, label),
        .soft_break, .hard_break => try buf.append(a, '\n'),
        // Smart punctuation reads as its source, as djot.js's `getStringContent`.
        .ellipsis => try buf.appendSlice(a, "..."),
        .em_dash => try buf.appendSlice(a, "---"),
        .en_dash => try buf.appendSlice(a, "--"),
        .str => |text| if (text.ptr == left_single.ptr or text.ptr == right_single.ptr) {
            try buf.append(a, '\'');
        } else if (isSmartQuote(text)) {
            try buf.append(a, '"');
        } else {
            try buf.appendSlice(a, text);
        },
        else => if (node.text().len > 0) {
            try buf.appendSlice(a, node.text());
        } else for (node.children()) |child| {
            try addPlainText(a, buf, child, footnote_labels);
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

fn mathNode(dollars: usize, content: []const u8) Node {
    return .{ .data = if (dollars == 2) .{ .display_math = content } else .{ .inline_math = content } };
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
