#!/bin/sh
# Run each named adapter over the unreviewed candidates in conformance/candidates
# (spec mode only); `zig-hocon` means this repository's own adapter.
#
#   conformance/survey/tools/run-candidates.sh zig-hocon java-1.4.9 sconfig
set -u
S=$(cd "$(dirname "$0")/.." && pwd)
cd "$S/../.."
[ -n "${JAVA_HOME:-}" ] && PATH=$JAVA_HOME/bin:$PATH && export PATH
for a in "$@"; do
  case $a in zig-hocon) cmd=conformance/adapters/zig-hocon.sh ;; *) cmd=$S/adapters/bin/$a.sh ;; esac
  conformance/run.sh --spec --dir conformance/candidates -- $cmd > "$S/results/candidates/$a.json"
done
