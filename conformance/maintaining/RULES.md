# Rules

Every rule is one normative sentence of [`spec/HOCON.md`](../../spec/HOCON.md), quoted
verbatim. The id is the section's anchor in the spec and the sentence's position
among the section's rules, so `path-expressions.2` is the second rule under
[Path expressions](../../spec/HOCON.md#path-expressions). A case names the rule it
pins in its sidecar (`"rule"`, one id or a list when one input pins several);
`report.py` counts the rules no case names.

A sentence is a rule when a parser's output can be checked against it: the
parsed config as JSON, or the input being rejected. Rationale, history,
"for example:" lead-ins, advice about typed getters and JVM internals are not.
A sentence that only introduces a list ("exactly these strings are supported:")
is not a rule either; its items are, one each. Items that are fragments of one
grammar ("optional whitespace", "a number") stay in their introducing sentence.

Ids are stable: when the spec moves, append new rules at the end of their
section rather than renumbering.

## [Unchanged from JSON](../../spec/HOCON.md#unchanged-from-json)

| rule | line | sentence |
|---|---|---|
| `unchanged-from-json.1` | L117 | files must be valid UTF-8 |
| `unchanged-from-json.2` | L118 | quoted strings are in the same format as JSON strings |
| `unchanged-from-json.3` | L119 | values have possible types: string, number, object, array, boolean, null |
| `unchanged-from-json.4` | L120 | allowed number formats matches JSON; as in JSON, some possible floating-point values are not represented, such as `NaN` |

## [Comments](../../spec/HOCON.md#comments)

| rule | line | sentence |
|---|---|---|
| `comments.1` | L125 | Anything between `//` or `#` and the next newline is considered a comment and ignored, unless the `//` or `#` is inside a quoted string. |

## [Omit root braces](../../spec/HOCON.md#omit-root-braces)

| rule | line | sentence |
|---|---|---|
| `omit-root-braces.1` | L130 | JSON documents must have an array or object at the root. |
| `omit-root-braces.2` | L130 | Empty files are invalid documents, as are files containing only a non-array non-object value such as a string. |
| `omit-root-braces.3` | L134 | In HOCON, if the file does not begin with a square bracket or curly brace, it is parsed as if it were enclosed with `{}` curly braces. |
| `omit-root-braces.4` | L138 | A HOCON file is invalid if it omits the opening `{` but still has a closing `}`; the curly braces must be balanced. |

## [Key-value separator](../../spec/HOCON.md#key-value-separator)

| rule | line | sentence |
|---|---|---|
| `key-value-separator.1` | L143 | The `=` character can be used anywhere JSON allows `:`, i.e. to separate keys from values. |
| `key-value-separator.2` | L146 | If a key is followed by `{`, the `:` or `=` may be omitted. |

## [Commas](../../spec/HOCON.md#commas)

| rule | line | sentence |
|---|---|---|
| `commas.1` | L151 | Values in arrays, and fields in objects, need not have a comma between them as long as they have at least one ASCII newline (`\n`, decimal value 10) between them. |
| `commas.2` | L155 | The last element in an array or last field in an object may be followed by a single comma. |
| `commas.3` | L156 | This extra comma is ignored. |
| `commas.4` | L160 | `[1,2,3,,]` is invalid because it has two trailing commas. |
| `commas.5` | L161 | `[,1,2,3]` is invalid because it has an initial comma. |
| `commas.6` | L162 | `[1,,2,3]` is invalid because it has two commas in a row. |
| `commas.7` | L163 | these same comma rules apply to fields in objects. |

## [Whitespace](../../spec/HOCON.md#whitespace)

| rule | line | sentence |
|---|---|---|
| `whitespace.1` | L170 | any Unicode space separator (Zs category), line separator (Zl category), or paragraph separator (Zp category), including nonbreaking spaces (such as 0x00A0, 0x2007, and 0x202F). |
| `whitespace.2` | L173 | The BOM (0xFEFF) must also be treated as whitespace. |
| `whitespace.3` | L174 | tab (`\t` 0x0009), newline ('\n' 0x000A), vertical tab ('\v' 0x000B)`, form feed (`\f' 0x000C), carriage return ('\r' 0x000D), file separator (0x001C), group separator (0x001D), record separator (0x001E), unit separator (0x001F). |
| `whitespace.4` | L182 | While all Unicode separators should be treated as whitespace, in this spec "newline" refers only and specifically to ASCII newline 0x000A. |

## [Duplicate keys and object merging](../../spec/HOCON.md#duplicate-keys-and-object-merging)

| rule | line | sentence |
|---|---|---|
| `duplicate-keys-and-object-merging.1` | L189 | In HOCON, duplicate keys that appear later override those that appear earlier, unless both values are objects. |
| `duplicate-keys-and-object-merging.2` | L191 | If both values are objects, then the objects are merged. |
| `duplicate-keys-and-object-merging.3` | L194 | The assumption here is that duplicate keys are invalid JSON. |
| `duplicate-keys-and-object-merging.4` | L199 | add fields present in only one of the two objects to the merged object. |
| `duplicate-keys-and-object-merging.5` | L201 | for non-object-valued fields present in both objects, the field found in the second object must be used. |
| `duplicate-keys-and-object-merging.6` | L203 | for object-valued fields present in both objects, the object values should be recursively merged according to these same rules. |
| `duplicate-keys-and-object-merging.7` | L207 | Object merge can be prevented by setting the key to another value first. |
| `duplicate-keys-and-object-merging.8` | L208 | This is because merging is always done two values at a time; if you set a key to an object, a non-object, then an object, first the non-object falls back to the object (non-object always wins), and then the object falls back to the non-object (no merging, object is the new value). |
| `duplicate-keys-and-object-merging.9` | L238 | The intermediate setting of `"foo"` to `null` prevents the object merge. |

## [Unquoted strings](../../spec/HOCON.md#unquoted-strings)

| rule | line | sentence |
|---|---|---|
| `unquoted-strings.1` | L242 | A sequence of characters outside of a quoted string is a string value if: |
| `unquoted-strings.2` | L245 | it does not contain "forbidden characters": '$', '"', '{', '}', '[', ']', ':', '=', ',', '+', '#', '`', '^', '?', '!', '@', '*', '&', '\' (backslash), or whitespace. |
| `unquoted-strings.3` | L248 | it does not contain the two-character string "//" (which starts a comment) |
| `unquoted-strings.4` | L250 | its initial characters do not parse as `true`, `false`, `null`, or a number. |
| `unquoted-strings.5` | L253 | Unquoted strings are used literally, they do not support any kind of escaping. |
| `unquoted-strings.6` | L254 | Quoted strings may always be used as an alternative when you need to write a character that is not permitted in an unquoted string. |
| `unquoted-strings.7` | L258 | `truefoo` parses as the boolean token `true` followed by the unquoted string `foo`. |
| `unquoted-strings.8` | L259 | However, `footrue` parses as the unquoted string `footrue`. |
| `unquoted-strings.9` | L260 | Similarly, `10.0bar` is the number `10.0` then the unquoted string `bar` but `bar10.0` is the unquoted string `bar10.0`. |
| `unquoted-strings.10` | L265 | In general, once an unquoted string begins, it continues until a forbidden character or the two-character string "//" is encountered. |
| `unquoted-strings.11` | L267 | Embedded (non-initial) booleans, nulls, and numbers are not recognized as such, they are part of the string. |
| `unquoted-strings.12` | L270 | An unquoted string may not _begin_ with the digits 0-9 or with a hyphen (`-`, 0x002D) because those are valid characters to begin a JSON number. |
| `unquoted-strings.13` | L272 | The initial number character, plus any valid-in-JSON number characters that follow it, must be parsed as a number value. |
| `unquoted-strings.14` | L278 | Note that quoted JSON strings may not contain control characters (control characters include some whitespace characters, such as newline). |
| `unquoted-strings.15` | L280 | However, unquoted strings have no restriction on control characters, other than the ones listed as "forbidden characters" above. |

## [Multi-line strings](../../spec/HOCON.md#multi-line-strings)

| rule | line | sentence |
|---|---|---|
| `multi-line-strings.1` | L291 | If the three-character sequence `"""` appears, then all Unicode characters until a closing `"""` sequence are used unmodified to create a string value. |
| `multi-line-strings.2` | L293 | Newlines and whitespace receive no special treatment. |
| `multi-line-strings.3` | L294 | Unlike Scala, and unlike JSON quoted strings, Unicode escapes are not interpreted in triple-quoted strings. |
| `multi-line-strings.4` | L300 | HOCON works like Scala; any sequence of at least three quotes ends the multi-line string, and any "extra" quotes are part of the string. |

## [Value concatenation](../../spec/HOCON.md#value-concatenation)

| rule | line | sentence |
|---|---|---|
| `value-concatenation.2` | L310 | if all the values are simple values (neither objects nor arrays), they are concatenated into a string. |
| `value-concatenation.3` | L312 | if all the values are arrays, they are concatenated into one array. |
| `value-concatenation.4` | L314 | if all the values are objects, they are merged (as with duplicate keys) into one object. |
| `value-concatenation.5` | L317 | String value concatenation is allowed in field keys, in addition to field values and array elements. |

## [String value concatenation](../../spec/HOCON.md#string-value-concatenation)

| rule | line | sentence |
|---|---|---|
| `string-value-concatenation.1` | L327 | Only simple values participate in string value concatenation. |
| `string-value-concatenation.2` | L331 | As long as simple values are separated only by non-newline whitespace, the _whitespace between them is preserved_ and the values, along with the whitespace, are concatenated into a string. |
| `string-value-concatenation.3` | L335 | String value concatenations never span a newline, or a character that is not part of a simple value. |
| `string-value-concatenation.4` | L338 | A string value concatenation may appear in any place that a string may appear, including object keys, object values, and array elements. |
| `string-value-concatenation.5` | L346 | Whitespace before the first and after the last simple value must be discarded. |
| `string-value-concatenation.6` | L347 | Only whitespace _between_ simple values must be preserved. |
| `string-value-concatenation.7` | L363 | `true` and `false` become the strings `"true"` and `"false"`. |
| `string-value-concatenation.8` | L364 | `null` becomes the string `"null"`. |
| `string-value-concatenation.9` | L365 | quoted and unquoted strings are themselves. |
| `string-value-concatenation.10` | L366 | numbers should be kept as they were originally written in the file. |
| `string-value-concatenation.11` | L371 | a substitution is replaced with its value which is then converted to a string as above. |
| `string-value-concatenation.12` | L373 | it is invalid for arrays or objects to appear in a string value concatenation. |
| `string-value-concatenation.13` | L376 | A single value is never converted to a string. |

## [Array and object concatenation](../../spec/HOCON.md#array-and-object-concatenation)

| rule | line | sentence |
|---|---|---|
| `array-and-object-concatenation.1` | L384 | Arrays can be concatenated with arrays, and objects with objects, but it is an error if they are mixed. |
| `array-and-object-concatenation.2` | L387 | For purposes of concatenation, "array" also means "substitution that resolves to an array" and "object" also means "substitution that resolves to an object." |
| `array-and-object-concatenation.3` | L391 | Within a field value or array element, if only non-newline whitespace separates the end of a first array or object or substitution from the start of a second array or object or substitution, the two values are concatenated. |
| `array-and-object-concatenation.4` | L394 | Newlines may occur _within_ the array or object, but not _between_ them. |
| `array-and-object-concatenation.5` | L394 | Newlines _between_ prevent concatenation. |
| `array-and-object-concatenation.6` | L398 | For objects, "concatenation" means "merging", so the second object overrides the first. |
| `array-and-object-concatenation.7` | L401 | Arrays and objects cannot be field keys, whether concatenation is involved or not. |

## [Note: Concatenation with whitespace and substitutions](../../spec/HOCON.md#note-concatenation-with-whitespace-and-substitutions)

| rule | line | sentence |
|---|---|---|
| `note-concatenation-with-whitespace-and-substitutions.1` | L437 | When concatenating substitutions such as `${foo} ${bar}`, the substitutions may turn out to be strings (which makes the whitespace between them significant) or may turn out to be objects or lists (which makes it irrelevant). |
| `note-concatenation-with-whitespace-and-substitutions.2` | L440 | Unquoted whitespace must be ignored in between substitutions which resolve to objects or lists. |
| `note-concatenation-with-whitespace-and-substitutions.3` | L442 | Quoted whitespace should be an error. |

## [Note: Arrays without commas or newlines](../../spec/HOCON.md#note-arrays-without-commas-or-newlines)

| rule | line | sentence |
|---|---|---|
| `note-arrays-without-commas-or-newlines.1` | L446 | Arrays allow you to use newlines instead of commas, but not whitespace instead of commas. |
| `note-arrays-without-commas-or-newlines.2` | L447 | Non-newline whitespace will produce concatenation rather than separate elements. |
| `note-arrays-without-commas-or-newlines.3` | L470 | Non-newline whitespace is never an element or field separator. |

## [Path expressions](../../spec/HOCON.md#path-expressions)

| rule | line | sentence |
|---|---|---|
| `path-expressions.1` | L475 | They appear in two places; in substitutions, like `${foo.bar}`, and as the keys in objects like `{ foo.bar : 42 }`. |
| `path-expressions.2` | L478 | Path expressions are syntactically identical to a value concatenation, except that they may not contain substitutions. |
| `path-expressions.3` | L483 | When concatenating the path expression, any `.` characters outside quoted strings are understood as path separators, while inside quoted strings `.` has no special meaning. |
| `path-expressions.4` | L485 | So `foo.bar."hello.world"` would be a path with three elements, looking up key `foo`, key `bar`, then key `hello.world`. |
| `path-expressions.5` | L489 | The main tricky point is that `.` characters in numbers do count as a path separator. |
| `path-expressions.6` | L490 | When dealing with a number as part of a path expression, it's essential to retain the _original_ string representation of the number as it appeared in the file (rather than converting it back to a string with a generic number-to-string library function). |
| `path-expressions.7` | L496 | `10.0foo` is a number then unquoted string `foo` and should be the two-element path with `10` and `0foo` as the elements. |
| `path-expressions.8` | L498 | `foo10.0` is an unquoted string with a `.` in it, so this would be a two-element path with `foo10` and `0` as the elements. |
| `path-expressions.9` | L500 | `foo"10.0"` is an unquoted then a quoted string which are concatenated, so this is a single-element path. |
| `path-expressions.10` | L502 | `1.2.3` is the three-element path with `1`,`2`,`3` |
| `path-expressions.11` | L504 | Unlike value concatenations, path expressions are _always_ converted to a string, even if they are just a single value. |
| `path-expressions.12` | L507 | If you have an array or element value consisting of the single value `true`, it's a value concatenation and retains its character as a boolean value. |
| `path-expressions.13` | L511 | If you have a path expression (in a key or substitution) then it must always be converted to a string, so `true` becomes the string that would be quoted as `"true"`. |
| `path-expressions.14` | L515 | If a path element is an empty string, it must always be quoted. |
| `path-expressions.15` | L516 | That is, `a."".b` is a valid path with three elements, and the middle element is an empty string. |
| `path-expressions.16` | L517 | But `a..b` is invalid and should generate an error. |
| `path-expressions.17` | L518 | Following the same rule, a path that starts or ends with a `.` is invalid and should generate an error. |

## [Paths as keys](../../spec/HOCON.md#paths-as-keys)

| rule | line | sentence |
|---|---|---|
| `paths-as-keys.1` | L523 | If a key is a path expression with multiple elements, it is expanded to create an object for each path element other than the last. |
| `paths-as-keys.2` | L525 | The last path element, combined with the value, becomes a field in the most-nested object. |
| `paths-as-keys.3` | L544 | These values are merged in the usual way; which implies that: |
| `paths-as-keys.4` | L553 | Because path expressions work like value concatenations, you can have whitespace in keys: |
| `paths-as-keys.5` | L562 | Because path expressions are always converted to strings, even single values that would normally have another type become strings. |
| `paths-as-keys.6` | L566 | `true : 42` is `"true" : 42` |
| `paths-as-keys.7` | L567 | `3 : 42` is `"3" : 42` |
| `paths-as-keys.8` | L568 | `3.14 : 42` is `"3" : { "14" : 42 }` |
| `paths-as-keys.9` | L570 | As a special rule, the unquoted string `include` may not begin a path expression in a key, because it has a special interpretation (see below). |

## [Substitutions](../../spec/HOCON.md#substitutions)

| rule | line | sentence |
|---|---|---|
| `substitutions.1` | L579 | The syntax is `${pathexpression}` or `${?pathexpression}` where the `pathexpression` is a path expression as described above. |
| `substitutions.2` | L580 | This path expression has the same syntax that you could use for an object key. |
| `substitutions.3` | L584 | The `?` in `${?pathexpression}` must not have whitespace before it; the three characters `${?` must be exactly like that, grouped together. |
| `substitutions.4` | L593 | Substitutions are not parsed inside quoted strings. |
| `substitutions.5` | L593 | To get a string containing a substitution, you must use value concatenation with the substitution in the unquoted portion: |
| `substitutions.6` | L599 | Or you could quote the non-substitution portion: |
| `substitutions.7` | L603 | Substitutions are resolved by looking up the path in the configuration. |
| `substitutions.8` | L604 | The path begins with the root configuration object, i.e. it is "absolute" rather than "relative." |
| `substitutions.9` | L607 | Substitution processing is performed as the last parsing step, so a substitution can look forward in the configuration. |
| `substitutions.10` | L608 | If a configuration consists of multiple files, it may even end up retrieving a value from another file. |
| `substitutions.11` | L612 | If a key has been specified more than once, the substitution will always evaluate to its latest-assigned value (that is, it will evaluate to the merged object, or the last non-object value that was set, in the entire document being parsed including all included files). |
| `substitutions.12` | L618 | If a configuration sets a value to `null` then it should not be looked up in the external source. |
| `substitutions.13` | L625 | If a substitution does not match any value present in the configuration and is not resolved by an external source, then it is undefined. |
| `substitutions.14` | L627 | An undefined substitution with the `${foo}` syntax is invalid and should generate an error. |
| `substitutions.15` | L632 | if it is the value of an object field then the field should not be created. |
| `substitutions.16` | L633 | If the field would have overridden a previously-set value for the same field, then the previous value remains. |
| `substitutions.17` | L635 | if it is an array element then the element should not be added. |
| `substitutions.18` | L636 | if it is part of a value concatenation with another string then it should become an empty string; if part of a value concatenation with an object or array it should become an empty object or array. |
| `substitutions.19` | L640 | `foo : ${?bar}` would avoid creating field `foo` if `bar` is undefined. |
| `substitutions.20` | L640 | `foo : ${?bar}${?baz}` would also avoid creating the field if _both_ `bar` and `baz` are undefined. |
| `substitutions.21` | L644 | Substitutions are only allowed in field values and array elements (value concatenations), they are not allowed in keys or nested inside other substitutions (path expressions). |
| `substitutions.22` | L648 | A substitution is replaced with any value type (number, object, string, array, true, false, null). |
| `substitutions.23` | L649 | If the substitution is the only part of a value, then the type is preserved. |
| `substitutions.24` | L650 | Otherwise, it is value-concatenated to form a string. |

## [Self-Referential Substitutions](../../spec/HOCON.md#self-referential-substitutions)

| rule | line | sentence |
|---|---|---|
| `self-referential-substitutions.1` | L657 | substitutions normally "look forward" and use the final value for their path expression |
| `self-referential-substitutions.2` | L659 | when this would create a cycle, when possible the cycle must be broken by looking backward only (thus removing one of the substitutions that's a link in the cycle) |
| `self-referential-substitutions.3` | L671 | has a substitution, or value concatenation containing a substitution, as its value |
| `self-referential-substitutions.4` | L673 | where this field value refers to the field being defined, either directly or by referring to one or more other substitutions which eventually point back to the field being defined |
| `self-referential-substitutions.5` | L680 | `a : ${a}` |
| `self-referential-substitutions.6` | L681 | `a : ${a}bc` |
| `self-referential-substitutions.7` | L682 | `path : ${path} [ /usr/bin ]` |
| `self-referential-substitutions.8` | L684 | Note that an object or array with a substitution inside it is _not_ considered self-referential for this purpose. |
| `self-referential-substitutions.9` | L688 | `a : { b : ${a} }` |
| `self-referential-substitutions.10` | L689 | `a : [${a}]` |
| `self-referential-substitutions.11` | L691 | These cases are unbreakable cycles that generate an error. |
| `self-referential-substitutions.12` | L714 | Cycles should be treated the same as a missing value when resolving an optional substitution (i.e. the `${?foo}` syntax). |
| `self-referential-substitutions.13` | L716 | If `${?foo}` refers to itself then it's as if it referred to a nonexistent value. |

## [The `+=` field separator](../../spec/HOCON.md#the--field-separator)

| rule | line | sentence |
|---|---|---|
| `the--field-separator.1` | L721 | Fields may have `+=` as a separator rather than `:` or `=`. |
| `the--field-separator.2` | L721 | A field with `+=` transforms into a self-referential array concatenation, like this: |
| `the--field-separator.3` | L731 | `+=` appends an element to a previous array. |
| `the--field-separator.4` | L731 | If the previous value was not an array, an error will result just as it would in the long form `a = ${?a} [b]`. |
| `the--field-separator.5` | L733 | Note that the previous value is optional (`${?a}` not `${a}`), which allows `a += b` to be the first mention of `a` in the file (it is not necessary to have `a = []` first). |

## [Examples of Self-Referential Substitutions](../../spec/HOCON.md#examples-of-self-referential-substitutions)

| rule | line | sentence |
|---|---|---|
| `examples-of-self-referential-substitutions.1` | L740 | In isolation (with no merges involved), a self-referential field is an error because the substitution cannot be resolved: |
| `examples-of-self-referential-substitutions.2` | L745 | When `foo : ${foo}` is merged with an earlier value for `foo`, however, the substitution can be resolved to that earlier value. |
| `examples-of-self-referential-substitutions.3` | L745 | When merging two objects, the self-reference in the overriding field refers to the overridden field. |
| `examples-of-self-referential-substitutions.4` | L756 | Then `${foo}` resolves to `{ a : 1 }`, the value of the overridden field. |
| `examples-of-self-referential-substitutions.5` | L759 | It would be an error if these two fields were reversed, so first: |
| `examples-of-self-referential-substitutions.6` | L767 | Here the `${foo}` self-reference comes before `foo` has a value, so it is undefined, exactly as if the substitution referenced a path not found in the document. |
| `examples-of-self-referential-substitutions.7` | L771 | Because `foo : ${foo}` conceptually looks to previous definitions of `foo` for a value, the error should be treated as "undefined" rather than "intractable cycle"; as a result, the optional substitution syntax `${?foo}` does not create a cycle: |
| `examples-of-self-referential-substitutions.8` | L778 | If a substitution is hidden by a value that could not be merged with it (by a non-object value) then it is never evaluated and no error will be reported. |
| `examples-of-self-referential-substitutions.9` | L785 | In this case, no matter what `${does-not-exist}` resolves to, we know `foo` is `42`, so `${does-not-exist}` is never evaluated and there is no error. |
| `examples-of-self-referential-substitutions.10` | L787 | The same is true for cycles like `foo : ${foo}, foo : 42`, where the initial self-reference must simply be ignored. |
| `examples-of-self-referential-substitutions.11` | L790 | A self-reference resolves to the value "below" even if it's part of a path expression. |
| `examples-of-self-referential-substitutions.12` | L797 | Here, `${foo.a}` would refer to `{ c : 1 }` rather than `2` and so the final merge would be `{ a : 2, c : 1 }`. |
| `examples-of-self-referential-substitutions.13` | L801 | If a field has an object or array value, for example, then it is not self-referential even if there is a reference to the field itself inside that object or array. |
| `examples-of-self-referential-substitutions.14` | L806 | Implementations must be careful to allow objects to refer to paths within themselves, for example: |
| `examples-of-self-referential-substitutions.15` | L815 | The implementation must only resolve the `foo` field in `bar`, rather than recursing the entire `bar` object. |
| `examples-of-self-referential-substitutions.16` | L818 | Because there is no inherent cycle here, the substitution must "look forward" (including looking at the field currently being defined). |
| `examples-of-self-referential-substitutions.17` | L820 | To make this clearer, `bar.baz` would be `43` in: |
| `examples-of-self-referential-substitutions.18` | L827 | Mutually-referring objects should also work, and are not self-referential (so they look forward): |
| `examples-of-self-referential-substitutions.19` | L837 | Another tricky case is an optional self-reference in a value concatenation, in this example `a` should be `foo` not `foofoo` because the self reference has to "look back" to an undefined `a`: |
| `examples-of-self-referential-substitutions.20` | L845 | lazy-evaluate the substitution target so there's no "circularity by side effect" |
| `examples-of-self-referential-substitutions.21` | L847 | "look forward" and use the final value for the path specified in the substitution |
| `examples-of-self-referential-substitutions.22` | L849 | if a cycle results, the implementation must "look back" in the merge stack to try to resolve the cycle |
| `examples-of-self-referential-substitutions.23` | L851 | if neither lazy evaluation nor "looking only backward" resolves a cycle, the substitution is missing which is an error unless the `${?foo}` optional-substitution syntax was used. |
| `examples-of-self-referential-substitutions.24` | L860 | A multi-step loop like this should also be detected as invalid: |
| `examples-of-self-referential-substitutions.25` | L875 | Implementations are allowed to handle this by setting both `a` and `b` to 1, setting both to `2`, or generating an error. |
| `examples-of-self-referential-substitutions.26` | L883 | Implementations must set both `a` and `b` to the same value in this case, however. |
| `examples-of-self-referential-substitutions.27` | L886 | Memoization should be keyed by the substitution "instance" (the specific occurrence of the `${}` expression) rather than by the path inside the `${}` expression, because substitutions may be resolved differently depending on their position in the file. |

## [List values from environment variables](../../spec/HOCON.md#list-values-from-environment-variables)

| rule | line | sentence |
|---|---|---|
| `list-values-from-environment-variables.1` | L902 | This is only supported for environment variables and not system properties or path expressions |
| `list-values-from-environment-variables.2` | L904 | When a substitution with the `[]` suffix is resolved via environment variable fallback, the implementation will look up `MY_LIST_0`, `MY_LIST_1`, `MY_LIST_2`, and so on (incrementing the index) until an environment variable is not found. |
| `list-values-from-environment-variables.3` | L907 | The collected values form a list. |
| `list-values-from-environment-variables.4` | L910 | `MY_LIST_0` is not set), a required substitution `${MY_LIST[]}` is an error, while an optional substitution `${?MY_LIST[]}` is treated as undefined (the key is removed from the config). |
| `list-values-from-environment-variables.5` | L914 | Each element value is a string, as with all environment variables. |
| `list-values-from-environment-variables.6` | L917 | The separator between the base name and the index is `_`. |

## [Include syntax](../../spec/HOCON.md#include-syntax)

| rule | line | sentence |
|---|---|---|
| `include-syntax.1` | L923 | An _include statement_ consists of the unquoted string `include` followed by whitespace and then either: |
| `include-syntax.2` | L925 | a single _quoted_ string which is interpreted heuristically as URL, filename, or classpath resource. |
| `include-syntax.3` | L927 | `url()`, `file()`, or `classpath()` surrounding a quoted string which is then interpreted as a URL, file, or classpath. |
| `include-syntax.4` | L928 | The string must be quoted, unlike in CSS. |
| `include-syntax.5` | L930 | `required()` surrounding one of the above |
| `include-syntax.6` | L932 | An include statement can appear in place of an object field. |
| `include-syntax.7` | L934 | If the unquoted string `include` appears at the start of a path expression where an object key would be expected, then it is not interpreted as a path expression or a key. |
| `include-syntax.8` | L938 | Instead, the next value must be a _quoted_ string or a quoted string surrounded by `url()`, `file()`, or `classpath()`. |
| `include-syntax.9` | L942 | Together, the unquoted `include` and the resource name substitute for an object field syntactically, and are separated from the following object fields or includes by the usual comma (and as usual the comma may be omitted if there's a newline). |
| `include-syntax.10` | L947 | If an unquoted `include` at the start of a key is followed by anything other than a single quoted string or the `url("")`/`file("")`/`classpath("")` syntax, it is invalid and an error should be generated. |
| `include-syntax.11` | L952 | There can be any amount of whitespace, including newlines, between the unquoted `include` and the resource name. |
| `include-syntax.12` | L953 | For `url()` etc., whitespace is allowed inside the parentheses `()` (outside of the quotes). |
| `include-syntax.13` | L957 | Value concatenation is NOT performed on the "argument" to `include` or `url()` etc. |
| `include-syntax.14` | L958 | The argument must be a single quoted string. |
| `include-syntax.15` | L959 | No substitutions are allowed, and the argument may not be an unquoted string or any other kind of value. |
| `include-syntax.16` | L962 | Unquoted `include` has no special meaning if it is not the start of a key's path expression. |
| `include-syntax.17` | L977 | You can quote `"include"` if you want a key that starts with the word `"include"`, only unquoted `include` is special: |

## [Include semantics: merging](../../spec/HOCON.md#include-semantics-merging)

| rule | line | sentence |
|---|---|---|
| `include-semantics-merging.1` | L989 | An included file must contain an object, not an array. |
| `include-semantics-merging.2` | L993 | If an included file contains an array as the root value, it is invalid and an error should be generated. |
| `include-semantics-merging.3` | L996 | The included file should be parsed, producing a root object. |
| `include-semantics-merging.4` | L996 | The keys from the root object are conceptually substituted for the include statement in the including file. |
| `include-semantics-merging.5` | L1000 | If a key in the included object occurred prior to the include statement in the including object, the included key's value overrides or merges with the earlier value, exactly as with duplicate keys found in a single file. |
| `include-semantics-merging.6` | L1004 | If the including file repeats a key from an earlier-included object, the including file's value would override or merge with the one from the included file. |

## [Include semantics: substitution](../../spec/HOCON.md#include-semantics-substitution)

| rule | line | sentence |
|---|---|---|
| `include-semantics-substitution.1` | L1010 | Substitutions in included files are looked up at two different paths; first, relative to the root of the included file; second, relative to the root of the including configuration. |
| `include-semantics-substitution.2` | L1015 | It should be done for the entire app's configuration, not for single files in isolation. |
| `include-semantics-substitution.3` | L1018 | Therefore, if an included file contains substitutions, they must be "fixed up" to be relative to the app's configuration root. |
| `include-semantics-substitution.4` | L1029 | If you include "foo.conf" in an object at key `a`, however, then it must be fixed up to be `${a.x}` rather than `${x}`. |
| `include-semantics-substitution.5` | L1041 | Then the `${x}` in "foo.conf", which has been fixed up to `${a.x}`, would evaluate to `42` rather than to `10`. |
| `include-semantics-substitution.6` | L1048 | So it's not enough to only look up the "fixed up" path, it's necessary to look up the original path as well. |

## [Include semantics: missing files and required files](../../spec/HOCON.md#include-semantics-missing-files-and-required-files)

| rule | line | sentence |
|---|---|---|
| `include-semantics-missing-files-and-required-files.1` | L1053 | By default, if an included file does not exist then the include statement should be silently ignored (as if the included file contained only an empty object). |
| `include-semantics-missing-files-and-required-files.2` | L1057 | If however an included resource is mandatory then the name of the included resource may be wrapped with `required()`, in which case file parsing will fail with an error if the resource cannot be resolved. |

## [Include semantics: file formats and extensions](../../spec/HOCON.md#include-semantics-file-formats-and-extensions)

| rule | line | sentence |
|---|---|---|
| `include-semantics-file-formats-and-extensions.1` | L1080 | If an implementation supports multiple formats, then the extension may be omitted from the name of included files: |
| `include-semantics-file-formats-and-extensions.2` | L1085 | If a filename has no extension, the implementation should treat it as a basename and try loading the file with all known extensions. |
| `include-semantics-file-formats-and-extensions.3` | L1088 | If the file exists with multiple extensions, they should _all_ be loaded and merged together. |
| `include-semantics-file-formats-and-extensions.4` | L1091 | Files in HOCON format should be parsed last. |
| `include-semantics-file-formats-and-extensions.5` | L1091 | Files in JSON format should be parsed next-to-last. |
| `include-semantics-file-formats-and-extensions.6` | L1100 | This same extension-based behavior is applied to classpath resources and files. |

## [Include semantics: locating resources](../../spec/HOCON.md#include-semantics-locating-resources)

| rule | line | sentence |
|---|---|---|
| `include-semantics-locating-resources.1` | L1111 | A quoted string not surrounded by `url()`, `file()`, `classpath()` must be interpreted heuristically. |
| `include-semantics-locating-resources.2` | L1115 | a URL, if the quoted string is a valid URL with a known protocol. |
| `include-semantics-locating-resources.3` | L1117 | otherwise, a file or other resource "adjacent to" the one being parsed and of the same type as the one being parsed. |
| `include-semantics-locating-resources.4` | L1152 | if the included file is an absolute path then it should be kept absolute and loaded as such. |
| `include-semantics-locating-resources.5` | L1154 | if the included file is a relative path, then it should be located relative to the directory containing the including file. |
| `include-semantics-locating-resources.6` | L1156 | The current working directory of the process parsing a file must NOT be used when interpreting included paths. |
| `include-semantics-locating-resources.7` | L1179 | Note that at present, if `url()`/`file()`/`classpath()` are specified, the included items are NOT interpreted relative to the including items. |
| `include-semantics-locating-resources.8` | L1181 | Relative-to-including-file paths only work with the heuristic `include "foo.conf"`. |

## [Conversion of numerically-indexed objects to arrays](../../spec/HOCON.md#conversion-of-numerically-indexed-objects-to-arrays)

| rule | line | sentence |
|---|---|---|
| `conversion-of-numerically-indexed-objects-to-arrays.1` | L1187 | To provide some mechanism for this, implementations should support converting objects with numeric keys into arrays. |
| `conversion-of-numerically-indexed-objects-to-arrays.2` | L1204 | the conversion should be done lazily when required to avoid a type error, NOT eagerly anytime an object has numeric keys. |
| `conversion-of-numerically-indexed-objects-to-arrays.3` | L1210 | the conversion should be done in a concatenation when a list is expected and an object with numeric keys is found. |
| `conversion-of-numerically-indexed-objects-to-arrays.4` | L1212 | the conversion should not occur if the object is empty or has no keys which parse as positive integers. |
| `conversion-of-numerically-indexed-objects-to-arrays.5` | L1214 | the conversion should ignore any keys which do not parse as positive integers. |
| `conversion-of-numerically-indexed-objects-to-arrays.6` | L1216 | the conversion should sort by the integer value of each key and then build the array; if the integer keys are "0" and "2" then the resulting array would have indices "0" and "1", i.e. missing indices in the object are eliminated. |

## [Units format](../../spec/HOCON.md#units-format)

| rule | line | sentence |
|---|---|---|
| `units-format.1` | L1279 | if the value is a number, it is taken to be a number in the default unit. |
| `units-format.2` | L1281 | if the value is a string, it is taken to be this sequence: optional whitespace, a number, optional whitespace, an optional unit name consisting only of letters (letters are the Unicode `L*` categories, Java `isLetter()`), optional whitespace |
| `units-format.6` | L1286 | an optional unit name consisting only of letters (letters are the Unicode `L*` categories, Java `isLetter()`) |
| `units-format.8` | L1290 | If a string value has no unit name, then it should be interpreted with the default unit, as if it were a number. |
| `units-format.9` | L1290 | If a string value has a unit name, that name of course specifies the value's interpretation. |

## [Duration format](../../spec/HOCON.md#duration-format)

| rule | line | sentence |
|---|---|---|
| `duration-format.1` | L1300 | This can use the general "units format" described above; bare numbers are taken to be in milliseconds already, while strings are parsed as a number plus an optional unit string. |
| `duration-format.2` | L1304 | The supported unit strings for duration are case-sensitive and must be lowercase. |
| `duration-format.4` | L1307 | `ns`, `nano`, `nanos`, `nanosecond`, `nanoseconds` |
| `duration-format.5` | L1308 | `us`, `micro`, `micros`, `microsecond`, `microseconds` |
| `duration-format.6` | L1309 | `ms`, `milli`, `millis`, `millisecond`, `milliseconds` |
| `duration-format.7` | L1310 | `s`, `second`, `seconds` |
| `duration-format.8` | L1311 | `m`, `minute`, `minutes` |
| `duration-format.9` | L1312 | `h`, `hour`, `hours` |
| `duration-format.10` | L1313 | `d`, `day`, `days` |

## [Period Format](../../spec/HOCON.md#period-format)

| rule | line | sentence |
|---|---|---|
| `period-format.1` | L1320 | This can use the general "units format" described above; bare numbers are taken to be in days, while strings are parsed as a number plus an optional unit string. |
| `period-format.2` | L1324 | The supported unit strings for period are case-sensitive and must be lowercase. |
| `period-format.4` | L1327 | `d`, `day`, `days` |
| `period-format.5` | L1328 | `w`, `week`, `weeks` |
| `period-format.6` | L1329 | `m`, `mo`, `month`, `months` (note that if you are using `getTemporal()` which may return either a `java.time.Duration` or a `java.time.Period` you will want to use `mo` rather than `m` to prevent your unit being parsed as minutes) |
| `period-format.7` | L1333 | `y`, `year`, `years` |

## [Size in bytes format](../../spec/HOCON.md#size-in-bytes-format)

| rule | line | sentence |
|---|---|---|
| `size-in-bytes-format.1` | L1340 | This can use the general "units format" described above; bare numbers are taken to be in bytes already, while strings are parsed as a number plus an optional unit string. |
| `size-in-bytes-format.2` | L1344 | The one-letter unit strings may be uppercase (note: duration units are always lowercase, so this convention is specific to size units). |
| `size-in-bytes-format.4` | L1361 | `B`, `b`, `byte`, `bytes` |
| `size-in-bytes-format.6` | L1365 | `kB`, `kilobyte`, `kilobytes` |
| `size-in-bytes-format.7` | L1366 | `MB`, `megabyte`, `megabytes` |
| `size-in-bytes-format.8` | L1367 | `GB`, `gigabyte`, `gigabytes` |
| `size-in-bytes-format.9` | L1368 | `TB`, `terabyte`, `terabytes` |
| `size-in-bytes-format.10` | L1369 | `PB`, `petabyte`, `petabytes` |
| `size-in-bytes-format.11` | L1370 | `EB`, `exabyte`, `exabytes` |
| `size-in-bytes-format.12` | L1371 | `ZB`, `zettabyte`, `zettabytes` |
| `size-in-bytes-format.13` | L1372 | `YB`, `yottabyte`, `yottabytes` |
| `size-in-bytes-format.15` | L1376 | `K`, `k`, `Ki`, `KiB`, `kibibyte`, `kibibytes` |
| `size-in-bytes-format.16` | L1377 | `M`, `m`, `Mi`, `MiB`, `mebibyte`, `mebibytes` |
| `size-in-bytes-format.17` | L1378 | `G`, `g`, `Gi`, `GiB`, `gibibyte`, `gibibytes` |
| `size-in-bytes-format.18` | L1379 | `T`, `t`, `Ti`, `TiB`, `tebibyte`, `tebibytes` |
| `size-in-bytes-format.19` | L1380 | `P`, `p`, `Pi`, `PiB`, `pebibyte`, `pebibytes` |
| `size-in-bytes-format.20` | L1381 | `E`, `e`, `Ei`, `EiB`, `exbibyte`, `exbibytes` |
| `size-in-bytes-format.21` | L1382 | `Z`, `z`, `Zi`, `ZiB`, `zebibyte`, `zebibytes` |
| `size-in-bytes-format.22` | L1383 | `Y`, `y`, `Yi`, `YiB`, `yobibyte`, `yobibytes` |
| `size-in-bytes-format.23` | L1385 | It's very unclear which units the single-character abbreviations ("128K") should go with; some precedents such as `java -Xmx 2G` and the GNU tools such as `ls` map these to powers of two, so this spec copies that. |

## [Config object merging and file merging](../../spec/HOCON.md#config-object-merging-and-file-merging)

| rule | line | sentence |
|---|---|---|
| `config-object-merging-and-file-merging.2` | L1406 | As with duplicate keys, an intermediate non-object value "hides" earlier object values. |
| `config-object-merging-and-file-merging.3` | L1414 | The result would be `{ a : { x : 1 } }`. |
| `config-object-merging-and-file-merging.4` | L1414 | The two objects are not merged because they are not "adjacent"; the merging is done in pairs, and when `42` is paired with `{ y : 2 }`, `42` simply wins and loses all information about what it overrode. |
| `config-object-merging-and-file-merging.5` | L1425 | Now the result would be `{ a : { x : 1, y : 2 } }` because the two objects are adjacent. |
| `config-object-merging-and-file-merging.6` | L1428 | This rule for merging objects loaded from different files is _exactly_ the same behavior as for merging duplicate fields in the same file. |
| `config-object-merging-and-file-merging.7` | L1436 | The one place where it matters, though, is that it allows you to "clear" an object and start over by setting it to null and then setting it back to a new object. |

## [Java properties mapping](../../spec/HOCON.md#java-properties-mapping)

| rule | line | sentence |
|---|---|---|
| `java-properties-mapping.1` | L1447 | Java properties parse as a one-level map from string keys to string values. |
| `java-properties-mapping.2` | L1471 | Values from properties files are _always_ strings, even if they could be parsed as some other type. |
| `java-properties-mapping.3` | L1486 | The _object_ must always win in this case... the "object wins" rule throws out at most one value (the string) while "string wins" would throw out all values in the object. |

## [Substitution fallback to environment variables](../../spec/HOCON.md#substitution-fallback-to-environment-variables)

| rule | line | sentence |
|---|---|---|
| `substitution-fallback-to-environment-variables.1` | L1536 | Recall that if a substitution is not present (not even set to `null`) within a configuration tree, implementations may search for it from external sources. |
| `substitution-fallback-to-environment-variables.2` | L1538 | One such source could be environment variables. |
| `substitution-fallback-to-environment-variables.3` | L1544 | (While on Windows getenv() is generally not case-sensitive, the lookup will be case-sensitive all the way until the env variable fallback lookup is reached). |
| `substitution-fallback-to-environment-variables.4` | L1550 | An application can explicitly block looking up a substitution in the environment by setting a value in the configuration, with the same name as the environment variable. |
| `substitution-fallback-to-environment-variables.5` | L1558 | env variables set to the empty string are kept as such (set to empty string, rather than undefined) |
| `substitution-fallback-to-environment-variables.6` | L1563 | environment variables always become a string value, though if an app asks for another type automatic type conversion would kick in |

## Out of scope

Sections with no rule above describe something a file-in, JSON-out suite cannot
observe: [API Recommendations](../../spec/HOCON.md#api-recommendations), [Automatic type conversions](../../spec/HOCON.md#automatic-type-conversions), [Conventional configuration files for JVM apps](../../spec/HOCON.md#conventional-configuration-files-for-jvm-apps), [Conventional override by system properties](../../spec/HOCON.md#conventional-override-by-system-properties), [Definitions](../../spec/HOCON.md#definitions), [Goals / Background](../../spec/HOCON.md#goals--background), [hyphen-separated vs. camelCase](../../spec/HOCON.md#hyphen-separated-vs-camelcase), [Java properties mapping](../../spec/HOCON.md#java-properties-mapping), [MIME Type](../../spec/HOCON.md#mime-type), [Note on Java properties similarity](../../spec/HOCON.md#note-on-java-properties-similarity), [Note on Windows and case sensitivity of environment variables](../../spec/HOCON.md#note-on-windows-and-case-sensitivity-of-environment-variables), [Syntax](../../spec/HOCON.md#syntax).
Rules from them appear above only where a case pins one (`.properties` includes).
