# Regenerates conformance/candidates/ (run from that directory): one call per case.
import json, os
C = []
def case(section, name, conf, meta):
    os.makedirs(section, exist_ok=True)
    open(f"{section}/{name}.conf", "w", newline="").write(conf)
    open(f"{section}/{name}.json", "w").write(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
S = "HOCON.md#"
case("self-referential-substitutions", "007-self-reference-inside-object-concatenated-with-substitution",
 "x = {}\np = ${x} { k = [a], k = ${p.k} [b] }\n",
 {"spec": S+"self-referential-substitutions", "rule": ["self-referential-substitutions.2", "array-and-object-concatenation.2"],
  "why": "the second k refers to the field being defined, so it looks back to the earlier k = [a] in the same object; ${x} resolves to {} and concatenating an empty object changes nothing, so the result must equal the plain object { k = [a], k = ${p.k} [b] }, which every implementation resolves to [a, b]. typesafe/config fails with an internal error (BugOrBroken, lightbend/config#647); ekrich/sconfig resolves it",
  "expect": {"x": {}, "p": {"k": ["a", "b"]}}, "java": "unsupported", "java_error": "BugOrBroken", "resolve": True})
case("plus-equals-field-separator", "010-plus-equals-inside-object-concatenated-with-substitution",
 "p: { z: 0 }\np: ${p} { k: [a], k += b }\n",
 {"spec": S+"the--field-separator", "rule": ["the--field-separator.2", "the--field-separator.3"],
  "why": "k += b is k = ${?p.k} [b]; its previous value is the k: [a] just before it in the same object, so k is [a, b] -- the same object written without ${p} gives [a, b] everywhere. Losing [a] silently is data loss. typesafe/config fails with BugOrBroken; ekrich/sconfig gets [a, b] (sconfig ConfigSubstitutionSharedTest)",
  "expect": {"p": {"z": 0, "k": ["a", "b"]}}, "java": "unsupported", "java_error": "BugOrBroken", "resolve": True})
case("plus-equals-field-separator", "011-repeated-plus-equals-inside-a-list-element",
 "a = [ { b += 1, b += 2, b += 3 } ]\n",
 {"spec": S+"the--field-separator", "rule": ["the--field-separator.2", "the--field-separator.3", "the--field-separator.5"],
  "why": "each b += n appends to the previous b in the same object, as x { b += 1, b += 2 } gives [1, 2] outside a list; the first += has no previous value and starts the array. typesafe/config refuses += inside a list (see 006)",
  "expect": {"a": [{"b": [1, 2, 3]}]}, "java": "unsupported", "java_error": "Parse", "resolve": True})
case("self-referential-examples", "027-substitution-in-merge-hidden-by-substituted-scalar",
 "p: { a : ${y} }\np: ${x}\np: { a : { x : 1 } }\nx: { a : 42 }\n",
 {"spec": S+"examples-of-self-referential-substitutions", "rule": "examples-of-self-referential-substitutions.8",
  "why": "p.a is the merge of ${y}, 42 (from ${x}) and { x : 1 }; 42 is not an object, so it hides ${y}, which is never evaluated and its being undefined is no error. typesafe/config gets this right (lightbend ConfigSubstitutionTest)",
  "expect": {"p": {"a": {"x": 1}}, "x": {"a": 42}}, "resolve": True})
case("self-referential-examples", "028-cycle-through-a-merged-object-is-broken-by-looking-back",
 "d { a = ${i.b} }\ni.b = 7\ni = ${d}\n",
 {"spec": S+"examples-of-self-referential-substitutions", "rule": ["self-referential-substitutions.2", "self-referential-substitutions.4", "examples-of-self-referential-substitutions.22"],
  "why": "i = ${d} refers to d, whose a refers back to i.b, so i is self-referential; the cycle can be broken by looking back, where i.b is 7, so d.a is 7 and i is { b : 7 } merged with { a : 7 }. Breaking the cycle at d.a instead gives the same answer. typesafe/config resolves it (lightbend ConfigSubstitutionTest, the 'tricky cycle' with defaults/item1)",
  "expect": {"d": {"a": 7}, "i": {"a": 7, "b": 7}}, "resolve": True})
case("self-referential-examples", "029-field-in-object-concatenated-with-substitution-hidden-by-later-scalar",
 "base = {}\nchild = ${base} {\n  foo = ${FOOBAR}\n}\nchild.foo = \"test-foo\"\n",
 {"spec": S+"examples-of-self-referential-substitutions", "rule": ["examples-of-self-referential-substitutions.8", "array-and-object-concatenation.2"],
  "why": "child.foo = \"test-foo\" hides foo = ${FOOBAR}, which is never evaluated; ${base} is {} and must behave exactly as the literal {} does, and child = {} { foo = ${FOOBAR} } followed by the same override resolves everywhere. typesafe/config, sconfig and zig-hocon evaluate the hidden substitution anyway (lightbend/config#812); pyhocon does not",
  "expect": {"base": {}, "child": {"foo": "test-foo"}}, "java": "unsupported", "java_error": "UnresolvedSubstitution", "resolve": True})
case("array-and-object-concatenation", "020-array-with-inner-merge-concatenated-with-substitution",
 "tail = [ 2 ]\nfront = [\n  {\n    foo = 1\n    foo = ${?bar}\n  }\n] ${tail}\n",
 {"spec": S+"array-and-object-concatenation", "rule": "array-and-object-concatenation.2",
  "why": "the array counterpart of 018: an array whose object element holds a merge (foo = 1 then an undefined optional) concatenates with a substituted array. typesafe/config fails with BugOrBroken (lightbend/config#751); inlining tail as [ 2 ] works there",
  "expect": {"tail": [2], "front": [{"foo": 1}, 2]}, "java": "unsupported", "java_error": "BugOrBroken", "resolve": True})
case("self-referential-substitutions", "008-self-referential-array-concatenation-in-object-merged-with-substitution",
 "d { x = [] }, c : ${d}, c { x : ${c.x}[1, 2] }\n",
 {"spec": S+"self-referential-substitutions", "rule": ["self-referential-substitutions.2", "self-referential-substitutions.7"],
  "why": "c.x : ${c.x}[1, 2] looks back to c.x from ${d}, which is [], so c.x is [1, 2]; typesafe/config resolves the two-step form x : ${c.x}[1], x : ${c.x}[2] but reports a cycle for this one (lightbend/config#728)",
  "expect": {"d": {"x": []}, "c": {"x": [1, 2]}}, "java": "unsupported", "java_error": "UnresolvedSubstitution", "resolve": True})
case("key-value-separator", "007-omitted-separator-then-object-concatenation",
 "common_modules {} {perl: 1}\n",
 {"spec": S+"key-value-separator", "rule": ["key-value-separator.2", "array-and-object-concatenation.6"],
  "why": "a key followed by { may omit the separator, which makes this common_modules : {} {perl: 1}, an object concatenation of {} and {perl: 1}. typesafe/config only reads one object after an omitted separator and rejects the second brace (pyhocon tests/test_config_parser.py expects {perl: 1})",
  "expect": {"common_modules": {"perl": 1}}, "java": "unsupported", "java_error": "Parse"})
case("unchanged-from-json", "028-integer-beyond-64-bits-is-a-number",
 "a = 12321321837612378126213217321\n",
 {"spec": S+"unchanged-from-json", "rule": "unchanged-from-json.4",
  "why": "JSON puts no limit on the size of a number, and an unquoted string may not begin with a digit, so this is a number. typesafe/config turns an integer that fits neither a long nor its own rules into the string \"12321321837612378126213217321\" (ekrich/sconfig#631)",
  "expect": {"a": 12321321837612378126213217321}, "java": "diverges", "java_expect": {"a": "12321321837612378126213217321"}})
case("unchanged-from-json", "029-float-beyond-long-range-keeps-its-value",
 "a = 9223372036854775808.0\n",
 {"spec": S+"unchanged-from-json", "rule": "unchanged-from-json.4",
  "why": "the number 2^63 written as a float must keep its value; typesafe/config 1.4.9 renders it as 9223372036854775807 (clamped to Long.MAX_VALUE, lightbend ConfigValueTest, lightbend/config#873), main renders 9.223372036854776E18, which is the same value",
  "expect": {"a": 9223372036854775808.0}, "java": "diverges", "java_expect": {"a": 9223372036854775807},
  "java_since": {"version": "main", "by": "verified on lightbend/config main@a9e5a9d"}})
case("unchanged-from-json", "030-unicode-escape-with-a-sign-is-illegal",
 "a = \"\\u+041\"\n",
 {"spec": S+"unchanged-from-json", "rule": "unchanged-from-json.2",
  "why": "a JSON \\u escape is exactly four hex digits, and + is not one. typesafe/config reads the four characters with Integer.parseInt(_, 16), which accepts a sign, and yields \"A\" (lightbend/config#884)",
  "error": "InvalidEscape", "java": "lenient", "java_expect": {"a": "A"}})
case("unchanged-from-json", "031-unicode-escape-with-non-ascii-digits-is-illegal",
 "a = \"\\u\u0660\u0660\u0664\u0661\"\n",
 {"spec": S+"unchanged-from-json", "rule": "unchanged-from-json.2",
  "why": "Arabic-Indic digits are not JSON hex digits; typesafe/config's Integer.parseInt accepts any Unicode decimal digit and yields \"A\" (lightbend/config#884)",
  "error": "InvalidEscape", "java": "lenient", "java_expect": {"a": "A"}})
case("unquoted-strings", "026-hyphen-right-after-a-substitution",
 "a = foo\nb = ${a}-bar\n",
 {"spec": S+"unquoted-strings", "rule": ["unquoted-strings.12", "unquoted-strings.13"],
  "why": "-bar follows ${a} with no whitespace. If it is a new unquoted string it begins with a hyphen and must be rejected like 012; if the hyphen is 'inside' the concatenation it is plain text and b is foo-bar. Every other implementation measured, typesafe/config included, gives foo-bar, and the shape (${prefix}-service, -Xmx${heap}m) is everyday config",
  "expect": {"a": "foo", "b": "foo-bar"}, "also_valid": ["rejected"],
  "review": "does 'may not begin with a hyphen' apply to a token that continues a value concatenation after a substitution? zig-hocon rejects it today (HyphenIsNotAJsonNumber)", "resolve": True})
case("note-arrays-without-commas-or-newlines".replace("note-",""), "008-objects-on-one-line-in-an-array-merge",
 "a = [ { b = 1 } { c = 2 } ]\n",
 {"spec": S+"note-arrays-without-commas-or-newlines", "rule": ["note-arrays-without-commas-or-newlines.2", "array-and-object-concatenation.6"],
  "why": "non-newline whitespace between two objects in an array concatenates them into one merged element rather than separating two elements -- the trap in lightbend/config#814, which the spec requires",
  "expect": {"a": [{"b": 1, "c": 2}]}})
case("unquoted-strings", "027-parentheses-are-allowed",
 "a = (42)\n",
 {"spec": S+"unquoted-strings", "rule": "unquoted-strings.2",
  "why": "( and ) are not forbidden characters, so (42) is one unquoted string (lightbend TestUtils validConf)",
  "expect": {"a": "(42)"}})
case("unchanged-from-json", "032-exponent-with-explicit-plus",
 "a = 10e+3\n",
 {"spec": S+"unchanged-from-json", "rule": "unchanged-from-json.4",
  "why": "JSON allows a + sign after the exponent marker (lightbend TestUtils validJson [ 10e+3 ])",
  "expect": {"a": 10000}})
case("array-and-object-concatenation", "021-plus-equals-in-object-concatenated-with-substituted-object",
 "x: {k: [a]}\np: ${x} {k += b}\n",
 {"spec": S+"array-and-object-concatenation", "rule": ["array-and-object-concatenation.2", "the--field-separator.3"],
  "why": "${x} resolves to {k: [a]}, so p is {k: [a]} {k += b}, which every implementation resolves to k = [a, b]; with the substitution in place all of them give [b]",
  "expect": {"x": {"k": ["a"]}, "p": {"k": ["a", "b"]}},
  "review": "is a substitution required to behave exactly like its value inside an object concatenation (ekrich/sconfig#611)? Under the spec's 'possible implementation' p is self-referential and k's lookup skips ${x}, giving [b]", "resolve": True})
case("array-and-object-concatenation", "022-sibling-reference-in-object-concatenated-with-substitution",
 "x: {}\np: ${x} {y: 0, m: ${p.y}}\n",
 {"spec": S+"array-and-object-concatenation", "rule": ["array-and-object-concatenation.2", "examples-of-self-referential-substitutions.14"],
  "why": "with x = {} this is p: {} {y: 0, m: ${p.y}}, where m is 0 in every implementation; an object may refer to paths within itself. With the substitution every implementation reports a cycle",
  "expect": {"x": {}, "p": {"y": 0, "m": 0}},
  "review": "same question as 021 (ekrich/sconfig#611, row 4)", "resolve": True})
