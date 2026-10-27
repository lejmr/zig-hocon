"""Where a value is past what the library holds, and input that is no text."""

import datetime

import pytest

from zig_hocon import ConfigFactory, parse_duration
from zig_hocon.exceptions import ConfigWrongTypeException


# java ✓ (getDuration saturates too, but its Duration holds it) · pyhocon ✗ (gives the
# timedelta) · spec – — the library's nanoseconds stop at about 292 years: a timedelta
# there would be quietly wrong, so it is an error, either way.
@pytest.mark.parametrize("text", ["300000 d", "-300000 d"])
def test_a_duration_past_292_years_is_an_error(text):
    conf = ConfigFactory.parse_string(f"d = {text}", env=None)
    with pytest.raises(ConfigWrongTypeException) as caught:
        conf.get_duration("d")
    assert caught.value.name == "Overflow"
    with pytest.raises(ConfigWrongTypeException):
        parse_duration(text)
    assert ConfigFactory.parse_string("d = 100000 d", env=None).get_duration("d") == datetime.timedelta(days=100000)


# pyhocon ✓ (AttributeError) — text or bytes only: a number is no buffer of zeros.
@pytest.mark.parametrize("content", [0, 3, [97]])
def test_parse_string_takes_text_or_bytes(content):
    with pytest.raises(TypeError):
        ConfigFactory.parse_string(content, env=None)


def test_parse_string_takes_any_bytes():
    assert ConfigFactory.parse_string(bytearray(b"a = 1"), env=None).get_int("a") == 1
    assert ConfigFactory.parse_string(memoryview(b"a = 1"), env=None).get_int("a") == 1


def test_a_missing_duration_is_the_default():
    assert ConfigFactory.parse_string("a = 1", env=None).get_duration("d", "no wait") == "no wait"
