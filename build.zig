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

    const cli_test_step = b.step("cli-test", "Run CLI golden tests");
    // expectExitCode goes first: expectStdOut* adds an exit-0 check if none exists yet.
    const html = "<section id=\"Hi\">\n<h1>Hi</h1>\n</section>\n";

    const run_file = b.addRunArtifact(exe);
    run_file.addFileArg(b.path("test/cli/hi.dj"));
    run_file.expectExitCode(0);
    run_file.expectStdOutEqual(html);
    run_file.expectStdErrEqual(""); // Debug builds report leaks here.
    cli_test_step.dependOn(&run_file.step);

    const run_stdin = b.addRunArtifact(exe);
    run_stdin.setStdIn(.{ .bytes = "# Hi\n" });
    run_stdin.expectExitCode(0);
    run_stdin.expectStdOutEqual(html);
    run_stdin.expectStdErrEqual("");
    cli_test_step.dependOn(&run_stdin.step);

    const run_help = b.addRunArtifact(exe);
    run_help.addArg("--help");
    run_help.expectExitCode(0);
    run_help.expectStdOutMatch("Usage: zjot [OPTIONS] [FILE]\n");
    run_help.expectStdErrEqual("");
    cli_test_step.dependOn(&run_help.step);

    const run_bogus = b.addRunArtifact(exe);
    run_bogus.addArg("--bogus");
    run_bogus.expectExitCode(1);
    run_bogus.expectStdOutEqual("");
    run_bogus.expectStdErrEqual("zjot: unknown option: --bogus\n");
    cli_test_step.dependOn(&run_bogus.step);

    const run_missing = b.addRunArtifact(exe);
    run_missing.addArg("/nope.dj");
    run_missing.expectExitCode(1);
    run_missing.expectStdOutEqual("");
    run_missing.expectStdErrEqual("zjot: file not found: /nope.dj\n");
    cli_test_step.dependOn(&run_missing.step);

    const run_ast = b.addRunArtifact(exe);
    run_ast.addArg("--ast");
    run_ast.addFileArg(b.path("test/cli/hi.dj"));
    run_ast.expectExitCode(0);
    run_ast.expectStdOutEqual("doc\n  section id=\"Hi\"\n    heading level=1\n      str text=\"Hi\"\n");
    run_ast.expectStdErrEqual("");
    cli_test_step.dependOn(&run_ast.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(cli_test_step);
}
