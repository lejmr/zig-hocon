# HOCON conformance suite

Every case here is one sentence of the [HOCON specification](../spec/HOCON.md),
written as a config file and the value it must produce. The suite is data, not
code: a runner in any language is a directory walk and a JSON compare.

## Check your implementation

```sh
cp conformance/adapters/example.sh my-adapter.sh   # ~10 lines, edit one of them
conformance/run.sh --text -- ./my-adapter.sh       # read the result
conformance/run.sh -- ./my-adapter.sh > result.json
```

Needs a POSIX shell and python3. Nothing else, and nothing from outside this
directory — the suite travels on its own.

Your adapter is called with one argument, the path to a `.conf` file. It prints
the parsed config as compact JSON and exits 0, or exits non-zero to reject the
input. Substitutions must be resolved; key order and JSON whitespace do not
matter; stderr is yours.

### Two bars, one suite

```sh
conformance/run.sh --spec -- ./my-adapter.sh   # default: what HOCON requires
conformance/run.sh --java -- ./my-adapter.sh   # what typesafe/config does
```

They ask the same question on every row but a handful — the ones where the
specification and the reference implementation genuinely part ways. Aim at
`--spec` if you want to be correct, at `--java` if you need configs that parse
in the JVM world today to keep parsing. `PROCESS.md` explains the difference and
lists every row where it matters.

`--only <text>` narrows a run to matching paths, which is how you work through
one section at a time.

## Layout

One directory per heading of the specification, named after the heading's
anchor. Inside, one case per pair of files:

```
conformance/<spec-section>/<nnn>-<name>.conf    the input, verbatim
conformance/<spec-section>/<nnn>-<name>.json    what it must produce
```

`SECTIONS.md` maps every heading of the spec to its directory, or to the reason
it has no observable parse behaviour. `FINDINGS.md` is the open work: cases
known to be defective and normative sentences nothing covers yet.

## The sidecar

```json
{
  "spec": "HOCON.md#duplicate-keys-and-object-merging",
  "why": "one sentence: what rule this case pins down",
  "expect": {"a": {"b": 1, "c": 2}}
}
```

`expect` is what the **specification** requires, not what any implementation
does — see "Tie-break" in `PROCESS.md`. A case that must be **rejected** carries
no `expect`:

```json
{
  "spec": "HOCON.md#path-expressions",
  "why": "an empty path element is only legal written as \"\"",
  "error": "BadPath"
}
```

`error` is documentation, not an assertion — messages differ per implementation,
so a runner asserts only that parsing failed.

A row where the reference implementation and the spec part ways carries
`"java": "diverges" | "unsupported" | "lenient"` and, next to it, `"java_expect"`
or `"java_error"` — what typesafe/config does with that same input. Those rows
are the reason the suite exists; `PROCESS.md` has the table of which kind means
what.

A row carrying `"review"` is an open question for a human. It is neither a pass
nor a failure.

`"resolve": true` marks a case that only means anything once substitutions are
resolved. Resolve them always and it makes no difference to you.

## Reusing this

BSD 3-Clause, like the rest of the repository. Vendor the directory, keep the
licence, and tell us what broke — a case that is wrong about the spec is worth
more to us as a bug report than a passing score is.
