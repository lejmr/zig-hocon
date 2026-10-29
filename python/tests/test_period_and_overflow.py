"""parse_period beside parse_duration, and a duration past what C holds."""

import pytest

import zig_hocon
from zig_hocon import ConfigFactory, ConfigWrongTypeException


def test_parse_period_reads_as_get_period():
    assert zig_hocon.parse_period("3mo") == zig_hocon.Period(years=0, months=3, days=0)
    assert zig_hocon.parse_period("2w").days == 14
    years, months, days = zig_hocon.parse_period(5)
    assert (years, months, days) == (0, 0, 5)


def test_parse_period_refuses_what_is_none():
    with pytest.raises(ConfigWrongTypeException, match="not a period: 'soon'") as e:
        zig_hocon.parse_period("soon")
    assert e.value.name == "WrongType"


# C holds nanoseconds in an int64 and saturates past 292 years: a timedelta
# of 292 years for 547 would be wrong without a word, so it is an error
def test_a_duration_past_292_years_is_an_overflow():
    conf = ConfigFactory.parse_string("long = 200000d\nfine = 100000d")
    assert conf.get_duration("fine").days == 100000
    assert conf.get_duration("absent", None) is None
    with pytest.raises(ConfigWrongTypeException, match="long is past 292 years") as e:
        conf.get_duration("long")
    assert e.value.name == "Overflow"
    # a value is there, too long: the default is not for that
    with pytest.raises(ConfigWrongTypeException):
        conf.get_duration("long", None)
    with pytest.raises(ConfigWrongTypeException) as e:
        zig_hocon.parse_duration("200000d")
    assert e.value.name == "Overflow"
