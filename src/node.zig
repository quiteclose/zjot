//! The syntax tree's node: by tag, what only its kind carries (`Payload`): a container's
//! children, a leaf's text, a list's style, a cell's alignment; and behind two pointers
//! what few nodes carry (the attributes written on it, the id the document gave it) and
//! what only `--sourcepos` builds (its positions). `Tag` names every kind the parser produces; a tag that carries nothing is a
//! bare variant.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tag = enum {
    // blocks
    para,
    heading,
    section,
    thematic_break,
    code_block,
    block_quote,
    div,
    bullet_list,
    ordered_list,
    task_list,
    definition_list,
    list_item,
    task_list_item,
    definition_list_item,
    term,
    definition,
    table,
    caption,
    row,
    cell,
    raw_block,
    footnote,
    // inline
    str,
    soft_break,
    hard_break,
    non_breaking_space,
    emph,
    strong,
    verbatim,
    link,
    image,
    span,
    mark,
    superscript,
    subscript,
    insert,
    delete,
    double_quoted,
    single_quoted,
    inline_math,
    display_math,
    raw_inline,
    url,
    email,
    footnote_reference,
    symb,
    ellipsis,
    em_dash,
    en_dash,
};

pub const CellAlign = enum { default, left, right, center };

/// How an ordered list's markers are written: `1.`, `1)` or `(1)`; a list keeps one, as djot.js.
pub const Delim = enum { period, paren, parens };

/// The numbering of an ordered list, from its markers; `htmlType` is the `type` it renders.
pub const ListStyle = enum {
    decimal,
    lower_alpha,
    upper_alpha,
    lower_roman,
    upper_roman,

    pub fn htmlType(self: ListStyle) ?[]const u8 {
        return switch (self) {
            .decimal => null,
            .lower_alpha => "a",
            .upper_alpha => "A",
            .lower_roman => "i",
            .upper_roman => "I",
        };
    }
};

pub const Attr = struct {
    key: []const u8,
    value: []const u8,
};

pub const SourcePos = struct {
    line: u32,
    col: u32,
    offset: u32,
};

/// A link or image: its destination when written inline or resolved, its reference label
/// when written by reference, and its content. The label is as written until the parser's
/// first walk over its leaf keys it (`inline.keyLabel`); written `[text][]`, it is empty
/// until then and read off the text.
pub const Link = struct {
    destination: ?[]const u8 = null,
    reference: ?[]const u8 = null,
    children: []const Node = &.{},
};

/// What a node of each kind carries.
pub const Payload = union(Tag) {
    // blocks
    para: []const Node,
    heading: struct { level: u8, children: []const Node = &.{} },
    /// A section a heading opens. It has no children: its blocks follow it as output
    /// events (`document.Sections`). Level 0, childless, stands for the document in the
    /// AST's `doc` line.
    section: struct { level: u8 = 0, children: []const Node = &.{} },
    thematic_break,
    code_block: struct { lang: ?[]const u8 = null, text: []const u8 },
    block_quote: []const Node,
    div: []const Node,
    /// `marker`: the bullet character.
    bullet_list: struct { marker: u8, tight: bool, children: []const Node },
    ordered_list: struct { style: ListStyle, delim: Delim, start: u64, tight: bool, children: []const Node },
    task_list: struct { tight: bool, children: []const Node },
    definition_list: []const Node,
    list_item: []const Node,
    task_list_item: struct { checked: bool, children: []const Node },
    /// A term then a definition.
    definition_list_item: []const Node,
    term: []const Node,
    definition: []const Node,
    /// A caption (empty when none was written) then rows.
    table: []const Node,
    caption: []const Node,
    row: struct { head: bool = false, children: []const Node },
    cell: struct { head: bool = false, cell_align: CellAlign = .default, children: []const Node },
    raw_block: struct { format: []const u8, text: []const u8 },
    footnote: struct { label: []const u8, children: []const Node = &.{} },
    // inline
    str: []const u8,
    soft_break,
    hard_break,
    non_breaking_space,
    emph: []const Node,
    strong: []const Node,
    verbatim: []const u8,
    link: Link,
    image: Link,
    span: []const Node,
    mark: []const Node,
    superscript: []const Node,
    subscript: []const Node,
    insert: []const Node,
    delete: []const Node,
    double_quoted: []const Node,
    single_quoted: []const Node,
    inline_math: []const u8,
    display_math: []const u8,
    raw_inline: struct { format: []const u8, text: []const u8 },
    url: []const u8,
    email: []const u8,
    /// The label.
    footnote_reference: []const u8,
    /// The alias.
    symb: []const u8,
    ellipsis,
    em_dash,
    en_dash,
};

/// A node: its payload, and pointers to what few nodes carry and what only `--sourcepos`
/// builds, so that the common node is its payload and two words (a block is held whole
/// until it closes, its nodes with it). `withMarks` and `withSpan` make a fresh one, so a
/// node copied before keeps its own; the inline scanner grows a text node's span in place,
/// having made it for that node alone, and a held section points at its own copies.
pub const Node = struct {
    data: Payload,
    /// The node's id and attributes, which few nodes have.
    marks: ?*const Marks = null,
    /// Where the node stands in the source, which only `--sourcepos` builds.
    span: ?*const Span = null,

    pub const Marks = struct {
        /// The id the document gave the node: written in a block or inline attribute, or
        /// generated for a heading. Rendered where an `id` attribute was written, else
        /// first.
        id: ?[]const u8 = null,
        attrs: []const Attr = &.{},
    };

    pub const Span = struct { start: SourcePos, end: SourcePos };

    pub fn tag(n: Node) Tag {
        return n.data;
    }

    pub fn id(n: Node) ?[]const u8 {
        return if (n.marks) |m| m.id else null;
    }

    pub fn attrs(n: Node) []const Attr {
        return if (n.marks) |m| m.attrs else &.{};
    }

    pub fn startPos(n: Node) ?SourcePos {
        return if (n.span) |s| s.start else null;
    }

    pub fn endPos(n: Node) ?SourcePos {
        return if (n.span) |s| s.end else null;
    }

    /// `n` with the id and attributes given, on `a`; with none, without marks.
    pub fn withMarks(n: Node, a: Allocator, node_id: ?[]const u8, node_attrs: []const Attr) Allocator.Error!Node {
        var r = n;
        r.marks = if (node_id == null and node_attrs.len == 0) null else try create(a, Marks{ .id = node_id, .attrs = node_attrs });
        return r;
    }

    pub fn withId(n: Node, a: Allocator, node_id: ?[]const u8) Allocator.Error!Node {
        return n.withMarks(a, node_id, n.attrs());
    }

    /// `n` standing from `start` to `end`, on `a`; with either unknown, without a span.
    pub fn withSpan(n: Node, a: Allocator, start: ?SourcePos, end: ?SourcePos) Allocator.Error!Node {
        var r = n;
        r.span = if (start == null or end == null) null else try create(a, Span{ .start = start.?, .end = end.? });
        return r;
    }

    fn create(a: Allocator, value: anytype) Allocator.Error!*const @TypeOf(value) {
        const p = try a.create(@TypeOf(value));
        p.* = value;
        return p;
    }

    /// The node's content nodes; none for a leaf.
    pub fn children(n: Node) []const Node {
        return switch (n.data) {
            .para, .block_quote, .div, .definition_list, .list_item, .definition_list_item, .term, .definition, .table, .caption, .emph, .strong, .span, .mark, .superscript, .subscript, .insert, .delete, .double_quoted, .single_quoted => |c| c,
            .heading => |h| h.children,
            .section => |s| s.children,
            .bullet_list => |l| l.children,
            .ordered_list => |l| l.children,
            .task_list => |l| l.children,
            .task_list_item => |i| i.children,
            .row => |r| r.children,
            .cell => |c| c.children,
            .footnote => |f| f.children,
            .link, .image => |l| l.children,
            else => &.{},
        };
    }

    /// The node's text: a leaf's content, a footnote reference's label, a symbol's alias;
    /// empty for a container.
    pub fn text(n: Node) []const u8 {
        return switch (n.data) {
            .str, .verbatim, .inline_math, .display_math, .url, .email, .footnote_reference, .symb => |t| t,
            .code_block => |c| c.text,
            .raw_block => |r| r.text,
            .raw_inline => |r| r.text,
            else => "",
        };
    }
};
