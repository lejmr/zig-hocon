"""Render the committed run results as a table. Runs no parser itself.

    python3 conformance/maintaining/report.py [--check]

Reads every conformance/reports/*.json — the output of `conformance/run.sh` —
and writes conformance/report.html plus a one-table summary in the README, which
links to the page. An implementation
appears because its result file is committed; leaving a file out is how a
column stays off the published page.

--check writes nothing and exits non-zero if any output is out of date.
"""

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import page
import suite

ROOT, SUITE, REPORTS = suite.ROOT, suite.SUITE, suite.REPORTS
PAGE = ROOT / "conformance" / "report.html"
README = ROOT / "README.md"
START, END = "<!-- conformance:start -->", "<!-- conformance:end -->"
COVERAGE = ROOT / "conformance" / "maintaining" / "COVERAGE.md"
SPEC_PAGE = ROOT / "conformance" / "maintaining" / "COVERAGE.html"
SPEC = ROOT / "spec" / "HOCON.md"
SECTIONS_MD = ROOT / "conformance" / "maintaining" / "SECTIONS.md"
# sections whose rules live in typed accessors the oracle protocol never calls;
# their cases pin only that the value survives the parse
NOT_MEASURED = {"units-format", "duration-format", "period-format", "size-in-bytes-format"}
# the typesafe/config a plain `run.sh --java` scores against; the page and the
# `java` mode mean this one, a run against any other version gets its own column
JAVA_RELEASE = "1.4.9"


def spec_coverage(rules, tagged):
    """spec/HOCON.md as a page: every sentence that is a rule in RULES.md is
    marked, green with a case and red without, hover for the id and the cases.
    Everything unmarked is prose the suite does not claim to check."""
    import html, re
    lines = SPEC.read_text().splitlines()
    blocks, i = [], 0  # (kind, first line, last line, text)
    while i < len(lines):
        if lines[i].startswith("```"):
            j = i + 1
            while j < len(lines) and not lines[j].startswith("```"):
                j += 1
            blocks.append(("pre", i + 1, j + 1, "\n".join(lines[i + 1:j]))); i = j + 1
        elif not lines[i].strip():
            i += 1
        elif lines[i].startswith("#"):
            blocks.append(("h", i + 1, i + 1, lines[i])); i += 1
        else:
            j = i
            while j < len(lines) and lines[j].strip() and not lines[j].startswith(("```", "#")):
                j += 1
            blocks.append(("p", i + 1, j, "\n".join(lines[i:j]))); i = j

    blocks = blocks[next(k for k, b in enumerate(blocks) if b[0] == "h"):]  # drop the doctoc TOC
    pattern = lambda words: r"\s+".join(re.escape(w) for w in words)
    spans, unplaced = {}, []  # block index -> [(start, end, rule)]
    for rule, (line, text) in rules.items():
        b = next((k for k, (_, a, z, _) in enumerate(blocks) if a <= line <= z), None)
        m = b is not None and (re.search(pattern(text.split()), blocks[b][3])
                               or re.search(pattern(text.split()[:10]), blocks[b][3]))
        if not m:
            unplaced.append(rule); continue
        # a sentence RULES.md folded from several spec lines matches by its first
        # ten words; the mark then runs for the sentence's length
        end = m.end() if len(m.group()) >= len(text) - 1 else min(len(blocks[b][3]), m.start() + len(text))
        spans.setdefault(b, []).append((m.start(), end, rule))

    out = []
    for k, (kind, a, z, text) in enumerate(blocks):
        if kind == "pre":
            out.append("<pre>{}</pre>".format(html.escape(text))); continue
        if kind == "h":
            level = len(text) - len(text.lstrip("#"))
            out.append("<h{0}>{1}</h{0}>".format(min(level, 4), html.escape(text.lstrip("# ")))); continue
        parts, pos = [], 0
        for start, end, rule in sorted(spans.get(k, [])):
            if start < pos:
                continue  # overlaps the previous rule's span; the first one keeps it
            parts.append(html.escape(text[pos:start]))
            cases = tagged.get(rule, [])
            soft = rule.rsplit(".", 1)[0] in NOT_MEASURED
            parts.append('<mark class="{}" title="{}">{}</mark>'.format(
                "soft" if cases and soft else "ok" if cases else "gap",
                html.escape(rule + (" — " + ", ".join(cases) if cases else " — no case")
                            + (" — case cannot be measured yet, see COVERAGE.md" if soft else "")),
                html.escape(text[start:end])))
            pos = end
        parts.append(html.escape(text[pos:]))
        out.append('<p data-line="{}">{}</p>'.format(a, "".join(parts)))

    soft = sum(1 for r in rules if tagged.get(r) and r.rsplit(".", 1)[0] in NOT_MEASURED)
    checked = sum(1 for r in rules if tagged.get(r)) - soft
    return SPEC_TEMPLATE.replace("__BODY__", "\n".join(out)) \
        .replace("__CHECKED__", str(checked)).replace("__TOTAL__", str(len(rules))) \
        .replace("__SOFT__", str(soft)) \
        .replace("__GAPS__", str(len(rules) - checked - soft)) \
        .replace("__UNPLACED__", "" if not unplaced else
                 "<p class=note>Not found verbatim in the spec, so not marked: {}</p>".format(
                     ", ".join("<code>{}</code>".format(html.escape(r)) for r in unplaced)))


SPEC_TEMPLATE = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HOCON spec coverage</title>
<style>
:root { --bg: #fff; --fg: #1d2429; --muted: #68737d; --ok: #cdeccd; --gap: #f7c9c9; --soft: #f5e6b3; --code: #f3f5f7; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #14181c; --fg: #d9dee3; --muted: #8a949e; --ok: #22502a; --gap: #6b2626; --soft: #5a4a14; --code: #1e242a; }
}
body { margin: 0 auto; max-width: 48rem; padding: 0 16px 4rem; background: var(--bg); color: var(--fg);
  font: 16px/1.55 system-ui, sans-serif; }
h1, h2, h3, h4 { line-height: 1.25; margin: 2em 0 .5em; }
p { white-space: pre-wrap; margin: 0 0 1em; }
pre { background: var(--code); padding: .6em .8em; overflow-x: auto; font-size: 14px; }
mark { color: inherit; border-radius: 2px; padding: 0 1px; cursor: help; }
mark.ok { background: var(--ok); } mark.gap { background: var(--gap); } mark.soft { background: var(--soft); }
.legend { position: sticky; top: 0; background: var(--bg); padding: .6em 0; border-bottom: 1px solid var(--code);
  color: var(--muted); font-size: 14px; }
.legend mark { padding: 0 .4em; }
.note { color: var(--muted); font-size: 14px; }
</style>
<div class="legend">
  <mark class="ok">__CHECKED__ rules with a case</mark> &nbsp;
  <mark class="gap">__GAPS__ rules without one</mark> &nbsp;
  <mark class="soft">__SOFT__ with a case the protocol cannot measure</mark> &nbsp;
  unmarked text is not a rule — __TOTAL__ rules in RULES.md. Hover a mark for the id and its cases.
</div>
__UNPLACED__
__BODY__
"""


def not_measured(cases, metas):
    """The COVERAGE.md section on the cases the oracle protocol cannot score:
    what they pin, what an implementation's typed accessors must do, how to
    check them by hand today, and what it takes to let the suite do it."""
    rows = [(suite.key_of(c), suite.encode(c.open(newline="").read()), m.get("why", ""))
            for c, m in zip(cases, metas) if suite.key_of(c).split("/")[0] in NOT_MEASURED]
    return (["", "## Not measured: the typed accessors", "",
        "{} cases in {} have a rule, a case and a green score in every column, and the score says "
        "nothing. `tools/oracle/Oracle.java` does `parseString(src).root().render()` and never calls "
        "`getDuration()`, `getPeriod()` or `getBytes()`, so `expect` on these rows is the text surviving "
        "the parse: `t = 10MS` expects `{{\"t\": \"10MS\"}}`, and a parser that has never heard of units "
        "passes. The rules and the inputs are right. The protocol cannot see the answer."
        .format(len(rows), ", ".join("`{}`".format(d) for d in sorted(NOT_MEASURED))), "",
        "This is the line the suite draws, on purpose: it measures the tree a parser produces from a file. "
        "HOCON has no type in the file (`10m` is minutes to a duration and months to a period; `10` is "
        "milliseconds, days or bytes depending on what is asked), so units and conversions are properties of "
        "the accessor the application calls, not of the parse. The spec files them under API Recommendations "
        "for the same reason.", "",
        "### What an implementation's interface should provide", "",
        "A way to ask for a value *as* a type (`getDuration(path)` in typesafe/config, a typed target "
        "such as `struct { t: Duration }` in a language with comptime types), with these rules behind it:", "",
        "- **Units format** (`units-format.*`): optional whitespace, a number, optional whitespace, an optional "
        "unit of letters only, optional whitespace. No unit means the accessor's default unit. An unknown unit is "
        "an error, never a silent default.",
        "- **Duration** (`duration-format.*`): bare number is milliseconds; units are exactly the strings in "
        "RULES.md and lowercase only, so `10MS` is an error. typesafe/config accepts a fractional number and "
        "truncates to whole nanoseconds.",
        "- **Period** (`period-format.*`): bare number is days; `d`, `w`, `m`/`mo`, `y`; the result is "
        "years, months and days, not a count of anything.",
        "- **Size in bytes** (`size-in-bytes-format.*`): bare number is bytes; `B`; powers of ten `kB`…`YB` and "
        "their long forms; powers of two `K`/`Ki`/`KiB`…`Y`/`Yi`/`YiB`; a single letter means a power of two "
        "and may be upper- or lowercase. `1YB` does not fit in 64 bits.",
        "- **Automatic type conversions** (spec, API Recommendations; not in RULES.md yet): number ↔ string "
        "as written in the file; `true`/`yes`/`on` and `false`/`no`/`off` to boolean, nothing else; string "
        "`\"null\"` to null only on request; a numerically-indexed object to an array. Never: null to anything, "
        "object or array to anything, anything to object, anything to array except the indexed object.", "",
        "### How to check an implementation today, by hand", "",
        "Parse the input, ask for each key with the accessor its section names, and compare with the sentence "
        "in the last column. A row that matches passes; a row that silently returns the text fails, whatever "
        "`run.sh` says.", "",
        "| case | input | the accessor must |", "|---|---|---|"]
    + ["| `{}` | `{}` | {} |".format(k, i.replace("|", "\\|"), w.replace("|", "\\|")) for k, i, w in rows]
    + ["", "### What it takes for the suite to measure it", "",
        "One addition to the sidecar and the adapter contract, so a case can say what to ask for:", "",
        "```json", '"as": {"t": "duration"}', "```", "",
        "- `run.sh` hands the adapter `--as t=duration` the way it hands it `env` today.",
        "- The adapter answers with the converted value in place of the text: an integer of nanoseconds for a "
        "duration, an integer of bytes for a size, `{\"years\": y, \"months\": m, \"days\": d}` for a period; "
        "a rejection is a rejection, as now.",
        "- `Oracle.java` fills `expect` from `getDuration(path).toNanos()`, `getBytes(path)` and "
        "`getPeriod(path)`, so expected values still come from the reference implementation, never by hand.",
        "- An adapter that does not know `--as` exits non-zero and the row fails. That is the honest result.", "",
        "The same request with `int`, `boolean` and `string` is what brings Automatic type conversions into "
        "RULES.md. It is one mechanism, not four.", "",
        "This is a change to the protocol every adapter speaks, so it is a decision for the maintainer, "
        "recorded in `PROCESS.md` when made. If you think the line belongs elsewhere, the argument that moves "
        "it is a case the protocol can score, or a protocol change with the oracle filling `expect`; "
        "an argument about where units *ought* to live has been had, and the spec settled it."])


def load_runs():
    """One entry per implementation, carrying its verdicts in both modes."""
    runs = {}
    for f in sorted(REPORTS.glob("*.json")):
        r = json.loads(f.read_text())
        impl = runs.setdefault(r["implementation"], {"version": r["version"], "modes": {}, "outputs": {}})
        version = r.get("java_version", JAVA_RELEASE)
        mode = "java" if r["mode"] == "java" and version == JAVA_RELEASE else \
            "java@" + version if r["mode"] == "java" else r["mode"]
        impl.setdefault("measured", set()).add(mode)
        impl["modes"][mode] = r["cases"]
        impl.setdefault("digests", set()).add(r.get("suite_digest", "none"))
        impl["outputs"].update(r.get("outputs", {}))
    for impl in runs.values():
        impl["modes"].setdefault("java", impl["modes"].get("spec", {}))
        impl["modes"].setdefault("spec", impl["modes"].get("java", {}))
    return runs


def main(argv):
    check = "--check" in argv

    cases, metas, orphans = suite.cases()
    if not cases:
        sys.exit("no cases found")
    runs = load_runs()
    if not runs:
        sys.exit("no results in {} — run conformance/run.sh first".format(REPORTS))
    impls = list(runs)

    # a result file scored against a different set of cases is not a result about
    # this suite; saying so is cheaper than quietly publishing last week's numbers
    now = suite.digest()
    behind = [i for i in impls if runs[i].get("digests", {"none"}) != {now}]
    if behind:
        print("results predate the current cases, re-run conformance/run.sh for:\n  "
              + "\n  ".join(behind))
        if check:
            return 1

    rel = [suite.key_of(c) for c in cases]
    verdict = lambda impl, key, mode: runs[impl]["modes"][mode].get(key, "open")

    sections, split = {}, []
    for case, meta, key in zip(cases, metas, rel):
        row = {"key": key, "name": suite.name_of(case), "why": meta.get("why", ""), "kind": meta.get("java", ""),
               "review": meta.get("review", ""),
               "v": {i: {m: verdict(i, key, m) for m in ("spec", "java")} for i in impls}}
        sections.setdefault(suite.section_of(case), []).append(row)
        if meta.get("java"):
            split.append({
                "input": suite.encode(case.open(newline="").read()) if not suite.is_dir_case(case)
                         else "{}/ (directory)".format(suite.name_of(case)),
                "kind": meta["java"],
                "spec_side": "rejects" if "error" in meta else "`" + json.dumps(meta["expect"]) + "`",
                "got": {i: runs[i]["outputs"].get(key, "—") for i in impls},
            })

    all_rows = [r for rows in sections.values() for r in rows]
    # coverage against RULES.md: a rule with no case is a sentence of the spec
    # this suite does not check, whatever its pass rate says
    rules = suite.rules()
    tagged = {}
    for c, m in zip(cases, metas):
        r = m.get("rule")
        for rule in ([r] if isinstance(r, str) else r or []):
            tagged.setdefault(rule, []).append(suite.key_of(c))
    known = {r for r in tagged if r in rules}
    coverage = "\n".join(
        ["# Rule coverage", "",
         "{} of {} rules in `RULES.md` have at least one case ({:.0f}%).".format(
             len(known), len(rules), 100 * len(known) / len(rules)),
         "", "Generated by `report.py`. A rule listed here is a sentence of the spec the",
         "suite does not check — not a rule an implementation fails. `COVERAGE.html` is the",
         "spec itself with every rule marked: green has a case, red has none.", "", "## Unchecked", ""]
        + ["- `{}` L{} {}".format(r, line, text) for r, (line, text) in rules.items() if r not in known]
        + not_measured(cases, metas)
        + ["", "## Cases pointing at a rule that is not in RULES.md", ""]
        + (["- `{}` → `{}`".format(f, r) for r in tagged if r not in rules for f in tagged[r]] or ["none"])
        + [""])

    # SECTIONS.md keeps its prose by hand; only the state column is derived, so
    # it cannot drift from the disk the way it did before
    import re
    counts = {name: len(rows) for name, rows in sections.items()}
    sec_lines, seen = [], set()
    for line in SECTIONS_MD.read_text().splitlines():
        m = re.match(r"^(\| \d+ \| .*? \| `)([a-z0-9-]+)(` \| ).*\|$", line)
        if m:
            d = m.group(2); seen.add(d)
            n = counts.get(d, 0)
            if d in NOT_MEASURED and n:
                state = "⚠ {} cases, not measured".format(n)
            elif n:
                state = "✅ {} cases".format(n)
            else:
                state = "— no cases yet"
            line = "{}{}{}{} |".format(m.group(1), d, m.group(3), state)
        sec_lines.append(line)
    unlisted = sorted(set(counts) - seen)
    if unlisted:
        print("directories with no row in SECTIONS.md (add one by hand):\n  " + "\n  ".join(unlisted))
    sections_md = "\n".join(sec_lines) + "\n"

    # the README carries the totals only; the cases are on the page it links to
    def score(impl, mode):
        if mode not in runs[impl]["measured"]:
            return "—"
        verdicts = runs[impl]["modes"][mode]
        p = sum(verdicts.get(r["key"]) == "pass" for r in all_rows)
        return "{:.0f}% ({}/{})".format(100 * p / len(all_rows), p, len(all_rows))
    java_modes = ["java"] + sorted({m for i in impls for m in runs[i]["measured"] if m.startswith("java@")})
    summary = "\n".join(
        [START, "<!-- generated by conformance/maintaining/report.py — do not edit by hand -->", "",
         "| implementation | against the spec | "
         + " | ".join("against typesafe/config " + (JAVA_RELEASE if m == "java" else m[len("java@"):])
                      for m in java_modes) + " |",
         "|---|---|" + "---|" * len(java_modes)]
        + ["| {} <sub>{}</sub> | {} | {} |".format(i, runs[i]["version"], score(i, "spec"),
                                                  " | ".join(score(i, m) for m in java_modes))
           for i in impls]
        + ["", END])
    text = README.read_text()
    if START not in text or END not in text:
        sys.exit("README.md has no {} … {} block to fill".format(START, END))
    readme = text[:text.index(START)] + summary + text[text.index(END) + len(END):]

    html_sections = [{"name": n, "rows": sections[n]} for n in sorted(sections)]
    lede = ("Every row is one sentence of the HOCON specification, turned into a config file and an "
            "expected value. Score against the specification and you get conformance; score against "
            "typesafe/config and you get compatibility with the implementation the JVM world runs.")
    html = page.build(impls, html_sections, split, lede,
                      {i: runs[i]["version"] for i in impls}, now)

    spec_page = spec_coverage(rules, tagged)
    stale = [str(p.relative_to(ROOT)) for p, content in
             ((README, readme), (PAGE, html), (COVERAGE, coverage), (SECTIONS_MD, sections_md),
              (SPEC_PAGE, spec_page))
             if not p.exists() or p.read_text() != content]
    if orphans:
        print("no sidecar, skipped:\n  " + "\n  ".join(str(o.relative_to(ROOT)) for o in orphans))
    if check:
        if stale:
            print("out of date:\n  " + "\n  ".join(stale))
            return 1
        print("up to date")
        return 0
    README.write_text(readme)
    PAGE.write_text(html)
    COVERAGE.write_text(coverage)
    SECTIONS_MD.write_text(sections_md)
    SPEC_PAGE.write_text(spec_page)
    print("{} cases, {} sections, {} implementations".format(len(all_rows), len(sections), len(impls)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
