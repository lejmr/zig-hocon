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
  <a href="#beyond-zig">Command line &amp; C</a>
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

A field can be any integer, float, `bool`, string, slice, array, struct (with defaults), enum, optional, tagged union, `hocon.Duration`, `hocon.Size`, `hocon.Period`.

Unlike `std.json`, unknown keys are skipped; set `.ignore_unknown_fields = false` to catch a misspelled key.

### Errors

They are plain Zig errors. To see where, pass `.diagnostics = &diag`, and `diag.render(writer)` prints it the way the compiler would:

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

## Beyond Zig

- **Command line:** `hocon` prints a config resolved, writes the one file to deploy with the variables left for the server, gets one value for a script, checks files against your struct, and diffs two configs as they resolve: [docs/cli.md](docs/cli.md).
- **C:** libhocon for Linux, macOS and Windows on the [releases page](https://github.com/lejmr/zig-hocon/releases), or `zig build lib`; [`c/hocon.h`](c/hocon.h) is its documentation.
- **Python:** `pip install zig-hocon`, see [python/README.md](python/README.md); from pyhocon, [python/MIGRATING.md](python/MIGRATING.md).

The `hocon` command, C and Python read the process environment by default, where the Zig library reads none: [docs/production.md](docs/production.md) has the defaults of each.

## Conformance

The repository carries a conformance suite meant as a reference for any HOCON implementation: cases derived from the sentences of the prose spec, each a config file, with its includes and environment, and the JSON it must resolve to, or a rejection. It checks end to end, text in and resolved value out, so any parser can be scored through a ten-line adapter. Where the spec leaves room, the suite takes one reading and [says so](conformance/README.md#readings-the-suite-takes). It does not yet check what a duration or size means, which error a rejection is, or http(s) includes.

zig-hocon is the first parser built against it, by the same maintainer, and passes all of them. Where typesafe/config 1.4.9 reads a case differently, the case records what it does; [docs/spec.md](docs/spec.md) says, section by section, where zig-hocon reads a config differently. How other parsers score: [conformance/README.md](conformance/README.md#published-results); every case: [the report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html).

## AI disclosure

I wrote the first working version by hand. The whole spec turned out to be much more, so from then on I switched to AI-augmented development: I broke the product into features, had them implemented one by one, and reviewed each. I use this library for my own services, and it will be maintained. More in [What I learned writing a HOCON parser as my first Zig project](https://pubs.miloskozak.cz/posts/hocon-tokenizer-and-parser/).

## Contributing

A failing test that shows what you need is the fastest way to get it; [CONTRIBUTING.md](CONTRIBUTING.md) has the workflow. BSD 3-Clause, see [LICENSE](LICENSE).
