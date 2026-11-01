# The `hocon` command

In a checkout, `zig build -Doptimize=ReleaseSafe` builds `hocon` into `zig-out/bin`. From Python, `pip install zig-hocon` puts it on your `PATH`. The examples read `app.conf` and `prod.conf` from the [README](../README.md#use).

## Print a file resolved

`hocon` prints a file resolved, as HOCON or with `--json` as JSON:

```sh
$ hocon --json prod.conf
{"db":{"host":"db.example.org","pool":4},"timeout":"30s","cache":"512MiB"}
```

## Environment variables

A `${…}` that the file leaves open comes from the environment. To see what a deployment will get, keep its variables in a file and pass it with `--env-file`. The file has the `KEY=value` lines docker compose and python-dotenv read, and a file written for a shell's `source`, with `export` and quotes, works as it is:

```sh
# prod.env
DB_HOST=db.internal
DB_POOL=16
# a line written for `source` reads the same
export LOG_LEVEL="warn"
```

The env file goes over your shell's variables. Add `--env=none` and your shell is left out, so a variable the file forgot is missing here too, as it will be on the server:

```sh
$ hocon --json --env=none --env-file=prod.env prod.conf
{"db":{"host":"db.example.org","pool":"16"},"timeout":"30s","cache":"512MiB"}
```

A variable is text, `"16"`; a getter or a struct reads it as the number. With several env files, a later one goes over an earlier one.

## One file to deploy

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
```

## get

`hocon get` prints one value, for a shell script:

```sh
$ hocon get db.host prod.conf
db.example.org
$ hocon get db --json prod.conf
{"host":"db.example.org","pool":4}
```

## diff

`hocon diff` compares two files as they resolve, path by path (`~ path: old → new`, `+` and `-`), and exits 0 when they say the same, as the deploy file does, 1 when they differ and 2 when one cannot be read:

```sh
$ DB_POOL=16 hocon diff app.conf prod.conf; echo $?
~ db.host: "localhost" → "db.example.org"
~ db.pool: 4 → "16"
1
$ hocon diff prod.conf deploy.conf; echo $?
0
```

## check

`hocon check` reads files, and with `--schema` into your struct, so a value of the wrong type fails as it would in your program. A key the struct has no field for is skipped, as `parseFromFile` does by default; a program with `.ignore_unknown_fields = false` refuses it where `check` does not. It compiles the struct with the `zig` on your `PATH`, so the file may import `std` and `hocon` and nothing else:

```sh
$ hocon check --schema config.zig:Config prod.conf
prod.conf: ok
$ DB_POOL=eight hocon check --schema config.zig:Config prod.conf
prod.conf:4:11: error: InvalidCharacter at db.pool: expected u16
db.pool = ${?DB_POOL}   # only when DB_POOL is set
          ^
1 of 1 failed
```

`config.zig` there is the `Config` struct from the [README](../README.md#use), declared `pub`, with `const hocon = @import("hocon");`.

## Exit codes

Each exits 1 when something is wrong, with the place on stderr (`diff` as above); `hocon` alone lists the commands and their flags.

## In build.zig

From `build.zig`, run the binary of the dependency, built for the machine the build runs on; `--schema` runs the `zig` on its `PATH`, here the one running the build. Next to the [Install](../README.md#install) lines, `zig build check-config` checks `deploy/prod.conf` against `Config`:

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
