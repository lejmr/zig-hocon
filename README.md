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
  - [x] Assignments (`=` and `:` are interchangeable)
  - [x] Objects, nested to any depth, including the empty object and the omitted
        `=` before a block (`a { b = c }`)
  - [x] Newlines and commas as interchangeable member separators
  - [x] Comments and blank lines skipped
  - [ ] Arrays (tokenized, not yet parsed)
  - [ ] Quoted values distinguishable from unquoted ones in the tree
        (needed to tell `a = "1"` from `a = 1`)
  - [ ] Path expressions as keys — `a.b.c = 1` nests, and an element may be
        quoted to contain a dot (`"a"."b" = c`, currently rejected)
  - [ ] Quoted and unquoted parts mixed in one key (`"a" b = c` should give the
        key `a b`; today it yields `a" b`)
  - [ ] Object merging (duplicate keys merge instead of overwrite)
  - [ ] Object concatenation
  - [ ] Array concatenation
  - [ ] String concatenation (unquoted string juxtaposition) — partially done:
        adjacent unquoted strings join (`a = milos kozak`), mixing in quoted ones
        (`a = "x" y`) does not yet
  - [ ] Building a value out of several string/quoted parts. The result is not a
        substring of the input, so it cannot stay a span: quotes are dropped but
        the whitespace *between* the parts is kept verbatim, and escapes inside
        quoted parts are expanded. `a = milos     "kozak"` is `milos     kozak`,
        `a = milos"kozak"` is `miloskozak`, `a = "x\ny"` holds a real newline.
  - [ ] `include` directives (file, url, required)
  - [ ] Substitutions (`${a.b.c}`, `${?a.b.c}`)
  - [ ] Duration unit values (`10s`, `5m`, ...)
  - [ ] Memory size unit values (`512K`, `1G`, ...)
  - [ ] Environment variable fallback for substitutions
  - [ ] JSON compatibility (valid JSON is valid HOCON)
- [ ] Public API
  - [ ] Parse from string
  - [ ] Parse from file
  - [ ] Typed accessors (string/int/float/bool/array/object)
  - [ ] Config merging across multiple sources (`with_fallback`-style)

## Reference oracles

Disputed behaviour is settled by running it, not by reading the spec from
memory. `tools/oracle/` holds two reference implementations behind one interface:

```sh
printf 'a = milos kozak\n' | tools/oracle/hocon-java   # Lightbend typesafe/config
printf 'a = milos kozak\n' | tools/oracle/hocon-py     # pyhocon
```

`hocon-java` is the authority; `hocon-py` shows what the implementation this
project replaces would do. See [tools/oracle/README.md](tools/oracle/README.md)
for the input format and the list of confirmed divergences between the two.

## Contributing

This project is developed in the open. If you need a HOCON feature that isn't
implemented yet, please open a PR — feature requests as PRs (even a failing
test showing what you need) are the fastest way to get something prioritized.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the PR workflow (draft until CI is
green).

## License

BSD 3-Clause — see [LICENSE](LICENSE).
