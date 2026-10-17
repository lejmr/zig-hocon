#!/bin/sh
# Adapter for the Python package: `python -m zig_hocon --json`, through ctypes
# and libhocon's C API. The same suite as zig-hocon.sh, so the two scores say
# whether the C API, the ctypes layer and the conversions lose anything.
#
#   zig build python
#   conformance/run.sh --text -- conformance/adapters/zig-hocon-python.sh
#
# It runs python/zig_hocon with the library `zig build python` put next to
# it, on the python3 in PATH (3.10 or later).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PKG="$HERE/../../python"

# As zig-hocon.sh: a digest of what a run measures, the package included.
if [ "${1:-}" = "--version" ]; then
    digest=$(git -C "$HERE/../.." ls-tree HEAD src build.zig build.zig.zon conformance/suite python/zig_hocon |
        git hash-object --stdin | cut -c1-7)
    echo "zig-hocon-python code@$digest"
    exit 0
fi

ls "$PKG"/zig_hocon/*hocon.* >/dev/null 2>&1 || { echo "no libhocon in $PKG/zig_hocon — run \`zig build python\` first" >&2; exit 2; }

PYTHONPATH="$PKG" exec python3 -m zig_hocon --json "$1"
