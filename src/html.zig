//! Renders a djot AST to HTML.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("node.zig").Node;

/// Footnote numbering, as djot.js's HTML renderer: labels in order of first reference
/// (`order.keys()`), kept for the document in `a`, since a reference's text lives only
/// as long as its block.
pub const Footnotes = struct {
    a: Allocator,
    order: std.StringArrayHashMapUnmanaged(void) = .{},

    /// The 1-based number of `label`, assigned on its first reference.
    pub fn number(self: *Footnotes, label: []const u8) !usize {
        const entry = try self.order.getOrPut(self.a, label);
        if (!entry.found_existing) entry.key_ptr.* = try self.a.dupe(u8, label);
        return entry.index + 1;
    }
};

pub const endnotes_open = "<section role=\"doc-endnotes\">\n<hr>\n<ol>\n";
pub const endnotes_close = "</ol>\n</section>\n";

/// Renders one block's tree into `out`; only `footnotes` outlives the block.
pub const Renderer = struct {
    a: Allocator,
    out: *std.ArrayList(u8),
    footnotes: *Footnotes,

    pub fn render(self: *Renderer, n: Node) anyerror!void {
        try self.renderBlock(n, false);
    }

    /// Endnote `n` from a footnote's resolved blocks, as djot.js: the backlink ends the
    /// last paragraph or gets one of its own.
    pub fn renderEndnote(self: *Renderer, n: usize, blocks: []const Node) anyerror!void {
        const a = self.a;
        const out = self.out;
        try out.appendSlice(a, try std.fmt.allocPrint(a, "<li id=\"fn{d}\">\n", .{n}));
        const backlink = try std.fmt.allocPrint(a, "<a href=\"#fnref{d}\" role=\"doc-backlink\">\u{21a9}\u{fe0e}</a>", .{n});
        const last_is_para = blocks.len > 0 and blocks[blocks.len - 1].tag == .para;
        for (blocks[0 .. blocks.len - @intFromBool(last_is_para)]) |block| try self.render(block);
        if (last_is_para) {
            try self.renderParagraph(blocks[blocks.len - 1], false, backlink);
        } else {
            try out.appendSlice(a, "<p>");
            try out.appendSlice(a, backlink);
            try out.appendSlice(a, "</p>\n");
        }
        try out.appendSlice(a, "</li>\n");
    }

    /// A paragraph, with `trailer` inside it after its content; without `<p>` when `tight`.
    fn renderParagraph(self: *Renderer, n: Node, tight: bool, trailer: []const u8) anyerror!void {
        const a = self.a;
        const out = self.out;
        if (tight) {
            for (n.children) |child| try self.render(child);
            try out.appendSlice(a, trailer);
            try out.append(a, '\n');
            return;
        }
        try out.appendSlice(a, "<p");
        try renderAttrs(a, out, n);
        try out.appendSlice(a, ">");
        for (n.children) |child| try self.render(child);
        try out.appendSlice(a, trailer);
        try out.appendSlice(a, "</p>\n");
    }

    /// `tight` is set inside a tight list item, where paragraphs render without `<p>`. As
    /// in djot.js it reaches through block quotes, divs and definition lists; a nested list
    /// sets its own.
    fn renderBlock(self: *Renderer, node: Node, tight: bool) anyerror!void {
        const a = self.a;
        const out = self.out;
        switch (node.tag) {
            .section => {
                if (node.level > 0) {
                    try renderSectionOpen(a, out, node);
                    for (node.children) |child| try self.renderBlock(child, tight);
                    try out.appendSlice(a, section_close);
                } else {
                    for (node.children) |child| try self.renderBlock(child, tight);
                }
            },
            .para => try self.renderParagraph(node, tight, ""),
            .heading => {
                const tag = switch (node.level) {
                    1 => "h1",
                    2 => "h2",
                    3 => "h3",
                    4 => "h4",
                    5 => "h5",
                    else => "h6",
                };
                try out.appendSlice(a, "<");
                try out.appendSlice(a, tag);
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</");
                try out.appendSlice(a, tag);
                try out.appendSlice(a, ">\n");
            },
            .thematic_break => {
                try out.appendSlice(a, "<hr");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">\n");
            },
            .code_block => {
                try out.appendSlice(a, "<pre");
                try renderFilteredAttrs(a, out, node, true);
                try out.appendSlice(a, "><code");
                if (node.lang) |lang| {
                    try out.appendSlice(a, " class=\"language-");
                    try appendAttrEscaped(a, out, lang);
                    try out.appendSlice(a, "\"");
                }
                try out.appendSlice(a, ">");
                try appendEscaped(a, out, node.text);
                try out.appendSlice(a, "</code></pre>\n");
            },
            .block_quote => {
                try out.appendSlice(a, "<blockquote");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">\n");
                for (node.children) |child| try self.renderBlock(child, tight);
                try out.appendSlice(a, "</blockquote>\n");
            },
            .div => {
                try out.appendSlice(a, "<div");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">\n");
                for (node.children) |child| try self.renderBlock(child, tight);
                try out.appendSlice(a, "</div>\n");
            },
            .bullet_list => {
                try out.appendSlice(a, "<ul");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">\n");
                for (node.children) |child| try self.renderListItem(child, node.tight);
                try out.appendSlice(a, "</ul>\n");
            },
            .ordered_list => {
                try out.appendSlice(a, "<ol");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">\n");
                for (node.children) |child| try self.renderListItem(child, node.tight);
                try out.appendSlice(a, "</ol>\n");
            },
            .task_list => {
                try out.appendSlice(a, "<ul class=\"task-list\"");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">\n");
                for (node.children) |child| try self.renderListItem(child, node.tight);
                try out.appendSlice(a, "</ul>\n");
            },
            .task_list_item => {
                try out.appendSlice(a, "<li>\n");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</li>\n");
            },
            .definition_list => {
                try out.appendSlice(a, "<dl>\n");
                for (node.children) |child| try self.renderBlock(child, tight);
                try out.appendSlice(a, "</dl>\n");
            },
            .definition_list_item => {
                for (node.children) |child| try self.renderBlock(child, tight);
            },
            .term => {
                try out.appendSlice(a, "<dt>");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</dt>\n");
            },
            .definition => {
                try out.appendSlice(a, "<dd>\n");
                for (node.children) |child| try self.renderBlock(child, tight);
                try out.appendSlice(a, "</dd>\n");
            },
            .table => {
                try out.appendSlice(a, "<table>\n");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</table>\n");
            },
            .caption => if (node.children.len > 0) {
                try out.appendSlice(a, "<caption>");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</caption>\n");
            },
            .row => {
                try out.appendSlice(a, "<tr>\n");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</tr>\n");
            },
            .cell => {
                const cell_tag: []const u8 = if (node.head) "th" else "td";
                try out.appendSlice(a, "<");
                try out.appendSlice(a, cell_tag);
                if (node.cell_align != .default) {
                    try out.appendSlice(a, " style=\"text-align: ");
                    try out.appendSlice(a, @tagName(node.cell_align));
                    try out.appendSlice(a, ";\"");
                }
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</");
                try out.appendSlice(a, cell_tag);
                try out.appendSlice(a, ">\n");
            },
            .str => try appendEscaped(a, out, node.text),
            .soft_break => try out.append(a, '\n'),
            .hard_break => try out.appendSlice(a, "<br>\n"),
            .emph => {
                try out.appendSlice(a, "<em");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</em>");
            },
            .strong => {
                try out.appendSlice(a, "<strong");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</strong>");
            },
            .verbatim => {
                try out.appendSlice(a, "<code");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                try appendEscaped(a, out, node.text);
                try out.appendSlice(a, "</code>");
            },
            .link => {
                try out.appendSlice(a, "<a");
                if (node.destination) |dest| {
                    try out.appendSlice(a, " href=\"");
                    try appendAttrEscaped(a, out, dest);
                    try out.appendSlice(a, "\"");
                }
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</a>");
            },
            .image => {
                try out.appendSlice(a, "<img alt=\"");
                try collectAltText(a, out, node.children);
                try out.appendSlice(a, "\"");
                if (node.destination) |dest| {
                    try out.appendSlice(a, " src=\"");
                    try appendAttrEscaped(a, out, dest);
                    try out.appendSlice(a, "\"");
                }
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
            },
            .span => {
                try out.appendSlice(a, "<span");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</span>");
            },
            .footnote_reference => {
                const n = try self.footnotes.number(node.text);
                try out.appendSlice(a, try std.fmt.allocPrint(a, "<a id=\"fnref{d}\" href=\"#fn{d}\" role=\"doc-noteref\"", .{ n, n }));
                try renderAttrsExceptId(a, out, node);
                try out.appendSlice(a, try std.fmt.allocPrint(a, "><sup>{d}</sup></a>", .{n}));
            },
            .superscript => {
                try out.appendSlice(a, "<sup");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</sup>");
            },
            .subscript => {
                try out.appendSlice(a, "<sub");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</sub>");
            },
            .insert => {
                try out.appendSlice(a, "<ins");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</ins>");
            },
            .delete => {
                try out.appendSlice(a, "<del");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</del>");
            },
            .mark => {
                try out.appendSlice(a, "<mark");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "</mark>");
            },
            .inline_math, .display_math => {
                // The node's class joins the intrinsic one; its other attributes follow, as djot.js.
                const display = node.tag == .display_math;
                try out.appendSlice(a, if (display) "<span class=\"math display" else "<span class=\"math inline");
                if (nodeClass(node)) |cls| {
                    try out.append(a, ' ');
                    try appendAttrEscaped(a, out, cls);
                }
                try out.appendSlice(a, "\"");
                try renderFilteredAttrs(a, out, node, true);
                try out.appendSlice(a, if (display) ">\\[" else ">\\(");
                try appendEscaped(a, out, node.text);
                try out.appendSlice(a, if (display) "\\]</span>" else "\\)</span>");
            },
            .url, .email => {
                try out.appendSlice(a, if (node.tag == .email) "<a href=\"mailto:" else "<a href=\"");
                try appendEscaped(a, out, node.text);
                try out.appendSlice(a, "\"");
                try renderAttrs(a, out, node);
                try out.appendSlice(a, ">");
                try appendEscaped(a, out, node.text);
                try out.appendSlice(a, "</a>");
            },
            .symb => {
                try out.appendSlice(a, "<span class=\"symbol\">");
                try appendEscaped(a, out, node.text);
                try out.appendSlice(a, "</span>");
            },
            .double_quoted => {
                try out.appendSlice(a, "\u{201c}");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "\u{201d}");
            },
            .single_quoted => {
                try out.appendSlice(a, "\u{2018}");
                for (node.children) |child| try self.render(child);
                try out.appendSlice(a, "\u{2019}");
            },
            .escape => try appendEscaped(a, out, node.text),
            .non_breaking_space => try out.appendSlice(a, "&nbsp;"),
            .left_single_quote => try out.appendSlice(a, "\u{2018}"),
            .right_single_quote => try out.appendSlice(a, "\u{2019}"),
            .left_double_quote => try out.appendSlice(a, "\u{201c}"),
            .right_double_quote => try out.appendSlice(a, "\u{201d}"),
            .ellipsis => try out.appendSlice(a, "\u{2026}"),
            .em_dash => try out.appendSlice(a, "\u{2014}"),
            .en_dash => try out.appendSlice(a, "\u{2013}"),
            .raw_inline => {
                if (node.lang) |lang| {
                    if (std.mem.eql(u8, lang, "html")) {
                        try out.appendSlice(a, node.text);
                    }
                }
            },
            .raw_block => {
                if (node.lang) |lang| {
                    if (std.mem.eql(u8, lang, "html")) {
                        try out.appendSlice(a, node.text);
                    }
                }
            },
            else => {
                for (node.children) |child| try self.render(child);
            },
        }
    }

    fn collectAltText(a: Allocator, out: *std.ArrayList(u8), children: []const Node) anyerror!void {
        for (children) |child| {
            if (child.tag == .str or child.tag == .soft_break) {
                try appendAttrEscaped(a, out, if (child.tag == .soft_break) " " else child.text);
            } else {
                try collectAltText(a, out, child.children);
            }
        }
    }

    fn renderListItem(self: *Renderer, item: Node, tight: bool) anyerror!void {
        const a = self.a;
        const out = self.out;
        if (item.tag == .task_list_item) {
            try out.appendSlice(a, "<li>\n");
            if (item.checked orelse false) {
                try out.appendSlice(a, "<input disabled=\"\" type=\"checkbox\" checked=\"\"/>\n");
            } else {
                try out.appendSlice(a, "<input disabled=\"\" type=\"checkbox\"/>\n");
            }
        } else {
            try out.appendSlice(a, "<li>\n");
        }

        for (item.children) |child| try self.renderBlock(child, tight);

        try out.appendSlice(a, "</li>\n");
    }
};

/// The opening tag of a section on its own, so a streaming consumer can write a
/// section's children between this and `section_close`.
pub fn renderSectionOpen(a: Allocator, out: *std.ArrayList(u8), section: Node) !void {
    try out.appendSlice(a, "<section");
    try renderAttrs(a, out, section);
    try out.appendSlice(a, ">\n");
}

pub const section_close = "</section>\n";

/// The node's class, wherever it lives (an attribute named `class`, else `classes`).
fn nodeClass(node: Node) ?[]const u8 {
    for (node.attrs) |attr| if (std.mem.eql(u8, attr.key, "class")) return attr.value;
    return node.classes;
}

pub fn renderAttrs(a: Allocator, out: *std.ArrayList(u8), node: Node) !void {
    if (node.id) |id| {
        try out.appendSlice(a, " id=\"");
        try appendAttrEscaped(a, out, id);
        try out.appendSlice(a, "\"");
    }
    try renderAttrsExceptId(a, out, node);
}

/// The attributes of a node whose id the tag has already written (a footnote reference's).
fn renderAttrsExceptId(a: Allocator, out: *std.ArrayList(u8), node: Node) !void {
    var class_rendered = false;
    for (node.attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "class")) class_rendered = true;
        try out.append(a, ' ');
        try out.appendSlice(a, attr.key);
        try out.appendSlice(a, "=\"");
        try appendAttrEscaped(a, out, attr.value);
        try out.appendSlice(a, "\"");
    }
    if (!class_rendered) {
        if (node.classes) |cls| {
            try out.appendSlice(a, " class=\"");
            try appendAttrEscaped(a, out, cls);
            try out.appendSlice(a, "\"");
        }
    }
}

fn renderFilteredAttrs(a: Allocator, out: *std.ArrayList(u8), node: Node, skip_class: bool) !void {
    if (node.id) |id| {
        try out.appendSlice(a, " id=\"");
        try appendAttrEscaped(a, out, id);
        try out.appendSlice(a, "\"");
    }
    for (node.attrs) |attr| {
        if (skip_class and std.mem.eql(u8, attr.key, "class")) continue;
        try out.append(a, ' ');
        try out.appendSlice(a, attr.key);
        try out.appendSlice(a, "=\"");
        try appendAttrEscaped(a, out, attr.value);
        try out.appendSlice(a, "\"");
    }
    if (!skip_class) {
        if (node.classes) |cls| {
            try out.appendSlice(a, " class=\"");
            try appendAttrEscaped(a, out, cls);
            try out.appendSlice(a, "\"");
        }
    }
}

pub fn appendEscaped(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            else => try out.append(a, c),
        }
    }
}

pub fn appendAttrEscaped(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            else => try out.append(a, c),
        }
    }
}
