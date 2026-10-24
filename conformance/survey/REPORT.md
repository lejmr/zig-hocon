# Survey of HOCON implementations, 2026-10-24

21 implementations in 12 languages measured against the suite · 19 candidate cases · 6 zig-hocon bugs · 3 questionable suite rows · 3 spec ambiguities · 2 harness problems

What a survey of every HOCON implementation we could find, and of their test suites, turned up. Nothing here changes the suite or the published reports: the candidates sit in `conformance/candidates/`, unreviewed, and everything else is record. Like `maintaining/FINDINGS.md`, this is work, not a verdict.

Every claim is marked **[verified]** — reproduced by running it — or **[inferred]** — read from code, a spec sentence or another result, not run. zig-hocon means `main` at `1a6ae55` (v0.5.2, adapter version `code@70c35b1`); typesafe/config 1.4.9 is the repository's own oracle (`tools/oracle`); line numbers are `spec/HOCON.md`.

## What is in here

```
REPORT.md              this file
results/spec/*.json    run.sh --spec, the whole suite, one file per implementation
results/java/*.json    run.sh --java, the same
results/candidates/    run.sh --spec --dir conformance/candidates, one file per implementation
adapters/              the adapters for the 20 implementations that are not zig-hocon (README.md there)
tools/                 run-all.sh, run-candidates.sh, analyze.py, gen-candidates.py
corpus/                the scripts that mined other projects' tests, and the list of inputs where zig-hocon and Java differ
../candidates/         the 19 candidate cases, in the suite's own layout
```

## zig-hocon bugs

All six are reproduced on `main` with `zig-out/bin/hocon --json` **[verified]**, and each is a candidate case below. typesafe/config's behaviour is from the 1.4.9 oracle **[verified]**.

1. **`+=` inside `${p} { … }` silently drops data.** The most serious: no error, the earlier value is just gone. Candidate `plus-equals-field-separator/010`.
   - input: `p: { z: 0 }` / `p: ${p} { k: [a], k += b }`
   - zig-hocon: `{"p":{"z":0,"k":["b"]}}`; spec: `k` is `[a, b]` — `k += b` is `k = ${?k} [b]` (lines 718-736), and its previous value is the `k: [a]` just before it. The same object without `${p}` gives `[a, b]` in zig-hocon **[verified]**. Java fails with `BugOrBroken`; ekrich/sconfig gets `[a, b]` (sconfig `ConfigSubstitutionSharedTest`).
2. **Repeated `+=` inside an array element keeps only the last.** Candidate `plus-equals-field-separator/011`.
   - input: `a = [ { b += 1, b += 2, b += 3 } ]`
   - zig-hocon: `{"a":[{"b":[3]}]}`; spec: `[1, 2, 3]`, as `x { b += 1, b += 2 }` outside an array gives `[1, 2]` (lines 718-736). Java rejects `+=` inside an array (already pinned by `plus-equals-field-separator/006`).
3. **False `SubstitutionCycle` when the object is concatenated with a substitution.** Candidate `self-referential-substitutions/007`.
   - input: `x = {}` / `p = ${x} { k = [a], k = ${p.k} [b] }`
   - zig-hocon: `error: SubstitutionCycle` at 2:25; with the literal `{}` in place of `${x}` it resolves to `[a, b]`. Spec: the second `k` looks back to `k = [a]` (lines 655-661). Java fails with `BugOrBroken` (lightbend/config#647); sconfig resolves it.
4. **A substitution hidden by a later non-object is evaluated anyway.** Candidate `self-referential-examples/027`, taken from lightbend `ConfigSubstitutionTest` (around L1299).
   - input: `p: { a : ${y} }` / `p: ${x}` / `p: { a : { x : 1 } }` / `x: { a : 42 }`
   - zig-hocon: `error: Unresolved` at `${y}`; spec: `42` is not an object, so it hides `${y}`, which "is never evaluated and no error will be reported" (lines 778-780). Java resolves it to `{"p":{"a":{"x":1}},"x":{"a":42}}`.
5. **A cycle that looking back can break is reported as a cycle.** Candidate `self-referential-examples/028`, the "tricky cycle" from lightbend `ConfigSubstitutionTest`.
   - input: `d { a = ${i.b} }` / `i.b = 7` / `i = ${d}`
   - zig-hocon: `error: SubstitutionCycle` at 3:5; spec: "when possible the cycle must be broken by looking backward only" (lines 657-661, 696-712), and here `i.b = 7` is right behind. Java resolves it to `d.a = 7`, `i = {a: 7, b: 7}`.
6. **`${FOOBAR}` hidden by a later scalar, behind `${base}`.** Candidate `self-referential-examples/029`, [lightbend/config#812](https://github.com/lightbend/config/issues/812).
   - input: `base = {}` / `child = ${base} { foo = ${FOOBAR} }` / `child.foo = "test-foo"`
   - zig-hocon: `error: Unresolved` at `${FOOBAR}`; spec: hidden, never evaluated (lines 778-780). typesafe/config 1.4.9 and main and sconfig fail the same way; pyhocon gets it right.

Bugs 1, 3, 4 and 6 probably share one cause: an object concatenated with a substitution (`${x} { … }`) is not resolved the way the same object written out is. **[inferred]** — from the results only; the resolver was not read.

## Candidate cases

`conformance/candidates/<section>/<nnn>-<name>.{conf,json}`, the suite's own layout and sidecar format, numbered after the section's last case in `main` (`plus-equals-field-separator` starts at 010, leaving 009 free: renumber when they move). They are unreviewed, which is why they are not in `suite/`. Every sidecar carries `spec`, `rule`, a `why` naming its source, and `java`/`java_expect`/`java_error` where 1.4.9 parts ways. `tools/gen-candidates.py` writes all of them.

Each was run through all 21 implementations (`results/candidates/`) **[verified]**; "pass" counts implementations out of 21.

| candidate | source | zig-hocon | Java 1.4.9 | Java main | sconfig | pass |
|---|---|---|---|---|---|---|
| `array-and-object-concatenation/020-array-with-inner-merge-concatenated-with-substitution` | lightbend/config#751 | pass | fail (BugOrBroken) | fail | pass | 10 |
| `array-and-object-concatenation/021-plus-equals-in-object-concatenated-with-substituted-object` | sconfig#611 | open | open | open | open | review |
| `array-and-object-concatenation/022-sibling-reference-in-object-concatenated-with-substitution` | sconfig#611 | open | open | open | open | review |
| `arrays-without-commas-or-newlines/008-objects-on-one-line-in-an-array-merge` | lightbend/config#814 | pass | pass | pass | pass | 19 |
| `key-value-separator/007-omitted-separator-then-object-concatenation` | pyhocon `test_config_parser.py` | pass | fail (Parse) | fail | fail | 12 |
| `plus-equals-field-separator/010-plus-equals-inside-object-concatenated-with-substitution` | sconfig `ConfigSubstitutionSharedTest` | **fail** (bug 1) | fail | fail | pass | 5 |
| `plus-equals-field-separator/011-repeated-plus-equals-inside-a-list-element` | — | **fail** (bug 2) | fail | fail | fail | 4 |
| `self-referential-examples/027-substitution-in-merge-hidden-by-substituted-scalar` | lightbend `ConfigSubstitutionTest` | **fail** (bug 4) | pass | pass | pass | 13 |
| `self-referential-examples/028-cycle-through-a-merged-object-is-broken-by-looking-back` | lightbend `ConfigSubstitutionTest` | **fail** (bug 5) | pass | pass | pass | 7 |
| `self-referential-examples/029-field-in-object-concatenated-with-substitution-hidden-by-later-scalar` | lightbend/config#812 | **fail** (bug 6) | fail | fail | fail | 6 |
| `self-referential-substitutions/007-self-reference-inside-object-concatenated-with-substitution` | lightbend/config#647 | **fail** (bug 3) | fail | fail | pass | 8 |
| `self-referential-substitutions/008-self-referential-array-concatenation-in-object-merged-with-substitution` | lightbend/config#728 | pass | fail | fail | fail | 5 |
| `unchanged-from-json/028-integer-beyond-64-bits-is-a-number` | sconfig#631 | pass | fail (a string) | fail | fail | 7 |
| `unchanged-from-json/029-float-beyond-long-range-keeps-its-value` | lightbend `ConfigValueTest`, lightbend/config#873 | pass | fail (clamped to Long.MAX_VALUE) | pass | fail | 13 |
| `unchanged-from-json/030-unicode-escape-with-a-sign-is-illegal` | lightbend/config#884 | pass | fail (`"A"`) | fail | fail | 11 |
| `unchanged-from-json/031-unicode-escape-with-non-ascii-digits-is-illegal` | lightbend/config#884 | pass | fail (`"A"`) | fail | fail | 12 |
| `unchanged-from-json/032-exponent-with-explicit-plus` | lightbend `TestUtils` validJson | pass | pass | pass | pass | 15 |
| `unquoted-strings/026-hyphen-right-after-a-substitution` | everyday config (`${prefix}-svc`, `-Xmx${heap}m`) | open | open | open | open | review |
| `unquoted-strings/027-parentheses-are-allowed` | lightbend `TestUtils` validConf | pass | pass | pass | pass | 19 |

zig-hocon passes 10, fails the 6 above and leaves the 3 `review` rows open **[verified]**. The `java` markers on the sidecars are from the 1.4.9 oracle **[verified]**; the `java_since` on 029 records that main renders `9.223372036854776E18`, the same value **[verified]**.

How the candidates were found: about 33 repositories were cloned (the ones measured below and the ones under "Not measured"), 1 227 inline config strings were extracted from their test sources and 754 fixture files collected (`corpus/extract.py`), and each of the 1 981 inputs was run through zig-hocon and typesafe/config 1.4.9 (`corpus/runzig.sh`, `corpus/Batch.java`, `corpus/compare.py`). 1 299 agree on the value, 520 are rejected by both, 31 differ in value, 61 are rejected only by zig-hocon, 70 only by Java **[verified]**; `corpus/diffs.json` lists the 162 that differ. The candidates are the ones among them, and among the upstream issues they led to, that the suite does not already pin. The extracted inputs themselves are not committed — they are third-party test code under several licences — and `extract.py` rebuilds them from the clones.

## Implementations against the suite

Each row is `run.sh` over the 446 cases of `main` (suite digest `a8fe29692ae3406d`), both modes, results in `results/` **[verified]**.

| implementation | language | version | spec | java |
|---|---|---|---|---|
| **zig-hocon** | Zig | v0.5.2 (`code@70c35b1`) | **446** | 402 |
| typesafe/config | Java | main@a9e5a9d (2026-10-23) | 414 | 431 |
| ekrich/sconfig | Scala | 2.1.0 | 406 | 440 |
| o3co/go.hocon | Go | v1.14.2 | 403 | 398 |
| typesafe/config | Java | 1.4.9 (the oracle) | 402 | **446** |
| o3co/ts.hocon | TypeScript | @o3co/ts.hocon 1.14.3 | 400 | 398 |
| o3co/py.hocon | Python | hocon-parser 1.14.2 | 398 | 396 |
| o3co/rs.hocon | Rust | hocon-parser 1.14.2 | 398 | 394 |
| hocon2 | Python | 0.6.3 | 387 | 361 |
| mikai233/hocon-rs | Rust | 0.2.0 | 377 | 366 |
| puppetlabs/ruby-hocon | Ruby | 1.4.0 | 375 | 412 |
| @pushcorn/hocon-parser | JavaScript | 1.3.1 | 371 | 358 |
| puppetlabs/cpp-hocon | C++ | 4981ed4 (2025-01-14, archived) | 353 | 373 |
| akkadotnet/HOCON | C# | Hocon 2.0.4 | 348 | 337 |
| gurkankaymak/hocon | Go | v1.4.1 | 340 | 328 |
| mockersf/hocon.rs | Rust | 0.9.0, strict loader | 319 | 331 |
| AstekGroup/pulse-pyhocon | Python (Rust core) | 0.2.1 | 317 | 307 |
| chimpler/pyhocon | Python | 0.3.63 | 316 | 300 |
| emqx/hocon | Erlang | 7759b15 (2026-09-22) | 284 | 275 |
| go-akka/configuration | Go | a002c03 (2020) | 134 * | 143 * |
| hocon-parser (npm) | JavaScript | 1.0.1 | 175 * | 178 * |

\* Not to be trusted: these two adapters come from o3co/xx.hocon's ecosystem-bench unchanged and their scores look like an adapter problem rather than the parser's **[inferred]**, so they were left out of every conclusion here.

### Against the published reports

- **zig-hocon and typesafe/config 1.4.9** agree with `reports/` exactly (446/402 and 402/446) **[verified]**.
- **zig-hocon's report label is behind `main`**: `reports/zig-hocon.*.json` say `code@96d9b8a`, `main` measures as `code@70c35b1` — the release commit bumped `build.zig.zon`, which is in the digest. The scores are the same, but the pre-push hook will re-measure on the next push from a clone that has it enabled **[verified]**.
- **hocon2, py.hocon, rs.hocon and pulse-pyhocon are stale**: their reports were measured on the 445-case suite (digest `cd4bdae3133b2042`, 2026-10-19). On today's 446: hocon2 java 361 (report 360), py.hocon java 396 (395), pulse-pyhocon java 307 (306), and **rs.hocon java 394, not 386** **[verified]**. Spec scores are unchanged.
- **pyhocon** measures 316/300, its report says 315/299 on the same suite digest **[verified]** — one case moved; not chased down.

## Questionable expectations in the suite

None of these sidecars was changed.

- **`substitutions/039-undefined-optional-with-number-is-a-string`** (`a = ${?x}42` → `"42"`). Only 6 of 21 implementations pass it **[verified]**. Line 636 gives the empty-string rule for "a value concatenation with another string", and `42` is a number; the sidecar's `why` says itself that it "extends" the rule. typesafe/config, sconfig and ruby-hocon give the number 42 **[verified]**. Suggestion: `"also_valid": [{"a": 42}]`, or `review`.
- **`unchanged-from-json/027-unpaired-surrogate-escape-is-kept`**. Neither JSON (RFC 8259 calls the behaviour of an unpaired surrogate unpredictable) nor the spec says what an unpaired `\ud800` becomes **[inferred]**; the expectation is a choice, which the `why` should say, or `also_valid` should allow rejection.
- **`include-file-formats`** (strict JSON in an included `.json`). Reasonable, but the spec says it only by implication (`.json` is parsed as JSON); the `why`s should say so **[inferred]**.

The other contested families — number strictness, include with substitutions, an array at the root — are backed by spec sentences and fine as they are **[inferred]**.

## Where the spec is unclear

- **A hyphen right after a substitution** (`b = ${a}-bar`, `-Xms${x}m`). zig-hocon rejects it with `HyphenIsNotAJsonNumber` **[verified]**; 18 of the other 20 give `foo-bar`, emqx/hocon rejects it and hocon-parser (npm) produces garbage **[verified]**. Lines 270-276 forbid an unquoted string to *begin* with `-`, and do not say whether a token that continues a concatenation begins anything. Everyday config looks exactly like this, so it should be decided explicitly. Candidate `unquoted-strings/026` (`review`, `also_valid: rejected`).
- **Is `${x} { … }` the same as its value written out?** ([ekrich/sconfig#611](https://github.com/ekrich/sconfig/issues/611)) With `x: {k: [a]}`, `p: ${x} {k += b}` gives `[a, b]` in none of the 21 implementations: 15 give `[b]`, pyhocon and pulse-pyhocon `" b"`, the rest reject it or produce garbage **[verified]**. The literal `p: {k: [a]} {k += b}` gives `[a, b]` in zig-hocon, typesafe/config 1.4.9 and main and sconfig (pyhocon: `"b"`) **[verified]**. Under the "possible implementation" (lines 696-712) `p` is self-referential and `k`'s lookup skips `${x}`, which gives `[b]` **[inferred]**. Candidates `array-and-object-concatenation/021`, `022` (`review`). Bugs 1 and 3 hinge on the same question.
- **`include classpath(...)`.** zig-hocon rejects it (`UnsupportedInclude`); typesafe/config 1.4.9 and main and sconfig silently skip a missing classpath resource (`include classpath("nope.conf")` / `a = 1` gives `{"a":1}`) **[verified]**. Lines 926-949 allow both an implementation without a classpath and a missing include being silently ignored **[inferred]**; worth a sentence in `PROCESS.md` on which way the suite counts it.

## Harness

- **`run.sh` breaks on a raw `0x1E` in an adapter's output.** Results are stored as `\037`-separated fields in `\036`-terminated records (the comment above says NUL-delimited, which it is not), and `out` is not escaped; an output containing `0x1E` splits a record, the Python half raises `ValueError: not enough values to unpack` and the report comes out empty **[verified]** with a one-line adapter printing `{"a":"x\036y"}`. `0x1F` survives (the split is limited to 2) and `0x1C` is harmless **[verified]**. A fix is to store `out` hex- or base64-encoded, or to make the records really NUL-delimited.
- **Java adapters lose non-ASCII under `env -i`.** `run.sh` clears the locale, and a JVM with no locale writes `?` for every non-ASCII character. `-Dstdout.encoding=UTF-8 -Dfile.encoding=UTF-8` fixes it; `adapters/javashim/java` does that for the survey's JVM adapters, and the survey's `java-1.4.9` adapter, the oracle through the shim, matches the published Java report **[verified]**. Whether `tools/oracle/hocon-java` alone is affected on a machine with a UTF-8 locale was not checked.

## Not measured

Cloned and mined for test inputs or only looked at, but not run against the suite — no adapter was built for them in this pass:

- Go: go-hocon/hocon (475a042), go-ruby-hocon/hocon (0fa3c31), jdevelop/go-hocon (2017), sopranoworks/gekka-config (7dd23f8)
- JavaScript/TypeScript: josephtzeng/hocon-parser (2024), maor-rozenfeld/hocon-js (2021), tkint/hocon-parser (2021)
- Python: myjniak/hocon (9cbed92; 34 of its test inputs are in the corpus)
- Rust: zolkko/hocon (db0be91)
- C/C++: nanomq/hocon (2024), alw017/cpp-hocon-parser (2024)
- JVM: dhakehurst/net.akehurst.kotlin.hocon (Kotlin), einnxk/Parser-Lib
- Haskell: aleperaltabazas/hocon (2020) · Elixir: zookzook/hocon (2020) · PHP: shanethehat/php-hocon (2015)

Not rerun either: the Java oracle for the five self-reference rows beyond the candidates, and no implementation's speed.

## Reproduce

```sh
zig build                                        # zig-hocon itself
cd conformance/survey/adapters && make build     # Go, TypeScript, Rust, Python, Ruby adapters; the rest: adapters/README.md
cd ../../..
conformance/survey/tools/run-all.sh sconfig pyhocon ...          # whole suite, both modes → results/
conformance/survey/tools/run-candidates.sh zig-hocon sconfig ... # the candidates → results/candidates/
(cd conformance/survey && python3 tools/analyze.py)              # suite rows ordered by how few implementations pass
```

JVM adapters need `JAVA_HOME` (JDK 21 was used); the adapters expect upstream clones under `$IMPL` (default `/tmp/impl`) and toolchains under `$TOOLS` (default `/tmp/tools`) where they need them. The corpus scripts in `corpus/` still carry the absolute paths of the machine they ran on; they are a record of how the inputs were mined, not a tool.
