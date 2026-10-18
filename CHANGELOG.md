# Changelog

What changed for someone using zig-hocon: the Zig package, the `hocon`
command line tool, libhocon for C and the `zig-hocon` Python package, which
are released together under one version. The technical detail is in the
commits each release links to.

## [Unreleased]

HOCON from C and Python, on Linux, macOS and Windows.

### Added

- libhocon, the C API in `include/hocon.h`: parse a file or a string, typed
  getters by path, a subtree as JSON or HOCON, errors with file, line,
  column and caret. A zip per platform on the release.
- The `zig-hocon` Python package on libhocon: pyhocon's API, typed, safe to
  share between threads. Wheels for macOS, Linux (glibc and musl) and
  Windows on every Python from 3.10.
- `ParseOptions.resolve = false` keeps every `${…}` in the tree, for
  `hocon.stringify` to write back.
- `ParseOptions.ignore_unknown_fields = false` makes a key the struct has no
  field for `error.UnknownField`.
- `hocon.parseFromSliceInDirLeaky` reads text whose includes are relative to
  a directory; `hocon.parseFromValue` converts a `hocon.Value` you already
  have into your struct.

### Fixed

- A number read from text into a struct follows the JSON rules: `0x10`,
  `1_000` and `nan` are errors, as in the spec and typesafe/config.

How much of the code in `src/` is written by hand, the rest with AI,
counted with `git blame` over the lines that are not empty, by who wrote
the commit each line comes from; moved code stays its author's. The tests
are left out: most of them are written with AI.

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

- `hocon.Duration`, `hocon.Period` and `hocon.Size`, read from `30s`,
  `3 months`, `512MiB` in any unit the spec lists.
- Objects with numeric keys (`{ "0": a, "1": b }`) read as lists, into a
  slice or an array.
- `hocon get` prints one value, `hocon check` reads files, with `--schema`
  into your own struct, and `hocon diff` compares two files as they resolve.

### Changed

- Nesting deeper than 500, or a chain of 500 substitutions, is
  `error.TooDeep` instead of a stack overflow.
- An included `.properties` file has to be UTF-8.

### Fixed

442 of the 445 tests in the conformance suite pass, up from 437.

- The file `--env=keep` writes reads back to the same result when a
  substitution comes from an include inside a block, and a `+=` still waiting
  on the environment is written as `+=`.
- A lone surrogate in a quoted string (`"\ud83d"`) is kept and written back
  as it was read.
- A `+` in a run that is no number is an error.
- An optional substitution that closes a cycle finds nothing.
- A key written many times merges in linear time.

How much of the code in `src/` is written by hand, the rest with AI,
counted with `git blame` over the lines that are not empty, by who wrote
the commit each line comes from; moved code stays its author's. The tests
are left out: most of them are written with AI.

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

- Includes: files, `file()`, `required()` and http(s) URLs, as `.conf`,
  `.json` or `.properties`, read through `hocon.parseFromFile` and
  `parseFromFileLeaky`. A slow server is `error.IncludeTimeout` after
  `ParseOptions.http_timeout` (30 s).
- Errors with a place: `ParseOptions.diagnostics` gets the file, line,
  column and the line itself, and `render` prints it with a caret, as the
  zig compiler does. A value of the wrong type names its path, what the type
  wanted and where the value is written.
- A key written again over a substitution of itself
  (`path = ${path} ":/opt"`), and `+=`.
- Environment variables: a `${…}` the document does not answer reads the
  variable of the same name, `${X[]}` a list from `X_0`, `X_1`, …
  (`ParseOptions.env`). `.keep` leaves them for later.
- `hocon.stringify` and `stringifyAlloc` write any value as HOCON, an
  unresolved one too, which is the one file to deploy.
- `hocon.parsePath` turns a path given as text into keys.
- `--env=process|none|keep` on the command line.

### Changed

- `parseFromSlice` and `parseFromSliceLeaky` take `ParseOptions` as their
  last argument; `.{}` does what they did before.
- `hocon <file>` prints HOCON; `--json` gives the JSON it printed before.
- A value that starts like a number has to be a JSON number: `01` and `-`
  alone are errors, as in JSON.
- Input over 64 MiB is `error.StreamTooLong`, a file that is not UTF-8
  `error.InvalidUtf8` at the first bad byte.

### Fixed

437 of the 445 tests in the conformance suite pass, up from 307.

- Every whitespace character the spec lists separates, a lone `\r`
  included; `//` right after unquoted text starts a comment.
- A comma separates once; array elements on one line concatenate; a
  document that starts with `[` is a list.
- Unquoted text may start with `_`, `%` or a letter outside ASCII; `1e+5`
  is a number; an escaped backslash before the closing quote ends the
  string.
- `${.a}` is an error, as the key `.a` is.

How much of the code in `src/` is written by hand, the rest with AI,
counted with `git blame` over the lines that are not empty, by who wrote
the commit each line comes from; moved code stays its author's. The tests
are left out: most of them are written with AI.

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

The first release that works end to end: HOCON text into your own Zig
struct, shaped after `std.json`.

### Added

- `hocon.parseFromSlice(T, gpa, source)` returns `Parsed(T)`, an arena that
  owns the value and is freed by one `deinit`; `parseFromSliceLeaky` takes
  your arena and returns the plain value.
- Into structs with nested structs, slices, optionals, enums and field
  defaults; a value converts as the spec's automatic type conversions say.
- `hocon.Value`, the tree itself, which `std.json.Stringify` prints as JSON.
- The syntax: JSON as it is, comments (`#` and `//`), root braces left out,
  `=` or `:` or nothing before `{`, newlines for commas, unquoted and
  multi-line strings.
- Paths as keys (`a.b.c = 1`), a key written again merging objects, and
  value concatenation of strings, lists and objects.
- Substitutions `${a.b}` and `${?a.b}`, resolved against the whole document.
- The `hocon` command prints a file as JSON and exits 1 with the reason when
  it does not parse or resolve.

307 of the 445 tests in the conformance suite pass. Not yet: includes,
`+=`, and a key that refers to its own earlier value.

How much of the code in `src/` is written by hand, the rest with AI,
counted with `git blame` over the lines that are not empty, by who wrote
the commit each line comes from; moved code stays its author's. The tests
are left out: most of them are written with AI.

| | share |
|---|---|
| Tokenizer | 100 % |
| AST | 99 % |
| Value | 80 % |
| Config | 100 % |
| API and CLI | 66 % |
| all of `src/` | 92 % of 2206 lines |
| conformance to the spec | 69 % (307 of 445 tests) |
