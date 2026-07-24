# zig-hocon

A [HOCON](https://github.com/lightbend/config/blob/main/HOCON.md) (Human-Optimized
Config Object Notation) parser for [Zig](https://ziglang.org), inspired by
[pyhocon](https://github.com/chimpler/pyhocon).

Requires Zig **0.16.0** or newer.

> **Status: early development.** The tokenizer and parser are being built out
> incrementally — see [Features](#features) below for what currently works.
> This is not yet published to the Zig package registry.

## Usage

```zig
// TODO: usage example once the parser has a public API.
```

## Features

Tracks HOCON spec coverage as the tokenizer/parser get built out. Checked
items are implemented and tested; unchecked items are planned.

- [x] Tokenizer
  - [x] Objects `{ }`
  - [x] Arrays `[ ]`
  - [x] Strings
    - [x] Unquoted
    - [x] Quoted (escaped `\"` handled; content returned raw, unescaping is the parser's job; `\\"` — escaped backslash right before the closing quote — not yet handled)
    - [x] Triple-quoted / multi-line
  - [x] Numbers (tokenize as plain strings, no dedicated type; leading `+` not yet supported)
  - [x] Booleans / null (work implicitly as unquoted strings, no dedicated type)
  - [x] Comments (`#` and `//`)
  - [x] Key paths (`a.b.c`)
- [ ] Parser
  - [ ] Object merging (duplicate keys merge instead of overwrite)
  - [ ] Object concatenation
  - [ ] Array concatenation
  - [ ] String concatenation (unquoted string juxtaposition)
  - [ ] Substitutions (`${a.b.c}`, `${?a.b.c}`)
  - [ ] `include` directives (file, url, required)
  - [ ] Duration unit values (`10s`, `5m`, ...)
  - [ ] Memory size unit values (`512K`, `1G`, ...)
  - [ ] Environment variable fallback for substitutions
  - [ ] JSON compatibility (valid JSON is valid HOCON)
- [ ] Public API
  - [ ] Parse from string
  - [ ] Parse from file
  - [ ] Typed accessors (string/int/float/bool/array/object)
  - [ ] Config merging across multiple sources (`with_fallback`-style)

## Contributing

This project is developed in the open. If you need a HOCON feature that isn't
implemented yet, please open a PR — feature requests as PRs (even a failing
test showing what you need) are the fastest way to get something prioritized.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the PR workflow (draft until CI is
green).

## License

BSD 3-Clause — see [LICENSE](LICENSE).
