# Section map

Every heading of `spec/HOCON.md`, and whether it can be pinned down by a
conformance case. A section marked ✅ gets a directory under `conformance/`
named by its slug; a section marked — is prose, rationale or API advice with no
observable parse behaviour.

| spec line | heading | directory | state |
|---|---|---|---|
| 59 | Goals / Background | — | — |
| 92 | Definitions | — | — |
| 115 | Unchanged from JSON | `unchanged-from-json` | ✅ 9 cases |
| 123 | Comments | `comments` | ✅ 6 cases |
| 128 | Omit root braces | `omit-root-braces` | ✅ 11 cases |
| 141 | Key-value separator | `key-value-separator` | ✅ 3 cases |
| 149 | Commas | `commas` | ✅ 8 cases |
| 165 | Whitespace | `whitespace` | ✅ 6 cases |
| 186 | Duplicate keys and object merging | `duplicate-keys-and-object-merging` | ✅ 9 cases |
| 240 | Unquoted strings | `unquoted-strings` | ✅ 17 cases |
| 288 | Multi-line strings | `multi-line-strings` | ✅ 7 cases |
| 304 | Value concatenation | `value-concatenation` | ✅ 4 cases |
| 321 | String value concatenation | `string-value-concatenation` | ✅ 13 cases |
| 382 | Array and object concatenation | `array-and-object-concatenation` | ✅ 13 cases |
| 435 | Concatenation with whitespace and substitutions | `concatenation-whitespace-and-substitutions` | ✅ 2 cases |
| 444 | Arrays without commas or newlines | `arrays-without-commas-or-newlines` | ✅ 7 cases |
| 472 | Path expressions | `path-expressions` | ✅ 19 cases |
| 521 | Paths as keys | `paths-as-keys` | ✅ 10 cases |
| 574 | Substitutions | `substitutions` | ✅ 24 cases |
| 653 | Self-referential substitutions | `self-referential-substitutions` | ✅ 6 cases |
| 719 | The += field separator | `plus-equals-field-separator` | ✅ 3 cases |
| 738 | Examples of self-referential substitutions | `self-referential-examples` | ✅ 14 cases |
| 893 | List values from environment variables | `list-values-from-environment-variables` | — no cases yet |
| 921 | Include syntax | `include-syntax` | ✅ 7 cases |
| 982 | Include semantics: merging | `include-merging` | ✅ 1 cases |
| 1008 | Include semantics: substitution | `include-substitution` | — no cases yet |
| 1051 | Include semantics: missing and required files | `include-missing-and-required` | — no cases yet |
| 1074 | Include semantics: file formats and extensions | `include-file-formats` | — no cases yet |
| 1109 | Include semantics: locating resources | `include-locating` | — no cases yet |
| 1184 | Conversion of numerically-indexed objects to arrays | `numerically-indexed-objects-to-arrays` | ✅ 8 cases |
| 1221 | MIME Type | — | — |
| 1230 | Automatic type conversions | — | — typed accessors, no parse behaviour |
| 1264 | Units format | `units-format` | ⚠ 6 cases, not measured |
| 1295 | Duration format | `duration-format` | ⚠ 9 cases, not measured |
| 1315 | Period format | `period-format` | ⚠ 7 cases, not measured |
| 1335 | Size in bytes format | `size-in-bytes-format` | ⚠ 5 cases, not measured |
| 1399 | Config object merging and file merging | `config-and-file-merging` | — no cases yet |
| 1441 | Java properties mapping | — | — JVM-specific |
| 1498 | Conventional configuration files for JVM apps | — | — JVM-specific |
| 1528 | Conventional override by system properties | — | — JVM-specific |
| 1534 | Substitution fallback to environment variables | `substitution-fallback-to-environment` | ✅ 1 cases |
| 1567 | hyphen-separated vs. camelCase | — | — naming advice |
| 1572 | Note on Java properties similarity | — | — |
| 1598 | Note on Windows and case sensitivity | — | — |

`(env)` needs environment variables set, `(multi-file)` needs more than one
input file — see the open questions in `PROCESS.md`.

⚠ **not measured.** `tools/oracle/Oracle.java` does `parseString(src).root().render()`
and nothing else — it never calls `getDuration()`, `getPeriod()` or `getBytes()`.
So for all 42 cases in the four unit sections the recorded `expect` is the literal
value surviving the parse (`t = 10s` → `{"t":"10s"}`), which every parser does and
which says nothing about the unit rules their `why` describes. The cases are real
and the inputs are right; the protocol cannot see the answer yet. Fixing this means
extending the oracle protocol with a typed-accessor request — a decision, not a
chore, so it is not made here.
