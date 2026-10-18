---
name: phase-r
description: >
  Reproduce-before-fix workflow for an externally-found miss (Codex or human
  reviewer). Owns the ORDERING so it cannot be violated: record → write failing
  reproduction → isolate the buggy state → confirm the repro FAILS on buggy code
  → restore/apply the fix → confirm it passes → log the corpus row. This is the
  executable form of /vreview's "Phase R"; that SKILL.md section remains the
  canonical rationale. Usage: /phase-r <finding description or comment URL>
disable-model-invocation: false
---

## Input
$ARGUMENTS — the finding: a Codex comment URL/id, or a description of the bug
and where it lives.

## Why the ordering is absolute

**STOP. No code fix may be applied until step 5 has produced a FAILING run on
the buggy code.** Fixing first collapses "does my repro detect the bug?" and
"does my fix work?" into one unverifiable check — a repro written after the fix
that passes proves nothing. The user has corrected this violation three times
(2026-06-22 ×2, 2026-07-01); it is a standing disappointed-user rule
([[feedback_phase_r_before_fix]]).

## Steps

1. **Record** — the commit the reviewer reviewed (`git log` / the PR review's
   `commit_id`), the `file:line`, and the bug class (lenient-parse, error-scope,
   orphan-frame, unbounded-accum, …). State these in the response before
   touching anything.

2. **Diagnose the review flaw — with evidence, not a default.** The corpus
   shows the answer is usually "present-but-not-run" (an angle/detector
   that should have caught this already existed, and the failure was
   execution — eyeballed instead of run) — but that history is context,
   not license to assume it. Name the specific rule (angle letter + bullet,
   detector script, or matrix row) and state WHY it failed (never run?
   eyeballed? a confirmed structural blind spot? scope narrower than this
   instance?). If you cannot name a rule, the honest answer is "missing,"
   not a softer present-but-not-run — a new angle bullet + detector (or
   matrix row / artifact column / checklist rule — see /vreview Phase R
   step 3) is part of the deliverable (step 8). State both fields in the
   response before touching anything, same as step 1's record.

3. **Write the reproduction** — a test in the appropriate `*_test.v`, or a
   `detect_*.sh` script for statically-visible defects (e.g. when the fix makes
   the bad input panic, or the bug is a missing guard). A detector isn't the
   only mechanical option, and isn't always the right one — a defect can also
   close as a conformance-matrix GAP row, a new column on an existing required
   artifact/table, a checklist rule, or (when a detector genuinely can't be
   extended to the shape) a documented detector limitation. See /vreview's
   Phase R step 3 for the full menu and when each fits; steps 4-7 below adapt
   to whichever one applies the same way that section's steps 4-5 do.
   **Test-design rule (hang-proof):** the test MUST emit an observable outcome
   on BUGGY code — never a bare wait for a frame/response that buggy code will
   never send. Pair the illegal input with a follow-up VALID request so the bug
   manifests as "server kept serving / wrong response" instead of a hang
   (learned 2026-07-02: an orphan-CONTINUATION repro hung 5+ min because the
   buggy server silently accepted the frame and idled). Run every test through
   `bash .claude/scripts/vtest-safe.sh <file>` (timeout-wrapped).

4. **Isolate the buggy state** — keep the new test, revert only the
   implementation:
   - fix not yet written: you are already on buggy code — proceed;
   - fix uncommitted: `git stash push -- <impl-file.v>` (test file stays);
   - fix committed: `git show <buggy-rev>:<impl-file> > /tmp/buggy.v` for
     detectors, or `git stash`/branch juggling for tests.

5. **Run on buggy — MUST fail/flag.** `vtest-safe` exit non-zero with the
   expected assertion, or detector exit 1. If it passes, the repro is
   insufficient — iterate on step 3. Quote the failing output in the response.

6. **Restore/apply the fix** — `git stash pop`, or now write the fix.

7. **Re-run — must pass.** Same command, exit 0. A green run with the bug still
   present means the REPRO is wrong (e.g. it tests an upstream guard the fix
   site doesn't own) — fix the repro, re-verify from step 4.

8. **Log it** — all of, in the same session:
   - corpus row in memory `code-review-misses.md` (class, reviewed commit,
     detector/check, failure narrative);
   - Angle bullet in `${CLAUDE_PLUGIN_ROOT}/skills/vreview/SKILL.md` if the class is new;
   - mechanical detector in `${CLAUDE_PLUGIN_ROOT}/skills/code-review/` if mechanizable
     (verify: exit 1 on buggy rev, exit 0 on fixed tree) + add it to
     `run_detectors.sh`'s manifest — or the non-detector remediation from
     step 3 (matrix row, artifact/table column, checklist rule, documented
     limitation) when a detector doesn't fit;
   - sync `${CLAUDE_PLUGIN_ROOT}/reference/code-review-reference.html`
     ([[feedback_update_code_review_html]]).

Phase R alone does NOT satisfy the commit gate — run the full `/vreview`
before committing (the PreToolUse hook enforces both the review fingerprint and
the HTML sync).

## When the repro won't localize: audit the harness constants

Before committing to a long bisect or patch-and-measure hunt, list every
constant in the reproduction harness — each fixed flag, env var, the bootstrap
binary/toolchain, cache settings, the input file — and for each ask: **could
THIS be the cause?** Anything held fixed across every measurement is
structurally invisible to whatever search runs on top of it (bisect,
patch-testing, symbol diff): if the cause lives there, every run holds it
constant and it never shows up as a signal.

Vary the suspicious constants one at a time against a known-bad baseline first.
Especially suspect any flag that changes codegen, the reachable/markused set, or
the module graph of the artifact being built — those have whole-program effects
that will NOT localize to a single commit, so a clean bisect through them is
misleading, not exonerating.

Learned 2026-09-06 (vlang/v#28423): a Linux `make` bootstrap OOM was chased for
hours with a 2-generation probe whose command line hard-coded `-no-parallel`.
The actual root cause was inside that constant — `-no-parallel` was injecting
`v3_no_parallel` into the *output* compiler, pruning its module graph into a
high-memory codegen. Fixed in ~3 lines (PR #28429, `vlib/v3/driver/driver.v`)
after being wrongly written off as "not classically bisectable, needs
maintainer-level knowledge." ([[repro-harness-constants-can-be-the-cause]])

## Applying this to code YOU are writing fresh, not just a reported miss

This skill's ordering (repro fails on buggy code → fix → repro passes) is
usually triggered by an external finding. Apply the SAME ordering to your own
new code when the fix establishes an invariant broader than "stop this one
reported bad input" — most fixes actually do this even when framed as fixing
one complaint. Ask: what is the GENERAL rule this fix is supposed to
establish (not just the specific symptom Codex named)? Write a test for the
GENERAL rule, confirm it FAILS against a version of the fix that only
partially establishes it (e.g. correct for one branch/pool/case but not its
sibling), then confirm it passes once the fix is actually complete. Skipping
this and testing only the exact scenario named in the report is how a fix can
pass its own test while still being incomplete: vlang/v#27643's
`evict_idle_h2_if_over_cap` had a regression test for "does not evict its own
new connection" (the exact reported scenario) that stayed green through two
more rounds while the function was still only evicting from one of the two
pools it was supposed to cover — a test for the general rule ("the combined
h1+h2 idle count never exceeds max_idle_conns") would have caught it a round
earlier.