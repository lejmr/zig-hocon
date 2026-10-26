# Changelog

What changed for someone using zig-hocon: the Zig package, the `hocon` command line tool, libhocon for C and the `zig-hocon` Python package, which are released together under one version. The technical detail is in the commits each release links to.

## [Unreleased]

### Fixed

- Optional substitutions on a cycle resolve the same whichever field comes first, as the spec has it, where v0.5.3 dropped or kept them by the order of the lines, and in two cases lost a value: `b.c += ${y}`, `b.c += 2`, `y = [1, ${?b}]` is `b.c = [[1], 2]` again, and `f = x${?a}`, `f = { z = 3 }`, `a = ${?f}` keeps `a`, since text under an object is hidden and never evaluated, as a list is. An include inside an object concatenated with an optional, `k = { include "x" } ${?y}`, no longer reports a cycle. Found by a bug hunt on v0.5.3.
- Four regressions in that change, found by a bug hunt on it, are fixed. A field written twice and reached again from inside a look-back, `d { z = ${?a.k} }`, `d.z += ${?c}`, `a : []`, `a += ${f}`, `f = ${d}`, crashed with `reached unreachable code` and resolves again, as typesafe/config has it; an undefined `${b}` in such a field, a crash already in v0.5.3, is the `Unresolved` error. `f += ${?b}`, `b = x${?f}`, `b += 1` dropped b's text and gave `b = [1]`, and is the error `+=` onto text is, whichever line comes first. `e = [${?f.k}y]`, `f = ${?e}${e}` and `e.k : ${?b}`, `b.k { k = ${?e}, k += ${?d} }` resolve the same in either order: an optional found to lead back to its own field stays nonexistent when it is met again. Ten new conformance cases, all 583 pass.
- A value concatenating many substitutions, `a = ${x} ${x} …`, resolves in memory linear in its length: 16 000 one-element lists took 3.9 GB and now take 18 MB, 32 000 strings 2.95 GB and now 24 MB.
- An included `.properties` file that is empty or holds only comments adds nothing, where it failed with `IncludedRootNotObject`. One new conformance case, all 584 pass.

## [0.5.3] - 2026-10-26

### Changed

- A value that begins with a digit but is no number is text again, as the spec has it: `host = 127.0.0.1`, `1.2.3`, a UUID and `01` are the strings they were written as, no longer a `BadNumber` error, so an IP address needs no quotes. The number JSON reads at the start is followed by text, as `10.0bar` is; the spec's own `1.2.3`, a path in a key, is written the same way in a value. So is a value that begins with `-` and no number: `-foo`, `-Xmx2g`, `--verbose`, and the `-` in `Monty Python - Holy Grail`, no longer a `HyphenIsNotAJsonNumber` error. So are `-.5` and `-.33e1`, which JSON has no number for, as `.5` already was. A `+` outside a number, `1+2` or `-.33e+1`, stays an error. Seven new conformance cases, eight rows rewritten, all 476 pass.

### Added

- Twelve conformance cases from bug reports in lightbend/config and ekrich/sconfig where the spec has the answer: typesafe/config fails inside `${a} { … }`, turns integers past 2^63 into strings and accepts `\u+041`; pyhocon loses `+=` across an include and the text of a substituted number. zig-hocon passes all 469.
- Eight conformance cases found by fuzzing zig-hocon against typesafe/config, where the spec has the answer: typesafe/config rejects `a { m = 2 } { n = 1 }` and `3+=[]`, loses the first `+=` after `c = null` and keeps the number in `[${?x}10]`. zig-hocon passes all 490.
- The conformance suite has 552 cases: 22 more from fuzzing that zig-hocon already passed, and its harness no longer takes `true` for `1` or splits an answer at U+0085. [docs/resolver.md](docs/resolver.md) draws how substitutions resolve.

### Fixed

- An object after a substitution, `top = ${x} { … }`, is a merge, the same as `top = ${x}` and `top { … }` written as two fields. A `+=` inside it appends to the list `${x}` gives (`top = ${x} { arr += four }` was `[four]`, is `[one, four]`), a self-reference looks back at it, and `${top.n}` inside it sees the merged object instead of reporting a cycle. Eight new conformance cases pin it.
- Layers of a key are merged before they are resolved, as the spec has it: in `p : { a : ${y} }`, `p : ${x}` with `x.a` set, `${y}` is hidden and no longer evaluated (it was an error), and a reference in the earlier object sees the final value. Three more conformance cases, all 457 pass.
- A field that refers to itself with nothing before it reads the environment variable of its own name, as the spec has it: `HOME : ${HOME}` is the variable `HOME`, where it was `Unresolved`, and `HOME : ${?HOME}` creates the field instead of dropping it, as pyhocon does. A value set earlier still wins, and `HOME += x` with `HOME` set is now an error: `+=` is `HOME = ${?HOME} [x]`, text and a list. Two new conformance cases, all 478 pass.
- A NUL byte inside a file is a character, as the spec has it, no longer the end of the file. In a comment it dropped everything below without a word: `a = 1 # note<NUL>`, then `b = 2`, read as `{a: 1}`, and a file saved as UTF-16 without a byte order mark read as `{}`, where it is now an error. In unquoted and triple-quoted text the NUL is kept (`a = x<NUL>y` was an error); in a quoted string it is an error, as any control character is. Four new conformance cases, all 482 pass.
- A comma after a braced root, `{ a = 1 },` or `[1, 2],`, is an error now, as the spec and typesafe/config have it; it was accepted. Two new conformance cases, all 492 pass.
- `a = null` then `a { … }` clears what `a` held before also when the file is included or the object merges with an earlier one: `a { x = 1 }` and then `include "over.conf"` with those two lines give `{a: {…}}` without `x`, as typesafe/config has it; the `x` was kept. Four new conformance cases, all 496 pass.
- An optional substitution on a cycle finds nothing also when the cycle runs on through other fields: `v { x = ${?r} }` with `r = ${v}` gives `v = {}` and `r = {}`, as typesafe/config has it; it was a SubstitutionCycle.
- A substitution path through an alias resolves only what it reaches: `a = ${p}` with `p = { r = ${a.q} }` reads `p.q`, as typesafe/config does; it was a SubstitutionCycle.
- `a = ${p}`, `p = 1`, `p = ${a}x` resolves to `a = 1`, `p = "1x"` in any order of the lines, as typesafe/config has it: the cycle breaks where `p` can look back. With `a` first it was a SubstitutionCycle.
- A field that looks back and refers to the object it is in sees that object with the field at its earlier value: `o { a = [], a += ${o} }` is `o = {a: [{a: []}]}`, as typesafe/config has it; it was a SubstitutionCycle. Four new conformance cases, all 500 pass.
- A word that begins with a number holding a `+` in its exponent and goes on as text is that text, as `10.0bar` is: `1e+5.x` is `"1e+5.x"` and `1e+5.5 = 1` is the path `1e+5`, `5`, where both were a `BadNumber` error. A `+` after that number, `1e+5e+5`, is still an error. HOCON written out quotes such a word, for typesafe/config and pyhocon, which reject it bare. Six new conformance cases, all 506 pass.
- An optional substitution that leads back to the field it stands in is nonexistent, whichever field is resolved first, as the spec has it: `f = ${?a.t}x`, `a = ${?y}${?f}` gives `f = "x"` in either order of the lines, and `o = ${a.n}` with `a { n = { h = 0 } ${?a} }` gives `o` the one value `a.n` has, where it was `{h: 0, n: {h: 0}}`. `d = yes${?c}`, `c = ${d}` and `e += ${?c}`, `c = ${e}` resolve instead of reporting a cycle when `d` or `e` comes first. `o = ${a.n}` with `a { n = ${?a} }` is now an error: `a.n` is never created, where `o` was `{}`.
- Cycles typesafe/config breaks are broken: a path into a field that refers back to itself looks back (`d { a = ${i.b} }`, `i.b = 7`, `i = ${d}`), and so does an alias in a list (`a = [${p}]`, `p = 1`, `p = ${a}`) or written twice, and a look-back inside a list element (`a = [{ c = 2, c = ${a} }]`). What an object or a list resolves to inside such a look-back is its value. A field that refers to the object it is in, `v { x = ${v} }`, stays an error, as the spec names it unbreakable.
- A concatenation with a list in it under an object is hidden and never evaluated, as the spec has it: `c = [1] ${x}`, `c = { a = 1 }` is `{a: 1}`, where it was an error. Seventeen new conformance cases, all 523 pass.
- `+=` and an include inside an object in a list work from that object, as the spec has it: `a = [{ b = [1], b += 2 }]` is `[{b: [1, 2]}]`, where the earlier `b` was not seen and it was `[{b: [2]}]`, and `+=` onto a value there that is no list is an error, as anywhere. A file included into a list element looks its substitutions up in that element first, then at the document root (`a = [{ include "child.conf" }]`, child `x = ${y}`, `y = 1`, was an error or took a root `y`). Five new conformance cases, all 528 pass.
- `include url("file:///…/inc")` loads exactly that file, as the spec has it for every URL: with only `inc.conf` beside it, it found `inc.conf`, as a basename does. The conformance suite can now name an absolute `file:` URL in a case (`@CASE_DIR@`), and has its first two. All 530 pass.

## [0.5.2] - 2026-10-23

The conformance suite has no open question left: the spec settles the last one, `url()` without a scheme, as an error ([lightbend/config#887](https://github.com/lightbend/config/pull/887)), and zig-hocon passes all 446 tests.

### Added

- A conformance case for a value that begins with a digit but is no number, `a = 1.2.3`: an error by the spec. `python/MIGRATING.md` says what it means for a pyhocon user: an IP address needs quotes.

## [0.5.1] - 2026-10-19

The conformance suite settles two of its three open questions: 444 of the 445 tests pass, up from 442. The last one, `url()` without a scheme, waits for the spec ([lightbend/config#887](https://github.com/lightbend/config/pull/887)).

### Added

- `python/BENCHMARK.md`: every Python HOCON library measured against the spec and timed on 1 KB, 1 MB and 10 MB files, with the best Rust crate and typesafe/config beside them. zig-hocon is the fastest Python library, from 2× the next one at 1 KB to 17× at 10 MB.
- The conformance report measures py.hocon, hocon2, pulse-pyhocon and rs.hocon beside typesafe/config and pyhocon; `conformance/README.md` lists the parsers left out and why.
- A conformance case can accept more than one output, `also_valid` in its sidecar, where the spec allows several answers. The first is two fields that substitute each other: both 1, both 2 or an error.

### Changed

- `include url("x.conf")`, a URL with no scheme, fails with `InvalidUrl` instead of `UnsupportedInclude`, which stays for a scheme zig-hocon cannot follow, such as `ftp:`. In C it is still `HOCON_ERR_PARSE`, in Python still a `ConfigParseException`; only the name changes.
- A newline between a key and its `{` is an ordinary conformance case, no longer an open question: every parser in the report accepts it.

### Fixed

- `conformance/run.sh --text` lists open questions apart from failures. They showed as failing, with the expected and the actual output the same.
- The conformance report page shows its scores and verdicts without JavaScript, so they show on a phone too.

## [0.5.0] - 2026-10-18

A timeout for http(s) includes from C and Python.

### Added

- An http(s) include from C and Python gives up after 30 s, or the time you give: `http_timeout_ms` in `hocon_options`, `http_timeout=` (a `timedelta` or seconds) on `parse_file` and `parse_string`. It fails with `IncludeTimeout`; until now a server that never answered held the parse for ever.

### Changed

- `hocon_options` starts with `size_t size`, which you set to `sizeof(hocon_options)`: the library reads the fields that fit in it and takes the defaults for the rest, so a program built against this header keeps working with a later library that adds fields. Options filled in order, `{HOCON_ENV_MAP, vars, true, NULL}`, become `{sizeof(hocon_options), HOCON_ENV_MAP, vars, true, NULL, 0}`; a size of 0 is `HOCON_ERR_OTHER`. Rebuild against the new `hocon.h`.
- A parse in libhocon sets SIGIO and SIGPIPE to a handler that does nothing, and leaves them so: it wakes its own fetch thread with SIGIO when the time is up.

## [0.4.0] - 2026-10-18

HOCON from C and Python, on Linux, macOS and Windows.

### Added

- libhocon, the C API in `include/hocon.h`: parse a file or a string, typed getters by path, a subtree as JSON or HOCON, errors with file, line, column and caret. A zip per platform on the release.
- The `zig-hocon` Python package on libhocon: pyhocon's API, typed, safe to share between threads. Wheels for macOS, Linux (glibc and musl) and Windows on every Python from 3.10.
- `ParseOptions.resolve = false` keeps every `${…}` in the tree, for `hocon.stringify` to write back.
- `ParseOptions.ignore_unknown_fields = false` makes a key the struct has no field for `error.UnknownField`.
- `hocon.parseFromSliceInDirLeaky` reads text whose includes are relative to a directory; `hocon.parseFromValue` converts a `hocon.Value` you already have into your struct.

### Fixed

- A number read from text into a struct follows the JSON rules: `0x10`, `1_000` and `nan` are errors, as in the spec and typesafe/config.

How much of the code in `src/` is written by hand, the rest with AI, counted with `git blame` over the lines that are not empty, by who wrote the commit each line comes from; moved code stays its author's. The tests are left out: most of them are written with AI.

| | share |
|---|---|
| Tokenizer | 73 % |
| AST | 51 % |
| Value | 15 % |
| Config | 19 % |
| API and CLI | 2 % |
| all of `src/` | 22 % of 7545 lines |
| conformance to the spec | 99 % (442 of 445 tests) |

## [0.3.0] - 2026-10-17

The rest of the spec, durations and sizes, and three new commands.

### Added

- `hocon.Duration`, `hocon.Period` and `hocon.Size`, read from `30s`, `3 months`, `512MiB` in any unit the spec lists.
- Objects with numeric keys (`{ "0": a, "1": b }`) read as lists, into a slice or an array.
- `hocon get` prints one value, `hocon check` reads files, with `--schema` into your own struct, and `hocon diff` compares two files as they resolve.

### Changed

- Nesting deeper than 500, or a chain of 500 substitutions, is `error.TooDeep` instead of a stack overflow.
- An included `.properties` file has to be UTF-8.

### Fixed

442 of the 445 tests in the conformance suite pass, up from 437.

- The file `--env=keep` writes reads back to the same result when a substitution comes from an include inside a block, and a `+=` still waiting on the environment is written as `+=`.
- A lone surrogate in a quoted string (`"\ud83d"`) is kept and written back as it was read.
- A `+` in a run that is no number is an error.
- An optional substitution that closes a cycle finds nothing.
- A key written many times merges in linear time.

How much of the code in `src/` is written by hand, the rest with AI, counted with `git blame` over the lines that are not empty, by who wrote the commit each line comes from; moved code stays its author's. The tests are left out: most of them are written with AI.

| | share |
|---|---|
| Tokenizer | 73 % |
| AST | 51 % |
| Value | 15 % |
| Config | 20 % |
| API and CLI | 3 % |
| all of `src/` | 24 % of 6880 lines |
| conformance to the spec | 99 % (442 of 445 tests) |

## [0.2.0] - 2026-10-17

Includes, errors with a place, environment variables and HOCON out.

### Added

- Includes: files, `file()`, `required()` and http(s) URLs, as `.conf`, `.json` or `.properties`, read through `hocon.parseFromFile` and `parseFromFileLeaky`. A slow server is `error.IncludeTimeout` after `ParseOptions.http_timeout` (30 s).
- Errors with a place: `ParseOptions.diagnostics` gets the file, line, column and the line itself, and `render` prints it with a caret, as the zig compiler does. A value of the wrong type names its path, what the type wanted and where the value is written.
- A key written again over a substitution of itself (`path = ${path} ":/opt"`), and `+=`.
- Environment variables: a `${…}` the document does not answer reads the variable of the same name, `${X[]}` a list from `X_0`, `X_1`, … (`ParseOptions.env`). `.keep` leaves them for later.
- `hocon.stringify` and `stringifyAlloc` write any value as HOCON, an unresolved one too, which is the one file to deploy.
- `hocon.parsePath` turns a path given as text into keys.
- `--env=process|none|keep` on the command line.

### Changed

- `parseFromSlice` and `parseFromSliceLeaky` take `ParseOptions` as their last argument; `.{}` does what they did before.
- `hocon <file>` prints HOCON; `--json` gives the JSON it printed before.
- A value that starts like a number has to be a JSON number: `01` and `-` alone are errors, as in JSON.
- Input over 64 MiB is `error.StreamTooLong`, a file that is not UTF-8 `error.InvalidUtf8` at the first bad byte.

### Fixed

437 of the 445 tests in the conformance suite pass, up from 307.

- Every whitespace character the spec lists separates, a lone `\r` included; `//` right after unquoted text starts a comment.
- A comma separates once; array elements on one line concatenate; a document that starts with `[` is a list.
- Unquoted text may start with `_`, `%` or a letter outside ASCII; `1e+5` is a number; an escaped backslash before the closing quote ends the string.
- `${.a}` is an error, as the key `.a` is.

How much of the code in `src/` is written by hand, the rest with AI, counted with `git blame` over the lines that are not empty, by who wrote the commit each line comes from; moved code stays its author's. The tests are left out: most of them are written with AI.

| | share |
|---|---|
| Tokenizer | 74 % |
| AST | 58 % |
| Value | 19 % |
| Config | 54 % |
| API and CLI | 5 % |
| all of `src/` | 33 % of 5342 lines |
| conformance to the spec | 98 % (437 of 445 tests) |

## [0.1.0] - 2026-10-15

The first release that works end to end: HOCON text into your own Zig struct, shaped after `std.json`.

### Added

- `hocon.parseFromSlice(T, gpa, source)` returns `Parsed(T)`, an arena that owns the value and is freed by one `deinit`; `parseFromSliceLeaky` takes your arena and returns the plain value.
- Into structs with nested structs, slices, optionals, enums and field defaults; a value converts as the spec's automatic type conversions say.
- `hocon.Value`, the tree itself, which `std.json.Stringify` prints as JSON.
- The syntax: JSON as it is, comments (`#` and `//`), root braces left out, `=` or `:` or nothing before `{`, newlines for commas, unquoted and multi-line strings.
- Paths as keys (`a.b.c = 1`), a key written again merging objects, and value concatenation of strings, lists and objects.
- Substitutions `${a.b}` and `${?a.b}`, resolved against the whole document.
- The `hocon` command prints a file as JSON and exits 1 with the reason when it does not parse or resolve.

307 of the 445 tests in the conformance suite pass. Not yet: includes, `+=`, and a key that refers to its own earlier value.

How much of the code in `src/` is written by hand, the rest with AI, counted with `git blame` over the lines that are not empty, by who wrote the commit each line comes from; moved code stays its author's. The tests are left out: most of them are written with AI.

| | share |
|---|---|
| Tokenizer | 100 % |
| AST | 99 % |
| Value | 80 % |
| Config | 100 % |
| API and CLI | 66 % |
| all of `src/` | 92 % of 2206 lines |
| conformance to the spec | 69 % (307 of 445 tests) |
