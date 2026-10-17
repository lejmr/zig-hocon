#!/bin/sh
# Installs a wheel into a fresh uv environment of one Python and runs the
# package's tests and every example against it: what `pip install` gives,
# not python/. CI runs it for each Python and system.
#
#   tools/test-wheel.sh 3.12 zig-out/wheels/zig_hocon-0.1.0-py3-none-macosx_13_0_arm64.whl
set -eu
version=$1
wheel=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

uv venv -q --python "$version" "$tmp/venv"
py=$tmp/venv/bin/python
[ -x "$py" ] || py=$tmp/venv/Scripts/python.exe
uv pip install -q --python "$py" "$wheel" pytest pydantic msgspec

# From elsewhere, so nothing imports python/zig_hocon by accident.
cd "$tmp"
"$py" -c 'import sys, zig_hocon; print(sys.version.split()[0], zig_hocon.__file__); assert "site-packages" in zig_hocon.__file__'
"$py" -m pytest -q -p no:cacheprovider "$root/python/tests"
# One run each: every example has its own models_pydantic.py.
for example in "$root"/examples/*/; do
    "$py" -m pytest -q -p no:cacheprovider "$example"
done
