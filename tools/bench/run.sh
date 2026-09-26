#!/bin/sh
# Parse speed of zig-hocon, the two Rust crates (hocon-rs, hocon), typesafe/config
# and pyhocon on the same files, twice: in-process parse times, cold and warm,
# then end to end as commands.
#
#   tools/bench/run.sh                      # 1 KB … 10 MB
#   tools/bench/run.sh 1000 100000          # sizes in bytes
#
# Each parser is timed inside its own process on text already in memory, so
# JVM and Python start-up are not in the numbers. Every file gets a fresh
# process: "cold" is its first parse, before anything is warmed up; "warm" is
# the median after warming up (two seconds of it for Java's JIT). Before timing,
# all five are checked to produce the same JSON for one file, so they are
# measured doing the same work. Needs cargo for the Rust side.
#
# The second table is what a user waits for: `hocon <file>`, a typesafe/config
# command (tools/bench/Cli.java) and the `pyhocon` tool, from process start to
# exit with the JSON written, start-up included.
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
(cd tools/bench/rust && cargo build --release --quiet)
RUST=tools/bench/rust/target/release
python3 tools/bench/gen.py "$OUT" $SIZES

# Same work: all three must print the same JSON for a mid-sized file.
probe="$OUT/10000.conf"
[ -f "$probe" ] || python3 tools/bench/gen.py "$OUT" 10000
zig-out/bin/hocon "$probe" > "$OUT/zig.json"
conformance/adapters/oracle.sh hocon-java "$probe" > "$OUT/java.json"
conformance/adapters/oracle.sh hocon-py "$probe" > "$OUT/py.json"
"$RUST/rust-hocon" hocon-rs "$probe" > "$OUT/hocon-rs.json"
"$RUST/rust-hocon" hocon "$probe" > "$OUT/hocon.json"
python3 - "$OUT" <<'PY'
import json, sys
out = sys.argv[1]
got = [json.load(open(f"{out}/{n}.json")) for n in ("zig", "java", "py", "hocon-rs", "hocon")]
if any(g != got[0] for g in got):
    sys.exit("the parsers disagree on 10000.conf — not comparable")
PY

files=$(for s in $SIZES; do printf '%s ' "$OUT/$s.conf"; done)
# One process per file, so "cold" really is cold for every size. Sizes grow
# geometrically, so once the last two first runs say the next one would take
# over two minutes (the old Rust crate is quadratic), the rest are skipped.
per_file() {
    name=$1; shift; tsv="$OUT/$name.tsv"; : > "$tsv"
    for f in $files; do
        if awk -F'\t' 'NR > 1 && $4 > 0 && p > 0 && $4 * $4 / p > 120e9 { slow = 1 } { p = $4 } END { exit !slow }' "$tsv"; then
            printf '%s\tskipped\t0\tskipped\n' "$f" >> "$tsv"
        else
            "$@" "$f" >> "$tsv"
        fi
    done
}
echo "parse: zig-hocon…" >&2;       per_file zig zig-out/bin/hocon-bench
echo "parse: hocon-rs…" >&2;        per_file hocon-rs "$RUST/rust-bench" hocon-rs
echo "parse: hocon (Rust)…" >&2;    per_file hocon "$RUST/rust-bench" hocon
echo "parse: typesafe/config…" >&2; javac=$(dirname "$(command -v "$JAVA" || echo "$JAVA")")/javac
mkdir -p "$OUT/classes"
"$javac" -cp "$JAR" -d "$OUT/classes" tools/bench/Bench.java tools/bench/Cli.java
per_file java "$JAVA" -cp "$JAR:$OUT/classes" Bench
echo "parse: pyhocon…" >&2;         per_file py "$PY" tools/bench/bench.py

echo "end to end…" >&2
# shellcheck disable=SC2086
JAVA="$JAVA" python3 tools/bench/e2e.py "$OUT" $files
echo
python3 tools/bench/table.py "$OUT"
