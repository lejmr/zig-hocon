# zig-hocon for Python

[HOCON](https://github.com/lightbend/config/blob/main/HOCON.md) configuration
files, read by [zig-hocon](https://github.com/lejmr/zig-hocon). The parser is the
Zig library (libhocon, shipped inside the package); this is a thin `ctypes`
layer with no dependencies and pyhocon's API, so moving over is a change of import.

```python
from zig_hocon import ConfigFactory, KEEP

conf = ConfigFactory.parse_file("deploy/prod/app.conf")      # ${VAR} from os.environ
conf = ConfigFactory.parse_file(path, env={"PORT": "8080"})  # from a dict
conf = ConfigFactory.parse_file(path, env=None)              # from nowhere
conf = ConfigFactory.parse_file(path, env=KEEP)              # left for later
conf = ConfigFactory.parse_file(path, resolve=False)         # every ${…} as written

conf.get_string("db.host")
conf.get_int("db.pool")
conf.get_duration("timeout")    # datetime.timedelta
conf.get_bytes("cache")         # int
conf.get_period("retention")    # {"years": 0, "months": 3, "days": 0}
conf.get_config("db")           # the object at db
conf.as_dict()
conf.to_json()                  # bytes, for msgspec.json.decode
conf.to_hocon()                 # with env=KEEP: everything resolved but the variables
```

Errors are `ConfigException`s with the place: `prod/app.conf:7:12: Unresolved`,
the line, and a caret under the column. A getter's too, where the value is
written: `defaults.conf:7:33: InvalidCharacter at app.db.pool: expected i64`.

The package is typed (`py.typed`, checked with `mypy --strict`): `get_int("a")`
is an `int`, `get_int("a", None)` an `int | None`. A document can be read from
many threads at once. The modules are pyhocon's: `zig_hocon.config_parser`,
`zig_hocon.config_tree`, `zig_hocon.exceptions`.

## Building from source

```sh
zig build python -Doptimize=ReleaseSafe   # libhocon into python/zig_hocon/
pip install python/                       # or: uv build --wheel python/
zig build test-python                     # pytest (100 % coverage) and mypy with uv; -Dpython=3.13 for another
```

The wheel is `py3-none-<platform>`: one per platform, for every Python 3.10+.
The library is built for the machine it is built on.
