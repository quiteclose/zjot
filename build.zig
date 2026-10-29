const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zjot", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "zjot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zjot", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run zjot");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // The golden runs assert an empty stderr, which is where the DebugAllocator
    // reports leaks. std guarantees that allocator only in Debug, so the goldens run a
    // Debug build whatever -Doptimize says; when that is already Debug, `exe` serves.
    const golden_exe = if (optimize == .Debug) exe else b.addExecutable(.{
        .name = "zjot-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "zjot", .module = mod },
            },
        }),
    });

    const cli_test_step = b.step("cli-test", "Run CLI golden tests");
    // expectExitCode goes first: expectStdOut* adds an exit-0 check if none exists yet.

    // One fixture per block family: test/cli/NAME.dj, with the expected output of each
    // mode beside it as NAME.html, NAME.ast and NAME.sourcepos.ast (AGENTS.md: Test suite).
    const fixtures = [_][]const u8{ "hi", "headings", "inlines", "lists", "code", "blockquote", "table", "footnotes", "nofinal" };
    for (fixtures) |name| {
        const dj = b.fmt("test/cli/{s}.dj", .{name});
        inline for (.{
            .{ "html", &[_][]const u8{} },
            .{ "ast", &[_][]const u8{"--ast"} },
            .{ "sourcepos.ast", &[_][]const u8{ "--ast", "--sourcepos" } },
        }) |mode| {
            const run = goldenRun(b, golden_exe);
            run.addArgs(mode[1]);
            run.addArg(dj);
            run.addFileInput(b.path(dj)); // keeps the fixture a cache input
            run.expectExitCode(0);
            run.expectStdOutEqual(readGolden(b, b.fmt("test/cli/{s}.{s}", .{ name, mode[0] })));
            run.expectStdErrEqual(""); // Debug builds report leaks here.
            cli_test_step.dependOn(&run.step);
        }
    }

    const hi_html = readGolden(b, "test/cli/hi.html");

    const run_stdin = goldenRun(b, golden_exe);
    run_stdin.setStdIn(.{ .lazy_path = b.path("test/cli/hi.dj") });
    run_stdin.expectExitCode(0);
    run_stdin.expectStdOutEqual(hi_html);
    run_stdin.expectStdErrEqual("");
    cli_test_step.dependOn(&run_stdin.step);

    const run_help = goldenRun(b, golden_exe);
    run_help.addArg("--help");
    run_help.expectExitCode(0);
    run_help.expectStdOutMatch("Usage: zjot [OPTIONS] [--] [FILE]\n");
    run_help.expectStdErrEqual("");
    cli_test_step.dependOn(&run_help.step);

    const run_bogus = goldenRun(b, golden_exe);
    run_bogus.addArg("--bogus");
    run_bogus.expectExitCode(1);
    run_bogus.expectStdOutEqual("");
    run_bogus.expectStdErrEqual("zjot: unknown option: --bogus\n");
    cli_test_step.dependOn(&run_bogus.step);

    const run_missing = goldenRun(b, golden_exe);
    run_missing.addArg("nope.dj");
    run_missing.expectExitCode(1);
    run_missing.expectStdOutEqual("");
    run_missing.expectStdErrEqual("zjot: file not found: nope.dj\n");
    cli_test_step.dependOn(&run_missing.step);

    const run_dir = goldenRun(b, golden_exe);
    run_dir.addArg("src");
    run_dir.expectExitCode(1);
    run_dir.expectStdOutEqual("");
    run_dir.expectStdErrEqual("zjot: src: IsDir\n");
    cli_test_step.dependOn(&run_dir.step);

    const run_dash = goldenRun(b, golden_exe);
    run_dash.addArg("-");
    run_dash.setStdIn(.{ .lazy_path = b.path("test/cli/hi.dj") });
    run_dash.expectExitCode(0);
    run_dash.expectStdOutEqual(hi_html);
    run_dash.expectStdErrEqual("");
    cli_test_step.dependOn(&run_dash.step);

    const run_extra = goldenRun(b, golden_exe);
    run_extra.addArgs(&.{ "a.dj", "b.dj" });
    run_extra.expectExitCode(1);
    run_extra.expectStdOutEqual("");
    run_extra.expectStdErrEqual("zjot: unexpected argument: b.dj\n");
    cli_test_step.dependOn(&run_extra.step);

    // A document that fails part-way keeps on stdout what was rendered before the failure.
    const run_deep = goldenRun(b, golden_exe);
    run_deep.setStdIn(.{ .bytes = "para\n\n" ++ ("> " ** 1000) ++ "x\n" });
    run_deep.expectExitCode(1);
    run_deep.expectStdOutEqual("<p>para</p>\n");
    run_deep.expectStdErrEqual("zjot: stdin: nesting deeper than 1000 levels\n");
    cli_test_step.dependOn(&run_deep.step);

    const run_sourcepos = goldenRun(b, golden_exe);
    run_sourcepos.addArg("--sourcepos");
    run_sourcepos.expectExitCode(1);
    run_sourcepos.expectStdOutEqual("");
    run_sourcepos.expectStdErrEqual("zjot: --sourcepos requires --ast\n");
    cli_test_step.dependOn(&run_sourcepos.step);

    const run_empty = goldenRun(b, golden_exe);
    run_empty.addArg("");
    run_empty.expectExitCode(1);
    run_empty.expectStdOutEqual("");
    run_empty.expectStdErrEqual("zjot: empty argument\n");
    cli_test_step.dependOn(&run_empty.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(cli_test_step);
}

/// The expected output of a golden run, read at configure time so that it lives beside
/// its fixture. A missing file is a build-script error, not a test failure.
fn readGolden(b: *std.Build, path: []const u8) []const u8 {
    return b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(1 << 20)) catch |err|
        std.debug.panic("cannot read golden {s}: {t}", .{ path, err });
}

/// A golden run has the repo root as its cwd and names fixtures by relative path, so the
/// same runs work under a WASI preopen of `.`, which hides absolute paths.
fn goldenRun(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    return run;
}
