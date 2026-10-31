# The `hocon` command

`pip install zig-hocon` puts `hocon` on your `PATH`; in a checkout, `zig build -Doptimize=ReleaseSafe` builds it into `zig-out/bin`. The examples read `app.conf` and `prod.conf` from the [README](../README.md#use).

`hocon` prints a file resolved, as HOCON or with `--json` as JSON:

```sh
$ hocon --json prod.conf
{"db":{"host":"db.example.org","pool":4},"timeout":"30s","cache":"512MiB","debug":false}
```

A `${…}` that the file does not answer reads the process environment; `--env=none` turns that off. `--env-file=prod.env` reads the `KEY=value` lines of a file, the way docker compose and python-dotenv read them, and puts them over the environment. A file written for a shell's `source`, with `export` and quotes, works as it is. With several env files, a later one goes over an earlier one, and with `--env=none` the env files are the only variables there are. So `hocon check --env=none --env-file=prod.env prod.conf` checks a deployment against its own variables and nothing from your shell.

`--env=keep` writes the one file to deploy: includes and overrides worked out, the variables left for the server. `pool = 4` followed by `pool = ${?DB_POOL}` means the server's `DB_POOL` wins when it is set, and 4 stays when it is not:

```sh
$ hocon --env=keep prod.conf > deploy.conf
$ cat deploy.conf
db {
  host = db.example.org
  pool = 4
  pool = ${?DB_POOL}
}
timeout = 30s
cache = 512MiB
debug = false
```

**get** prints one value, for a shell script, and with `--json` an object as JSON. **diff** compares two files as they resolve, path by path (`~ path: old → new`, `+` and `-`); the deploy file says the same as `prod.conf`:

```sh
$ hocon get db.host prod.conf
db.example.org
$ hocon diff prod.conf deploy.conf; echo $?
0
```

**check** reads each file and says which fail and where. With `--schema` it also reads them into your struct, so a value of the wrong type fails as it would in your program. It compiles the struct with the `zig` on your `PATH`, so the file may import `std` and `hocon` and nothing else. It skips a key the struct has no field for, whatever your program does ([Gotchas](production.md#gotchas)).

With `config.zig` holding the `Config` struct from the top of this page, declared `pub`, and `const hocon = @import("hocon");`, `DB_POOL=eight hocon check --schema config.zig:Config prod.conf` prints the error shown under [the README](../README.md#before-you-ship), then `1 of 1 failed`.

**Exit codes**: 0 is success. `hocon`, `get` and `check` exit 1 when something is wrong; `diff` exits 1 when the files differ and 2 when one cannot be read. What went wrong, and where, goes to stderr. `hocon` with no arguments lists the commands and their flags.

From `build.zig`, run the binary of the dependency, built for the machine the build runs on. Next to the [Install](../README.md#install) lines, `zig build check-config` then checks `deploy/prod.conf` against `Config`; `--schema` runs the `zig` on its `PATH`, here the one running the build:

```zig
const hocon_cli = b.dependency("hocon", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
const check = std.Build.Step.Run.create(b, "check config");
check.addFileArg(hocon_cli.namedLazyPath("cli"));
check.addArgs(&.{ "check", "--schema", b.fmt("{s}:Config", .{b.pathFromRoot("src/config.zig")}) });
check.addFileInput(b.path("src/config.zig"));
check.addFileArg(b.path("deploy/prod.conf"));
check.setEnvironmentVariable("PATH", std.fs.path.dirname(b.graph.zig_exe).?);
b.step("check-config", "Check the config against Config").dependOn(&check.step);
```
