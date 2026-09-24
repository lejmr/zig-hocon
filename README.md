<img src="docs/brand/zig-Hocon-badge-master-1650x500.png" width="600" alt="zig-Hocon">

zig-Hocon is a [HOCON](https://github.com/lightbend/config/blob/main/HOCON.md)
(Human-Optimized Config Object Notation) parser for [Zig](https://ziglang.org),
inspired by [pyhocon](https://github.com/chimpler/pyhocon).

Requires Zig **0.16.0** or newer.

> **Status: early development.** The tokenizer, the parser and the value graph
> are being built out incrementally — see [Features](#features) below for what
> currently works.
> This is not yet published to the Zig package registry.

## Usage

```zig
// TODO: usage example once the parser has a public API.
```

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

- [ ] [Automatic type conversions](https://github.com/lightbend/config/blob/main/HOCON.md#automatic-type-conversions)
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
      text. Nothing has a `deinit` of its own: freeing is dropping the arena.
      Two consequences worth knowing before writing a caller. The input text
      must outlive the parsed document, since leaf values are slices into it.
      And an individual string is not freeable on its own, so a non-arena
      allocator leaks by construction rather than by accident.
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
- [ ] Evaluation — resolving substitutions against the finished graph, splicing
      includes, and type conversions.
- [ ] Public API — parse from a string or a file, typed accessors, and a JSON
      rendering (the bridge this project is ultimately for).

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

Every row is one sentence of the specification, turned into a config file and an
expected value under `conformance/`. The suite is data, not code — see
`conformance/README.md` for the file format and how to check your own parser, and
`conformance/maintaining/PROCESS.md` for how the suite is built and what it is for.

Regenerate this table with `python3 conformance/maintaining/report.py`; it renders
the committed results in `conformance/reports/` and writes `conformance/report.html`
alongside. `--check` fails instead of writing.

**Java sits at 100% by construction.** Expected values are produced by
`tools/oracle/hocon-java`, so the reference implementation can only fail a row
that a human has since corrected against the spec text. Those rows are the point
of the exercise — they are marked `java: unsupported` or `java: diverges` in the
`rule` column, and they are where HOCON says more than `typesafe/config` does.

<!-- conformance:start -->

<!-- generated by conformance/maintaining/report.py — do not edit by hand -->

<details open>
<summary><b>Where HOCON and typesafe/config part ways</b> — 34 rows</summary>

| input | the spec requires | Java | pyhocon |
|---|---|---|---|
| `x = [1]\ny = [2]\na = ${x}​${y}\n` | rejects | `{"a":[1,2],"x":[1],"y":[2]}` | `rejected` |
| `x = [1]\na = ${?absent} ${x}\n` | `{"x": [1], "a": [1]}` | `rejected` | `{"x":[1],"a":[1]}` |
| `v = { x = 1 }\nr = null\nr = ${v}\na = { helper = 0 }\na = ${r}\n` | `{"v": {"x": 1}, "r": {"x": 1}, "a": {"helper": 0, "x": 1}}` | `{"a":{"x":1},"r":{"x":1},"v":{"x":1}}` | `{"v":{"x":1},"r":{"x":1},"a":{"helper":0,"x":1}}` |
| `v = { nested = { old = 2 }, nested = null, nested = { x = 1 } }\na = { nested = { helper = 0 } }\na = ${v}\n` | `{"v": {"nested": {"x": 1}}, "a": {"nested": {"helper": 0, "x": 1}}}` | `{"a":{"nested":{"x":1}},"v":{"nested":{"x":1}}}` | `{"v":{"nested":{"x":1}},"a":{"nested":{"helper":0,"x":1}}}` |
| `v = { nested = null, nested = ${payload}, sibling = ${payload} }\npayload = { x = 1 }\na = { nested = { helper = 0 } }\na = ${v}\no24bbd = ${a.nested}\n` | `{"v": {"nested": {"x": 1}, "sibling": {"x": 1}}, "payload": {"x": 1}, "a": {"nested": {"helper": 0, "x": 1}, "sibling": {"x": 1}}, "o24bbd": {"helper": 0, "x": 1}}` | `{"a":{"nested":{"x":1},"sibling":{"x":1}},"o24bbd":{"x":1},"payload":{"x":1},"v":{"nested":{"x":1},"sibling":{"x":1}}}` | `{"v":{"nested":{"x":1},"sibling":{"x":1}},"payload":{"x":1},"a":{"nested":{"helper":0,"x":1},"sibling":{"x":1}},"o24bbd"` |
| `v = null\nv = { x = ${pending} }\npending = 1\na = { helper = 0 }\na = ${v}\n` | `{"v": {"x": 1}, "pending": 1, "a": {"helper": 0, "x": 1}}` | `{"a":{"x":1},"pending":1,"v":{"x":1}}` | `{"v":{"x":1},"pending":1,"a":{"helper":0,"x":1}}` |
| `v = { nested = null, nested = ${pending} }\nv = ${pendingTop}\na = { nested = { helper = 0 } }\na = ${v}\npending = { x = 1 }\npendingTop = { y = 2 }\n` | `{"v": {"nested": {"x": 1}, "y": 2}, "a": {"nested": {"helper": 0, "x": 1}, "y": 2}, "pending": {"x": 1}, "pendingTop": {"y": 2}}` | `{"a":{"nested":{"x":1},"y":2},"pending":{"x":1},"pendingTop":{"y":2},"v":{"nested":{"x":1},"y":2}}` | `rejected` |
| `a = { n = null, n = { d = null, d = ${p} } }\np = { x = 1 }\no24bbd = ${a.n.d}\n` | `{"a": {"n": {"d": {"x": 1}}}, "p": {"x": 1}, "o24bbd": {"x": 1}}` | `rejected` | `{"a":{"n":{"d":{"x":1}}},"p":{"x":1},"o24bbd":{"x":1}}` |
| `009-undefined-optional-at-fixed-up-path-falls-back/ (directory)` | `{"common": {"x": {}, "a": 0}, "x": {"y": 0}}` | `rejected` | `{"common":{"x":{},"a":0},"x":{"y":0}}` |
| `011-optional-reference-falls-back-too/ (directory)` | `{"common": {"x": {}, "a": 0}, "x": {"y": 0}}` | `{"common":{"x":{}},"x":{"y":0}}` | `{"common":{"x":{},"a":0},"x":{"y":0}}` |
| `014-unrelated-key-does-not-change-the-result/ (directory)` | `{"common": {"x": {}, "a": 0}, "x": {"y": 0}, "zzz": {}}` | `rejected` | `{"common":{"x":{},"a":0},"x":{"y":0},"zzz":{}}` |
| `[1, 2, 3]\n` | `[1, 2, 3]` | `rejected` | `[1,2,3]` |
| `[ { a = 1 }, { b = 2 } ]\n` | `[{"a": 1}, {"b": 2}]` | `rejected` | `[{"a":1},{"b":2}]` |
| `[]\n` | `[]` | `rejected` | `[]` |
| `# a leading comment\n[1, 2]\n` | `[1, 2]` | `rejected` | `[1,2]` |
| `\n[1, 2]\n` | `[1, 2]` | `rejected` | `[1,2]` |
| `include.foo : 42\n` | rejects | `{"include":{"foo":42}}` | `{"include":{"foo":42}}` |
| `wrapper = [${does-not-exist}]\nreplacement = {}\nwrapper = ${replacement}\n` | `{"wrapper": {}, "replacement": {}}` | `rejected` | `{"wrapper":{},"replacement":{}}` |
| `wrapper = { a = ${does-not-exist} }\nreplacement = 42\nwrapper = ${replacement}\n` | `{"wrapper": 42, "replacement": 42}` | `rejected` | `rejected` |
| `wrapper = { a = ${does-not-exist} }\nreplacement = 42\nwrapper = ${replacement}suffix\n` | `{"wrapper": "42suffix", "replacement": 42}` | `rejected` | `rejected` |
| `w = [${does-not-exist}]\nr = { x = 1 }\nw = ${r}\nzzz = ${w.x}\n` | `{"w": {"x": 1}, "r": {"x": 1}, "zzz": 1}` | `rejected` | `{"w":{"x":1},"r":{"x":1},"zzz":1}` |
| `a = { b: 1 } x\n` | rejects | `{"a":{"b":1}}` | `rejected` |
| `a = [ 1, 2 ] x\n` | rejects | `{"a":[1,2]}` | `rejected` |
| `x = [1]suffix\n` | rejects | `{"x":[1]}` | `rejected` |
| `x = {a:1}suffix\n` | rejects | `{"x":{"a":1}}` | `rejected` |
| `x = [1]suffix[2]\n` | rejects | `{"x":[1,2]}` | `rejected` |
| `list = [0, 1] \| [2,3]\n` | rejects | `{"list":[0,1,2,3]}` | `rejected` |
| `a = 01\n` | rejects | `{"a":1}` | `{"a":1}` |
| `a = -.33\n` | rejects | `{"a":-0.33}` | `{"a":-0.33}` |
| `a = -.33e+1\n` | rejects | `{"a":-3.3}` | `{"a":-3.3}` |
| `a = 1.\n` | rejects | `{"a":1}` | `{"a":"1."}` |
| `a = -1.e3\n` | rejects | `{"a":-1000}` | `{"a":"-1.e3"}` |
| `a = -0033\n` | rejects | `{"a":-33}` | `{"a":-33}` |
| `a = -foo\n` | rejects | `{"a":"-foo"}` | `{"a":"-foo"}` |

Each column is what that implementation actually returns.

</details>

<details>
<summary><b>array-and-object-concatenation</b> — 17 cases · Java 17/17 · pyhocon 17/17</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-arrays-concatenate` | ✅ | ✅ | arrays can be concatenated with arrays when only non-newline whitespace separates them |
| `002-objects-concatenate` | ✅ | ✅ | objects can be concatenated with objects when only non-newline whitespace separates them |
| `003-mixing-array-and-object-is-error` | ✅ | ✅ | it is an error to concatenate an array with an object |
| `004-substitution-counts-as-array-for-concatenation` | ✅ | ✅ | for purposes of concatenation a substitution that resolves to an array also means an array, so ${x} [ 1, 2 ] with x an array concatenates into one array |
| `005-substitution-counts-as-object-for-concatenation` | ✅ | ✅ | for purposes of concatenation a substitution that resolves to an object also means an object, so ${x} { c : 1 } with x an object merges into one object |
| `006-newline-between-values-prevents-concatenation` | ✅ | ✅ | newlines between a substitution and an array prevent concatenation, so inside an array they stay two separate elements instead of one concatenated array |
| `007-object-concatenation-merges-and-second-overrides` | ✅ | ✅ | for objects, concatenation means merging, and the second object overrides the first on overlapping keys |
| `008-array-cannot-be-field-key` | ✅ | ✅ | arrays cannot be field keys; nested inside an object so the rejection comes from the key position, not from the document root |
| `009-object-cannot-be-field-key` | ✅ | ✅ | objects cannot be field keys; nested inside an object so the rejection comes from the key position, not from the document root |
| `010-worked-example-object-inheritance` | ✅ | ✅ | the spec's worked example: object concatenation with a substitution is a common way to express inheritance |
| `011-worked-example-array-path-append` | ✅ | ✅ | the spec's worked example: array concatenation with a substitution is a common way to add to paths |
| `012-worked-example-self-referential-array-concat` | ✅ | ✅ | the spec's worked example: a later array definition can concatenate a substitution referring to its own earlier value with a new array |
| `013-newlines-within-value-still-allow-concatenation` | ✅ | ✅ | newlines may occur within an array without preventing it from concatenating with a second array on the same line as its closing bracket |
| `014-substitution-object-with-literal-array-is-error` | ✅ | ✅ | a substitution that resolves to an object means an object for concatenation, and concatenating an object with an array is an error |
| `015-substitution-array-with-literal-object-is-error` | ✅ | ✅ | a substitution that resolves to an array means an array for concatenation, and concatenating an array with an object is an error |
| `016-mixing-object-then-array-is-error` | ✅ | ✅ | it is an error to concatenate an object with an array in this order too, not only array then object |
| `017-newline-between-arrays-in-field-value-prevents-concatenation` | ✅ | ✅ | a newline between two arrays in a field value prevents concatenation, so the second array begins a new field, and an array cannot be a field key |

</details>

<details>
<summary><b>arrays-without-commas-or-newlines</b> — 7 cases · Java 7/7 · pyhocon 7/7</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-newlines-instead-of-commas` | ✅ | ✅ | arrays allow newlines to separate elements instead of commas |
| `002-whitespace-instead-of-comma-concatenates-into-one-element` | ✅ | ✅ | the spec's worked example: non-newline whitespace instead of a comma produces concatenation, so this array has one element, the string 1 2 3 4, not four integers |
| `003-newline-separates-two-arrays-into-elements` | ✅ | ✅ | the spec's worked example: a newline between two bracketed arrays makes them two separate elements |
| `004-same-line-whitespace-concatenates-two-arrays-into-one-element` | ✅ | ✅ | the spec's worked example: whitespace on the same line between two bracketed arrays concatenates them into a single element, the array [1, 2, 3, 4] |
| `005-unquoted-string-concatenation-with-substitutions-in-array` | ✅ | ✅ | the spec's worked example: unquoted words and substitutions separated by whitespace concatenate into one string element, and only the comma separates elements |
| `006-two-elements-each-a-substitution-concatenation` | ✅ | ✅ | the spec's worked example: whitespace between two substitutions concatenates them into one element, and the comma separates the two concatenations |
| `007-whitespace-never-separates-fields` | ✅ | ✅ | non-newline whitespace is never a field separator, so two field definitions cannot be written on one line separated only by spaces |

</details>

<details>
<summary><b>commas</b> — 8 cases · Java 8/8 · pyhocon 4/8</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-array-trailing-comma` | ✅ | ✅ | the last element in an array may be followed by a single comma, which is ignored: [1,2,3,] and [1,2,3] are the same array |
| `002-array-newline-no-comma` | ✅ | ✅ | array elements need not have a comma between them as long as an ASCII newline separates them: [1\n2\n3] and [1,2,3] are the same array |
| `003-array-double-trailing-comma-invalid` | ✅ | ❌ | [1,2,3,,] is explicitly called invalid because it has two trailing commas |
| `004-array-initial-comma-invalid` | ✅ | ❌ | [,1,2,3] is explicitly called invalid because it has an initial comma |
| `005-array-double-comma-invalid` | ✅ | ❌ | [1,,2,3] is explicitly called invalid because it has two commas in a row |
| `006-object-trailing-comma` | ✅ | ✅ | these same comma rules apply to fields in objects, so a single trailing comma after the last field is ignored |
| `007-object-newline-no-comma` | ✅ | ✅ | fields in objects need not have a comma between them as long as an ASCII newline separates them, same as array elements |
| `008-object-double-comma-invalid` | ✅ | ❌ | these same comma rules apply to fields in objects, so two commas in a row between fields is invalid just as in an array |

</details>

<details>
<summary><b>comments</b> — 6 cases · Java 6/6 · pyhocon 6/6</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-hash-comment` | ✅ | ✅ | anything between # and the next newline is a comment and ignored |
| `002-double-slash-comment` | ✅ | ✅ | anything between // and the next newline is a comment and ignored |
| `003-whole-line-comment` | ✅ | ✅ | a comment may occupy an entire line by itself, ignored just like a trailing one |
| `004-comment-stops-at-newline` | ✅ | ✅ | a comment runs only to the next newline, so the following line is parsed normally |
| `005-hash-inside-quoted-string-is-not-a-comment` | ✅ | ✅ | a # inside a quoted string is not treated as starting a comment |
| `006-double-slash-inside-quoted-string-is-not-a-comment` | ✅ | ✅ | a // inside a quoted string is not treated as starting a comment |

</details>

<details>
<summary><b>concatenation-whitespace-and-substitutions</b> — 9 cases · Java 7/9 · pyhocon 7/9</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-unquoted-whitespace-between-substitutions-is-significant-for-strings` | ✅ | ✅ | when the substitutions turn out to be strings, the unquoted whitespace between them is significant and survives into the concatenated string |
| `002-quoted-whitespace-between-substitutions-is-error` | ✅ | ✅ | between substitutions that resolve to objects, unquoted whitespace is ignored but quoted whitespace should be an error |
| `003-unquoted-whitespace-between-object-and-list-substitutions-is-ignored` | ✅ | ✅ | unquoted whitespace between substitutions that resolve to objects or lists must be ignored, so they merge and concatenate as if adjacent |
| `004-tab-between-list-substitutions-is-ignored` | ✅ | ✅ | whitespace between two list substitutions is ignored, tabs included, and the lists concatenate |
| `005-nonbreaking-space-between-list-substitutions-is-ignored` | ✅ | ❌ | U+00A0 is a Zs space and so whitespace in HOCON; between two list substitutions it is ignored (lightbend/config#862 review) |
| `006-bom-between-list-substitutions-is-ignored` | ✅ | ❌ | the BOM must be treated as whitespace, so between two list substitutions it is ignored |
| `007-zero-width-space-between-list-substitutions-is-error` | ❌ | ✅ | U+200B is format (Cf), not a space separator, so it is text, and text between two list substitutions is invalid. typesafe/config drops it and concatenates the lists; lightbend/config#862 rejects it _(java: lenient)_ |
| `008-list-then-undefined-optional-is-the-list` | ✅ | ✅ | an undefined optional substitution in a concatenation with an array becomes an empty array |
| `009-undefined-optional-then-list-is-the-list` | ❌ | ✅ | the mirror of 008: an undefined optional substitution before an array becomes an empty array too. typesafe/config keeps the whitespace before the list as text and rejects it, while accepting 008 (noted on lightbend/config#862) _(java: unsupported)_ |

</details>

<details>
<summary><b>config-and-file-merging</b> — 5 cases · Java 5/5 · pyhocon 3/5</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-objects-from-two-files-merge` | ✅ | ✅ | merging two objects loaded from different files works as if the two objects were duplicate values for the same key in the same file, so the object from the included file and the object in the including file merge key-by-key |
| `002-file-merge-is-recursive-and-later-file-wins` | ✅ | ✅ | merging objects loaded from different files is exactly the same behavior as merging duplicate fields in the same file: object-valued fields present in both files merge recursively and a non-object field takes the value from the later file |
| `003-non-object-between-files-hides-earlier-object` | ✅ | ❌ | the spec's own example: an intermediate non-object value hides earlier object values because merging is done in pairs, so when 42 is paired with { y : 2 } it simply wins and loses all information about what it overrode, and the two objects are never merged |
| `004-adjacent-objects-across-files-merge` | ✅ | ❌ | the spec's re-ordered example: with the non-object 42 moved to the lowest priority the two objects are adjacent, so they merge to { a : { x : 1, y : 2 } } |
| `005-null-clears-included-object` | ✅ | ✅ | setting an object to null and then setting it back to a new object clears it and starts over, which is how to get rid of default fallback values from another file that you don't want |

</details>

<details>
<summary><b>duplicate-keys-and-object-merging</b> — 17 cases · Java 11/17 · pyhocon 15/17</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-later-scalar-wins` | ✅ | ✅ | for a non-object value the later assignment simply replaces the earlier one |
| `002-objects-merge` | ✅ | ✅ | two objects under the same key merge key-by-key, they do not replace |
| `003-scalar-breaks-the-merge` | ✅ | ❌ | merging is always done two values at a time: the scalar replaces the first object (non-object always wins), then the second object replaces the scalar (no merging, object is the new value), so the two objects never see each other |
| `004-merge-scalar-field-later-wins` | ✅ | ✅ | for a non-object-valued field present in both merged objects, the field from the second object is used |
| `005-merge-nested-object-recursive` | ✅ | ✅ | for an object-valued field present in both objects, the object values are recursively merged by the same rules |
| `006-null-prevents-merge` | ✅ | ✅ | the spec's own example: an intermediate null is a non-object, so it replaces the first object and is in turn replaced by the second object with no merging, which prevents the two objects from ever seeing each other |
| `007-merge-keeps-fields-from-either-side` | ✅ | ✅ | fields present in only one of the two objects are added to the merged object as they are, whether the first or the second side has them and whether the value is a scalar or an object with nothing to merge against |
| `008-arrays-are-not-objects` | ✅ | ✅ | only two object values merge; an array is not an object, so a later array replaces an earlier array (no concatenation) and replaces an earlier object (no merge) |
| `009-later-null-overrides` | ✅ | ✅ | null is a value like any other, so a later null overrides an earlier scalar or object: the key stays, set to null, rather than being removed or the assignment skipped |
| `010-null-in-referenced-key-history-does-not-block-merge` | ❌ | ✅ | the null at r only stops merging at r; ${r} is the object {x:1}, and a later object merges with the earlier a, so helper stays. typesafe/config carries r's null through the substitution and drops helper (lightbend/config#864) _(java: diverges)_ |
| `011-nested-null-in-referenced-object-does-not-block-merge` | ❌ | ✅ | the same rule one level down: the null in v.nested's history belongs to v.nested, so a.nested still merges with the substituted {x:1} (lightbend/config#864) _(java: diverges)_ |
| `012-reference-to-merged-field-sees-the-same-value` | ❌ | ✅ | a substitution sees the resolved value of the field it names, so o24bbd equals a.nested, which keeps helper. The key name is chosen to sort before a in typesafe/config's root HashMap, the order in which the first version of lightbend/config#864 answered differently for the two _(java: diverges)_ |
| `013-top-level-null-before-object-with-substitution` | ❌ | ✅ | the null belongs to v's history even when v's object is still unresolved, so a merges and keeps helper (lightbend/config#864) _(java: diverges)_ |
| `014-own-null-still-blocks-merge-with-referenced-object` | ✅ | ✅ | the receiver's own intermediate null still breaks the merge: a is {helper:0}, then null, then the substituted object, so helper is gone |
| `015-earlier-receiver-value-is-evaluated-once-merged` | ✅ | ✅ | ${r} is an object, so it merges with the earlier a and the ${missing} inside it is evaluated: an error. typesafe/config 1.4.5 agrees; 1.4.9 drops the earlier a and yields {y:1}; lightbend/config#864 restores the error |
| `016-null-deeper-in-a-merge-stack-stays-at-its-key` | ❌ | ❌ | v's value is a merge whose top is an object and whose null sits further down, under nested; that null is still v.nested's merge instruction, so a.nested keeps helper (lightbend/config#864 review, round 3) _(java: diverges)_ |
| `017-lookup-into-nested-null-merges` | ❌ | ✅ | two nested nulls each break only their own key's merge, and a lookup of a.n.d sees the final {x:1}; typesafe/config throws BugOrBroken in this key order (reported on lightbend/config#864, same on main) _(java: unsupported)_ |

</details>

<details>
<summary><b>duration-format</b> — 9 cases · Java 9/9 · pyhocon 2/9</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-bare-number-is-milliseconds` | ✅ | ✅ | bare numbers are taken to be in milliseconds already |
| `002-uppercase-unit-is-illegal` | ✅ | ✅ | the supported unit strings for duration are case-sensitive and must be lowercase, so an uppercase unit is not one of the supported strings |
| `003-nanoseconds-spellings` | ✅ | ❌ | exactly ns, nano, nanos, nanosecond, nanoseconds are the supported unit strings for nanoseconds |
| `004-microseconds-spellings` | ✅ | ❌ | exactly us, micro, micros, microsecond, microseconds are the supported unit strings for microseconds |
| `005-milliseconds-spellings` | ✅ | ❌ | exactly ms, milli, millis, millisecond, milliseconds are the supported unit strings for milliseconds |
| `006-seconds-spellings` | ✅ | ❌ | exactly s, second, seconds are the supported unit strings for seconds |
| `007-minutes-spellings` | ✅ | ❌ | exactly m, minute, minutes are the supported unit strings for minutes |
| `008-hours-spellings` | ✅ | ❌ | exactly h, hour, hours are the supported unit strings for hours |
| `009-days-spellings` | ✅ | ❌ | exactly d, day, days are the supported unit strings for days in the duration format |

</details>

<details>
<summary><b>include-merging</b> — 9 cases · Java 9/9 · pyhocon 9/9</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-included-keys-merge-in-place` | ✅ | ✅ | the keys from the included object are conceptually substituted for the include statement in the including file, so the included field lands between the fields around it and merges by the usual duplicate-key rules |
| `002-included-conf-array-root-is-error` | ✅ | ✅ | an included file must contain an object, not an array; if it contains an array as the root value it is invalid and an error should be generated |
| `003-included-json-array-root-is-error` | ✅ | ✅ | both JSON and HOCON allow arrays as root values in a document, but an included file must contain an object, so a JSON file with an array root is an error when included |
| `004-include-inside-nested-object` | ✅ | ✅ | the keys from the included root object are conceptually substituted for the include statement in the including file, so an include inside a nested object contributes its keys to that object |
| `005-included-scalar-overrides-earlier-key` | ✅ | ✅ | if a key in the included object occurred prior to the include statement in the including object, the included key's value overrides the earlier value, exactly as with duplicate keys found in a single file |
| `006-included-object-merges-with-earlier-object` | ✅ | ✅ | if a key in the included object occurred prior to the include statement and both values are objects, the included value merges with the earlier value, exactly as with duplicate keys found in a single file |
| `007-included-scalar-replaces-earlier-object` | ✅ | ✅ | an included key's value overrides the earlier value exactly as with duplicate keys in a single file, so an included non-object replaces an earlier object rather than merging with it |
| `008-later-key-overrides-included-key` | ✅ | ✅ | if the including file repeats a key from an earlier-included object, the including file's value overrides the one from the included file |
| `009-later-object-merges-with-included-object` | ✅ | ✅ | if the including file repeats a key from an earlier-included object and both values are objects, the including file's value merges with the one from the included file |

</details>

<details>
<summary><b>include-missing-and-required</b> — 6 cases · Java 6/6 · pyhocon 6/6</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-missing-include-ignored` | ✅ | ✅ | by default, if an included file does not exist the include statement is silently ignored, so the keys around it parse as if the line were not there |
| `002-missing-include-is-empty-object` | ✅ | ✅ | a missing include is treated as if the included file contained only an empty object, so an object whose only content is that include stays an empty object |
| `003-missing-file-include-ignored` | ✅ | ✅ | the silent-ignore default applies to an explicit file() include as well: a file that does not exist contributes nothing and parsing continues |
| `004-required-missing-is-error` | ✅ | ✅ | when the included resource name is wrapped with required(), file parsing fails with an error if the resource cannot be resolved |
| `005-required-file-missing-is-error` | ✅ | ✅ | required() may also wrap the file() form, and a required file that cannot be resolved is a parse error rather than an empty object |
| `006-required-present-is-included` | ✅ | ✅ | required() only makes the include mandatory; a resource that does resolve is included exactly as an unwrapped include would be |

</details>

<details>
<summary><b>include-substitution</b> — 15 cases · Java 12/15 · pyhocon 10/15</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-substitution-relativized-to-include-scope` | ✅ | ❌ | a substitution in an included file must be fixed up to be relative to the app's configuration root, so ${x} in a file included at key a becomes ${a.x} |
| `002-relativized-path-sees-later-redefinition` | ✅ | ❌ | substitution happens after parsing the whole configuration, so the ${x} fixed up to ${a.x} evaluates to the root's later redefinition 42 rather than the included file's 10 |
| `003-original-path-tried-as-fallback` | ✅ | ✅ | it is not enough to only look up the fixed-up path; when a.x is undefined the original path x is looked up relative to the root of the including configuration |
| `004-relativized-path-tried-before-original` | ✅ | ❌ | substitutions in included files are looked up first relative to the root of the included file and only second relative to the root of the including configuration, so a.x wins over x |
| `005-neither-path-defined-is-error` | ✅ | ✅ | only the fixed-up path a.x and the original path x are looked up; with neither defined the substitution is undefined and the configuration is invalid |
| `006-optional-substitution-with-neither-path-is-omitted` | ✅ | ✅ | an optional substitution in an included file is looked up at the fixed-up path a.x and at the original path x; with neither defined the field is omitted rather than an error |
| `007-nested-include-relativized-through-both-levels` | ✅ | ❌ | the fix-up is relative to the app's configuration root, so ${x} in a file included at b inside a file included at a becomes ${a.b.x} |
| `008-original-path-falls-back-to-environment` | ✅ | ✅ | an included file may intend to refer to the application's root config, for example to get a value from the environment; the original path CONFORMANCE_HOME is looked up and falls back to the environment variable |
| `009-undefined-optional-at-fixed-up-path-falls-back` | ❌ | ✅ | an undefined ${?nope} means common.x.y is never created, so ${x.y} is not found at the fixed-up path and is looked up at the original path x.y. typesafe/config treats the vanished value as a miss that ends the lookup -- except in some root key orders (see 014); lightbend/config#863 falls back _(java: unsupported)_ |
| `010-undefined-optional-at-fixed-up-path-with-no-original` | ✅ | ✅ | with neither common.x.y nor x.y defined, the required ${x.y} in the included file is unresolved |
| `011-optional-reference-falls-back-too` | ❌ | ✅ | the optional form of 009 falls back the same way; typesafe/config leaves a out instead (lightbend/config#863) _(java: diverges)_ |
| `012-earlier-value-at-fixed-up-path-wins` | ✅ | ❌ | an undefined optional that would override keeps the previous value, so common.x.y is 9 and found at the fixed-up path; the original path is not consulted |
| `013-missing-leaf-under-existing-object-falls-back` | ✅ | ✅ | the metamorphic twin of 009 without the optional: common.x exists, common.x.y does not, so x.y is looked up at the original path |
| `014-unrelated-key-does-not-change-the-result` | ❌ | ✅ | an unrelated key that reads common.x must not change what common.a resolves to; in typesafe/config this input fails while the same input with the key named o24bbd resolves to 0 (lightbend/config#863) _(java: unsupported)_ |
| `015-undefined-at-both-paths-is-error` | ✅ | ✅ | when the original path is itself an undefined optional, neither lookup finds a value and the required ${x.y} is an error |

</details>

<details>
<summary><b>include-syntax</b> — 7 cases · Java 7/7 · pyhocon 7/7</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-include-later-in-key-is-literal` | ✅ | ✅ | unquoted include has no special meaning if it is not the start of a key's path expression; it may appear later in the key, so { foo include : 42 } is equivalent to { "foo include" : 42 } |
| `002-include-as-object-value-is-string` | ✅ | ✅ | unquoted include has no special meaning if it is not the start of a key's path expression; as an object value it is the string "include" |
| `003-include-as-array-element-is-string` | ✅ | ✅ | unquoted include has no special meaning if it is not the start of a key's path expression; as an array element it is the string "include". the spec's example is the root array [ include ]; it is wrapped in a field here so the row does not depend on array-root support |
| `004-no-concatenation-on-include-argument` | ✅ | ✅ | value concatenation is NOT performed on the argument to include; the argument must be a single quoted string, so a second quoted string after the resource name is an error whether or not the first resource exists |
| `005-no-substitution-in-include-argument` | ✅ | ✅ | no substitutions are allowed in the argument to include, which must be a single quoted string; ${x} after include is an error even though x is defined, so an implementation that resolves the argument first still fails this row |
| `006-include-argument-must-be-quoted` | ✅ | ✅ | if an unquoted include at the start of a key is followed by anything other than a single quoted string or the url()/file()/classpath() syntax, it is invalid and an error should be generated; the argument may not be an unquoted string |
| `007-quoted-include-is-ordinary-key` | ✅ | ✅ | only unquoted include is special; quoting it gives a key that starts with the word include, so { "include" : 42 } is an ordinary field named include |

</details>

<details>
<summary><b>key-value-separator</b> — 3 cases · Java 3/3 · pyhocon 3/3</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-equals-as-separator` | ✅ | ✅ | the = character can be used anywhere JSON allows :, to separate keys from values |
| `002-omitted-separator-before-object` | ✅ | ✅ | if a key is followed by {, the : or = may be omitted; the spec's own example is "foo" {} meaning "foo" : {} |
| `003-omitted-separator-unquoted-key` | ✅ | ✅ | the separator-omission rule before { applies to unquoted keys too, not just the quoted example in the spec |

</details>

<details>
<summary><b>multi-line-strings</b> — 7 cases · Java 7/7 · pyhocon 7/7</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-basic-triple-quote` | ✅ | ✅ | the three-character sequence """ starts a multi-line string whose unicode characters are used unmodified to create the string value |
| `002-newlines-and-whitespace-preserved` | ✅ | ✅ | newlines and whitespace inside a multi-line string receive no special treatment and are kept in the value |
| `003-unicode-escape-not-interpreted` | ✅ | ✅ | unlike JSON quoted strings, unicode escapes are not interpreted in triple-quoted strings, so \u0041 stays literal rather than becoming A |
| `004-extra-quote-becomes-part-of-string` | ✅ | ✅ | any sequence of at least three quotes ends the multi-line string and any extra quotes are part of the string, so HOCON works like Scala's four-character string foo" rather than Python's syntax error |
| `005-five-closing-quotes-two-extra` | ✅ | ✅ | a closing run of five quotes still only needs three to end the string, so both extra quotes are appended to the string value |
| `006-unterminated-is-illegal` | ✅ | ✅ | a multi-line string opened with a three-character quote sequence that never reaches a closing """ is not a legal value |
| `007-fewer-than-three-quotes-does-not-close` | ✅ | ✅ | only a run of at least three quote characters ends the multi-line string, so the single embedded quote pairs around hi do not terminate it early |

</details>

<details>
<summary><b>numerically-indexed-objects-to-arrays</b> — 8 cases · Java 8/8 · pyhocon 4/8</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-object-with-numeric-keys-stays-object` | ✅ | ✅ | the conversion should be done lazily when required to avoid a type error, not eagerly anytime an object has numeric keys, so a bare object with numeric keys stays an object |
| `002-properties-style-dotted-numeric-keys` | ✅ | ✅ | worked example: foo.0 = "a", foo.1 = "b" is the properties-file idiom the spec says implementations should support converting to an array |
| `003-concatenation-converts-numeric-object-to-array` | ✅ | ❌ | the conversion should be done in a concatenation when a list is expected and an object with numeric keys is found, so the trailing object concatenates onto the array as elements x, y |
| `004-concatenation-ignores-non-integer-keys` | ✅ | ❌ | the conversion should ignore any keys which do not parse as positive integers, so key "foo" is dropped and only "0" contributes to the resulting array |
| `005-empty-object-concatenation-not-converted` | ✅ | ✅ | the conversion should not occur if the object is empty, so an empty object cannot satisfy a list-expected concatenation and this is illegal |
| `006-object-without-integer-keys-not-converted` | ✅ | ✅ | the conversion should not occur if the object has no keys which parse as positive integers, so this object cannot satisfy a list-expected concatenation and this is illegal |
| `007-sparse-integer-keys-sorted-and-reindexed` | ✅ | ❌ | the conversion should sort by the integer value of each key and then build the array; missing indices such as "1" are eliminated rather than left as gaps, so keys "0" and "2" become a two-element array |
| `008-negative-key-ignored-in-conversion` | ✅ | ❌ | the conversion ignores any keys which do not parse as positive integers, and "-1" is not a positive integer, so it is dropped and only key "0" contributes |

</details>

<details>
<summary><b>omit-root-braces</b> — 11 cases · Java 5/11 · pyhocon 10/11</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-implicit-root-object` | ✅ | ✅ | if the file does not begin with [ or {, it is parsed as if enclosed with {} curly braces |
| `002-explicit-root-object-unaffected` | ✅ | ✅ | the implicit-wrap rule only applies when the file does not begin with [ or {; a file already beginning with { is parsed as ordinary JSON-style object |
| `003-missing-open-brace-with-close-brace-illegal` | ✅ | ✅ | a HOCON file is invalid if it omits the opening { but still has a closing }, since the curly braces must be balanced |
| `004-empty-file` | ✅ | ✅ | in plain JSON empty files are invalid documents; this case checks whether HOCON's implicit-brace wrapping (the file does not begin with [ or {) extends to an empty file as well |
| `005-bare-string-root-illegal` | ✅ | ✅ | a JSON document containing only a non-array non-object value such as a string is invalid, and wrapping such content in {} does not produce a valid object body either |
| `006-array-root-unaffected` | ❌ | ✅ | the implicit {} wrap fires only when the file does not begin with a square bracket or curly brace, so a file starting with [ keeps its array root; the include section says so outright -- 'both JSON and HOCON allow arrays as root values in a document' (the reason an included file may not be one). typesafe/config has no array-rooted config at all and rejects the document as LIST rather than object. _(java: unsupported)_ |
| `007-array-root-of-objects` | ❌ | ✅ | a file beginning with a square bracket keeps its array root whatever the elements are; typesafe/config parses it and then refuses it at the API, having no array-rooted config _(java: unsupported)_ |
| `008-empty-array-root` | ❌ | ✅ | an empty array is still an array root, and the wrap rule looks at the opening bracket, not at whether the document has content _(java: unsupported)_ |
| `009-comment-before-array-root` | ❌ | ✅ | the {} wrap fires only for a file that does not begin with a bracket or brace, and a leading comment does not make it one -- both typesafe/config and pyhocon read the first token, not the first byte. the spec's wording is loose here; this row records the consensus reading _(java: unsupported)_ |
| `010-blank-line-before-array-root` | ❌ | ✅ | leading whitespace does not trigger the {} wrap either, for the same reason as a leading comment _(java: unsupported)_ |
| `011-trailing-array-after-root-array` | ⚠ | ⚠ | two arrays side by side concatenate when only non-newline whitespace separates them, which would make this document [1,2,3]; but nothing in the spec says a root value may be a concatenation, and typesafe/config calls the second bracket a trailing token. pyhocon rejects it too, with a different error **⚠ oracle rejected this — illegal per spec, or unsupported by java?** |

</details>

<details>
<summary><b>path-expressions</b> — 20 cases · Java 20/20 · pyhocon 13/20</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-quoted-dot-has-no-meaning` | ✅ | ✅ | a dot inside a quoted string has no special meaning as a path separator, so a quoted "a.b" key is a single-element path |
| `002-mixed-quoted-and-unquoted-path` | ✅ | ❌ | foo.bar."hello.world" is a path with three elements: foo, bar, and hello.world, since unquoted dots are path separators but a quoted dot is not |
| `003-number-then-unquoted-string` | ✅ | ✅ | 10.0foo is a number then unquoted string foo, giving the two-element path 10 and 0foo, because a dot inside a number still counts as a path separator |
| `004-unquoted-string-with-dot` | ✅ | ✅ | foo10.0 is an unquoted string with a dot in it, giving the two-element path foo10 and 0 |
| `005-unquoted-concatenated-with-quoted-number` | ✅ | ❌ | foo followed by quoted "10.0" is an unquoted then a quoted string which concatenate, giving a single-element path |
| `006-all-numeric-path` | ✅ | ✅ | dots in numbers count as path separators, so 1.2.3 is the three-element path with elements 1, 2, 3 |
| `007-path-expression-always-a-string` | ✅ | ✅ | a path expression is always converted to a string, so the key true becomes the string true rather than a boolean |
| `008-value-concatenation-keeps-boolean` | ✅ | ✅ | unlike a path expression, an array or element value consisting of the single value true is a value concatenation and retains its character as a boolean |
| `009-empty-path-element-quoted-is-valid` | ✅ | ❌ | a path element that is an empty string must be quoted; a."".b is a valid three-element path whose middle element is the empty string |
| `010-consecutive-dots-invalid` | ✅ | ❌ | an unquoted empty path element is invalid, so a..b must generate an error |
| `011-path-starting-with-dot-invalid` | ✅ | ❌ | a path that starts with a dot is invalid and should generate an error |
| `012-path-ending-with-dot-invalid` | ✅ | ❌ | a path that ends with a dot is invalid and should generate an error |
| `013-substitution-in-key-invalid` | ✅ | ✅ | path expressions may not contain substitutions, so a substitution used as a key is illegal |
| `014-nested-substitution-invalid` | ✅ | ✅ | you cannot nest substitutions inside other substitutions |
| `015-dotted-path-in-substitution` | ✅ | ✅ | path expressions appear in substitutions like ${foo.bar}, where the unquoted dot separates foo and bar into two path elements, so the lookup walks key foo then key bar |
| `016-number-keeps-original-text-in-path` | ✅ | ✅ | a number in a path expression must keep its original string representation as it appeared in the file, so 1.10 is the two-element path 1 and 10, not the 1 and 1 a generic number-to-string conversion would give |
| `017-whitespace-concatenation-in-path` | ✅ | ✅ | path expressions are syntactically identical to a value concatenation, so the whitespace-separated a b concatenates into one element and the unquoted dot then splits off c, giving the two-element path a b and c |
| `018-quoted-element-in-substitution-path` | ✅ | ✅ | path expressions appear in substitutions as well as keys, and inside quoted strings a dot has no special meaning there either, so ${foo."bar.baz"} looks up key foo then the single key bar.baz |
| `019-empty-element-in-substitution-path-invalid` | ✅ | ❌ | an unquoted empty path element is invalid in a substitution just as in a key, so ${a..b} must generate an error rather than collapsing to ${a.b} (a.b is defined so a lenient implementation would produce a value and fail) |
| `020-negative-leading-dot-key-is-a-path` | ✅ | ✅ | in a key, -.33 is a path expression split on the unquoted dot, not a number, so it names - then 33; the JSON number rule for values does not reach keys |

</details>

<details>
<summary><b>paths-as-keys</b> — 10 cases · Java 9/10 · pyhocon 8/10</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-two-element-path-expands` | ✅ | ✅ | a key that is a multi-element path expands to a nested object per element, the last element combined with the value becomes a field in the most-nested object: foo.bar:42 is equivalent to foo{bar:42} |
| `002-three-element-path-expands` | ✅ | ✅ | a three-element path key expands through two levels of nesting: foo.bar.baz:42 is equivalent to foo{bar{baz:42}} |
| `003-merge-sibling-paths` | ✅ | ✅ | the objects created by expanding path keys are merged in the usual way, so a.x:42, a.y:43 is equivalent to a{x:42,y:43} |
| `004-whitespace-in-key` | ✅ | ✅ | because path expressions work like value concatenations, whitespace is allowed in keys: a b c:42 is equivalent to "a b c":42 |
| `005-unquoted-true-key-becomes-string` | ✅ | ✅ | path expressions are always converted to strings, so the unquoted boolean-looking key true:42 is "true":42 |
| `006-unquoted-number-key-becomes-string` | ✅ | ✅ | path expressions are always converted to strings, so the unquoted numeric key 3:42 is "3":42 |
| `007-decimal-key-splits-on-dot` | ✅ | ✅ | a dot in an unquoted key is a path separator even when it looks like a decimal number, so 3.14:42 is "3":{"14":42} |
| `008-include-cannot-begin-key` | ❌ | ❌ | the unquoted string include may not begin a path expression in a key: where an object key is expected, include is not read as a key at all and must be followed by a quoted resource name, so include.foo is an error. typesafe/config recognises the keyword only as a bare include token -- include.foo tokenizes as one unquoted string, so it is accepted as the path include.foo, while include = 42 is rejected under the very rule the spec states. _(java: lenient)_ |
| `009-include-not-at-start-is-ordinary` | ✅ | ❌ | only the unquoted string include that begins a path expression in a key is special: include later in a key (foo.include) and a quoted "include" beginning one are ordinary path elements |
| `010-path-key-merges-with-brace-object` | ✅ | ✅ | the object created by expanding a path key is merged in the usual way with an object written in braces at the same key, whichever form comes first: a{x:1}, a.y:2 and b.x:1, b{y:2} are both equivalent to {x:1,y:2} |

</details>

<details>
<summary><b>period-format</b> — 7 cases · Java 7/7 · pyhocon 3/7</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-bare-number-is-days` | ✅ | ✅ | for getPeriod(), bare numbers are taken to be in days, unlike getDuration() where bare numbers are milliseconds |
| `002-uppercase-unit-is-illegal` | ✅ | ✅ | the supported unit strings for period are case-sensitive and must be lowercase, so an uppercase unit is not one of the supported strings |
| `003-days-spellings` | ✅ | ❌ | exactly d, day, days are the supported unit strings for days in the period format |
| `004-weeks-spellings` | ✅ | ❌ | exactly w, week, weeks are the supported unit strings for weeks |
| `005-months-spellings` | ✅ | ❌ | exactly m, mo, month, months are the supported unit strings for months |
| `006-years-spellings` | ✅ | ✅ | exactly y, year, years are the supported unit strings for years |
| `007-month-m-ambiguous-with-duration-minutes` | ✅ | ❌ | the spec notes that getTemporal() callers should prefer mo over m for months, since m is also the duration unit for minutes and getTemporal() may return either a Duration or a Period |

</details>

<details>
<summary><b>plus-equals-field-separator</b> — 3 cases · Java 3/3 · pyhocon 0/3</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-plus-equals-desugars-to-optional-self-ref-array` | ✅ | ❌ | a += b transforms into a = ${?a} [b], and because the fallback is optional (${?a} not ${a}) this is legal even as the first mention of a in the file |
| `002-plus-equals-appends-to-existing-array` | ✅ | ❌ | += appends an element to a previous array |
| `003-plus-equals-errors-on-non-array-previous-value` | ✅ | ❌ | if the previous value was not an array, += results in an error just as the long form a = ${?a} [b] would with a non-array a |

</details>

<details>
<summary><b>self-referential-examples</b> — 23 cases · Java 19/23 · pyhocon 20/23</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-isolated-self-reference-is-an-error` | ✅ | ✅ | in isolation, with no merges involved, a self-referential field is an error because the substitution cannot be resolved |
| `002-self-reference-resolves-to-earlier-merged-value` | ✅ | ✅ | when foo:${foo} is merged with an earlier value for foo, the self-reference resolves to that overridden value, so foo ends up { a : 1 } |
| `003-self-reference-before-any-value-is-undefined` | ✅ | ✅ | if the self-referential foo:${foo} comes before foo has any value, the reference is undefined, exactly as if it named a path not found in the document, so it is an error even though foo is given a value afterward |
| `004-optional-self-reference-disappears-silently` | ✅ | ✅ | because the self-reference error is treated as undefined rather than an intractable cycle, the optional syntax foo:${?foo} makes the field disappear silently instead of erroring |
| `005-substitution-hidden-by-later-non-mergeable-value-is-never-evaluated` | ✅ | ✅ | if a substitution is hidden by a later non-object value that could not be merged with it, it is never evaluated and no error is reported, no matter what it would have resolved to; foo ends up 42 |
| `006-self-reference-cycle-ignored-when-overridden-by-literal` | ✅ | ✅ | the same hiding rule applies to a self-reference cycle: once overridden by a non-mergeable literal, the initial foo:${foo} must simply be ignored, so foo ends up 42 with no error |
| `007-self-reference-in-path-expression-resolves-to-value-below` | ✅ | ✅ | a self-reference resolves to the value below it even as part of a path expression, so ${foo.a} refers to { c : 1 } rather than 2, and the final merge is { a : 2, c : 1 } |
| `008-object-may-refer-to-sibling-path-within-itself` | ✅ | ✅ | an implementation must allow an object to refer to a path within itself without treating it as a cycle, by resolving only the referenced field rather than recursing the whole enclosing object; bar.baz ends up 42 |
| `009-non-cycling-reference-looks-forward-across-merge` | ✅ | ✅ | because there is no inherent cycle here, the substitution must look forward including the field's own later merges, so bar.baz ends up 43 once foo is overridden to 43 |
| `010-mutually-referring-objects-are-not-self-referential` | ✅ | ✅ | mutually-referring objects should work and are not self-referential, so they look forward: bar.a ends up 4 and foo.c ends up 3 |
| `011-optional-self-reference-in-concatenation-looks-back` | ✅ | ✅ | an optional self-reference in a value concatenation has to look back to an undefined a, so a ends up "foo" rather than "foofoo" |
| `012-mutual-non-self-cycle-is-unresolvable` | ✅ | ✅ | the spec gives bar:${foo}, foo:${bar} as an example that is not possible to resolve, since neither lazy evaluation nor looking backward breaks the cycle and neither field is optional |
| `013-multi-step-cycle-is-invalid` | ✅ | ✅ | a multi-step loop across three fields (a:${b}, b:${c}, c:${a}) must also be detected as invalid, not just a direct two-field cycle |
| `014-order-dependent-resolution-must-agree-on-one-value` | ✅ | ✅ | this case has undefined behavior depending on resolution order: implementations are allowed to set both a and b to 1, both to 2, or to error, but must set both to the same value because substitutions are memoized by instance, so a and b must never diverge (e.g. a=1,b=2 is not permitted) |
| `015-list-hidden-by-substituted-object-is-never-evaluated` | ❌ | ✅ | a list cannot merge with the object that replaces it, so it is hidden and never evaluated, whether the object is written literally or arrives through ${replacement}; typesafe/config evaluates it (lightbend/config#865) _(java: unsupported)_ |
| `016-object-hidden-by-substituted-scalar-is-never-evaluated` | ❌ | ❌ | ${replacement} resolves to 42, a non-object, so the earlier object is hidden and never evaluated -- as with the literal in 005. typesafe/config 1.4.5 evaluates it; 1.4.9 and later do not _(java: unsupported)_ |
| `017-object-hidden-by-substituted-concatenation-is-never-evaluated` | ❌ | ❌ | a string concatenation is a non-object too, so it hides the earlier object. typesafe/config 1.4.5 evaluates it; 1.4.9 and later do not _(java: unsupported)_ |
| `018-object-merged-with-substituted-object-is-evaluated` | ✅ | ✅ | a substituted object merges with the earlier object, so its fields are part of the result and ${does-not-exist} is an error |
| `019-list-hidden-by-literal-scalar-is-never-evaluated` | ✅ | ✅ | the literal counterpart of 015: a literal number could not be merged with the list, so the list is never evaluated and there is no error |
| `020-object-hidden-by-literal-list-is-never-evaluated` | ✅ | ✅ | a literal list is a non-object value, so it hides the earlier object and ${does-not-exist} is never evaluated |
| `021-hidden-list-does-not-depend-on-key-order` | ❌ | ✅ | a reader of w.x must not change whether the hidden list is evaluated. typesafe/config fails here, yet resolves the same file with the reader named o24bbd, which it visits before w (lightbend/config#865) _(java: unsupported)_ |
| `022-undefined-optional-does-not-hide` | ✅ | ✅ | an undefined optional that would override leaves the previous value in place, so the list is the result and ${does-not-exist} is evaluated: an error |
| `023-append-does-not-hide` | ✅ | ❌ | w += 1 is w = ${?w} [1], which reads the earlier list, so ${does-not-exist} is evaluated: an error |

</details>

<details>
<summary><b>self-referential-substitutions</b> — 6 cases · Java 6/6 · pyhocon 6/6</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-path-builds-on-older-value` | ✅ | ✅ | a field may look up its own older value before being overridden with a new value based on it, letting path:${path}":d" extend the earlier path:"a:b:c" |
| `002-self-referential-concatenation` | ✅ | ✅ | a value concatenation containing a substitution that refers to the field being defined is self-referential, as the spec lists a:${a}bc among the examples |
| `003-object-containing-self-reference-is-not-self-referential` | ✅ | ✅ | an object with a substitution inside it is not considered self-referential for this purpose, so a:{b:${a}} is an unbreakable cycle that must generate an error |
| `004-array-containing-self-reference-is-not-self-referential` | ✅ | ✅ | an array with a substitution inside it is not considered self-referential for this purpose, so a:[${a}] is an unbreakable cycle that must generate an error |
| `005-optional-self-reference-resolves-as-missing` | ✅ | ✅ | cycles are treated the same as a missing value when resolving an optional substitution, so if ${?a} refers to itself it is as if it referred to a nonexistent value |
| `006-self-referential-array-concatenation` | ✅ | ✅ | the spec lists path:${path} [ /usr/bin ] among the examples of self-referential fields: a value concatenation of a substitution with an array literal is still self-referential |

</details>

<details>
<summary><b>size-in-bytes-format</b> — 5 cases · Java 5/5 · pyhocon 4/5</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-bare-number-is-bytes` | ✅ | ✅ | bare numbers are taken to be in bytes already |
| `002-single-byte-spellings` | ✅ | ✅ | for single bytes, exactly B, b, byte, bytes are supported |
| `003-powers-of-ten-suffixes` | ✅ | ✅ | every power-of-10 suffix and its long forms name the same unit family; one table, one rule |
| `004-powers-of-two-suffixes` | ✅ | ❌ | every power-of-2 suffix and its long forms name the same unit family; one table, one rule |
| `019-single-letter-abbreviation-means-powers-of-two` | ✅ | ✅ | the single-letter abbreviations (like K) are ambiguous between powers of two and ten, and this spec follows the java -Xmx / GNU-tools precedent of mapping them to powers of two |

</details>

<details>
<summary><b>string-value-concatenation</b> — 19 cases · Java 13/19 · pyhocon 17/19</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-substitution-in-string-concatenation` | ✅ | ✅ | string value concatenation supports substitutions inside the concatenated string |
| `002-only-simple-values-participate` | ✅ | ✅ | it is invalid for arrays or objects to appear in a string value concatenation, since only simple values participate |
| `003-leading-and-trailing-whitespace-trimmed` | ✅ | ✅ | whitespace before the first and after the last simple value is discarded, but whitespace between simple values is preserved |
| `004-concatenation-never-spans-newline` | ✅ | ✅ | string value concatenations never span a newline, so a bare word on the following line is not appended to the value above it |
| `005-array-element-string-concatenation` | ✅ | ✅ | a string value concatenation may appear in any place a string may appear, including array elements |
| `006-boolean-becomes-string-in-concatenation` | ✅ | ❌ | true and false become the strings "true" and "false" when they participate in a concatenation |
| `007-null-becomes-string-in-concatenation` | ✅ | ❌ | null becomes the string "null" when it participates in a concatenation |
| `008-number-kept-as-written-in-concatenation` | ✅ | ✅ | numbers should be kept as they were originally written in the file when they participate in a concatenation, not renormalized |
| `009-single-boolean-not-converted-to-string` | ✅ | ✅ | a single value is never converted to a string; true by itself must be parsed as a boolean-typed value, not a string |
| `010-object-then-scalar-drops-the-scalar` | ❌ | ✅ | it is invalid for arrays or objects to appear in a string value concatenation; typesafe/config accepts this one silently and discards the trailing x, losing data with no diagnostic, while erroring on the same pair in the other order _(java: lenient)_ |
| `011-array-then-scalar-drops-the-scalar` | ❌ | ✅ | the same rule for arrays; typesafe/config again accepts and discards the trailing x, where it errors when the scalar comes first _(java: lenient)_ |
| `012-scalar-then-object-is-an-error` | ✅ | ✅ | the same rule with the scalar first, which typesafe/config does reject -- the half of the rule it enforces |
| `013-scalar-then-array-is-an-error` | ✅ | ✅ | the same rule with the scalar first and an array, also rejected |
| `014-array-then-unquoted-text-without-space` | ❌ | ✅ | an array may not appear in a string value concatenation, with or without whitespace between them; typesafe/config silently drops suffix (lightbend/config#862) _(java: lenient)_ |
| `015-object-then-unquoted-text-without-space` | ❌ | ✅ | the same rule for an object followed directly by text; typesafe/config silently drops suffix (lightbend/config#862) _(java: lenient)_ |
| `016-text-between-arrays-is-not-dropped` | ❌ | ✅ | text between two arrays makes a concatenation of array, string and array, which is invalid; typesafe/config drops the text and concatenates the arrays (lightbend/config#862) _(java: lenient)_ |
| `017-operator-like-text-between-arrays` | ❌ | ✅ | | is ordinary unquoted text, so it sits in a concatenation between two arrays and the value is invalid; typesafe/config drops it and concatenates the arrays (lightbend/config#685, #862) _(java: lenient)_ |
| `018-line-comment-after-array` | ✅ | ✅ | a // comment after an array is not text in a concatenation; the value is just the array |
| `019-hash-comment-after-array-without-space` | ✅ | ✅ | a # comment directly after ] is a comment, not text in a concatenation |

</details>

<details>
<summary><b>substitution-fallback-to-environment</b> — 8 cases · Java 8/8 · pyhocon 7/8</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-env-fallback-for-undefined-path` | ✅ | ✅ | a substitution whose path is not defined in the configuration falls back to an environment variable of the same name |
| `002-required-substitution-resolved-from-env` | ✅ | ✅ | a required ${x} substitution that is not present in the configuration tree is searched for in the environment and resolves to the variable's value instead of being an error |
| `003-config-value-wins-over-env` | ✅ | ✅ | the environment is only searched when the substitution is not present within the configuration tree, so a value set in the configuration wins over an environment variable of the same name |
| `004-null-in-config-blocks-env-lookup` | ✅ | ❌ | setting a key to null in the configuration explicitly blocks looking that substitution up in the environment, so ${CONFORMANCE_X} resolves to null even though the variable is set |
| `005-config-lookup-is-case-sensitive` | ✅ | ✅ | the lookup is case-sensitive all the way until the env variable fallback is reached, so a lowercase key does not shadow an uppercase substitution and the environment variable is used |
| `006-empty-env-var-is-empty-string` | ✅ | ✅ | an env variable set to the empty string is kept as such, so a required substitution resolves to "" rather than being undefined |
| `007-empty-env-var-creates-optional-field` | ✅ | ✅ | an env variable set to the empty string is set to empty string rather than undefined, so an optional ${?x} substitution creates the field with "" instead of dropping it |
| `008-env-vars-always-become-strings` | ✅ | ✅ | environment variables always become a string value, so values that would parse as a number, a boolean or null in HOCON stay the strings "42", "true" and "null" |

</details>

<details>
<summary><b>substitutions</b> — 29 cases · Java 29/29 · pyhocon 26/29</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-basic-substitution` | ✅ | ✅ | the syntax ${pathexpression} refers to another part of the configuration tree |
| `002-optional-substitution-syntax` | ✅ | ✅ | ${?pathexpression} is the optional substitution syntax; when the path is defined it resolves exactly like ${pathexpression}, keeping the value and its type |
| `003-optional-substitution-whitespace-illegal` | ✅ | ✅ | the ? in ${?pathexpression} must not have whitespace before it; the three characters ${? must be exactly grouped together |
| `004-substitution-not-parsed-in-quoted-string` | ✅ | ✅ | substitutions are not parsed inside quoted strings, so this stays the literal text |
| `005-substitution-value-concatenation-unquoted` | ✅ | ✅ | worked example: to get a string containing a substitution, use value concatenation with the substitution in the unquoted portion |
| `006-substitution-value-concatenation-quoted-tail` | ✅ | ✅ | worked example: quoting the non-substitution portion also forms a value concatenation with the substitution |
| `007-substitution-path-absolute` | ✅ | ✅ | substitutions are resolved by looking up the path from the root configuration object, absolute rather than relative, so ${a} inside b finds the root a and not the sibling b.a |
| `008-substitution-forward-reference` | ✅ | ✅ | substitution processing happens as the last parsing step, so a substitution can look forward in the configuration |
| `009-substitution-latest-duplicate-key` | ✅ | ✅ | if a key has been specified more than once, a substitution referring to it always evaluates to its latest-assigned value |
| `010-substitution-latest-duplicate-key-object-merge` | ✅ | ✅ | a substitution to a key set more than once evaluates to the merged object, not an earlier snapshot |
| `011-undefined-required-substitution-is-error` | ✅ | ✅ | an undefined substitution with the ${foo} syntax is invalid and should generate an error |
| `012-undefined-optional-substitution-field-not-created` | ✅ | ✅ | if an undefined ${?foo} substitution is the value of an object field, the field should not be created |
| `013-undefined-optional-substitution-keeps-previous-value` | ✅ | ✅ | if an undefined ${?foo} would override a previously-set value for the same field, the previous value remains |
| `014-undefined-optional-substitution-array-element-not-added` | ✅ | ✅ | if an undefined ${?foo} substitution is an array element, the element should not be added |
| `015-undefined-optional-substitution-concatenation-string-empty` | ✅ | ✅ | an undefined ${?foo} in a value concatenation with another string becomes an empty string |
| `016-undefined-optional-substitution-concatenation-object-empty` | ✅ | ✅ | an undefined ${?foo} in a value concatenation with an object becomes an empty object |
| `017-undefined-optional-substitution-concatenation-array-empty` | ✅ | ✅ | an undefined ${?foo} in a value concatenation with an array becomes an empty array |
| `018-two-optional-substitutions-both-undefined-field-not-created` | ✅ | ✅ | foo : ${?bar}${?baz} avoids creating the field only if both bar and baz are undefined |
| `019-two-optional-substitutions-one-defined-field-created` | ✅ | ✅ | foo : ${?bar}${?baz} creates the field once at least one of bar or baz is defined |
| `020-substitution-not-allowed-in-key` | ✅ | ✅ | substitutions are only allowed in field values and array elements, not in keys |
| `021-substitution-not-allowed-nested-in-path-expression` | ✅ | ✅ | substitutions are not allowed nested inside other substitutions (path expressions) |
| `022-substitution-preserves-type-array` | ✅ | ✅ | a substitution is replaced with any value type; if it is the only part of a value, the type (here an array) is preserved |
| `024-substitution-concatenation-forms-string` | ✅ | ✅ | when a substitution is not the only part of a value, it is value-concatenated to form a string rather than keeping the substituted type |
| `025-substitution-preserves-type-string-booleans-null` | ✅ | ❌ | a substitution is replaced with any value type and, when it is the only part of a value, the type is preserved: here string, true, false and null stay what they were rather than becoming strings |
| `026-unterminated-substitution-is-error` | ✅ | ✅ | the syntax is ${pathexpression}: a substitution opened with ${ and never closed with } is not that syntax, and $ cannot start an unquoted string either, so it must be rejected |
| `027-null-value-blocks-environment-lookup` | ✅ | ❌ | if a configuration sets a value to null then it should not be looked up in the external source: with { HOME : null } in the root object, ${HOME} never looks at the environment variable and resolves to null; the case only bites when HOME is set in the runner's environment, which it is wherever the suite runs |
| `028-optional-substitution-to-null-value-is-defined` | ✅ | ❌ | a substitution is undefined only if it does not match any value present in the configuration, and null is among the value types a substitution is replaced with, so ${?a} with a = null is defined: the field is created with null rather than omitted |
| `029-substitution-path-quoted-element` | ✅ | ✅ | the path expression inside ${} has the same syntax you could use for an object key, so the quoted element in ${a."b.c"} names the single key b.c under a instead of a path a.b.c |
| `030-quoted-key-is-not-a-substitution` | ✅ | ✅ | substitutions are not parsed inside quoted strings, and a quoted key is a quoted string: "${a}" is the literal key ${a}, not a substitution in a key (which would be illegal) |

</details>

<details>
<summary><b>unchanged-from-json</b> — 14 cases · Java 8/14 · pyhocon 7/14</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-quoted-string-json-format` | ✅ | ❌ | quoted strings are in the same format as JSON strings, so JSON escapes like \n, \t, \", \\ and \u unicode escapes are honored |
| `002-string-value-type` | ✅ | ✅ | string is one of the possible value types |
| `003-number-value-type` | ✅ | ✅ | number is one of the possible value types |
| `004-object-value-type` | ✅ | ✅ | object is one of the possible value types |
| `005-array-value-type` | ✅ | ✅ | array is one of the possible value types |
| `006-boolean-value-type` | ✅ | ✅ | boolean is one of the possible value types |
| `007-null-value-type` | ✅ | ✅ | null is one of the possible value types |
| `008-number-format-decimal-and-exponent` | ✅ | ✅ | allowed number formats match JSON, including negative numbers, decimals, and exponent notation |
| `009-number-leading-zero-illegal` | ❌ | ❌ | allowed number formats match JSON, and JSON forbids a zero followed by further digits; the initial number character plus the valid-in-JSON number characters after it must be parsed as a number value, so the whole token 01 has to be a number and is not one, with no fallback offered. typesafe/config parses it leniently as the number 1. _(java: lenient)_ |
| `010-negative-number-without-integer-part-illegal` | ❌ | ❌ | allowed number formats match JSON, and JSON requires a digit before the decimal point, so -.33 is a number token that is not a valid number. typesafe/config releases up to 1.4.9 parse it as -0.33; upstream main since lightbend/config#861 (unreleased) reads it as the unquoted string "-.33", like .33 -- still accepted, still not the error the hyphen rule asks for _(java: lenient)_ |
| `011-negative-exponent-number-without-integer-part-illegal` | ❌ | ❌ | the same JSON rule with an exponent: -.33e+1 has no integer part. typesafe/config releases up to 1.4.9 parse it as -3.3; upstream main since lightbend/config#861 (unreleased) rejects it, on the reserved + _(java: lenient)_ |
| `012-number-with-trailing-dot-illegal` | ❌ | ❌ | JSON requires a digit after the decimal point; 1. is a number token that is not a valid number. typesafe/config reads it as 1, and lightbend/config#861 leaves it so on purpose _(java: lenient)_ |
| `013-trailing-dot-before-exponent-illegal` | ❌ | ❌ | the same rule with an exponent after the dot; typesafe/config reads it as -1000 (named out of scope in lightbend/config#861) _(java: lenient)_ |
| `014-negative-leading-zeros-illegal` | ❌ | ❌ | JSON forbids leading zeros after the minus sign as well; typesafe/config reads it as -33 (named out of scope in lightbend/config#861) _(java: lenient)_ |

</details>

<details>
<summary><b>units-format</b> — 6 cases · Java 6/6 · pyhocon 5/6</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-number-value-is-default-unit` | ✅ | ✅ | if the value is a number, it is taken to be a number in the default unit |
| `002-quoted-string-with-no-unit-uses-default-unit` | ✅ | ✅ | a string value with no unit name should be interpreted with the default unit, as if it were a number |
| `003-string-with-unit-name-specifies-interpretation` | ✅ | ❌ | a string value with a unit name has that name specify the value's interpretation |
| `004-whitespace-optional-around-number-and-unit` | ✅ | ✅ | the units-format grammar is optional whitespace, a number, optional whitespace, an optional unit name, optional whitespace |
| `005-unit-name-must-be-letters-only` | ✅ | ✅ | the unit name consists only of letters (Unicode L* categories, Java isLetter()), so a unit name with a trailing digit is not a legal units-format string |
| `006-unit-before-number-is-illegal` | ✅ | ✅ | the units-format grammar puts the number before the unit name, not after, so a unit-then-number string is not a legal units-format value |

</details>

<details>
<summary><b>unquoted-strings</b> — 18 cases · Java 17/18 · pyhocon 13/18</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-simple-unquoted-string` | ✅ | ✅ | a sequence of characters outside a quoted string is a string value when it contains none of the forbidden characters |
| `002-quoted-alternative-for-forbidden-char` | ✅ | ✅ | a quoted string may always be used as an alternative to write a character that is not permitted in an unquoted string, such as '@' |
| `003-unquoted-cannot-contain-at-sign` | ✅ | ✅ | '@' is one of the listed forbidden characters, so it cannot appear inside an unquoted string |
| `004-double-slash-starts-comment` | ✅ | ❌ | the two-character string '//' starts a comment, ending the unquoted string before it even mid-token |
| `005-single-slash-allowed` | ✅ | ✅ | only the two-character string '//' is special for comments; a lone '/' is not a forbidden character and stays part of the unquoted string |
| `006-truefoo-parses-as-true-then-foo` | ✅ | ✅ | worked example: truefoo parses as the boolean token true followed by the unquoted string foo, because its initial characters parse as true |
| `007-footrue-is-one-unquoted-string` | ✅ | ✅ | worked example: footrue does not begin with true, false, null, or a number, so it parses as a single unquoted string |
| `008-number-then-suffix-string` | ✅ | ✅ | worked example: 10.0bar is the number 10.0 followed by the unquoted string bar, since 10.0 parses as a number at the start |
| `009-digits-not-at-start-stay-string` | ✅ | ✅ | worked example: bar10.0 does not begin with a digit, so the whole thing is the single unquoted string bar10.0, not a number |
| `010-embedded-null-not-recognized` | ✅ | ✅ | embedded (non-initial) null, true, false, and numbers are not recognized as such: they are just part of the string, since only the leading characters are checked |
| `011-unquoted-cannot-contain-backslash` | ✅ | ❌ | backslash is a forbidden character, and unquoted strings support no escaping at all, so a literal backslash requires a quoted string instead |
| `012-unquoted-cannot-start-with-hyphen` | ❌ | ❌ | an unquoted string may not begin with a hyphen, and the initial number character plus any valid-in-JSON number characters that follow must be parsed as a number value -- here that is the lone '-', which is not a number. typesafe/config falls back to unquoted text and yields the string '-foo', the same leniency it shows for '1e'. _(java: lenient)_ |
| `013-negative-number-then-string` | ✅ | ✅ | a hyphen followed by digits begins number parsing (-1), after which foo continues as a separate unquoted string token, mirroring the 10.0bar example for negative numbers |
| `014-hash-starts-comment-not-forbidden-char-in-string` | ✅ | ✅ | '#' is forbidden inside an unquoted string because it already has meaning in HOCON: it starts a comment |
| `015-reserved-forbidden-char-no-current-meaning` | ✅ | ✅ | some forbidden characters, such as '!', have no meaning in HOCON today and are reserved as keywords for future extensions to the spec |
| `016-control-char-allowed-unquoted` | ✅ | ✅ | unquoted strings place no restriction on control characters, other than the forbidden characters listed |
| `017-control-char-forbidden-in-quoted` | ✅ | ❌ | quoted JSON strings may not contain control characters, per the JSON spec, unlike unquoted strings |
| `018-leading-dot-is-not-a-number` | ✅ | ❌ | only 0-9 and - begin a number, so .33 is an ordinary unquoted string -- the reading lightbend/config#861 extends to -.33 |

</details>

<details>
<summary><b>value-concatenation</b> — 4 cases · Java 4/4 · pyhocon 4/4</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-simple-values-concatenate-to-string` | ✅ | ✅ | if all the values are simple values they are concatenated into a string |
| `002-arrays-concatenate-into-one-array` | ✅ | ✅ | if all the values are arrays they are concatenated into one array |
| `003-objects-concatenate-by-merging` | ✅ | ✅ | if all the values are objects they are merged (as with duplicate keys) into one object |
| `004-string-concatenation-allowed-in-field-keys` | ✅ | ✅ | string value concatenation is allowed in field keys, in addition to field values and array elements |

</details>

<details>
<summary><b>whitespace</b> — 6 cases · Java 6/6 · pyhocon 2/6</summary>

| case | Java | pyhocon | rule |
|---|---|---|---|
| `001-nonbreaking-space-as-whitespace` | ✅ | ❌ | a nonbreaking space (0x00A0) is a Unicode Zs separator and must be treated as whitespace |
| `002-bom-at-start-is-whitespace` | ✅ | ❌ | the BOM (0xFEFF) must be treated as whitespace, not as part of the key |
| `003-unicode-line-paragraph-separator` | ✅ | ✅ | the Unicode line separator (Zl, U+2028) and paragraph separator (Zp, U+2029) count as whitespace |
| `004-vertical-tab-form-feed-whitespace` | ✅ | ❌ | vertical tab (0x000B) and form feed (0x000C) are whitespace characters |
| `005-ascii-separator-control-chars` | ✅ | ✅ | file separator (0x001C), group separator (0x001D), record separator (0x001E), and unit separator (0x001F) are whitespace characters |
| `006-special-nonbreaking-spaces` | ✅ | ❌ | the spec names figure space (0x2007) and narrow no-break space (0x202F) explicitly among the nonbreaking spaces treated as whitespace |

</details>

| 322 cases | Java<br><sub>typesafe/config 1.4.5</sub> | pyhocon<br><sub>pyhocon 0.3.63</sub> |
|---|---|---|
| **spec mode** — what HOCON requires | **89%** (287/322) | **78%** (252/322) |
| **java mode** — what typesafe/config does | 100% (321/322) | 74% (237/322) |

Cells show **spec mode**. The two differ only on the 34 rows marked `java:`. 1 rows are open questions (⚠) rather than results. The suite checks 153 of the 210 rules in its inventory — `conformance/maintaining/COVERAGE.md` lists the rest. Columns appear here because their result file is committed under `conformance/reports/`.

<!-- conformance:end -->

## Contributing

This project is developed in the open. If you need a HOCON feature that isn't
implemented yet, please open a PR — feature requests as PRs (even a failing
test showing what you need) are the fastest way to get something prioritized.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the PR workflow (draft until CI is
green).

## License

BSD 3-Clause — see [LICENSE](LICENSE).
