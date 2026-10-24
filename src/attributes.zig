//! Parser for djot attributes: `{#id .class key="value" %comment%}`.
//! Used for both block-level and inline attributes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Attr = @import("node.zig").Attr;

pub const BlockAttrs = struct {
    id: ?[]const u8 = null,
    classes: ?[]const u8 = null,
    attrs: []const Attr = &.{},

    pub fn merge(self: BlockAttrs, other: BlockAttrs, a: Allocator) !BlockAttrs {
        var result = BlockAttrs{};
        result.id = other.id orelse self.id;

        var merged: std.ArrayList(Attr) = .empty;
        var class_buf: std.ArrayList(u8) = .empty;

        for (self.attrs) |sa| {
            if (std.mem.eql(u8, sa.key, "class")) {
                if (class_buf.items.len > 0) try class_buf.append(a, ' ');
                try class_buf.appendSlice(a, sa.value);
            }
        }
        for (other.attrs) |oa| {
            if (std.mem.eql(u8, oa.key, "class")) {
                if (class_buf.items.len > 0) try class_buf.append(a, ' ');
                try class_buf.appendSlice(a, oa.value);
            }
        }

        for (self.attrs) |sa| {
            if (std.mem.eql(u8, sa.key, "class")) continue;
            var overridden = false;
            for (other.attrs) |oa| {
                if (std.mem.eql(u8, sa.key, oa.key)) {
                    overridden = true;
                    break;
                }
            }
            if (!overridden) try merged.append(a, sa);
        }

        for (other.attrs) |oa| {
            if (std.mem.eql(u8, oa.key, "class")) continue;
            try merged.append(a, oa);
        }

        if (class_buf.items.len > 0) {
            try merged.append(a, .{ .key = "class", .value = try class_buf.toOwnedSlice(a) });
        }

        if (self.classes != null or other.classes != null) {
            result.classes = other.classes orelse self.classes;
        }
        if (merged.items.len > 0) {
            result.attrs = try merged.toOwnedSlice(a);
        }
        return result;
    }

    /// A deep copy in `a`, sharing no bytes with the source or the text it was parsed from.
    pub fn dupe(self: BlockAttrs, a: Allocator) !BlockAttrs {
        const attrs = try a.alloc(Attr, self.attrs.len);
        for (self.attrs, attrs) |src, *dst| {
            dst.* = .{ .key = try a.dupe(u8, src.key), .value = try a.dupe(u8, src.value) };
        }
        return .{
            .id = if (self.id) |id| try a.dupe(u8, id) else null,
            .classes = if (self.classes) |c| try a.dupe(u8, c) else null,
            .attrs = attrs,
        };
    }
};

pub const AttrParseStatus = enum { done, fail, @"continue" };

pub const AttrParser = struct {
    src: []const u8,
    state: AttrState,
    begin: ?usize,
    lastpos: ?usize,
    result: BlockAttrs,
    attrs_list: std.ArrayList(Attr),
    value_buf: std.ArrayList(u8),
    current_key: ?[]const u8,
    a: Allocator,

    const AttrState = enum {
        start,
        scanning,
        scanning_id,
        scanning_class,
        scanning_key,
        scanning_value,
        scanning_bare_value,
        scanning_quoted_value,
        scanning_escaped,
        scanning_comment,
        done,
        fail,
    };

    pub fn init(a: Allocator, src: []const u8) AttrParser {
        return .{
            .src = src,
            .state = .start,
            .begin = null,
            .lastpos = null,
            .result = .{},
            .attrs_list = .empty,
            .value_buf = .empty,
            .current_key = null,
            .a = a,
        };
    }

    pub fn feed(self: *AttrParser, startpos: usize, endpos: usize) struct { status: AttrParseStatus, position: usize } {
        var pos = startpos;
        while (pos <= endpos and pos < self.src.len) {
            self.state = self.step(pos);
            if (self.state == .done) return .{ .status = .done, .position = pos };
            if (self.state == .fail) return .{ .status = .fail, .position = pos };
            self.lastpos = pos;
            pos += 1;
        }
        return .{ .status = .@"continue", .position = if (endpos < self.src.len) endpos else self.src.len -| 1 };
    }

    fn step(self: *AttrParser, pos: usize) AttrState {
        const c = self.src[pos];
        return switch (self.state) {
            .start => if (c == '{') .scanning else .fail,
            .scanning => self.stepScanning(c, pos),
            .scanning_id => self.stepScanningId(c, pos),
            .scanning_class => self.stepScanningClass(c, pos),
            .scanning_key => self.stepScanningKey(c, pos),
            .scanning_value => self.stepScanningValue(c, pos),
            .scanning_bare_value => self.stepScanningBareValue(c, pos),
            .scanning_quoted_value => self.stepScanningQuotedValue(c, pos),
            .scanning_escaped => .scanning_quoted_value,
            .scanning_comment => self.stepScanningComment(c),
            .done => .done,
            .fail => .fail,
        };
    }

    fn stepScanning(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') return .scanning;
        if (c == '}') return .done;
        if (c == '#') {
            self.begin = pos;
            return .scanning_id;
        }
        if (c == '%') {
            self.begin = pos;
            return .scanning_comment;
        }
        if (c == '.') {
            self.begin = pos;
            return .scanning_class;
        }
        if (isName(c)) {
            self.begin = pos;
            return .scanning_key;
        }
        return .fail;
    }

    fn stepScanningId(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (isIdChar(c)) return .scanning_id;
        if (c == '}') {
            self.emitId(pos);
            return .done;
        }
        if (isAttrWhitespace(c)) {
            self.emitId(pos);
            return .scanning;
        }
        return .fail;
    }

    fn stepScanningClass(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (isName(c)) return .scanning_class;
        if (c == '}') {
            self.emitClass(pos);
            return .done;
        }
        if (isAttrWhitespace(c)) {
            self.emitClass(pos);
            return .scanning;
        }
        return .fail;
    }

    fn stepScanningKey(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (c == '=' and self.begin != null) {
            self.current_key = self.src[self.begin.?..pos];
            self.begin = null;
            return .scanning_value;
        }
        if (isName(c)) return .scanning_key;
        return .fail;
    }

    fn stepScanningValue(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (c == '"') {
            self.begin = pos;
            self.value_buf.items.len = 0;
            return .scanning_quoted_value;
        }
        if (isName(c)) {
            self.begin = pos;
            return .scanning_bare_value;
        }
        return .fail;
    }

    fn stepScanningBareValue(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (isName(c)) return .scanning_bare_value;
        if (c == '}') {
            self.emitBareValue(pos);
            return .done;
        }
        if (isAttrWhitespace(c)) {
            self.emitBareValue(pos);
            return .scanning;
        }
        return .fail;
    }

    fn stepScanningQuotedValue(self: *AttrParser, c: u8, pos: usize) AttrState {
        if (c == '"') {
            self.emitQuotedValue(pos);
            return .scanning;
        }
        if (c == '\\') return .scanning_escaped;
        if (c == '\n') {
            if (self.begin) |b| {
                self.value_buf.appendSlice(self.a, self.src[b + 1 .. pos]) catch {};
                self.value_buf.appendSlice(self.a, " ") catch {};
                self.begin = pos;
            }
            return .scanning_quoted_value;
        }
        return .scanning_quoted_value;
    }

    fn stepScanningComment(self: *AttrParser, c: u8) AttrState {
        _ = self;
        if (c == '%') return .scanning;
        if (c == '}') return .done;
        return .scanning_comment;
    }

    fn emitId(self: *AttrParser, pos: usize) void {
        if (self.begin) |b| {
            const lp = if (self.lastpos) |l| l else pos -| 1;
            if (lp >= b) {
                self.result.id = self.src[b + 1 .. pos];
            }
            self.begin = null;
        }
    }

    fn emitClass(self: *AttrParser, pos: usize) void {
        if (self.begin) |b| {
            const cls = self.src[b + 1 .. pos];
            self.attrs_list.append(self.a, .{ .key = "class", .value = cls }) catch {};
            self.begin = null;
        }
    }

    fn emitBareValue(self: *AttrParser, pos: usize) void {
        if (self.begin) |b| {
            const value = self.src[b..pos];
            if (self.current_key) |key| {
                self.attrs_list.append(self.a, .{ .key = key, .value = value }) catch {};
                self.current_key = null;
            }
            self.begin = null;
        }
    }

    fn emitQuotedValue(self: *AttrParser, pos: usize) void {
        if (self.value_buf.items.len > 0) {
            if (self.begin) |b| {
                self.value_buf.appendSlice(self.a, self.src[b + 1 .. pos]) catch {};
            }
            if (self.current_key) |key| {
                const raw = self.value_buf.toOwnedSlice(self.a) catch &.{};
                const value = self.processEscapes(raw);
                self.attrs_list.append(self.a, .{ .key = key, .value = value }) catch {};
                self.current_key = null;
            }
        } else if (self.begin) |b| {
            const value = self.processEscapes(self.src[b + 1 .. pos]);
            if (self.current_key) |key| {
                self.attrs_list.append(self.a, .{ .key = key, .value = value }) catch {};
                self.current_key = null;
            }
        }
        self.begin = null;
    }

    fn processEscapes(self: *AttrParser, raw: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                buf.append(self.a, raw[i + 1]) catch {};
                i += 2;
            } else {
                buf.append(self.a, raw[i]) catch {};
                i += 1;
            }
        }
        return buf.toOwnedSlice(self.a) catch raw;
    }

    pub fn finish(self: *AttrParser) BlockAttrs {
        var result = self.result;
        if (self.attrs_list.items.len > 0) {
            var merged: std.ArrayList(Attr) = .empty;
            var class_buf: std.ArrayList(u8) = .empty;
            var class_inserted = false;
            for (self.attrs_list.items) |attr| {
                if (std.mem.eql(u8, attr.key, "class")) {
                    if (class_buf.items.len > 0) class_buf.append(self.a, ' ') catch {};
                    class_buf.appendSlice(self.a, attr.value) catch {};
                    if (!class_inserted) {
                        merged.append(self.a, .{ .key = "class", .value = "" }) catch {};
                        class_inserted = true;
                    }
                } else {
                    merged.append(self.a, attr) catch {};
                }
            }
            if (class_buf.items.len > 0) {
                const class_val = class_buf.toOwnedSlice(self.a) catch "";
                for (merged.items) |*m| {
                    if (std.mem.eql(u8, m.key, "class") and m.value.len == 0) {
                        m.value = class_val;
                        break;
                    }
                }
            }
            result.attrs = merged.toOwnedSlice(self.a) catch &.{};
        }
        return result;
    }

    fn isName(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':';
    }

    fn isIdChar(c: u8) bool {
        if (c <= ' ') return false;
        return switch (c) {
            ']', '[', '~', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '{', '}', '`', ',', '.', '<', '>', '\\', '|', '=', '+', '/', '?', '"', '\'' => false,
            else => true,
        };
    }

    fn isAttrWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

pub fn tryParseBlockAttr(a: Allocator, line: []const u8) ?BlockAttrs {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 2) return null;
    if (trimmed[0] != '{') return null;
    if (trimmed[trimmed.len - 1] != '}') return null;
    return parseAttrsFromStr(a, trimmed);
}

pub fn parseAttrsFromStr(a: Allocator, src: []const u8) ?BlockAttrs {
    if (src.len < 2 or src[0] != '{') return null;
    var parser = AttrParser.init(a, src);
    const result = parser.feed(0, src.len -| 1);
    if (result.status == .done) return parser.finish();
    return null;
}

/// Whether `line` opens a block attribute it does not close: `{` followed by attribute
/// syntax that is still incomplete at the end of the line.
pub fn opensAttr(a: Allocator, line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 1 or trimmed[0] != '{') return false;
    var parser = AttrParser.init(a, trimmed);
    return parser.feed(0, trimmed.len -| 1).status == .@"continue";
}

pub fn parseInlineAttrs(a: Allocator, src: []const u8, pos: usize) ?struct { attrs: BlockAttrs, end: usize } {
    if (pos >= src.len or src[pos] != '{') return null;
    var parser = AttrParser.init(a, src);
    const result = parser.feed(pos, src.len -| 1);
    if (result.status == .done) return .{ .attrs = parser.finish(), .end = result.position + 1 };
    return null;
}
