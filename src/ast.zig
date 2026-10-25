//! Renders a djot AST as indented text. Format follows djot.js conventions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("node.zig").Node;

pub fn renderAstNode(a: Allocator, out: *std.ArrayList(u8), node: Node, indent: usize, is_root: bool) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try out.append(a, ' ');

    const tag_name = if (is_root and node.data == .section) "doc" else @tagName(node.data);
    try out.appendSlice(a, tag_name);

    if (node.start_pos) |sp| {
        if (node.end_pos) |ep| {
            try out.appendSlice(a, try std.fmt.allocPrint(
                a,
                " ({d}:{d}:{d}-{d}:{d}:{d})",
                .{ sp.line, sp.col, sp.offset, ep.line, ep.col, ep.offset },
            ));
        }
    }

    switch (node.data) {
        // As djot.js's text form: a url, an email and math print no text.
        .str, .verbatim, .footnote_reference => |text| if (text.len > 0) {
            try out.appendSlice(a, " text=");
            try appendJsonStr(a, out, text);
        },
        .symb => |alias| if (alias.len > 0) {
            try out.appendSlice(a, " alias=");
            try appendJsonStr(a, out, alias);
        },
        .code_block => |c| if (c.text.len > 0) {
            try out.appendSlice(a, " text=");
            try appendJsonStr(a, out, c.text);
        },
        .raw_block => |r| if (r.text.len > 0) {
            try out.appendSlice(a, " text=");
            try appendJsonStr(a, out, r.text);
        },
        .raw_inline => |r| if (r.text.len > 0) {
            try out.appendSlice(a, " text=");
            try appendJsonStr(a, out, r.text);
        },
        .heading => |h| try out.appendSlice(a, try std.fmt.allocPrint(a, " level={d}", .{h.level})),
        .footnote => |f| {
            try out.appendSlice(a, " label=");
            try appendJsonStr(a, out, f.label);
        },
        .bullet_list => |l| {
            try out.appendSlice(a, if (l.tight) " tight=true" else " tight=false");
            try out.appendSlice(a, " style=");
            try appendJsonStr(a, out, &.{l.marker});
        },
        .ordered_list => |l| try out.appendSlice(a, if (l.tight) " tight=true" else " tight=false"),
        .task_list_item => |item| try out.appendSlice(a, if (item.checked) " checked=true" else " checked=false"),
        .link, .image => |l| {
            if (l.destination) |dest| {
                try out.appendSlice(a, " destination=");
                try appendJsonStr(a, out, dest);
            }
            if (l.reference) |ref| if (ref.len > 0) {
                try out.appendSlice(a, " reference=");
                try appendJsonStr(a, out, ref);
            };
        },
        .row => |r| try out.appendSlice(a, if (r.head) " head=true" else " head=false"),
        .cell => |c| {
            try out.appendSlice(a, if (c.head) " head=true" else " head=false");
            const align_str = switch (c.cell_align) {
                .default => " align=\"default\"",
                .left => " align=\"left\"",
                .right => " align=\"right\"",
                .center => " align=\"center\"",
            };
            try out.appendSlice(a, align_str);
        },
        else => {},
    }

    switch (node.data) {
        .code_block => |c| if (c.lang) |lang| {
            try out.appendSlice(a, " lang=");
            try appendJsonStr(a, out, lang);
        },
        .raw_block => |r| {
            try out.appendSlice(a, " lang=");
            try appendJsonStr(a, out, r.format);
        },
        .raw_inline => |r| {
            try out.appendSlice(a, " lang=");
            try appendJsonStr(a, out, r.format);
        },
        else => {},
    }

    // Attributes print as djot.js's text form does: id, class, then the rest in order.
    if (node.id) |id| {
        try out.appendSlice(a, " id=");
        try appendJsonStr(a, out, id);
    }
    for (node.attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "class")) {
            try out.appendSlice(a, " class=");
            try appendJsonStr(a, out, attr.value);
        }
    }
    for (node.attrs) |attr| {
        if (std.mem.eql(u8, attr.key, "class") or std.mem.eql(u8, attr.key, "id")) continue;
        try out.append(a, ' ');
        try out.appendSlice(a, attr.key);
        try out.append(a, '=');
        try appendJsonStr(a, out, attr.value);
    }

    try out.append(a, '\n');

    for (node.children()) |child| {
        try renderAstNode(a, out, child, indent + 2, false);
    }
}

fn appendJsonStr(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => try out.append(a, c),
        }
    }
    try out.append(a, '"');
}
