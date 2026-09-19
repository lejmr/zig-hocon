export const meta = {
  name: 'hocon-conformance-validate',
  description: 'Stage 5: judge every filled conformance case against the spec text, mark where the reference implementation and HOCON part ways',
  phases: [{ title: 'Validate', detail: 'one agent per spec section audits expect values against the spec' }],
}

const ROOT = '/Users/milos/src/tries/2026-07-23-zig-hocon-conformance'

const GROUPS = [
  { slug: 'syntax-basics', lines: '110-140', dirs: ['unchanged-from-json', 'comments', 'omit-root-braces'] },
  { slug: 'separators', lines: '141-164', dirs: ['key-value-separator', 'commas'] },
  { slug: 'whitespace-and-duplicates', lines: '165-239', dirs: ['whitespace', 'duplicate-keys-and-object-merging'] },
  { slug: 'unquoted-strings', lines: '240-287', dirs: ['unquoted-strings'] },
  { slug: 'multi-line-strings', lines: '288-303', dirs: ['multi-line-strings'] },
  { slug: 'string-concatenation', lines: '304-381', dirs: ['value-concatenation', 'string-value-concatenation'] },
  { slug: 'array-object-concatenation', lines: '382-471', dirs: ['array-and-object-concatenation', 'concatenation-whitespace-and-substitutions', 'arrays-without-commas-or-newlines'] },
  { slug: 'path-expressions', lines: '472-520', dirs: ['path-expressions'] },
  { slug: 'paths-as-keys', lines: '521-573', dirs: ['paths-as-keys'] },
  { slug: 'substitutions', lines: '574-652', dirs: ['substitutions'] },
  { slug: 'self-referential', lines: '653-892', dirs: ['self-referential-substitutions', 'plus-equals-field-separator', 'self-referential-examples'] },
  { slug: 'numeric-index-arrays', lines: '1184-1220', dirs: ['numerically-indexed-objects-to-arrays'] },
  { slug: 'type-conversions', lines: '1230-1263', dirs: ['automatic-type-conversions'] },
  { slug: 'units', lines: '1264-1398', dirs: ['units-format', 'duration-format', 'period-format', 'size-in-bytes-format'] },
]

const SCHEMA = {
  type: 'object',
  properties: {
    divergences: {
      type: 'array',
      description: 'cases where the reference implementation does not do what the spec says',
      items: {
        type: 'object',
        properties: {
          case: { type: 'string' },
          kind: { type: 'string', enum: ['unsupported', 'diverges'] },
          spec_says: { type: 'string' },
          java_does: { type: 'string' },
          changed_expect: { type: 'boolean' },
        },
        required: ['case', 'kind', 'spec_says', 'java_does', 'changed_expect'],
      },
    },
    wrong_cases: { type: 'array', items: { type: 'string' }, description: 'cases whose input or why is wrong about the spec, with what is wrong' },
    gaps: { type: 'array', items: { type: 'string' }, description: 'normative sentences in this range with no case at all' },
    verdict: { type: 'string', description: 'two sentences: does this section faithfully map to the spec' },
  },
  required: ['divergences', 'wrong_cases', 'gaps', 'verdict'],
}

const prompt = (g) => `You are auditing a finished slice of a HOCON conformance suite. Work only inside ${ROOT}.

Read first:
- ${ROOT}/conformance/PROCESS.md — you are stage 5, and its section "The point of stage 5" is your mandate.
- ${ROOT}/conformance/README.md — the sidecar format.
- ${ROOT}/spec/HOCON.md, LINES ${g.lines}. That range is the authority. Nothing else decides.

Your directories: ${g.dirs.map(d => 'conformance/' + d).join(', ')}
Read every .conf and its .json sidecar in them. The \`expect\` (or \`error\`) in each sidecar was produced by \`tools/oracle/hocon-java\` — Lightbend's typesafe/config. It is what the reference implementation DOES, which is not automatically what the spec SAYS.

For each case, decide: does the recorded value follow from the spec sentence quoted in \`why\`?

Three outcomes, and only the third touches a file:
1. They agree — leave the sidecar alone.
2. The case itself is wrong: the input does not isolate the rule, or \`why\` misreads the spec. Do not fix it. Report it in \`wrong_cases\` with what is wrong.
3. The spec and the reference implementation genuinely part ways. Then edit the sidecar:
   - add \`"java": "diverges"\` when both parse the input but produce different results, or \`"java": "unsupported"\` when the spec describes behaviour typesafe/config simply does not have (it errors, or ignores it).
   - extend \`why\` so it states the spec's rule AND what java does instead, in one or two sentences.
   - change \`expect\`/\`error\` to what the SPEC requires ONLY when the spec is unambiguous about the exact value. If the spec states a rule but not a precise output, keep the oracle's value and say so in \`why\`.

Be conservative. A divergence you cannot quote a spec sentence for is not a divergence — typesafe/config is the implementation HOCON was written against, so it is right far more often than not, and a false divergence poisons the suite. Do not invent cases, do not add or delete files, do not touch README.md / PROCESS.md / SECTIONS.md / spec/ / src/ / tools/ or a directory that is not yours.

Also list, in \`gaps\`, any normative sentence in your line range that no case covers.

Do NOT run oracles, parsers or builds. You are reading and judging, not measuring.`

phase('Validate')
const results = await parallel(GROUPS.map(g => () =>
  agent(prompt(g), { label: `validate:${g.slug}`, phase: 'Validate', model: 'opus', effort: 'max', schema: SCHEMA })
))

const ok = results.filter(Boolean)
log(`${ok.length}/${GROUPS.length} sections audited; ${ok.reduce((n, r) => n + r.divergences.length, 0)} divergences, ${ok.reduce((n, r) => n + r.gaps.length, 0)} gaps`)

return GROUPS.map((g, i) => ({ section: g.slug, result: results[i] }))
