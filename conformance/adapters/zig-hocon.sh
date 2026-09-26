#!/bin/sh
# Adapter for this repository's own parser: the `hocon` CLI already speaks the
# run.sh contract (path in, compact JSON out, non-zero on rejection).
#
#   zig build
#   conformance/run.sh --text -- conformance/adapters/zig-hocon.sh
#
# HOCON_BIN points it at another build; tools/hooks/pre-push uses that to
# measure HEAD rather than whatever is in the working tree.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="${HOCON_BIN:-$HERE/../../zig-out/bin/hocon}"

# The version is a digest of what a run measures — the parser and the suite as
# committed in HEAD — not a commit hash. Adding the results to a commit, amended
# in or on top, changes the hash but not this, so the results stay current.
if [ "${1:-}" = "--version" ]; then
    digest=$(git -C "$HERE/../.." ls-tree HEAD src build.zig build.zig.zon conformance/suite |
        git hash-object --stdin | cut -c1-7)
    echo "zig-hocon code@$digest"
    exit 0
fi

[ -x "$BIN" ] || { echo "no binary at $BIN — run \`zig build\` first" >&2; exit 2; }

exec "$BIN" "$1"
