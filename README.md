<p align="center">
  <img src="docs/brand/zig-Hocon-badge-master-1650x500.png" width="600" alt="zig-Hocon">
</p>
<p align="center">
  Reads <a href="https://github.com/lightbend/config/blob/main/HOCON.md">HOCON</a> config files into your own Zig structs, the way <code>std.json</code> reads JSON.
  <br />
  The primary goal is to follow the HOCON specification: includes, substitutions, merging and environment variables are all implemented.
  <br />
  On top of it: a command line tool, a C library and a Python package.
  <br />
  <br />
  <a href="#install">Install</a>
  ·
  <a href="#use">Use</a>
  ·
  <a href="#command-line">Command line</a>
  ·
  <a href="python/README.md">Python</a>
  ·
  <a href="#conformance">Conformance</a>
</p>

HOCON is JSON made for people: comments, no quotes needed, units like `30s` and `512MiB`, files that include other files, later settings that merge over earlier ones, and values taken from other keys or from environment variables. One base file, one small file per environment on top.

```hocon
# app.conf
db {
  host = localhost
  pool = 4
}
timeout = 30s
cache = 512MiB
debug = false
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

The rest of this page reads these two files. **Variables go last.** A later setting hides an earlier one, a `${?…}` too: `workers = ${?WORKERS}` in `app.conf` under `workers = 8` in `prod.conf` is 8 whatever `WORKERS` says. Put what the environment overrides where nothing comes after it, as `prod.conf` here does with `${?DB_POOL}`, or in a file every environment includes last.

## Why zig-hocon

- **To the spec.** Passes all 589 tests of this project's [conformance suite](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html), written from the spec's sentences (276 of its 290 rules) and from fuzzing, each with the value the spec gives and the sentence it rests on.
- **Your schema is a Zig struct.** HOCON is only what sits on disk; the struct says what it holds, with defaults, optionals, enums, durations and sizes.
- **Fast.** A 10 MB config in a quarter of a second.\*
- **Clear errors.** File, line, column and a caret, also for a value of the wrong type.
- **One file to deploy.** Includes and overrides worked out ahead of time, the environment variables left for the server.
- **No dependencies.** The standard library and nothing else.

\* Read and written out as JSON by the command line tool, on an Apple M4 Pro.

## Install

Requires Zig 0.16.

```sh
zig fetch --save https://github.com/lejmr/zig-hocon/archive/refs/tags/v0.6.1.tar.gz
```

That records the dependency in `build.zig.zon`, pinned by its content hash. Then hand the module to your program in `build.zig`:

```zig
const hocon = b.dependency("hocon", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("hocon", hocon.module("hocon"));
```

The same package has the other three:

| | |
|---|---|
| command line tool | `zig build -Doptimize=ReleaseSafe` in a checkout: `zig-out/bin/hocon` |
| Python | `pip install zig-hocon`, see [python/README.md](python/README.md) |
| C library | `zig build lib -Doptimize=ReleaseSafe`: `libhocon` and [`hocon.h`](c/hocon.h), whose comments are its documentation |

## Use

`parseFromFile` reads the file and what it includes; `parseFromSlice(T, gpa, text, .{})` reads text, which can include nothing. Both return `Parsed(T)`: an arena that owns everything in `.value`, freed by one `deinit`. The `Leaky` twins, `parseFromFileLeaky` and `parseFromSliceLeaky`, take your arena and return the plain value.

The options, errors, durations, periods and sizes, a config without a struct and writing HOCON: [docs/zig.md](docs/zig.md).

## Command line

`hocon` prints a file resolved, as HOCON or with `--json` as JSON:

```sh
$ hocon --json prod.conf
{"db":{"host":"db.example.org","pool":4},"timeout":"30s","cache":"512MiB","debug":false}
```

The environment and env files, `get`, `diff`, `check` with a schema, and running it from `build.zig`: [docs/cli.md](docs/cli.md).

## Conformance

[`conformance/`](conformance) turns the spec into data: every sentence of it that says what a config means is a `.conf` file and the value it must give. Expected values are seeded from typesafe/config, the Java reference, and checked by hand against the sentence; where the two disagree, the spec wins.

<!-- conformance:start -->
<!-- generated by conformance/maintaining/report.py — do not edit by hand -->

| implementation | against the spec | against typesafe/config 1.4.9 |
|---|---|---|
| Java <sub>typesafe/config 1.4.9</sub> | 84.4% (497/589) | 99.8% (588/589) |
| hocon.rs <sub>hocon 0.9.0 (Rust)</sub> | 64.7% (381/589) | 65.9% (388/589) |
| hocon2 <sub>hocon2 0.6.3</sub> | 80.8% (476/589) | 71.1% (419/589) |
| pulse-pyhocon <sub>pulse-pyhocon 0.2.1</sub> | 65.2% (384/589) | 61.1% (360/589) |
| py.hocon <sub>hocon-parser 1.14.2 (Python)</sub> | 79.1% (466/589) | 79.5% (468/589) |
| pyhocon <sub>pyhocon 0.3.63</sub> | 64.3% (379/589) | 60.1% (354/589) |
| rs.hocon <sub>hocon-parser 1.14.2 (Rust)</sub> | 78.6% (463/589) | 78.8% (464/589) |
| zig-hocon <sub>zig-hocon code@d8010c4</sub> | 100% (589/589) | 84.6% (498/589) |

The table keeps the best parsers; the others measured, and why they are not in it: [conformance/README.md](conformance/README.md#not-in-the-table).

<!-- conformance:end -->

Every case, and what each implementation printed, is in **[the conformance report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html)**. Any HOCON parser can be scored on it through a ten-line adapter: [conformance/README.md](conformance/README.md) shows how.

## Status

- **Beta until 1.0.** The API can still change; each change is in [CHANGELOG.md](CHANGELOG.md), and what a version may change is in [CONTRIBUTING.md](CONTRIBUTING.md#versions).
- **One maintainer, held by tests; more are welcome** ([CONTRIBUTING.md](CONTRIBUTING.md)). Every change runs the 589 cases of the conformance suite, the tests the C header and the Python package are held to, which only the maintainer edits, and a fuzzer over the parser.
- **Yours to build.** Zig 0.16 and `zig build` give the library, libhocon for C and the command line tool; the suite says what a fork changed.

## What is in, what is out

[docs/spec.md](docs/spec.md) goes through the spec section by section: what is done, how, and where it differs from typesafe/config. [docs/typesafe-config.md](docs/typesafe-config.md) is the short version, for a team on the JVM. Not supported: `include classpath(…)`, and URL schemes other than http, https and file. Left out on purpose: the JVM conventions (properties mapping, system property overrides), and merging two loaded configs in code (`withFallback`), which an `include` in the file does.

How it is built, and the reference implementations disputes are settled with: [docs/internals.md](docs/internals.md).

## AI disclosure

I started this project because I was tired of deciding, in every language I work in, how to do configuration. JSON (naah), YAML (ehmm), TOML (works...), but I always end up with environments and overrides soon enough. PKL and HOCON are the only two that meet my needs, and HOCON is usually my first choice because it is simpler. I also wanted to learn Zig, and a HOCON parser was the obvious project. I learned a lot about data structures, error propagation and memory arenas, and I got to the point where HOCON worked, and I was happy.

The real world is more complicated once you read the whole spec, and each feature would have cost several evenings. So I made the obvious choice and switched to AI-augmented development. I used every development skill I have, but I did not write the code: I broke the product of my dreams into features, had them implemented one by one, and reviewed each at its end. I had my say in the test scenarios, the readability of the code and how the files are organised, so that all of it stays checkable by a human. Up to 0.4.0, the changelog says how much of each release is written by hand.

A lot can change and break over time, so the tests go through what a user touches: the conformance suite, the command line, the C API and the Python package, checking what a user would see and how each is meant to be used.

I am happy with the result: it does everything I need to run and develop my services. In other words, this is a library I use myself, and it will be maintained.

References:

- [What I learned writing a HOCON parser as my first Zig project](https://pubs.miloskozak.cz/posts/hocon-tokenizer-and-parser/)
- [I built a HOCON conformance suite. It found bugs in the reference implementation.](https://pubs.miloskozak.cz/posts/hocon-conformance-suite/)

## Contributing

If you need a HOCON feature that is not there, open a pull request; a failing test that shows what you need is the fastest way to get it prioritized. [CONTRIBUTING.md](CONTRIBUTING.md) has the workflow.

## License

BSD 3-Clause, see [LICENSE](LICENSE).
