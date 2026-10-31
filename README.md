<p align="center">
  <img src="docs/brand/zig-Hocon-badge-master-1650x500.png" width="600" alt="zig-Hocon">
</p>
<p align="center">
  A <a href="https://github.com/lightbend/config/blob/main/HOCON.md">HOCON</a> parser written in Zig: one core, used from Zig, from the command line, from C and from Python.
  <br />
  The primary goal is to follow the HOCON specification: includes (all but <code>classpath(…)</code>), substitutions, merging and environment variables are implemented.
  <br />
  In Zig it reads config files into your own structs, the way <code>std.json</code> reads JSON.
  <br />
  <br />
  <a href="#install">Install</a>
  ·
  <a href="#use-from-zig">Zig</a>
  ·
  <a href="python/README.md">Python</a>
  ·
  <a href="#command-line">Command line</a>
  ·
  <a href="#conformance">Conformance</a>
  ·
  <a href="#coming-from-typesafeconfig">Coming from typesafe/config</a>
</p>

Where to read on, by what you use:

- **Python**: `pip install zig-hocon`, then [python/README.md](python/README.md). Wheels for Python 3.10 and later on Linux (x86_64, aarch64; glibc and musl), macOS and Windows. Coming from pyhocon: [python/MIGRATING.md](python/MIGRATING.md) lists every difference, and `zig-hocon-migrate` shows which of them your configs hit.
- **Zig**: this page, from [Install](#install) on.
- **C**: libhocon and [`c/hocon.h`](c/hocon.h), whose comments are its documentation.
- **Shell and CI**: the [`hocon` command](#command-line).
- **The JVM**: [Coming from typesafe/config](#coming-from-typesafeconfig) says where zig-hocon reads a config differently.

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

In Zig:

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

In Python ([python/README.md](python/README.md)):

```python
from zig_hocon import ConfigFactory

conf = ConfigFactory.parse_file("prod.conf")
conf.get_string("db.host")   # "db.example.org"
conf.get_int("db.pool")      # 4, or $DB_POOL when it is set
```

The rest of this page reads these two files.

## Why zig-hocon

- **Correct.** Passes all 589 cases of its [conformance suite](#conformance). Each case checks one sentence of the spec, and together they cover 276 of its 290 rules. The suite is the maintainer's own reading of the spec; the next section says what that means and where zig-hocon differs from typesafe/config.
- **Your schema is a Zig struct.** HOCON is only what sits on disk; the struct says what it holds, with defaults, optionals, enums, durations and sizes. In Python a pydantic or msgspec model does the same job ([python/README.md](python/README.md#into-a-model)).
- **Fast.** A 1 KB config with substitutions parses and resolves in 0.014 ms in Zig and 0.093 ms through Python; a 1 MB one takes 12.6 ms either way.\*
- **Clear errors.** File, line, column and a caret, also for a value of the wrong type.
- **One file to deploy.** Includes and overrides are worked out ahead of time, and the environment variables are left for the server.
- **No dependencies.** The Zig standard library and nothing else; in Python, a thin ctypes layer over one bundled library.

\* Text already in memory, median of warm runs, on an Apple M4 Pro, measured on v0.5.3-23-gca6d6f4: [python/BENCHMARK.md](python/BENCHMARK.md), next to the other Python parsers and typesafe/config. Import and process start-up time are not measured.

## Conformance

[`conformance/`](conformance) turns the spec into data: every sentence of it that says what a config means is a `.conf` file and the value it must give. The maintainer of zig-hocon wrote the suite as well as the parser. Expected values were seeded from typesafe/config 1.4.9, the Java reference implementation, and then checked by hand against the sentence of the spec. Where the two disagree, the case follows the spec and records what typesafe/config does next to it. Where the spec leaves room, the suite takes one reading and lists it in [conformance/README.md](conformance/README.md#readings-the-suite-takes). So "100 % against the spec" means that zig-hocon agrees with this suite's reading of the spec.

**zig-hocon differs from typesafe/config 1.4.9 in 91 of the 589 cases.** These are exactly the cases where the suite's reading of the spec and typesafe/config part ways. They are listed in [the conformance report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html) when you switch it to scoring against typesafe/config, and each case's `.json` file says which way the two differ. Measured on the 588 cases it was last run on, typesafe/config falls short of the spec's reading in the same 91:

- **12 are how numbers are read.** The spec says the "allowed number formats matches JSON" (L120), and the suite takes that literally: `01`, `1.` and `127.0.0.1` are the text they were written as. typesafe/config reads `01` as the number `1`, so someone coming from Java sees a difference here.
- **16 are fixed upstream** on lightbend/config main ([#861](https://github.com/lightbend/config/pull/861), [#862](https://github.com/lightbend/config/pull/862), [#864](https://github.com/lightbend/config/pull/864)), not in a release yet. <!-- VERIFY: merged upstream? -->
- **19 are bugs reported upstream**: the case links the lightbend/config issue or pull request.
- **44 have no upstream reference.** In 27 of them typesafe/config refuses valid input: some are internal errors such as `BugOrBroken`, some are things it does not support by design, such as an array as the root of the document. In 9 it gives a different value, and in 8 it accepts input the spec forbids.

To check whether another parser reads configs the way your JVM services do, score it with `conformance/run.sh --java`, which compares it with typesafe/config 1.4.9 instead of the spec.

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

Besides typesafe/config and zig-hocon, the table has pyhocon, every other Python parser of its own that scores above 60 % against the spec, the best-scoring Rust parser, and `hocon`, the Rust crate of that name. The others measured, and why they are left out: [conformance/README.md](conformance/README.md#not-in-the-table).

<!-- conformance:end -->

Every case, and what each implementation printed, is in **[the conformance report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html)**. Any HOCON parser can be scored on it through an adapter of about ten lines: [conformance/README.md](conformance/README.md) shows how.

## Coming from typesafe/config

zig-hocon reads the same format, but not always the same way, and it leaves out what belongs to the JVM rather than to HOCON ([docs/spec.md](docs/spec.md)). What you are most likely to run into:

- **A number is a number only as JSON writes it.** `01`, `1.`, `08` and `127.0.0.1` stay text, where typesafe/config reads `01` as `1`; an integer getter or struct field refuses such text. In a duration, `.5 s` and `01 s`, which typesafe/config takes, are errors.
- **`1.5` read as an integer is an error**, not a silent `1`.
- **`include classpath(…)` is not supported**: it is an error. Files, `file()`, `required()` and http(s) URLs are, as `.conf`, `.json` or `.properties`.
- **No JVM conventions**: no system property overrides, no mapping from Java properties beyond the `.properties` lines [docs/spec.md](docs/spec.md) lists, and no conventional file names, so nothing loads `application.conf` or a `reference.conf` from every jar on its own.
- **No `withFallback`.** There is no way to merge two configs that are already loaded, or a config built in code, the way `withFallback` and the `reference.conf` layering do. What there is: layers in files, a file that includes the defaults and then overrides them, as `prod.conf` above does with `app.conf`; text made of `include` lines read from a directory, when the layers are chosen at run time (`parseFromSliceInDirLeaky` in Zig, `include_dir` in C, `parse_string(…, basedir=…)` in Python); and in Zig, defaults as the struct's field defaults, which a key missing from the file takes.
- **91 cases of the conformance suite read differently** ([above](#conformance)). `hocon` prints what zig-hocon reads, which in those cases is not what a JVM service loads.

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

The same package also builds the other three:

| | |
|---|---|
| command line tool | `zig build -Doptimize=ReleaseSafe` in a checkout gives `zig-out/bin/hocon`; `pip install zig-hocon` also puts `hocon` on the path, without `check --schema` |
| Python | `pip install zig-hocon`, see [python/README.md](python/README.md) |
| C library | `zig build lib -Doptimize=ReleaseSafe` gives `libhocon` and [`hocon.h`](c/hocon.h), whose comments are its documentation |

## Use from Zig

`parseFromFile` reads the file and every file it includes. `parseFromSlice(T, gpa, text, .{})` reads text; there is no file behind it to include from, so an `include` in it is an error (`parseFromSliceInDirLeaky` reads the includes from a directory you give). Both return `Parsed(T)`: an arena that owns everything in `.value`, freed by one `deinit`. The `Leaky` twins, `parseFromFileLeaky` and `parseFromSliceLeaky`, take your arena and return the plain value.

What the options do, each set to something other than its default:

```zig
.{
    .env = .{ .map = init.environ_map }, // where ${DB_POOL} looks; default .none, no variables; or .keep
    .resolve = false,                    // default true; false keeps every ${…} as written, for hocon.Value
    .ignore_unknown_fields = false,      // default true, a key the struct has no field for is skipped; false makes it an error
    .diagnostics = &diag,                // default null; where an error is, see below
    .http_timeout = .fromSeconds(5),     // default 30 s; for an include of an http(s) URL
}
```

**Errors** are plain Zig errors. To know where, pass `Diagnostics`:

```zig
var diag: hocon.Diagnostics = .{};
defer diag.deinit(init.gpa);
const parsed = hocon.parseFromFile(Config, init.gpa, init.io, "prod.conf", .{
    .env = .{ .map = init.environ_map },
    .diagnostics = &diag,
}) catch |err| {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(init.io, &buffer);
    try diag.render(&stderr.interface); // any *std.Io.Writer
    try stderr.interface.flush();
    return err;
};
```

With `DB_POOL=eight` in the environment it prints what the zig compiler would, pointing at where the value comes from:

```
prod.conf:4:11: error: InvalidCharacter at db.pool: expected u16
db.pool = ${?DB_POOL}   # only when DB_POOL is set
          ^
```

For a message of your own, `diag.location` has the same `path`, `line` and `column` and the text of the line, `diag.key_path` the key, and `diag.expected` the type that was wanted.

**Durations, periods and sizes** are read in any unit the spec lists. A number without a unit is in the spec's default unit: milliseconds for a duration, bytes for a size, days for a period.

```zig
config.timeout.whole(.ms)      // 30000; .as(.minutes) gives an f64, .toIo() a std.Io.Duration
config.cache.whole(.B)         // 536870912; "512MB" counts by 1000, "512MiB" by 1024
period.months                  // hocon.Period: years, months, days, as java.time.Period
```

The units are `.ns`, `.us`, `.ms`, `.s`, `.min`, `.h`, `.d` and `.w` for a duration, and `.B`, `.kB`, `.MB`, `.GB`, `.TB`, `.PB`, `.EB` and `.KiB` … `.EiB` for a size. How large a duration or a size can be, in Zig, C and Python, is in [docs/spec.md](docs/spec.md).

**Without a struct**, when the keys are not known ahead of time, ask for `hocon.Value`: the whole tree of objects, lists and values, to walk with a `switch`. `std.json.Stringify` prints it as JSON:

```zig
const parsed = try hocon.parseFromFile(hocon.Value, gpa, io, "prod.conf", .{});
try std.json.Stringify.value(parsed.value, .{}, writer);
```

**Writing HOCON**: `hocon.stringify(value, .{}, writer)` writes a struct or a `hocon.Value`, so a program can write its defaults once and let each environment include them; `stringifyAlloc` returns the text.

## Command line

`hocon` prints a file resolved, as HOCON or with `--json` as JSON:

```sh
$ hocon --json prod.conf
{"db":{"host":"db.example.org","pool":4},"timeout":"30s","cache":"512MiB","debug":false}
```

A `${…}` that the file does not answer reads the process environment; `--env=none` turns that off. `--env-file=prod.env` reads the `KEY=value` lines of a file, the way docker compose and python-dotenv read them, and puts them over the environment. A file written for a shell's `source`, with `export` and quotes, works as it is. With several env files, a later one goes over an earlier one, and with `--env=none` the env files are the only variables there are. So `hocon check --env=none --env-file=prod.env prod.conf` checks a deployment against its own variables and nothing from your shell.

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

**diff** compares two files as they resolve, path by path (`~ path: old → new`, `+` and `-`). It exits 0 when they say the same, as the deploy file does, 1 when they differ and 2 when one cannot be read:

```sh
$ hocon diff prod.conf deploy.conf; echo $?
0
```

**check** reads each file and says which fail and where. With `--schema` it also reads them into your struct, so a value of the wrong type fails as it would in your program. It compiles the struct with the `zig` on your `PATH`, so the file may import `std` and `hocon` and nothing else. It skips a key the struct has no field for, whatever your program does ([Gotchas](#gotchas)).

```sh
$ hocon check --schema config.zig:Config prod.conf
prod.conf: ok
$ DB_POOL=eight hocon check --schema config.zig:Config prod.conf
prod.conf:4:11: error: InvalidCharacter at db.pool: expected u16
db.pool = ${?DB_POOL}   # only when DB_POOL is set
          ^
1 of 1 failed
```

`config.zig` there holds the `Config` struct from the top of this page, declared `pub`.

Every command exits 1 when something is wrong, except `diff`, which exits 2 because 1 means the files differ. What went wrong, and where, goes to stderr. `hocon` with no arguments lists the commands and their flags.

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

## Defaults that matter in production

| | Zig | `hocon` | C | Python |
|---|---|---|---|---|
| a `${X}` not in the file reads | nothing: `.env = .none`; pass `.{ .map = init.environ_map }` for the process environment | the process environment; `--env=none` for nothing | the process environment (`HOCON_ENV_PROCESS`, also with `NULL` options); `HOCON_ENV_NONE` for nothing | `os.environ`; `env=None` for nothing |
| an http(s) include | fetched, 30 s per fetch; `.http_timeout` | fetched, 30 s per fetch; no flag to change it | fetched; `http_timeout_ms`, 0 is 30 s | fetched; `http_timeout=`, 30 s by default |

- **http(s) includes cannot be turned off.** No surface has an option for it: a file that includes a URL fetches it, during the parse. The only way to read with no includes at all is to read the text yourself and parse it as text: `parseFromSlice` in Zig, `hocon_parse_string` with `include_dir` left `NULL` in C, `parse_string` without `basedir` in Python. Each of them refuses every include, files too. The command line tool reads only files.
- **Everything is resolved inside the parse call.** Includes are read first, then the substitutions resolve once over the whole document, against the environment as it is at that moment. Keep mode (`.keep`, `--env=keep`, `HOCON_ENV_KEEP`, `env=KEEP`) and reading without resolving (`resolve = false`) leave the `${…}` in, for later.

## Gotchas

- **Variables go last.** A later setting hides an earlier one, and that includes a `${?…}`. If `app.conf` has `workers = ${?WORKERS}` and `prod.conf` sets `workers = 8` after its `include`, `workers` is 8 whatever `WORKERS` says. Put a setting the environment overrides where nothing comes after it, as `prod.conf` does with `${?DB_POOL}`, or in a file that every environment includes last.
- **Zig reads no environment unless you pass it**, while `hocon`, C and Python read the process environment by default ([the table above](#defaults-that-matter-in-production)).
- **`hocon check --schema` skips unknown keys.** It reads with the default options, so a key the struct has no field for is skipped, as `parseFromFile` does by default. A program that sets `.ignore_unknown_fields = false` refuses that key, so a file `check` passes can still stop that program; `check` has no flag for it.

## What is in, what is out

[docs/spec.md](docs/spec.md) goes through the spec section by section: what is done, how, and where it differs from typesafe/config. Not supported: `include classpath(…)`, and URL schemes other than http, https and file. Left out on purpose: the JVM conventions (properties mapping, system property overrides, conventional file names) and merging two loaded configs in code (`withFallback`); [Coming from typesafe/config](#coming-from-typesafeconfig) says what to do instead.

How it is built, and the reference implementations disputes are settled with: [docs/internals.md](docs/internals.md).

## Status

- **Beta until 1.0.** The API can still change; each change is in [CHANGELOG.md](CHANGELOG.md), and what a version may change is in [CONTRIBUTING.md](CONTRIBUTING.md#versions).
- **Releases.** Ten so far, from v0.1.0 on 2026-10-15 to v0.6.1 on 2026-10-30, each with its section in [CHANGELOG.md](CHANGELOG.md). One release is one tag for the Zig package, libhocon and the Python package at once. Only the Release workflow makes one, after every test has passed on Linux, macOS and Windows and every wheel on each Python ([CONTRIBUTING.md](CONTRIBUTING.md#releasing)).
- **Zig versions.** Built and tested with Zig 0.16.0. A weekly CI job builds against Zig master to show early what breaks; it is informational and blocks nothing.
- **Tests.** CI runs `zig build test` on Linux (x86_64, aarch64), macOS (arm64, x86_64) and Windows, which includes the C library's tests; the Python package's tests on every wheel; and a few minutes of fuzzing on every pull request. The tests in `c/tests/` and `python/tests/` stand for users' code, and only the maintainer changes them. Before a push, a git hook runs the conformance suite on the code being pushed and commits the result ([CONTRIBUTING.md](CONTRIBUTING.md#local-setup)). A weekly job opens an issue when the spec changes upstream.
- **One maintainer; more are welcome** ([CONTRIBUTING.md](CONTRIBUTING.md)).
- **Yours to build.** Zig 0.16 and `zig build` give the library, libhocon for C and the command line tool; the conformance suite shows what a fork changed.

## AI disclosure

I started this project to learn Zig, and because I was tired of deciding how to do configuration in every language I work in; HOCON is usually my first choice. I wrote the first working version by hand. The whole spec turned out to be much more, so from then on I switched to AI-augmented development: I broke the product into features, had them implemented one by one, and reviewed each at its end. I did not write that code. I had my say in the test scenarios, the readability of the code and how the files are organised, so that all of it stays checkable by a human. CHANGELOG.md gives the share of `src/` written by hand for each release from v0.1.0 to v0.4.0. I use this library for my own services, and it will be maintained.

More on how it was made:

- [What I learned writing a HOCON parser as my first Zig project](https://pubs.miloskozak.cz/posts/hocon-tokenizer-and-parser/)
- [I built a HOCON conformance suite. It found bugs in the reference implementation.](https://pubs.miloskozak.cz/posts/hocon-conformance-suite/)
- [All I wanted was to see inside an ArrayList](https://pubs.miloskozak.cz/posts/zig-debugging-in-zed/), Zig debugging in Zed

## Contributing

If you need a HOCON feature that is not there, open a pull request; a failing test that shows what you need is the fastest way to get it prioritized. [CONTRIBUTING.md](CONTRIBUTING.md) has the workflow.

## License

BSD 3-Clause, see [LICENSE](LICENSE).
