#!/bin/sh
# The table in python/BENCHMARK.md: run.sh on 1 KB, 1 MB and 10 MB files with
# substitutions, then every implementation against the conformance suite,
# then the table.
#
#   tools/bench/landscape.sh
#
# Spec scores land in zig-out/landscape/<name>.spec.json. pyhocon's and
# typesafe/config's are the ones in conformance/reports, for the same versions
# (pyhocon 0.3.63, typesafe/config 1.4.9); the rest are measured here, through
# the same commands run.sh compares, cut off after 30 s a case (pyhocon loops
# forever on some inputs, and pulse-pyhocon falls back to it).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
REFS=1 sh tools/bench/run.sh 1000 1000000 10000000

S=zig-out/landscape
mkdir -p "$S"
cp conformance/reports/pyhocon.spec.json "$S/pyhocon.spec.json"
cp conformance/reports/Java.spec.json "$S/java.spec.json"
spec() {
    name=$1 version=$2; shift 2
    echo "spec: ${name}…" >&2
    # run.sh exits 1 on any failure that is not an open question; the score is the point here
    conformance/run.sh --spec --impl "$name" --version "$version" -- perl -e 'alarm 30; exec @ARGV' "$@" > "$S/$name.spec.json" || true
}
here=$(git describe --tags --always)
spec zig "$here" conformance/adapters/zig-hocon.sh
spec zig-hocon-python "$here" conformance/adapters/zig-hocon-python.sh
for lib in pulse-pyhocon:0.2.1 py.hocon:1.14.2; do
    spec "${lib%:*}" "${lib#*:}" zig-out/bench-py/bin/python tools/bench/bench.py "${lib%:*}" --json
done
spec hocon2 0.6.3 zig-out/bench-py-hocon2/bin/python tools/bench/bench.py hocon2 --json
spec rs.hocon 1.14.2 tools/bench/rust/target/release/rust-hocon rs.hocon
spec hocon-rs 0.2.0 tools/bench/rust/target/release/rust-hocon hocon-rs
spec hocon 0.9.0 tools/bench/rust/target/release/rust-hocon hocon

echo
python3 tools/bench/table.py --landscape zig-out/bench-refs "$S"
