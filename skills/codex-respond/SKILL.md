---
name: codex-respond
description: >
  End-to-end handler for a Codex (or human) review round on a vlang/v PR:
  fetch the review's inline comments, triage each claim against current code,
  run /phase-r for every confirmed bug, fix, run /vreview, commit, push to the
  fork, and reply to every thread. Encodes the loop run weekly on the net.http
  PRs so it is not re-derived each session.
  Usage: /codex-respond <PR#> [review-id]
disable-model-invocation: false
---

## Input
$ARGUMENTS — PR number; optionally a review id (the number after
`#pullrequestreview-` in the GitHub URL) to scope to one round.

## Phase 1 — Fetch

- Review body: `gh api repos/vlang/v/pulls/<N>/reviews` (match `id` when a
  review-id was given; Codex is `chatgpt-codex-connector[bot]`).
- Inline comments: `gh api repos/vlang/v/pulls/<N>/comments --jq '.[] |
  select(.pull_request_review_id==<ID>) | {id, path, line, body}'`.
- Skip threads already answered: a comment whose `in_reply_to_id` chain ends in
  a reply from `quaesitor-scientiam` is done.
- P-badges (P1/P2/P3) rank severity; handle all, order by badge.

## Phase 2 — Triage every claim (before any code change)

For each comment, verify against the CURRENT tree and classify:
- **CONFIRMED** — the defect is real. Note file:line and the mechanism.
- **ALREADY-FIXED** — name the commit that fixed it; reply needs no code change.
- **REFUTED** — prove it empirically where possible, not by argument: run the
  actual probe (e.g. the h2spec case with `-v`, 5× for determinism), quote the
  wire trace or the guarding line. A hedge ("might be flaky") is resolved by
  running it, not reasoning about it (2026-07-02: the §5.1.2 baseline claim
  was settled by a 5/5 verbose h2spec run).
- Also triage the FIX SHAPE, not just the claim: a reviewer's suggested fix can
  be correct-but-insufficient (the orphan-CONTINUATION per-branch check vs the
  dispatch-level gate). Ask where the invariant belongs before adopting it.
- **A finding's CITATION and its claimed CONSEQUENCE are two separate things —
  verify each independently, not as a package deal.** A reviewer can be right
  that something is wrong while being wrong about WHY (which RFC section
  actually says so) or WHAT HAPPENS as a result (what the code actually does
  today). Confirming one does not confirm the other. Concretely, on
  vlang/v#27680 pullrequestreview-4806500473: (1) a finding cited RFC 8446
  §4.4.3 for "MUST send illegal_parameter" on an unoffered CertificateVerify
  algorithm — fetching §4.4.3 directly, it states the algorithm requirement
  but never names that alert; the classification is real (matches §6.2's
  general definition, this file's own precedent, and majority real-world
  practice) but isn't a literal quote from the cited section, and the reply
  said so rather than implying it was. (2) a finding claimed a hostname bound
  was "letting a malformed ClientHello through with no error" — tracing the
  arithmetic (and confirming with a direct test against the unfixed code)
  showed an unrelated generic guard already rejected every value the loose
  bound let through; the bound was still wrong (fixed it, at the right layer,
  for a correctly-attributed error message), but the specific claimed
  consequence never actually occurred. Both fixes still land — a fix can be a
  good idea even when the reviewer's supporting citation or consequence claim
  doesn't fully hold up — but classify the row as CONFIRMED (bound wrong) with
  an explicit note on what was and wasn't independently verified, not a blanket
  accept. Do this by actually fetching the cited text / running the claimed
  scenario, not by reasoning from how plausible the claim sounds.

## Phase 3 — Phase R for every CONFIRMED finding

Invoke `/phase-r` per finding — reproduction must FAIL on buggy code BEFORE the
fix is applied. No exceptions; this ordering is a standing user rule.

## Phase 4 — Fix + verify

Run the next four checks PER FINDING, immediately after writing that
finding's fix and before moving to the next one — not once at the end for the
whole batch. Reviewing finding 4's fix with the same fresh attention as
finding 1's is exactly what a batched end-of-round pass erodes (anchoring:
by finding 4 you've mentally filed findings 1-3 as "already handled").

- Fix at the right altitude (dispatch-level gate over per-branch patch).
- **Sibling search, before writing the fix — not after.** Grep the file for
  every EXISTING function that already does the same CLASS of thing your fix
  is about to add: abandoning/terminating a resource, enforcing a shared
  limit across sibling pools, applying a documented config field on a new
  code path. Diff your planned change against each sibling line-by-line for
  parity (does it also notify the peer? credit back resources? cover every
  pool the sibling covers? match the field's established semantics
  elsewhere?). Writing a THIRD way to abandon a stream without checking how
  the other two already do it is exactly how vlang/v#27643 round 4's P2
  (no RST_STREAM on watchdog timeout) happened — `cancel_stream` and
  `reset_stream` already established the pattern in the same file. This is
  the fix-writing mirror of `/vreview` Phase 0 step 7 (mandatory sibling-
  parity diff for any new type/function/branch): round 5 (pullrequestreview-
  4631763931) had three findings of this exact shape (a value-vs-pointer
  field, a delayed-vs-immediate wake, a missing retryable-error fallthrough),
  and in each case the working sibling was one function or one file away —
  `/vreview`'s own Phase 0 pass on that same code, run AFTER writing it,
  still missed all three, which is why this check belongs here too, done
  proactively while writing, not only retrospectively at the gate.
- **Impact analysis, before narrowing/changing EXISTING behavior.** If the fix
  changes when/how an existing mechanism fires — narrows a condition, moves
  when something is armed, excludes a case that used to be covered — grep for
  EVERY caller/dependent of that mechanism, not just the one call site
  exhibiting the reported symptom, and ask of each: "did this rely on the
  behavior I'm about to remove?" A fix scoped to "stop the reported false
  positive" can silently delete the only bound something else depended on.
  Concrete near-miss: excluding the upload phase from `req.read_timeout` (to
  stop it firing before the response wait even started) would have left
  `send_body_on_stream`'s flow-control wait with NO timeout at all — caught
  only because it happened to be re-examined before push, not because this
  check was a named, repeatable step at the time.
- **A fix that adds a NEW `error_with_code`/classified-error call needs its
  caller checked too, immediately, not assumed.** If the function you're
  fixing didn't previously return a code-carrying error and now does, grep
  every caller of that function and confirm at least one of them actually
  reads `.code()` before falling back to a generic classification — don't
  assume "this file already has the pattern elsewhere" covers the specific
  caller in front of you. This is Phase C's cross-file caller check applied
  to code you just wrote, not just pre-existing code, and it is exactly as
  easy to skip on your own new code as on someone else's. Missed and then
  self-caught on vlang/v#27680 pullrequestreview-4822597219: fixing
  `parse_certificate` to return `error_with_code(..., unsupported_extension)`
  for a newly-added CertificateEntry-extension check, without checking that
  its only caller (`process_certificate_or_request`) still unconditionally
  remapped ANY failure to a generic `decode_error` — discarding the new code
  entirely, even though 3 OTHER functions in the SAME file already used the
  `err.code() != 0` preservation pattern for their own callees. Caught by
  this session's own `/vreview` pass before push, not by Codex or a human;
  see [[code-review-misses]] round 7 for the full repro.
- **One-paragraph contract check, after writing the fix.** State the touched
  function's complete contract in one paragraph, as if reading it fresh, then
  check every line — not just the new ones — against that paragraph. This is
  what catches an internal inconsistency within a function you just wrote
  (vlang/v#27643 round 2's `evict_idle_h2_if_over_cap`: the cap CHECK counted
  both pools, `total_idle_locked() + h2_conns.len`, but the eviction LOOP only
  ever walked one of them — an asymmetry visible on a single re-read, missed
  because the fix was verified against "does it stop the reported bug," not
  against the function's own stated contract). Mechanical assist for THIS
  specific pattern (a shared-cap check referencing more containers than the
  action touches): `v run "${CLAUDE_PLUGIN_ROOT}"/detectors/detect_pool_cap_scope_symmetry.v <file>`.
- **Test-first for the invariant the fix establishes, not just the reported
  symptom.** Phase R already requires reproducing Codex's SPECIFIC complaint
  before fixing it. Separately: if the fix introduces a NEW invariant that
  isn't just "undo the specific bad input Codex found" (e.g. "a shared cap
  must be evictable from either pool," not merely "this one call site now
  evicts correctly"), write a test for the INVARIANT itself, confirm it fails
  with the invariant only partially applied (e.g. fixed for one pool but not
  the other), then confirm it passes fully fixed. This is what would have
  caught `evict_idle_h2_if_over_cap` being complete for h2 but not h1 — the
  ORIGINAL fix's own test only exercised the specific reported scenario, not
  the general invariant it was supposed to establish.
- `./vnew fmt -w` every touched `.v` file.
- `bash .claude/scripts/vtest-safe.sh vlib/net/http/<suite>_test.v` — all green.
- h2 server changes: rerun the h2spec gate if stream/frame semantics moved
  (`vlib/net/http/h2spec/run_h2spec.sh`, needs `H2SPEC_BIN`).

## Phase 5 — Review gate

Run the full `/vreview` (which runs the detectors via
`run_detectors.sh` and writes the `.git/.last_code_review` fingerprint).
The PreToolUse hook hard-blocks commit/push without it.

## Phase 6 — Commit + push

- Conventional message, e.g. `fix(h2): <what>; <what>` with RFC § references
  and `Both from Codex, vlang/v#<N> pullrequestreview-<ID>.` in the body.
- **Push to `origin` (fork `quaesitor-scientiam/v`) — pushing to vlang/v is
  always 403** ([[feedback_vlang_fork_required]]). Non-fast-forward after a
  remote rebase: fetch, verify content-identical, `reset --hard` +
  `cherry-pick` + `--force-with-lease`.

## Phase 7 — Reply to every thread

`gh api repos/vlang/v/pulls/<N>/comments/<comment-id>/replies -f body="..."`
(NOT `gh pr comment` — that posts top-level). Templates:
- confirmed: `Good catch. Fixed in commit <hash>.` + 2–5 sentences on the
  mechanism and why the fix shape was chosen (include a code fence when the
  gate/guard is short).
- already-fixed: name the commit and the code path.
- refuted: lead with the empirical evidence (wire trace, guard line, N/N runs),
  then the mechanism, then the decision (`Keeping X off the baseline.`).
Multi-line bodies: `-f body="$(cat <<'EOF' ... EOF)"` from the Bash tool —
never a pwsh here-string through the Bash tool.

## Phase 8 — Bookkeeping (same session, unprompted)

- Miss-corpus rows + SKILL.md angle bullets + detectors (Phase R step 8).
- Sync `code-review-reference.html` — the commit-gate hook now also blocks when
  review docs are newer than the HTML.
- Update the project memory (e.g. `project_http_conn_pooling.md`) if the PR's
  status changed.