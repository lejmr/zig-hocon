export const meta = {
  name: 'hocon-conformance-cover',
  description: 'One agent per HOCON spec section: write conformance cases (inputs + rationale, no expected values)',
  phases: [{ title: 'Cover', detail: 'one agent per spec section writes .conf inputs and sidecars without expect' }],
}

const ROOT = '/Users/milos/src/tries/2026-07-23-zig-hocon-conformance'

const SECTIONS = [
  { slug: 'syntax-basics', lines: '110-140', title: 'Unchanged from JSON, Comments, Omit root braces', dirs: 'unchanged-from-json, comments, omit-root-braces' },
  { slug: 'separators', lines: '141-164', title: 'Key-value separator, Commas', dirs: 'key-value-separator, commas' },
  { slug: 'whitespace-and-duplicates', lines: '165-239', title: 'Whitespace, Duplicate keys and object merging', dirs: 'whitespace, duplicate-keys-and-object-merging (already has 3 cases — read them, do not duplicate, extend)' },
  { slug: 'unquoted-strings', lines: '240-287', title: 'Unquoted strings', dirs: 'unquoted-strings' },
  { slug: 'multi-line-strings', lines: '288-303', title: 'Multi-line strings', dirs: 'multi-line-strings' },
  { slug: 'string-concatenation', lines: '304-381', title: 'Value concatenation, String value concatenation', dirs: 'value-concatenation, string-value-concatenation' },
  { slug: 'array-object-concatenation', lines: '382-471', title: 'Array and object concatenation, and the two notes that follow', dirs: 'array-and-object-concatenation, concatenation-whitespace-and-substitutions, arrays-without-commas-or-newlines' },
  { slug: 'path-expressions', lines: '472-520', title: 'Path expressions', dirs: 'path-expressions' },
  { slug: 'paths-as-keys', lines: '521-573', title: 'Paths as keys', dirs: 'paths-as-keys' },
  { slug: 'substitutions', lines: '574-652', title: 'Substitutions', dirs: 'substitutions' },
  { slug: 'self-referential', lines: '653-892', title: 'Self-referential substitutions, the += field separator, and the worked examples', dirs: 'self-referential-substitutions, plus-equals-field-separator, self-referential-examples' },
  { slug: 'numeric-index-arrays', lines: '1184-1220', title: 'Conversion of numerically-indexed objects to arrays', dirs: 'numerically-indexed-objects-to-arrays' },
  { slug: 'type-conversions', lines: '1230-1263', title: 'Automatic type conversions', dirs: 'automatic-type-conversions' },
  { slug: 'units', lines: '1264-1398', title: 'Units format, Duration format, Period format, Size in bytes format', dirs: 'units-format, duration-format, period-format, size-in-bytes-format' },
]

const SCHEMA = {
  type: 'object',
  properties: {
    cases: { type: 'array', items: { type: 'string' }, description: 'relative paths of every .conf file written' },
    uncovered: { type: 'array', items: { type: 'string' }, description: 'normative sentences in this range that no single-file case can pin down, and why' },
    notes: { type: 'string', description: 'anything the next stage must know' },
  },
  required: ['cases', 'uncovered', 'notes'],
}

const prompt = (s) => `You are writing conformance test INPUTS for the HOCON specification. Work only inside ${ROOT}.

First read, in this order:
- ${ROOT}/conformance/README.md  (the file format — obey it exactly)
- ${ROOT}/conformance/PROCESS.md (your stage is stage 2, "Cover")
- ${ROOT}/conformance/duplicate-keys-and-object-merging/002-objects-merge.conf and its .json sidecar (the shape of one finished case)
- ${ROOT}/spec/HOCON.md, LINES ${s.lines} ONLY. That range is your entire mandate. Do not write cases for behaviour described elsewhere in the spec.

Your section: ${s.title}
Create cases under these directories (create them if missing): ${s.dirs}

Write, for every normative statement in your line range, at least one case:
- \`<nnn>-<kebab-name>.conf\` — the input, verbatim HOCON, numbered from 001 within its directory.
- \`<nnn>-<kebab-name>.json\` — the sidecar, with ONLY these fields:
  {"spec": "HOCON.md#<anchor of the heading this case comes from>",
   "why": "one sentence naming the rule, close to the spec's own wording"}

CRITICAL RULES:
- Do NOT write an "expect" field. Do NOT write an "error" field. Do NOT guess what the input produces. A later stage fills those in from the reference implementation. A sidecar you write has exactly two keys.
- Do NOT run any parser, oracle, or build. Do not run \`tools/oracle/*\`. Do not run zig.
- Do NOT touch README.md, PROCESS.md, SECTIONS.md, spec/, src/, or another section's directory.
- Every case must be ONE self-contained file with no \`include\` and no dependency on environment variables. If a statement in your range can only be tested with extra files or env vars, skip it and list it in \`uncovered\`.
- Keep each input minimal: the smallest config that isolates the one rule. Multi-rule inputs make failures unreadable.
- Cover the negative side too: inputs the spec says are illegal deserve a case just as much as legal ones. Say so in \`why\`.
- Where the spec gives a worked example, turn it into a case — those are the sentences with the least room for interpretation.
- \`why\` is what a human reviewer reads to decide whether the reference implementation is right. Make it specific: "a trailing comma is permitted after the last element", not "tests commas".

Aim for thorough coverage of your range, not a round number of cases. Return the list of .conf paths you wrote.`

phase('Cover')
const results = await parallel(SECTIONS.map(s => () =>
  agent(prompt(s), { label: `cover:${s.slug}`, phase: 'Cover', model: 'sonnet', schema: SCHEMA })
))

const ok = results.filter(Boolean)
log(`${ok.length}/${SECTIONS.length} sections returned; ${ok.reduce((n, r) => n + r.cases.length, 0)} cases written`)

return SECTIONS.map((s, i) => ({ section: s.slug, result: results[i] }))
