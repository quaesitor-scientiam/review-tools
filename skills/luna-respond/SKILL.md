---
name: luna-respond
description: >
  End-to-end handler for a GPT-5.6 Luna review round on a vlang/v PR, mirroring
  /codex-respond's shape: fetch Luna's findings, triage each claim against
  current code, run /phase-r for every confirmed bug, fix, run /vreview,
  commit, push to the fork, and report results back. NOT YET WIRED — Phase 1's
  fetch step is a placeholder until a Luna-providing MCP server is connected
  (see [[project_vreview_luna_reconsideration]]). Do not invoke this skill
  expecting real findings until Phase 0 confirms the server is connected.
  Usage: /luna-respond <PR#> [round/scope]
disable-model-invocation: false
---

## Input
$ARGUMENTS — PR number; optionally a round/scope identifier if Luna's output
is chunked (analogous to `/codex-respond`'s optional review-id).

## Phase 0 — Wiring check (STOP here if unwired)

This skill was authored 2026-08-15 before any Luna-providing MCP server was
connected or found in the registry. Before doing anything else:

1. Check for a connected server: `ToolSearch({query: "luna", max_results:
   10})` and/or `mcp__mcp-registry__list_connectors({keywords: ["luna",
   "review"]})`.
2. **If nothing is found:** stop. Tell the user this skill isn't wired yet
   and point them at [[project_vreview_luna_reconsideration]] rather than
   fabricating findings or silently falling back to `/codex-respond`'s
   mechanics with no actual Luna data behind them.
3. **If a server is found:** this is the first real invocation — read its
   tool schema(s) via the `ToolSearch` result, then edit Phase 1 below to
   replace the placeholder with the concrete tool name/args/output shape
   before proceeding. Leave Phase 1 permanently updated for future runs
   (this is a one-time wiring cost, not a per-invocation step).

## Phase 1 — Fetch (PLACEHOLDER — replace on first real wiring)

Two possible delivery shapes; determine which applies once the server is
connected, use the matching path, and delete the other from this file:

- **MCP tool returns findings directly** (most likely, per the user's own
  framing — "could be an MCP server that /vreview could use"): call the
  discovered tool for PR `<N>`, passing whatever it needs (PR diff, PR
  number, branch). Normalize its output into the same shape Phase 2 below
  expects: a list of `{id, file, line, body, severity?}`. There is no
  GitHub thread to skip-if-already-answered in this shape — track
  already-triaged findings by their own `id` instead (e.g. a local marker
  file, mirroring how `/codex-respond` checks for an existing reply).
- **Luna posts as a GitHub PR review** (if it turns out to run as a bot
  account, like Codex): fetch identically to `/codex-respond` Phase 1 —
  `gh api repos/vlang/v/pulls/<N>/reviews` (match Luna's bot account once
  its username is known), inline comments via `gh api
  repos/vlang/v/pulls/<N>/comments --jq '... | select(.pull_request_review_id==<ID>)'`,
  skip threads already answered by `quaesitor-scientiam`.

Severity ranking: if Luna emits P1/P2/P3-style badges, handle all, ordered
by badge, same as Codex. If it doesn't, ask the user how findings are
ranked rather than inventing a severity scheme.

## Phase 2 — Triage every claim (before any code change)

Identical to `/codex-respond` Phase 2 — reviewer identity doesn't change
this step. For each finding, verify against the CURRENT tree and classify:
- **CONFIRMED** — the defect is real. Note file:line and the mechanism.
- **ALREADY-FIXED** — name the commit that fixed it; reply needs no code
  change.
- **REFUTED** — prove it empirically where possible (run the actual probe,
  quote the trace or the guarding line), not by argument.
- Triage the FIX SHAPE too, not just the claim — a suggested fix can be
  correct-but-insufficient; decide where the invariant actually belongs.
- Apply the codex-respond citation/consequence-independence rule: a
  finding's CITATION (which RFC section / which line) and its claimed
  CONSEQUENCE (what actually happens today) are two separate things to
  verify independently, not a package deal.

## Phase 3 — Phase R for every CONFIRMED finding

Invoke `/phase-r` per finding — reproduction must FAIL on buggy code BEFORE
the fix is applied. No exceptions; this ordering is a standing user rule,
same as for Codex findings.

## Phase 4 — Fix + verify

Identical checklist to `/codex-respond` Phase 4 — read that section in full
before fixing anything here; it is reviewer-agnostic engineering discipline,
not Codex-specific, and duplicating it risks the two copies drifting. In
summary, per finding, immediately after writing its fix (not batched at the
end): sibling search before writing, impact analysis before narrowing
existing behavior, one-paragraph contract check after writing, test-first
for the general invariant (not just the reported scenario), `./vnew fmt -w`
the touched files, run the relevant suite via
`bash .claude/scripts/vtest-safe.sh <file>`.

## Phase 5 — Review gate

Run the full `/vreview` (runs the detectors via `run_detectors.sh` and
writes the `.git/.last_code_review` fingerprint). The PreToolUse hook
hard-blocks commit/push without it — this is unconditional regardless of
which upstream skill produced the diff.

## Phase 6 — Commit + push

- Conventional message, e.g. `fix(quic): <what>; <what>`, with RFC §
  references where applicable and `Both from GPT-5.6 Luna, vlang/v#<N>
  <finding-id-or-review-id>.` in the body (mirrors `/codex-respond`'s
  attribution line).
- Push to `origin` (fork `quaesitor-scientiam/v`) — pushing to vlang/v is
  always 403 ([[feedback_vlang_fork_required]]).

## Phase 7 — Report back to the review source

Depends on which Phase 1 path applies — pick the one that matches and
delete the other once known:

- **If Luna posts as GitHub PR review comments:** reply per-thread exactly
  like `/codex-respond` Phase 7 — `gh api
  repos/vlang/v/pulls/<N>/comments/<comment-id>/replies -f body="..."` (NOT
  `gh pr comment`, which posts top-level), same confirmed/already-fixed/
  refuted templates.
- **If Luna is a pure MCP tool with no GitHub presence:** there are no
  threads to reply to. Post ONE new top-level PR comment (`gh pr comment
  <N> --body "..."`) summarizing every finding's verdict (confirmed+fixed,
  already-fixed, refuted) and the commit hash — mirroring how this project
  already handles self-found gaps with no existing external thread (see
  PR #28083 comment `5300372620`).

## Phase 8 — Bookkeeping (same session, unprompted)

- Miss-corpus rows in `${CLAUDE_PLUGIN_ROOT}/reference/code-review-misses.md` / the reference HTML's data
  file (`${CLAUDE_PLUGIN_ROOT}/reference/code-review-misses-data.js`) — the corpus
  has no separate structured `reviewer`/`source` field today (Codex vs.
  Copilot attribution lives in the free-text narrative); follow the same
  convention and name "GPT-5.6 Luna" in the row's text.
- SKILL.md angle bullets + detectors for any genuinely new bug class,
  same as any other Phase R (see `/phase-r` step 8).
- Sync `code-review-reference.html` — the commit-gate hook also blocks when
  review docs are newer than the HTML.
- Update [[project_vreview_luna_reconsideration]]: once this skill has
  actually processed one real round, update it to record that Luna moved
  from "flagging" to "active use," and note here (not by re-litigating the
  earlier open question) whether the user has since given direction on
  replacing / keeping-alongside `/vreview`.
