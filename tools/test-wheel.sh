#!/bin/sh
# Installs a wheel into a fresh uv environment of one Python and runs the
# package's tests and every example against it: what `pip install` gives,
# not python/. CI runs it for each Python and system.
#
#   tools/test-wheel.sh 3.12 zig-out/wheels/zig_hocon-0.4.0-py3-none-macosx_13_0_arm64.whl
set -eu
version=$1
wheel=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

uv venv -q --python "$version" "$tmp/venv"
py=$tmp/venv/bin/python
[ -x "$py" ] || py=$tmp/venv/Scripts/python.exe
# The examples read into pydantic and msgspec, and msgspec has no build for
# PyPy or a free-threaded Python: there only the package's tests run.
case $version in
    pypy* | *t) examples=no; uv pip install -q --python "$py" "$wheel" pytest pyhocon ;;
    *) examples=yes; uv pip install -q --python "$py" "$wheel" pytest pyhocon pydantic msgspec ;;
esac

# From elsewhere, so nothing imports python/zig_hocon by accident.
cd "$tmp"
"$py" -c 'import sys, zig_hocon; print(sys.version.split()[0], zig_hocon.__file__); assert "site-packages" in zig_hocon.__file__'
"$py" -m pytest -q -p no:cacheprovider "$root/python/tests"
# The command pip puts beside python (zig-hocon-migrate.exe on Windows).
"$(dirname "$py")/zig-hocon-migrate" --help >/dev/null
if [ $examples = no ]; then
    echo "examples left out: no msgspec for Python $version"
    exit 0
fi
# One run each: every example has its own models_pydantic.py.
for example in "$root"/python/examples/*/; do
    "$py" -m pytest -q -p no:cacheprovider "$example"
done
