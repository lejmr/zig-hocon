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

    // The CLI's own tests, `diff` and `check --schema` in src/main.zig.
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

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
    // `db.connect` comes from the block's include: `${timeout}` is db.timeout
    // while DB_TIMEOUT sets it, and the root's otherwise, so the file has both.
    // `hosts += spare` onto the variable stays `+=`.
    // java ✓ reads both files to the same JSON (keys sorted), but ⚠️ fails on
    // the original without DB_TIMEOUT (lightbend/config#863, suite 009) and
    // reads the compacted one as here. pyhocon has no `[]`.
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
        \\hosts += spare
        \\timeout = 30
        \\db {
        \\  host = ${HOST}
        \\  pool = 4
        \\  timeout = ${?DB_TIMEOUT}
        \\  connect = ${timeout}
        \\  connect = ${?db.timeout}
        \\}
        \\url = "http://"${db.host}":"${port}"/burrow"
        \\
    );
    const compacted = compact.captureStdOut(.{ .basename = "compact.conf" });
    for ([_]struct { vars: []const [2][]const u8, json: []const u8 }{
        .{
            .vars = &.{ .{ "HOST", "wombat.example" }, .{ "PORT", "9090" }, .{ "L_0", "alpha" }, .{ "L_1", "beta" }, .{ "DB_TIMEOUT", "5" } },
            .json = "{\"name\":\"grumpy wombat\",\"port\":\"9090\",\"plugins\":[\"auth\",\"metrics\"],\"hosts\":[\"alpha\",\"beta\",\"spare\"],\"timeout\":30,\"db\":{\"host\":\"wombat.example\",\"pool\":4,\"timeout\":\"5\",\"connect\":\"5\"},\"url\":\"http://wombat.example:9090/burrow\"}\n",
        },
        .{
            .vars = &.{.{ "HOST", "wombat.example" }},
            .json = "{\"name\":\"grumpy wombat\",\"port\":8080,\"plugins\":[\"auth\",\"metrics\"],\"hosts\":[\"localhost\",\"spare\"],\"timeout\":30,\"db\":{\"host\":\"wombat.example\",\"pool\":4,\"connect\":30},\"url\":\"http://wombat.example:8080/burrow\"}\n",
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

    // `hocon get` (R2-5) on a real file: text bare, for a shell; an object as
    // HOCON, or with `--json` anywhere among the arguments as JSON; a path as
    // `parsePath` reads one, quotes and all. `--env` as everywhere else, and
    // `--hocon` writes text as HOCON would. java ✓ (`getString`, `getConfig`,
    // `getValue` on the same paths) · pyhocon ✓ · spec ✓ paths
    for ([_]struct { args: []const []const u8, after: []const []const u8 = &.{}, out: []const u8 }{
        .{ .args = &.{"name"}, .out = "grumpy wombat\n" },
        .{ .args = &.{"zip"}, .out = "01234\n" },
        .{ .args = &.{"zip"}, .after = &.{"--hocon"}, .out = "\"01234\"\n" },
        .{ .args = &.{ "--json", "zip" }, .out = "\"01234\"\n" },
        .{ .args = &.{"db"}, .out = "host = db.example.org\npool = 8\n" },
        .{ .args = &.{ "db", "--json" }, .out = "{\"host\":\"db.example.org\",\"pool\":8}\n" },
        .{ .args = &.{"plugins"}, .out = "[auth, metrics]\n" },
        .{ .args = &.{"\"burrow.main\".depth"}, .out = "3\n" },
        .{ .args = &.{" db.pool "}, .out = "8\n" },
        .{ .args = &.{"port"}, .out = "9090\n" },
        .{ .args = &.{"port"}, .after = &.{"--env=none"}, .out = "8080\n" },
    }) |row| {
        const run_get = runCli(b, exe);
        run_get.addArg("get");
        run_get.addArgs(row.args);
        run_get.addFileArg(b.path("tests/cli-get/app.conf"));
        run_get.addArgs(row.after);
        run_get.setEnvironmentVariable("WOMBAT_PORT", "9090");
        run_get.expectStdOutEqual(row.out);
        test_step.dependOn(&run_get.step);
    }

    // What `get` refuses: a path that is not there, or not below an object,
    // says so; a path that is no path gets a caret under where it stops being
    // one; `--env=keep` leaves `port` two values until the environment picks.
    for ([_]struct { path: []const u8, args: []const []const u8 = &.{}, err: []const u8 }{
        .{ .path = "nope", .err = "error: no value at 'nope'\n" },
        .{ .path = "name.first", .err = "error: no value at 'name.first'\n" },
        .{ .path = "db.pool.size", .err = "error: no value at 'db.pool.size'\n" },
        .{ .path = "\"burrow\".main", .err = "error: no value at '\"burrow\".main'\n" },
        .{ .path = "db..pool", .err = "1:4: error: MalformedKey\ndb..pool\n   ^\n" },
        .{ .path = "port", .args = &.{"--env=keep"}, .err = "error: app.conf: WaitsForTheEnvironment\n" },
    }) |row| {
        const run_get = runCli(b, exe);
        run_get.setCwd(b.path("tests/cli-get"));
        run_get.addFileInput(b.path("tests/cli-get/app.conf"));
        run_get.addArgs(&.{ "get", row.path, "app.conf" });
        run_get.addArgs(row.args);
        run_get.expectExitCode(1);
        run_get.expectStdErrEqual(row.err);
        test_step.dependOn(&run_get.step);
    }

    // `hocon check` (R2-6) without a schema: each file parsed and resolved,
    // includes and all, `ok` on stdout for the good ones, the error with its
    // caret on stderr for the others, then how many failed; exit 1.
    const check_files = [_][]const u8{ "staging/app.conf", "prod/app.conf", "broken/app.conf", "loud.conf", "slow.conf" };
    const run_check = runCheck(b, exe);
    run_check.addArgs(&.{"check"});
    run_check.addArgs(&check_files);
    run_check.expectExitCode(1);
    run_check.expectStdOutEqual("staging/app.conf: ok\nprod/app.conf: ok\nloud.conf: ok\nslow.conf: ok\n");
    run_check.expectStdErrEqual(
        \\broken/app.conf:2:14: error: UnexpectedToken
        \\db { host = x
        \\             ^
        \\1 of 5 failed
        \\
    );
    test_step.dependOn(&run_check.step);

    // All good is exit 0 and nothing on stderr.
    const run_check_ok = runCheck(b, exe);
    run_check_ok.addArgs(&.{ "check", "staging/app.conf", "loud.conf" });
    run_check_ok.expectStdOutEqual("staging/app.conf: ok\nloud.conf: ok\n");
    run_check_ok.expectStdErrEqual("");
    test_step.dependOn(&run_check_ok.step);

    // With `--schema`: `hocon` compiles a program with the struct in
    // tests/cli-check/config.zig through the zig that runs this build, and the
    // files are read into it. Type errors name the path and point at the
    // value, in the file it is in, a `hocon.Duration` too. The cache it builds
    // in is this build's, `$XDG_CACHE_HOME` here and `$HOME/.cache` for the
    // runs below.
    const home = b.pathResolve(&.{ b.graph.cache.cwd, b.cache_root.path orelse ".", "hocon-check" });
    const run_schema = runSchema(b, exe, home, "config.zig:Config");
    run_schema.addArgs(&check_files);
    run_schema.setEnvironmentVariable("XDG_CACHE_HOME", b.pathJoin(&.{ home, ".cache" }));
    run_schema.expectExitCode(1);
    run_schema.expectStdOutEqual("staging/app.conf: ok\n");
    run_schema.expectStdErrEqual(
        \\prod/app.conf:5:10: error: InvalidCharacter at db.pool: expected u8
        \\  pool = eight
        \\         ^
        \\broken/app.conf:2:14: error: UnexpectedToken
        \\db { host = x
        \\             ^
        \\loud.conf:2:9: error: TypeMismatch at level: expected one of debug, info, warn
        \\level = shouting
        \\        ^
        \\slow.conf:2:11: error: UnknownUnit at timeout: expected duration
        \\timeout = 3 fortnights
        \\          ^
        \\4 of 5 failed
        \\
    );
    test_step.dependOn(&run_schema.step);

    // `config` is `Config` in other letters, and a type of its own, also on
    // a file system that ignores case (macOS): read as it, prod's pool and
    // the loud level are fine. After the run above, in the same cache.
    const run_lower = runSchema(b, exe, home, "config.zig:config");
    run_lower.addArgs(&check_files);
    run_lower.step.dependOn(&run_schema.step);
    run_lower.expectExitCode(1);
    run_lower.expectStdOutEqual("staging/app.conf: ok\nprod/app.conf: ok\nloud.conf: ok\nslow.conf: ok\n");
    run_lower.expectStdErrEqual(
        \\broken/app.conf:2:14: error: UnexpectedToken
        \\db { host = x
        \\             ^
        \\1 of 5 failed
        \\
    );
    test_step.dependOn(&run_lower.step);

    // The program reads the environment `hocon` was given, not the one
    // `zig run` gives it: ZIG_EXE is the user's, or not there.
    for ([_]?[]const u8{ null, "a confused zebra" }) |zig_exe| {
        const run_env = runSchema(b, exe, home, "config.zig:Config");
        run_env.addArg("zig-exe.conf");
        run_env.step.dependOn(&run_schema.step);
        if (zig_exe) |value| {
            run_env.setEnvironmentVariable("ZIG_EXE", value);
            run_env.expectStdOutEqual("zig-exe.conf: ok\n");
        } else {
            run_env.expectExitCode(1);
            run_env.expectStdErrEqual("zig-exe.conf: error: MissingField at name\n1 of 1 failed\n");
        }
        test_step.dependOn(&run_env.step);
    }

    // A schema that is not there is said the way a .conf that is not there
    // is, before anything is compiled; a cache that cannot be written says
    // where it was to go.
    for ([_]struct { schema: []const u8, cache: []const u8 = "", err: []const u8 }{
        .{ .schema = "nope.zig:Config", .err = "error: nope.zig: FileNotFound\n" },
        .{ .schema = "config.zig:Config", .cache = "/dev/null", .err = "error: --schema writes its cache in /dev/null: NotDir\n" },
    }) |row| {
        const run_bad = runSchema(b, exe, home, row.schema);
        run_bad.addArg("loud.conf");
        run_bad.setEnvironmentVariable("XDG_CACHE_HOME", row.cache);
        run_bad.expectExitCode(1);
        run_bad.expectStdErrEqual(row.err);
        test_step.dependOn(&run_bad.step);
    }

    // `hocon diff` (R2-7): what prod.conf changes on top of the defaults it
    // includes, path by path, values as JSON; a list compared whole, an
    // object's keys in any order the same object, `null` a value of its own.
    // Exit 1 when anything differs. The other way round, what prod added is
    // what the defaults lack.
    for ([_]struct { a: []const u8, b: []const u8, out: []const u8 }{
        .{ .a = "defaults.conf", .b = "prod.conf", .out =
        \\~ port: 8080 → 443
        \\~ debug: true → false
        \\~ plugins: ["auth"] → ["auth","metrics"]
        \\+ db.host: "db.example.org"
        \\~ feature.beta: true → null
        \\
        },
        .{ .a = "prod.conf", .b = "defaults.conf", .out =
        \\~ port: 443 → 8080
        \\~ debug: false → true
        \\~ plugins: ["auth","metrics"] → ["auth"]
        \\- db.host
        \\~ feature.beta: null → true
        \\
        },
    }) |row| {
        const run_diff = runCli(b, exe);
        run_diff.addArg("diff");
        run_diff.addFileArg(b.path(b.fmt("tests/cli-diff/{s}", .{row.a})));
        run_diff.addFileArg(b.path(b.fmt("tests/cli-diff/{s}", .{row.b})));
        run_diff.expectExitCode(1);
        run_diff.expectStdOutEqual(row.out);
        test_step.dependOn(&run_diff.step);
    }

    // The same as JSON, for a program to read.
    const diff_json = runCli(b, exe);
    diff_json.addArgs(&.{ "diff", "--json" });
    diff_json.addFileArg(b.path("tests/cli-diff/prod.conf"));
    diff_json.addFileArg(b.path("tests/cli-diff/defaults.conf"));
    diff_json.expectExitCode(1);
    diff_json.expectStdOutEqual("[{\"op\":\"changed\",\"path\":\"port\",\"old\":443,\"new\":8080},{\"op\":\"changed\",\"path\":\"debug\",\"old\":false,\"new\":true},{\"op\":\"changed\",\"path\":\"plugins\",\"old\":[\"auth\",\"metrics\"],\"new\":[\"auth\"]},{\"op\":\"removed\",\"path\":\"db.host\",\"old\":\"db.example.org\"},{\"op\":\"changed\",\"path\":\"feature.beta\",\"old\":null,\"new\":true}]\n");
    test_step.dependOn(&diff_json.step);

    // Compaction checked the way the plan has it: the file `--env=keep`
    // wrote (above) and the one it came from, both read with the variables
    // set, are no different: exit 0, nothing printed.
    const diff_compact = runCli(b, exe);
    diff_compact.addArg("diff");
    diff_compact.addFileArg(b.path("tests/cli-compact/prod.conf"));
    diff_compact.addFileArg(compacted);
    diff_compact.setEnvironmentVariable("HOST", "wombat.example");
    diff_compact.setEnvironmentVariable("PORT", "9090");
    diff_compact.expectExitCode(0);
    diff_compact.expectStdOutEqual("");
    test_step.dependOn(&diff_compact.step);

    // A file `diff` cannot read or compare exits 2, as diff(1) does: 1 is
    // only for files that differ, so a script can tell the two apart.
    for ([_]struct { args: []const []const u8, err: []const u8 }{
        .{ .args = &.{ "deep.conf", "nofile.conf" }, .err = "nofile.conf: error: FileNotFound\n" },
        .{ .args = &.{ "--env=keep", "prod.conf", "deep.conf" }, .err = "error: prod.conf: WaitsForTheEnvironment\n" },
        .{ .args = &.{ "deep.conf", "deep.conf" }, .err = "error: deep.conf: TooDeepForJson\n" },
    }) |row| {
        const diff_bad = runCli(b, exe);
        diff_bad.setCwd(broken.getDirectory());
        diff_bad.addArg("diff");
        diff_bad.addArgs(row.args);
        diff_bad.expectExitCode(2);
        diff_bad.expectStdErrEqual(row.err);
        test_step.dependOn(&diff_bad.step);
    }

    // A stdout that is gone is one line on stderr, as for the command-less
    // form, not a stack trace; `diff` exits 2 for it, as for any trouble.
    // `get` names the file, as the command-less form does, since it writes
    // the value the same way. `inputs` are the files the row reads, so the
    // run reruns when one changes.
    for ([_]struct { args: []const u8, inputs: []const []const u8, code: u8, err: []const u8 }{
        .{ .args = "get name ../cli-get/app.conf", .inputs = &.{"tests/cli-get/app.conf"}, .code = 1, .err = "error: ../cli-get/app.conf: WriteFailed\n" },
        .{ .args = "get db ../cli-get/app.conf", .inputs = &.{"tests/cli-get/app.conf"}, .code = 1, .err = "error: ../cli-get/app.conf: WriteFailed\n" },
        .{ .args = "check loud.conf", .inputs = &.{"tests/cli-check/loud.conf"}, .code = 1, .err = "error: WriteFailed\n" },
        .{ .args = "diff ../cli-diff/defaults.conf ../cli-diff/prod.conf", .inputs = &.{ "tests/cli-diff/defaults.conf", "tests/cli-diff/prod.conf" }, .code = 2, .err = "error: WriteFailed\n" },
    }) |row| {
        const closed = b.addSystemCommand(&.{ "sh", "-c", b.fmt("exec \"$0\" {s} >&-", .{row.args}) });
        closed.addArtifactArg(exe);
        closed.clearEnvironment();
        closed.setCwd(b.path("tests/cli-check"));
        for (row.inputs) |input| closed.addFileInput(b.path(input));
        closed.expectExitCode(row.code);
        closed.expectStdErrEqual(row.err);
        test_step.dependOn(&closed.step);
    }

    // Every command says how it is called when it is called wrong, its own
    // line; `hocon` alone lists all four.
    const usage_get = "error: usage: hocon get [--hocon | --json] [--env=process|none|keep] <path> <file.conf>\n";
    const usage_check = "error: usage: hocon check [--env=process|none|keep] [--schema <file.zig>:<Type>] <file.conf>...\n";
    const usage_diff = "error: usage: hocon diff [--json] [--env=process|none|keep] <a.conf> <b.conf>\n";
    for ([_]struct { args: []const []const u8, err: []const u8 }{
        .{ .args = &.{}, .err =
        \\error: usage: hocon [--hocon | --json] [--env=process|none|keep] <file.conf>
        \\              hocon get [--hocon | --json] [--env=process|none|keep] <path> <file.conf>
        \\              hocon check [--env=process|none|keep] [--schema <file.zig>:<Type>] <file.conf>...
        \\              hocon diff [--json] [--env=process|none|keep] <a.conf> <b.conf>
        \\
        },
        .{ .args = &.{"get"}, .err = usage_get },
        .{ .args = &.{ "get", "port" }, .err = usage_get },
        .{ .args = &.{ "get", "port", "a.conf", "b.conf" }, .err = usage_get },
        .{ .args = &.{ "get", "--json", "--hocon", "port", "a.conf" }, .err = usage_get },
        .{ .args = &.{ "get", "--env=shell", "port", "a.conf" }, .err = usage_get },
        .{ .args = &.{ "get", "", "a.conf" }, .err = usage_get },
        .{ .args = &.{ "get", "--schema", "x.zig:T", "port", "a.conf" }, .err = usage_get },
        .{ .args = &.{"check"}, .err = usage_check },
        .{ .args = &.{ "check", "--json", "a.conf" }, .err = usage_check },
        .{ .args = &.{ "check", "a.conf", "--schema" }, .err = usage_check },
        .{ .args = &.{ "check", "--schema", "config.zig", "a.conf" }, .err = usage_check },
        .{ .args = &.{ "check", "--schema", "config.zig:Config;", "a.conf" }, .err = usage_check },
        .{ .args = &.{ "check", "--schema", "config.zig:", "a.conf" }, .err = usage_check },
        .{ .args = &.{ "check", "--schema", ":Config", "a.conf" }, .err = usage_check },
        .{ .args = &.{ "check", "--schema", "a.zig:A", "--schema", "b.zig:B", "a.conf" }, .err = usage_check },
        .{ .args = &.{ "diff", "a.conf" }, .err = usage_diff },
        .{ .args = &.{ "diff", "--hocon", "a.conf", "b.conf" }, .err = usage_diff },
        .{ .args = &.{ "diff", "--env=none", "--env=keep", "a.conf", "b.conf" }, .err = usage_diff },
    }) |row| {
        const bad = runCli(b, exe);
        bad.addArgs(row.args);
        bad.expectExitCode(1);
        bad.expectStdErrEqual(row.err);
        test_step.dependOn(&bad.step);
    }
}

/// `hocon check` in tests/cli-check, so the paths it prints are the ones it
/// was given. The files are its inputs: a change to one runs it again.
fn runCheck(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = runCli(b, exe);
    run.setCwd(b.path("tests/cli-check"));
    for ([_][]const u8{ "config.zig", "staging/app.conf", "prod/app.conf", "broken/app.conf", "loud.conf", "slow.conf", "zig-exe.conf" }) |name| {
        run.addFileInput(b.path(b.fmt("tests/cli-check/{s}", .{name})));
    }
    return run;
}

/// `hocon check --schema <schema>`, with the zig that runs this build on the
/// PATH and its global cache, and `home/.cache` for a cache: an empty
/// XDG_CACHE_HOME is none, as the XDG spec has it.
fn runSchema(b: *std.Build, exe: *std.Build.Step.Compile, home: []const u8, schema: []const u8) *std.Build.Step.Run {
    const run = runCheck(b, exe);
    run.addArgs(&.{ "check", "--schema", schema });
    run.setEnvironmentVariable("PATH", std.fs.path.dirname(b.graph.zig_exe).?);
    run.setEnvironmentVariable("HOME", home);
    run.setEnvironmentVariable("XDG_CACHE_HOME", "");
    if (b.graph.global_cache_root.path) |global| run.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", global);
    return run;
}

/// The binary for an end-to-end test. It gets none of the environment the
/// build runs in, only the variables the test sets.
fn runCli(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    run.clearEnvironment();
    return run;
}
