# Coming from typesafe/config

zig-hocon reads the same format, but not always the same way. [spec.md](spec.md) goes through the spec section by section and says where it differs from typesafe/config; [internals.md](internals.md) says how it is built and which reference implementations settle disputes. What you are most likely to run into:

- **A number is a number only as JSON writes it.** `01`, `1.` and `08` stay text, where typesafe/config reads `01` as `1`; an integer getter or struct field refuses such text. A duration's number is read the same JSON way, so `.5 s` and `01 s`, which typesafe/config takes, are errors.
- **`1.5` read as an integer is an error**, not a silent `1`.
- **Not supported:** `include classpath(…)`, URL schemes other than http, https and file, and the JVM conventions: system property overrides, Java properties mapping beyond plain `.properties` lines, and conventional file names, so nothing loads `application.conf` or `reference.conf` on its own.
- **No `withFallback`.** typesafe/config's model, where every library ships a `reference.conf` and the application's config falls back to them, has no equivalent: configs that are already loaded, or built in code, cannot be merged. Layer files instead, with a file that includes the defaults and then overrides them, as `prod.conf` does with `app.conf`. In Zig, a struct's field defaults fill in what the file leaves out.
- **`hocon` prints what zig-hocon reads**, which in the [91 cases](#the-91-cases) is not what a JVM service loads.

## The 91 cases

**zig-hocon differs from typesafe/config 1.4.9 in 91 cases**: the ones where the suite's reading and typesafe/config part ways, listed in [the conformance report](https://htmlpreview.github.io/?https://github.com/lejmr/zig-hocon/blob/main/conformance/report.html) when you switch it to typesafe/config. Why they differ:

- **12 are numbers.** The spec says "allowed number formats matches JSON" (L120), so `01`, `1.` and `08080` stay text. typesafe/config reads them as 1, 1 and 8080, a leniency it keeps on purpose for compatibility: [#861](https://github.com/lightbend/config/pull/861) leaves leading zeros and trailing dots out of scope.
- **16 have a fix in an upstream pull request** ([#861](https://github.com/lightbend/config/pull/861), [#862](https://github.com/lightbend/config/pull/862), [#864](https://github.com/lightbend/config/pull/864)); none of it is in a typesafe/config release yet.
- **19 are reported upstream**, as an issue or a pull request the case links, [#863](https://github.com/lightbend/config/pull/863) among them.
- **44 are not reported upstream yet.** In 27 typesafe/config refuses input the spec allows: some are internal errors such as `BugOrBroken`, others are things it does not support by design, such as an array as the document root. In 9 it gives a different value, and in 8 it accepts input the spec forbids.

`conformance/run.sh --java` scores any parser against typesafe/config instead of the spec, through an adapter of about ten lines ([conformance/README.md](../conformance/README.md)).
