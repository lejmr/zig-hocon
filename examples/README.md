# Examples

Each example is a set of `.conf` files and the same settings modelled three
ways: a pydantic model, a msgspec Struct and a standard library `@dataclass`.
Its test reads every config into every model and checks they agree.

## Run one

From a clone of the repository:

```sh
pip install zig-hocon pydantic msgspec pytest
cd examples/layered-service
pytest
```

Run them one at a time: their model modules share names.

## What each one shows

| example | shows |
|---|---|
| [layered-service](layered-service) | shared defaults and a config per environment: include, override, `+=`, and `${?PORT}`, `${DB_HOST}` from the environment |
| [durations-and-sizes](durations-and-sizes) | `30s` and `512MiB` read as `timedelta` and `int` |
| [errors](errors) | a broken file raises a `ConfigException` with file, line, column and a caret; a value of the wrong type is the model's error, with its path |
| [compaction](compaction) | `env=zig_hocon.KEEP` and `to_hocon()`: one file to deploy, read on the server with its own environment |

## The three models

zig_hocon gives a dict (`as_dict()`) or JSON bytes (`to_json()`). The model
library does the rest:

```python
conf = zig_hocon.ConfigFactory.parse_file("conf/prod/app.conf")

settings = models_pydantic.Settings.model_validate(conf.as_dict())
settings = msgspec.json.decode(conf.to_json(), type=models_msgspec.Settings)
settings = msgspec.json.decode(conf.to_json(), type=models_dataclasses.Settings)
```

| | checks types | builds nested objects | needs |
|---|---|---|---|
| pydantic | ✓ | ✓ | pydantic |
| msgspec Struct | ✓ | ✓ | msgspec |
| `@dataclass`, decoded by msgspec | ✓ | ✓ | msgspec |

Two things every example deals with:

- **A variable is text.** `PORT=9443` arrives as `"9443"`. pydantic turns it
  into an int by default; msgspec needs `strict=False`.
- **JSON has no durations or sizes.** `timeout = 30s` arrives as `"30s"`.
  pydantic converts it in a `BeforeValidator` with `zig_hocon.parse_duration`.
  msgspec reads a `timedelta` only from ISO 8601 (`"PT30S"`), so its models
  give the field a type of their own and convert it in a `dec_hook`.

Coming from pyhocon, where `30s` is already a `timedelta`: the
[migration guide](../python/MIGRATING.md) lists every difference.
