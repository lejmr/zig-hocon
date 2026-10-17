<img src="docs/brand/zig-Hocon-badge-master-1650x500.png" width="600" alt="zig-Hocon">

zig-hocon reads [HOCON](https://github.com/lightbend/config/blob/main/HOCON.md)
config files into your own Zig structs, the way `std.json` reads JSON:
includes, substitutions, merging and environment variables, as the spec says.
On top of it: a command line tool, a C library and a Python package.

HOCON is JSON made for people: comments, no quotes needed, units like `30s`
and `512MiB`, files that include other files, later settings that merge over
earlier ones, and values taken from other keys or from environment variables.
One base file, one small file per environment on top.

```hocon
# app.conf
db {
  host = localhost
  pool = 4
}
timeout = 30s
cache = 512MiB
debug = false
include "prod.conf"
```

```hocon
# prod.conf
db.host = db.example.org
db.pool = ${?DB_POOL}   # only when DB_POOL is set
```

```zig
const std = @import("std");
const hocon = @import("hocon");

const Config = struct {
    db: struct { host: []const u8, pool: u16 },
    timeout: hocon.Duration,
    cache: hocon.Size,
    debug: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const parsed = try hocon.parseFromFile(Config, init.gpa, init.io, "app.conf", .{
        .env = .{ .map = init.environ_map },
    });
    defer parsed.deinit();
    const config = parsed.value;
    // config.db.host == "db.example.org", config.db.pool == 4, or $DB_POOL
    // config.timeout.whole(.s) == 30, config.cache.whole(.B) == 536870912
}
```

The rest of this page reads these two files.

## Why zig-hocon

- **Correct.** Passes 442 of the 445 tests in the
  [conformance suite](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html),
  one test for each sentence of the spec.\*
- **Your schema is a Zig struct.** HOCON is only what sits on disk; the struct
  says what it holds, with defaults, optionals, enums, durations and sizes.
- **Fast.** A 10 MB config in a quarter of a second.\*\*
- **Clear errors.** File, line, column and a caret, also for a value of the
  wrong type.
- **One file to deploy.** Includes and overrides worked out ahead of time, the
  environment variables left for the server.
- **No dependencies.** The standard library and nothing else.

\* The other three are where the spec leaves room and implementations
disagree.  
\*\* Read and written out as JSON by the command line tool, on an Apple M4 Pro.

## Install

Requires Zig 0.16.

```sh
zig fetch --save https://github.com/lejmr/zig-hocon/archive/refs/tags/v0.4.0.tar.gz
```

That records the dependency in `build.zig.zon`, pinned by its content hash.
Then hand the module to your program in `build.zig`:

```zig
const hocon = b.dependency("hocon", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("hocon", hocon.module("hocon"));
```

The same package has the other three:

| | |
|---|---|
| command line tool | `zig build -Doptimize=ReleaseSafe` in a checkout: `zig-out/bin/hocon` |
| Python | `pip install zig-hocon`, see [python/README.md](python/README.md) |
| C library | `zig build lib -Doptimize=ReleaseSafe`: `libhocon` and [`hocon.h`](include/hocon.h), whose comments are its documentation |

## Use

`parseFromFile` reads the file and what it includes; `parseFromSlice(T, gpa,
text, .{})` reads text, which can include nothing. Both return `Parsed(T)`: an
arena that owns everything in `.value`, freed by one `deinit`. The `Leaky`
twins, `parseFromFileLeaky` and `parseFromSliceLeaky`, take your arena and
return the plain value.

What the options do:

```zig
.{
    .env = .{ .map = init.environ_map }, // where ${DB_POOL} looks; .none (the default) or .keep
    .resolve = false,                    // every ${…} stays as written, for hocon.Value
    .ignore_unknown_fields = false,      // a key the struct has no field for is an error
    .diagnostics = &diag,                // where an error is, see below
    .http_timeout = .fromSeconds(30),    // for an include of an http(s) URL
}
```

**Errors** are plain Zig errors. To know where, pass `Diagnostics`:

```zig
var diag: hocon.Diagnostics = .{};
defer diag.deinit(gpa);
const parsed = hocon.parseFromFile(Config, gpa, io, "app.conf", .{ .diagnostics = &diag }) catch |err| {
    try diag.render(stderr);
    return err;
};
```

With `DB_POOL=eight` in the environment it prints what the zig compiler
would, pointing at where the value comes from:

```
prod.conf:3:11: error: InvalidCharacter at db.pool: expected u16
db.pool = ${?DB_POOL}
          ^
```

`diag.location` has the same `path`, `line`, `column` and the line itself,
`diag.key_path` and `diag.expected` the rest, for a message of your own.

**Durations, periods and sizes** are read in any unit the spec lists, a bare
number in the default one:

```zig
config.timeout.whole(.ms)      // 30000; .as(.minutes) gives an f64, .toIo() a std.Io.Duration
config.cache.whole(.B)         // 536870912; "512MB" counts by 1000, "512MiB" by 1024
period.months                  // hocon.Period: years, months, days, as java.time.Period
```

**The tree itself** is `hocon.Value`, the way `std.json.Value` is:

```zig
const parsed = try hocon.parseFromFile(hocon.Value, gpa, io, "app.conf", .{});
try std.json.Stringify.value(parsed.value, .{}, writer);
```

**Writing HOCON**: `hocon.stringify(value, .{}, writer)` writes a struct or a
`hocon.Value`, so a program can write its defaults once and let each
environment include them; `stringifyAlloc` returns the text.

**A path as text**, a command line argument say, becomes keys by the same
rules as in a file: `hocon.parsePath(arena, "db.\"a.b\"", null)` is `db`, then
`a.b`.

## Command line

`hocon` prints a file resolved, as HOCON or with `--json` as JSON:

```sh
$ hocon --json app.conf
{"db":{"host":"db.example.org","pool":4},"timeout":"30s","cache":"512MiB","debug":false}
```

A `${…}` the file does not answer reads the environment; `--env=none` reads
none. `--env=keep` writes the one file to deploy: includes and overrides worked
out, the variables left for the server:

```sh
$ hocon --env=keep app.conf > deploy.conf
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
$ hocon get db.host app.conf
db.example.org
$ hocon get db --json app.conf
{"host":"db.example.org","pool":4}
```

**check** reads files, and with `--schema` into your struct, so a value of the
wrong type fails as it would in your program. It compiles the struct with the
`zig` on your `PATH`, so the file may import `std` and `hocon` and nothing else:

```sh
$ hocon check --schema config.zig:Config app.conf
app.conf: ok
$ DB_POOL=eight hocon check --schema config.zig:Config app.conf
prod.conf:3:11: error: InvalidCharacter at db.pool: expected u16
db.pool = ${?DB_POOL}
          ^
1 of 1 failed
```

`config.zig` there is the `Config` struct from the top of this page, `pub`.

**diff** compares two files as they resolve, path by path (`~ path: old →
new`, `+` and `-`), and exits 0 when they say the same, as the deploy file
does:

```sh
$ hocon diff app.conf deploy.conf; echo $?
0
```

Each exits 1 when something is wrong, with the place on stderr; `hocon` alone
lists the commands and their flags.

From `build.zig`, run the binary of the dependency. Here `zig build
check-config` checks `deploy/prod/app.conf` against `Config`:

```zig
const hocon = b.dependency("hocon", .{ .target = target, .optimize = optimize });
const check = b.addRunArtifact(hocon.artifact("hocon"));
check.addArgs(&.{ "check", "--schema", b.fmt("{s}:Config", .{b.pathFromRoot("src/config.zig")}) });
check.addFileInput(b.path("src/config.zig"));
check.addFileArg(b.path("deploy/prod/app.conf"));
b.step("check-config", "Check the config against Config").dependOn(&check.step);
```

## Conformance

[`conformance/`](conformance) turns the spec into data: every sentence of it
that says what a config means is a `.conf` file and the value it must give.
Expected values are seeded from typesafe/config, the Java reference, and
checked by hand against the sentence; where the two disagree, the spec wins.

<!-- conformance:start -->
<!-- generated by conformance/maintaining/report.py — do not edit by hand -->

| implementation | against the spec | against typesafe/config 1.4.9 | against typesafe/config main |
|---|---|---|---|
| Java <sub>typesafe/config 1.4.9</sub> | 90% (399/445) | 99% (442/445) | 96% (428/445) |
| Java main <sub>typesafe/config main@275f872, unreleased</sub> | 93% (412/445) | 96% (428/445) | 99% (442/445) |
| pyhocon <sub>pyhocon 0.3.63</sub> | 70% (312/445) | 66% (295/445) | 68% (304/445) |
| zig-hocon <sub>zig-hocon code@f9d16e2</sub> | 99% (442/445) | 90% (399/445) | 93% (412/445) |

<!-- conformance:end -->

Every case, and what each implementation printed, is in
**[the conformance report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html)**.
Any HOCON parser can be scored on it through a ten-line adapter:
[conformance/README.md](conformance/README.md) shows how.

## What is in, what is out

[docs/spec.md](docs/spec.md) goes through the spec section by section: what
is done, how, and where it differs from typesafe/config. Not supported:
`include classpath(…)`, and URL schemes other than http, https and file. Left
out on purpose: the JVM conventions (properties mapping, system property
overrides), and merging two loaded configs in code (`withFallback`), which an
`include` in the file does.

How it is built, and the reference implementations disputes are settled with:
[docs/internals.md](docs/internals.md).

## Contributing

If you need a HOCON feature that is not there, open a pull request; a failing
test that shows what you need is the fastest way to get it prioritized.
[CONTRIBUTING.md](CONTRIBUTING.md) has the workflow.

## License

BSD 3-Clause, see [LICENSE](LICENSE).
