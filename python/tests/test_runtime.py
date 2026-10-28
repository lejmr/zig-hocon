"""What a parse does to the process around it: a deep document on a thread
with little stack is TooDeep or read, never a crash, and the signal handlers
a program set are its own after a parse, one that fetches an include too."""

import http.server
import os
import signal
import socket
import threading
import time

import pytest

from zig_hocon import ConfigFactory, ConfigParseException


def deep(shape, n):
    if shape == "appends":
        return "x = []\n" + "".join(f"x += [{i}]\n" for i in range(n))
    if shape == "nested":
        return "a = " + "{b = " * n + "1" + "}" * n
    # each field waits for the next, so the chain is resolved in depth
    return "".join(f"a{i} = ${{a{i + 1}}}\n" for i in range(n)) + f"a{n} = 1\n"


def on_a_small_thread(work):
    """``work()`` on a thread of 256 KiB of stack, as musl gives one; what it
    returned or raised."""
    out = {}

    def run():
        try:
            out["value"] = work()
        except Exception as e:  # noqa: BLE001 - handed to the test
            out["error"] = e

    before = threading.stack_size(256 * 1024)
    try:
        thread = threading.Thread(target=run)
        thread.start()
    finally:
        threading.stack_size(before)
    thread.join()
    return out


@pytest.mark.parametrize("shape", ["appends", "nested", "chained"])
def test_a_deep_document_on_a_small_stack(shape):
    # read, and written back: as HOCON, as JSON stops at 256 levels
    out = on_a_small_thread(lambda: ConfigFactory.parse_string(deep(shape, 499), env=None).to_hocon())
    assert "value" in out, out
    if shape == "appends":
        assert len(ConfigFactory.parse_string(out["value"]).as_dict()["x"]) == 499
    out = on_a_small_thread(lambda: ConfigFactory.parse_string(deep(shape, 1000), env=None))
    assert isinstance(out.get("error"), ConfigParseException), out
    assert out["error"].name == "TooDeep"


def test_writing_a_deep_value_on_a_small_stack():
    conf = ConfigFactory.parse_string("a = " + "[" * 400 + "]" * 400, env=None)
    out = on_a_small_thread(conf.to_json)
    assert out["error"].name == "TooDeep"
    conf = ConfigFactory.parse_string("a = " + "[" * 255 + "]" * 255, env=None)
    assert "value" in on_a_small_thread(conf.as_dict)


@pytest.fixture
def owl_url():
    """A server with one config on it, for an include to fetch."""

    class Owl(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"hoot = 1\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Owl)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_address[1]}/owl.conf"
    server.shutdown()


@pytest.fixture
def silent_url():
    """A socket that listens and never accepts: a fetch that times out."""
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        server.listen()
        yield f"http://127.0.0.1:{server.getsockname()[1]}/hang"


@pytest.mark.skipif(not hasattr(signal, "SIGIO"), reason="no SIGIO here")
def test_the_program_s_signal_handler_stays(owl_url, silent_url, tmp_path):
    heard = []
    before = signal.signal(signal.SIGIO, lambda *_: heard.append(1))
    try:
        for parse in [
            lambda: ConfigFactory.parse_string("a = 1", env=None),
            lambda: ConfigFactory.parse_string(f'include url("{owl_url}")', basedir=tmp_path, env=None),
        ]:
            conf = parse()
            heard.clear()
            os.kill(os.getpid(), signal.SIGIO)
            time.sleep(0.05)
            assert heard, conf
        assert conf.get_int("hoot") == 1
        with pytest.raises(ConfigParseException):
            ConfigFactory.parse_string(f'include url("{silent_url}")', basedir=tmp_path, env=None, http_timeout=0.2)
        heard.clear()
        os.kill(os.getpid(), signal.SIGIO)
        time.sleep(0.05)
        assert heard
    finally:
        signal.signal(signal.SIGIO, before)
