#!/bin/sh
# Adapter for this repository's own parser: the `hocon` CLI already speaks the
# run.sh contract (path in, compact JSON out, non-zero on rejection).
#
#   zig build
#   conformance/run.sh --text -- conformance/adapters/zig-hocon.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HERE/../../zig-out/bin/hocon"

[ -x "$BIN" ] || { echo "no binary at $BIN — run \`zig build\` first" >&2; exit 2; }
[ "${1:-}" = "--version" ] && { echo "zig-hocon $(git -C "$HERE" rev-parse --short HEAD)"; exit 0; }

exec "$BIN" "$1"
