#!/bin/sh
# Line coverage of typesafe/config while it parses and resolves this suite.
#
#   conformance/maintaining/java-coverage.sh            # table on stdout
#   HOCON_JAVA_VERSION=1.4.5 conformance/maintaining/java-coverage.sh
#   printf 'resolve:a = 1\n' | conformance/maintaining/java-coverage.sh --probe
#
# --probe reads oracle lines from stdin, runs them against the last full run's
# build, and lists the lines they reach that the suite does not; the answers
# come out on stderr.
#
# The code the cases never reach is the list of cases still to write. Writes
# coverage/ next to this script (gitignored): jacoco.exec, report.xml, html/,
# and uncovered.txt — every missed line with its source, grouped by class.
#
# Needs java, javac, curl, python3. The sources (a GitHub tag tarball) and the
# JaCoCo jars are fetched into tools/oracle/ on first run.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/../..
CACHE=$ROOT/tools/oracle
OUT=$HERE/coverage
VERSION=${HOCON_JAVA_VERSION:-1.4.9}
JACOCO=0.8.15
MAVEN=https://repo1.maven.org/maven2

if ! java -version >/dev/null 2>&1; then
    PATH="/opt/homebrew/opt/openjdk/bin:$PATH"
    export PATH
fi

fetch() { [ -f "$CACHE/$1" ] || curl -sSLf -o "$CACHE/$1" "$MAVEN/$2"; }
SRC=$CACHE/config-$VERSION-src.tar.gz
[ -f "$SRC" ] || curl -sSLf -o "$SRC" "https://github.com/lightbend/config/archive/refs/tags/v$VERSION.tar.gz"
fetch "org.jacoco.agent-$JACOCO-runtime.jar" "org/jacoco/org.jacoco.agent/$JACOCO/org.jacoco.agent-$JACOCO-runtime.jar"
fetch "org.jacoco.cli-$JACOCO-nodeps.jar" "org/jacoco/org.jacoco.cli/$JACOCO/org.jacoco.cli-$JACOCO-nodeps.jar"
AGENT=$CACHE/org.jacoco.agent-$JACOCO-runtime.jar
CLI=$CACHE/org.jacoco.cli-$JACOCO-nodeps.jar

if [ "${1:-}" = "--probe" ]; then
    rm -f "$OUT/probe.exec"
    java -javaagent:$AGENT=destfile=$OUT/probe.exec,includes=com.typesafe.* -cp "$OUT/classes:$OUT" Oracle >&2
    java -jar "$CLI" report "$OUT/probe.exec" --classfiles "$OUT/classes" --xml "$OUT/probe.xml" >/dev/null
    exec python3 "$HERE/java-coverage.py" "$OUT" --probe "$OUT/probe.xml"
fi

rm -rf "$OUT"
mkdir -p "$OUT/src" "$OUT/classes"
tar xzf "$SRC" -C "$OUT/src" --strip-components 5 "config-$VERSION/config/src/main/java"
# -g keeps line numbers; 17 because JaCoCo has to understand the class files
javac -g -nowarn -Xlint:none --release 17 -d "$OUT/classes" $(find "$OUT/src" -name '*.java')
javac -nowarn -cp "$OUT/classes" -d "$OUT" "$CACHE/Oracle.java"

# every case as one oracle line; cases that need environment variables get a
# JVM each, because the environment is per process
python3 - "$HERE" "$OUT" <<'PY'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1]); import suite
out = pathlib.Path(sys.argv[2])
plain, env = [], []
for conf in sorted(suite.SUITE.rglob("*.conf")):
    side = conf.with_suffix(".json")
    if not side.exists() or suite.is_fixture(conf):
        continue
    meta = json.loads(side.read_text())
    line = "resolve:file:" + str(conf) if conf.name == "main.conf" else "resolve:" + suite.encode(conf.read_text())
    if meta.get("env"):
        env.append(" ".join(f"{k}={v}" for k, v in meta["env"].items()) + "\t" + line)
    else:
        plain.append(line)
(out / "lines.txt").write_text("\n".join(plain) + "\n")
(out / "env-lines.txt").write_text("".join(l + "\n" for l in env))
PY

JVM="java -javaagent:$AGENT=destfile=$OUT/jacoco.exec,append=true,includes=com.typesafe.* -cp $OUT/classes:$OUT Oracle"
$JVM < "$OUT/lines.txt" > "$OUT/answers.txt"
while IFS="$(printf '\t')" read -r vars line; do
    printf '%s\n' "$line" | env $vars $JVM >> "$OUT/answers.txt"
done < "$OUT/env-lines.txt"

java -jar "$CLI" report "$OUT/jacoco.exec" --classfiles "$OUT/classes" --sourcefiles "$OUT/src" \
    --xml "$OUT/report.xml" --html "$OUT/html" >/dev/null

python3 "$HERE/java-coverage.py" "$OUT"
