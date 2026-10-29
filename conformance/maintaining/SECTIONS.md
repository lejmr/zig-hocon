# Section map

Every heading of `spec/HOCON.md`, and whether it can be pinned down by a
conformance case. A section marked ✅ gets a directory under `conformance/suite/`
named by its slug; a section marked — is prose, rationale or API advice with no
observable parse behaviour.

| spec line | heading | directory | state |
|---|---|---|---|
| 59 | Goals / Background | — | — |
| 92 | Definitions | — | — |
| 115 | Unchanged from JSON | `unchanged-from-json` | ✅ 34 cases |
| 123 | Comments | `comments` | ✅ 15 cases |
| 128 | Omit root braces | `omit-root-braces` | ✅ 14 cases |
| 141 | Key-value separator | `key-value-separator` | ✅ 8 cases |
| 149 | Commas | `commas` | ✅ 15 cases |
| 165 | Whitespace | `whitespace` | ✅ 14 cases |
| 186 | Duplicate keys and object merging | `duplicate-keys-and-object-merging` | ✅ 30 cases |
| 240 | Unquoted strings | `unquoted-strings` | ✅ 35 cases |
| 288 | Multi-line strings | `multi-line-strings` | ✅ 11 cases |
| 304 | Value concatenation | `value-concatenation` | ✅ 2 cases |
| 321 | String value concatenation | `string-value-concatenation` | ✅ 19 cases |
| 382 | Array and object concatenation | `array-and-object-concatenation` | ✅ 23 cases |
| 435 | Concatenation with whitespace and substitutions | `concatenation-whitespace-and-substitutions` | ✅ 10 cases |
| 444 | Arrays without commas or newlines | `arrays-without-commas-or-newlines` | ✅ 7 cases |
| 472 | Path expressions | `path-expressions` | ✅ 22 cases |
| 521 | Paths as keys | `paths-as-keys` | ✅ 11 cases |
| 574 | Substitutions | `substitutions` | ✅ 41 cases |
| 653 | Self-referential substitutions | `self-referential-substitutions` | ✅ 8 cases |
| 719 | The += field separator | `plus-equals-field-separator` | ✅ 33 cases |
| 738 | Examples of self-referential substitutions | `self-referential-examples` | ✅ 77 cases |
| 893 | List values from environment variables | `list-values-from-environment-variables` | ✅ 6 cases |
| 921 | Include syntax | `include-syntax` | ✅ 16 cases |
| 982 | Include semantics: merging | `include-merging` | ✅ 19 cases |
| 1008 | Include semantics: substitution | `include-substitution` | ✅ 28 cases |
| 1051 | Include semantics: missing and required files | `include-missing-and-required` | ✅ 7 cases |
| 1074 | Include semantics: file formats and extensions | `include-file-formats` | ✅ 30 cases |
| 1109 | Include semantics: locating resources | `include-locating` | ✅ 5 cases |
| 1188 | Conversion of numerically-indexed objects to arrays | `numerically-indexed-objects-to-arrays` | ✅ 7 cases |
| 1225 | MIME Type | — | — |
| 1234 | Automatic type conversions | — | — typed accessors, no parse behaviour |
| 1268 | Units format | `units-format` | ⚠ 6 cases, not measured |
| 1299 | Duration format | `duration-format` | ⚠ 9 cases, not measured |
| 1319 | Period format | `period-format` | ⚠ 7 cases, not measured |
| 1339 | Size in bytes format | `size-in-bytes-format` | ⚠ 5 cases, not measured |
| 1403 | Config object merging and file merging | `config-and-file-merging` | ✅ 4 cases |
| 1445 | Java properties mapping | — | — JVM-specific |
| 1502 | Conventional configuration files for JVM apps | — | — JVM-specific |
| 1532 | Conventional override by system properties | — | — JVM-specific |
| 1538 | Substitution fallback to environment variables | `substitution-fallback-to-environment` | ✅ 10 cases |
| 1571 | hyphen-separated vs. camelCase | — | — naming advice |
| 1576 | Note on Java properties similarity | — | — |
| 1602 | Note on Windows and case sensitivity | — | — |

⚠ **not measured** by the suite. A sidecar records the parsed JSON, so for the 27
cases in the four unit sections `expect` is the literal value (`t = 10s` →
`{"t":"10s"}`). `tools/oracle/hocon-java` can read them typed (`as:duration:`,
`as:period:`, `as:bytes:`), and `src/units/parse.zig` checks each key that way,
but the sidecar format has no field for a typed answer yet.
