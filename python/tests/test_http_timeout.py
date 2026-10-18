"""An include from a server that takes the connection and never answers fails
in ``http_timeout`` with IncludeTimeout, instead of holding the parse."""

import datetime
import socket
import time

import pytest

from zig_hocon import ConfigFactory, ConfigParseException


@pytest.fixture
def silent_url():
    """A socket that listens and never accepts: the system takes the
    connection, and nobody reads the request."""
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        server.listen()
        yield f"http://127.0.0.1:{server.getsockname()[1]}/hang"


def expect_timeout(parse):
    start = time.monotonic()
    with pytest.raises(ConfigParseException) as e:
        parse()
    assert e.value.name == "IncludeTimeout"
    # Up to 5 s for a slow machine: far from the 30 s of the default.
    assert 0.1 < time.monotonic() - start < 5


@pytest.mark.parametrize("timeout", [0.2, datetime.timedelta(milliseconds=200)])
def test_a_string_s_include_times_out(silent_url, tmp_path, timeout):
    expect_timeout(lambda: ConfigFactory.parse_string(f'include url("{silent_url}")', basedir=tmp_path, env=None, http_timeout=timeout))


def test_a_file_s_include_times_out(silent_url, tmp_path):
    path = tmp_path / "app.conf"
    path.write_text(f'name = patient owl\ninclude url("{silent_url}")\n')
    expect_timeout(lambda: ConfigFactory.parse_file(path, env=None, http_timeout=0.2))


# 0 is hocon.h's default, and a uint32_t of milliseconds ends at 49 days.
@pytest.mark.parametrize("timeout", [0, -1, 0.0001, datetime.timedelta(days=50)])
def test_a_timeout_out_of_range(timeout):
    with pytest.raises(ValueError, match="http_timeout: expected 1 ms to 49 days"):
        ConfigFactory.parse_string("a = 1", http_timeout=timeout)
