# HOCON conformance suite

Every case here is one sentence of the [HOCON specification](../spec/HOCON.md), written as a config file and the value it must produce. The suite is data, not code: a runner in any language is a directory walk and a JSON compare.

## What is in here

```
suite/        the cases — one directory per heading of the specification
run.sh        point your parser at the suite, get a result out
adapters/     ten-line shims; example.sh is the one to copy
reports/      results we publish, one file per implementation and mode
maintaining/  how the suite is built and kept honest — you can ignore this
```

## Check your implementation

```sh
cp conformance/adapters/example.sh my-adapter.sh   # ~10 lines, edit one of them
conformance/run.sh --text -- ./my-adapter.sh       # read the result
conformance/run.sh -- ./my-adapter.sh > result.json
```

Needs a POSIX shell and python3. Nothing else, and nothing from outside this directory — the suite travels on its own.

Your adapter is called with one argument, the path to a `.conf` file. It prints the parsed config as compact JSON and exits 0, or exits non-zero to reject the input. Substitutions must be resolved; key order and JSON whitespace do not matter; stderr is yours.

### Two bars, one suite

```sh
conformance/run.sh --spec -- ./my-adapter.sh   # default: what HOCON requires
conformance/run.sh --java -- ./my-adapter.sh   # what typesafe/config 1.4.9 does
conformance/run.sh --java-version main -- ./my-adapter.sh   # what its unreleased main does
```

They ask the same question on every row but the 91 that carry a `java` kind — the ones where the specification and the reference implementation genuinely part ways. Aim at `--spec` if you want to be correct, at `--java` if you need configs that parse in the JVM world today to keep parsing. `maintaining/PROCESS.md` explains the difference and lists every row where it matters.

`--only <text>` narrows a run to matching paths, which is how you work through one section at a time.

## Layout

One directory per heading of the specification. The directory name is readable; the exact heading is the `spec` anchor every sidecar in it carries, and `maintaining/SECTIONS.md` is the map between the two. Inside, one case per pair of files:

```
suite/<spec-section>/<nnn>-<name>.conf    the input, verbatim
suite/<spec-section>/<nnn>-<name>.json    what it must produce
```

A case that needs more than one file — anything with `include` — is a directory instead:

```
suite/<spec-section>/<nnn>-<name>/main.conf    the input; this is what gets parsed
suite/<spec-section>/<nnn>-<name>/main.json    what it must produce
suite/<spec-section>/<nnn>-<name>/*             fixtures main.conf includes (.conf, .json, .properties)
```

A runner hands your adapter the path to `main.conf`; includes resolve beside it. Where a fixture needs an absolute path, as `include url("file:…")` does, it writes `@CASE_DIR@`: the runner then hands your adapter a copy of the case directory with `@CASE_DIR@` replaced by that copy's absolute path. A case that needs environment variables lists them in the sidecar as `"env": {"NAME": "value"}`, and the runner sets them for your adapter.

`maintaining/SECTIONS.md` maps every heading of the spec to its directory, or to the reason it has no observable parse behaviour. `maintaining/FINDINGS.md` records what the stage-5 review found, much of it fixed since; `maintaining/COVERAGE.md` lists the rules no case checks yet.

## The sidecar

```json
{
  "spec": "HOCON.md#duplicate-keys-and-object-merging",
  "why": "one sentence: what rule this case pins down",
  "expect": {"a": {"b": 1, "c": 2}}
}
```

`expect` is what the **specification** requires, not what any implementation does — see "Tie-break" in `maintaining/PROCESS.md`. A case that must be **rejected** carries no `expect`:

```json
{
  "spec": "HOCON.md#path-expressions",
  "why": "an empty path element is only legal written as \"\"",
  "error": "BadPath"
}
```

`error` is documentation, not an assertion — messages differ per implementation, so a runner asserts only that parsing failed.

A row where the reference implementation and the spec part ways carries `"java": "diverges" | "unsupported" | "lenient"` and, next to it, `"java_expect"` or `"java_error"` — what typesafe/config does with that same input. Those rows are the reason the suite exists; `maintaining/PROCESS.md` has the table of which kind means what.

Where the spec allows more than one answer, `"also_valid"` lists the others, and an output matching `expect` or any of them passes. `"rejected"` in the list lets an error pass too:

```json
{
  "spec": "HOCON.md#examples-of-self-referential-substitutions",
  "why": "the order a and b resolve in is undefined: both 1, both 2 or an error are all allowed, but a and b must agree",
  "expect": {"a": 1, "b": 1},
  "also_valid": [{"a": 2, "b": 2}, "rejected"]
}
```

A row carrying `"review"` is an open question for a human. It is neither a pass nor a failure. `--text` lists such rows apart from the failing ones, and they alone do not make `run.sh` exit 1.

Two directories assert features the specification only permits: `include-file-formats` (other formats, basename probing: "implementations may support") and `substitution-fallback-to-environment` together with `list-values-from-environment-variables` ("implementations may search external sources"). An implementation without them is still conformant; it fails those rows knowingly, and `--only` can leave them out.

`"resolve": true` marks a case that only means anything once substitutions are resolved. Resolve them always and it makes no difference to you.

## Readings the suite takes

Where the spec leaves room, the suite takes one reading and says so here, so a disagreement is with a stated choice and not a hidden one. Where typesafe/config is catching up, the row's `java_since` (or the `why`) names the upstream PR; those links are also listed under each reading.

- **A value that starts like a number** is a number only when it is one in JSON (L120, "allowed number formats matches JSON"); otherwise the longest JSON number at the start followed by text, as `10.0bar` is the number `10.0` then `bar` (L260-261). Settled: `01`, `1.`, `-.33`, `-0033`, `08080` and `127.0.0.1` are the text they were written as, and so are `-Xmx2g` and `1.2.3` — not an error on the letter of L272, and not typesafe/config's lenient number parser (`01` → `1`, marked `java: diverges`). That lenience is a tokenizer biproduct upstream leaves for compatibility ([lightbend/config#861](https://github.com/lightbend/config/pull/861) aligns `-.33` with `.33` as text and names leading zeros / trailing dots out of scope on purpose), not a HOCON rule. The same reading decides keys before `+=`: after a completed JSON number (or non-number text such as `1e`), `+=` is the field separator (L720+), so `3+=[]` and `1e+=1` are the keys `"3"` and `"1e"` (path-expressions/024) — not a separate open case; typesafe/config's Parse is the same biproduct eating `+` as an exponent. Rows: unchanged-from-json/009-014, 032, 033, unquoted-strings/033, substitutions/043, path-expressions/024, 025.
- **The order two fields resolve in** is undefined, and either order's result or an error is allowed (L866-881): a cycle through optionals is broken at the optional that closes it (L660-661, L714-716), memoized (L884-888). A row expects one order's result and lists the others in `also_valid`.
- **An undefined optional next to one other value** adds nothing, and the value keeps its type: `${?x}42` is `42` (L376, L636-637). An object or array next to leftover text is still an error (L373-374, L384-385); typesafe/config 1.4.9 drops that text silently, and [lightbend/config#862](https://github.com/lightbend/config/pull/862) (on main) makes it a `WrongType` — the same fix self-referential-examples/043 waits on when the cycle resolves to an object then `x`.
- **Substitutions in an included file** are looked up at the fixed-up path first, then at the original path (L1043-1049). Settled in two halves: (a) when an included optional vanishes without a cycle (`x.y = ${?nope}` then `a = ${x.y}` / `${?x.y}`), the original path must still be tried — so with a root `x.y = 0`, `a` is `0` (include-substitution/009, 011, 014). typesafe/config 1.4.9 ends the lookup instead (and 014 even depends on the name of an unrelated key); that is a bug, not HOCON, and [lightbend/config#863](https://github.com/lightbend/config/pull/863) (open) fixes it to this reading. (b) a self-reference looks back at the fixed-up path only — the original-path fallback is for referring to the application's root config, which a field referring to itself does not — so `a += 2` included at `k` is `k.a = [2]` (025, 027, 028); typesafe/config already matches, and #863 keeps a swallowed cycle from falling back.

## Published results

`reports/` holds one JSON per implementation and mode, produced by `run.sh` and committed. The page at `report.html`, which the repository's top-level README links to, is rendered from those files and nothing else — an implementation appears there because its result file is committed.

```sh
python3 conformance/maintaining/report.py          # re-render from reports/
```

Drop your own result into `reports/` and the local report picks it up.

## Not in the table

The published table keeps pyhocon, every Python parser of its own above 60 % against the spec, the best Rust one, and `hocon`, the Rust crate of that name, measured with its strict loader (the default one never fails); its repository is archived since 2023, and non-ASCII whitespace makes it panic. These were measured too and left out:

- **hocon-rs 0.2.0** (Rust, mikai233/hocon-rs): 448/588 (76.2 %) against the spec, behind rs.hocon (77.6 %).
- **hocon_** (Rust, pepa65): a republished fork of `hocon` 0.9.0, not measured on its own.
- **pyhocon-fix 0.0.4** (Python, 2018) and **dd-pyhocon 0.3.61** (Python, 2023): forks of pyhocon, within two cases of it on the 445-case suite of 2026-10-18 (316 and 314), not measured again; dd-pyhocon hangs on one merge-stack case.
- Not parsers of their own: `hocon` 0.3.0, `hocon-validator`, `pytyped-hocon`, `pyhocon-dantic` and `dataconf` wrap pyhocon; `atomr` (Rust/PyO3) builds its `Config` from TOML or a dict and parses no HOCON; chris-martin/hocon-python (2015) is an unfinished port of typesafe/config.

## Reusing this

BSD 3-Clause, like the rest of the repository. Vendor the directory, keep the licence, and tell us what broke — a case that is wrong about the spec is worth more to us as a bug report than a passing score is.
