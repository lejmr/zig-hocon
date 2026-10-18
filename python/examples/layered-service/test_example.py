"""Each leaf read into each of the three models gives the same settings.

java ✓ (same JSON for both leaves) · pyhocon ⚠️ `+=` onto an included list
gives `" metrics"` · spec ✓
"""

import pathlib
import shutil

import models_dataclasses
import models_msgspec
import models_pydantic
import msgspec
import pydantic
import pytest
import zig_hocon

CONF = pathlib.Path(__file__).parent / "conf"


def load(variant, path, env):
    conf = zig_hocon.ConfigFactory.parse_file(path, env=env)
    if variant == "pydantic":
        return models_pydantic.Settings.model_validate(conf.as_dict())
    # A variable is text: PORT=9443 is "9443". strict=False lets msgspec read
    # it as the int the model wants, as pydantic does by default.
    if variant == "msgspec":
        return msgspec.json.decode(conf.to_json(), type=models_msgspec.Settings, strict=False)
    return msgspec.json.decode(conf.to_json(), type=models_dataclasses.Settings, strict=False)


def plain(settings):
    """The settings as dicts and lists, whichever model holds them."""
    if isinstance(settings, pydantic.BaseModel):
        return settings.model_dump()
    return msgspec.to_builtins(settings)


# The leaf, the environment it runs in, and what it gives. env= is a dict
# here so the test does not depend on the shell; the default is os.environ.
LEAVES = {
    "prod": (
        {"DB_HOST": "db.prod.internal", "PORT": "9443"},
        {
            "service": {
                "name": "burrow-api",
                "port": 9443,
                "log_level": "warn",
                "plugins": ["auth", "metrics"],
                "db": {"host": "db.prod.internal", "port": 5432, "pool": 16},
            }
        },
    ),
    "staging": (
        {},
        {
            "service": {
                "name": "burrow-api-staging",
                "port": 8080,
                "log_level": "info",
                "plugins": ["auth", "debug-toolbar"],
                "db": {"host": "staging-db.internal", "port": 5432, "pool": 4},
            }
        },
    ),
}


@pytest.mark.parametrize("variant", ["pydantic", "msgspec", "dataclasses"])
@pytest.mark.parametrize("leaf", LEAVES)
def test_leaf(leaf, variant):
    env, want = LEAVES[leaf]
    assert plain(load(variant, CONF / leaf / "app.conf", env)) == want


# prod has no default for DB_HOST: without it, it does not load, whichever model.
@pytest.mark.parametrize("variant", ["pydantic", "msgspec", "dataclasses"])
def test_prod_needs_db_host(variant):
    with pytest.raises(zig_hocon.ConfigSubstitutionException, match="Unresolved"):
        load(variant, CONF / "prod" / "app.conf", {})


# A log level the model does not know is the model's error, with the path.
@pytest.mark.parametrize("variant", ["pydantic", "msgspec", "dataclasses"])
def test_log_level_is_checked(variant, tmp_path):
    shutil.copy(CONF / "defaults.conf", tmp_path)
    (tmp_path / "app.conf").write_text('include "defaults.conf"\nservice.log_level = chatty\n')
    with pytest.raises((pydantic.ValidationError, msgspec.ValidationError), match="log_level"):
        load(variant, tmp_path / "app.conf", {})
