<img src="docs/brand/zig-Hocon-badge-master-1650x500.png" width="600" alt="zig-Hocon">

zig-Hocon is a [HOCON](https://github.com/lightbend/config/blob/main/HOCON.md)
(Human-Optimized Config Object Notation) parser for [Zig](https://ziglang.org).

**Why?** I have been using HOCON in production for nearly five years, in other
languages. It is the format I reach for when one service runs in several
environments: a shared file is included once, each environment overrides only
the keys that differ, substitutions pull one value into another, and the merge
rules decide the rest — no templating layer on top.

What this library adds is the other half: the schema stays in the language you
already work in. You describe the config as an ordinary Zig struct, HOCON is
only what sits on disk, and the parser fills the struct in — the same shape as
`std.json`.


Requires Zig **0.16.0** or newer.

> **Status: early development.** Source text parses into a value graph,
> substitutions resolve against the finished document, and the result converts
> into a Zig struct of your own through `hocon.parseFromSlice`, shaped after
> `std.json`, or prints as JSON from the `hocon` command line tool. Not yet:
> includes (`include` parses, but nothing splices the file in, so a file that
> uses one is rejected). See [Features](#features) below for what
> currently works, and [Conformance](#conformance) for how far that gets.
> The latest release is [`v0.1.0`](https://github.com/lejmr/zig-hocon/tree/v0.1.0).

## Installation

Add the package to your `build.zig.zon`:

```sh
zig fetch --save https://github.com/lejmr/zig-hocon/archive/refs/tags/v0.1.0.tar.gz
```

That records the dependency in `build.zig.zon`, pinned by its content hash. For
the tip of `main` fetch `git+https://github.com/lejmr/zig-hocon`, for a particular
commit append it: `git+https://github.com/lejmr/zig-hocon#<commit>`.

Then hand the module to your executable in `build.zig`:

```zig
const hocon = b.dependency("hocon", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("hocon", hocon.module("hocon"));
```

and `@import("hocon")` works in your code.

## Usage

Describe the config as a struct and parse into it, the way `std.json` does:

```zig
const hocon = @import("hocon");

const Server = struct {
    host: []const u8,
    port: u16 = 8080,
    tls: ?struct { cert: []const u8 } = null,
    level: enum { debug, info } = .info,
};

const parsed = try hocon.parseFromSlice(Server, gpa,
    \\host = example.org
    \\level = debug
, .{});
defer parsed.deinit();

const server = parsed.value; // server.port == 8080, server.tls == null
```

`parsed` owns an arena with everything the result points to, and `deinit` gives
it back in one go — any allocator will do. Strings in the result are copies, so
the source can be freed as soon as the call returns. When you already have an
arena of your own, `parseFromSliceLeaky(Server, arena, source, .{})` returns the
plain struct and allocates straight into it.

Reading the file is yours for now. Zig 0.16 hands back the 0-terminated buffer
the parser takes when asked for a `0` sentinel, so the whole thing is:

```zig
const source = try std.Io.Dir.cwd().readFileAllocOptions(
    io, "server.conf", gpa, .limited(1 << 20), .of(u8), 0,
);
defer gpa.free(source);

const parsed = try hocon.parseFromSlice(Server, gpa, source, .{});
defer parsed.deinit();

const server = parsed.value;
```

When a parse fails, the error is a plain Zig error. To learn where, pass
`Diagnostics` in the options. It keeps the error and the place: the file it is
in — the one you gave or one it includes — with the line and column there:

```zig
var diag: hocon.Diagnostics = .{};
defer diag.deinit(gpa);
const parsed = hocon.parseFromFile(Server, gpa, io, "server.conf", .{ .diagnostics = &diag }) catch |err| {
    try diag.render(stderr);
    return err;
};
```

which prints what the zig compiler would:

```
conf.d/limits.conf:2:16: error: Unresolved
burst = ${max} ${unknown}
               ^
```

`diag.location` holds the same `path`, `line` and `column` (1-based, the column
counted in code points) and the line itself, for a message of your own. The
path and the line are copies, since a failed parse frees the files it read;
`deinit` with the allocator the parse was given frees them. A slice has no file
name, so after `parseFromSlice` the path is empty and the render starts at
`3:11:`. Errors with no place in a file — out of memory, a file that cannot be
read — render as `error: FileNotFound`.

An error in turning the document into your type also says which value it is
about, `diag.key_path`, and what the type wanted there, `diag.expected`; text
that is no duration, period or size (below) too. It points at the value where
it is written, or at the `${` it came from. An empty list or object has nothing
to point at, a value from an included `.json` file no place (std.json copies its
text), and a missing field no value, so for those it is the first line alone:

```
deploy/prod/app.conf:7:10: error: InvalidCharacter at db.pool: expected u8
  pool = eight
         ^
error: MissingField at db.host
```

It is the first error the parser runs into, and the parser reads the whole
file before it builds any value: a stray `}` on line 9 is reported before a
bad escape in a value on line 2. Keys are checked as they are read, so a bad
escape in a key on line 2 comes first.

For the tree itself rather than a struct, ask for `hocon.Value`, the way
`std.json.Value` works; `std.json.Stringify` prints it:

```zig
const parsed = try hocon.parseFromSlice(hocon.Value, gpa, source, .{});
defer parsed.deinit();
try std.json.Stringify.value(parsed.value, .{}, writer);
```

The other way round, `hocon.stringify` writes a value as HOCON, shaped after
`std.json.Stringify` — a program can write its defaults once and let every
environment `include` them:

```zig
try hocon.stringify(Server{ .host = "example.org" }, .{}, writer);
```

```
host = example.org
port = 8080
level = info
```

Nested blocks, two spaces, keys in field order, quotes only where a string
would not read back the same; a `null` optional is left out unless its default
is something else. `stringifyAlloc(gpa, value, .{})` returns the text instead.
A `hocon.Value` is written the way it was loaded, so one that was never
resolved keeps its `${…}`, concatenations and repeated keys.

A path given as text — a name to look up, a command-line argument — becomes
its keys through `hocon.parsePath`, by the same rules as a key in a file and the
inside of a `${…}`: a quoted dot is a character, `""` is an empty key, and an
unquoted empty element is an error at its dot:

```zig
const keys = try hocon.parsePath(arena, "server.\"tls.cert\".path", &diag);
// keys[0].value == "server", keys[1].value == "tls.cert", keys[2].value == "path"
```

The keys point into memory the call allocates, so pass an arena; `diag` may be
`null`, and is filled in like a parse of a slice, the path being the source.

Times and sizes have types of their own, read from text in the units format
of the spec — any unit it lists, a bare number in the default one:

```zig
const Cache = struct {
    ttl: hocon.Duration = .of(30, .s),        // "30s", "1500 ms", "2 hours", 1500 (= ms)
    retention: hocon.Period = .of(3, .mo),    // "3 mo", "2 weeks", "1y", 14 (= days)
    size: hocon.Size = .of(512, .MiB),        // "512M", "1 GiB", "10kB", 4096 (= B)
};

cache.ttl.as(.weeks)         // f64: kept in nanoseconds, read in any unit
cache.ttl.whole(.ms)         // i64, cut toward zero
cache.ttl.toIo()             // std.Io.Duration
cache.retention.months       // years, months, days, as java.time.Period
cache.retention.toDuration() // error.NotExact while it has months or years
cache.size.whole(.B)         // u64
```

A `Period` is calendar time: a month has no fixed length, so it does not turn
into a `Duration`. `stringify` writes each one in the largest unit that says it
exactly (`90s`, `3mo`, `512MiB`), which reads back the same. Without a struct,
`hocon.Duration.fromValue(value)` reads one `hocon.Value`.

### Command line

`zig build` also installs `hocon`, which prints a file resolved, as HOCON —
includes, substitutions and `+=` worked out into one file — or with `--json` as
compact JSON:

```sh
$ zig build
$ zig-out/bin/hocon server.conf
server {
  host = example.org
  port = 8080
  tags = [a, "b c"]
  tls = on
}
$ zig-out/bin/hocon --json server.conf
{"server":{"host":"example.org","port":8080,"tags":["a","b c"],"tls":"on"}}
```

In JSON, unquoted `true`, `false`, `null` and numbers keep their JSON type, a number is
printed as written (`1e5` stays `1e5`), and anything quoted is a string. A file
that does not parse, or holds a substitution that does not resolve, exits 1 and
points at the spot on stderr, as above. `zig build run -- server.conf` does the same without the install step.

A path that is not in the file reads the variable of the same name from the
process environment; `--env=none` reads none. `--env=keep` compacts a config
before it ships: includes, overrides and `+=` are worked out, and what waits
for the environment stays as written, to be resolved on the server:

```sh
$ zig-out/bin/hocon --env=keep server.conf
host = localhost
host = ${?WOMBAT_HOST}
port = 8080
port = ${?WOMBAT_PORT}
```

With a command in front, `hocon` does more than print the file. The commands
read files the same way, and take `--env` like the above, `--json` where they
print something, anywhere among their arguments (`hocon` alone lists them all).
A file named like a command is `./get`.

`hocon get <path> <file.conf>` prints one value. Text comes out as it is, so a
shell script can take it; an object or a list comes out as HOCON, or with
`--json` as JSON (`--hocon` writes text as HOCON too, quoted where it needs
it). The path is a HOCON path, quotes and all, and one that is not there exits 1:

```sh
$ hocon get server.host server.conf
example.org
$ PORT=$(hocon get server.port server.conf)
$ hocon get server --json server.conf
{"host":"example.org","port":8080,"tags":["a","b c"],"tls":"on"}
$ hocon get server.nope server.conf
error: no value at 'server.nope'
```

`hocon check <file.conf>...` reads each file: syntax, includes, substitutions,
cycles. A good one is `ok` on stdout, a bad one gets its error and caret on
stderr, and at the end it says how many failed, with exit 1. With
`--schema <file.zig>:<Type>` the files are read into your own struct, so a
value of the wrong type fails as it would in your program:

```sh
$ hocon check --schema src/config.zig:Config deploy/*/app.conf
deploy/prod/app.conf:7:10: error: InvalidCharacter at db.pool: expected u8
  pool = eight
         ^
deploy/staging/app.conf: ok
1 of 2 failed
```

A struct exists only when Zig compiles, so `hocon` writes a small program with
your type in it and runs it with `zig run`, from the `PATH`. That needs a zig
of the version the library is written for (0.16), and `src/config.zig` has to
stand on its own: it imports `std` and `hocon`, nothing else. The library comes
with the binary, which unpacks its own source into `~/.cache/zig-hocon/` (or
`$XDG_CACHE_HOME`) the first time; zig caches the build, so only the first run
of a type, or of a changed one, waits for the compiler.

`hocon diff <a.conf> <b.conf>` compares two files as they resolve, path by
path, not line by line. Values are printed as JSON, so `8080` and `"8080"` look
as different as they are; a list is compared whole, an object key by key in any
order. Exit 0 when there is no difference, 1 when there is, 2 when a file
cannot be read or compared, as for diff(1); `--json` for a program to read:

```sh
$ hocon diff defaults.conf prod.conf
~ port: 8080 → 443
~ plugins: ["auth"] → ["auth","metrics"]
+ db.host: "db.example.org"
- feature.beta
$ hocon --env=keep prod.conf > deploy.conf && hocon diff prod.conf deploy.conf; echo $?
0
```

#### From `build.zig`

There is no build API: a build runs the binary from the dependency, over
whatever files it finds. Here `zig build check-config` reads every
`deploy/**/*.conf` into `Config`, and `zig build compact` writes the production
config into one file, its variables left for the server:

```zig
const hocon = b.dependency("hocon", .{ .target = target, .optimize = optimize });

const check = b.addRunArtifact(hocon.artifact("hocon"));
check.addArgs(&.{ "check", "--schema", b.fmt("{s}:Config", .{b.pathFromRoot("src/config.zig")}) });
check.addFileInput(b.path("src/config.zig"));
var deploy = try b.build_root.handle.openDir(b.graph.io, "deploy", .{ .iterate = true });
defer deploy.close(b.graph.io);
var walker = try deploy.walk(b.allocator);
defer walker.deinit();
while (try walker.next(b.graph.io)) |entry| {
    if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".conf"))
        check.addFileArg(b.path(b.fmt("deploy/{s}", .{entry.path})));
}
b.step("check-config", "Check deploy/**/*.conf against Config").dependOn(&check.step);

const compact = b.addRunArtifact(hocon.artifact("hocon"));
compact.addArgs(&.{ "--hocon", "--env=keep" });
compact.addFileArg(b.path("deploy/prod/app.conf"));
const prod = compact.captureStdOut(.{ .basename = "prod.conf" });
b.step("compact", "Compact deploy/prod/app.conf").dependOn(&b.addInstallFile(prod, "prod.conf").step);
```

`build` returns `!void` for the directory walk. A failed check fails the step,
with the errors above in the build's output; leave the step out of the default
one, or make it a dependency of `install`, as suits the project.

## Features

Tracks coverage of the [HOCON spec](https://github.com/lightbend/config/blob/main/HOCON.md),
following its own section names so the two can be read side by side. Checked
items are implemented and tested; unchecked items are planned.

### Syntax

Everything under [§Syntax](https://github.com/lightbend/config/blob/main/HOCON.md#syntax),
grouped in the order it is meant to be built rather than the spec's, and blank
lines separate the stages. See **Order of work** below for why they fall this
way.

- [x] [Unchanged from JSON](https://github.com/lightbend/config/blob/main/HOCON.md#unchanged-from-json)
      — a JSON document parses as HOCON
- [x] [Comments](https://github.com/lightbend/config/blob/main/HOCON.md#comments) (`#` and `//`)
- [x] [Omit root braces](https://github.com/lightbend/config/blob/main/HOCON.md#omit-root-braces)
      — both `a = b` and `{ a = b }` are a valid root
- [x] [Key-value separator](https://github.com/lightbend/config/blob/main/HOCON.md#key-value-separator)
      — `=` and `:` are interchangeable, and may be omitted before `{`
- [x] [Commas](https://github.com/lightbend/config/blob/main/HOCON.md#commas)
      — interchangeable with newlines, runs collapse, a trailing one is allowed
- [x] [Whitespace](https://github.com/lightbend/config/blob/main/HOCON.md#whitespace)
      — kept verbatim inside a value, trimmed at its ends
- [x] [Unquoted strings](https://github.com/lightbend/config/blob/main/HOCON.md#unquoted-strings)
      — including the reserved characters that end one

Not spec sections of their own, but needed to get there, and already done:

- [x] Quoted and unquoted values stay distinguishable in the tree, which type
      inference needs to tell `a = "1"` from `a = 1`
- [x] A value with nothing in it (`a =`) is a parse error rather than a crash
- [x] Nesting deeper than 500 (blocks, lists, dotted keys, also in an included
      `.json` or `.properties`), or a chain of 500 substitutions or layers of one
      key, is `error.TooDeep` rather than a stack overflow

- [x] [Multi-line strings](https://github.com/lightbend/config/blob/main/HOCON.md#multi-line-strings)
      — a text part like any other, on the key side and as an include path too;
      the `"""` stay in the tree because escapes are literal inside them, which
      is what tells `"""a\nb"""` from `"a\nb"`
- [x] [Includes](https://github.com/lightbend/config/blob/main/HOCON.md#includes) (file, url, classpath, required)
      — files, `file()`, `required()` and http(s) URLs, as `.conf`, strict `.json`
      or `.properties`; a basename loads all three. Not supported: `classpath()`
      and URL schemes other than http, https and file (an error). Merge stacks
      across an include (`a = {…}` then `a = ${q}` in the included file) wait
      for #7. Read through
      `parseFromFile`; `parseFromSlice` has no files and refuses an include. An
      http(s) fetch that takes longer than `ParseOptions.http_timeout` (30 s, each
      fetch on its own) is `error.IncludeTimeout`, also when it is not `required`.

- [x] [Path expressions](https://github.com/lightbend/config/blob/main/HOCON.md#path-expressions)
      — a substitution path is split into elements when its reference is built,
      so resolution never parses. The split walks the parts the parser left
      rather than the text, which is what keeps a quoted dot out of it: a dot
      outside quotes is the only thing that ends an element, and the end of a
      part means nothing at all. So `${x."y.z"}` is two elements and finds the
      key `x { "y.z" = 1 }`, `${a"b"}` is the single element `ab`, and
      `${a."".b}` keeps its empty middle, which java accepts. Keys, `${…}` and
      `hocon.parsePath` share one splitter (`Key.split`), so `.a`, `a.` and
      `a..b` are `MalformedKey` (java's `BadPath`) at the same dot in all three
- [x] [Paths as keys](https://github.com/lightbend/config/blob/main/HOCON.md#paths-as-keys)
      — an unquoted dotted key nests: `a.b.c = 1` builds the same tree as
      `a { b { c = 1 } }`, `a.b {c = 1}` joins the two ways of writing it, and a
      number splits like any other unquoted string, so `1.5 = x` is `1 { 5 = x }`.
      A malformed path (`.a`, `a.`, `a..b`) is `MalformedKey`, java's `BadPath`.
      A key written in parts splits the same way, so `"a"."b" = 1` nests and
      `a."b.c" = 1` keeps `b.c` as one key

- [x] [Duplicate keys and object merging](https://github.com/lightbend/config/blob/main/HOCON.md#duplicate-keys-and-object-merging)
      — a key written twice is one member, whether the two spellings meet inside
      one block (`{b=1, b=2}`) or in a concatenation (`{b=1} {b=2}`), and the
      surviving member keeps the position of the first. A key held by both sides
      merges again only if both hold an object; anything else lets the
      right-hand value win outright, so `{b=[1]} {b=[2]}` is `[2]` where the
      `[1] [2]` of a concatenation would be `[1,2]`. That pair is the whole
      difference between merging and concatenating
- [x] [Value concatenation](https://github.com/lightbend/config/blob/main/HOCON.md#value-concatenation)
      — the parser collects the parts of `a = x "y"`, `a = [1] [2]` and
      `a = {x=1} {y=2}` with the whitespace between them, and the value graph
      then joins them: lists concatenate flatly, objects merge, text parts join
      and stop being numbers. Mixing kinds is the `WrongType` java reports, and
      it is reported while loading rather than later. The whitespace between two
      parts goes whichever way its neighbours do — a separator beside a list or
      an object, a character beside text — and a *quoted* space is a value, so
      `[1] " " [2]` is an error where `[1]   [2]` is `[1,2]`. A substitution is
      the one part that cannot be joined into, so the parts around it are kept
      in order for resolution to finish
- [x] [Substitutions](https://github.com/lightbend/config/blob/main/HOCON.md#substitutions) (`${a.b.c}`, `${?a.b.c}`)
      — `${…}` and `${?…}` become nodes of their own wherever a value may
      stand, and everything java rejects at parse time is rejected here too
      (`${}`, an unclosed `${a`, a newline or a nested `${` inside the path, `?`
      anywhere but directly after `${`, and a substitution where a key or an
      include target belongs). In the value graph a substitution becomes a
      reference of its own and everything holding one stays pending, since its
      type is unknown until it resolves — which is why `"1" ${x} [2]` loads and
      only fails once `x` turns out to be a number, while `"1" [2] ${x}` fails
      immediately. Resolution then runs once, over the finished document, so
      `x = 1`, `a = ${x}`, `x = 2` gives `a = 2`. A path steps through objects
      and through other references, each target is resolved once and stored
      back, and the parts of a pending value join exactly the way loading joins
      them. `${?x}` with nothing behind it removes the member or the list
      element; inside a concatenation it is empty, so `${?nope}42` is the
      string `"42"`, as the spec says and where both oracles give the number
      `42`. A key written again over a reference keeps both on a merge stack,
      resolved from the top: a reference to the key's own previous value sees
      the layers below it (`path = ${path} ":/opt"`, also through a path,
      `${a.b}`), with nothing below it is undefined rather than a cycle, an
      undefined `${?x}` on top leaves what was below, and `null` stops a merge
      only at its own key. A value hidden by one it cannot merge with is never
      evaluated. A reference that needs itself any other way is
      `SubstitutionCycle`.

- [x] [Conversion of numerically-indexed objects to arrays](https://github.com/lightbend/config/blob/main/HOCON.md#conversion-of-numerically-indexed-objects-to-arrays)
      — next to a list in a concatenation, and read into a slice or an array, an
      object with numeric keys is the list of its values in key order, gaps
      closed: `[] { "2" : b, "0" : a }` is `[a, b]`, and `list.0 = a` in a
      properties file makes one. Other keys are left out; with none left it
      stays a type error. Keys read as java reads them (`01`, `+1` count).
- [x] [The `+=` field separator](https://github.com/lightbend/config/blob/main/HOCON.md#the--field-separator)
      — `a += b` is `a = ${?a} [b]` with the field's whole path in the ref, so
      it starts a list or appends to the one below it, also under a dotted key,
      inside an object, and from a file that was included. `+` apart from `=`
      is an error

<details>
<summary><b>Order of work</b> — why the stages above fall this way</summary>

The guiding idea is to build one complete tree first and only then walk it. That
is what puts includes so early: until they are spliced in, there is no complete
tree to walk, because an include contributes members the merge would otherwise
never see.

Two constraints from the spec fix the rest of the order. An include has to be
resolved before anything reads the values it contributes, and substitutions
resolve against the *finished* object graph. Getting the second one wrong is a
known pyhocon bug and one of the reasons this project exists.

**Includes** next, as a tree operation: parse the referenced file and splice its
root members in. Nothing here needs evaluation, which is why it can come this
early, and it has to precede substitutions regardless.

**Path expressions and paths as keys** before merging, not after. Merging has to
know that `a.b = 1` and `a { b = 2 }` describe the same field, and a substitution
written as `${a.b}` looks it up the same way — so splitting a key into segments is
part of building the graph rather than something bolted on later.

**Duplicate keys, merging and value concatenation** turned out to belong to
building the value graph rather than to the walk over it. Java decides them while
parsing too — `a = {x=1} {y=2}` prints merged without anything being resolved —
and doing the same here buys an invariant worth having: once loading is done,
every value that holds no substitution is finished. Resolution then never has to
know what a quote or a gap meant, only how to put a value where a reference was
and re-run the same two functions loading used.

**Substitutions** are what is left for the walk, and the reason a value holding
one stays pending: its type is unknown until the graph is finished, so the type
check that rejects `1 [2]` cannot run across it. `+=` then costs almost nothing,
since the spec defines `a += b` as sugar for `a = ${?a} [b]`.

Somewhere around here the library becomes useful end to end: with merging done and
**automatic type conversions** in place, a JSON rendering works — and type
conversion is on the critical path rather than a convenience, since rendering has
to decide whether `a = 1` is the number `1` or the string `"1"`.

**Conversion of numerically-indexed objects to arrays** last of the syntax items:
a small rule with few users.

</details>

### API recommendations

[§API Recommendations](https://github.com/lightbend/config/blob/main/HOCON.md#api-recommendations)
is explicitly advisory — a HOCON implementation is conforming without it — but
these are what makes the format pleasant, so they are on the roadmap.

- [x] [Automatic type conversions](https://github.com/lightbend/config/blob/main/HOCON.md#automatic-type-conversions)
      — into a Zig type rather than through typed getters: integers, floats,
      `bool` (`true`/`yes`/`on`, `false`/`no`/`off`, lowercase only), strings,
      slices, fixed arrays, structs, tagged unions (`{ tag = … }`), optionals,
      enums and field defaults. A number reads as a
      string exactly as written (`1.50` stays `"1.50"`), unquoted `null` fits
      only an optional, and objects and arrays never become strings. One
      deliberate difference from typesafe/config: `1.5` into an integer is an
      error rather than a silent `1`. An object with numeric keys reads as a
      list (see above).
- [x] [Duration format](https://github.com/lightbend/config/blob/main/HOCON.md#duration-format) (`10s`, `5m`, ...)
      — `hocon.Duration`, nanoseconds in an i96 like `std.Io.Duration`. A
      fraction is exact, no floats (`0.3 s` is 300000000ns), where
      typesafe/config multiplies a double and can round (`9.999…9 s`). Where
      typesafe/config saturates at 292 years, an i96 holds the value, and past
      that it is `error.Overflow`. The number is JSON's: `.5 s` and `01 s`,
      which typesafe/config takes, are errors.
- [x] [Period format](https://github.com/lightbend/config/blob/main/HOCON.md#period-format) (`3d`, `2 weeks`, ...)
      — `hocon.Period`, `{ years, months, days }` like `java.time.Period`;
      weeks are days, the number a whole one.
- [x] [Size in bytes format](https://github.com/lightbend/config/blob/main/HOCON.md#size-in-bytes-format) (`512K`, `1G`, ...)
      — `hocon.Size`, bytes in a u64, so up to 16 EiB where typesafe/config's
      long stops at 8. Zetta and yotta are there, for a fraction of one.
- [ ] [Config object merging and file merging](https://github.com/lightbend/config/blob/main/HOCON.md#config-object-merging-and-file-merging) (`with_fallback`-style)
- [x] [Substitution fallback to environment variables](https://github.com/lightbend/config/blob/main/HOCON.md#substitution-fallback-to-environment-variables)
      — a path that is not in the document at all reads the variable of the
      same name (`${a.b}` reads `a.b`), always a string; `null` in the file
      blocks it, and a self-reference (`+=` too) never reads it. An optional
      that found nothing makes no field, so a path to it reads the variable.
      `${X[]}` collects `X_0`, `X_1`, … into a list. The variables come from
      `ParseOptions.env` (`.{ .map = init.environ_map }`): by default there are
      none, the library never reads the process. The CLI passes its own.
      `.keep` resolves everything else and leaves what waits for the
      environment in the tree; `hocon.stringify` writes it out as HOCON, a
      default under a variable as the key written twice, to be resolved
      where it runs. JSON cannot hold it.

Deliberately out of scope: Java properties mapping, conventional JVM config file
names, and override by system properties — all of them describe JVM conventions
rather than the format.

### Implementation

- [x] Tokenizer — objects, arrays, unquoted, quoted and triple-quoted strings,
      comments, the reserved characters that terminate an unquoted string, and
      the substitution openers `${` and `${?`. Numbers, booleans and `null` are
      tokenized as plain strings; giving them types belongs to evaluation. What
      is *inside* `${…}` gets no special lexing — it is an ordinary token stream
      closed by `}`. A token's `loc` covers the token, quotes included, rather
      than its content: the tree keeps the raw text, so anything else would make
      every reader add the quotes back — one of them, or three. Known gaps: an
      escaped backslash right before a closing quote (`\\"`), and a leading `+`
      on a number.
- [x] Parser — source text to a syntax tree, covering the checked syntax items
      above. Nested objects and arrays to any depth. The tree keeps whatever
      distinguishes two sources that mean different things — quotes, the
      whitespace between two parts of a value, duplicate keys — and leaves what
      it means to evaluation.
- [x] Memory — one arena owns the whole document, and everything the parser and
      the value graph produce is allocated from it or borrowed from the source
      text. Nothing inside has a `deinit` of its own: freeing is dropping the
      arena. `Parsed(T)` is that arena packaged with the result, so its single
      `deinit` is the only one a caller sees; the arena lives behind a pointer,
      which keeps any copy of `Parsed` freeing the same memory. The input text
      must outlive the value graph, since its leaf values are slices into it —
      a converted struct does not have that tie, its strings are copied. The
      `Leaky` variants skip the packaging and expect an arena from the caller:
      an individual string is not freeable on its own, so any other allocator
      leaks by construction. A failed parse, out of memory at any allocation
      included, gives everything back.
- [x] Value graph — syntax tree to values. A key is a type rather than a
      string, because three places produce one and all three have to agree that
      `a`, `"a"` and `"""a"""` are the same key; unquoting is shared with
      values, where the delimiter is kept as a flag instead, since `a = "1"` and
      `a = 1` differ only by it. Concatenation, object merging and path
      splitting happen here (see the syntax items above), which leaves a value
      either finished or explicitly pending on a substitution. The rule the
      layer is built on: anything decidable while the context is still around
      gets decided now, because nothing downstream can reconstruct it — which
      is why a gap beside a list is dropped and a gap between two references is
      not.
- [x] Conversion — value graph to a caller's type, one `switch` on
      `@typeInfo(T)` with a branch per kind of type, recursing through struct
      fields, slice elements and optionals. Values stay text until a type asks
      for them, so `yes` is a boolean only where a `bool` is wanted. A key
      missing from the file takes the field's default, then `null` for an
      optional, and only then is an error. It runs on the resolved document, so
      nothing pending ever reaches it.
- [x] Evaluation, substitutions — one depth-first pass from the root over the
      finished graph. It carries the list of places being resolved right now,
      which is what turns `a = ${b}`, `b = ${a}` into an error instead of a
      loop, and an index of each object's members, built on the first lookup
      into it.
- [x] Evaluation, includes — the referenced file is parsed and spliced in
      where the `include` stands, before substitutions resolve.
- [x] Public API, first cut — `hocon.parseFromSlice` returning `Parsed(T)` and
      its `parseFromSliceLeaky` twin, named and shaped after `std.json`, with
      `hocon.Value` as a target for the tree itself, and `parseFromFile` /
      `parseFromFileLeaky`, which read includes through an `std.Io` and take a
      `ParseOptions` (`http_timeout`, 30 s by default).
- [x] JSON rendering — `Value.jsonStringify`, which `std.json.Stringify` finds
      on its own, so there is no serializer here to maintain. A scalar is text
      until this point; quotes decide string, and otherwise JSON's own number
      grammar decides number, all of the text or nothing (`.5`, `1.` and `1 2`
      stay strings). Resolution runs inside the parse, so a substitution that
      does not resolve fails there rather than in the printer, since Stringify
      has no way to report an error of its own.
      This is the bridge the project is ultimately for.
- [x] HOCON rendering — `hocon.stringify`, after `std.json.Stringify`: any
      Zig value a config is made of, or a `Value`, resolved or not. A string is
      bare only when it is a plain ASCII word that reads back as the same
      string, otherwise a JSON string, always on one line (`\n`, never `"""`),
      and bytes that are not UTF-8 are a list of numbers, as std.json has them;
      a float is the shortest digits that read back the same, with an exponent
      outside 1e-6…1e21, and `nan`/`inf` as strings. A `+=` still waiting is
      written as `+=` again. A `${…}` from a file included inside a block
      also falls back to the path without that block; a field that still
      needs it is the key written twice, `a = ${x}` under `a = ${?block.x}`,
      and a self-reference, `+=` too, is its earlier layers over `a = ${x}`.
      Known losses, each needing an unusual input: inside a list or a
      concatenation other than `+=` one `${…}` cannot say that, and only the
      path with the block is written; an object found at `block.x` merges
      onto `${x}`, which then has to resolve too; and written out, the
      fallback reads variables the original never does, `block.x` with the
      dot, and `x` once a self-reference's root `x` vanishes.
- [x] Command line — `hocon <file.conf>` prints the resolved file as HOCON,
      `hocon --json <file.conf>` as JSON; exits 1 on rejection, and substitutions
      fall back to its environment (`--env=none` to not, `--env=keep` to leave
      them for later). With `--json` it is the same contract as a
      conformance adapter, so it is what the suite
      measures (`conformance/adapters/zig-hocon.sh`). `hocon get` prints one
      value, `hocon check` reads files and with `--schema` into a struct,
      `hocon diff` compares two by path.
- [ ] Public API, the rest — the other `ParseOptions` fields (`ignore_unknown_fields`;
      unknown keys are ignored for now), and `parseFromValue`.

## Reference oracles

Disputed behaviour is settled by running it, not by reading the spec from
memory. `tools/oracle/` holds two reference implementations behind one interface:

```sh
printf 'a = grumpy wombat\n' | tools/oracle/hocon-java   # Lightbend typesafe/config
printf 'a = grumpy wombat\n' | tools/oracle/hocon-py     # pyhocon
```

`hocon-java` is the authority; `hocon-py` shows what the implementation this
project replaces would do. See [tools/oracle/README.md](tools/oracle/README.md)
for the input format and the list of confirmed divergences between the two.

## Conformance

To know what "compatible" means, `conformance/` turns the specification into
data: every normative sentence of `HOCON.md` becomes a config file and the value
it must produce. Expected values are seeded from typesafe/config, then checked
by hand against the sentence they stand for; where the two disagree the spec
wins and the row says so. Where it stands today:

<!-- conformance:start -->
<!-- generated by conformance/maintaining/report.py — do not edit by hand -->

| implementation | against the spec | against typesafe/config 1.4.9 | against typesafe/config main |
|---|---|---|---|
| Java <sub>typesafe/config 1.4.9</sub> | 90% (399/445) | 99% (442/445) | 96% (428/445) |
| Java main <sub>typesafe/config main@275f872, unreleased</sub> | 93% (412/445) | 96% (428/445) | 99% (442/445) |
| pyhocon <sub>pyhocon 0.3.63</sub> | 70% (312/445) | 66% (295/445) | 68% (304/445) |
| zig-hocon <sub>zig-hocon code@2012bd0</sub> | 99% (442/445) | 90% (399/445) | 93% (412/445) |

<!-- conformance:end -->

As you can see there is still a lot of work ahead, but I believe it is worth every second.

A set of conformance tests on top of that keeps the implementation clean and
fully working — every case, and what each implementation printed, is in
**[the conformance report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html)**.

The suite is not tied to Zig. Any HOCON parser can be scored on it through a
ten-line adapter — [conformance/README.md](conformance/README.md) shows how to
add yours.

## Contributing

This project is developed in the open. If you need a HOCON feature that isn't
implemented yet, please open a PR — feature requests as PRs (even a failing
test showing what you need) are the fastest way to get something prioritized.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the PR workflow (draft until CI is
green).

## License

BSD 3-Clause — see [LICENSE](LICENSE).
