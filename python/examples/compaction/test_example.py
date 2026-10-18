"""A compacted leaf, deployed alone and read where it runs, gives each model
the same settings as the leaf itself, in every environment.

Zig only (pyhocon and java have no env=KEEP) · java ✓ reads the leaf and the
compacted file to the same JSON · spec ✓
"""

import pathlib
import subprocess
import sys

import models_dataclasses
import models_msgspec
import models_pydantic
import msgspec
import pydantic
import pytest
import zig_hocon
from compact import compact

HERE = pathlib.Path(__file__).parent
VARIANTS = ["pydantic", "msgspec", "dataclasses"]


def load(variant, path, env):
    conf = zig_hocon.ConfigFactory.parse_file(path, env=env)
    if variant == "pydantic":
        return models_pydantic.Settings.model_validate(conf.as_dict())
    # strict=False: PORT=9443 is the text "9443", the port an int.
    if variant == "msgspec":
        return msgspec.json.decode(conf.to_json(), type=models_msgspec.Settings, strict=False)
    return msgspec.json.decode(conf.to_json(), type=models_dataclasses.Settings, strict=False)


def plain(settings):
    if isinstance(settings, pydantic.BaseModel):
        return settings.model_dump()
    return msgspec.to_builtins(settings)


# Where the compacted leaf is deployed: the leaf, the machine's environment,
# and what every model reads there. One machine has every variable set, the
# other the least the leaf needs.
RUNS = [
    (
        "prod",
        {"DB_HOST": "db.prod.internal", "PORT": "9443"},
        {
            "service": {
                "name": "burrow-api",
                "port": 9443,
                "plugins": ["auth", "metrics"],
                "db": {"host": "db.prod.internal", "pool": 16},
                "url": "postgres://db.prod.internal/burrow?pool=16",
            }
        },
    ),
    (
        "prod",
        {"DB_HOST": "db.prod.internal"},
        {
            "service": {
                "name": "burrow-api",
                "port": 8080,
                "plugins": ["auth", "metrics"],
                "db": {"host": "db.prod.internal", "pool": 16},
                "url": "postgres://db.prod.internal/burrow?pool=16",
            }
        },
    ),
    (
        "staging",
        {"PORT": "9443"},
        {
            "service": {
                "name": "burrow-api-staging",
                "port": 9443,
                "plugins": ["auth", "debug-toolbar"],
                "db": {"host": "localhost", "pool": 4},
                "url": "postgres://localhost/burrow?pool=4",
            }
        },
    ),
    (
        "staging",
        {},
        {
            "service": {
                "name": "burrow-api-staging",
                "port": 8080,
                "plugins": ["auth", "debug-toolbar"],
                "db": {"host": "localhost", "pool": 4},
                "url": "postgres://localhost/burrow?pool=4",
            }
        },
    ),
]


@pytest.fixture(scope="module")
def deployed(tmp_path_factory):
    """Each leaf compacted into a directory of its own, as on a server: none
    of conf/ is next to it."""
    out = {}
    for leaf in ["prod", "staging"]:
        out[leaf] = tmp_path_factory.mktemp(f"server-{leaf}") / "app.conf"
        compact(HERE / "conf" / leaf / "app.conf", out[leaf])
    return out


@pytest.mark.parametrize("variant", VARIANTS)
@pytest.mark.parametrize("leaf, env, want", RUNS)
def test_deployed_reads_as_the_leaf(leaf, env, want, variant, deployed):
    assert plain(load(variant, HERE / "conf" / leaf / "app.conf", env)) == want
    assert plain(load(variant, deployed[leaf], env)) == want


def test_what_is_deployed(deployed):
    text = deployed["prod"].read_text()
    assert "include" not in text
    assert "port = ${?PORT}" in text
    assert "host = ${DB_HOST}" in text
    assert '"postgres://"${service.db.host}"/burrow?pool="16' in text
    # What it waits for is still required where it runs.
    with pytest.raises(zig_hocon.ConfigSubstitutionException, match="Unresolved"):
        zig_hocon.ConfigFactory.parse_file(deployed["prod"], env={})


# The script as it is run, on files on disk.
def test_compact_script(tmp_path):
    out = tmp_path / "prod.conf"
    subprocess.run([sys.executable, HERE / "compact.py", HERE / "conf" / "prod" / "app.conf", out], check=True)
    settings = load("pydantic", out, {"DB_HOST": "db.prod.internal"})
    assert settings.service.url == "postgres://db.prod.internal/burrow?pool=16"
    assert settings.service.plugins == ["auth", "metrics"]
    assert settings.service.port == 8080
