# Migrating from pyhocon

This guide moves a project from pyhocon to zig_hocon. There are two ways:

- **The short way: `zig_hocon.pyhocon`, a change of import.** pyhocon's API as pyhocon 0.3.63 has it: the same modules, names, arguments and output, the tree an `OrderedDict` you can `put` into and `pop` from. Its section says what it covers and what it does not.
- **The native way: `zig_hocon`, the package's own API.** Typed getters on a document that stays in the library until one asks, and no tree in Python at all, in three steps.

`zig_hocon` reads a config by the spec, which in a few places is not how pyhocon reads it: Step 3. `zig_hocon.pyhocon` reads pyhocon's own syntax as pyhocon does, and the rest by the spec. The checklist at the end finds every place to look at.

## Why move

- **Correct.** zig_hocon passes all 586 tests in the [conformance suite](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html), pyhocon 359.
- **Fast.** A 10 MB config loads in 0.3 s. pyhocon takes 68 s, and 867 s when the file has substitutions.
- **No crash on a layered config.** A list from an included file, extended with `+=`, stops pyhocon 0.3.63 with an `AttributeError`:

  ```hocon
  # defaults.conf
  plugins = [auth]
  ```
  ```hocon
  # prod.conf
  include "defaults.conf"
  plugins += metrics
  ```

  zig_hocon gives `["auth", "metrics"]`.
- **No silent guesses.** pyhocon accepts input the spec rejects, and changes what you wrote. zig_hocon reports such input as an error with its place, and keeps what you wrote as you wrote it:

  | input | pyhocon 0.3.63 | zig_hocon |
  |---|---|---|
  | `a = [include "x"]` | `{"a": []}`, the element is gone | `{"a": ["include x"]}`: an include belongs in an object, in a list it is text |
  | `a..b = 1` | `{"a": {"b": 1}}` | error at 1:3 |
  | `a = b:c` | `{"a": "b:c"}` | error at 1:6 (`:` is reserved) |
  | `,a = b` | `{"a": "b"}` | error at 1:1 |
  | `a = b<TAB>c` | `"b   c"`, the tab became spaces | `"b\tc"` |

- **One exception to catch.** Every error is a `ConfigException`, with the file, line and column. A syntax error in pyhocon is pyparsing's `ParseSyntaxException`, which `except ConfigException` misses.

## The short way: zig_hocon.pyhocon

Replace `pyhocon` with `zig_hocon.pyhocon` in the imports and leave the rest:

```python
from zig_hocon.pyhocon import ConfigFactory, ConfigTree, HOCONConverter
from zig_hocon.pyhocon.exceptions import ConfigMissingException
```

Everything of pyhocon's public API is there: `ConfigFactory.parse_file` (with `encoding` and `required`), `parse_string`, `parse_URL`, `from_dict`; the `ConfigTree` with `get`, the typed getters, `get_list`, `get_config`, `put`, `pop`, `with_fallback`, `merge_configs`, `as_plain_ordered_dict`, `conf["db.host"]` and `conf.db.host`; `ConfigParser.parse`, `resolve_substitutions` and `resolve_package_path`; `HOCONConverter` with its JSON, HOCON, YAML and .properties output to the character; `period_parser` and `period_serializer`; and pyhocon's command line as `python -m zig_hocon.pyhocon.tool`. The exceptions are zig_hocon's, so one `except` catches either module's.

Two tests hold it against the newest pyhocon on every change: [test_pyhocon_signatures.py](tests/test_pyhocon_signatures.py) has every public name of pyhocon's modules, with the same parameters, and [test_pyhocon_compat.py](tests/test_pyhocon_compat.py) reads documents with both and compares the values, their types and the converter's output. Each difference by design is in them with its reason.

Values have the types the spec gives them: a number JSON reads is a number, everything else text, as the core reads it. A text stays exactly the text, quoted or not, from an environment variable too: `${ACCOUNT_ID}` with `012345678901` in it, `"0644"` and `"512m"` stay what they say. pyhocon turns an unquoted `30s` into a `timedelta` and an unquoted `0024` into 24; here they are the text `"30s"` and `"0024"`, and `zig_hocon.parse_duration` reads the first. (The core's JSON does not say which values were quoted, so guessing pyhocon's types from it changed quoted and inherited text too; it is not done.)

The text itself is read by the spec, as `zig_hocon` reads it. Of pyhocon's own syntax two includes are there, in the text you parse (not in a file it includes): `include package("pkg:file.conf")`, the file in the installed package, and a glob, `include "conf.d/*.conf"`, each file it finds, in sorted order. With pyparsing installed, as it is beside pyhocon, a syntax error is pyparsing's `ParseException` and `ParseSyntaxException` too.

What pyhocon reads its own way and this module reads by the spec:

| config | pyhocon | here |
|---|---|---|
| `timeout = 30s`, unquoted | a `timedelta` (`relativedelta` with dateutil) | the text `"30s"`; `zig_hocon.parse_duration` reads it |
| `zip = 0024`, unquoted | 24 | the text `"0024"` |
| `x += [3, 4]` after `x = [1, 2]` | `[1, 2, 3, 4]` | `[1, 2, [3, 4]]`; write `x = ${x} [3, 4]` |
| `x += def` onto text, `x += { b = 2 }` onto an object | goes on after the text, merges | an error |
| `include "f"` with a file named `f` | that file | `f.conf`, `f.json`, `f.properties`; name the extension |
| an include in a list | the included list's elements | an error |
| `abc\"d` unquoted | `abc"d` | an error |
| `x = [${x}, 2]`, an object that refers into itself | a value | an error, as typesafe/config has it |
| `a {} {b: 1}` | an error | the two objects merge |
| `${?nope} 4` | the number 4 | the text `" 4"` |

The one left is `ConfigTree.resolve()`, which is not there. Nor are a few things pyhocon has inside its parser:

- **A value with a `${…}` is no `ConfigValues`.** A document read with `resolve=False` has its values where it resolves on its own; where it does not, it has none until `with_fallback()` or `ConfigParser.resolve_substitutions()` gives it what it waits for, and reading it before is a `ConfigSubstitutionException`.
- **`unresolved_value`** takes `DEFAULT_SUBSTITUTION`, `MANDATORY_SUBSTITUTION` and `NO_SUBSTITUTION`; `STR_SUBSTITUTION` and a value of your own are a `NotImplementedError`.
- **`parse_URL`** reads a document with no `include` in it: one is an error, as it has no directory to be found in. pyhocon follows a `url(…)` include and leaves out the others with a warning.

Where the spec has the answer, it reads by the spec, also around pyhocon's syntax:

- **`+=` of a number, a boolean or `null`** appends it: `x += 2` after `x = [1]` is `[1, 2]`, and after `x = 5` an error. pyhocon puts the value in place of `x`.
- **An included file under an object** looks its `${…}` and `+=` up in that object first: `n { include "f.conf" }` with `z = ${y}` in it reads `n.y` before `y`. pyhocon reads `y` at the root.
- **`include "f"`** with no file named `f` reads `f.conf`, `f.json` or `f.properties`; pyhocon includes nothing. Values from a `.properties` file are text, where pyhocon reads numbers and booleans.
- **An object file included in a list** is one element; pyhocon gives its fields as `(key, value)` tuples.
- **An include of a URL that cannot be reached** is a `ConfigParseException`; pyhocon leaves it out with a warning.

The whole document is in Python, as in pyhocon, so it is a little slower than `zig_hocon`, still far from pyhocon: a 5 KB config in 0.3 ms (pyhocon 29 ms), 10 MB in 0.4 s (pyhocon 68 s), against 0.12 ms and 0.13 s for `zig_hocon`.

## The native way: zig_hocon

The package's own API: the document stays in libhocon, and a typed getter or `as_dict()` takes what it needs from it. It is the fastest way, and the one that reads every config by the spec. Steps 1 and 2 change the code, Step 3 lists the configs that read differently.

### Step 1: imports

| pyhocon | zig_hocon |
|---|---|
| `from pyhocon import ConfigFactory` | `from zig_hocon import ConfigFactory` |
| `from pyhocon.exceptions import ConfigMissingException` (and the others) | `from zig_hocon.exceptions import ConfigMissingException` |
| `ConfigFactory.parse_file(path, resolve=False)` | the same |
| `ConfigFactory.parse_string(text, basedir=…)` | the same |
| `conf.get_string / get_int / get_float / get_bool / get_config(path, default)` | the same |
| `conf.as_plain_ordered_dict()` | `conf.as_dict()` |
| `HOCONConverter.to_json(conf)` | `conf.to_json()` (bytes) |
| `HOCONConverter.to_hocon(conf)` | `conf.to_hocon()` |

The exception names are the same: `ConfigException`, `ConfigMissingException` (also a `KeyError`), `ConfigSubstitutionException`, `ConfigWrongTypeException` (also a `ValueError`), plus `ConfigParseException` for text that is not valid HOCON.

### Step 2: what needs code

**The tree is not a dict.** pyhocon's `ConfigTree` is an `OrderedDict`, so `conf["db"]["host"]`, `"db" in conf`, `for key in conf`, `dict(conf)` and `json.dumps(conf)` work on it. Here the values stay in the library until a getter asks; take a dict where you need one:

```python
settings = conf.as_dict()
settings["db"]["host"]
```

**Truth and equality are the object's.** `if conf:` is true for any tree, an empty one too, and `conf == other` asks whether they are the same object: pyhocon's dict was false when empty and equal by content. Ask `conf.as_dict()` for either. Neither raises, so look for them by hand.

**Getters read only what is that type**, as typesafe/config's do (`zig_hocon.pyhocon` keeps pyhocon's):

| on | pyhocon | zig_hocon |
|---|---|---|
| `null`, `get_string("a")` | `None` | `ConfigMissingException`; with a default, the default |
| `1.0` or `1e3`, `get_int` | 1, 1000 | `ConfigWrongTypeException` |
| `true`, `get_int` or `get_float` | 1, 1.0 | `ConfigWrongTypeException` |
| `" 5 "`, `get_int` | 5 | `ConfigWrongTypeException` |
| `True`, `Yes`, `get_bool` | `True` | `ConfigWrongTypeException`; `true`, `yes`, `on` are booleans |
| an object or a list, `get_string` | its `str()` | `ConfigWrongTypeException` |
| a duration past about 292 years, `get_duration` | the `timedelta` | `ConfigWrongTypeException` named `Overflow` |

**A thread needs 4 MiB of stack** for a document nested near the limit of 500: the parse recurses in the library, and on a smaller stack it ends the process, as `hocon.h` says for C. Python's default thread stack is enough; a server that shrinks it (`threading.stack_size`, musl's 128 KiB) should parse on a thread of its own size.

**Methods that are not there**, and what does the job:

| pyhocon | instead |
|---|---|
| `conf.get(path)`, `conf.get_list(path)` | a typed getter, or `functools.reduce(dict.__getitem__, path.split("."), conf.as_dict())` for a plain dotted path |
| `conf.with_fallback(defaults)` | `include "defaults.conf"` at the top of the file: the same merge, done by the parser |
| `conf.put(…)`, `conf.pop(…)` | change the dict from `as_dict()` |
| `ConfigFactory.from_dict(d)` | `ConfigFactory.parse_string(json.dumps(d))`: JSON is HOCON |
| `ConfigFactory.parse_URL(url)` | `include url("…")` in a file, or fetch it and `parse_string` |
| `parse_file(path, encoding=…)` | files are UTF-8 |
| `parse_file(path, required=False)` | catch the `ConfigException` named `FileNotFound` |
| `unresolved_value=…` | `resolve=False` keeps every `${…}`, `env=KEEP` only the variables |
| `include package("pkg:file.conf")` | not supported, see Step 3 |

`parse_file` takes everything after the path by keyword, so `parse_file(path, "utf-8")` fails loudly instead of meaning something else.

### Step 3: configs that read differently

- **`include package(...)` is not supported** (in `zig_hocon.pyhocon` it is). It is pyhocon's own extension, not HOCON, and zig_hocon reports it as an error (`UnexpectedToken` where `package` starts). Include the file by its path instead, relative to the file that includes it:

  ```hocon
  include "defaults.conf"
  ```

  For a file that ships inside an installed Python package, find it in Python and parse it from there:

  ```python
  from importlib.resources import files

  conf = ConfigFactory.parse_file(str(files("mypackage") / "defaults.conf"))
  ```

- **Durations and sizes are text until something asks** (in `zig_hocon.pyhocon` too). pyhocon turns `30s` into a `timedelta` while it parses; here `as_dict()` has `"30s"`, and `get_duration` or the model converts it. With pydantic, a `BeforeValidator(zig_hocon.parse_duration)` on the field; [examples/durations-and-sizes](examples/durations-and-sizes) has it for pydantic and msgspec.
- **A concatenation is a string.** `a = ${?nope}42` is `"42"` by the spec; pyhocon gives the number `42`. A model that wants an int converts it.
- **An `include url(…)` gives up after 30 s.** pyhocon waits as long as `socket.setdefaulttimeout` says, by default for ever. Here `http_timeout=` on `parse_file` and `parse_string` sets it, and a server that does not answer in time is a `ConfigParseException` named `IncludeTimeout`.
- **A leading zero keeps the text** (not in `zig_hocon.pyhocon`, which reads such a number as pyhocon does). A value that begins with a digit begins with the number JSON reads there, and the rest is text, so `zip = 01234` is `"01234"` by the spec; pyhocon gives the number 1234. An IP address, a version or a UUID is text as written, as in pyhocon. So is a value that begins with `-` and no number, `-foo` or `-Xmx2g`, and a fraction JSON has no number for: `.5` and `-.5` are the text `".5"` and `"-.5"`, where pyhocon gives 0.5 and -0.5. Text becomes a number only by the JSON rules, so `get_int("zip")` on `01234` and `get_float` on `-.5` raise `ConfigWrongTypeException`, where pyhocon gives 1234 and -0.5: write `zip = "01234"` and read it with `get_string`, or `-0.5`.
- **`+=` appends one element** (not in `zig_hocon.pyhocon`, which has pyhocon's `+=`). `x += [3, 4]` after `x = [1, 2]` is `[1, 2, [3, 4]]`, as `x = ${?x} [[3, 4]]` is; pyhocon gives `[1, 2, 3, 4]`. To extend a list with another, `x = ${x} [3, 4]`.
- **Strict syntax.** The other inputs in the table under *No silent guesses* are errors now. They are rare, and each error says where to look.

Everything else (variables, includes, merging) reads the same, except where pyhocon breaks the spec; the conformance report lists those cases.

## Checklist

With `zig_hocon.pyhocon`, only the differences in its section apply. With `zig_hocon`, run this over the code that uses pyhocon; each hit is a row in Step 2 or 3:

```sh
grep -rnE "pyhocon|include package|as_plain_ordered_dict|get_list|with_fallback|from_dict|parse_URL|HOCONConverter|\.put\(|\.pop\(|conf\[" .
```

Then load each of your configs with both and compare. With both packages installed:

```python
import sys

import pyhocon
import zig_hocon

for path in sys.argv[1:]:
    old = pyhocon.ConfigFactory.parse_file(path).as_plain_ordered_dict()
    new = zig_hocon.ConfigFactory.parse_file(path).as_dict()
    print("same" if old == new else "DIFFERENT", path)
```

A duration shows as a difference by design: pyhocon has a `timedelta`, zig_hocon the text `"30s"`. The [examples](examples) show how a model reads it, with pydantic, msgspec and dataclasses.
