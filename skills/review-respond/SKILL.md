---
name: review-respond
description: >
  End-to-end handler for one round of review on a PR, from any reviewer: a
  maintainer, another person, or a bot such as Codex. Fetch the review's
  findings (review body, inline comments, or a plain PR comment), triage each
  claim against current code, run /phase-r for every confirmed bug, fix, run
  /vreview, commit, push to the fork, and reply where each finding was posted.
  Encodes the loop so it is not re-derived each session. Not for findings from
  /adversarial-review, which has its own fix loop.
  Usage: /review-respond <PR#> [review-id | comment-id | URL] [owner/repo]
disable-model-invocation: false
---

Renamed from `/codex-respond` on 2026-11-14: the loop is the same whoever the
reviewer is, and most rounds now come from maintainers, not Codex.

## Input
$ARGUMENTS — PR number; optionally the one review or comment to answer (a
review id, the number after `#pullrequestreview-`; a comment id, the number
after `#issuecomment-` or `#discussion_r`; or the full GitHub URL); optionally
the repository as `owner/repo`. Without a repository, take it from the URL, else
from `gh pr view <N> --json url` in the current checkout (vlang/v for the main
checkout, the graphify repository for graphify). Below, `<repo>` is that value.
Without a review or comment, answer every finding on the PR that has no reply
from `quaesitor-scientiam` yet.

## Phase 1 — Fetch

Reviewers post findings in three places; check all three, not just the one a
bot uses:
- Review bodies: `gh api repos/<repo>/pulls/<N>/reviews` (match `id` when a
  review id was given). Codex is `chatgpt-codex-connector[bot]`.
- Inline comments: `gh api repos/<repo>/pulls/<N>/comments --jq '.[] |
  {id, pull_request_review_id, in_reply_to_id, user: .user.login, path, line, body}'`
  (filter on `pull_request_review_id` when a review id was given).
- Plain PR comments, where maintainers often post findings (vlang/v#31848's
  were issue comments): `gh api repos/<repo>/issues/<N>/comments --jq '.[] |
  {id, user: .user.login, created_at, body}'`.
- Skip findings already answered: an inline comment whose `in_reply_to_id`
  chain ends in a reply from `quaesitor-scientiam`, or a plain comment followed
  by a reply from `quaesitor-scientiam` that quotes or links it.
- One comment may hold several findings (a maintainer's numbered list, `[P2]`
  items); split it and give each its own row from here on.
- Severity badges (P1/P2/P3, or `[P2]` in text) rank them; handle all, ordered
  by badge.

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
  see reference/code-review-misses.md round 7 for the full repro.
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
  symptom.** Phase R already requires reproducing the reviewer's SPECIFIC
  complaint before fixing it. Separately: if the fix introduces a NEW invariant
  that isn't just "undo the specific bad input the reviewer found" (e.g. "a shared cap
  must be evictable from either pool," not merely "this one call site now
  evicts correctly"), write a test for the INVARIANT itself, confirm it fails
  with the invariant only partially applied (e.g. fixed for one pool but not
  the other), then confirm it passes fully fixed. This is what would have
  caught `evict_idle_h2_if_over_cap` being complete for h2 but not h1 — the
  ORIGINAL fix's own test only exercised the specific reported scenario, not
  the general invariant it was supposed to establish.
- `./v fmt -w` every touched `.v` file.
- Run the tests nearest the change, timeout-wrapped so a hang ends
  (`bash .claude/scripts/vtest-safe.sh <suite>_test.v` where the checkout has
  it) — all green.
- h2 server changes: rerun the h2spec gate if stream/frame semantics moved
  (`vlib/net/http/h2spec/run_h2spec.sh`, needs `H2SPEC_BIN`).

## Phase 5 — Review gate

Run the full `/vreview` (which runs the detectors through
`detectors/run_detectors.v` and writes the `.last_code_review` fingerprint in
the checkout's git directory). The commit gate blocks commit/push without it.

## Phase 6 — Commit + push

- Conventional message, e.g. `fix(h2): <what>; <what>`, with spec references
  where they apply and the source in the body: `From <reviewer>'s review,
  <repo>#<N> pullrequestreview-<ID>.` (or `comment <ID>`). Write "From", never
  "fixes" or "closes" before the reference: GitHub would close the PR.
- **Push to your fork, the remote whose URL is `quaesitor-scientiam/...`
  (named `fork` in the vlang checkouts), never to the upstream repository**
  ([[feedback_vlang_fork_required]]); check `git remote -v` first.
  Non-fast-forward after a remote rebase: fetch, verify content-identical,
  `reset --hard` + `cherry-pick` + `--force-with-lease`.

## Phase 7 — Reply where each finding was posted

- Inline comment: `gh api repos/<repo>/pulls/<N>/comments/<comment-id>/replies
  -F body=@<file>` (NOT `gh pr comment`, which posts top-level).
- Review body or plain PR comment: there is no thread to reply in, so post one
  PR comment, `gh api repos/<repo>/issues/<N>/comments -F body=@<file>`, that
  links the comment it answers and takes its findings one by one.

Templates:
- confirmed: `Good catch. Fixed in commit <hash>.` + 2–5 sentences on the
  mechanism and why the fix shape was chosen (include a code fence when the
  gate/guard is short).
- already-fixed: name the commit and the code path.
- refuted: lead with the empirical evidence (wire trace, guard line, N/N runs),
  then the mechanism, then the decision (`Keeping X off the baseline.`).
Multi-line bodies: write the text to a file in the scratchpad and pass
`-F body=@<file>` — never a pwsh here-string through the Bash tool. Replies are
public: show the user the text before posting it.

## Phase 8 — Bookkeeping (same session, unprompted)

- Miss-corpus rows + SKILL.md angle bullets + detectors (`/vreview` Phase R
  step 6).
- Sync `code-review-reference.html` — the commit-gate hook now also blocks when
  review docs are newer than the HTML.
- Update the project memory (e.g. `project_http_conn_pooling.md`) if the PR's
  status changed.