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

So every case carries what the reference implementation does with it:

```json
{
  "spec": "HOCON.md#units-format",
  "why": "the spec lists 'µs' among the microsecond suffixes",
  "expect": {"t": "1µs"},
  "java": "unsupported"
}
```

`java` is absent when the oracle agrees with the spec. It is `"unsupported"`
when the spec describes behaviour the reference implementation does not have,
and `"diverges"` when the two disagree on the same input — with the
disagreement spelled out in `why`. Those rows are the deliverable: run the
suite as coverage against the `typesafe/config` sources and the uncovered
cases are the spec's unimplemented corners.

## Open, blocking their sections only

- **Multi-file cases** (includes, file merging). A case is a `.conf`/`.json`
  pair today. Includes need siblings on disk. Cheapest shape: when a case needs
  more than one file it becomes a directory with `main.conf` plus its
  neighbours and one `case.json`. Decide when the includes sections come up.
- **Environment cases** (`list-values-from-environment-variables`,
  `substitution-fallback-to-environment`). Needs an `env` object in the
  sidecar and a runner that honours it.
