#!/bin/sh
# Parse speed of zig-hocon, the Python HOCON libraries (zig-hocon's own package,
# pyhocon, pulse-pyhocon, py.hocon, hocon2), the Rust crates (hocon-rs, hocon, rs.hocon)
# and typesafe/config on the same files, twice: in-process parse times, cold and
# warm, then end to end as commands.
#
#   tools/bench/run.sh                      # 1 KB … 10 MB
#   tools/bench/run.sh 1000 100000          # sizes in bytes, smallest first
#   REFS=1 tools/bench/run.sh               # the same with substitutions (gen.py --refs)
#
# Each parser is timed inside its own process on text already in memory, so
# JVM and Python start-up are not in the numbers. Every file gets a fresh
# process: "cold" is its first parse, before anything is warmed up; "warm" is
# the median after warming up (two seconds of it for Java's JIT). Before timing,
# each implementation's JSON for the file must equal typesafe/config's, so they
# are measured doing the same work; a cell says "wrong output" (or "error", if
# the file is rejected) instead of a time where it does not. A parse that has
# not finished in two minutes is cut off and shown as "> 120 s", and the larger
# files after it are not tried. Needs cargo for the Rust side and uv for the
# Python one: the Python libraries are pinned below and installed into
# zig-out/bench-py*, on one interpreter for all.
#
# The second table is what a user waits for: `hocon --json <file>`, the Rust
# crates as a command, a typesafe/config command (tools/bench/Cli.java) and the
# `pyhocon` tool, from process start to exit with the JSON written, start-up
# included.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
OUT=zig-out/bench
GEN=
[ -n "${REFS:-}" ] && { OUT=zig-out/bench-refs; GEN=--refs; }
SIZES=${*:-1000 10000 100000 1000000 10000000}

JAVA=java
java -version >/dev/null 2>&1 || JAVA=/opt/homebrew/opt/openjdk/bin/java
JAR=tools/oracle/config-1.4.9.jar
[ -f "$JAR" ] || curl -sSLf -o "$JAR" https://repo1.maven.org/maven2/com/typesafe/config/1.4.9/config-1.4.9.jar

zig build -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast
zig build python -Doptimize=ReleaseFast
(cd tools/bench/rust && cargo build --release --quiet)
RUST=tools/bench/rust/target/release
PY=zig-out/bench-py/bin/python
uv venv -q --allow-existing --python 3.12 zig-out/bench-py
uv pip install -q -p "$PY" pyhocon==0.3.63 pyparsing==3.3.2 pulse-pyhocon==0.2.1 hocon-parser==1.14.2
# hocon2 imports as `hocon` too, like hocon-parser, so it gets its own
PY2=zig-out/bench-py-hocon2/bin/python
uv venv -q --allow-existing --python 3.12 zig-out/bench-py-hocon2
uv pip install -q -p "$PY2" hocon2==0.6.3
javac=$(dirname "$(command -v "$JAVA" || echo "$JAVA")")/javac
mkdir -p "$OUT/classes"
"$javac" -cp "$JAR" -d "$OUT/classes" tools/bench/Bench.java tools/bench/Cli.java
python3 tools/bench/gen.py $GEN "$OUT" $SIZES

# What implementation $1 makes of file $2, as JSON; and its parse times for $2.
# ponytail: perl alarm, since macOS ships no timeout(1); killed by it = exit 142
CAP="perl -e alarm(120);exec(@ARGV)"
json() {
    case $1 in
        zig) $CAP zig-out/bin/hocon --json "$2" ;;
        java) $CAP "$JAVA" -cp "$JAR:$OUT/classes" Cli "$2" ;;
        hocon-rs|hocon|rs.hocon) $CAP "$RUST/rust-hocon" "$1" "$2" ;;
        hocon2) $CAP "$PY2" tools/bench/bench.py "$1" --json "$2" ;;
        *) $CAP "$PY" tools/bench/bench.py "$1" --json "$2" ;;
    esac
}
timed() {
    case $1 in
        zig) $CAP zig-out/bin/hocon-bench "$2" ;;
        java) $CAP "$JAVA" -cp "$JAR:$OUT/classes" Bench "$2" ;;
        hocon-rs|hocon|rs.hocon) $CAP "$RUST/rust-bench" "$1" "$2" ;;
        hocon2) $CAP "$PY2" tools/bench/bench.py "$1" "$2" ;;
        *) $CAP "$PY" tools/bench/bench.py "$1" "$2" ;;
    esac
}
mark() { printf '%s\t%s\t0\t%s\n' "$1" "$2" "$2"; }
cell() {
    st=0; json "$1" "$2" > "$OUT/got.json" 2>/dev/null || st=$?
    case $st in 0) ;; 142) mark "$2" timeout; return ;; *) mark "$2" error; return ;; esac
    python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' \
        "$2.json" "$OUT/got.json" || { mark "$2" wrong; return; }
    st=0; timed "$1" "$2" || st=$?
    case $st in 0) ;; 142) mark "$2" timeout ;; *) mark "$2" error ;; esac
}

files=$(for s in $SIZES; do printf '%s ' "$OUT/$s.conf"; done)
for f in $files; do json java "$f" > "$f.json"; done
# One process per file, so "cold" really is cold for every size.
per_file() {
    echo "parse: $1…" >&2
    tsv="$OUT/$1.tsv"; : > "$tsv"
    for f in $files; do
        if grep -q '	timeout	' "$tsv"; then mark "$f" timeout; else cell "$1" "$f"; fi >> "$tsv"
    done
}
for impl in zig zig-hocon-python pyhocon pulse-pyhocon py.hocon hocon2 hocon-rs hocon rs.hocon java; do
    per_file "$impl"
done

echo "end to end…" >&2
# shellcheck disable=SC2086
JAVA="$JAVA" python3 tools/bench/e2e.py "$OUT" $files
echo
python3 tools/bench/table.py "$OUT"
