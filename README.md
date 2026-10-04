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

> **Status: early development.** Source text parses into a value graph, and the
> graph converts into a Zig struct of your own through `hocon.parseFromSlice`,
> shaped after `std.json`, or prints as JSON from the `hocon` command line tool.
> Substitutions are not resolved yet — see [Features](#features) below for what
> currently works, and [Conformance](#conformance) for how far that gets.
> No tagged release yet: install straight from the repository, as below.

## Installation

Add the package to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/lejmr/zig-hocon
```

That records the dependency in `build.zig.zon`, pinned by its content hash. For
a particular commit, append it: `git+https://github.com/lejmr/zig-hocon#<commit>`.

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
);
defer parsed.deinit();

const server = parsed.value; // server.port == 8080, server.tls == null
```

`parsed` owns an arena with everything the result points to, and `deinit` gives
it back in one go — any allocator will do. Strings in the result are copies, so
the source can be freed as soon as the call returns. When you already have an
arena of your own, `parseFromSliceLeaky(Server, arena, source)` returns the
plain struct and allocates straight into it.

Reading the file is yours for now. Zig 0.16 hands back the 0-terminated buffer
the parser takes when asked for a `0` sentinel, so the whole thing is:

```zig
const source = try std.Io.Dir.cwd().readFileAllocOptions(
    io, "server.conf", gpa, .limited(1 << 20), .of(u8), 0,
);
defer gpa.free(source);

const parsed = try hocon.parseFromSlice(Server, gpa, source);
defer parsed.deinit();

const server = parsed.value;
```

For the tree itself rather than a struct, ask for `hocon.Value`, the way
`std.json.Value` works; `std.json.Stringify` prints it:

```zig
const parsed = try hocon.parseFromSlice(hocon.Value, gpa, source);
defer parsed.deinit();
try std.json.Stringify.value(parsed.value, .{}, writer);
```

### Command line

`zig build` also installs `hocon`, which prints a file as compact JSON:

```sh
$ zig build
$ zig-out/bin/hocon server.conf
{"server":{"host":"example.org","port":8080,"tags":["a","b c"],"tls":"on"}}
```

Unquoted `true`, `false`, `null` and numbers keep their JSON type, a number is
printed as written (`1e5` stays `1e5`), and anything quoted is a string. A file
that does not parse, or still holds a substitution, exits 1 with the reason on
stderr. `zig build run -- server.conf` does the same without the install step.

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

- [x] [Multi-line strings](https://github.com/lightbend/config/blob/main/HOCON.md#multi-line-strings)
      — a text part like any other, on the key side and as an include path too;
      the `"""` stay in the tree because escapes are literal inside them, which
      is what tells `"""a\nb"""` from `"a\nb"`
- [ ] [Includes](https://github.com/lightbend/config/blob/main/HOCON.md#includes) (file, url, classpath, required)

- [x] [Path expressions](https://github.com/lightbend/config/blob/main/HOCON.md#path-expressions)
      — a substitution path is split into elements when its reference is built,
      so resolution never parses. The split walks the parts the parser left
      rather than the text, which is what keeps a quoted dot out of it: a dot
      outside quotes is the only thing that ends an element, and the end of a
      part means nothing at all. So `${x."y.z"}` is two elements and finds the
      key `x { "y.z" = 1 }`, `${a"b"}` is the single element `ab`, and
      `${a."".b}` keeps its empty middle, which java accepts. Still to do:
      rejecting `.a`, `a.` and `a..b` as `BadPath`, and lending the same
      splitter to the key side
- [x] [Paths as keys](https://github.com/lightbend/config/blob/main/HOCON.md#paths-as-keys)
      — an unquoted dotted key nests: `a.b.c = 1` builds the same tree as
      `a { b { c = 1 } }`, `a.b {c = 1}` joins the two ways of writing it, and a
      number splits like any other unquoted string, so `1.5 = x` is `1 { 5 = x }`.
      A malformed path (`.a`, `a.`, `a..b`) is rejected, though as the parser's
      `UnexpectedToken` rather than the `BadPath` java names. Known gap: a key
      written in several parts is left alone, so `"a"."b" = 1` and `a."b.c" = 1`
      stay flat where java nests them. The splitter that path expressions use
      answers exactly this and only wants wiring up here

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
- [ ] [Substitutions](https://github.com/lightbend/config/blob/main/HOCON.md#substitutions) (`${a.b.c}`, `${?a.b.c}`)
      — parsed, not resolved: `${…}` and `${?…}` become nodes of their own
      wherever a value may stand, and everything java rejects at parse time is
      rejected here too (`${}`, an unclosed `${a`, a newline or a nested `${`
      inside the path, `?` anywhere but directly after `${`, and a substitution
      where a key or an include target belongs). In the value graph a
      substitution becomes a reference of its own and everything holding one
      stays pending, since its type is unknown until it resolves — which is why
      `"1" ${x} [2]` loads and only fails once `x` turns out to be a number,
      while `"1" [2] ${x}` fails immediately. The path is split on `.` there,
      but naively: a quoted dot (`${a."b.c"}`) still splits and waits for path
      expressions above

- [ ] [Conversion of numerically-indexed objects to arrays](https://github.com/lightbend/config/blob/main/HOCON.md#conversion-of-numerically-indexed-objects-to-arrays)
- [ ] [The `+=` field separator](https://github.com/lightbend/config/blob/main/HOCON.md#the--field-separator)
      — self-referential array append, which the spec defines as sugar for
      `a = ${?a} [b]`; `+` is rejected by the tokenizer today

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
      slices, structs, optionals, enums and field defaults. A number reads as a
      string exactly as written (`1.50` stays `"1.50"`), unquoted `null` fits
      only an optional, and objects and arrays never become strings. One
      deliberate difference from typesafe/config: `1.5` into an integer is an
      error rather than a silent `1`. Not yet: numerically-indexed objects as
      lists.
- [ ] [Duration format](https://github.com/lightbend/config/blob/main/HOCON.md#duration-format) (`10s`, `5m`, ...)
- [ ] [Period format](https://github.com/lightbend/config/blob/main/HOCON.md#period-format) (`3d`, `2 weeks`, ...)
- [ ] [Size in bytes format](https://github.com/lightbend/config/blob/main/HOCON.md#size-in-bytes-format) (`512K`, `1G`, ...)
- [ ] [Config object merging and file merging](https://github.com/lightbend/config/blob/main/HOCON.md#config-object-merging-and-file-merging) (`with_fallback`-style)
- [ ] [Substitution fallback to environment variables](https://github.com/lightbend/config/blob/main/HOCON.md#substitution-fallback-to-environment-variables)

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
      optional, and only then is an error. A substitution still pending is an
      error rather than a guess, until evaluation exists.
- [ ] Evaluation — resolving substitutions against the finished graph and
      splicing includes.
- [x] Public API, first cut — `hocon.parseFromSlice` returning `Parsed(T)` and
      its `parseFromSliceLeaky` twin, named and shaped after `std.json`, with
      `hocon.Value` as a target for the tree itself.
- [x] JSON rendering — `Value.jsonStringify`, which `std.json.Stringify` finds
      on its own, so there is no serializer here to maintain. A scalar is text
      until this point; quotes decide string, and otherwise JSON's own number
      grammar decides number, all of the text or nothing (`.5`, `1.` and `1 2`
      stay strings). A tree with a substitution left in it is refused when it
      is parsed, since Stringify has no way to report an error of its own.
      This is the bridge the project is ultimately for.
- [x] Command line — `hocon <file.conf>` prints JSON, exits 1 on rejection;
      the same contract as a conformance adapter, so it is what the suite
      measures (`conformance/adapters/zig-hocon.sh`).
- [ ] Public API, the rest — `ParseOptions` (`ignore_unknown_fields`; unknown
      keys are ignored for now), `parseFromValue`, and `parseFromFile` taking an
      `std.Io` and a directory, which `include` will need anyway.

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
| zig-hocon <sub>zig-hocon code@2a79c7b</sub> | 56% (251/445) | 59% (261/445) | 61% (270/445) |

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
