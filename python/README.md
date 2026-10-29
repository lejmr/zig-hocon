<img src="https://raw.githubusercontent.com/lejmr/zig-hocon/main/docs/brand/zig-Hocon-badge-master-1650x500.png" width="600" alt="zig-hocon">

Read [HOCON](https://github.com/lightbend/config/blob/main/HOCON.md) config files in Python, to the spec. Fast, because the parser is written in Zig.

HOCON is JSON made for people: comments, no quotes needed, units like `30s` and `512MiB`, files that include other files, later settings that merge over earlier ones, and values taken from other keys or from environment variables. One base file, one small file per environment on top.

```hocon
# app.conf
db {
  host = localhost
  pool = 4
}
timeout = 30s
cache = 512MiB
retention = 3 months
debug = false
ratio = 0.75
```

```hocon
# prod.conf
include "app.conf"
db.host = db.example.org
db.pool = ${?DB_POOL}   # only when DB_POOL is set
```

```python
from zig_hocon import ConfigFactory

conf = ConfigFactory.parse_file("prod.conf")
conf.get_string("db.host")   # "db.example.org"
conf.get_int("db.pool")      # 4, or $DB_POOL when it is set
```

The rest of this page reads these two files. **Variables go last.** A later setting hides an earlier one, a `${?…}` too: `workers = ${?WORKERS}` in `app.conf` under `workers = 8` in `prod.conf` is 8 whatever `WORKERS` says. Put what the environment overrides where nothing comes after it, as `prod.conf` here does with `${?DB_POOL}`, or in a file every environment includes last.

## Why zig-hocon

- **Correct.** Passes all 588 tests in the [conformance suite](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html): each checks one sentence of the spec, and together they cover 276 of its 290 rules.
- **Fast.** Orders of magnitude faster than what Python usually has.\*
- **Clear errors.** File, line, column, and a caret under the mistake.
- **No dependencies.** A thin ctypes layer over one bundled library.

\* A 1 MB config with substitutions in 13 ms, a 10 MB one in 0.14 s, on an Apple M4 Pro: [BENCHMARK.md](https://github.com/lejmr/zig-hocon/blob/main/python/BENCHMARK.md).

## Install

```sh
pip install zig-hocon
```

It puts two commands on the path: [`hocon`](#the-hocon-command), the command line tool of zig-hocon built for your platform, and `zig-hocon-migrate`, the check of what changes from pyhocon ([Coming from pyhocon](#coming-from-pyhocon)).

One wheel per platform, for every Python from 3.10 on, free-threaded builds and PyPy included: macOS (arm64, x86_64), Linux (x86_64, aarch64; glibc 2.17+ and musl) and Windows (x86_64). The import name is `zig_hocon`. Anywhere else, build it from source (below).

Beta: the API can still change before 1.0. BSD-3-Clause.

## Use

```python
from zig_hocon import ConfigFactory, KEEP

conf = ConfigFactory.parse_file("prod.conf")                       # DB_POOL from os.environ
conf = ConfigFactory.parse_file("prod.conf", env={"DB_POOL": "8"}) # from a dict
conf = ConfigFactory.parse_file("prod.conf", env=None)             # no variables: pool stays 4
conf = ConfigFactory.parse_file("prod.conf", env=KEEP)             # ${?DB_POOL} kept, for to_hocon(); a getter there is Unresolved
conf = ConfigFactory.parse_file("prod.conf", resolve=False)        # every ${…} as written
conf = ConfigFactory.parse_file("prod.conf", http_timeout=5)       # an http(s) include waits 5 s, not 30
conf = ConfigFactory.parse_string('include "prod.conf"', basedir=".")  # text, includes from basedir

conf.get_string("db.host")      # "db.example.org"
conf.get_int("db.pool")         # 4
conf.get_float("ratio")         # 0.75
conf.get_bool("debug")          # False: true/yes/on, false/no/off
conf.get_duration("timeout")    # timedelta(seconds=30)
conf.get_bytes("cache")         # 536870912: "512MB" counts by 1000, "512MiB" by 1024
conf.get_period("retention")    # {"years": 0, "months": 3, "days": 0}: a timedelta has no months
conf.get_config("db")           # the object at db, read the same way
conf.get_int("db.size", default=10)  # 10: nothing at db.size

conf.as_dict()                  # plain dicts and lists
conf.to_json()                  # bytes, not str: for msgspec.json.decode
conf.to_hocon()                 # HOCON text
```

A path is written as in the file: `db.host`, `a."b.c"`. A getter's default is its second argument, as in pyhocon; `parse_file` and `parse_string` take everything after the path by keyword. The package is typed (`py.typed`): `get_int("a")` is an `int`, `get_int("a", None)` an `int | None`. One document can be read from many threads at once.

**Errors** are `ConfigException`s, with `name`, `file`, `line`, `column` and `source_line`:

| exception | when |
|---|---|
| `ConfigParseException` | the text is not valid HOCON, or an include fails |
| `ConfigSubstitutionException` | a `${…}` with no value, or a cycle |
| `ConfigMissingException` (also a `KeyError`) | nothing at the path, or `null` |
| `ConfigWrongTypeException` (also a `ValueError`) | the value is not what the getter wants |

**One file to deploy.** `env=KEEP` resolves includes, overrides and references between keys, and leaves the environment variables in; `to_hocon()` writes the result, to be read on the server with its own environment:

```python
from pathlib import Path

Path("deploy.conf").write_text(ConfigFactory.parse_file("prod.conf", env=KEEP).to_hocon())
```

**Durations, periods and sizes** have helpers with the same rules as the getters: `zig_hocon.parse_duration("30s")` gives a `timedelta`, `zig_hocon.parse_period("3 months")` a dict as `get_period` does, `zig_hocon.parse_bytes("512MiB")` an int; `zig_hocon.parse_int` and `zig_hocon.parse_bool` read a number and a boolean as `get_int` and `get_bool` do ([Strict, as the Zig side reads it](#into-a-model)). A duration is nanoseconds in an int64, as in C: a `timedelta` to the microsecond, rounded half to even (`1500ns` is 2 µs, where Zig keeps 1500 ns), of up to 292 years; a longer one is a `ConfigWrongTypeException` named `Overflow`.

**From the shell**, [`hocon`](#the-hocon-command) prints the file resolved, and more; `python -m zig_hocon [--json] [--env=process|none|keep] prod.conf` does the first through the package.

## The hocon command

`pip install zig-hocon` puts `hocon` on the path: the same tool as a release of zig-hocon has, built for your platform. It prints a file resolved, as HOCON or with `--json` as JSON:

```sh
$ hocon --json prod.conf
{"db":{"host":"db.example.org","pool":4},"timeout":"30s","cache":"512MiB","retention":"3 months","debug":false,"ratio":0.75}
```

A `${…}` the file does not answer reads the environment; `--env=none` reads none. `--env-file=prod.env` puts the `KEY=value` lines of a file over it, as docker compose and python-dotenv read them; a file written for a shell's `source`, with `export` and quotes, works as it is. A later file goes over an earlier one, and with `--env=none` they are all there is: `hocon check --env=none --env-file=prod.env prod.conf` checks a deployment against its own variables and nothing from your shell.

```sh
# prod.env
DB_HOST=db.internal
DB_POOL=16
# a line written for `source` reads the same
export LOG_LEVEL="warn"
```

`--env=keep` writes the one file to deploy: includes and overrides worked out, the variables left for the server:

```sh
$ hocon --env=keep prod.conf > deploy.conf
$ cat deploy.conf
db {
  host = db.example.org
  pool = 4
  pool = ${?DB_POOL}
}
timeout = 30s
cache = 512MiB
retention = 3 months
debug = false
ratio = 0.75
```

**get** prints one value, for a shell script:

```sh
$ hocon get db.host prod.conf
db.example.org
$ hocon get db --json prod.conf
{"host":"db.example.org","pool":4}
```

**diff** compares two files as they resolve, path by path (`~ path: old → new`, `+` and `-`), and exits 0 when they say the same, as the deploy file does, 1 when they differ and 2 when one cannot be read:

```sh
$ hocon diff prod.conf deploy.conf; echo $?
0
```

**check** reads each file and says which fail and where, for CI:

```sh
$ hocon check prod.conf staging.conf
prod.conf: ok
staging.conf:2:11: error: Unresolved
db.host = ${DB_HOST}
          ^
1 of 2 failed
```

Each exits 1 when something is wrong (`diff` 2, as 1 is a difference), with the place on stderr; `hocon` alone lists the commands and their flags. (The `hocon` of a release also has `check --schema`, which reads a file into a Zig struct; it needs zig, and the wheel's leaves it out.)

## Coming from pyhocon

Moving over is a rewrite of the code that works with the tree, not a change of import. What carries over: `ConfigFactory.parse_file` and `parse_string`, the typed getters (`get_string`, `get_int`, `get_float`, `get_bool`, `get_config`) and the exception names. What does not:

- **The tree is not a dict**, and `get`, `get_list`, `with_fallback` and `put` are not there: a typed getter, `conf.as_dict()` or an include does the job.
- **A list has no getters.** Read it through your model (`list[str]`), which checks the type as `get_list` did; `conf.as_dict()` gives whatever is there, a string from the environment too.
- **Durations stay text.** `30s` is `"30s"` in `as_dict()` until a getter or a model reads it.
- **`+=` appends one element.** `x += [a]`, the form pyhocon takes, adds the list `[a]` as one element; `x = ${x} [a]` extends it.
- **Values from the environment are text**, read as numbers and booleans only as written: `08` or `True` stop `get_int` and `get_bool`. Check your secret store first.
- **Strict syntax**, and no `include package(...)`.

`zig-hocon-migrate`, which pip installs with zig-hocon, reads your configs with pyhocon and with zig-hocon and shows what differs:

```sh
zig-hocon-migrate conf/prod.conf --env-file env/prod.env
```

[MIGRATING.md](https://github.com/lejmr/zig-hocon/blob/main/python/MIGRATING.md) has every difference, what to write instead, and how to run the check for each deployment in CI.

## Into a model

The package hands over a dict (`as_dict()`) or JSON bytes (`to_json()`); a model library does the checking. The same `prod.conf` into the three usual ones.

**pydantic** reads the dict. A duration is text in the file, `"30s"`, so a `BeforeValidator` turns it into a `timedelta` first:

```python
from datetime import timedelta
from typing import Annotated

import zig_hocon
from pydantic import BaseModel, BeforeValidator

Duration = Annotated[timedelta, BeforeValidator(zig_hocon.parse_duration)]

class Db(BaseModel):
    host: str
    pool: int

class Settings(BaseModel):
    db: Db
    timeout: Duration
    debug: bool

conf = zig_hocon.ConfigFactory.parse_file("prod.conf")
settings = Settings.model_validate(conf.as_dict())
```

**msgspec** decodes the JSON bytes straight into a Struct. It reads a `timedelta` itself only from ISO 8601 (`"PT30S"`), so the field gets a type of its own that msgspec hands to `dec_hook`. An environment variable is always a string, so `strict=False` lets `DB_POOL=16` into the `int`:

```python
from datetime import timedelta

import msgspec
import zig_hocon

class Duration(timedelta):
    pass

def dec_hook(type, value):
    if type is Duration:
        d = zig_hocon.parse_duration(value)
        return Duration(d.days, d.seconds, d.microseconds)
    raise NotImplementedError(type)

class Db(msgspec.Struct):
    host: str
    pool: int

class Settings(msgspec.Struct):
    db: Db
    timeout: Duration
    debug: bool

conf = zig_hocon.ConfigFactory.parse_file("prod.conf")
settings = msgspec.json.decode(conf.to_json(), type=Settings, dec_hook=dec_hook, strict=False)
```

**`@dataclass`** converts no types and does not build `Db` from a dict, so msgspec builds it, with the `Duration`, `dec_hook` and `conf` from above:

```python
from dataclasses import dataclass

@dataclass
class Db:
    host: str
    pool: int

@dataclass
class Settings:
    db: Db
    timeout: Duration
    debug: bool

settings = msgspec.json.decode(conf.to_json(), type=Settings, dec_hook=dec_hook, strict=False)
```

All three give `settings.db.host == "db.example.org"` and `settings.timeout == timedelta(seconds=30)`, and fail with the model's own error, path included, on a value of the wrong type. A size works the same way through `zig_hocon.parse_bytes`. The [examples](https://github.com/lejmr/zig-hocon/tree/main/python/examples) have these as tests, with layered environments, errors and one-file deploys.

**Strict, as the Zig side reads it.** A model's own rules for a number or a boolean are not the library's, and a value from the environment is always text, `${DB_POOL}` with `08` in it is `"08"`:

| text | `get_int` / `get_bool`, a Zig struct | pydantic | msgspec, `strict=False` |
|---|---|---|---|
| `"08"`, `"+9000"`, `"9_000"`, `" 48"` | refused | 8, 9000, 9000, 48 | refused |
| `"True"`, `"1"` | refused | `True` | `True` |
| `"yes"`, `"on"` | `True` | `True` | refused |

So the same file, with the same environment, can start the Python side with `workers = 8` where the Zig side of the application refuses to start, or the other way round. `zig_hocon.parse_int` and `zig_hocon.parse_bool` read as `get_int`, `get_bool` and a Zig struct do; as validators they make a model take exactly what the Zig side takes:

```python
from typing import Annotated

import zig_hocon
from pydantic import BaseModel, BeforeValidator, Field

Int = Annotated[int, BeforeValidator(zig_hocon.parse_int)]
Bool = Annotated[bool, BeforeValidator(zig_hocon.parse_bool)]

class Db(BaseModel):
    host: str
    pool: Annotated[Int, Field(ge=0, le=65535)]  # a u16 on the Zig side

class Settings(BaseModel):
    db: Db
    debug: Bool
```

The range stays the model's (`Field`). With msgspec, the same calls go in `dec_hook`, for types of their own as `Duration` above. Text is the other way round: unquoted `password = 12345` is the text `"12345"` to a Zig `[]const u8` field and to `get_string`, but a number to `as_dict()`, where `1.50` is also `1.5`, so a model's `str` field cannot see what was written. Quote a value meant as text that looks like a number, `password = "12345"`, and both sides read the same text.

## Building from source

```sh
zig build python -Doptimize=ReleaseSafe   # libhocon into python/zig_hocon/
pip install python/
zig build test-python                     # the package's tests, with uv
zig build wheels                          # a wheel for every platform, into zig-out/wheels/
```

Needs Zig 0.16. Source, issues and the Zig and C libraries: [github.com/lejmr/zig-hocon](https://github.com/lejmr/zig-hocon). BSD-3-Clause.
