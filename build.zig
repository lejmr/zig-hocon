const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("hocon", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `hocon <file.conf>` prints the file as JSON; `zig build run -- file.conf`.
    const exe = b.addExecutable(.{
        .name = "hocon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "hocon", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run the hocon CLI: zig build run -- file.conf");
    run_step.dependOn(&run_exe.step);

    // `zig build bench -Doptimize=ReleaseFast`: the parse-speed runner that
    // tools/bench/run.sh compares against typesafe/config and pyhocon.
    const bench = b.addExecutable(.{
        .name = "hocon-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "hocon", .module = mod }},
        }),
    });
    const bench_step = b.step("bench", "Build the parse-speed runner used by tools/bench/run.sh");
    bench_step.dependOn(&b.addInstallArtifact(bench, .{}).step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // The real binary on a directory with nested includes: main.conf includes
    // sub/defaults.conf, which includes inner.conf from its own directory, and
    // main.conf's own port comes after the include and wins.
    const cli_includes = b.addRunArtifact(exe);
    cli_includes.addFileArg(b.path("tests/cli-includes/main.conf"));
    cli_includes.expectStdOutEqual("{\"name\":\"from inner\",\"port\":443,\"log\":{\"level\":\"info\",\"file\":\"quiet-wombat.log\"}}\n");
    test_step.dependOn(&cli_includes.step);

    // The layered workflow end to end: prod.conf includes defaults.conf, then
    // builds on what it left with self-references (`path = ${path}…`,
    // `server = ${server} {…}`) and appends with `+=`, one element a substitution
    // defined further down. java agrees (pyhocon fails on `+=`).
    const cli_layers = b.addRunArtifact(exe);
    cli_layers.addFileArg(b.path("tests/cli-layers/prod.conf"));
    cli_layers.expectStdOutEqual("{\"path\":\"/usr/bin:/opt/llama/bin\",\"plugins\":[\"auth\",\"metrics\",\"coffee-detector\"],\"server\":{\"port\":443,\"motto\":\"the wombat sleeps at noon\"},\"extra\":\"coffee-detector\"}\n");
    test_step.dependOn(&cli_layers.step);

    // The CLI on a broken file, checked as a user meets it: exit 1 and exactly
    // this on stderr. Run from the file's own directory, so the path it prints
    // is the one it was given and not wherever the cache put it.
    const broken = b.addWriteFiles();
    _ = broken.add("app.conf",
        \\name = grumpy wombat
        \\port = 80 [1]
        \\
    );
    const run_broken = b.addRunArtifact(exe);
    run_broken.setCwd(broken.getDirectory());
    run_broken.addArg("app.conf");
    run_broken.expectExitCode(1);
    run_broken.expectStdErrEqual(
        \\app.conf:2:11: error: UnsupportedConcatenation
        \\port = 80 [1]
        \\          ^
        \\
    );
    test_step.dependOn(&run_broken.step);

    // The same with the mistake in an included file, two directories down: the
    // error names that file, by the path the include made of its name, and the
    // caret is on its line — not on the line with the same number in app.conf.
    _ = broken.add("prod.conf",
        \\name = grumpy wombat
        \\include "conf.d/limits.conf"
        \\
    );
    _ = broken.add("conf.d/limits.conf",
        \\max = 10
        \\burst = ${max} ${unknown}
        \\
    );
    const run_included = b.addRunArtifact(exe);
    run_included.setCwd(broken.getDirectory());
    run_included.addArg("prod.conf");
    run_included.expectExitCode(1);
    run_included.expectStdErrEqual(
        \\conf.d/limits.conf:2:16: error: Unresolved
        \\burst = ${max} ${unknown}
        \\               ^
        \\
    );
    test_step.dependOn(&run_included.step);
}
