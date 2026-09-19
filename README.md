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
`conformance/README.md` for the file format and `conformance/PROCESS.md` for how
it is built and what it is for.

Regenerate this table with `python3 tools/conformance/report.py`; `--check` fails
instead of writing.

**Java sits at 100% by construction.** Expected values are produced by
`tools/oracle/hocon-java`, so the reference implementation can only fail a row
that a human has since corrected against the spec text. Those rows are the point
of the exercise — they are marked `java: unsupported` or `java: diverges` in the
`rule` column, and they are where HOCON says more than `typesafe/config` does.

<!-- conformance:start -->

<!-- generated by tools/conformance/report.py — do not edit by hand -->

<details open>
<summary><b>Where HOCON and typesafe/config part ways</b> — 8 rows</summary>

| input | the spec requires | Java | pyhocon | Rust |
|---|---|---|---|---|
| `[1, 2, 3]\n` | `[1, 2, 3]` | `rejects: WrongType` | `[1,2,3]` | `rejects: Unexpected token, e…` |
| `[ { a = 1 }, { b = 2 } ]\n` | `[{"a": 1}, {"b": 2}]` | `rejects: WrongType` | `[{"a":1},{"b":2}]` | `rejects: Unexpected token, e…` |
| `[]\n` | `[]` | `rejects: WrongType` | `[]` | `rejects: Unexpected token, e…` |
| `# a leading comment\n[1, 2]\n` | `[1, 2]` | `rejects: WrongType` | `[1,2]` | `rejects: Unexpected token, e…` |
| `\n[1, 2]\n` | `[1, 2]` | `rejects: WrongType` | `[1,2]` | `rejects: Unexpected token, e…` |
| `include.foo : 42\n` | rejects | `{"include":{"foo":42}}` | `{"include":{"foo":42}}` | `rejects: Unexpected token, e…` |
| `a = 01\n` | rejects | `{"a":1}` | `{"a":1}` | `{"a":"01"}` |
| `a = -foo\n` | rejects | `{"a":"-foo"}` | `{"a":"-foo"}` | `{"a":"-foo"}` |

Each column is what that implementation actually returns. The spec column is the bar; Java's column is, by definition, the other bar.

</details>

<details>
<summary><b>array-and-object-concatenation</b> — 13 cases · Java 13/13 · pyhocon 13/13 · Rust 13/13</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-arrays-concatenate` | ✅ | ✅ | ✅ | arrays can be concatenated with arrays when only non-newline whitespace separates them |
| `002-objects-concatenate` | ✅ | ✅ | ✅ | objects can be concatenated with objects when only non-newline whitespace separates them |
| `003-mixing-array-and-object-is-error` | ✅ | ✅ | ✅ | it is an error to concatenate an array with an object |
| `004-substitution-counts-as-array-for-concatenation` | ✅ | ✅ | ✅ | for concatenation purposes, a substitution that resolves to an array also counts as an array |
| `005-substitution-counts-as-object-for-concatenation` | ✅ | ✅ | ✅ | for concatenation purposes, a substitution that resolves to an object also counts as an object |
| `006-newline-between-values-prevents-concatenation` | ✅ | ✅ | ✅ | a newline between two values prevents concatenation, unlike non-newline whitespace |
| `007-object-concatenation-merges-and-second-overrides` | ✅ | ✅ | ✅ | for objects, concatenation means merging, and the second object overrides the first on overlapping keys |
| `008-array-cannot-be-field-key` | ✅ | ✅ | ✅ | arrays cannot be field keys, whether concatenation is involved or not |
| `009-object-cannot-be-field-key` | ✅ | ✅ | ✅ | objects cannot be field keys, whether concatenation is involved or not |
| `010-worked-example-object-inheritance` | ✅ | ✅ | ✅ | the spec's worked example: object concatenation with a substitution is a common way to express inheritance |
| `011-worked-example-array-path-append` | ✅ | ✅ | ✅ | the spec's worked example: array concatenation with a substitution is a common way to add to paths |
| `012-worked-example-self-referential-array-concat` | ✅ | ✅ | ✅ | the spec's worked example: a later array definition can concatenate a substitution referring to its own earlier value with a new array |
| `013-newlines-within-value-still-allow-concatenation` | ✅ | ✅ | ✅ | newlines may occur within an array without preventing it from concatenating with a second array on the same line as its closing bracket |

</details>

<details>
<summary><b>arrays-without-commas-or-newlines</b> — 7 cases · Java 7/7 · pyhocon 7/7 · Rust 7/7</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-newlines-instead-of-commas` | ✅ | ✅ | ✅ | arrays allow newlines to separate elements instead of commas |
| `002-whitespace-instead-of-comma-concatenates-into-one-element` | ✅ | ✅ | ✅ | the spec's worked example: non-newline whitespace instead of a comma produces concatenation, so this array has one element, the string 1 2 3 4, not four integers |
| `003-newline-separates-two-arrays-into-elements` | ✅ | ✅ | ✅ | the spec's worked example: a newline between two bracketed arrays makes them two separate elements |
| `004-same-line-whitespace-concatenates-two-arrays-into-one-element` | ✅ | ✅ | ✅ | the spec's worked example: whitespace on the same line between two bracketed arrays concatenates them into a single element, the array [1, 2, 3, 4] |
| `005-unquoted-string-concatenation-with-substitutions-in-array` | ✅ | ✅ | ✅ | the spec's worked example: whitespace-separated unquoted tokens and substitutions concatenate into one array element per comma-separated group |
| `006-two-elements-each-a-substitution-concatenation` | ✅ | ✅ | ✅ | the spec's worked example: commas separate elements while whitespace within a comma-separated group concatenates substitutions together |
| `007-whitespace-never-separates-fields` | ✅ | ✅ | ✅ | non-newline whitespace is never a field separator, so two field definitions cannot be written on one line separated only by spaces |

</details>

<details>
<summary><b>commas</b> — 8 cases · Java 8/8 · pyhocon 4/8 · Rust 8/8</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-array-trailing-comma` | ✅ | ✅ | ✅ | the last element in an array may be followed by a single comma, which is ignored: [1,2,3,] and [1,2,3] are the same array |
| `002-array-newline-no-comma` | ✅ | ✅ | ✅ | array elements need not have a comma between them as long as an ASCII newline separates them: [1\n2\n3] and [1,2,3] are the same array |
| `003-array-double-trailing-comma-invalid` | ✅ | ❌ | ✅ | [1,2,3,,] is explicitly called invalid because it has two trailing commas |
| `004-array-initial-comma-invalid` | ✅ | ❌ | ✅ | [,1,2,3] is explicitly called invalid because it has an initial comma |
| `005-array-double-comma-invalid` | ✅ | ❌ | ✅ | [1,,2,3] is explicitly called invalid because it has two commas in a row |
| `006-object-trailing-comma` | ✅ | ✅ | ✅ | these same comma rules apply to fields in objects, so a single trailing comma after the last field is ignored |
| `007-object-newline-no-comma` | ✅ | ✅ | ✅ | fields in objects need not have a comma between them as long as an ASCII newline separates them, same as array elements |
| `008-object-double-comma-invalid` | ✅ | ❌ | ✅ | these same comma rules apply to fields in objects, so two commas in a row between fields is invalid just as in an array |

</details>

<details>
<summary><b>comments</b> — 6 cases · Java 6/6 · pyhocon 6/6 · Rust 6/6</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-hash-comment` | ✅ | ✅ | ✅ | anything between # and the next newline is a comment and ignored |
| `002-double-slash-comment` | ✅ | ✅ | ✅ | anything between // and the next newline is a comment and ignored |
| `003-whole-line-comment` | ✅ | ✅ | ✅ | a comment may occupy an entire line by itself, ignored just like a trailing one |
| `004-comment-stops-at-newline` | ✅ | ✅ | ✅ | a comment runs only to the next newline, so the following line is parsed normally |
| `005-hash-inside-quoted-string-is-not-a-comment` | ✅ | ✅ | ✅ | a # inside a quoted string is not treated as starting a comment |
| `006-double-slash-inside-quoted-string-is-not-a-comment` | ✅ | ✅ | ✅ | a // inside a quoted string is not treated as starting a comment |

</details>

<details>
<summary><b>concatenation-whitespace-and-substitutions</b> — 2 cases · Java 2/2 · pyhocon 2/2 · Rust 2/2</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-unquoted-whitespace-between-substitutions-is-significant-for-strings` | ✅ | ✅ | ✅ | when substitutions resolve to strings, unquoted whitespace between them is significant and becomes part of the concatenated value |
| `002-quoted-whitespace-between-substitutions-is-error` | ✅ | ✅ | ✅ | quoted whitespace between substitutions should be an error, unlike unquoted whitespace which is merely ignored or preserved |

</details>

<details>
<summary><b>duplicate-keys-and-object-merging</b> — 6 cases · Java 6/6 · pyhocon 5/6 · Rust 6/6</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-later-scalar-wins` | ✅ | ✅ | ✅ | for a non-object value the later assignment simply replaces the earlier one |
| `002-objects-merge` | ✅ | ✅ | ✅ | two objects under the same key merge key-by-key, they do not replace |
| `003-scalar-breaks-the-merge` | ✅ | ❌ | ✅ | a non-object in between discards the earlier object, so the last object merges into nothing |
| `004-merge-scalar-field-later-wins` | ✅ | ✅ | ✅ | for a non-object-valued field present in both merged objects, the field from the second object is used |
| `005-merge-nested-object-recursive` | ✅ | ✅ | ✅ | for an object-valued field present in both objects, the object values are recursively merged by the same rules |
| `006-null-prevents-merge` | ✅ | ✅ | ✅ | setting a key to null between two object assignments prevents the merge, since a non-object always wins over an object it borders |

</details>

<details>
<summary><b>duration-format</b> — 9 cases · Java 9/9 · pyhocon 2/9 · Rust 9/9</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-bare-number-is-milliseconds` | ✅ | ✅ | ✅ | bare numbers are taken to be in milliseconds already |
| `002-uppercase-unit-is-illegal` | ✅ | ✅ | ✅ | the supported unit strings for duration are case-sensitive and must be lowercase, so an uppercase unit is not one of the supported strings |
| `003-nanoseconds-spellings` | ✅ | ❌ | ✅ | exactly ns, nano, nanos, nanosecond, nanoseconds are the supported unit strings for nanoseconds |
| `004-microseconds-spellings` | ✅ | ❌ | ✅ | exactly us, micro, micros, microsecond, microseconds are the supported unit strings for microseconds |
| `005-milliseconds-spellings` | ✅ | ❌ | ✅ | exactly ms, milli, millis, millisecond, milliseconds are the supported unit strings for milliseconds |
| `006-seconds-spellings` | ✅ | ❌ | ✅ | exactly s, second, seconds are the supported unit strings for seconds |
| `007-minutes-spellings` | ✅ | ❌ | ✅ | exactly m, minute, minutes are the supported unit strings for minutes |
| `008-hours-spellings` | ✅ | ❌ | ✅ | exactly h, hour, hours are the supported unit strings for hours |
| `009-days-spellings` | ✅ | ❌ | ✅ | exactly d, day, days are the supported unit strings for days in the duration format |

</details>

<details>
<summary><b>key-value-separator</b> — 3 cases · Java 3/3 · pyhocon 3/3 · Rust 3/3</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-equals-as-separator` | ✅ | ✅ | ✅ | the = character can be used anywhere JSON allows :, to separate keys from values |
| `002-omitted-separator-before-object` | ✅ | ✅ | ✅ | if a key is followed by {, the : or = may be omitted; the spec's own example is "foo" {} meaning "foo" : {} |
| `003-omitted-separator-unquoted-key` | ✅ | ✅ | ✅ | the separator-omission rule before { applies to unquoted keys too, not just the quoted example in the spec |

</details>

<details>
<summary><b>multi-line-strings</b> — 7 cases · Java 7/7 · pyhocon 7/7 · Rust 5/7</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-basic-triple-quote` | ✅ | ✅ | ✅ | the three-character sequence """ starts a multi-line string whose unicode characters are used unmodified to create the string value |
| `002-newlines-and-whitespace-preserved` | ✅ | ✅ | ✅ | newlines and whitespace inside a multi-line string receive no special treatment and are kept in the value |
| `003-unicode-escape-not-interpreted` | ✅ | ✅ | ✅ | unlike JSON quoted strings, unicode escapes are not interpreted in triple-quoted strings, so \u0041 stays literal rather than becoming A |
| `004-extra-quote-becomes-part-of-string` | ✅ | ✅ | ❌ | any sequence of at least three quotes ends the multi-line string and any extra quotes are part of the string, so HOCON works like Scala's four-character string foo" rather than Python's syntax error |
| `005-five-closing-quotes-two-extra` | ✅ | ✅ | ❌ | a closing run of five quotes still only needs three to end the string, so both extra quotes are appended to the string value |
| `006-unterminated-is-illegal` | ✅ | ✅ | ✅ | a multi-line string opened with a three-character quote sequence that never reaches a closing """ is not a legal value |
| `007-fewer-than-three-quotes-does-not-close` | ✅ | ✅ | ✅ | only a run of at least three quote characters ends the multi-line string, so the single embedded quote pairs around hi do not terminate it early |

</details>

<details>
<summary><b>numerically-indexed-objects-to-arrays</b> — 8 cases · Java 8/8 · pyhocon 4/8 · Rust 4/8</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-object-with-numeric-keys-stays-object` | ✅ | ✅ | ✅ | the conversion should be done lazily when required to avoid a type error, not eagerly anytime an object has numeric keys, so a bare object with numeric keys stays an object |
| `002-properties-style-dotted-numeric-keys` | ✅ | ✅ | ✅ | worked example: foo.0 = "a", foo.1 = "b" is the properties-file idiom the spec says implementations should support converting to an array |
| `003-concatenation-converts-numeric-object-to-array` | ✅ | ❌ | ❌ | the conversion should be done in a concatenation when a list is expected and an object with numeric keys is found, so the trailing object concatenates onto the array as elements x, y |
| `004-concatenation-ignores-non-integer-keys` | ✅ | ❌ | ❌ | the conversion should ignore any keys which do not parse as positive integers, so key "foo" is dropped and only "0" contributes to the resulting array |
| `005-empty-object-concatenation-not-converted` | ✅ | ✅ | ✅ | the conversion should not occur if the object is empty, so an empty object cannot satisfy a list-expected concatenation and this is illegal |
| `006-object-without-integer-keys-not-converted` | ✅ | ✅ | ✅ | the conversion should not occur if the object has no keys which parse as positive integers, so this object cannot satisfy a list-expected concatenation and this is illegal |
| `007-sparse-integer-keys-sorted-and-reindexed` | ✅ | ❌ | ❌ | the conversion should sort by the integer value of each key and then build the array; missing indices such as "1" are eliminated rather than left as gaps, so keys "0" and "2" become a two-element array |
| `008-negative-key-ignored-in-conversion` | ✅ | ❌ | ❌ | the conversion ignores any keys which do not parse as positive integers, and "-1" is not a positive integer, so it is dropped and only key "0" contributes |

</details>

<details>
<summary><b>omit-root-braces</b> — 11 cases · Java 5/11 · pyhocon 10/11 · Rust 5/11</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-implicit-root-object` | ✅ | ✅ | ✅ | if the file does not begin with [ or {, it is parsed as if enclosed with {} curly braces |
| `002-explicit-root-object-unaffected` | ✅ | ✅ | ✅ | the implicit-wrap rule only applies when the file does not begin with [ or {; a file already beginning with { is parsed as ordinary JSON-style object |
| `003-missing-open-brace-with-close-brace-illegal` | ✅ | ✅ | ✅ | a HOCON file is invalid if it omits the opening { but still has a closing }, since the curly braces must be balanced |
| `004-empty-file` | ✅ | ✅ | ✅ | in plain JSON empty files are invalid documents; this case checks whether HOCON's implicit-brace wrapping (the file does not begin with [ or {) extends to an empty file as well |
| `005-bare-string-root-illegal` | ✅ | ✅ | ✅ | a JSON document containing only a non-array non-object value such as a string is invalid, and wrapping such content in {} does not produce a valid object body either |
| `006-array-root-unaffected` | ❌ | ✅ | ❌ | the implicit {} wrap fires only when the file does not begin with a square bracket or curly brace, so a file starting with [ keeps its array root; the include section says so outright -- 'both JSON and HOCON allow arrays as root values in a document' (the reason an included file may not be one). typesafe/config has no array-rooted config at all and rejects the document as LIST rather than object. _(java: unsupported)_ |
| `007-array-root-of-objects` | ❌ | ✅ | ❌ | a file beginning with a square bracket keeps its array root whatever the elements are; typesafe/config parses it and then refuses it at the API, having no array-rooted config _(java: unsupported)_ |
| `008-empty-array-root` | ❌ | ✅ | ❌ | an empty array is still an array root, and the wrap rule looks at the opening bracket, not at whether the document has content _(java: unsupported)_ |
| `009-comment-before-array-root` | ❌ | ✅ | ❌ | the {} wrap fires only for a file that does not begin with a bracket or brace, and a leading comment does not make it one -- both typesafe/config and pyhocon read the first token, not the first byte. the spec's wording is loose here; this row records the consensus reading _(java: unsupported)_ |
| `010-blank-line-before-array-root` | ❌ | ✅ | ❌ | leading whitespace does not trigger the {} wrap either, for the same reason as a leading comment _(java: unsupported)_ |
| `011-trailing-array-after-root-array` | ⚠ | ⚠ | ⚠ | two arrays side by side concatenate when only non-newline whitespace separates them, which would make this document [1,2,3]; but nothing in the spec says a root value may be a concatenation, and typesafe/config calls the second bracket a trailing token. pyhocon rejects it too, with a different error **⚠ oracle rejected this — illegal per spec, or unsupported by java?** |

</details>

<details>
<summary><b>path-expressions</b> — 15 cases · Java 15/15 · pyhocon 9/15 · Rust 14/15</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-quoted-dot-has-no-meaning` | ✅ | ✅ | ✅ | a dot inside a quoted string has no special meaning as a path separator, so a quoted "a.b" key is a single-element path |
| `002-mixed-quoted-and-unquoted-path` | ✅ | ❌ | ✅ | foo.bar."hello.world" is a path with three elements: foo, bar, and hello.world, since unquoted dots are path separators but a quoted dot is not |
| `003-number-then-unquoted-string` | ✅ | ✅ | ✅ | 10.0foo is a number then unquoted string foo, giving the two-element path 10 and 0foo, because a dot inside a number still counts as a path separator |
| `004-unquoted-string-with-dot` | ✅ | ✅ | ✅ | foo10.0 is an unquoted string with a dot in it, giving the two-element path foo10 and 0 |
| `005-unquoted-concatenated-with-quoted-number` | ✅ | ❌ | ❌ | foo followed by quoted "10.0" is an unquoted then a quoted string which concatenate, giving a single-element path |
| `006-all-numeric-path` | ✅ | ✅ | ✅ | 1.2.3 is the three-element path with elements 1, 2, 3 |
| `007-path-expression-always-a-string` | ✅ | ✅ | ✅ | a path expression is always converted to a string, so the key true becomes the string true rather than a boolean |
| `008-value-concatenation-keeps-boolean` | ✅ | ✅ | ✅ | unlike a path expression, a value consisting of the single value true is a value concatenation and retains its character as a boolean |
| `009-empty-path-element-quoted-is-valid` | ✅ | ❌ | ✅ | a path element that is an empty string must be quoted; a."".b is a valid three-element path whose middle element is the empty string |
| `010-consecutive-dots-invalid` | ✅ | ❌ | ✅ | an unquoted empty path element is invalid, so a..b must generate an error |
| `011-path-starting-with-dot-invalid` | ✅ | ❌ | ✅ | a path that starts with a dot is invalid and should generate an error |
| `012-path-ending-with-dot-invalid` | ✅ | ❌ | ✅ | a path that ends with a dot is invalid and should generate an error |
| `013-substitution-in-key-invalid` | ✅ | ✅ | ✅ | path expressions may not contain substitutions, so a substitution used as a key is illegal |
| `014-nested-substitution-invalid` | ✅ | ✅ | ✅ | you cannot nest substitutions inside other substitutions |
| `015-dotted-path-in-substitution` | ✅ | ✅ | ✅ | path expressions appear in substitutions like ${foo.bar}, where the unquoted dot separates foo and bar into two path elements |

</details>

<details>
<summary><b>paths-as-keys</b> — 8 cases · Java 7/8 · pyhocon 7/8 · Rust 7/8</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-two-element-path-expands` | ✅ | ✅ | ✅ | a key that is a multi-element path expands to a nested object per element, the last element combined with the value becomes a field in the most-nested object: foo.bar:42 is equivalent to foo{bar:42} |
| `002-three-element-path-expands` | ✅ | ✅ | ✅ | a three-element path key expands through two levels of nesting: foo.bar.baz:42 is equivalent to foo{bar{baz:42}} |
| `003-merge-sibling-paths` | ✅ | ✅ | ✅ | the objects created by expanding path keys are merged in the usual way, so a.x:42, a.y:43 is equivalent to a{x:42,y:43} |
| `004-whitespace-in-key` | ✅ | ✅ | ❌ | because path expressions work like value concatenations, whitespace is allowed in keys: a b c:42 is equivalent to "a b c":42 |
| `005-unquoted-true-key-becomes-string` | ✅ | ✅ | ✅ | path expressions are always converted to strings, so the unquoted boolean-looking key true:42 is "true":42 |
| `006-unquoted-number-key-becomes-string` | ✅ | ✅ | ✅ | path expressions are always converted to strings, so the unquoted numeric key 3:42 is "3":42 |
| `007-decimal-key-splits-on-dot` | ✅ | ✅ | ✅ | a dot in an unquoted key is a path separator even when it looks like a decimal number, so 3.14:42 is "3":{"14":42} |
| `008-include-cannot-begin-key` | ❌ | ❌ | ✅ | the unquoted string include may not begin a path expression in a key, and where an object key would be expected include is not read as a key at all -- what follows it must be a quoted string. typesafe/config accepts the key as the path include.foo, and is inconsistent with itself here: it rejects 'include = 42' with the very same rule. _(java: lenient)_ |

</details>

<details>
<summary><b>period-format</b> — 7 cases · Java 7/7 · pyhocon 3/7 · Rust 7/7</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-bare-number-is-days` | ✅ | ✅ | ✅ | for getPeriod(), bare numbers are taken to be in days, unlike getDuration() where bare numbers are milliseconds |
| `002-uppercase-unit-is-illegal` | ✅ | ✅ | ✅ | the supported unit strings for period are case-sensitive and must be lowercase, so an uppercase unit is not one of the supported strings |
| `003-days-spellings` | ✅ | ❌ | ✅ | exactly d, day, days are the supported unit strings for days in the period format |
| `004-weeks-spellings` | ✅ | ❌ | ✅ | exactly w, week, weeks are the supported unit strings for weeks |
| `005-months-spellings` | ✅ | ❌ | ✅ | exactly m, mo, month, months are the supported unit strings for months |
| `006-years-spellings` | ✅ | ✅ | ✅ | exactly y, year, years are the supported unit strings for years |
| `007-month-m-ambiguous-with-duration-minutes` | ✅ | ❌ | ✅ | the spec notes that getTemporal() callers should prefer mo over m for months, since m is also the duration unit for minutes and getTemporal() may return either a Duration or a Period |

</details>

<details>
<summary><b>plus-equals-field-separator</b> — 3 cases · Java 3/3 · pyhocon 0/3 · Rust 3/3</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-plus-equals-desugars-to-optional-self-ref-array` | ✅ | ❌ | ✅ | a += b transforms into a = ${?a} [b], and because the fallback is optional (${?a} not ${a}) this is legal even as the first mention of a in the file |
| `002-plus-equals-appends-to-existing-array` | ✅ | ❌ | ✅ | += appends an element to a previous array |
| `003-plus-equals-errors-on-non-array-previous-value` | ✅ | ❌ | ✅ | if the previous value was not an array, += results in an error just as the long form a = ${?a} [b] would with a non-array a |

</details>

<details>
<summary><b>self-referential-examples</b> — 14 cases · Java 14/14 · pyhocon 14/14 · Rust 11/14</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-isolated-self-reference-is-an-error` | ✅ | ✅ | ✅ | in isolation, with no merges involved, a self-referential field is an error because the substitution cannot be resolved |
| `002-self-reference-resolves-to-earlier-merged-value` | ✅ | ✅ | ✅ | when foo:${foo} is merged with an earlier value for foo, the self-reference resolves to that overridden value, so foo ends up { a : 1 } |
| `003-self-reference-before-any-value-is-undefined` | ✅ | ✅ | ✅ | if the self-referential foo:${foo} comes before foo has any value, the reference is undefined, exactly as if it named a path not found in the document, so it is an error even though foo is given a value afterward |
| `004-optional-self-reference-disappears-silently` | ✅ | ✅ | ✅ | because the self-reference error is treated as undefined rather than an intractable cycle, the optional syntax foo:${?foo} makes the field disappear silently instead of erroring |
| `005-substitution-hidden-by-later-non-mergeable-value-is-never-evaluated` | ✅ | ✅ | ❌ | if a substitution is hidden by a later non-object value that could not be merged with it, it is never evaluated and no error is reported, no matter what it would have resolved to; foo ends up 42 |
| `006-self-reference-cycle-ignored-when-overridden-by-literal` | ✅ | ✅ | ❌ | the same hiding rule applies to a self-reference cycle: once overridden by a non-mergeable literal, the initial foo:${foo} must simply be ignored, so foo ends up 42 with no error |
| `007-self-reference-in-path-expression-resolves-to-value-below` | ✅ | ✅ | ❌ | a self-reference resolves to the value below it even as part of a path expression, so ${foo.a} refers to { c : 1 } rather than 2, and the final merge is { a : 2, c : 1 } |
| `008-object-may-refer-to-sibling-path-within-itself` | ✅ | ✅ | ✅ | an implementation must allow an object to refer to a path within itself without treating it as a cycle, by resolving only the referenced field rather than recursing the whole enclosing object; bar.baz ends up 42 |
| `009-non-cycling-reference-looks-forward-across-merge` | ✅ | ✅ | ✅ | because there is no inherent cycle here, the substitution must look forward including the field's own later merges, so bar.baz ends up 43 once foo is overridden to 43 |
| `010-mutually-referring-objects-are-not-self-referential` | ✅ | ✅ | ✅ | mutually-referring objects should work and are not self-referential, so they look forward: bar.a ends up 4 and foo.c ends up 3 |
| `011-optional-self-reference-in-concatenation-looks-back` | ✅ | ✅ | ✅ | an optional self-reference in a value concatenation has to look back to an undefined a, so a ends up "foo" rather than "foofoo" |
| `012-mutual-non-self-cycle-is-unresolvable` | ✅ | ✅ | ✅ | the spec gives bar:${foo}, foo:${bar} as an example that is not possible to resolve, since neither lazy evaluation nor looking backward breaks the cycle and neither field is optional |
| `013-multi-step-cycle-is-invalid` | ✅ | ✅ | ✅ | a multi-step loop across three fields (a:${b}, b:${c}, c:${a}) must also be detected as invalid, not just a direct two-field cycle |
| `014-order-dependent-resolution-must-agree-on-one-value` | ✅ | ✅ | ✅ | this case has undefined behavior depending on resolution order: implementations are allowed to set both a and b to 1, both to 2, or to error, but must set both to the same value because substitutions are memoized by instance, so a and b must never diverge (e.g. a=1,b=2 is not permitted) |

</details>

<details>
<summary><b>self-referential-substitutions</b> — 6 cases · Java 6/6 · pyhocon 6/6 · Rust 6/6</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-path-builds-on-older-value` | ✅ | ✅ | ✅ | a field may look up its own older value before being overridden with a new value based on it, letting path:${path}":d" extend the earlier path:"a:b:c" |
| `002-self-referential-concatenation` | ✅ | ✅ | ✅ | a value concatenation containing a substitution that refers to the field being defined is self-referential, as the spec lists a:${a}bc among the examples |
| `003-object-containing-self-reference-is-not-self-referential` | ✅ | ✅ | ✅ | an object with a substitution inside it is not considered self-referential for this purpose, so a:{b:${a}} is an unbreakable cycle that must generate an error |
| `004-array-containing-self-reference-is-not-self-referential` | ✅ | ✅ | ✅ | an array with a substitution inside it is not considered self-referential for this purpose, so a:[${a}] is an unbreakable cycle that must generate an error |
| `005-optional-self-reference-resolves-as-missing` | ✅ | ✅ | ✅ | cycles are treated the same as a missing value when resolving an optional substitution, so if ${?a} refers to itself it is as if it referred to a nonexistent value |
| `006-self-referential-array-concatenation` | ✅ | ✅ | ✅ | the spec lists path:${path} [ /usr/bin ] among the examples of self-referential fields: a value concatenation of a substitution with an array literal is still self-referential |

</details>

<details>
<summary><b>size-in-bytes-format</b> — 20 cases · Java 20/20 · pyhocon 19/20 · Rust 20/20</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-bare-number-is-bytes` | ✅ | ✅ | ✅ | bare numbers are taken to be in bytes already |
| `002-single-byte-spellings` | ✅ | ✅ | ✅ | for single bytes, exactly B, b, byte, bytes are supported |
| `003-kilobytes-spellings` | ✅ | ✅ | ✅ | for powers of ten, exactly kB, kilobyte, kilobytes are the supported unit strings |
| `004-megabytes-spellings` | ✅ | ✅ | ✅ | for powers of ten, exactly MB, megabyte, megabytes are the supported unit strings |
| `005-gigabytes-spellings` | ✅ | ✅ | ✅ | for powers of ten, exactly GB, gigabyte, gigabytes are the supported unit strings |
| `006-terabytes-spellings` | ✅ | ✅ | ✅ | for powers of ten, exactly TB, terabyte, terabytes are the supported unit strings |
| `007-petabytes-spellings` | ✅ | ✅ | ✅ | for powers of ten, exactly PB, petabyte, petabytes are the supported unit strings |
| `008-exabytes-spellings` | ✅ | ✅ | ✅ | for powers of ten, exactly EB, exabyte, exabytes are the supported unit strings |
| `009-zettabytes-spellings` | ✅ | ✅ | ✅ | for powers of ten, exactly ZB, zettabyte, zettabytes are the supported unit strings |
| `010-yottabytes-spellings` | ✅ | ✅ | ✅ | for powers of ten, exactly YB, yottabyte, yottabytes are the supported unit strings |
| `011-kibibytes-spellings` | ✅ | ✅ | ✅ | for powers of two, exactly K, k, Ki, KiB, kibibyte, kibibytes are the supported unit strings (including both upper- and lower-case single-letter forms, since one-letter unit strings may be uppercase) |
| `012-mebibytes-spellings` | ✅ | ❌ | ✅ | for powers of two, exactly M, m, Mi, MiB, mebibyte, mebibytes are the supported unit strings (including both upper- and lower-case single-letter forms, since one-letter unit strings may be uppercase) |
| `013-gibibytes-spellings` | ✅ | ✅ | ✅ | for powers of two, exactly G, g, Gi, GiB, gibibyte, gibibytes are the supported unit strings (including both upper- and lower-case single-letter forms, since one-letter unit strings may be uppercase) |
| `014-tebibytes-spellings` | ✅ | ✅ | ✅ | for powers of two, exactly T, t, Ti, TiB, tebibyte, tebibytes are the supported unit strings (including both upper- and lower-case single-letter forms, since one-letter unit strings may be uppercase) |
| `015-pebibytes-spellings` | ✅ | ✅ | ✅ | for powers of two, exactly P, p, Pi, PiB, pebibyte, pebibytes are the supported unit strings (including both upper- and lower-case single-letter forms, since one-letter unit strings may be uppercase) |
| `016-exbibytes-spellings` | ✅ | ✅ | ✅ | for powers of two, exactly E, e, Ei, EiB, exbibyte, exbibytes are the supported unit strings (including both upper- and lower-case single-letter forms, since one-letter unit strings may be uppercase) |
| `017-zebibytes-spellings` | ✅ | ✅ | ✅ | for powers of two, exactly Z, z, Zi, ZiB, zebibyte, zebibytes are the supported unit strings (including both upper- and lower-case single-letter forms, since one-letter unit strings may be uppercase) |
| `018-yobibytes-spellings` | ✅ | ✅ | ✅ | for powers of two, exactly Y, y, Yi, YiB, yobibyte, yobibytes are the supported unit strings (including both upper- and lower-case single-letter forms, since one-letter unit strings may be uppercase) |
| `019-single-letter-abbreviation-means-powers-of-two` | ✅ | ✅ | ✅ | the single-letter abbreviations (like K) are ambiguous between powers of two and ten, and this spec follows the java -Xmx / GNU-tools precedent of mapping them to powers of two |
| `020-multiletter-unit-wrong-case-is-illegal` | ✅ | ✅ | ✅ | multi-letter size units must match the listed spelling exactly (kB for kilobytes), so a differently-cased multi-letter unit like Kb is not one of the supported strings, unlike the one-letter forms which may be uppercase |

</details>

<details>
<summary><b>string-value-concatenation</b> — 9 cases · Java 9/9 · pyhocon 7/9 · Rust 9/9</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-substitution-in-string-concatenation` | ✅ | ✅ | ✅ | string value concatenation supports substitutions inside the concatenated string |
| `002-only-simple-values-participate` | ✅ | ✅ | ✅ | it is invalid for arrays or objects to appear in a string value concatenation, since only simple values participate |
| `003-leading-and-trailing-whitespace-trimmed` | ✅ | ✅ | ✅ | whitespace before the first and after the last simple value is discarded, but whitespace between simple values is preserved |
| `004-concatenation-never-spans-newline` | ✅ | ✅ | ✅ | string value concatenations never span a newline, so a bare word on the following line is not appended to the value above it |
| `005-array-element-string-concatenation` | ✅ | ✅ | ✅ | a string value concatenation may appear in any place a string may appear, including array elements |
| `006-boolean-becomes-string-in-concatenation` | ✅ | ❌ | ✅ | true and false become the strings "true" and "false" when they participate in a concatenation |
| `007-null-becomes-string-in-concatenation` | ✅ | ❌ | ✅ | null becomes the string "null" when it participates in a concatenation |
| `008-number-kept-as-written-in-concatenation` | ✅ | ✅ | ✅ | numbers should be kept as they were originally written in the file when they participate in a concatenation, not renormalized |
| `009-single-boolean-not-converted-to-string` | ✅ | ✅ | ✅ | a single value is never converted to a string; true by itself must be parsed as a boolean-typed value, not a string |

</details>

<details>
<summary><b>substitutions</b> — 24 cases · Java 24/24 · pyhocon 24/24 · Rust 22/24</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-basic-substitution` | ✅ | ✅ | ✅ | the syntax ${pathexpression} refers to another part of the configuration tree |
| `002-optional-substitution-syntax` | ✅ | ✅ | ✅ | ${?pathexpression} is the optional substitution syntax, distinct from the required form |
| `003-optional-substitution-whitespace-illegal` | ✅ | ✅ | ✅ | the ? in ${?pathexpression} must not have whitespace before it; the three characters ${? must be exactly grouped together |
| `004-substitution-not-parsed-in-quoted-string` | ✅ | ✅ | ✅ | substitutions are not parsed inside quoted strings, so this stays the literal text |
| `005-substitution-value-concatenation-unquoted` | ✅ | ✅ | ✅ | worked example: to get a string containing a substitution, use value concatenation with the substitution in the unquoted portion |
| `006-substitution-value-concatenation-quoted-tail` | ✅ | ✅ | ✅ | worked example: quoting the non-substitution portion also forms a value concatenation with the substitution |
| `007-substitution-path-absolute` | ✅ | ✅ | ✅ | substitutions are resolved by looking up the path from the root configuration object, absolute rather than relative to where the substitution appears |
| `008-substitution-forward-reference` | ✅ | ✅ | ✅ | substitution processing happens as the last parsing step, so a substitution can look forward in the configuration |
| `009-substitution-latest-duplicate-key` | ✅ | ✅ | ✅ | if a key has been specified more than once, a substitution referring to it always evaluates to its latest-assigned value |
| `010-substitution-latest-duplicate-key-object-merge` | ✅ | ✅ | ✅ | a substitution to a key set more than once evaluates to the merged object, not an earlier snapshot |
| `011-undefined-required-substitution-is-error` | ✅ | ✅ | ✅ | an undefined substitution with the ${foo} syntax is invalid and should generate an error |
| `012-undefined-optional-substitution-field-not-created` | ✅ | ✅ | ✅ | if an undefined ${?foo} substitution is the value of an object field, the field should not be created |
| `013-undefined-optional-substitution-keeps-previous-value` | ✅ | ✅ | ❌ | if an undefined ${?foo} would override a previously-set value for the same field, the previous value remains |
| `014-undefined-optional-substitution-array-element-not-added` | ✅ | ✅ | ❌ | if an undefined ${?foo} substitution is an array element, the element should not be added |
| `015-undefined-optional-substitution-concatenation-string-empty` | ✅ | ✅ | ✅ | an undefined ${?foo} in a value concatenation with another string becomes an empty string |
| `016-undefined-optional-substitution-concatenation-object-empty` | ✅ | ✅ | ✅ | an undefined ${?foo} in a value concatenation with an object becomes an empty object |
| `017-undefined-optional-substitution-concatenation-array-empty` | ✅ | ✅ | ✅ | an undefined ${?foo} in a value concatenation with an array becomes an empty array |
| `018-two-optional-substitutions-both-undefined-field-not-created` | ✅ | ✅ | ✅ | foo : ${?bar}${?baz} avoids creating the field only if both bar and baz are undefined |
| `019-two-optional-substitutions-one-defined-field-created` | ✅ | ✅ | ✅ | foo : ${?bar}${?baz} creates the field once at least one of bar or baz is defined |
| `020-substitution-not-allowed-in-key` | ✅ | ✅ | ✅ | substitutions are only allowed in field values and array elements, not in keys |
| `021-substitution-not-allowed-nested-in-path-expression` | ✅ | ✅ | ✅ | substitutions are not allowed nested inside other substitutions (path expressions) |
| `022-substitution-preserves-type-array` | ✅ | ✅ | ✅ | a substitution is replaced with any value type; if it is the only part of a value, the type (here an array) is preserved |
| `023-substitution-preserves-type-number` | ✅ | ✅ | ✅ | a substitution is replaced with any value type; if it is the only part of a value, the type (here a number) is preserved |
| `024-substitution-concatenation-forms-string` | ✅ | ✅ | ✅ | when a substitution is not the only part of a value, it is value-concatenated to form a string rather than keeping the substituted type |

</details>

<details>
<summary><b>unchanged-from-json</b> — 9 cases · Java 8/9 · pyhocon 7/9 · Rust 7/9</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-quoted-string-json-format` | ✅ | ❌ | ❌ | quoted strings are in the same format as JSON strings, so JSON escapes like \n, \t, \", \\ and \u unicode escapes are honored |
| `002-string-value-type` | ✅ | ✅ | ✅ | string is one of the possible value types |
| `003-number-value-type` | ✅ | ✅ | ✅ | number is one of the possible value types |
| `004-object-value-type` | ✅ | ✅ | ✅ | object is one of the possible value types |
| `005-array-value-type` | ✅ | ✅ | ✅ | array is one of the possible value types |
| `006-boolean-value-type` | ✅ | ✅ | ✅ | boolean is one of the possible value types |
| `007-null-value-type` | ✅ | ✅ | ✅ | null is one of the possible value types |
| `008-number-format-decimal-and-exponent` | ✅ | ✅ | ✅ | allowed number formats match JSON, including negative numbers, decimals, and exponent notation |
| `009-number-leading-zero-illegal` | ❌ | ❌ | ❌ | allowed number formats match JSON, and JSON forbids a zero followed by further digits; the initial number character plus the valid-in-JSON number characters after it must be parsed as a number value, so the whole token 01 has to be a number and is not one, with no fallback offered. typesafe/config parses it leniently as the number 1. _(java: lenient)_ |

</details>

<details>
<summary><b>units-format</b> — 6 cases · Java 6/6 · pyhocon 5/6 · Rust 6/6</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-number-value-is-default-unit` | ✅ | ✅ | ✅ | if the value is a number, it is taken to be a number in the default unit |
| `002-quoted-string-with-no-unit-uses-default-unit` | ✅ | ✅ | ✅ | a string value with no unit name should be interpreted with the default unit, as if it were a number |
| `003-string-with-unit-name-specifies-interpretation` | ✅ | ❌ | ✅ | a string value with a unit name has that name specify the value's interpretation |
| `004-whitespace-optional-around-number-and-unit` | ✅ | ✅ | ✅ | the units-format grammar is optional whitespace, a number, optional whitespace, an optional unit name, optional whitespace |
| `005-unit-name-must-be-letters-only` | ✅ | ✅ | ✅ | the unit name consists only of letters (Unicode L* categories, Java isLetter()), so a unit name with a trailing digit is not a legal units-format string |
| `006-unit-before-number-is-illegal` | ✅ | ✅ | ✅ | the units-format grammar puts the number before the unit name, not after, so a unit-then-number string is not a legal units-format value |

</details>

<details>
<summary><b>unquoted-strings</b> — 17 cases · Java 16/17 · pyhocon 13/17 · Rust 15/17</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-simple-unquoted-string` | ✅ | ✅ | ✅ | a sequence of characters outside a quoted string is a string value when it contains none of the forbidden characters |
| `002-quoted-alternative-for-forbidden-char` | ✅ | ✅ | ✅ | a quoted string may always be used as an alternative to write a character that is not permitted in an unquoted string, such as '@' |
| `003-unquoted-cannot-contain-at-sign` | ✅ | ✅ | ✅ | '@' is one of the listed forbidden characters, so it cannot appear inside an unquoted string |
| `004-double-slash-starts-comment` | ✅ | ❌ | ✅ | the two-character string '//' starts a comment, ending the unquoted string before it even mid-token |
| `005-single-slash-allowed` | ✅ | ✅ | ✅ | only the two-character string '//' is special for comments; a lone '/' is not a forbidden character and stays part of the unquoted string |
| `006-truefoo-parses-as-true-then-foo` | ✅ | ✅ | ✅ | worked example: truefoo parses as the boolean token true followed by the unquoted string foo, because its initial characters parse as true |
| `007-footrue-is-one-unquoted-string` | ✅ | ✅ | ✅ | worked example: footrue does not begin with true, false, null, or a number, so it parses as a single unquoted string |
| `008-number-then-suffix-string` | ✅ | ✅ | ✅ | worked example: 10.0bar is the number 10.0 followed by the unquoted string bar, since 10.0 parses as a number at the start |
| `009-digits-not-at-start-stay-string` | ✅ | ✅ | ✅ | worked example: bar10.0 does not begin with a digit, so the whole thing is the single unquoted string bar10.0, not a number |
| `010-embedded-null-not-recognized` | ✅ | ✅ | ✅ | embedded (non-initial) null, true, false, and numbers are not recognized as such: they are just part of the string, since only the leading characters are checked |
| `011-unquoted-cannot-contain-backslash` | ✅ | ❌ | ✅ | backslash is a forbidden character, and unquoted strings support no escaping at all, so a literal backslash requires a quoted string instead |
| `012-unquoted-cannot-start-with-hyphen` | ❌ | ❌ | ❌ | an unquoted string may not begin with a hyphen, and the initial number character plus any valid-in-JSON number characters that follow must be parsed as a number value -- here that is the lone '-', which is not a number. typesafe/config falls back to unquoted text and yields the string '-foo', the same leniency it shows for '1e'. _(java: lenient)_ |
| `013-negative-number-then-string` | ✅ | ✅ | ✅ | a hyphen followed by digits begins number parsing (-1), after which foo continues as a separate unquoted string token, mirroring the 10.0bar example for negative numbers |
| `014-hash-starts-comment-not-forbidden-char-in-string` | ✅ | ✅ | ✅ | '#' is forbidden inside an unquoted string because it already has meaning in HOCON: it starts a comment |
| `015-reserved-forbidden-char-no-current-meaning` | ✅ | ✅ | ✅ | some forbidden characters, such as '!', have no meaning in HOCON today and are reserved as keywords for future extensions to the spec |
| `016-control-char-allowed-unquoted` | ✅ | ✅ | ✅ | unquoted strings place no restriction on control characters, other than the forbidden characters listed |
| `017-control-char-forbidden-in-quoted` | ✅ | ❌ | ❌ | quoted JSON strings may not contain control characters, per the JSON spec, unlike unquoted strings |

</details>

<details>
<summary><b>value-concatenation</b> — 4 cases · Java 4/4 · pyhocon 4/4 · Rust 3/4</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-simple-values-concatenate-to-string` | ✅ | ✅ | ✅ | if all the values are simple values they are concatenated into a string |
| `002-arrays-concatenate-into-one-array` | ✅ | ✅ | ✅ | if all the values are arrays they are concatenated into one array |
| `003-objects-concatenate-by-merging` | ✅ | ✅ | ✅ | if all the values are objects they are merged (as with duplicate keys) into one object |
| `004-string-concatenation-allowed-in-field-keys` | ✅ | ✅ | ❌ | string value concatenation is allowed in field keys, in addition to field values and array elements |

</details>

<details>
<summary><b>whitespace</b> — 6 cases · Java 6/6 · pyhocon 2/6 · Rust 6/6</summary>

| case | Java | pyhocon | Rust | rule |
|---|---|---|---|---|
| `001-nonbreaking-space-as-whitespace` | ✅ | ❌ | ✅ | a nonbreaking space (0x00A0) is a Unicode Zs separator and must be treated as whitespace |
| `002-bom-at-start-is-whitespace` | ✅ | ❌ | ✅ | the BOM (0xFEFF) must be treated as whitespace, not as part of the key |
| `003-unicode-line-paragraph-separator` | ✅ | ✅ | ✅ | the Unicode line separator (Zl, U+2028) and paragraph separator (Zp, U+2029) count as whitespace |
| `004-vertical-tab-form-feed-whitespace` | ✅ | ❌ | ✅ | vertical tab (0x000B) and form feed (0x000C) are whitespace characters |
| `005-ascii-separator-control-chars` | ✅ | ✅ | ✅ | file separator (0x001C), group separator (0x001D), record separator (0x001E), and unit separator (0x001F) are whitespace characters |
| `006-special-nonbreaking-spaces` | ✅ | ❌ | ✅ | the spec names figure space (0x2007) and narrow no-break space (0x202F) explicitly among the nonbreaking spaces treated as whitespace |

</details>

| 228 cases | Java | pyhocon | Rust |
|---|---|---|---|
| **spec mode** — what HOCON requires | **96%** (219/228) | **80%** (183/228) | **89%** (204/228) |
| **java mode** — what typesafe/config does | 100% (227/228) | 79% (181/228) | 92% (209/228) |

Cells above show **spec mode**. The two modes differ on the 8 rows marked `java:` — the ones where HOCON and typesafe/config part ways; everywhere else they are the same question. 1 rows are open questions (⚠) rather than results.

<!-- conformance:end -->

## Contributing

This project is developed in the open. If you need a HOCON feature that isn't
implemented yet, please open a PR — feature requests as PRs (even a failing
test showing what you need) are the fastest way to get something prioritized.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the PR workflow (draft until CI is
green).

## License

BSD 3-Clause — see [LICENSE](LICENSE).
