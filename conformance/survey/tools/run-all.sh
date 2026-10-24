#!/bin/sh
# Run each named survey adapter (conformance/survey/adapters/bin/<name>.sh) over
# the whole suite in both modes; results land in conformance/survey/results/.
#
#   conformance/survey/tools/run-all.sh sconfig pyhocon ruby-hocon
#
# A result that is already there is kept; delete it to measure again.
# JAVA_HOME/bin goes first on PATH for the JVM adapters.
set -u
S=$(cd "$(dirname "$0")/.." && pwd)
cd "$S/../.."
[ -n "${JAVA_HOME:-}" ] && PATH=$JAVA_HOME/bin:$PATH && export PATH
for a in "$@"; do
  for m in spec java; do
    out=$S/results/$m/$a.json
    [ -s "$out" ] && continue
    conformance/run.sh --$m -- "$S/adapters/bin/$a.sh" > "$out"
    echo "$a $m done"
  done
done
