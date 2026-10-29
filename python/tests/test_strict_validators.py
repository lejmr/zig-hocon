"""parse_int and parse_bool read as get_int, get_bool and the Zig side do:
what a lax model takes from the environment and they refuse."""

from typing import Annotated

import pytest

import zig_hocon
from zig_hocon import ConfigWrongTypeException


@pytest.mark.parametrize("text, want", [("48", 48), ("-3", -3), (48, 48)])
def test_parse_int_reads_as_get_int(text, want):
    assert zig_hocon.parse_int(text) == want


@pytest.mark.parametrize("text", ["08", "+9000", "9_000", " 48", "1.5", 1.5, True, "9223372036854775808"])
def test_parse_int_refuses_what_zig_refuses(text):
    with pytest.raises(ConfigWrongTypeException, match="not an integer") as e:
        zig_hocon.parse_int(text)
    assert e.value.name == "WrongType"


@pytest.mark.parametrize("text, want", [("true", True), ("yes", True), ("on", True), ("off", False), (False, False)])
def test_parse_bool_reads_as_get_bool(text, want):
    assert zig_hocon.parse_bool(text) is want


@pytest.mark.parametrize("text", ["True", "1", "y", 1])
def test_parse_bool_refuses_what_zig_refuses(text):
    with pytest.raises(ConfigWrongTypeException, match="not a boolean"):
        zig_hocon.parse_bool(text)


# in a model: the lax one takes "08" as 8, the strict one refuses it as the
# Zig struct does
# pydantic has no build for every Python the wheel covers (tools/test-wheel.sh)
def test_a_model_with_the_validators_refuses_what_a_lax_one_takes():
    pydantic = pytest.importorskip("pydantic")
    BaseModel, BeforeValidator, ValidationError = pydantic.BaseModel, pydantic.BeforeValidator, pydantic.ValidationError

    class Lax(BaseModel):
        workers: int
        debug: bool

    class Strict(BaseModel):
        workers: Annotated[int, BeforeValidator(zig_hocon.parse_int)]
        debug: Annotated[bool, BeforeValidator(zig_hocon.parse_bool)]

    assert Lax(workers="08", debug="True").workers == 8
    with pytest.raises(ValidationError):
        Strict(workers="08", debug="yes")
    with pytest.raises(ValidationError):
        Strict(workers="8", debug="True")
    assert Strict(workers="8", debug="yes") == Strict(workers=8, debug=True)
