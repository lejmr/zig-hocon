# Conformance suite

Data, not code. Nothing here imports Zig, and nothing here is specific to this
repo — a runner in any language is a directory walk plus a JSON compare.

## Layout

One directory per heading of the HOCON specification (`HOCON.md` in
lightbend/config), named after the heading's anchor slug. Inside, one case per
pair of files:

```
conformance/<spec-section>/<nnn>-<name>.conf    the input, verbatim
conformance/<spec-section>/<nnn>-<name>.json    what it must produce
```

## The sidecar

```json
{
  "spec": "HOCON.md#duplicate-keys-and-object-merging",
  "why": "one sentence: what rule this case pins down",
  "expect": {"a": {"b": 1, "c": 2}}
}
```

`expect` is the parsed config rendered as JSON, unresolved substitutions left
alone, key order irrelevant. A case that must be **rejected** carries no
`expect`:

```json
{
  "spec": "HOCON.md#path-expressions",
  "why": "an empty path element is only legal written as \"\"",
  "error": "BadPath"
}
```

`expect` is what the **specification** requires, not what any implementation
does. It is seeded from `tools/oracle/hocon-java` and then owned by the
validation stage — see "Tie-break" in `PROCESS.md`.

A row where the reference implementation and the spec part ways carries
`"java": "diverges" | "unsupported" | "lenient"` and, next to it,
`"java_expect"` or `"java_error"` — what typesafe/config does with that same
input. Those rows are the reason the suite exists; `PROCESS.md` has the table
of which kind means what.

A row carrying `"review"` is an open question for a human. It is not a pass and
not a failure; `report.py` marks it ⚠.

`error` is documentation, not an assertion — messages differ per
implementation. A runner asserts only that parsing failed.

## Running one

Each case is a single line of input to the oracles, so any case can be checked
against the reference implementation:

```sh
tools/oracle/hocon-java < <(printf '%s' "$(cat conformance/*/001-*.conf)")
```

`hocon-java` is the authority — see `tools/oracle/README.md`. Expected values
are **produced by it**, not written by hand; they are hand-checked against the
spec text quoted in `why`.

## Resolution

Substitutions stay unresolved by default. A case that needs them resolved says
so:

```json
{"resolve": true, "expect": {"a": 1, "b": 1}}
```
