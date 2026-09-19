# Section map

Every heading of `spec/HOCON.md`, and whether it can be pinned down by a
conformance case. A section marked ✅ gets a directory under `conformance/`
named by its slug; a section marked — is prose, rationale or API advice with no
observable parse behaviour.

| spec line | heading | directory | state |
|---|---|---|---|
| 59 | Goals / Background | — | — |
| 92 | Definitions | — | — |
| 115 | Unchanged from JSON | `unchanged-from-json` | ✅ todo |
| 123 | Comments | `comments` | ✅ todo |
| 128 | Omit root braces | `omit-root-braces` | ✅ todo |
| 141 | Key-value separator | `key-value-separator` | ✅ todo |
| 149 | Commas | `commas` | ✅ todo |
| 165 | Whitespace | `whitespace` | ✅ todo |
| 186 | Duplicate keys and object merging | `duplicate-keys-and-object-merging` | ✅ seeded (3) |
| 240 | Unquoted strings | `unquoted-strings` | ✅ todo |
| 288 | Multi-line strings | `multi-line-strings` | ✅ todo |
| 304 | Value concatenation | `value-concatenation` | ✅ todo |
| 321 | String value concatenation | `string-value-concatenation` | ✅ todo |
| 382 | Array and object concatenation | `array-and-object-concatenation` | ✅ todo |
| 435 | Concatenation with whitespace and substitutions | `concatenation-whitespace-and-substitutions` | ✅ todo |
| 444 | Arrays without commas or newlines | `arrays-without-commas-or-newlines` | ✅ todo |
| 472 | Path expressions | `path-expressions` | ✅ todo |
| 521 | Paths as keys | `paths-as-keys` | ✅ todo |
| 574 | Substitutions | `substitutions` | ✅ todo |
| 653 | Self-referential substitutions | `self-referential-substitutions` | ✅ todo |
| 719 | The `+=` field separator | `plus-equals-field-separator` | ✅ todo |
| 738 | Examples of self-referential substitutions | `self-referential-examples` | ✅ todo |
| 893 | List values from environment variables | `list-values-from-environment-variables` | ✅ todo (env) |
| 921 | Include syntax | `include-syntax` | ✅ todo (multi-file) |
| 982 | Include semantics: merging | `include-merging` | ✅ todo (multi-file) |
| 1008 | Include semantics: substitution | `include-substitution` | ✅ todo (multi-file) |
| 1051 | Include semantics: missing and required files | `include-missing-and-required` | ✅ todo (multi-file) |
| 1074 | Include semantics: file formats and extensions | `include-file-formats` | ✅ todo (multi-file) |
| 1109 | Include semantics: locating resources | — | — classpath, JVM-specific |
| 1184 | Conversion of numerically-indexed objects to arrays | `numerically-indexed-objects-to-arrays` | ✅ todo |
| 1221 | MIME Type | — | — |
| 1230 | Automatic type conversions | `automatic-type-conversions` | ✅ todo |
| 1264 | Units format | `units-format` | ✅ todo |
| 1295 | Duration format | `duration-format` | ✅ todo |
| 1315 | Period format | `period-format` | ✅ todo |
| 1335 | Size in bytes format | `size-in-bytes-format` | ✅ todo |
| 1399 | Config object merging and file merging | `config-and-file-merging` | ✅ todo (multi-file) |
| 1441 | Java properties mapping | — | — JVM-specific |
| 1498 | Conventional configuration files for JVM apps | — | — JVM-specific |
| 1528 | Conventional override by system properties | — | — JVM-specific |
| 1534 | Substitution fallback to environment variables | `substitution-fallback-to-environment` | ✅ todo (env) |
| 1567 | hyphen-separated vs. camelCase | — | — naming advice |
| 1572 | Note on Java properties similarity | — | — |
| 1598 | Note on Windows and case sensitivity | — | — |

`(env)` needs environment variables set, `(multi-file)` needs more than one
input file — see the open questions in `PROCESS.md`.
