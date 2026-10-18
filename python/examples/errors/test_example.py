"""What a broken config looks like, whichever model reads it.

A mistake in the HOCON is a zig_hocon.ConfigException before any model sees
the settings: the file (an included one, where the mistake is), the line and
column, the line itself and a caret under the column, as the hocon CLI
prints it. A value of the wrong type is valid HOCON, and the model's error:
it names the path, and the JSON the model read has no lines.

java ✓ (same files and lines; no columns) · pyhocon ✓ (lines; other columns) ·
spec –
"""

import pathlib

import models_dataclasses
import models_msgspec
import models_pydantic
import msgspec
import pydantic
import pytest
import zig_hocon

CONF = pathlib.Path(__file__).parent / "conf"
VARIANTS = ["pydantic", "msgspec", "dataclasses"]


def load(variant, path):
    conf = zig_hocon.ConfigFactory.parse_file(path)
    if variant == "pydantic":
        return models_pydantic.Settings.model_validate(conf.as_dict())
    if variant == "msgspec":
        return msgspec.json.decode(conf.to_json(), type=models_msgspec.Settings)
    return msgspec.json.decode(conf.to_json(), type=models_dataclasses.Settings)


# The leaf, the exception, the file the mistake is in, line, column, and the
# message's last two lines.
BROKEN = {
    "syntax": (zig_hocon.ConfigParseException, "syntax/app.conf", 3, 13, "  port = 80 [443]", "            ^"),
    "unresolved": (
        zig_hocon.ConfigSubstitutionException,
        "unresolved/limits.conf",
        2,
        28,
        "burst = ${max_connections} ${burst_factor}",
        "                           ^",
    ),
}


@pytest.mark.parametrize("variant", VARIANTS)
@pytest.mark.parametrize("leaf", BROKEN)
def test_broken_hocon(leaf, variant, monkeypatch):
    cls, file, line, column, shown, caret = BROKEN[leaf]
    # Relative to where it runs, as a service names its config.
    monkeypatch.chdir(CONF)
    with pytest.raises(cls) as e:
        load(variant, f"{leaf}/app.conf")
    assert pathlib.Path(e.value.file) == pathlib.Path(file)
    assert (e.value.line, e.value.column) == (line, column)
    first, *rest = str(e.value).splitlines()
    assert first == f"{e.value.file}:{line}:{column}: {e.value.name}"
    assert rest == [shown, caret]


@pytest.mark.parametrize("variant", VARIANTS)
def test_wrong_type(variant):
    with pytest.raises((pydantic.ValidationError, msgspec.ValidationError), match="server.port"):
        load(variant, CONF / "wrong-type" / "app.conf")
