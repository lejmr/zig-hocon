# Changelog

What changed for someone using zig-hocon: the Zig package, the `hocon`
command line tool, libhocon for C and the `zig-hocon` Python package, which
are released together under one version. The technical detail is in the
commits each release links to.

## [Unreleased]

The whole spec, a C library and a Python package. Everything since 0.1.0;
0.2.0 and 0.3.0 were never published.

### Added

- Includes: files, `file()`, `required()` and http(s) URLs, as `.conf`,
  `.json` or `.properties`, read through `parseFromFile`. A slow server is
  `error.IncludeTimeout` after `ParseOptions.http_timeout` (30 s).
- Errors with a place: `ParseOptions.diagnostics` gets the file, line,
  column and the line itself, and `render` prints it with a caret, as the
  zig compiler does. A value of the wrong type names its path, what the type
  wanted and where the value is written.
- A key written again over a substitution (`path = ${path} ":/opt"`), `+=`,
  and objects with numeric keys read as lists.
- Environment variables: a `${…}` the document does not answer reads the
  variable of the same name, `${X[]}` a list from `X_0`, `X_1`, …
  (`ParseOptions.env`). `.keep` leaves them for later, and
  `hocon.stringify` writes the one file to deploy.
- `hocon.Duration`, `hocon.Period` and `hocon.Size`, read from `30s`,
  `3 months`, `512MiB` in any unit the spec lists.
- `hocon.stringify` and `stringifyAlloc` write any value as HOCON;
  `hocon.parsePath` turns a path given as text into keys.
- `ParseOptions.resolve = false` keeps every `${…}`;
  `ParseOptions.ignore_unknown_fields = false` makes a key the struct has no
  field for an error.
- `hocon get`, `hocon check` (with `--schema` into your own struct) and
  `hocon diff`; `--env=process|none|keep` on every command.
- libhocon, the C API in `include/hocon.h`, as a zip per platform on the
  release.
- The `zig-hocon` Python package: pyhocon's API, typed, wheels for macOS,
  Linux (glibc and musl) and Windows on every Python from 3.10.

### Changed

- `hocon <file>` prints HOCON; `--json` gives the JSON it printed before.
- A value that starts like a number has to be a JSON number: `01` and `-`
  alone are errors, as in JSON.
- Nesting deeper than 500, or a chain of 500 substitutions, is
  `error.TooDeep` instead of a stack overflow.

## [0.1.0] - 2026-10-15

The first release: HOCON into your own Zig structs through
`hocon.parseFromSlice`, shaped after `std.json`, with substitutions resolved
against the whole document, and a `hocon` command that prints a file as JSON.
