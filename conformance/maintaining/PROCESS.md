# How the suite gets built

A pipeline, not a sitting. Each stage hands the next something checkable.

1. **Decompose** — every heading of `spec/HOCON.md` becomes a row in
   `SECTIONS.md`: a directory, or a reason it has no observable behaviour.
   Done once, revisited only when the spec moves.
2. **Cover** — one agent per section, reading only its line range of the spec,
   writes cases until every normative sentence in that range is pinned by at
   least one. It writes `.conf` and the `why` + `spec` fields; it does **not**
   invent `expect`.
3. **Oracle** — `tools/oracle/hocon-java` produces `expect` for every new case.
   A case whose oracle output contradicts the sentence quoted in `why` is a
   finding, not a value to paste: it goes to stage 5.
4. **Run** — the suite is green against the oracle before anything else reads
   it.
5. **Validate** — a holistic pass over the finished suite against the whole
   spec: does the coverage actually map to what HOCON says, or only to what
   the oracle does?

## The point of stage 5

Stages 2–4 alone would build a suite that describes `typesafe/config`, not
HOCON. The suite's value is exactly the gap between them.

## Tie-break: what `expect` means

`expect` is **what the specification requires**. Always. The suite measures
conformance to HOCON, so the spec is the only thing that can decide a row.

That does not make the oracle decoration. It is how `expect` is *seeded* —
stage 3 fills every row with what `tools/oracle/hocon-java` does, because on
the overwhelming majority of rows the reference implementation and the spec
say the same thing, and starting from a measured value keeps stage 2 and
stage 5 from writing wishful ones. Stage 5 then reads every seeded row against
the spec text and owns the result.

Where the two part ways, the row records both:

```json
{
  "spec": "HOCON.md#units-format",
  "why": "the spec lists 'µs' among the microsecond suffixes; typesafe/config rejects it",
  "expect": {"t": "1µs"},
  "java": "unsupported",
  "java_error": "ConfigException.BadValue"
}
```

- `expect` / `error` — the spec's answer. What a conforming implementation must do.
- `java_expect` / `java_error` — present **only** on a divergent row: what
  typesafe/config actually does with that same input.
- `java` — which way the two part company:

| kind | the spec | typesafe/config | shape of the row |
|---|---|---|---|
| `diverges` | a value | a **different** value | `expect` + `java_expect` |
| `unsupported` | a value | refuses | `expect` + `java_error` |
| `lenient` | rejects | a value | `error` + `java_expect` |

`lenient` is the common one, and the one worth staring at: it is every input
HOCON forbids that typesafe/config waves through. `a = 01`, `a = -foo` and
`include.foo : 42` are all of this kind. An implementation aiming at
compatibility may copy the leniency; one aiming at conformance must not.

### What a runner must do with this

A runner reads the suite in one of two modes, and must support both:

- **spec** (the default) — score against `expect` / `error`. This is
  conformance to HOCON. A row marked `java: lenient` must be **rejected** to
  pass.
- **java** — on a row carrying `java_expect` / `java_error`, score against that
  instead. This is compatibility with typesafe/config, the implementation the
  JVM world actually runs, and it is a legitimate bar to aim at: a config that
  parses in production today should keep parsing.

Only the rows carrying a `java` kind differ between the modes. Everywhere else
the two ask the same question, so a mode switch is cheap: one lookup per row,
no second copy of the suite.

`report.py` renders both from the committed results in `conformance/reports/`.

`fill-expected.py --check` enforces the shape column — a row whose fields do
not match its declared kind is sent back as `review` instead of being scored.

So one suite answers two questions. Score a column against `expect` and it
says "am I HOCON". Score it against `java_expect` where present and `expect`
elsewhere and it says "am I compatible with the implementation everyone
actually runs". An implementation picks which bar it is aiming at; this repo
aims at the first and reports the second.

Invariants a row must satisfy, checked by `conformance/maintaining/fill-expected.py --check`:

- `java_expect` / `java_error` appear only together with `java`.
- without `java`, `expect` must equal what the oracle produces — otherwise
  someone edited a row by hand without declaring a divergence.

## Stage 3 cannot fill an unsupported row

When the oracle rejects an input, stage 3 has no value to write. The input may
be genuinely illegal — a negative case, and `error` is the right answer — or it
may be something the spec requires and typesafe/config never implemented, in
which case the correct `expect` can only be read out of the spec by a human or
by stage 5.

Stage 3 cannot tell those apart, and must not guess. It writes `error` and adds

```json
"review": "oracle rejected this — illegal per spec, or unsupported by java?"
```

A row carrying `review` is unresolved. Stage 5 either deletes the field (the
input really is illegal) or converts the row to `java: "unsupported"` with an
`expect` read from the spec. A `review` field that stage 5 leaves in place is a
row it was not confident about — that is the queue for a human, and
`report.py` marks those rows ⚠ rather than pretending they pass.

## Stage 5 is a different head

Stage 5 runs on the most capable model available and reads evidence, not
summaries: the spec range itself, the actual `.conf` inputs, the actual
recorded values. It never sees stage 2's notes about what stage 2 believed it
was doing. It is the last gate, and the only place in the pipeline where it can
come out that everything below it was wrong the whole time — an agent that
inherits the earlier reasoning cannot discover that.

Where stage 5 is not confident, it writes `review` with the question rather
than a verdict. An unresolved row is a cheap outcome; a confidently wrong row
poisons every column in the table.

## Multi-file and environment cases

Settled, the way o3co/xx.hocon settles it: a case that needs more than one
file is a directory, `<nnn>-<name>/main.conf` + `main.json`, with its fixtures
beside it. The oracles take such a case by path (`file:<path>`, stacked as
`resolve:file:<path>`) so includes resolve next to the file, exactly as they
would for an application. `run.sh` hands adapters the path to `main.conf`.

A case that needs environment variables carries `"env": {"NAME": "value"}` in
its sidecar. `run.sh` sets them for the adapter; `fill-expected.py` runs the
oracle in a separate process with that environment for each such case.
