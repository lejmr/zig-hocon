# Java adapter, any config jar

## What it is

Two files, no build tool. `Adapter.java` takes the path the runner hands it —
a `.conf` file or a directory case's `main.conf` — parses it with includes
resolving beside it, resolves substitutions, prints the resolved root as
compact JSON and exits 0. Any `ConfigException` prints on stderr and exits 1:
a reject. `java-adapter.sh` compiles it once per jar and runs it on each case.

The jar under test is not baked in: it arrives through `CONFIG_JAR`, so the
same adapter scores the released typesafe/config, an unreleased branch
snapshot of it, or sconfig. `AdapterSconfig.java` is the same adapter with
`org.ekrich.config` imports; the script falls back to it when the jar does not
provide `com.typesafe.config`.

## The one command

```sh
CONFIG_JAR=/path/to/config.jar conformance/run.sh -- ./java-adapter.sh
```

Compiled classes land in `${XDG_CACHE_HOME:-$HOME/.cache}/hocon-java-adapter/`
(one subdirectory per jar) and are reused across runs.

## What it needs

A POSIX shell, `python3` (that is `run.sh`'s own bill), and a JDK with `javac`
and `java` on PATH. No sbt, no maven, no scala. `CONFIG_JAR` holds the
classpath under test: one typesafe/config jar is enough (it is
self-contained); sconfig is a Scala library, so its jar travels with its scala
runtime — the classpath may be colon-separated:

```sh
CONFIG_JAR=sconfig_3-2.1.0.jar:scala3-library_3-3.3.6.jar:scala-library-2.13.16.jar \
    conformance/run.sh -- ./java-adapter.sh
```

Checked on typesafe/config 1.4.9 and on sconfig 2.1.0. The adapter itself
depends on nothing but whatever `CONFIG_JAR` provides.
