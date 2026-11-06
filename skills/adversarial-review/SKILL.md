---
name: adversarial-review
description: >
  Completion gate for any programming work (not project-specific): after a
  change is implemented and tested — ideally after an inline review too —
  launches a multi-agent Workflow that finds candidate bugs from several
  independent lenses, then adversarially tries to REFUTE each one before it
  counts. Confirms real findings, discards ones nobody could actually
  construct a failure for. Use before considering a change genuinely done,
  not as a substitute for testing or an inline review — it's a second,
  differently-shaped check on top of both.
  Usage: /adversarial-review [target] — target is optional: defaults to the
  change just discussed/implemented in this conversation; can also be a diff
  scope (uncommitted, a PR#, a branch) or a freeform description of what to
  verify (e.g. a list of already-suspected findings to adjudicate).
disable-model-invocation: false
---

## Input

$ARGUMENTS — optional. Empty means: adversarially review whatever change this
conversation just implemented. Otherwise: a diff scope (PR number, branch
name, "uncommitted") or a freeform description of specific claims/findings to
adjudicate.

## Why this exists

An inline review (by you, in this same context) shares your own blind spots —
if you didn't consider a failure mode while writing the code, you're unlikely
to spot it while reviewing it five minutes later in the same context. Independent
agents with no stake in the code being correct, given only the relevant files
and a clear instruction to look for problems, catch a different distribution
of bugs. Adversarial verification on top of THAT catches the other failure
mode: a finder agent inventing a plausible-sounding but wrong claim, which an
unverified finding list would otherwise pass through as fact.

This is a **standing, pre-authorized use of the Workflow tool** for this user
— do not re-ask permission to invoke Workflow when running this skill. (If a
future session runs this for a different user/account, confirm first — the
opt-in is this user's, not a property of the skill itself.)

## Step 1 — Determine scope and gather grounding context yourself

Before writing a single agent prompt, read the actual diff/files yourself —
agents work from what you hand them, not from independently rediscovering
context you already have:

- If `$ARGUMENTS` is empty: identify the files/diff from the conversation's
  own recent work (`git diff HEAD`, or the specific files just edited).
- If given a PR#/branch: `gh pr diff <N>` or `git diff <merge-base>...HEAD`.
- If given a freeform description: read whatever files/claims it points to.

While reading, collect what agents will need and can't efficiently discover
themselves: absolute file paths, the specific functions/lines in scope, any
established convention or sibling pattern this change claims to follow (find
and name the sibling), and any spec/RFC/API-contract text the change is
supposed to satisfy (quote the actual normative text, don't paraphrase from
memory — verify it if unsure). Bad grounding produces agents that either
hallucinate a spec requirement or miss a real one because they had to guess
at context you already had for free.

**Search-anchoring pitfall — grep the raw pattern, not calls to the fix's own
remediation function.** A "wrong call" bug (existing call, bad argument) shows
up in a grep for the function name. A "missing call" bug (the fix's escaping/
validation/cleanup function was never invoked at this site at all) does not —
there's nothing to grep for at the buggy site itself. If the change's shape is
"thread a new field/check through every consumer of an existing field or
pattern" (a provenance field, a permission check, a resource-cleanup call),
tell finders to grep the RAW field/pattern access across the whole tree (e.g.
`attr\.(arg|name)\b`, not `smart_quote\(`) and triage every hit for whether it
reaches the risk (a sink, an unchecked branch, a leak) — not just re-verify
the call sites the fix's own description already names. A real case: a fix
added `opaque_pos` provenance and wired 8 named call sites; three more sites
existed that never called the escaping function at all, so a grep for the
escaping function's name never surfaced them — only a grep for the raw field
read would have.

**Grounding is a hypothesis, not a premise.** Every classifying sentence in
`CONTEXT` — "the template is AT&T", "an operand identifier is a typed
variable", "this field is always set by the caller" — is a claim the finders
must be told to test, so write it as one ("the change assumes X; find an input
the old code accepted for which X is false"). On vlang/v#31407 three rounds
inherited exactly those two sentences as facts from CONTEXT, and both were the
bugs the maintainer then found (vreview Angle K).

**Point finders at the source of a list, never at a closed list.** A vocabulary written
into `CONTEXT` ("local, parameter, global, enum") bounds what finders try. Name the code
that defines it and ask them to derive it, including what a spelling-based gate lets
through. On #31407 round four got such a list with no literal in it, and `"r" (true)`
survived all four rounds until the maintainer tried it. Code changed after the last
round has had no adversarial review: say so when reporting, as it was the source of the
`"A"` input finding on the same PR.

## Step 2 — Pick lenses

Four lenses cover most changes and are the default starting set — adapt,
add, or drop per what the change actually is:

1. **Correctness / spec conformance** — does the code do what it claims,
   and what does the actual governing spec/contract (RFC, API docs, type
   contract) require that a diff-driven read might miss? For protocol code
   this is literal RFC text; for a UI change it might be accessibility/UX
   conformance; for a library it's the documented API contract.
2. **Security / robustness** — malformed/adversarial/boundary input,
   integer overflow, out-of-bounds access, unbounded resource use,
   anything reachable from untrusted input.
3. **Sibling-parity / internal consistency** — find the closest existing
   analog this change claims to mirror (or should mirror) and diff intent
   against it clause by clause; verify every claim the new code's own
   comments/commit message makes against what the code actually does. When
   this lens (or any other) confirms a defect in one function, its very next
   step is to grep the SAME file/module for every other function handling the
   same kind of data and check each for the identical defect shape, before
   reporting just the one instance — "fixed one, missed its twin in the next
   function down" is a common and easily-avoidable miss. Report the sibling
   check as part of the same finding (or as its own finding) either way.
4. **Test-coverage adequacy** — for each test touching this change, trace
   whether it would actually catch a real regression, not just whether a
   plausibly-named test exists; look for vacuous passes and missing
   boundary cases.

For concurrent/protocol code, add a **race/lifecycle** lens (shared-state
writers/readers, goroutine exit paths, lock ordering). For a change with no
tests at all, fold lens 4 into "what test would have caught this" as part of
each finding instead of its own lens. For a change that threads a new field,
parameter, or check through many existing call sites of some existing
pattern (provenance tracking, a permission gate, resource cleanup), add a
**field-flow completeness** lens: grep the raw pattern the new plumbing is
meant to reach (per the search-anchoring note in Step 1) across the whole
tree, not just the call sites the change's own description names, and flag
every hit that doesn't yet carry the new field/check as a candidate gap.

For a change that adds or widens a rejection (a new compiler diagnostic, a
validation error, a lint, a stricter parser), add an **acceptance-regression**
lens — and make it mandatory, not optional, for that shape. Its finder does
not read the new check for defects; it CONSTRUCTS inputs the previous build
accepted and the new one refuses, by enumerating the accepted vocabulary from
the OLD code (keyword and synonym tables, directive or mode sets, every kind of
expression or binding an operand may be) and writing the smallest valid
program for each entry. Hand it the merge-base revision and tell it to run
every program through both builds (or the checker's fixture mode). Its
refuters must try to make the program PASS on the old build, not to argue the
new check is reasonable. Six rounds on vlang/v#31407 ran without this lens and
missed four such programs (vreview Angle K has the list).

Scale lens count and verification strictness to the change's size and
stakes: 3-4 lenses / 3 refuters per finding for a small, self-contained diff;
5+ lenses / 5 refuters with majority vote for something large, security-
sensitive, or concurrency-heavy. Default to the smaller end unless the
change or the user's request signals otherwise.

## Step 3 — Launch the Workflow

Use this shape (pipeline of finders → flatten → parallel adversarial verify).
Fill in `CONTEXT`, `LENSES`, and the file paths from Step 1/2 — do not skip
grounding the prompts, that's the part that actually determines quality:

```js
export const meta = {
  name: 'adversarial-review-<short-slug>',
  description: 'Adversarial verification of <what this diff/change is>',
  phases: [
    { title: 'Find', detail: 'independent finders across distinct lenses' },
    { title: 'Verify', detail: 'adversarial refuters per candidate finding' },
  ],
}

const CONTEXT = `
<Everything from Step 1: absolute file paths to read in full, what the
change claims to do, the sibling pattern it claims to mirror (named), the
exact relevant spec/contract text quoted verbatim, and an explicit scope
boundary — what is DELIBERATELY out of scope for this change (so agents
don't flag a documented, deliberate future-phase gap as a bug).>
`

const LENSES = [
  { key: 'correctness', prompt: `${CONTEXT}\nLens: ... Return up to 5 candidate findings with file, line, summary, and a concrete failure_scenario. If you find nothing wrong, say so explicitly — do not manufacture a finding.` },
  // ... one per lens from Step 2
]

const FINDINGS_SCHEMA = { type: 'object', properties: { findings: { type: 'array', items: { type: 'object', properties: { file: { type: 'string' }, line: { type: 'number' }, summary: { type: 'string' }, failure_scenario: { type: 'string' } }, required: ['file', 'summary', 'failure_scenario'] } } }, required: ['findings'] }
const VERDICT_SCHEMA = { type: 'object', properties: { refuted: { type: 'boolean' }, reasoning: { type: 'string' } }, required: ['refuted', 'reasoning'] }

phase('Find')
const results = await pipeline(
  LENSES,
  lens => agent(lens.prompt, { label: `find:${lens.key}`, phase: 'Find', schema: FINDINGS_SCHEMA }),
  (review, lens) => ((review && review.findings) || []).map(f => ({ ...f, lens: lens.key }))
)
const candidates = results.flat().filter(Boolean)
log(`${candidates.length} raw candidates from ${LENSES.length} finders`)
if (candidates.length === 0) return { confirmed: [], note: 'No finders surfaced any candidates.' }

phase('Verify')
const REFUTERS_PER_FINDING = 3 // bump to 5 for high-stakes/large diffs
const verified = await parallel(candidates.map(c => () =>
  parallel(Array.from({ length: REFUTERS_PER_FINDING }, () => () =>
    agent(
      `Adversarially verify this claimed bug. Try to REFUTE it — default to refuted=true if you cannot construct a concrete failure. Read the actual file/line before judging.\n\nClaim (from the "${c.lens}" lens): ${c.summary}\nFile: ${c.file}${c.line ? ':' + c.line : ''}\nClaimed failure scenario: ${c.failure_scenario}\n\n${CONTEXT}`,
      { label: `verify:${c.lens}`, phase: 'Verify', schema: VERDICT_SCHEMA }
    )
  )).then(votes => {
    const v = votes.filter(Boolean)
    const refuteCount = v.filter(x => x.refuted).length
    const survives = v.length > 0 && refuteCount <= Math.floor(v.length / 2)
    return { ...c, votes: v, survives }
  })
))

const done = verified.filter(Boolean)
const confirmed = done.filter(v => v.survives)
// No vote at all means the refuters failed (for example a usage limit), not that it was refuted.
const unverified = done.filter(v => v.votes.length === 0)
log(`${confirmed.length}/${candidates.length} survived; ${unverified.length} never verified`)
return { confirmed, unverified, totalCandidates: candidates.length }
```

Launch it in the background (the default) unless the user is actively
waiting on nothing else — this task's own result arrives as a notification;
don't poll for it.

## Step 4 — Report

**An empty `confirmed` is only a clean result if every agent ran.** Check the
`<failures>` block and `agents_error` first, and treat any non-empty `unverified`
as an unfinished round: resume with `resumeFromRunId` once the cause is cleared.
On vlang/v#31407 round 2, 45 of 48 agents hit a usage limit and the run returned
`{"confirmed":[],"totalCandidates":15}`; on resume all 15 were confirmed unanimously.

When the workflow completes, report the `confirmed` findings — file, line,
summary, failure scenario, which lens found it. If `confirmed` is empty,
say so plainly: candidates were found but none survived adversarial
verification, or no finder surfaced anything at all (state which). Do not
report the raw, unverified `candidates` list as if it were findings — the
whole point of this skill is that only `confirmed` entries have been checked.

If this run is part of a formal code-review flow that uses `ReportFindings`,
route `confirmed` through it (rank most-severe first). Otherwise a plain
summary in the response is enough — this skill doesn't mandate a specific
output format beyond "confirmed findings only, clearly separated from
refuted/unconfirmed ones."

## Maintenance — where this skill lives

This skill ships in the `review-tools` plugin (one git repository, installed at
user scope on every machine). There is exactly one copy per machine, the clone;
`git pull` / `git push` is the sync between the Mac, WSL and the Windows box.
Edit the skill in the clone, commit, push; the other machine pulls. Nothing is
copied through `/Volumes/SSData`, no staging payload, no `sync_skills.sh`. See
`MIGRATION.md` at the plugin root for install and update commands.
