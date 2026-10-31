<p align="center">
  <img src="docs/brand/zig-Hocon-badge-master-1650x500.png" width="600" alt="zig-hocon">
</p>
<p align="center">
  Read <a href="https://github.com/lightbend/config/blob/main/HOCON.md">HOCON</a> config files into your own Zig structs, the way <code>std.json</code> reads JSON.
  <br />
  Includes, substitutions, merging, environment variables, durations and sizes; no dependencies beyond the standard library.
  <br />
  The same core also ships as the <code>hocon</code> command line tool, a C library and a Python package.
  <br />
  <br />
  <a href="#install">Install</a>
  ·
  <a href="#use">Use</a>
  ·
  <a href="#before-you-ship">Before you ship</a>
  ·
  <a href="#also-from">Command line &amp; C</a>
  ·
  <a href="python/README.md">Python</a>
  ·
  <a href="#conformance">Conformance</a>
</p>

**Beta**: the API can change before 1.0 ([CHANGELOG.md](CHANGELOG.md)).

## Install

Requires Zig 0.16.

```sh
zig fetch --save https://github.com/lejmr/zig-hocon/archive/refs/tags/v0.6.1.tar.gz
```

```zig
// build.zig
const hocon = b.dependency("hocon", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("hocon", hocon.module("hocon"));
```

## Use

```hocon
# app.conf
db {
  host = localhost
  pool = 4
}
timeout = 30s
cache = 512MiB
```

```hocon
# prod.conf
include "app.conf"
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
    const parsed = try hocon.parseFromFile(Config, init.gpa, init.io, "prod.conf", .{
        .env = .{ .map = init.environ_map },
    });
    defer parsed.deinit();
    const config = parsed.value;
    std.debug.print("{s} pool {d}, timeout {d} s\n", .{ config.db.host, config.db.pool, config.timeout.whole(.s) });
    // db.example.org pool 4 (or $DB_POOL), timeout 30 s; config.cache.whole(.B) == 536870912
}
```

`Parsed(T)` owns everything in `.value` until `deinit`. A field can be any integer, float, `bool`, string, slice, array, struct (with defaults), enum, optional, tagged union, `hocon.Duration`, `hocon.Size`, `hocon.Period`, or `hocon.Value` for a tree you walk yourself. `parseFromSlice` reads text instead of a file (`[:0]const u8`), the `…Leaky` variants allocate into your arena, and `hocon.stringify` writes a struct or a `Value` back as HOCON. Every option is documented where it is declared, in [src/Config.zig](src/Config.zig).

## Before you ship

These are the Zig library's defaults; the `hocon` command, C and Python read the process environment by default ([docs/production.md](docs/production.md) has every surface, and what is resolved when).

- **No environment by default.** `.env` is `.none`, so `${DB_POOL}` finds nothing unless you pass `.{ .map = init.environ_map }` as above, or `.keep` to leave the `${…}` in, for whatever reads the file on the machine it is deployed to.
- **Unknown keys are skipped**, unlike `std.json`: `.ignore_unknown_fields` defaults to `true`. Set it to `false` and a misspelled key is `error.UnknownField`.
- **Put `${?…}` overrides last.** A later setting hides an earlier one, a `${?…}` too: with `workers = ${?WORKERS}` in `app.conf` and `workers = 8` after the include in `prod.conf`, `workers` is 8 whatever `WORKERS` says.
- **An http(s) include is downloaded during the parse**, with a 30 s timeout by default (`.http_timeout`).
- **Errors are plain Zig errors.** To see where, pass `.diagnostics = &diag` (a `hocon.Diagnostics`, freed with `diag.deinit(gpa)`); `diag.render(writer)` prints it the way the compiler would:

```zig
var diag: hocon.Diagnostics = .{};
defer diag.deinit(init.gpa);
const parsed = hocon.parseFromFile(Config, init.gpa, init.io, "prod.conf", .{
    .env = .{ .map = init.environ_map },
    .diagnostics = &diag,
}) catch |err| {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
    try diag.render(&stderr.interface);
    try stderr.interface.flush();
    return err;
};
defer parsed.deinit();
```

With `DB_POOL=eight`:

```
prod.conf:4:11: error: InvalidCharacter at db.pool: expected u16
db.pool = ${?DB_POOL}   # only when DB_POOL is set
          ^
```

## Also from

- **Shell and CI:** `pip install zig-hocon` puts `hocon` on your `PATH`, or `zig build -Doptimize=ReleaseSafe` builds it into `zig-out/bin`. It prints, gets, checks and diffs resolved configs, and `hocon check --schema config.zig:Config prod.conf` reads them into your struct, also as a step in your `build.zig`: [docs/cli.md](docs/cli.md).
- **C:** libhocon for Linux, macOS and Windows on the [releases page](https://github.com/lejmr/zig-hocon/releases), or `zig build lib`; [`c/hocon.h`](c/hocon.h) is its documentation.
- **Python:** `pip install zig-hocon`, see [python/README.md](python/README.md); from pyhocon, [python/MIGRATING.md](python/MIGRATING.md).
- **From typesafe/config:** [docs/typesafe-config.md](docs/typesafe-config.md) says where zig-hocon reads a config differently, and what it leaves out.

## Conformance

zig-hocon passes all 589 cases of [its conformance suite](conformance/README.md), each one sentence of the spec. The maintainer wrote the suite as well as the parser, seeding it from typesafe/config 1.4.9 and checking each case by hand against the spec, so 100 % means agreement with [this suite's reading](conformance/README.md#readings-the-suite-takes). Against typesafe/config itself zig-hocon differs in 91 cases; [why](docs/typesafe-config.md#the-91-cases). How other parsers score: [conformance/README.md](conformance/README.md#published-results); every case: [the report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html).

## Contributing

A failing test that shows what you need is the fastest way to get it; [CONTRIBUTING.md](CONTRIBUTING.md) has the workflow. BSD 3-Clause, see [LICENSE](LICENSE).
