//! Parser for djot attributes: `{#id .class key="value" %comment%}`.
//! Used for both block-level and inline attributes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Attr = @import("node.zig").Attr;

/// `attrs` hold every attribute as djot.js's attribute object holds them (`AttrObject`):
/// a key keeps its first position and takes its last value, `id=x` the same key as `#x`;
/// a `.c` joins the classes before it and `class=c` starts them over. `id` is the
/// non-empty `id` among them.
pub const BlockAttrs = struct {
    id: ?[]const u8 = null,
    attrs: []const Attr = &.{},
    /// What the list can grow to in place before `apply` reallocates it, 0 for a slice
    /// this object does not own (a node's, a parsed one's), which the first application
    /// copies. An object applied to again and again grows geometrically, so a run of
    /// applications costs what its result holds, not the sum of what it held.
    attrs_cap: usize = 0,
    /// The same for the buffer the class value is joined in.
    class_cap: usize = 0,
    /// The object's index by key, once it has one (`AttrObject`); none for a borrowed list.
    index: ?*AttrObject.Index = null,

    /// `attrs` as the block attributes they are, the id read off them: an empty `id=""`
    /// stays an attribute and names nothing, as djot.js tests the id's truthiness.
    pub fn fromAttrs(attrs: []const Attr) BlockAttrs {
        return .{ .id = idOf(attrs), .attrs = attrs };
    }

    fn idOf(attrs: []const Attr) ?[]const u8 {
        const id = find(attrs, "id") orelse "";
        return if (id.len > 0) id else null;
    }

    /// `other` applied over `self` in place, as djot.js applies one attribute's object to
    /// the one before it: each key set as `AttrObject.set` sets it, a `class` joined to the
    /// classes before it (a later block attribute, or a later inline attribute on the same
    /// node).
    pub fn apply(self: *BlockAttrs, other: BlockAttrs, a: Allocator) !void {
        var obj = AttrObject{ .list = .{ .items = @constCast(self.attrs), .capacity = self.attrs_cap }, .class_cap = self.class_cap, .index = self.index };
        if (self.attrs_cap == 0) { // not this object's to write: copied first, with room
            obj = .{};
            try obj.list.ensureTotalCapacity(a, @max(8, 2 * (self.attrs.len + other.attrs.len)));
            obj.list.appendSliceAssumeCapacity(self.attrs);
            try obj.indexIfLong(a); // a copied list that is long already is indexed before any key is set
        }
        for (other.attrs) |oa| try obj.set(a, oa.key, oa.value, std.mem.eql(u8, oa.key, "class"));
        const id = if (obj.find("id")) |i| obj.list.items[i].value else "";
        self.* = .{ .id = if (id.len > 0) id else null, .attrs = obj.list.items, .attrs_cap = obj.list.capacity, .class_cap = obj.class_cap, .index = obj.index };
    }

    /// `other` applied over a copy of `self`, which stays as it is.
    pub fn merge(self: BlockAttrs, other: BlockAttrs, a: Allocator) !BlockAttrs {
        var copy = BlockAttrs{ .attrs = self.attrs }; // borrowed: `apply` copies before it writes
        try copy.apply(other, a);
        return copy;
    }

    /// Whether an id was written, `#x` or `id=`, empty included: a later one overrides
    /// the id before it, which djot.js registered all the same.
    pub fn writesId(self: BlockAttrs) bool {
        return find(self.attrs, "id") != null;
    }

    fn find(attrs: []const Attr, key: []const u8) ?[]const u8 {
        for (attrs) |attr| if (std.mem.eql(u8, attr.key, key)) return attr.value;
        return null;
    }

    /// A deep copy in `a`, sharing no bytes with the source or the text it was parsed from.
    pub fn dupe(self: BlockAttrs, a: Allocator) !BlockAttrs {
        const attrs = try a.alloc(Attr, self.attrs.len);
        for (self.attrs, attrs) |src, *dst| {
            dst.* = .{ .key = try a.dupe(u8, src.key), .value = try a.dupe(u8, src.value) };
        }
        return .{
            .id = if (self.id) |id| try a.dupe(u8, id) else null,
            .attrs = attrs,
        };
    }
};

/// An attribute object under construction, djot.js's: `set` keeps a key's first position
/// and gives it the last value, `join` adding the value after the one there with a space
/// (a `.class`, and a class merged from a later block attribute or a later inline
/// attribute on the same node); `class=c` written as a
/// key starts the classes over, and `id=x` is the id as `#x` is. A key is found by a
/// scan of the list while the list is short and by an index once it is not, so a run of
/// a thousand keys costs a thousand sets, not a million comparisons.
const AttrObject = struct {
    list: std.ArrayList(Attr) = .empty,
    /// The room in the buffer the class value is joined in (`joinClass`), 0 for none.
    class_cap: usize = 0,
    index: ?*Index = null,

    const Index = std.StringHashMapUnmanaged(usize);
    const index_from = 32;

    fn find(self: *const AttrObject, key: []const u8) ?usize {
        if (self.index) |ix| return ix.get(key);
        for (self.list.items, 0..) |attr, i| if (std.mem.eql(u8, attr.key, key)) return i;
        return null;
    }

    fn set(self: *AttrObject, a: Allocator, key: []const u8, value: []const u8, join: bool) !void {
        if (self.find(key)) |i| {
            const attr = &self.list.items[i];
            if (join and attr.value.len > 0) {
                attr.value = try joinClass(a, &self.class_cap, attr.value, value);
            } else {
                attr.value = value;
                if (std.mem.eql(u8, key, "class")) self.class_cap = 0;
            }
            return;
        }
        try self.list.append(a, .{ .key = key, .value = value });
        if (self.index) |ix| try ix.put(a, key, self.list.items.len - 1) else try self.indexIfLong(a);
    }

    /// Builds the index once the list is past `index_from` keys, from whatever the list
    /// holds: the key just appended, or a long list copied in.
    fn indexIfLong(self: *AttrObject, a: Allocator) !void {
        if (self.index != null or self.list.items.len <= index_from) return;
        const ix = try a.create(Index);
        ix.* = .{};
        for (self.list.items, 0..) |attr, i| try ix.put(a, attr.key, i);
        self.index = ix;
    }
};

/// `value` after `sofar` and a space, in a buffer that doubles as it fills: `cap` is the
/// buffer's size when `sofar` is in one, else 0 and a buffer is made.
fn joinClass(a: Allocator, cap: *usize, sofar: []const u8, value: []const u8) ![]const u8 {
    const need = sofar.len + 1 + value.len;
    var buf: []u8 = undefined;
    if (cap.* >= need) {
        buf = @constCast(sofar.ptr)[0..cap.*];
    } else {
        buf = try a.alloc(u8, @max(2 * need, 16));
        @memcpy(buf[0..sofar.len], sofar);
        cap.* = buf.len;
    }
    buf[sofar.len] = ' ';
    @memcpy(buf[sofar.len + 1 .. need], value);
    return buf[0..need];
}

pub const AttrParseStatus = enum { done, fail, @"continue" };

pub const AttrParser = struct {
    src: []const u8,
    state: AttrState,
    begin: ?usize,
    lastpos: ?usize,
    /// The attributes read so far.
    obj: AttrObject = .{},
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
            .value_buf = .empty,
            .current_key = null,
            .a = a,
        };
    }

    /// Steps through `src[startpos..endpos]`, `endpos` included, without feeding a line
    /// end after it: `done` at the `}`, `fail` at the byte that failed, else `continue` at
    /// the last byte fed.
    pub fn feed(self: *AttrParser, startpos: usize, endpos: usize) !struct { status: AttrParseStatus, position: usize } {
        var pos = startpos;
        while (pos <= endpos and pos < self.src.len) {
            self.state = try self.step(pos);
            if (self.state == .done) return .{ .status = .done, .position = pos };
            if (self.state == .fail) return .{ .status = .fail, .position = pos };
            self.lastpos = pos;
            pos += 1;
        }
        return .{ .status = .@"continue", .position = if (endpos < self.src.len) endpos else self.src.len -| 1 };
    }

    /// What one line of a block attribute leaves the parser at: complete at its `}` (what
    /// stands after it on the line is the caller's), unfinished at the line end, or
    /// failed at an index into the line, or at the line's length for the line end itself.
    pub const Fed = union(enum) { complete: usize, unfinished, failed_at: usize };

    /// Feeds `line`, the block attribute's next line as written, and the line end after
    /// it, as djot.js feeds each line to the parser its container keeps. The attributes
    /// keep slices of `line`, so it must outlive them. An id, a class or a bare value ends
    /// at the line end, a comment runs on, and a key or a `=` still waiting for its value
    /// fails there; a quoted value runs on, its text so far kept and the next line's read
    /// from that line's start (`valueFrom`).
    pub fn feedLine(self: *AttrParser, line: []const u8) !Fed {
        self.src = line;
        self.lastpos = null;
        for (line, 0..) |c, pos| {
            self.state = try self.stepByte(c, pos);
            if (self.state == .done) return .{ .complete = pos };
            if (self.state == .fail) return .{ .failed_at = pos };
            self.lastpos = pos;
        }
        switch (self.state) {
            // An escaped line end is the value's, as the newline it escapes.
            .scanning_quoted_value, .scanning_escaped => {
                try self.value_buf.appendSlice(self.a, line[self.valueFrom()..]);
                try self.value_buf.append(self.a, '\n');
                self.begin = null;
                self.state = .scanning_quoted_value;
            },
            else => {
                self.state = try self.stepByte('\n', line.len);
                if (self.state == .done) return .{ .complete = line.len };
                if (self.state == .fail) return .{ .failed_at = line.len };
            },
        }
        return .unfinished;
    }

    /// Where a quoted value's text starts in `src`: after its quote or the newline last
    /// flushed, or at the start of a line fed on its own.
    fn valueFrom(self: *const AttrParser) usize {
        return if (self.begin) |b| b + 1 else 0;
    }

    fn step(self: *AttrParser, pos: usize) !AttrState {
        return self.stepByte(self.src[pos], pos);
    }

    fn stepByte(self: *AttrParser, c: u8, pos: usize) !AttrState {
        return switch (self.state) {
            .start => if (c == '{') .scanning else .fail,
            .scanning => try self.stepScanning(c, pos),
            .scanning_id => try self.stepScanningId(c, pos),
            .scanning_class => try self.stepScanningClass(c, pos),
            .scanning_key => try self.stepScanningKey(c, pos),
            .scanning_value => try self.stepScanningValue(c, pos),
            .scanning_bare_value => try self.stepScanningBareValue(c, pos),
            .scanning_quoted_value => try self.stepScanningQuotedValue(c, pos),
            .scanning_escaped => .scanning_quoted_value,
            .scanning_comment => try self.stepScanningComment(c),
            .done => .done,
            .fail => .fail,
        };
    }

    fn stepScanning(self: *AttrParser, c: u8, pos: usize) !AttrState {
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

    fn stepScanningId(self: *AttrParser, c: u8, pos: usize) !AttrState {
        if (isIdChar(c)) return .scanning_id;
        if (c == '}') {
            try self.emitId(pos);
            return .done;
        }
        if (isAttrWhitespace(c)) {
            try self.emitId(pos);
            return .scanning;
        }
        return .fail;
    }

    fn stepScanningClass(self: *AttrParser, c: u8, pos: usize) !AttrState {
        if (isName(c)) return .scanning_class;
        if (c == '}') {
            try self.emitClass(pos);
            return .done;
        }
        if (isAttrWhitespace(c)) {
            try self.emitClass(pos);
            return .scanning;
        }
        return .fail;
    }

    fn stepScanningKey(self: *AttrParser, c: u8, pos: usize) !AttrState {
        if (c == '=' and self.begin != null) {
            self.current_key = self.src[self.begin.?..pos];
            self.begin = null;
            return .scanning_value;
        }
        if (isName(c)) return .scanning_key;
        return .fail;
    }

    fn stepScanningValue(self: *AttrParser, c: u8, pos: usize) !AttrState {
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

    fn stepScanningBareValue(self: *AttrParser, c: u8, pos: usize) !AttrState {
        if (isName(c)) return .scanning_bare_value;
        if (c == '}') {
            try self.emitBareValue(pos);
            return .done;
        }
        if (isAttrWhitespace(c)) {
            try self.emitBareValue(pos);
            return .scanning;
        }
        return .fail;
    }

    fn stepScanningQuotedValue(self: *AttrParser, c: u8, pos: usize) !AttrState {
        if (c == '"') {
            try self.emitQuotedValue(pos);
            return .scanning;
        }
        if (c == '\\') return .scanning_escaped;
        if (c == '\n') {
            if (self.begin) |b| {
                try self.value_buf.appendSlice(self.a, self.src[b + 1 .. pos]);
                try self.value_buf.appendSlice(self.a, " ");
                self.begin = pos;
            }
            return .scanning_quoted_value;
        }
        return .scanning_quoted_value;
    }

    fn stepScanningComment(self: *AttrParser, c: u8) !AttrState {
        _ = self;
        if (c == '%') return .scanning;
        if (c == '}') return .done;
        return .scanning_comment;
    }

    /// The id is the `id` attribute, so renderers write it where it was written; a second
    /// `#id` keeps the first's place with the last value, as djot.js's object does.
    fn emitId(self: *AttrParser, pos: usize) !void {
        if (self.begin) |b| {
            const lp = if (self.lastpos) |l| l else pos -| 1;
            if (lp > b) try self.obj.set(self.a, "id", self.src[b + 1 .. pos], false); // an empty `#` names nothing (djot.js)
            self.begin = null;
        }
    }

    fn emitClass(self: *AttrParser, pos: usize) !void {
        if (self.begin) |b| {
            const lp = if (self.lastpos) |l| l else pos -| 1;
            if (lp > b) try self.obj.set(self.a, "class", self.src[b + 1 .. pos], true); // an empty `.` names nothing (djot.js)
            self.begin = null;
        }
    }

    fn emitBareValue(self: *AttrParser, pos: usize) !void {
        if (self.begin) |b| {
            const value = self.src[b..pos];
            if (self.current_key) |key| {
                try self.obj.set(self.a, key, value, false);
                self.current_key = null;
            }
            self.begin = null;
        }
    }

    fn emitQuotedValue(self: *AttrParser, pos: usize) !void {
        if (self.value_buf.items.len > 0) {
            try self.value_buf.appendSlice(self.a, self.src[self.valueFrom()..pos]);
            if (self.current_key) |key| {
                const raw = try self.value_buf.toOwnedSlice(self.a);
                const value = try self.processEscapes(try self.collapseBlanks(raw));
                try self.obj.set(self.a, key, value, false);
                self.current_key = null;
            }
        } else if (self.begin) |b| {
            const value = try self.processEscapes(try self.collapseBlanks(self.src[b + 1 .. pos]));
            if (self.current_key) |key| {
                try self.obj.set(self.a, key, value, false);
                self.current_key = null;
            }
        }
        self.begin = null;
    }

    /// A quoted value's runs of spaces and line ends are one space (djot.js's `[ \r\n]+`);
    /// `raw` itself when it has none.
    fn collapseBlanks(self: *AttrParser, raw: []const u8) ![]const u8 {
        const needs = for (raw, 0..) |c, i| {
            if (c == '\r' or c == '\n' or (c == ' ' and i + 1 < raw.len and raw[i + 1] == ' ')) break true;
        } else false;
        if (!needs) return raw;
        var buf = try std.ArrayList(u8).initCapacity(self.a, raw.len);
        var in_run = false;
        for (raw) |c| {
            if (c == ' ' or c == '\r' or c == '\n') {
                if (!in_run) buf.appendAssumeCapacity(' ');
                in_run = true;
            } else {
                buf.appendAssumeCapacity(c);
                in_run = false;
            }
        }
        return buf.items;
    }

    /// A backslash before one of these goes in an attribute value: djot.js's set, which
    /// lacks `<`, `>`, `@` and the space, so those keep their backslash.
    fn attrEscapable(c: u8) bool {
        return switch (c) {
            '.', ',', '\\', '/', '#', '!', '$', '%', '^', '&', '*', ';', ':', '{', '}', '=', '-', '_', '`', '~', '+', '[', ']', '(', ')', '\'', '"', '?', '|' => true,
            else => false,
        };
    }

    fn processEscapes(self: *AttrParser, raw: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len and attrEscapable(raw[i + 1])) {
                try buf.append(self.a, raw[i + 1]);
                i += 2;
            } else {
                try buf.append(self.a, raw[i]);
                i += 1;
            }
        }
        return buf.toOwnedSlice(self.a);
    }

    pub fn finish(self: *AttrParser) !BlockAttrs {
        return BlockAttrs.fromAttrs(try self.obj.list.toOwnedSlice(self.a));
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

/// Whether `line`, a block attribute's first line, leaves the attribute open: `{` followed
/// by attribute syntax still incomplete at its last byte. The line end is not fed, as
/// `feedLine` feeds it; the caller passes only lines `feedLine` opened.
pub fn opensAttr(a: Allocator, line: []const u8) !bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 1 or trimmed[0] != '{') return false;
    var parser = AttrParser.init(a, trimmed);
    return (try parser.feed(0, trimmed.len -| 1)).status == .@"continue";
}

pub fn parseInlineAttrs(a: Allocator, src: []const u8, pos: usize) !?struct { attrs: BlockAttrs, end: usize } {
    if (pos >= src.len or src[pos] != '{') return null;
    var parser = AttrParser.init(a, src);
    const result = try parser.feed(pos, src.len -| 1);
    if (result.status == .done) return .{ .attrs = try parser.finish(), .end = result.position + 1 };
    return null;
}
