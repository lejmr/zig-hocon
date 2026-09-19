"""The HTML face of the conformance suite. Fed by report.py, which owns the scoring."""

import html as esc
import json

PAGE = """<title>HOCON Conformance</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap">
<style>
:root {
  --ground: #f6f7f8; --panel: #ffffff; --ink: #14181c; --muted: #5c666f;
  --rule: #dde2e6; --rule-soft: #eceff1; --accent: #2f5d9e;
  --pass: #1c6b4c; --pass-bg: #e4f0ea; --fail: #a6342f; --fail-bg: #f7e5e3;
  --open: #8a6212; --open-bg: #f6ecd8; --other: #6b4a93; --other-bg: #eee7f5;
  --shadow: 0 1px 2px rgba(20,24,28,.06), 0 8px 24px rgba(20,24,28,.05);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ground: #101418; --panel: #171c21; --ink: #e6eaed; --muted: #949ea7;
    --rule: #2a323a; --rule-soft: #212831; --accent: #7aa7e0;
    --pass: #6cc49c; --pass-bg: #163026; --fail: #e08a84; --fail-bg: #351c1b;
    --open: #d9ad5c; --open-bg: #332813; --other: #b9a0dd; --other-bg: #271f33;
    --shadow: 0 1px 2px rgba(0,0,0,.4), 0 8px 24px rgba(0,0,0,.3);
  }
}
:root[data-theme="dark"] {
  --ground: #101418; --panel: #171c21; --ink: #e6eaed; --muted: #949ea7;
  --rule: #2a323a; --rule-soft: #212831; --accent: #7aa7e0;
  --pass: #6cc49c; --pass-bg: #163026; --fail: #e08a84; --fail-bg: #351c1b;
  --open: #d9ad5c; --open-bg: #332813; --other: #b9a0dd; --other-bg: #271f33;
  --shadow: 0 1px 2px rgba(0,0,0,.4), 0 8px 24px rgba(0,0,0,.3);
}
* { box-sizing: border-box; }
body {
  background: var(--ground); color: var(--ink); margin: 0;
  font: 400 15px/1.55 "IBM Plex Sans", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
}
.wrap { max-width: 1180px; margin: 0 auto; padding: 32px 24px 96px; display: flex; flex-direction: column; gap: 28px; }
h1 { font-size: 28px; font-weight: 600; margin: 0; letter-spacing: -.015em; text-wrap: balance; }
.lede { color: var(--muted); max-width: 66ch; margin: 6px 0 0; }
code, .mono { font-family: "JetBrains Mono", ui-monospace, monospace; font-size: .88em; }
.num { font-variant-numeric: tabular-nums; }

.modes { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.modes .label { font-size: 12px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin-right: 4px; }
button.mode {
  font: 500 14px/1 "IBM Plex Sans", sans-serif; color: var(--ink);
  background: var(--panel); border: 1px solid var(--rule); border-radius: 6px;
  padding: 9px 14px; cursor: pointer;
}
button.mode[aria-pressed="true"] { border-color: var(--accent); color: var(--accent); box-shadow: inset 0 0 0 1px var(--accent); }
button.mode:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

.scores { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; }
.score { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px; padding: 16px 18px; box-shadow: var(--shadow); }
.score .impl { font-size: 12px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
.score .pct { font: 500 32px/1.1 "JetBrains Mono", monospace; font-variant-numeric: tabular-nums; margin-top: 6px; }
.score .of { color: var(--muted); font-size: 13px; }
.bar { height: 4px; background: var(--rule-soft); border-radius: 2px; margin-top: 12px; overflow: hidden; }
.bar > i { display: block; height: 100%; background: var(--accent); }

table { width: 100%; border-collapse: collapse; font-size: 14px; }
.scroll { overflow-x: auto; }
th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid var(--rule-soft); vertical-align: top; }
th { font-size: 12px; letter-spacing: .06em; text-transform: uppercase; color: var(--muted); font-weight: 500; white-space: nowrap; }
td.v { text-align: center; width: 78px; }
tr:last-child td { border-bottom: none; }
.why { color: var(--muted); font-size: 13px; min-width: 22ch; }

.tag { display: inline-block; padding: 1px 7px; border-radius: 999px; font: 500 12px/1.6 "IBM Plex Sans", sans-serif; }
.pass { color: var(--pass); background: var(--pass-bg); }
.fail { color: var(--fail); background: var(--fail-bg); }
.review { color: var(--open); background: var(--open-bg); }
.kind { color: var(--other); background: var(--other-bg); margin-left: 6px; }

details { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px; box-shadow: var(--shadow); }
details + details { margin-top: 10px; }
summary { cursor: pointer; padding: 13px 18px; display: flex; gap: 14px; align-items: baseline; flex-wrap: wrap; }
summary::-webkit-details-marker { display: none; }
summary::before { content: "▸"; color: var(--muted); }
details[open] summary::before { content: "▾"; }
summary:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
summary .name { font-weight: 600; }
summary .tally { color: var(--muted); font-size: 13px; margin-left: auto; }
details .scroll { padding: 0 8px 10px; }

.split { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px; box-shadow: var(--shadow); padding: 4px 8px 8px; }
h2 { font-size: 17px; font-weight: 600; margin: 0 0 2px; }
.section-head { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; }
.note { color: var(--muted); font-size: 13px; max-width: 78ch; }
footer { color: var(--muted); font-size: 13px; border-top: 1px solid var(--rule); padding-top: 16px; }
@media (prefers-reduced-motion: reduce) { * { animation: none !important; transition: none !important; } }
</style>

<div class="wrap">
  <header>
    <h1>HOCON Conformance</h1>
    <p class="lede">__LEDE__</p>
  </header>

  <div class="modes">
    <span class="label">Scoring against</span>
    <button class="mode" data-mode="spec" aria-pressed="true">the specification</button>
    <button class="mode" data-mode="java" aria-pressed="false">typesafe/config</button>
  </div>

  <div class="scores" id="scores"></div>

  <section class="split">
    <div class="section-head" style="padding:12px 10px 2px">
      <h2>Where the two bars disagree</h2>
      <span class="note">__SPLITCOUNT__ of __TOTAL__ rows. Everywhere else they ask the same question.</span>
    </div>
    <div class="scroll">__SPLIT__</div>
  </section>

  <section>
    <div class="section-head" style="margin-bottom:12px">
      <h2>By section of the specification</h2>
      <span class="note">One fold per heading of <code>HOCON.md</code>.</span>
    </div>
    __SECTIONS__
  </section>

  <footer>
    Generated by <code>tools/conformance/report.py</code> from __TOTAL__ cases under <code>conformance/</code>.
    Expected values are seeded from <code>tools/oracle/hocon-java</code> and owned by the validation stage —
    see <code>conformance/PROCESS.md</code>.
  </footer>
</div>

<script>
const DATA = __DATA__;
let mode = "spec";

function cell(v) {
  if (v === "review") return '<span class="tag review">open</span>';
  return v === "pass" ? '<span class="tag pass">pass</span>' : '<span class="tag fail">fail</span>';
}
function score(rows, impl) {
  let ok = 0;
  for (const r of rows) if (r.v[impl][mode] === "pass") ok++;
  return [ok, rows.length];
}
function render() {
  const all = DATA.sections.flatMap(s => s.rows);
  document.getElementById("scores").innerHTML = DATA.impls.map(impl => {
    const [ok, n] = score(all, impl);
    const pct = n ? Math.round(100 * ok / n) : 0;
    return `<div class="score"><div class="impl">${impl}</div>
      <div class="pct num">${pct}%</div>
      <div class="of num">${ok} of ${n} rows</div>
      <div class="bar"><i style="width:${pct}%"></i></div></div>`;
  }).join("");
  for (const td of document.querySelectorAll("td.v")) td.innerHTML = cell(JSON.parse(td.dataset.v)[mode]);
  for (const el of document.querySelectorAll("[data-tally]")) {
    const rows = DATA.sections[+el.dataset.tally].rows;
    el.textContent = DATA.impls.map(i => { const [ok, n] = score(rows, i); return `${i} ${ok}/${n}`; }).join(" · ");
  }
}
for (const b of document.querySelectorAll("button.mode")) {
  b.addEventListener("click", () => {
    mode = b.dataset.mode;
    for (const o of document.querySelectorAll("button.mode")) o.setAttribute("aria-pressed", String(o === b));
    render();
  });
}
render();
</script>
"""


def _cells(row, impls):
    return "".join('<td class="v" data-v=\'{}\'></td>'.format(json.dumps(row["v"][i])) for i in impls)


def build(impls, sections, split_rows, lede):
    head = "".join("<th>{}</th>".format(esc.escape(i)) for i in impls)

    split = ['<table><thead><tr><th>input</th><th>the spec</th><th>typesafe/config</th>{}</tr></thead><tbody>'.format(head)]
    for r in split_rows:
        split.append("<tr><td class=\"mono\">{}</td><td class=\"mono\">{}</td><td class=\"mono\">{}</td>{}</tr>".format(
            esc.escape(r["input"]), esc.escape(r["spec_side"]), esc.escape(r["java_side"]), _cells(r, impls)))
    split.append("</tbody></table>")

    out = []
    for n, sec in enumerate(sections):
        rows = ['<table><thead><tr><th>case</th>{}<th>rule</th></tr></thead><tbody>'.format(head)]
        for r in sec["rows"]:
            kind = '<span class="tag kind">java: {}</span>'.format(r["kind"]) if r["kind"] else ""
            rows.append('<tr><td class="mono">{}</td>{}<td class="why">{}{}</td></tr>'.format(
                esc.escape(r["name"]), _cells(r, impls), esc.escape(r["why"]), kind))
        rows.append("</tbody></table>")
        out.append('<details><summary><span class="name">{}</span>'
                   '<span class="note num">{} cases</span>'
                   '<span class="tally num" data-tally="{}"></span></summary>'
                   '<div class="scroll">{}</div></details>'.format(
                       esc.escape(sec["name"]), len(sec["rows"]), n, "".join(rows)))

    total = sum(len(s["rows"]) for s in sections)
    return (PAGE.replace("__DATA__", json.dumps({"impls": impls, "sections": sections}))
                .replace("__SECTIONS__", "".join(out))
                .replace("__SPLIT__", "".join(split))
                .replace("__SPLITCOUNT__", str(len(split_rows)))
                .replace("__TOTAL__", str(total))
                .replace("__LEDE__", esc.escape(lede)))
