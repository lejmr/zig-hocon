# The hocon command

What `hocon` does beyond printing a file: the environment, env files, `get`, `diff`, `check` and `check --schema`, and running it from `build.zig`. The examples read `app.conf` and `prod.conf`, the two files at the top of the [README](../README.md).

A `${…}` the file does not answer reads the environment; `--env=none` reads none. `--env-file=prod.env` puts the `KEY=value` lines of a file over it, as docker compose and python-dotenv read them; a file written for a shell's `source`, with `export` and quotes, works as it is. A later file goes over an earlier one, and with `--env=none` they are all there is: `hocon check --env=none --env-file=prod.env prod.conf` checks a deployment against its own variables and nothing from your shell.

```sh
# prod.env
DB_HOST=db.internal
DB_POOL=16
# a line written for `source` reads the same
export LOG_LEVEL="warn"
```

`--env=keep` writes the one file to deploy: includes and overrides worked out, the variables left for the server:

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

**get** prints one value, for a shell script:

```sh
$ hocon get db.host prod.conf
db.example.org
$ hocon get db --json prod.conf
{"host":"db.example.org","pool":4}
```

**diff** compares two files as they resolve, path by path (`~ path: old → new`, `+` and `-`), and exits 0 when they say the same, as the deploy file does, 1 when they differ and 2 when one cannot be read:

```sh
$ hocon diff prod.conf deploy.conf; echo $?
0
```

**check** reads files, and with `--schema` into your struct, so a value of the wrong type fails as it would in your program. A key the struct has no field for is skipped, as `parseFromFile` does by default; a program with `.ignore_unknown_fields = false` refuses it where `check` does not. It compiles the struct with the `zig` on your `PATH`, so the file may import `std` and `hocon` and nothing else:

```sh
$ hocon check --schema config.zig:Config prod.conf
prod.conf: ok
$ DB_POOL=eight hocon check --schema config.zig:Config prod.conf
prod.conf:4:11: error: InvalidCharacter at db.pool: expected u16
db.pool = ${?DB_POOL}   # only when DB_POOL is set
          ^
1 of 1 failed
```

`config.zig` there is the `Config` struct from the top of this page, `pub`.

Each exits 1 when something is wrong (`diff` 2, as 1 is a difference), with the place on stderr; `hocon` alone lists the commands and their flags.

From `build.zig`, run the binary of the dependency. Here `zig build check-config` checks `deploy/prod.conf` against `Config`:

```zig
const hocon = b.dependency("hocon", .{ .target = target, .optimize = optimize });
const check = std.Build.Step.Run.create(b, "check config");
check.addFileArg(hocon.namedLazyPath("cli"));
check.addArgs(&.{ "check", "--schema", b.fmt("{s}:Config", .{b.pathFromRoot("src/config.zig")}) });
check.addFileInput(b.path("src/config.zig"));
check.addFileArg(b.path("deploy/prod.conf"));
b.step("check-config", "Check the config against Config").dependOn(&check.step);
```
