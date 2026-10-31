<p align="center">
  <img src="docs/brand/zig-Hocon-badge-master-1650x500.png" width="600" alt="zig-hocon">
</p>

Read [HOCON](https://github.com/lightbend/config/blob/main/HOCON.md) config files into your own Zig structs, the way `std.json` reads JSON: includes, substitutions, merging, environment variables, durations and sizes. No dependencies beyond the standard library. The same core also ships as the `hocon` command line tool, a C library and a Python package.

**Beta**, with one maintainer: the API can still change before 1.0 ([CHANGELOG.md](CHANGELOG.md)). Most of the code is written with AI and reviewed by the maintainer ([how](docs/ai-disclosure.md)).

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

- **No environment by default.** `.env` is `.none`, so `${DB_POOL}` finds nothing unless you pass `.{ .map = init.environ_map }` as above, or `.keep` to leave the variables in for the server.
- **Unknown keys are skipped**, unlike `std.json`: `.ignore_unknown_fields` defaults to `true`. Set it to `false` and a misspelled key is `error.UnknownField`.
- **Variables go last.** A later setting hides an earlier `${?…}`: with `workers = ${?WORKERS}` in `app.conf` and `workers = 8` after the include in `prod.conf`, `workers` is 8 whatever `WORKERS` says.
- **An http(s) include is fetched during the parse**, 30 s per fetch (`.http_timeout`), and no option turns that off. `parseFromSlice` refuses every include, files too.
- **Errors are plain Zig errors.** To see where, pass `.diagnostics = &diag` (a `hocon.Diagnostics`, freed with `diag.deinit(gpa)`); `diag.render(writer)` prints it the way the compiler would. With `DB_POOL=eight`:

```
prod.conf:4:11: error: InvalidCharacter at db.pool: expected u16
db.pool = ${?DB_POOL}   # only when DB_POOL is set
          ^
```

The same defaults on the other surfaces, and what is resolved when: [docs/production.md](docs/production.md).

## Also from

- **Shell and CI:** `pip install zig-hocon` puts `hocon` on your `PATH`, or `zig build -Doptimize=ReleaseSafe` builds it into `zig-out/bin`. It prints, gets, checks and diffs resolved configs, and `hocon check --schema config.zig:Config prod.conf` reads them into your struct, also as a step in your `build.zig`: [docs/cli.md](docs/cli.md).
- **C:** libhocon for Linux, macOS and Windows on the [releases page](https://github.com/lejmr/zig-hocon/releases), or `zig build lib`; [`c/hocon.h`](c/hocon.h) is its documentation.
- **Python:** `pip install zig-hocon`, see [python/README.md](python/README.md); from pyhocon, [python/MIGRATING.md](python/MIGRATING.md).
- **From typesafe/config:** [docs/typesafe-config.md](docs/typesafe-config.md) says where zig-hocon reads a config differently, and what it leaves out.

## Conformance

zig-hocon passes all 589 cases of [its conformance suite](conformance/README.md), each one sentence of the spec. The maintainer wrote the suite as well as the parser, seeding it from typesafe/config 1.4.9 and checking each case by hand against the spec, so 100 % means agreement with [this suite's reading](conformance/README.md#readings-the-suite-takes). Against typesafe/config itself zig-hocon differs in 91 cases; [why](docs/typesafe-config.md#the-91-cases), and every case in [the report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html).

<!-- conformance:start -->
<!-- generated by conformance/maintaining/report.py — do not edit by hand -->

| implementation | against this suite's reading of the spec | against typesafe/config 1.4.9 |
|---|---|---|
| Java <sub>typesafe/config 1.4.9</sub> ¹ | 84.5% (497/588) | 100% (588/588) |
| hocon.rs <sub>hocon 0.9.0 (Rust)</sub> ¹ | 64.8% (381/588) | 66.0% (388/588) |
| hocon2 <sub>hocon2 0.6.3</sub> ¹ | 81.0% (476/588) | 71.3% (419/588) |
| pulse-pyhocon <sub>pulse-pyhocon 0.2.1</sub> ¹ | 65.3% (384/588) | 61.2% (360/588) |
| py.hocon <sub>hocon-parser 1.14.2 (Python)</sub> ¹ | 79.3% (466/588) | 79.6% (468/588) |
| pyhocon <sub>pyhocon 0.3.63</sub> ¹ | 64.5% (379/588) | 60.2% (354/588) |
| rs.hocon <sub>hocon-parser 1.14.2 (Rust)</sub> ¹ | 78.7% (463/588) | 78.9% (464/588) |
| zig-hocon <sub>zig-hocon code@d8010c4</sub> | 100% (589/589) | 84.6% (498/589) |

¹ Measured on an older version of the suite, with 588 cases (it has 589 now), and scored out of the cases it had then.

Which parsers the table has:

- typesafe/config and zig-hocon
- pyhocon
- every other Python library with a HOCON parser of its own, not a wrapper around pyhocon, above 60 % against the spec
- the best-scoring Rust parser, and `hocon`, the Rust crate of that name

The others measured, and why they are left out: [conformance/README.md](conformance/README.md#not-in-the-table).

<!-- conformance:end -->

## Contributing

A failing test that shows what you need is the fastest way to get it; [CONTRIBUTING.md](CONTRIBUTING.md) has the workflow. BSD 3-Clause, see [LICENSE](LICENSE).
