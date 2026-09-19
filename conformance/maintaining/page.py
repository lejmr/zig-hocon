"""The HTML face of the conformance suite. Fed by report.py, which owns the scoring."""

import html as esc
import json

PAGE = """<meta charset="utf-8">
<title>HOCON Conformance</title>
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
/* the caret is drawn, not typed — a glyph here depends on whatever font the
   viewer actually has, and IBM Plex Sans has no triangles */
summary::before {
  content: ""; flex: none; align-self: center;
  width: 0; height: 0; color: var(--muted);
  border-left: 5px solid currentColor;
  border-top: 4px solid transparent;
  border-bottom: 4px solid transparent;
  transition: transform .12s ease;
}
details[open] summary::before { transform: rotate(90deg); }
summary:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; }
summary .name { font-weight: 600; }
summary .tally { color: var(--muted); font-size: 13px; margin-left: auto; }
details .scroll { padding: 0 8px 10px; }

.split { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px; box-shadow: var(--shadow); padding: 4px 8px 8px; }
h2 { font-size: 17px; font-weight: 600; margin: 0 0 2px; }
.section-head { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; }
.note { color: var(--muted); font-size: 13px; max-width: 78ch; }
footer { color: var(--muted); font-size: 13px; border-top: 1px solid var(--rule); padding-top: 16px; }
.drop {
  border: 1px dashed var(--rule); border-radius: 10px; padding: 14px 18px;
  background: var(--panel); display: flex; flex-direction: column; gap: 4px;
}
.drop.over { border-color: var(--accent); border-style: solid; }
.drop .note { margin: 0; }
.drop input[type=file] { font: inherit; font-size: 13px; max-width: 100%; }
.score.local { border-style: dashed; }
.score .local-tag { font-size: 11px; letter-spacing: .06em; text-transform: uppercase; color: var(--accent); }
#dropmsg.bad { color: var(--fail); }
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

  <section class="drop" id="drop">
    <label for="pick"><b>Add your own result</b></label>
    <p class="note">Run <code>conformance/run.sh -- ./your-adapter.sh &gt; result.json</code> and drop the
    file here, or <input type="file" id="pick" accept="application/json,.json"> pick it. It is read in
    your browser and shown beside the others; nothing is uploaded, and reloading the page forgets it.</p>
    <p class="note" id="dropmsg" hidden></p>
  </section>

  <section id="yours" hidden></section>

  <section class="split">
    <div class="section-head" style="padding:12px 10px 2px">
      <h2>Where the two bars disagree</h2>
      <span class="note">__SPLITCOUNT__ of __TOTAL__ rows. Everywhere else they ask the same question.</span>
    </div>
    <div class="scroll">__SPLIT__</div>
    <p class="note" style="padding:0 10px 10px">Each column is what that implementation actually returns. The spec column is the bar being scored; Java's is, by definition, the other one.</p>
  </section>

  <section>
    <div class="section-head" style="margin-bottom:12px">
      <h2>By section of the specification</h2>
      <span class="note">One fold per heading of <code>HOCON.md</code>.</span>
    </div>
    __SECTIONS__
  </section>

  <footer>
    Generated by <code>conformance/maintaining/report.py</code> from the committed results in <code>conformance/reports/</code>, over __TOTAL__ cases.
    Expected values are seeded from <code>tools/oracle/hocon-java</code> and owned by the validation stage —
    see <code>conformance/maintaining/PROCESS.md</code>.
  </footer>
</div>

<script>
const DATA = __DATA__;
let mode = "spec";
const LOCAL = {};   // results dropped in by the viewer, this tab only

function cell(v) {
  if (v === "review") return '<span class="tag review">open</span>';
  return v === "pass" ? '<span class="tag pass">pass</span>' : '<span class="tag fail">fail</span>';
}
function verdictOf(row, impl) {
  if (LOCAL[impl]) return LOCAL[impl].cases[row.key] || "open";
  return row.v[impl][mode];
}
function score(rows, impl) {
  let ok = 0;
  for (const r of rows) if (verdictOf(r, impl) === "pass") ok++;
  return [ok, rows.length];
}
function columns() { return DATA.impls.concat(Object.keys(LOCAL)); }
function render() {
  const all = DATA.sections.flatMap(s => s.rows);
  document.getElementById("scores").innerHTML = columns().map(impl => {
    const [ok, n] = score(all, impl);
    const pct = n ? Math.round(100 * ok / n) : 0;
    const local = LOCAL[impl];
    return `<div class="score${local ? " local" : ""}"><div class="impl">${impl}</div>
      <div class="pct num">${pct}%</div>
      <div class="of num">${ok} of ${n} rows</div>
      <div class="of num">${local ? local.version : DATA.versions[impl]}</div>
      ${local ? '<div class="local-tag">yours · not published</div>' : ""}
      <div class="bar"><i style="width:${pct}%"></i></div></div>`;
  }).join("");
  for (const td of document.querySelectorAll("td.v")) td.innerHTML = cell(JSON.parse(td.dataset.v)[mode]);
  renderYours();
  for (const el of document.querySelectorAll("[data-tally]")) {
    const rows = DATA.sections[+el.dataset.tally].rows;
    el.textContent = columns().map(i => { const [ok, n] = score(rows, i); return `${i} ${ok}/${n}`; }).join(" · ");
  }
}
function renderYours() {
  const box = document.getElementById("yours");
  const names = Object.keys(LOCAL);
  box.hidden = names.length === 0;
  if (box.hidden) return;
  const rows = DATA.sections.flatMap(s => s.rows.map(r => [s.name, r]));
  box.innerHTML = names.map(impl => {
    const bad = rows.filter(([, r]) => verdictOf(r, impl) === "fail");
    const head = `<div class="section-head" style="padding:12px 10px 2px"><h2>${impl} — what fails</h2>` +
      `<span class="note">${bad.length} of ${rows.length} rows. Read left to right: the rule you broke.</span></div>`;
    if (!bad.length) return `<section class="split">${head}<p class="note" style="padding:0 10px 12px">` +
      `Nothing fails. Check <code>COVERAGE.md</code> for the rules this suite never asks about.</p></section>`;
    const body = bad.map(([sec, r]) =>
      `<tr><td class="mono">${sec}/${r.name}</td><td class="why">${r.why}` +
      (r.kind ? `<span class="tag kind">java: ${r.kind}</span>` : "") + `</td></tr>`).join("");
    return `<section class="split">${head}<div class="scroll"><table><thead><tr>` +
      `<th>case</th><th>rule</th></tr></thead><tbody>${body}</tbody></table></div></section>`;
  }).join("");
}

function adopt(text, name) {
  const msg = document.getElementById("dropmsg");
  const say = (t, bad) => { msg.hidden = false; msg.textContent = t; msg.classList.toggle("bad", !!bad); };
  let r;
  try { r = JSON.parse(text); } catch (e) { return say(`${name} is not JSON: ${e.message}`, true); }
  if (r.suite !== "hocon-conformance" || !r.cases)
    return say(`${name} is not a conformance result — expected the JSON that conformance/run.sh prints.`, true);
  if (r.suite_digest && r.suite_digest !== DATA.digest)
    say(`Scored against a different set of cases (${r.suite_digest}, this page has ${DATA.digest}). ` +
        `Showing it anyway — re-run conformance/run.sh for numbers that line up.`, true);
  else
    say(`${r.implementation || name}: ${r.passed}/${r.total} in ${r.mode} mode.`);
  const label = (r.implementation || name) + " (yours)";
  LOCAL[label] = { cases: r.cases, version: r.version || "unknown", mode: r.mode };
  render();
}

const drop = document.getElementById("drop");
drop.addEventListener("dragover", e => { e.preventDefault(); drop.classList.add("over"); });
drop.addEventListener("dragleave", () => drop.classList.remove("over"));
drop.addEventListener("drop", e => {
  e.preventDefault(); drop.classList.remove("over");
  for (const f of e.dataTransfer.files) f.text().then(t => adopt(t, f.name));
});
document.getElementById("pick").addEventListener("change", e => {
  for (const f of e.target.files) f.text().then(t => adopt(t, f.name));
});

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


def build(impls, sections, split_rows, lede, versions, digest):
    head = "".join("<th>{}</th>".format(esc.escape(i)) for i in impls)

    split = ['<table><thead><tr><th>input</th><th>the spec requires</th>{}</tr></thead>'
             '<tbody>'.format(head)]
    for r in split_rows:
        got = "".join('<td class="mono">{}</td>'.format(esc.escape(r["got"][i])) for i in impls)
        split.append('<tr><td class="mono">{}<span class="tag kind">{}</span></td>'
                     '<td class="mono">{}</td>{}</tr>'.format(
                         esc.escape(r["input"]), esc.escape(r["kind"]),
                         esc.escape(r["spec_side"]), got))
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
    return (PAGE.replace("__DATA__", json.dumps({"impls": impls, "sections": sections, "versions": versions, "digest": digest}))
                .replace("__SECTIONS__", "".join(out))
                .replace("__SPLIT__", "".join(split))
                .replace("__SPLITCOUNT__", str(len(split_rows)))
                .replace("__TOTAL__", str(total))
                .replace("__LEDE__", esc.escape(lede)))
