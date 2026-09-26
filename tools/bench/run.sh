#!/bin/sh
# Parse speed of zig-hocon, typesafe/config and pyhocon on the same files.
#
#   tools/bench/run.sh                      # 1 KB … 10 MB
#   tools/bench/run.sh 1000 100000          # sizes in bytes
#
# Each parser is timed inside its own process on text already in memory, so
# JVM and Python start-up are not in the numbers; Java is warmed up first. Each
# cell is the median of repeated runs. Before timing, the three are checked to
# produce the same JSON for one file, so they are measured doing the same work.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
OUT=zig-out/bench
SIZES=${*:-1000 10000 100000 1000000 10000000}

JAVA=java
java -version >/dev/null 2>&1 || JAVA=/opt/homebrew/opt/openjdk/bin/java
PY=tools/oracle/venv/bin/python
JAR=tools/oracle/config-1.4.9.jar
[ -x "$PY" ] || { echo "no pyhocon venv — run tools/oracle/hocon-py once to create it" >&2; exit 2; }
[ -f "$JAR" ] || { echo "no $JAR — run tools/oracle/hocon-java once to fetch it" >&2; exit 2; }

zig build -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast
python3 tools/bench/gen.py "$OUT" $SIZES

# Same work: all three must print the same JSON for a mid-sized file.
probe="$OUT/10000.conf"
[ -f "$probe" ] || python3 tools/bench/gen.py "$OUT" 10000
zig-out/bin/hocon "$probe" > "$OUT/zig.json"
conformance/adapters/oracle.sh hocon-java "$probe" > "$OUT/java.json"
conformance/adapters/oracle.sh hocon-py "$probe" > "$OUT/py.json"
python3 - "$OUT" <<'PY'
import json, sys
out = sys.argv[1]
z, j, p = (json.load(open(f"{out}/{n}.json")) for n in ("zig", "java", "py"))
if not z == j == p:
    sys.exit("the three parsers disagree on 10000.conf — not comparable")
PY

files=$(for s in $SIZES; do printf '%s ' "$OUT/$s.conf"; done)
echo "zig-hocon…" >&2
# shellcheck disable=SC2086
zig-out/bin/hocon-bench $files > "$OUT/zig.tsv"
echo "typesafe/config…" >&2
# shellcheck disable=SC2086
"$JAVA" -cp "$JAR" tools/bench/Bench.java $files > "$OUT/java.tsv"
echo "pyhocon…" >&2
# shellcheck disable=SC2086
"$PY" tools/bench/bench.py $files > "$OUT/py.tsv"

python3 tools/bench/table.py "$OUT"
