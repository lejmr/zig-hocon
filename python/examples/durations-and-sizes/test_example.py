"""Each leaf read into each of the three models gives the same durations and
sizes: the rules are zig_hocon.parse_duration's and parse_bytes', the same
as hocon.Duration and hocon.Size in Zig.

java ✓ (getDuration, getBytes) · pyhocon ⚠️ makes `30s` a timedelta on its own
and leaves `512MiB` text · spec ✓
"""

import datetime
import pathlib

import models_dataclasses
import models_msgspec
import models_pydantic
import msgspec
import pydantic
import pytest
import zig_hocon

CONF = pathlib.Path(__file__).parent / "conf"


def load(variant, conf):
    if variant == "pydantic":
        return models_pydantic.Settings.model_validate(conf.as_dict())
    if variant == "msgspec":
        return msgspec.json.decode(conf.to_json(), type=models_msgspec.Settings, dec_hook=models_msgspec.dec_hook)
    return msgspec.json.decode(conf.to_json(), type=models_dataclasses.Settings, dec_hook=models_msgspec.dec_hook)


def plain(settings):
    """The settings as dicts, timedeltas and ints, whichever model holds them."""
    if isinstance(settings, pydantic.BaseModel):
        return settings.model_dump()
    return msgspec.to_builtins(settings, builtin_types=(datetime.timedelta,), enc_hook=enc_hook)


def enc_hook(value):
    """Duration and Size are types msgspec does not know, as for decoding."""
    if isinstance(value, models_msgspec.Duration):
        return datetime.timedelta(value.days, value.seconds, value.microseconds)
    return int(value)


def seconds(n):
    return datetime.timedelta(seconds=n)


LEAVES = {
    "laptop": {
        "http": {"timeout": seconds(5), "retry_backoff": seconds(0.25), "keepalive": seconds(120), "max_body": 10_000_000},
        "cache": {"ttl": seconds(3600), "max_size": 64 * 1024**2},
    },
    "server": {
        "http": {"timeout": seconds(120), "retry_backoff": seconds(0.25), "keepalive": seconds(120), "max_body": 10_000_000},
        "cache": {"ttl": seconds(86400), "max_size": 4 * 1024**3},
    },
}


@pytest.mark.parametrize("variant", ["pydantic", "msgspec", "dataclasses"])
@pytest.mark.parametrize("leaf", LEAVES)
def test_leaf(leaf, variant):
    conf = zig_hocon.ConfigFactory.parse_file(CONF / leaf / "app.conf")
    assert plain(load(variant, conf)) == LEAVES[leaf]


# A duration or size no rule reads, or a value of another JSON type, is a
# validation error at its field, whichever model reads it.
@pytest.mark.parametrize("variant", ["pydantic", "msgspec", "dataclasses"])
@pytest.mark.parametrize("line, field", [("http.timeout = 3 parsecs", "timeout"), ("http.timeout = true", "timeout"), ("cache.max_size = [1, 2]", "max_size")])
def test_not_a_duration_or_size(variant, line, field):
    conf = zig_hocon.ConfigFactory.parse_file(CONF / "server" / "app.conf")
    broken = zig_hocon.ConfigFactory.parse_string(conf.to_hocon() + "\n" + line + "\n")
    with pytest.raises((pydantic.ValidationError, msgspec.ValidationError), match=field):
        load(variant, broken)


# A pydantic model reads its own fields back: a timedelta is a duration already.
def test_pydantic_reads_what_it_holds():
    settings = load("pydantic", zig_hocon.ConfigFactory.parse_file(CONF / "server" / "app.conf"))
    assert models_pydantic.Settings.model_validate(settings.model_dump()) == settings
