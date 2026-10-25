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

pub const Node = struct {
    tag: Tag,
    children: []const Node = &.{},
    text: []const u8 = "",
    level: u8 = 0,
    id: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    reference: ?[]const u8 = null,
    attrs: []const Attr = &.{},
    tight: bool = false,
    checked: ?bool = null,
    head: bool = false,
    cell_align: CellAlign = .default,
    /// Bullet lists: the marker character.
    style: ?[]const u8 = null,
    /// Ordered lists: the first number and the numbering, rendered as `start` and `type`.
    start: u64 = 1,
    list_style: ?ListStyle = null,
    start_pos: ?SourcePos = null,
    end_pos: ?SourcePos = null,
};
