# Stage 5 findings

4 divergences · 30 defective cases · 66 uncovered sentences

What the validation pass turned up and did **not** fix. The divergences it was
confident about are already in the sidecars; everything below is work, not record.

This pass ran *before* the tie-break rule in `PROCESS.md` was settled, so where a
divergence says `expect` was left at java's value, the row is still unresolved —
`fill-expected.py` now flags those with `review`.

## syntax-basics

The three directories map honestly onto lines 110-140: the comments section is complete and fully in agreement with the spec, and omit-root-braces covers all four of its normative sentences. The two places where the suite had silently recorded typesafe/config behaviour against a `why` that said the opposite — leading-zero numbers and the array root — are now marked `diverges` and `unsupported`, leaving UTF-8 validity and the unrepresentable-float clause as the real uncovered corners.

**Divergences marked in the sidecars**

- `unchanged-from-json/009-number-leading-zero-illegal` — **diverges** _(expect left at java's value — unresolved under the tie-break rule)_
  - spec: "allowed number formats matches JSON" (line 120) — JSON's grammar forbids a zero followed by further digits, so `01` is not a valid number literal.
  - java: Accepts it: the tokenizer collects `01`, Long.parseLong succeeds, and the value comes out as the number 1. Recorded expect was {"a": 1}, which contradicts the sentence quoted in `why`.
- `omit-root-braces/006-array-root-unaffected` — **unsupported**
  - spec: "JSON documents must have an array or object at the root" and the wrap only fires "if the file does not begin with a square bracket or curly brace" (lines 130, 134-136) — a file starting with `[` is left unwrapped and is a valid array-rooted document, so `[1, 2, 3]` is the array [1,2,3].
  - java: Has no array-rooted config at all: parsing succeeds internally but the Config API rejects the document with a WrongType error (LIST rather than OBJECT).

**Cases that are wrong about the spec** — the case, not the implementation

- omit-root-braces/004-empty-file: `why` asks a question instead of stating a rule ("this case checks whether HOCON's implicit-brace wrapping ... extends to an empty file as well"), leaving the outcome to the oracle. The spec settles it: the wrap rule is unconditional for a file that does not begin with `[` or `{`, so an empty file is `{}` and the "empty files are invalid documents" clause is about JSON only. expect {} is right; the `why` should assert that, not ask it.

**Uncovered normative sentences**

- "files must be valid UTF-8" (line 117) — no case at all. Every .conf in these three directories is pure ASCII; 001-quoted-string uses a \u escape, not a raw multi-byte sequence, so neither valid non-ASCII UTF-8 nor a malformed byte sequence is pinned.
- "as in JSON, some possible floating-point values are not represented, such as `NaN`" (lines 120-121) — no case. Nothing pins what `a = NaN` (or Infinity) does.
- "quoted strings are in the same format as JSON strings" (line 118) — only the accepting half is covered (001). No case pins the rejecting half: a JSON-illegal string such as an unknown escape `\q`, a raw newline or control character inside quotes, or an unterminated quote.

## separators

All eleven cases in key-value-separator and commas map cleanly onto the eight normative sentences of HOCON.md lines 141–164, and every recorded `expect`/`error` follows from the sentence quoted in its `why` — the three-element arrays, the ignored trailing comma, and the four rejections are each a spec bullet verbatim, so no sidecar needed editing. The only weakness is coverage rather than correctness: the "at least one ASCII newline" qualifier is never exercised in the negative, which is precisely where typesafe/config's value concatenation would show up.

**Uncovered normative sentences**

- "...need not have a comma between them as long as they have at least one ASCII newline (`\n`, decimal value 10) between them." — the qualifier has no case: nothing pins two array elements or two object fields separated only by spaces/tabs on a single line (no comma, no newline). This is the interesting corner, because typesafe/config does not reject `a = [1 2 3]` — value concatenation turns it into one element — so the missing case is also the most likely place in this range for a spec/implementation gap.
- Same sentence, the `\n` decimal-10 specificity: no case separates two values by a lone carriage return (`\r`) or by a Unicode line separator (U+2028) to pin that only ASCII LF counts as the comma substitute.
- "these same comma rules apply to fields in objects" is pinned only for three of the five bullets (single trailing comma, newline instead of comma, two commas in a row). The object counterparts of `[1,2,3,,]` (two trailing commas) and `[,1,2,3]` (initial comma) have no case.

## whitespace-and-duplicates

The duplicate-keys-and-object-merging directory maps faithfully and completely onto lines 186–239: all six normative sentences (later-wins, objects-merge, the three merge bullets, and merge-prevention-by-intervening-non-object) have an isolating case, and all six recorded values are exactly what the spec's own worked examples require, so the oracle and the spec agree everywhere here. The whitespace directory is weaker: the four cases that pin the nonbreaking spaces and the BOM are sound, but the two error cases mislabel which sentence they test and do not discriminate the whitespace claim they cite, and several members of the spec's whitespace list (tab, CR, ordinary Zs) have no case at all — no genuine spec/typesafe-config divergence exists in this range, because typesafe/config's own isWhitespace adds back exactly the nonbreaking spaces and the BOM that the spec's Java note says Character.isWhitespace omits, so no sidecar was edited.

**Cases that are wrong about the spec** — the case, not the implementation

- conformance/whitespace/003-unicode-line-paragraph-separator.json — `why` names the wrong rule. It claims the case pins "U+2028 (Zl) and U+2029 (Zp) count as whitespace", but the recorded outcome is a parse error, and a parse error does NOT isolate that claim: with `a = 1 b = 2 c = 3`, an implementation that treats U+2028/U+2029 as whitespace produces the concatenation `1 b` followed by a stray `=` (error), and an implementation that treats them as ordinary unquoted-string characters produces the single token `1 b` followed by a stray `=` (also error). What the input actually isolates is the other sentence in the range — "in this spec 'newline' refers only and specifically to ASCII newline 0x000A" — i.e. a Unicode separator is whitespace but does not terminate a field. `why` should quote that sentence. To pin whitespace-ness itself the input has to put the separator where a non-whitespace character would change the key or value, e.g. ` a = 1` expecting key `a`.
- conformance/whitespace/005-ascii-separator-control-chars.json — same defect. `why` claims the case pins that 0x1C–0x1F are whitespace, but `a\x1C=\x1D1\x1Eb\x1F=2` errors either way: as whitespace it is the concatenation `1 b` followed by a stray `=`; as non-whitespace it is key `a\x1C`, value `\x1D1\x1Eb\x1F`, then a stray `=`. The error is produced by 0x1E not being a newline, not by the characters being whitespace. Either re-word `why` around the "newline means only 0x000A" sentence, or move the separator to a position that discriminates (e.g. `\x1Ca = 1` expecting key `a`).
- conformance/duplicate-keys-and-object-merging/001-later-scalar-wins.json — `spec` is `HOCON.md#duplicate-keys`, which is not a heading in spec/HOCON.md. The heading at line 186 is "Duplicate keys and object merging", anchor `#duplicate-keys-and-object-merging`, which is what the other five sidecars in the directory use. The case body itself (a = 1 / a = 2 → {a: 2}) is correct and isolates the rule.

**Uncovered normative sentences**

- Whitespace, second bullet: "tab (`\t` 0x0009)". No case in conformance/whitespace contains a tab character at all — every case uses ASCII space or the exotic character under test.
- Whitespace, second bullet: "carriage return ('\r' 0x000D)". No case contains a CR. This is the one genuinely interesting untested member of the list, because the range also says "newline" means only 0x000A — so `a = 1\rb = 2` should be whitespace-but-not-a-separator (an error), while `a = 1\r\nb = 2` should parse.
- Whitespace, first bullet: "any Unicode space separator (Zs category) ... including nonbreaking spaces". Only the three nonbreaking Zs characters the spec names by number (0x00A0, 0x2007, 0x202F) are covered, by cases 001 and 006. No ordinary non-ASCII Zs character (e.g. U+2000 EN QUAD, U+3000 IDEOGRAPHIC SPACE) is exercised, so "the whole Zs category" is pinned only by its three most exotic members.
- Whitespace, first bullet: "line separator (Zl category), or paragraph separator (Zp category)" as whitespace. Case 003 is the only case naming them, and per wrong_cases it does not isolate the claim, so nothing in the suite actually distinguishes an implementation that treats U+2028/U+2029 as whitespace from one that treats them as unquoted-string characters.
- Whitespace, second bullet: file/group/record/unit separators (0x001C–0x001F) as whitespace. Same situation as the previous item — case 005 mentions them but does not isolate the claim.
- Whitespace, second bullet: "newline ('\n' 0x000A)" as whitespace. Only covered incidentally, as the line terminator inside multi-field cases; no case pins it directly. Arguably fine, but there is no dedicated case.
- Whitespace, third paragraph: "The BOM (0xFEFF) must also be treated as whitespace." Case 002 covers the BOM only at the very start of the file, where an implementation might strip it as an encoding marker rather than as whitespace. No case puts the BOM mid-document, e.g. around the `=` of a later field, which is where the whitespace claim (as opposed to a BOM-stripping hack) would actually be tested.

## unquoted-strings

The section maps to the spec faithfully: all seventeen cases quote sentences that are actually in lines 240-287, and sixteen of them record values that follow from those sentences, including the error cases for '@', backslash, '!' and the raw control character in a quoted string. One real divergence exists (012, `-foo`, where java's number-parse fallback produces a string the spec forbids, now marked `"java": "diverges"` with the oracle value kept since the spec names no outcome for the failure), one case claims a token structure its output cannot show (006), and the digit-initial half of the "may not begin with" rule is uncovered.

**Divergences marked in the sidecars**

- `conformance/unquoted-strings/012-unquoted-cannot-start-with-hyphen.conf` — **diverges** _(expect left at java's value — unresolved under the tie-break rule)_
  - spec: "An unquoted string may not _begin_ with the digits 0-9 or with a hyphen (`-`, 0x002D) ... The initial number character, plus any valid-in-JSON number characters that follow it, must be parsed as a number value." For `a = -foo` the initial number character is a lone `-` with no number characters after it; `-` is not a number, and no reading of the spec makes the result a string starting with a hyphen.
  - java: typesafe/config gathers `-`, fails to parse it as a number, and falls back to emitting it as unquoted text, which then concatenates with `foo` into the string "-foo" -- a string that begins with a hyphen.

**Cases that are wrong about the spec** — the case, not the implementation

- 006-truefoo-parses-as-true-then-foo: the input cannot isolate the rule its `why` quotes. `why` claims `truefoo` parses as the boolean token `true` followed by the unquoted string `foo`, but the expect is the string "truefoo", which is exactly what a single unquoted string would also produce -- the spec itself concedes this in the same paragraph ("this distinction doesn't matter much because of value concatenation"). typesafe/config in fact tokenises the whole run as one unquoted text and only compares the completed token against true/false/null, so it does NOT do what the `why` describes, yet the recorded value is identical. The case pins the output, not the parse it claims to pin; the `why` should be reworded to claim only the observable result.

**Uncovered normative sentences**

- "An unquoted string may not _begin_ with the digits 0-9" -- no case covers a digit-initial sequence whose number parse fails (e.g. `a = 1.2.3` or `a = 1x2`). 008 (`10.0bar`) only covers the case where the leading run IS a valid number. This is the digit-side twin of the hyphen divergence in 012 and is where java's number-parse fallback to unquoted text shows again; it is the most valuable uncovered sentence in the range.
- "forbidden characters: ... or whitespace" -- whitespace is listed as a forbidden character, but no case pins that whitespace ends an unquoted string (the covered forbidden chars are only '@', '\\', '!', '#'). Hard to isolate because `a = foo bar` becomes a value concatenation, but the list member is currently untested here.
- "its initial characters do not parse as `true`, `false`, `null`, or a number" -- only the `true` arm is exercised (006). No case starts a token with `false` or `null` (e.g. `a = nullfoo`, `a = falsefoo`).

## multi-line-strings

Six of the seven cases map cleanly onto lines 288-303: 001/007 pin the open-and-scan-until-closing-\"\"\" rule, 002 pins \"newlines and whitespace receive no special treatment\", and 004/005 pin the Scala rule that a run of three or more quotes closes the string with the extras kept — 005's greedy `foo\"\"` in particular is exactly what the spec's \"any 'extra' quotes are part of the string\" demands, and typesafe/config agrees, so no divergence is provable anywhere in this range. The one failure is 003, which is supposed to carry the section's only remaining normative sentence (unicode escapes not interpreted) but contains a literal `A` instead of an escape, leaving that sentence — and the broader \"used unmodified\" rule for backslash escapes — with no coverage at all.

**Cases that are wrong about the spec** — the case, not the implementation

- conformance/multi-line-strings/003-unicode-escape-not-interpreted: the input does not contain a unicode escape at all. The .conf is literally `a = """A"""` (bytes 61 20 3d 20 22 22 22 41 22 22 22 0a) — a bare capital A, no backslash. The `why` claims "A stays literal rather than becoming A", but the file never has `A`, so nothing about escape interpretation is exercised. Worse, `expect` is `{"a": "A"}`, which is exactly the value an implementation that DID interpret the escape would produce — so even if the input were fixed to `a = """A"""`, the recorded expect would contradict the spec sentence it quotes (the spec requires the six literal characters A). The case needs its input changed to contain the escape and its expect changed to the literal `A`; as it stands it pins nothing.

**Uncovered normative sentences**

- "Unlike Scala, and unlike JSON quoted strings, Unicode escapes are not interpreted in triple-quoted strings." — no working case covers it. 003 is the intended case but its input has no escape sequence (see wrong_cases), so this sentence is effectively untested.
- "...all Unicode characters until a closing \"\"\" sequence are used unmodified to create a string value." — the "unmodified" half is only tested for plain text and newlines (001, 002, 007). No case puts a backslash inside a triple-quoted string, so the rule that ordinary JSON escapes (`\n`, `\t`, `\\`) also stay literal — the practical consequence of "unmodified", and the one an implementer is most likely to get wrong by reusing the quoted-string scanner — is uncovered.
- The degenerate boundary of "any sequence of at least three quotes ends the multi-line string": the empty multi-line string (six quotes, `a = """\"\"\"`) has no case. It is where a tokenizer that counts the opening quotes toward the closing run misbehaves, and neither 004 nor 005 reaches it since both have content before the closing run.

## string-concatenation

All thirteen cases in these two directories map cleanly onto spec lines 304-381, and every recorded `expect`/`error` follows from the sentence its `why` quotes, so nothing here is the oracle's behaviour standing in for the spec's — no sidecar was edited. The weakness is coverage rather than correctness: several normative clauses are pinned only in one of their two halves (trailing whitespace, `false`, objects-in-concatenation, objects as keys), and quoted strings never appear as concatenation operands anywhere.

**Cases that are wrong about the spec** — the case, not the implementation

- string-value-concatenation/003-leading-and-trailing-whitespace-trimmed: the `why` quotes both halves of "Whitespace before the first and after the last simple value must be discarded" (spec 346-348), but the input `a =   foo   bar   baz` has no trailing whitespace at all, so only the leading half is pinned. The trailing half is unverified by this case despite the name and the `why` claiming it; the input would have to end in spaces (or the `why` be narrowed to leading whitespace only).

**Uncovered normative sentences**

- "Objects and arrays do not make sense as field keys." (spec 319) — no case feeds an object or array literal into a key position (e.g. `{ b = 1 } = 2`). value-concatenation/004 covers only the positive half of that paragraph.
- "quoted and unquoted strings are themselves" (spec 365) and the seven-character equivalence of `foo bar` with `"foo bar"` (spec 356-358) — no case in either directory puts a quoted string into a concatenation (`a = "foo" bar`, `a = foo" "bar`). Every concatenation case uses unquoted operands plus one substitution.
- "it is invalid for arrays or objects to appear in a string value concatenation" (spec 373-374) — only the array half is pinned (string-value-concatenation/002, `a = foo [1, 2]`). No case pins the object half (`a = foo { b = 1 }`), which is a separate code path in any parser since object-with-object concatenation is legal.
- "`true` and `false` become the strings `"true"` and `"false"`" (spec 363) — only `true` is pinned (006). `false` in a concatenation has no case.
- "String value concatenations never span ... a character that is not part of a simple value" (spec 336) — pinned only incidentally, by the comma in string-value-concatenation/005's array. No case isolates a non-simple-value character as the terminator outside an array element.

## array-object-concatenation

The three directories map to the spec faithfully wherever the cases are self-contained: every literal-input case (arrays and objects concatenating, second-object-overrides, newlines within versus between, `[ 1 2 3 4 ]` as one string, whitespace never separating fields) matches the sentence it quotes, all four of the spec's worked examples are reproduced, and I found no place in lines 382-471 where typesafe/config genuinely parts ways with the spec text, so no sidecar needed a `java` field or a changed value. The weakness is systematic rather than scattered: eight of the twenty-two cases use substitutions that are never defined, so the oracle collapsed them all into `UnresolvedSubstitution` and they now pin the undefined-substitution rule from another section instead of the sentence in their `why` - which is also why the whole 'concatenation with whitespace and substitutions' note is effectively uncovered.

**Cases that are wrong about the spec** — the case, not the implementation

- conformance/array-and-object-concatenation/004-substitution-counts-as-array-for-concatenation.conf (`a : ${x} [ 1, 2 ]`): the input does not isolate the rule. `why` says a substitution that resolves to an array counts as an array for concatenation, but `${x}` is never defined, so the recorded `error: UnresolvedSubstitution` follows from the undefined-substitution rule (outside this line range), not from the concatenation rule. Nothing here distinguishes array-counting from any other unresolved substitution. To isolate: define `x : [ 0 ]` first and expect `[0, 1, 2]`.
- conformance/array-and-object-concatenation/005-substitution-counts-as-object-for-concatenation.conf (`a : ${x} { c : 1 }`): same defect as 004 - `${x}` undefined, so the recorded error is about resolution, not about a substitution counting as an object. Define `x : { b : 1 }` and expect `{b: 1, c: 1}`. Case 010 (the inheritance example) is currently the only thing pinning this sentence for objects; 011/012 pin it for arrays.
- conformance/array-and-object-concatenation/006-newline-between-values-prevents-concatenation.conf (`arr = [\n  ${a}\n  [ 1, 2 ]\n]`): the input cannot discriminate. `${a}` is undefined, so the result is `UnresolvedSubstitution` under either reading - `[ ${a}, [1,2] ]` and `[ ${a} [1,2] ]` both error. Define `a = [ 0 ]` and expect `[[0], [1,2]]`; the non-conforming variant would yield `[[0,1,2]]`.
- conformance/array-and-object-concatenation/008-array-cannot-be-field-key.conf (`[ 1, 2 ] : 3`): weak isolation. The document starts with `[`, so the error is attributable to the document root not being an object (or to trailing tokens after it), not to an array appearing in key position. The recorded error still agrees with the spec, but the case does not pin the sentence. Nest it, e.g. `a { [ 1, 2 ] : 3 }`.
- conformance/array-and-object-concatenation/009-object-cannot-be-field-key.conf (`{ a : 1 } : 3`): same weakness - the leading `{ a : 1 }` is consumed as the root object and the error comes from the trailing `: 3`, not from an object used as a key. Nest it, e.g. `a { { b : 1 } : 3 }`. Neither 008 nor 009 covers the clause 'whether concatenation is involved or not'.
- conformance/concatenation-whitespace-and-substitutions/001-unquoted-whitespace-between-substitutions-is-significant-for-strings.conf (`a = ${foo} ${bar}`): `foo` and `bar` are undefined, so the recorded `UnresolvedSubstitution` says nothing about whitespace being significant between string-valued substitutions. The point of the sentence - that the space survives into the value - is untested. Define `foo = x`, `bar = y` and expect `"x y"`.
- conformance/concatenation-whitespace-and-substitutions/002-quoted-whitespace-between-substitutions-is-error.conf (`a = ${foo}" "${bar}`): undefined substitutions again, so the recorded error is a resolution failure, not the 'quoted whitespace should be an error' rule, and the case cannot tell the two apart. The spec sentence sits in a paragraph about substitutions resolving to objects or lists, so the isolating input is `foo = {a:1}`, `bar = {b:2}`, `x = ${foo}" "${bar}`. The `why` also asserts that unquoted whitespace is 'merely ignored or preserved', conflating the two halves of the paragraph (ignored for objects/lists, significant for strings).
- conformance/arrays-without-commas-or-newlines/005-unquoted-string-concatenation-with-substitutions-in-array.conf: `${name}` and `${world}` are undefined, so the case records a resolution error and never demonstrates the element grouping its `why` describes. Define `name` and `world` and expect two string elements.
- conformance/arrays-without-commas-or-newlines/006-two-elements-each-a-substitution-concatenation.conf (`a = [ ${a} ${b}, ${x} ${y} ]`): undefined substitutions, and `${a}` inside the value of `a` makes it self-referential, dragging in the self-referential-substitution rules from a different spec section. Neither the comma-vs-whitespace grouping nor the concatenation is observable. Use four defined keys with names other than `a`.

**Uncovered normative sentences**

- 'Unquoted whitespace must be ignored in between substitutions which resolve to objects or lists.' - no case covers it; the only two cases in that directory concern strings and quoted whitespace, and both are unresolvable. Needs e.g. `x = {a:1}`, `y = {b:2}`, `z = ${x}   ${y}` expecting `{a:1, b:2}`.
- 'the substitutions may turn out to be strings (which makes the whitespace between them significant)' - the significance of the space in a resolved string concatenation is never observed, since 001 errors on undefined keys.
- 'Quoted whitespace should be an error.' - no working case; 002 errors for an unrelated reason.
- 'Newlines _between_ prevent concatenation' at field-value level, e.g. `a : [ 1, 2 ]` followed on the next line by `    [ 3, 4 ]`. Case 006 is the only dedicated one and cannot discriminate; arrays-without-commas/003 covers the rule only for array elements, not field values.
- 'Arrays and objects cannot be field keys, whether concatenation is involved or not.' - the 'whether concatenation is involved or not' clause has no case (a concatenated key such as `{a:1} {b:2} : 3` or `[1] [2] : 3`).
- 'it is an error if they are mixed' is covered only in the array-then-object order; object-then-array (`a : { c : 3 } [ 1, 2 ]`) has no case.
- Object concatenation whose second operand is a substitution resolving to an object appears only inside the inheritance worked example (010); there is no minimal case, and none at all for a substitution on both sides (`a : ${x} ${y}`) in this section.

## path-expressions

Thirteen of the fifteen cases map cleanly onto the quoted spec sentences, and every recorded oracle value is what the spec text demands — including the four numeric-path bullets, which typesafe/config gets right because it keeps a number token's original text. Nothing in this range is a genuine spec/implementation divergence, so no sidecar was edited; the weaknesses are one case that asserts an error instead of the rule it claims to pin (015), two cases with a meaningless `resolve` flag, and four normative sentences left effectively uncovered.

**Cases that are wrong about the spec** — the case, not the implementation

- 015-dotted-path-in-substitution: the input `x = ${foo.bar}` with `resolve: true` and no `foo` defined cannot isolate the rule its `why` claims. The recorded outcome is an UnresolvedSubstitution error, identical whether the parser split `foo.bar` into two elements or kept it as one element `foo.bar` — nothing in the result depends on the dot being a separator. Pinning that sentence needs a resolvable input (e.g. `foo { bar = 1 }` plus `x = ${foo.bar}` expecting `x: 1`), ideally contrasted with `${"foo.bar"}`.
- 013-substitution-in-key-invalid and 014-nested-substitution-invalid carry `resolve: true`, but both fail while parsing the path expression, before any resolution happens. The flag misleads: it suggests the rejection depends on the resolver, when the sentence quoted in `why` ("path expressions ... may not contain substitutions") is purely syntactic. Inputs and `why` are otherwise correct.

**Uncovered normative sentences**

- "Path expressions are syntactically identical to a value concatenation, except that they may not contain substitutions." — the concatenation half is untested. 002/005 concatenate adjacent tokens, but nothing pins whitespace-separated unquoted tokens inside one path element (e.g. `a b.c = 1` giving the two-element path `a b` / `c`), which is what "identical to a value concatenation" buys.
- "it's essential to retain the _original_ string representation of the number as it appeared in the file (rather than converting it back to a string with a generic number-to-string library function)" — no case can fail if an implementation round-trips the number. `10.0foo`, `foo10.0` and `1.2.3` all survive naive double-to-string conversion (or never become numbers at all). The sentence needs an input whose original text differs from its canonical rendering, e.g. `1.10 = 1` (elements `1` and `10`, not `1` and `1`), or a leading-zero / exponent form.
- "If you have an array or element value consisting of the single value `true`, it's a value concatenation and retains its character as a boolean value." — only the element-value half is covered (008, `x = true`). No case covers the array half, e.g. `x = [true]` keeping a boolean element rather than the string "true".
- "They appear in two places; in substitutions, like `${foo.bar}` ..." — with 015 discounted, no case exercises a path expression inside a substitution at all: no multi-element substitution path resolving through nested objects, no quoting inside one (`${"a.b"}` as a single element), and no empty-element or leading/trailing-dot rule applied to a substitution path (`${a..b}`).

## paths-as-keys

Seven of the eight cases map cleanly onto the spec sentences they quote: 001/002 pin the expansion rule, 003 the "merged in the usual way" example, 004 the whitespace-in-keys sentence, and 005/006/007 reproduce the spec's own three bullets for path-expressions-become-strings verbatim, each with the value the spec literally states. The only place spec and oracle part ways is 008, where the spec's "include may not begin a path expression in a key" prohibition is simply absent from typesafe/config; that sidecar now records an error with "java": "unsupported", and every normative sentence in lines 521-573 has at least one case.

**Divergences marked in the sidecars**

- `conformance/paths-as-keys/008-include-cannot-begin-key.conf` — **unsupported**
  - spec: "As a special rule, the unquoted string `include` may not begin a path expression in a key, because it has a special interpretation (see below)." — `include.foo : 42` is a key path expression beginning with unquoted `include`, so it is illegal and must be rejected.
  - java: typesafe/config has no such restriction: its include handling fires only on a bare `include` token followed by a resource argument, and `.` is ordinary unquoted-text material, so it reads the key as the two-element path include.foo and parses successfully to {"include":{"foo":42}}.

## substitutions

This section maps faithfully to lines 574-652: every case's recorded value follows from the sentence quoted in its `why`, and I found no place where typesafe/config and the spec part ways here — unsurprising, since this range is the core the reference implementation was written against, so no sidecar needed a `java` field. The weaknesses are coverage rather than correctness: one case (007) cannot actually fail an implementation that breaks the rule it claims to pin, one (002) reads on a sentence it does not measure, and the null-value rule plus the key-syntax-in-substitution rule have no case at all.

**Cases that are wrong about the spec** — the case, not the implementation

- 007-substitution-path-absolute: the input does not isolate "the path begins with the root configuration object, i.e. it is 'absolute' rather than 'relative'". With `a = 5` and `b { c = ${a} }` there is no `a` inside `b`, so an implementation that resolves relative-first and falls back to the root produces the same `b.c = 5`. Only a shadowing input (e.g. `a = 5`, `b { a = 10, c = ${a} }` expecting `c = 5`) distinguishes absolute lookup from relative-with-fallback, which is the failure mode this sentence exists to forbid. The recorded expect is correct; the case is just too weak to pin the rule.
- 002-optional-substitution-syntax: `why` cites the syntax sentence ("${?pathexpression} is the optional substitution syntax") but the recorded `expect: {}` is produced entirely by a different, later sentence — the bullet "if it is the value of an object field then the field should not be created" — which 012 already pins with a byte-identical shape. The case does demonstrate that `${?` is accepted where `${` would error, so it is not useless, but as written it reads on a sentence it does not actually measure.

**Uncovered normative sentences**

- "If a configuration sets a value to `null` then it should not be looked up in the external source. ... if you have `{ "HOME" : null }` in a root object, then `${HOME}` will never look at the environment variable." — no case at all. Even the half that needs no environment support is unpinned: `a = null` + `b = ${a}` (b must be null, not an error), and `a = null` + `b = ${?a}` (the field is created with null, because the path IS present in the tree — a null value is a found value, not an undefined substitution). That last distinction is the one implementations get wrong, and nothing in the directory covers it.
- "For substitutions which are not found in the configuration tree, implementations may try to resolve them by looking at system environment variables or other external sources of configuration." — no case. Permissive ("may") rather than strictly normative, and PROCESS.md lists environment cases as blocked on an `env` object in the sidecar, so this is a known-open gap rather than an oversight.
- "If a configuration consists of multiple files, it may even end up retrieving a value from another file", and the clause "in the entire document being parsed including all included files" in the latest-assigned-value paragraph — no case. Blocked on the multi-file case shape PROCESS.md defers to the includes sections.
- "This path expression has the same syntax that you could use for an object key." — no case. Every substitution in the directory uses a bare or bare-dotted path (`${a}`, `${animal.favorite}`). Nothing pins that key syntax carries into `${}`: a quoted element (`${"a b"}`), a mixed path (`${a."b c"}`), or whitespace trimming around the path (`${ a.b }`).
- "A substitution is replaced with any value type (number, object, string, array, true, false, null)." — pinned only for number (023) and array (022). Object, string, boolean and null are each unpinned, and object is the one with real content, since a substituted object participates in later merging rather than just being copied.

## self-referential

The three sections map faithfully onto lines 653-892: every worked example the spec spells out (path:"a:b:c" extension, the not-self-referential object/array cycles, the +=  desugaring, foo:${foo.a} producing {a:2,c:1}, bar.baz=43, the mutually-referring objects, ${?a}foo, the two- and three-step cycles, the order-dependent a/b pair) has a case whose recorded value is exactly the value the spec states, and I found no place where typesafe/config's behaviour contradicts a sentence I could quote — so no sidecar needed a "java" marker. The weaknesses are all in isolation rather than in values: two cases omit "resolve": true and therefore never test the resolution-time rule they name, one case's `why` quotes a classification sentence that does not by itself yield the recorded error, and three normative sentences near the end of the range (lazy evaluation, the optional escape from a non-self cycle, instance-keyed memoization) are unpinned.

**Cases that are wrong about the spec** — the case, not the implementation

- /Users/milos/src/tries/2026-07-23-zig-hocon-conformance/conformance/self-referential-examples/005-substitution-hidden-by-later-non-mergeable-value-is-never-evaluated.json — the sidecar omits "resolve": true (every sibling case has it). Per conformance/README.md substitutions stay unresolved by default, so the case never reaches resolution and the rule it claims to pin (lines 778-786: a substitution hidden by a later non-object value "is never evaluated and no error will be reported") is satisfied trivially: foo is 42 with or without the rule. The expect value is right; the case as configured does not isolate the rule.
- /Users/milos/src/tries/2026-07-23-zig-hocon-conformance/conformance/self-referential-examples/006-self-reference-cycle-ignored-when-overridden-by-literal.json — same defect, and it matters more here: "resolve" is absent, so the assertion that the initial foo : ${foo} cycle "must simply be ignored" (line 787-788) is never exercised. Unresolved, a 42-valued foo proves nothing about the cycle.
- /Users/milos/src/tries/2026-07-23-zig-hocon-conformance/conformance/self-referential-substitutions/002-self-referential-concatenation.json — the `why` quotes only the classification sentence (line 681 lists a : ${a}bc among self-referential fields), but the recorded outcome (error) does not follow from classification: it follows from lines 706-712, where looking backward leaves an empty document and the missing value becomes an error. With nothing defined before it, both readings — self-referential-looking-backward and unbreakable cycle — produce an error, so this input cannot distinguish them. The isolating input would be a prior value for `a` (as case 001 does for `path`), or the `why` should quote the look-backward/missing rule instead.

**Uncovered normative sentences**

- Lines 845-846, "lazy-evaluate the substitution target so there's no 'circularity by side effect'" — no case exercises it as a standalone rule. 008 covers the neighbouring sentence (resolve only the referenced field, do not recurse the whole object); nothing covers the inverse shape, where an outside reference into an object would create a cycle only if the object's other fields were resolved eagerly, e.g. a : ${b.c} with b : { c : 1, d : ${a} }.
- Lines 851-853, "the substitution is missing which is an error unless the ${?foo} optional-substitution syntax was used" — the optional escape is covered only for self-references (self-referential-substitutions/005, self-referential-examples/004). No case uses ${?} to defuse a genuine multi-field cycle such as bar : ${?foo} / foo : ${?bar}, which is the half of the sentence that pairs with 012 and 013.
- Lines 886-890, memoization "should be keyed by the substitution 'instance' ... rather than by the path inside the ${} expression, because substitutions may be resolved differently depending on their position in the file" — 014 covers only the consequence that a and b must agree. No case has two occurrences of the same path that must resolve to different values by position (e.g. foo : { a : 1 } / foo : ${foo} / bar : ${foo}, where the first instance looks backward and the second forward).
- Lines 800-804, the restatement that a field with an object or array value is not self-referential even when it references itself inside, has no case inside self-referential-examples. It is covered in substance by self-referential-substitutions/003 and 004, so this is a placement note rather than an uncovered rule.

## numeric-index-arrays

This section maps faithfully to lines 1184-1220: six of the seven observable normative bullets each have a case that isolates them (lazy/not-eager in 001, concatenation conversion in 003, the empty/no-integer-keys exclusion in 005 and 006, non-integer keys ignored in 004 and 008, sort-and-reindex in 007), and every recorded value follows from the bullet quoted in its `why`. The differentiated oracle results — arrays for 003/004/007/008 but `WrongType` for 005/006 — are exactly what the spec's bullets predict, so I found no place where typesafe/config parts ways with the text; the only weaknesses are case 002 citing the wrong sentence for the value it records, and two sentences (the automatic-type-conversion hook and the properties-file idiom) that this case format cannot reach.

**Cases that are wrong about the spec** — the case, not the implementation

- 002-properties-style-dotted-numeric-keys: the recorded value does not follow from the sentence quoted in `why`. `why` cites the worked example "This allows creating an array in a properties file like this: foo.0 = \"a\" / foo.1 = \"b\"" and says implementations should convert it to an array, but `expect` is `{"foo":{"0":"a","1":"b"}}` — an object. The object is correct (the lazy bullet forbids eager conversion, and nothing here forces a list), but that is the sentence case 001 already pins, so 002 isolates nothing new and its `why` points at a sentence that argues for the opposite value. Either `why` should be rewritten to say "the properties idiom written in a .conf file still stays an object, because conversion is lazy", or the case should be dropped as a duplicate of 001.

**Uncovered normative sentences**

- "the conversion should be done when you would do an automatic type conversion (see the section \"Automatic type conversions\" below)" — no case covers this. It is only observable through a typed accessor (getList on a numerically-indexed object), which a parse-to-JSON case shape cannot express; a case would need an API-level hook the suite does not have.
- "This allows creating an array in a properties file like this: foo.0 = \"a\" / foo.1 = \"b\"" — the properties-file origin of the rule is uncovered. The suite only parses HOCON files, where (per the lazy bullet) those two lines stay an object; case 002 uses a .conf and therefore does not pin this sentence. Covering it would need a .properties input, which the case format does not support.

## type-conversions

There is nothing to audit: conformance/automatic-type-conversions does not exist, so the section has no sidecar that could agree with, misread, or diverge from the spec - the whole line range is a gap, and SECTIONS.md marking it done-pending overstates what is on disk. That absence is arguably right rather than an oversight: this range sits under API Recommendations, and every rule in it is conditioned on "if an application asks for a value with a particular type", which the suite's .conf-plus-expect shape cannot express - a JSON rendering fixes one type per value and never issues a typed request - so the section needs either a sidecar field naming the requested type and expected coercion, or an explicit no-directory row like MIME Type's, not silent absence.

**Uncovered normative sentences**

- conformance/automatic-type-conversions/ does not exist: the section has zero cases, so every sentence below is uncovered. conformance/SECTIONS.md line 41 lists it as `automatic-type-conversions` with state "todo", but stage 2 never wrote it and README.md has no case table for it (25 section directories exist, 223 cases, none here).
- L1232-1233 (framing): "If an application asks for a value with a particular type, the implementation should attempt to convert types as follows" - nothing pins that conversion is driven by the requested type at all.
- L1235-1236: number to string - convert the number into a string representation that would be a valid number in JSON.
- L1237: boolean to string - should become the string "true" or "false".
- L1238: string to number - parse the number with the JSON rules.
- L1239-1243: string to boolean - exactly the six strings "true", "yes", "on", "false", "no", "off" convert, and no longer list is recommended.
- L1244-1246: string to null - the string "null" should become null when the application specifically asks for a null value.
- L1247-1248: numerically-indexed object to array (cross-reference to the section above). Partially covered elsewhere by conformance/numerically-indexed-objects-to-arrays (8 cases), but nothing exercises it as a requested-type conversion.
- L1250-1253: null to anything must NOT be converted - asking for a specific type and finding null should usually be an error.
- L1254: object to anything must NOT be converted.
- L1255: array to anything must NOT be converted.
- L1256: anything to object must NOT be converted.
- L1257-1258: anything to array must NOT be converted, with the single exception of numerically-indexed object to array.
- L1260-1262 is rationale, not normative (why object/array to-and-from string conversion is refused); it needs no case.

## units

The slice is faithful in the narrow sense: every `expect` is the correct parse of its input, no `why` invents a sentence the spec does not contain, and no genuine spec/typesafe-config divergence exists to record, because nothing in HOCON.md 1264-1398 is reachable by a parser. But it does not map to the spec in the sense stage 5 asks about - this whole line range specifies an optional post-parse API interpretation layer, so a parse-to-JSON suite records only value-concatenation behaviour under units-format filenames, and essentially every case would pass unchanged against an implementation that has never heard of units.

**Cases that are wrong about the spec** — the case, not the implementation

- STRUCTURAL, applies to all 42 cases in /Users/milos/src/tries/2026-07-23-zig-hocon-conformance/conformance/{units-format,duration-format,period-format,size-in-bytes-format}: the inputs do not isolate any rule in HOCON.md 1264-1398. Every sentence in that range describes how an *API* (getMilliseconds/getPeriod/getBytes) interprets an already-parsed value; HOCON parsing itself never converts a unit string. So each `expect` records only what value concatenation and quoted-string rules already decide, and would be byte-identical for an implementation with zero units support. Compounding this, the whole range is permissive ('Implementations may wish to support...'), so there is no mandatory behaviour to pin in the first place.
- /Users/milos/src/tries/2026-07-23-zig-hocon-conformance/conformance/units-format/002-quoted-string-with-no-unit-uses-default-unit.json: the sidecar contradicts the sentence it quotes. `why` says the value 'should be interpreted with the default unit, as if it were a number', but `expect` is the string "10", not the number 10. The quoted sentence is about the units API's interpretation, not about the parsed value; quoting it against a parse result is a misread.
- /Users/milos/src/tries/2026-07-23-zig-hocon-conformance/conformance/units-format/001-number-value-is-default-unit.json, duration-format/001-bare-number-is-milliseconds.json, period-format/001-bare-number-is-days.json, size-in-bytes-format/001-bare-number-is-bytes.json: four cases, one input (`x = 10`), one expect (`10`), four different `why` claims - milliseconds, days, bytes, 'the default unit'. The spec sentences genuinely differ (duration defaults to ms, period to days, size to bytes) yet the recorded cases are indistinguishable. At most one of the four earns its place.
- /Users/milos/src/tries/2026-07-23-zig-hocon-conformance/conformance/units-format/005-unit-name-must-be-letters-only.json, units-format/006-unit-before-number-is-illegal.json, duration-format/002-uppercase-unit-is-illegal.json, period-format/002-uppercase-unit-is-illegal.json, size-in-bytes-format/020-multiletter-unit-wrong-case-is-illegal.json: five cases whose names and `why` assert something 'is illegal', paired with an `expect` recording a successful parse. The spec readings are correct (`10m2` has a digit in the unit name; `ms10` inverts the grammar; `10MS`/`10D` are not the listed lowercase strings; `Kb` is not `kB`), but the suite cannot express the rejection, so these rows read as if the illegal input were accepted. Most misleading rows in the slice.
- /Users/milos/src/tries/2026-07-23-zig-hocon-conformance/conformance/period-format/007-month-m-ambiguous-with-duration-minutes.json: the quoted sentence is a parenthetical recommendation to callers of getTemporal() ('you will want to use `mo` rather than `m`'), not a normative rule about values. The input `p = 1m` is also already covered by 005-months-spellings.conf (`m = 5m`). Non-normative and duplicated.
- /Users/milos/src/tries/2026-07-23-zig-hocon-conformance/conformance/units-format/004-whitespace-optional-around-number-and-unit.json: the input `t = " 10 ms "` preserves whitespace because it is a *quoted* string - that is the quoted-string rule, not the units grammar. The name claims whitespace is optional but the input only exercises whitespace present. The interesting vehicle, unquoted `t = 10 ms` where HOCON's own whitespace-preserving concatenation is what makes the units grammar reachable, is absent.

**Uncovered normative sentences**

- 'an optional unit name consisting only of letters (letters are the Unicode `L*` categories, Java `isLetter()`)' - the Unicode L* clause is untested: no case uses a non-ASCII letter as a unit name, which is the only way the clause differs from 'ASCII letters'.
- The units-format grammar reached through an *unquoted* value: no case for `t = 10 ms`, where HOCON's own whitespace-preserving value concatenation produces the string the units grammar then has to accept. Only the quoted form is covered.
- The grammar requires a number ('optional whitespace / a number / optional whitespace / an optional unit name') - the unit name is optional, the number is not. No case for a string that is only a unit name, e.g. `t = "ms"`.
- 'If an API supports this, for each family of units it should define a default unit in the family.' - no case; not observable at parse level.
- 'Note: any value in zetta/zebi or yotta/yobi will overflow a 64-bit integer, and of course large-enough values in any of the units may overflow.' - no case. A bare number exceeding 64 bits (`s = 99999999999999999999`) is the one thing in this line range with a consequence visible in the parsed JSON, and the slice does not test it.
- 'The one-letter unit strings may be uppercase (note: duration units are always lowercase, so this convention is specific to size units).' - the cross-family contrast is not pinned: nothing puts the same uppercase one-letter unit in both a size and a duration position to show it is legal in one and not the other.

