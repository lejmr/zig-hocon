const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("hocon", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `hocon <file.conf>` prints the file resolved, as HOCON, or with `--json`
    // as JSON; `zig build run -- file.conf`.
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
    const cli_includes = runCli(b, exe);
    cli_includes.addArg("--json");
    cli_includes.addFileArg(b.path("tests/cli-includes/main.conf"));
    cli_includes.expectStdOutEqual("{\"name\":\"from inner\",\"port\":443,\"log\":{\"level\":\"info\",\"file\":\"quiet-wombat.log\"}}\n");
    test_step.dependOn(&cli_includes.step);

    // The layered workflow end to end: prod.conf includes defaults.conf, then
    // builds on what it left with self-references (`path = ${path}…`,
    // `server = ${server} {…}`) and appends with `+=`, one element a substitution
    // defined further down. java agrees (pyhocon fails on `+=`).
    const layers_json = "{\"path\":\"/usr/bin:/opt/llama/bin\",\"plugins\":[\"auth\",\"metrics\",\"coffee-detector\"],\"server\":{\"port\":443,\"motto\":\"the wombat sleeps at noon\"},\"extra\":\"coffee-detector\"}\n";
    const cli_layers = runCli(b, exe);
    cli_layers.addArg("--json");
    cli_layers.addFileArg(b.path("tests/cli-layers/prod.conf"));
    cli_layers.expectStdOutEqual(layers_json);
    test_step.dependOn(&cli_layers.step);

    // The same file printed as HOCON, the default: resolved into one file with
    // no include left in it. Strings that were quoted stay quoted.
    const layers_hocon =
        \\path = "/usr/bin:/opt/llama/bin"
        \\plugins = [auth, metrics, "coffee-detector"]
        \\server {
        \\  port = 443
        \\  motto = "the wombat sleeps at noon"
        \\}
        \\extra = "coffee-detector"
        \\
    ;
    const cli_hocon = runCli(b, exe);
    cli_hocon.addFileArg(b.path("tests/cli-layers/prod.conf"));
    cli_hocon.expectStdOutEqual(layers_hocon);
    test_step.dependOn(&cli_hocon.step);

    // And that file, read by the binary again, is the same JSON. java ✓ reads
    // it to the same JSON too.
    const to_hocon = runCli(b, exe);
    to_hocon.addArg("--hocon");
    to_hocon.addFileArg(b.path("tests/cli-layers/prod.conf"));
    const flattened = to_hocon.captureStdOut(.{ .basename = "flattened.conf" });
    const reread = runCli(b, exe);
    reread.addArg("--json");
    reread.addFileArg(flattened);
    reread.expectStdOutEqual(layers_json);
    test_step.dependOn(&reread.step);

    // A format it does not know is refused before any file is read.
    const bad_format = runCli(b, exe);
    bad_format.addArgs(&.{ "--yaml", "no-such-file.conf" });
    bad_format.expectExitCode(1);
    bad_format.expectStdErrEqual("error: usage: hocon [--hocon | --json] [--env=process|none|keep] <file.conf>\n");
    test_step.dependOn(&bad_format.step);

    // A flag alone, or an empty name, is no file name: usage, not FileNotFound.
    for ([_][]const u8{ "--json", "" }) |arg| {
        const no_file = runCli(b, exe);
        no_file.addArg(arg);
        no_file.expectExitCode(1);
        no_file.expectStdErrEqual("error: usage: hocon [--hocon | --json] [--env=process|none|keep] <file.conf>\n");
        test_step.dependOn(&no_file.step);
    }

    // The environment end to end (#11): the binary reads the variables of its
    // own process, and these are all it gets — nothing from the shell the
    // build runs in. `WOMBAT_HOST` is unset, so the default under it stays;
    // `HOME = null` in the file keeps `$HOME` out. java agrees; pyhocon drops
    // `host`, `admins` and `home`.
    const cli_env = runCli(b, exe);
    cli_env.addArg("--json");
    cli_env.addFileArg(b.path("tests/cli-env/prod.conf"));
    cli_env.setEnvironmentVariable("HOME", "/home/the-wombat");
    cli_env.setEnvironmentVariable("WOMBAT_PORT", "9090");
    cli_env.setEnvironmentVariable("WOMBAT_ADMINS_0", "grumpy-owl");
    cli_env.setEnvironmentVariable("WOMBAT_ADMINS_1", "sleepy-badger");
    cli_env.setEnvironmentVariable("WOMBAT_MOOD", "grumpy");
    cli_env.expectStdOutEqual("{\"server\":{\"host\":\"localhost\",\"port\":\"9090\"},\"admins\":[\"grumpy-owl\",\"sleepy-badger\"],\"motto\":\"the grumpy wombat sleeps at noon\",\"HOME\":null,\"home\":null}\n");
    test_step.dependOn(&cli_env.step);

    // `--env=` takes one of three; anything else, or the flag twice, is usage.
    for ([_][]const []const u8{
        &.{ "--env=shell", "prod.conf" },
        &.{ "--env=", "prod.conf" },
        &.{ "--env", "prod.conf" },
        &.{ "--env=none", "--env=keep", "prod.conf" },
        &.{ "--json", "--hocon", "prod.conf" },
    }) |args| {
        const bad_env = runCli(b, exe);
        bad_env.addArgs(args);
        bad_env.expectExitCode(1);
        bad_env.expectStdErrEqual("error: usage: hocon [--hocon | --json] [--env=process|none|keep] <file.conf>\n");
        test_step.dependOn(&bad_env.step);
    }

    // `--env=none`: the variables are there, and not read.
    const env_none = runCli(b, exe);
    env_none.addArgs(&.{ "--env=none", "--json" });
    env_none.addFileArg(b.path("tests/cli-env/server.conf"));
    env_none.setEnvironmentVariable("WOMBAT_PORT", "9090");
    env_none.expectStdOutEqual("{\"host\":\"localhost\",\"port\":8080}\n");
    test_step.dependOn(&env_none.step);

    // `--env=keep` leaves a `${…}` for later, which only HOCON can write.
    const keep_json = runCli(b, exe);
    keep_json.addArgs(&.{ "--json", "--env=keep" });
    keep_json.addFileArg(b.path("tests/cli-env/server.conf"));
    keep_json.expectExitCode(1);
    keep_json.expectStdErrMatch("WaitsForTheEnvironment\n");
    test_step.dependOn(&keep_json.step);

    // Compaction end to end (#11): `--env=keep` on a config with includes, an
    // override, `+=` and variables, run with no variables at all, works out
    // everything but them into one file. Read where it runs, with the
    // variables there, that file is what the original is with them: the same
    // JSON, with every variable set and with only the required `HOST`.
    // java ✓ reads both files to the same JSON (keys sorted); pyhocon has no `[]`.
    const compact = runCli(b, exe);
    compact.addArgs(&.{ "--hocon", "--env=keep" });
    compact.addFileArg(b.path("tests/cli-compact/prod.conf"));
    compact.expectStdOutEqual(
        \\name = grumpy wombat
        \\port = 8080
        \\port = ${?PORT}
        \\plugins = [auth, metrics]
        \\hosts = [localhost]
        \\hosts = ${?L[]}
        \\db {
        \\  host = ${HOST}
        \\  pool = 4
        \\}
        \\url = "http://"${db.host}":"${port}"/burrow"
        \\
    );
    const compacted = compact.captureStdOut(.{ .basename = "compact.conf" });
    for ([_]struct { vars: []const [2][]const u8, json: []const u8 }{
        .{
            .vars = &.{ .{ "HOST", "wombat.example" }, .{ "PORT", "9090" }, .{ "L_0", "alpha" }, .{ "L_1", "beta" } },
            .json = "{\"name\":\"grumpy wombat\",\"port\":\"9090\",\"plugins\":[\"auth\",\"metrics\"],\"hosts\":[\"alpha\",\"beta\"],\"db\":{\"host\":\"wombat.example\",\"pool\":4},\"url\":\"http://wombat.example:9090/burrow\"}\n",
        },
        .{
            .vars = &.{.{ "HOST", "wombat.example" }},
            .json = "{\"name\":\"grumpy wombat\",\"port\":8080,\"plugins\":[\"auth\",\"metrics\"],\"hosts\":[\"localhost\"],\"db\":{\"host\":\"wombat.example\",\"pool\":4},\"url\":\"http://wombat.example:8080/burrow\"}\n",
        },
    }) |run| {
        for ([_]std.Build.LazyPath{ b.path("tests/cli-compact/prod.conf"), compacted }) |file| {
            const resolved = runCli(b, exe);
            resolved.addArg("--json");
            resolved.addFileArg(file);
            for (run.vars) |kv| resolved.setEnvironmentVariable(kv[0], kv[1]);
            resolved.expectStdOutEqual(run.json);
            test_step.dependOn(&resolved.step);
        }
    }

    // The CLI on a broken file, checked as a user meets it: exit 1 and exactly
    // this on stderr. Run from the file's own directory, so the path it prints
    // is the one it was given and not wherever the cache put it.
    const broken = b.addWriteFiles();
    _ = broken.add("app.conf",
        \\name = grumpy wombat
        \\port = 80 [1]
        \\
    );
    const run_broken = runCli(b, exe);
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
    const run_included = runCli(b, exe);
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

    // std.json writes no more than 256 lists and objects deep, so --json
    // refuses a deeper document with one line, not a panic. HOCON writes it.
    // java ⚠️ prints it.
    _ = broken.add("deep.conf", "a = " ++ "[" ** 300 ++ "]" ** 300 ++ "\n");
    const run_deep = runCli(b, exe);
    run_deep.setCwd(broken.getDirectory());
    run_deep.addArgs(&.{ "--json", "deep.conf" });
    run_deep.expectExitCode(1);
    run_deep.expectStdErrEqual("error: deep.conf: TooDeepForJson\n");
    test_step.dependOn(&run_deep.step);

    // Deeper than the parser goes (500), a chain of substitutions longer than
    // the resolver follows, a chain that nests a list deeper at each link: an
    // error with its place, not a stack overflow.
    _ = broken.add("deeper.conf", "a = " ++ "[" ** 3000 ++ "]" ** 3000 ++ "\n");
    _ = broken.add("chain.conf", "a = ${a}\n" ** 3000);
    var links: std.ArrayList(u8) = .empty;
    for (0..3000) |i| links.print(b.allocator, "x{d} = [${{x{d}}}]\n", .{ i, i + 1 }) catch @panic("OOM");
    _ = broken.add("links.conf", links.items);
    for ([_][2][]const u8{
        .{ "deeper.conf", "deeper.conf:1:504: error: TooDeep\n" },
        .{ "chain.conf", "chain.conf:2500:5: error: TooDeep\n" },
        .{ "links.conf", "links.conf:499:9: error: TooDeep\n" },
    }) |row| {
        const name, const want = row;
        const run_deeper = b.addRunArtifact(exe);
        run_deeper.setCwd(broken.getDirectory());
        run_deeper.addArg(name);
        run_deeper.expectExitCode(1);
        run_deeper.expectStdErrMatch(want);
        test_step.dependOn(&run_deeper.step);
    }
}

/// The binary for an end-to-end test. It gets none of the environment the
/// build runs in, only the variables the test sets.
fn runCli(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.clearEnvironment();
    return run;
}
