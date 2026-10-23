//! Test harness for djot.js `.test` files. Each file contains backtick-fenced
//! blocks with input/output pairs separated by `.` (HTML) or `!` (AST).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zjot = @import("root.zig");

const TestCase = struct {
    input: []const u8,
    expected: []const u8,
    line_number: usize,
    ast_mode: bool,
    sourcepos: bool,
};

const TestResults = struct {
    passed: usize = 0,
    failed: usize = 0,

    fn total(self: TestResults) usize {
        return self.passed + self.failed;
    }

    fn add(self: *TestResults, other: TestResults) void {
        self.passed += other.passed;
        self.failed += other.failed;
    }
};

fn countBackticks(line: []const u8) usize {
    for (line, 0..) |c, i| {
        if (c != '`') return i;
    }
    return line.len;
}

fn parseTestFile(a: Allocator, content: []const u8) ![]TestCase {
    var cases: std.ArrayList(TestCase) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;

    while (true) {
        const raw = lines.next() orelse break;
        line_num += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");

        const fence = countBackticks(line);
        if (fence < 3) continue;

        const opts = std.mem.trim(u8, line[fence..], " \t");
        const ast_mode = std.mem.indexOfScalar(u8, opts, 'a') != null;
        const sourcepos = std.mem.indexOfScalar(u8, opts, 'p') != null;
        const start_line = line_num;

        var input_buf: std.ArrayList(u8) = .empty;
        var sep_found = false;

        while (lines.next()) |r| {
            line_num += 1;
            const l = std.mem.trimEnd(u8, r, "\r");
            if (l.len == 1 and (l[0] == '.' or l[0] == '!')) {
                sep_found = true;
                break;
            }
            try input_buf.appendSlice(a, l);
            try input_buf.append(a, '\n');
        }

        if (!sep_found) {
            input_buf.deinit(a);
            break;
        }

        var output_buf: std.ArrayList(u8) = .empty;

        while (lines.next()) |r| {
            line_num += 1;
            const l = std.mem.trimEnd(u8, r, "\r");
            if (countBackticks(l) >= fence) break;
            try output_buf.appendSlice(a, l);
            try output_buf.append(a, '\n');
        }

        try cases.append(a, .{
            .input = try input_buf.toOwnedSlice(a),
            .expected = try output_buf.toOwnedSlice(a),
            .line_number = start_line,
            .ast_mode = ast_mode,
            .sourcepos = sourcepos,
        });
    }

    return try cases.toOwnedSlice(a);
}

fn runTestFile(a: Allocator, io: std.Io, dir: std.Io.Dir, filename: []const u8) !TestResults {
    const content = try std.Io.Dir.readFileAlloc(dir, io, filename, a, .limited(10 * 1024 * 1024));
    const cases = try parseTestFile(a, content);

    var results = TestResults{};

    for (cases, 0..) |tc, ci| {
        const output = if (tc.ast_mode)
            zjot.toAstOpts(a, tc.input, tc.sourcepos) catch |err| {
                std.debug.print("    ERR[{d}] at line {d}: {s}\n", .{ ci, tc.line_number, @errorName(err) });
                results.failed += 1;
                continue;
            }
        else
            zjot.toHtml(a, tc.input) catch |err| {
                std.debug.print("    ERR[{d}] at line {d}: {s}\n", .{ ci, tc.line_number, @errorName(err) });
                results.failed += 1;
                continue;
            };

        if (std.mem.eql(u8, output, tc.expected)) {
            results.passed += 1;
        } else {
            results.failed += 1;
            if (results.failed <= 100) {
                std.debug.print("    FAIL[{d}] at line {d}:\n", .{ ci, tc.line_number });
                std.debug.print("---expected---\n{s}\n---got---\n{s}\n---end---\n", .{ tc.expected, output });
            }
        }
    }

    return results;
}

const test_file_names = [_][]const u8{
    "attributes.test",
    "block_quote.test",
    "code_blocks.test",
    "definition_lists.test",
    "emphasis.test",
    "escapes.test",
    "fenced_divs.test",
    "footnotes.test",
    "headings.test",
    "insert_delete_mark.test",
    "links_and_images.test",
    "lists.test",
    "math.test",
    "para.test",
    "raw.test",
    "regression.test",
    "smart.test",
    "spans.test",
    "sourcepos.test",
    "super_subscript.test",
    "symb.test",
    "tables.test",
    "task_lists.test",
    "thematic_breaks.test",
    "verbatim.test",
    "zjot.test",
};

test "djot test suite" {
    const io = std.testing.io;
    var test_dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, "test", .{}) catch |err| {
        std.debug.print("\nCould not open test directory: {}\n", .{err});
        return err;
    };
    defer test_dir.close(io);

    var total = TestResults{};

    for (test_file_names) |filename| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const results = runTestFile(arena.allocator(), io, test_dir, filename) catch |err| {
            std.debug.print("  {s}: ERROR ({})\n", .{ filename, err });
            total.failed += 1;
            continue;
        };

        const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
        const name = filename[0..dot];
        if (results.failed > 0) {
            std.debug.print("  {s}: {d}/{d} passed\n", .{ name, results.passed, results.total() });
        }
        total.add(results);
    }

    if (total.failed > 0) {
        std.debug.print("\n  Total: {d}/{d} passed\n\n", .{ total.passed, total.total() });
    }

    try std.testing.expect(total.total() > 0);
    try std.testing.expectEqual(0, total.failed);
}
