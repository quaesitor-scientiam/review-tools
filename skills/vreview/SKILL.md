---
name: vreview
description: >
  The project's code-review process (renamed from code-review so the bundled
  skill of that name can never shadow it — the Skill tool resolved the old name
  to the bundled skill despite documented project-over-bundled precedence).
  Runs Phase 1 inline (no sub-agents, so session limits cannot kill it) and adds
  a full-file holistic angle, an H2/QUIC protocol-spec angle, and admission-gate +
  swallowed-write-error checks — the classes of findings Codex keeps catching
  that diff-only review misses. Detector scripts and the conformance matrices
  (H2, QUIC) remain at ${CLAUDE_PLUGIN_ROOT}/skills/code-review/ so every embedded path
  stays valid; run detectors all at once with
  `bash "${CLAUDE_PLUGIN_ROOT}"/skills/code-review/run_detectors.sh`.
  Usage: /vreview [PR#|branch|--fix|--comment] [low|medium|high|max]
  [lite|standard|high-risk|regression]
disable-model-invocation: false
---

## Hard rules — read before anything else

These come from the user after skipped steps cost them heavy token spend (graphify
PR #149, 2026-11-01). They bind on every machine; they live here, not in local
memory, because memory does not sync.

1. **No artifacts, no pass.** A `/vreview` run counts as a pass only when its
   Artifacts block (per-file contract paragraphs, repeat-offender list, new
   type/function contracts, sibling parity table, test discrimination table,
   acceptance-regression table, and every other artifact this file requires) is written out in the response, with an
   explicit "none" / "N/A — reason" where one is empty. Never report "`/vreview`
   passed" or "clean" for a run that omitted any of it — not to the user, not in a
   commit message, not in a PR body. On PR #149, passes reported clean without the
   artifacts let five `/adversarial-review` rounds (~14M subagent tokens) find 35
   defects; 6 of them were already covered by rules here (the parity table alone
   would have compared `generated_enum_mod` with `resolve_qualified_callee`).
   **A filled-in artifact is not evidence by itself.** Every "pass", "matches" or
   "handled by" cell names what was run or read: the command and its result, or the
   `file:line` opened during this review. A cell that repeats what the author already
   believes is unverified; mark it so. A row holding several entries is several
   unverified rows. On vlang/v#31407 (rev 88) one row read "const untyped, typed, bool,
   enum, sizeof, expr ... pass", and another said "`A` still not listed, handled by pair
   logic" although that logic reads outputs only. Both hid a finding the maintainer
   then reported.
2. **Never skip a required step silently — ask first.** If any required step of this
   skill, of `/adversarial-review`, or of a standing rule (an artifact, a rerun,
   Phase R, a test) looks unnecessary or too costly, stop and ask the user before
   skipping it. Do not decide alone.
3. **Review loop order.** `/vreview` → fix → rerun `/vreview` after EVERY fix round
   until a pass has no confirmed findings → only then `/adversarial-review` → fix →
   back to `/vreview`. Repeat until both are clean in the same round. The inline pass
   is far cheaper; every defect it catches is one the agent swarm need not.
   **Where the code approximates another tool, "clean" can't be reached, so the loop
   stops at a round with no blocking finding.** That covers a resolver, analyzer or
   indexer that picks one reading of what a compiler would do from less than it knows:
   some valid program always breaks the approximation. State the classification, and why,
   before the first adversarial round; ask the user when in doubt. It never covers code
   that rejects or accepts input, handles untrusted data, or touches protocol, crypto,
   concurrency or memory lifetime: those stay "until both are clean". Blocking means:
   a regression from base with a real occurrence; a wrong output on a real tree; or a false
   claim in a doc or comment. Every other confirmed finding is logged as a disclosed limit
   in the project's docs and doesn't trigger another round. Downgrading a regression takes
   a search: name the trees searched and the pattern used, or it stays blocking. A fix for
   a blocking finding still goes back through this loop. On graphify `resolve-remaining`
   (rev 91) four rounds confirmed 22, 13, 20 and 12 findings and ~20M subagent tokens, the
   last three commits changed no edge of the V tree, and one of round 4's 12 occurs in a real
   tree: the 164 false edges between two clones, which is what the review is for.

## Plugin paths
This skill ships in the `review-tools` plugin (git repo, installed at user scope).
Every `${CLAUDE_PLUGIN_ROOT}` below is substituted by Claude Code with the plugin's
install directory, a Windows-style path with forward slashes on Windows. Detectors
must run under WSL on Windows (per-line subshells hang on git-bash), so convert the
root first: `wsl -e bash -lc 'root=$(wslpath -u "<expanded root>"); cd /mnt/s/repo/<checkout> && bash "$root"/skills/code-review/run_detectors.sh <files>'`.
The commit gate (`${CLAUDE_PLUGIN_ROOT}/hooks/require_code_review.sh`) and the HTML
reference (`${CLAUDE_PLUGIN_ROOT}/reference/code-review-reference.html`) live in the
same plugin; nothing is read from the target repo's `.claude/` directory any more.
All detectors are V programs in `${CLAUDE_PLUGIN_ROOT}/detectors/*.v`, run through the V
runner `${CLAUDE_PLUGIN_ROOT}/detectors/run_detectors.v`, so on Windows the whole loop runs
from PowerShell with no bash or WSL:
`S:\\repo\\vlang\\v.exe run "<expanded root>/detectors/run_detectors.v" <files>` from the
checkout being reviewed (it compiles the detectors once into a cache under %TEMP%). On
WSL/macOS `v run ...` or the thin `run_detectors.sh` work the same. Past revisions:
`--at <rev> <file>`; detectors themselves never call git.

## Input
$ARGUMENTS (optional: PR number, branch name, --fix, --comment, effort level,
review mode). Review mode is auto-detected from the diff by default (see
Phase 0's Mode Selection) — pass one of `lite`/`standard`/`high-risk`/
`regression` explicitly only to override the auto-detected mode (e.g. a
reviewer wants High-risk rigor on a diff that wouldn't otherwise qualify).

---

## Phase 0 — Gather the diff and full file content

**The scope is the diff against the PR base, NOT the last commit or the upstream
branch.** The dominant cause of missed findings (PR #27413, four rounds running)
was reviewing only the last incremental hunk: when the branch tracks
`origin/<branch>` and you just pushed, `git diff @{upstream}...HEAD` is **empty**,
and a per-commit diff shows only the latest change — so the review never sees the
rest of the PR. Codex always reviews the full PR diff against base; you must too.

1. **Determine the base branch.** PR number passed → use `gh pr view <N> --json
   baseRefName`. Otherwise the base is `master` (the repo's default; confirm with
   `git remote show origin` only if `master` does not exist). Find the merge base:
   `git merge-base <base> HEAD`.

2. **Get the diff at PR scope:**
   - PR number passed → `gh pr diff <N>`.
   - Otherwise → `git diff $(git merge-base <base> HEAD)...HEAD`. This is the
     entire branch's contribution, the same scope Codex reviews. Do **not** use
     `@{upstream}...HEAD` or `HEAD~1` — both under-scope a pushed branch.
   - Also fold in uncommitted work: `git diff HEAD`.

3. **Classify every `.v` file in that diff** as either NEW (added in this branch
   vs base: `git diff --diff-filter=A --name-only $(git merge-base <base> HEAD)...HEAD`)
   or MODIFIED.

### Select the review mode — before continuing to step 4

**The full process is expensive; not every diff needs the same amount of
it.** Pick exactly one mode from the file/context evidence above — state
which and why as part of the Phase 0 checklist. This is a classification
with evidence, same discipline as everything else in this skill: cite the
files/domains that put the diff in a mode, don't just assert a level of
effort. If `$ARGUMENTS` names a mode explicitly, it overrides
auto-detection — still state the evidence for what auto-detection would
have picked, so a downgrade from what the files imply is visible, not
silent.

- **Lite** — the diff touches ONLY docs (`.md`), test files (`_test.v`,
  `vlib/v/tests/`, `vlib/v/slow_tests/`), or local/non-shared code with no
  protocol, concurrency, security, or cross-file surface. Full-file reads
  and the Phase 0 artifacts stay required, but "N/A" is the expected answer
  for most of them (repeat-offender list, sibling parity table, Angle
  E/F/H matrices) — state N/A explicitly rather than skip the field.
  **Exception — a test that certifies a fix is never Lite.** A test-only diff
  that adds a regression test for a bug, or rests on a claim that the bug is
  "already fixed" (upstream, in an earlier commit, by another PR), takes the
  mode of the code under test. Read the fixed function in full, find every
  writer of the state the fix corrects (each branch that changes the counter,
  map, flag or collection the fix keeps consistent), and for each one either
  point at a test case that goes through it or state why it cannot reach the
  failure. The sibling parity table compares the fix's own sites with those
  writers, not the test harness with other harnesses. One reproduced shape
  does not establish "fixed". Missed on vlang/v#31797 (adversarial review
  round 1, 2026-11-03): a test-only diff pinned FastC's `m[x or { y }] = v`
  panic, fixed upstream by #31394's two `source_token_count` resets; `/vreview`
  ran Lite, never read `read_expression_with_prefix_mode_impl`, and passed
  while `.filter(...)` folds still panicked the same slice (`8 >= 6`) and
  other branches (`$d`, `${}`, `if` values) let the count fall behind and lose
  the target type.
- **Standard** (default) — everything else: ordinary production changes
  with no High-risk-domain surface. Run the full process as documented
  throughout this file, at full strength.
- **High-risk** — the diff touches ANY of: protocol code (H2/QUIC/HTTP),
  the parser/scanner/checker, a new or widened diagnostic, rejection or
  validation gate in any tool (Angle K applies in full), crypto/TLS, an
  `unsafe{}` block, concurrency primitives (locks, condvars,
  goroutines/threads, atomics), or manual resource-lifetime code (C interop,
  `.free()`/`.close()`/`.shutdown()` contracts). Even a small diff in these domains has a track record of
  hiding real findings — see the Bug Corpus.
- **Regression** — this review is running because an external reviewer
  (Codex or human) already found a miss in a prior pass on this exact
  code — i.e. this invocation is (or includes) Phase R. A confirmed miss
  raises the prior on siblings elsewhere in the same PR; treat the whole
  PR at High-risk rigor even if individual files wouldn't otherwise
  qualify.

**High-risk and Regression both disable the Phase 1 per-angle candidate cap
(step "up to 6 candidates" becomes uncapped — surface every candidate an
angle finds) and require every applicable matrix/artifact
(sibling parity table, Angle E's conformance matrix rows, Angle F's three
concurrency matrices, Angle H's absence-search checklist) to be FULLY
populated, not liberally marked N/A.** In these two modes, "N/A" for an
angle that plausibly applies is itself a claim that needs justification —
state why the angle doesn't apply, don't default to N/A the way Lite mode
does. Standard and Lite keep the per-angle cap and normal N/A discretion.

4. **Read every file in the diff IN FULL — mandatory, no exceptions.**
   - For a NEW file, *every line is in scope*: the whole file is the PR's
     contribution. The bugs Codex keeps finding (content-length not validated, 1xx
     interim responses latched as final, PING ACK before preface) were never in any
     incremental hunk — they were in untouched parts of the new file.
   - Do **not** rationalize "the diff is small, targeted reads of the enclosing
     function are enough." That rationalization is the bug. If a file is NEW or the
     change touches protocol/concurrency logic, read it top to bottom before Phase 1.
   - Diff-only review is blind to pre-existing bugs that interact with the new code;
     full-file reading is the primary source of findings we otherwise miss.
   - **Artifact: per-file contract paragraph.** For every file read in full this
     step, write one paragraph stating its contract — the invariant(s) it exists
     to hold, its before/after state transitions, and what shared state it
     touches. This is the proof the read happened, not a summary of it: "I read
     it" with no paragraph is unverifiable and does not count as Phase 0. Carry
     every paragraph into the Output format's Artifacts block verbatim.

5. **Flag repeat-offender functions — diff-only review is INSUFFICIENT for
   them.** For every function touched by this diff, check whether it was ALSO
   modified in an earlier commit on this same branch: `git log --oneline
   <base>..HEAD -- <file>`, then check each prior commit's diff for the
   function name. A function on its second (or later) touch this branch is a
   repeat offender: it already absorbed one narrow, Phase-R-scoped fix for a
   SPECIFIC reported bug, and that kind of fix does not re-derive the
   function's complete contract — it only closes the one gap that was named.
   For every repeat-offender function, before running Angle A-I on it: write
   its complete contract in one paragraph, from scratch, as if seeing it for
   the first time, then check EVERY line of its CURRENT body (not just the
   newly-changed lines) against that paragraph. This is not optional and not
   covered by a normal diff scan. Concrete cost of skipping it: on
   vlang/v#27643, `evict_idle_h2_if_over_cap` was touched in round 2 (created)
   and round 3 (added a self-eviction guard) — both rounds' `/vreview` passes
   read the diff hunks and found nothing, and round 4's Codex still caught
   the function counting both connection pools in its cap check but only
   ever evicting from one of them, an inconsistency visible on a single
   fresh read of the whole function, never spotted because neither prior
   round re-derived its contract from scratch.
   **Artifact: repeat-offender list.** For every function flagged this step,
   record one row: `function — file:line — prior commits touching it (git log)
   — pass/fail against the from-scratch contract`. An empty list is a valid
   artifact ("no repeat offenders in this diff") — an OMITTED list is not;
   state it explicitly rather than leaving the reader to assume the check ran.

6. **New types/functions get the SAME from-scratch contract check as repeat
   offenders — being new is not a reason for LESS scrutiny.** The repeat-
   offender rule exists because a narrow, Phase-R-scoped fix doesn't re-derive
   a function's full contract — but the identical gap exists for code written
   fresh in this diff: an author's own assumptions about a brand-new type are
   exactly as untested as a revised one, and several bugs in this corpus were
   in code touched exactly once. For every NEW struct, method, or function
   this diff introduces, write its complete contract in one paragraph, from
   scratch, before running Angle A-I on it — do not skip this because "it's
   new, there's nothing to compare it against yet" (step 7 below is precisely
   the check that answers that objection). Missed on vlang/v#27643 round 5
   (pullrequestreview-4631763931): `H2PooledTransport.conn` stored a dialed
   TLS connection by value in a struct written fresh for this PR. The
   contract — "this field must let read()/write()/close() all operate on the
   SAME live connection object for the struct's whole lifetime" — takes one
   sentence to write and immediately raises the question of whether a value
   copy could violate it.
   **Artifact: new type/function contract list.** Same row format as the
   repeat-offender list above, one row per NEW struct/method/function this
   diff introduces. State "none" explicitly if the diff adds no new types or
   functions — do not simply omit the artifact.

7. **Find the closest existing sibling for every new type/function/branch and
   diff intent line-by-line.** Before considering new code finished, ask: does
   an existing, already-working piece of code in this file or a sibling file
   do the SAME class of thing (hold a pooled connection, coordinate a
   singleflight dial, wake a set of waiters, retry a stream error)? If so,
   compare the new code against it clause by clause — every case the sibling
   handles that the new code doesn't is a candidate. This is broader than the
   existing "sibling handler scan" below (which compares match arms within one
   dispatch function): it applies to a whole TYPE or CODE PATH having a
   working analog elsewhere, not just one branch of one match statement. Three
   of six findings on vlang/v#27643 round 5 (pullrequestreview-4631763931) had
   exactly this shape: `H1PooledConn.ssl` was already `&ssl.SSLConn` while the
   newly-written `H2PooledTransport.conn` was a bare value; the same
   function's own h2-success branch already woke singleflight waiters
   immediately while its h1-fallback branch delayed the wake; `h2_round_trip`'s
   own fast path already had an `h2_err_retryable_code` fallthrough retry that
   a new recheck path elsewhere in the same file lacked. In each case the fix
   was to copy a pattern already proven correct one function or one file away
   — a sibling-parity check would have caught all three before Codex did.
   **The parity diff's scope is the sibling's CALL PATH, not just its body.**
   A guard can live in the sibling's CALLER rather than the sibling itself —
   a capability gate, platform check, or admission guard that every path TO
   the sibling passes through is part of the sibling's effective contract,
   and new code that enters the mirrored logic at a different altitude must
   reproduce it. Missed on vlang/v#27712 (Codex P1, pullrequestreview-
   4729311285): `h2_dial_probe_vschannel` faithfully mirrored
   `vschannel_h2_do`'s connect sequence (its doc comment even says so), but
   the `C.vschannel_alpn_supported() != 0` gate — pre-8.1 SChannel can fail
   the whole handshake on an ALPN buffer — lives in `vschannel_ssl_do`, the
   sibling's caller, so a function-body parity diff never saw it; on pre-8.1
   Windows the pooled probe would have failed ordinary HTTPS outright instead
   of degrading to h1. When mirroring function X, grep X's callers and list
   every condition they check before calling X; each one is a parity
   candidate for the new path. Run the mechanical detector for this instance:
   `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_vschannel_pooled_alpn_gate.v
   vlib/net/http/vschannel_pooled_transport_windows.c.v` (exit 1 on
   `e0368d7a2d`, 0 after the gate).
   **The sibling can live in another LANGUAGE or LAYER.** When two layers
   each interpret the same wire field (a C fast-path framing decision and a
   V parser's decode decision), they must share ONE semantics — find the
   existing authoritative parser and mirror it exactly; a hand-rolled weaker
   approximation (substring, prefix, lenient parse) WILL disagree on some
   input, and the disagreement is the bug. Missed on vlang/v#27714 (Codex
   P2, pullrequestreview-4689847198): vschannel.c matched
   `Transfer-Encoding` by SUBSTRING (`xchunked` counted as chunked) while
   `net.http`'s `has_header_token` — acting on the same bytes later —
   matches whole comma-separated tokens; the C loop stopped at an accidental
   fake chunk terminator that V then (correctly) refused to decode, silently
   truncating the body. Same round, same file: a strict-parse-with-safe-
   fallback design ("unparseable → read until close") silently reverted to
   the PRE-FIX hang for the grammar-legal variant `Content-Length: 27 `
   (trailing OWS never trimmed) — when the fallback IS the old bug,
   normalize every legal variation before the strict check and Phase-R
   against variant inputs, not only canonical ones.
   **The sibling can be a build-flag-selected BACKEND of the same interface
   — a fix to ONE backend's security-relevant default does not audit the
   others.** This repo routinely ships 2-4 parallel implementations of one
   capability behind a build tag (`net.mbedtls` / `net.openssl` / SChannel
   for TLS; `_d_use_openssl.v` / `_notd_use_openssl.v` for crypto backends),
   each with its OWN copy of any security-relevant default. Fixing an
   insecure-default gap in ONE backend is not "done" until every OTHER
   backend selected by the SAME build flag has been read for the identical
   gap — grep the flag/interface name (`SSLListener`, `SSLConn`, the shared
   `FetchConfig`/`Request` fields every backend consumes) for its full list
   of implementations first, add one row per backend to the sibling table
   below, don't stop at the one file the original bug report named. Missed
   on vlang/v#28406 (external "Local AI"/Codex review, many rounds,
   2026-09-07): this PR's own headline fix was `net.mbedtls` silently
   accepting any certificate when `validate` defaulted to `false`
   (`MBEDTLS_SSL_VERIFY_OPTIONAL` never aborts the handshake on failure) —
   but `net.openssl`, a SIBLING TLS backend in the SAME PR's own diff,
   never called `SSL_VERIFY_PEER` or verified the requested hostname AT
   ALL, in either its default or explicit-`verify` path — a second,
   independent instance of the exact bug class this PR was written to fix,
   sitting in a file the sibling-search step should have reached but never
   did. A third backend (Windows SChannel) turned out to already validate
   correctly via the OS trust store but had no doc comment saying so,
   itself only found because this check was finally run backend-by-backend
   after the OpenSSL gap surfaced externally.
   **The sibling can also be every OTHER CONSUMER of a config field whose
   DEFAULT you just changed, not only files that mirror its logic.**
   Flipping a shared struct field's default (`validate bool = false` →
   `= true`) changes behavior for every code path that reads that field,
   including ones the diff never touches — grep the field name across the
   whole module tree, not just the primary path the change was written
   for. Same PR: failed HTTP CONNECT/SOCKS5 TLS setup left partial SSL
   state unfreed and the TCP socket open on error, in proxy code the CA-
   bundle/validate-default PR never edited directly but whose behavior the
   default change still altered (a validate:true default now fails more
   often on untrusted proxies, exercising an error path that was already
   leaky and simply hadn't been reached before).
   **The sibling can be the VERIFICATION step of the artifact it checks.**
   When a diff adds a gate that validates a freshly built artifact (a smoke
   test, a post-build self-check, an install precondition), the build command
   that produced the artifact is the sibling: every flag that chose the
   toolchain or configuration for the build (`-cc`, `-cflags`, a target
   triple) must reach the check too, or the check validates a different
   configuration than the one being installed and fails on exactly the
   machines where the explicit choice mattered. Missed on vlang/v#30278
   (medvednikov, pullrequestreview-5531629970): `makev.bat`'s new
   `:smoke_test_updated` compiled hello world with no `-cc` while every build
   of `v_up.exe` passed one, so a `-msvc --local` clone with no bundled TCC
   built a working MSVC compiler and then refused to install it, because the
   driver's implicit default (bundled TCC, then gcc) was absent. Fix: one
   variable (`updated_vflags`) set beside every build of the artifact and
   reused by the check. The mechanical check is the harness test
   `test_install_smoke_tests_with_the_toolchain_that_built_the_compiler` in
   `cmd/tools/makev_test.py` (fails on `531110823f` for all five install
   routes); add one parity row per gate, with the build line as its sibling.
   **The sibling can share a NAMESPACE with the new code, not only its logic.**
   When new code allocates a name, id, slot or key, compare the set it checks
   against every sibling that allocates from the same space, and list what each
   one has already taken by the time the new code runs. A sibling can have the
   same shape and still be a collision source; "follows the same pattern" does
   not answer "can both pick the same value". Missed on vlang/v#31799
   (medvednikov, pullrequestreview-5759552885, P2): the FastC function rename
   mirrored the constant collision pass and was compared with it, but only for
   shape. The constant pass had already allocated `__vf_function_<name>`, so the
   rename reused it and the generated C had conflicting types. Add one row per
   allocator in that space, stating which names the new code's check can see.
   **A helper called for a new purpose gets its own row.** Reusing a function on new
   input (outputs to inputs, one section to another, a rename that widens its role) is
   new code even when no line of the helper changed. Its old callers may have handled
   part of the input beside it, so list every input form the new purpose admits and
   name what handles each. Then grep the fixtures for those forms: a fixture that
   expects the old result for a form the new rule now covers is a question to answer,
   not a settled result. Missed on vlang/v#31407 (medvednikov, comment 6686391495): the
   fixed-input exemption reused the fixed-output helper, which leaves `A` to the pair
   logic, and that logic reads outputs only. So a `u128` input bound through `"A"` got
   an impossible suggestion to clobber `rax`, while
   `asm_raw_clobber_pair_undeclared.vv:54` already showed an `"A"` input being reported.
   **Attribute placement is a parity axis.** For every element kind a parser decides (named
   field, embedded field, section switch, comptime block), emit one row for each attribute
   position the spelling allows (leading before the name, trailing after the type, after the
   default) and state, for each flag the attribute can carry (`skip`, `required`), where the
   flag is recorded and what refuses it. A position with no row is a gap, not an omission.

   **Artifact: sibling parity table.** One row per new type/function/branch
   checked against a sibling, six columns:

   | new path | sibling | sibling caller guards | matched behavior | intentional divergence | unresolved divergence |

   - **new path** — the new code, `file:line`.
   - **sibling** — the existing analog it was compared against, `file:line`;
     if none exists anywhere in the codebase, say so here explicitly rather
     than skipping the row.
   - **sibling caller guards** — every condition the sibling's CALLERS check
     before invoking it (a capability gate, platform check, admission
     guard), not just the sibling's own body. This is the column that
     closes the rev-18 gap: `h2_dial_probe_vschannel` mirrored
     `vschannel_h2_do`'s body faithfully but missed the ALPN gate living in
     the sibling's CALLER (`vschannel_ssl_do`) — a body-only parity check
     has no column that would have caught it; this one does.
     **A sibling's guard can also live DOWNSTREAM, in the stage that reads its
     output, so list those here too.** If new code decides at an earlier stage
     than the sibling does, name each fact the sibling only knows later, and
     keep the decision for that stage. Missed on graphify#161 (5 findings): the
     `xs.map(<selector>)` recipe returned at extraction, while its siblings
     `mapit:` and `mapto:` are steps `follow_steps` applies after checking the
     receiver is an array. A program's own `Stream.map` was typed as an array,
     and `[]T` lost array-ness. The parity row read "`kids.len == 2`, composes
     steps": it compared what the paths produce, not what the new one drops.
   - **matched behavior** — what the new code correctly mirrors. This is
     positive evidence the comparison actually happened, not just a
     negative-findings list.
   - **intentional divergence** — a difference from the sibling that is
     deliberate and justified; state the reason inline (e.g. "sibling
     pools the connection, this path is one-shot by design").
   - **unresolved divergence** — a difference with no stated justification.
     This is the actual finding column: every row with a non-empty entry
     here is a Phase 1 candidate, triaged in Phase 2 like anything else.

   State "none" in matched behavior / intentional divergence / unresolved
   divergence individually where genuinely empty — do not omit a column.

8. **Declare what this review does NOT cover.** Effort-level constraints,
   files excluded from the full-file read, angles skipped, matrix sections
   not walked, detectors not run — every deliberate exclusion must be named,
   not left for a reader to infer from absence. **Artifact: negative
   evidence / skipped areas.** A silent gap reads as "checked and clean"; a
   stated gap reads as "not checked" — these are different claims, and only
   one of them is true when a step was skipped.

### Phase 0 checklist — produce this before starting Phase 1

**STOP. Do not start Phase 1 until every line below has a real answer.** A
line left blank — instead of filled in, or explicitly marked "N/A"/"none" —
means Phase 0 is not finished. This is the first, local place these
artifacts get written down; producing them here, right after doing the work,
is what makes them reliable — reconstructing the same list from memory at
the end of the review (Output format's Artifacts block) is exactly the
recall-driven failure mode this skill has repeatedly found unreliable.

```
- [ ] Base branch: <name> (gh pr view / git remote show)
- [ ] Diff scope command: <command actually run>
- [ ] Files classified: <N NEW, M MODIFIED>
- [ ] Review mode: <Lite/Standard/High-risk/Regression — files/domains that justify it>
- [ ] Full-file read: <files read in full, or "none required">
- [ ] Per-file contract paragraphs: <count> (or "N/A — no file required a full read")
- [ ] Repeat-offender list: <n rows> (or "none")
- [ ] New type/function contract list: <n rows> (or "none")
- [ ] Sibling parity table (new path / sibling / sibling caller guards / matched behavior / intentional divergence / unresolved divergence): <n rows> (or "no new code requiring a sibling check")
- [ ] Model ledger (Angle K): <one row per function that models another tool: rounds with confirmed findings, added/removed clauses; two in a row means ask the allow-list question before fixing> (or "no model of another tool in this diff")
- [ ] Accepted-vocabulary inventory (Angle K): <n entries, from which old-code lists> (or "no new or widened rejection in this diff")
- [ ] Mutation log (Angle J): <one row per added `||`, `&&`, `if` guard, early return, and carried-state boundary: mutation command, test that fails, result> (or "none — no added conditions")
- [ ] Exclusions declared: <what and why> (or "none — full scope covered")
```

Carry this checklist forward verbatim into the Output format's Artifacts
block at the end of the review rather than re-deriving it there.

---

## Phase 1 — Find candidates (run inline, no sub-agents)

**Before working through the angles below, spend one pass with NO checklist at
all.** A structured walk through A–I is good at guaranteeing known bug classes
are never skipped, but by construction it cannot surface a shape nobody has
written a bullet for yet — every genuinely novel finding in this corpus was
missed by a COMPLETED A–I pass, not caught by a skipped one (vlang/v#27643
round 5, pullrequestreview-4631763931: 4 of 6 findings were bug shapes with no
existing angle at all). Read the diff (and the full files from Phase 0) once,
deliberately setting aside anything already decided or discussed earlier in
this session — no "we already agreed this design is fine," no assumed
context — and ask only: if a stranger were seeing this cold, with no checklist
and no memory of why any of it was written this way, what's the least obvious
way it breaks? Write down any candidates this produces before moving into the
structured angles; they get triaged in Phase 2 exactly like the rest. This is
not the same exercise as Angle D's full-file read below — Angle D still asks a
list of specific sub-questions; this pass asks none.

**Run the full detector batch next, before working the angles by hand.**
`bash "${CLAUDE_PLUGIN_ROOT}"/skills/code-review/run_detectors.sh` runs every applicable
mechanical check against the diff in one pass. Detector output is a set of
candidates requiring verification, not automatic findings — a flag still
needs a triaged CONFIRMED/PLAUSIBLE/REFUTED disposition in Phase 2 like
anything else. **Artifact: detector run log.** Record the command actually
run and its output (or the specific reason a detector could not run — e.g.
platform-gated, file type not present in this diff). A detector that exists
but was never invoked this review is the single most common way a "must"
rule goes unexecuted; the log is what makes that visible instead of assumed.

Work through every angle yourself. For each angle, surface up to 6 candidates
(uncapped in High-risk/Regression mode — see Phase 0's Mode Selection) with
`file`, `line`, a one-line `summary`, and a concrete `failure_scenario`. Pass every
candidate with a nameable failure scenario through — silently dropping half-believed
candidates is the dominant cause of misses.

### Angle A — New-code line scan
Read every added/modified line. For each line ask: what input, state, timing, or
platform makes this wrong?
- Inverted/wrong condition, off-by-one, nil/zero deref, wrong-variable copy-paste
- Error swallowed in `or {}`, missing propagation via `!`
- **Side effect after a chained call that may not return:** when code wraps or
  replaces a callback/handler and chains to the original (abort/exit handlers,
  signal handlers, cleanup hooks), do every side effect it needs (diagnostics,
  flushes, state writes) BEFORE the chained call, and read the original for
  paths that never return (spin loops such as Boehm's `GC_LOOP_ON_ABORT`,
  `abort()`, `exit()`, `longjmp`). Missed on vlang/v#28914
  (pullrequestreview-5309842842): `internal_gc_abort_to_stderr` called
  `GC_default_on_abort(NULL)` first, so with `GC_LOOP_ON_ABORT` set the fatal
  message never reached stderr; the original handler prints first, loops last.
- Lock ordering: what locks are held when this line executes? Is that order
  consistent with the declared nesting in the file header?
- Concurrent access: is each field accessed under its declared guard?
- **Duplicate-signature closures capturing the same variable (V compiler gotcha):**
  when a function spawns/calls two or more inline closure literals with an
  IDENTICAL parameter-list type (e.g. `fn [s] () bool {...}` appearing twice in
  one enclosing function, even in different branches where only one executes at
  runtime), V's closure codegen can conflate their capture contexts — the second
  closure silently observes only the first one's stale, closure-creation-time
  snapshot of the captured variable, not live updates. This is NOT visible from
  a `voidptr()` cast test (that fails for a WORKING closure too — it's an
  unrelated static-typing quirk, not evidence of the bug) and is invisible in a
  single minimal repro with only one such closure; it only reproduces with TWO
  same-signature closures declared in the same function. When you see this
  pattern, verify empirically (bump the captured value from another thread
  after a measured delay, assert the closure observes it) rather than trusting
  that "it's the same mechanism as the other closure that already works."
  Fix: give `s` (or whatever is captured) as an EXPLICIT PARAMETER to plain,
  non-capturing named top-level functions instead of closure literals — this
  sidesteps the conflation entirely. Missed while implementing a fix for Codex
  P1/P2, vlang/v#27643 pullrequestreview-4630174759: `h2_stream_timeout_watchdog`
  was spawned twice from `do_on_stream` (upload phase, response phase), each
  with a `done fn [s] () bool {...}` and (newly added) `activity fn [s] () time.Time
  {...}` closure; the response phase's `activity` closure always returned the
  connection's INITIAL last-activity snapshot, silently defeating the intended
  fix (an idle-timeout reset on response progress) until refactored to named
  functions (`h2_response_phase_done`/`h2_response_phase_since` taking `s
  &H2MuxStream` explicitly).
- **C-interop resource threaded through a struct field, not just a local
  variable, needs the SAME missing-`.free()` scrutiny as a bare local.** A
  type with a documented manual-free contract (`ecdsa.PrivateKey`/`PublicKey`
  wrapping an OpenSSL `EVP_PKEY*`, no GC backing, no finalizer) leaks just as
  surely when it's bundled into a struct field and RETURNED to a caller that
  discards the struct via `_`, as when a bare local var is never freed — but a
  discard-via-`_` at a distant call site produces no diff-visible line naming
  the leaked resource at all, so this shape survives even a careful read of
  the constructor's own call site. Whenever a helper function returns a
  struct containing a manual-free resource, enumerate EVERY caller (not just
  the ones a diff happens to touch) and confirm each either captures-and-frees
  it or forwards it to something that will. This is the same failure mode as
  the plain missing-finalizer case below, one level of indirection removed —
  and mechanical detectors for the plain case (grep "does `.free()` appear
  anywhere for this variable name") are structurally blind to it, since the
  freed identifier (`server.priv_key`) is textually different from the
  constructor's own local variable name (`server_priv`). Missed on
  vlang/v#27680 (found by CI's `sanitize-address-clang`/`sanitize-address-gcc`
  LeakSanitizer jobs, not Codex, not `/vreview`): 7 of
  `tls13_handshake_test.v`'s test functions discarded a returned
  `FakeServerHandshake` (whose `priv_key` field is a real `ecdsa.PrivateKey`)
  as `_`, while 5 sibling call sites in the SAME file already captured it and
  freed it correctly — a sibling-parity gap (Phase 0 step 7) within one
  file's own test helpers. **This one-hop struct-field-threading case IS
  mechanically checkable** — do not assume it needs real data-flow/alias
  analysis before trying: `detect_struct_wrapped_resource_leak.v` resolves
  it with two chained greps (struct field of the resource type → its
  enclosing struct → every function returning that struct and which position
  → every call site's binding at that position), no interprocedural analysis
  required. What genuinely WOULD need deeper analysis — and this detector
  does not attempt — is the resource being re-aliased to another variable
  before the free, nested two-plus struct levels deep, or consumed by a
  caller in a DIFFERENT file. See reference/code-review-misses.md for the full
  breakdown, the corrected count, and why the first framing of this as
  "needs real data-flow tracing" overstated it.
- **Unshared getter return (V-specific):** V's plain array/map assignment
  shares backing storage rather than copying it -- a public getter whose body
  is a bare `return r.field` (no `.clone()`) hands the caller a live,
  mutable alias to internal state, even when the getter's own doc comment
  promises a "snapshot" or "copy". `mut x := receiver.getter(); x[0] = y`
  then silently corrupts the receiver's own state. Run the mechanical
  detector, do not eyeball -- it's an enumerate-and-verify aid (a struct
  return type is flagged even though the detector can't see whether that
  struct itself contains array/map fields, so confirm each candidate by
  hand; a plain value type like an enum is a safe, dismissible candidate):
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_unshared_getter_return.v <file>`.
  Missed on vlang/v#27880 (Codex round 4, three rounds after the file was
  first written): `CryptoStreamReassembler.data()` returned `r.received`
  directly; a caller doing `mut d := r.data(); d[0] = x` corrupted the
  reassembler's own CRYPTO transcript, despite its own doc comment saying
  "this is a growing snapshot". Pointing the newly built detector at the
  rest of the module immediately found two more, still-open instances one
  file away (`Tls13ClientHandshake.application_secrets()`/
  `handshake_secrets()`, each returning a struct with `[]u8` secret
  fields) -- proof the detector generalizes past the one instance it was
  written for, not just re-detecting the original. Root cause of the miss:
  the repeat-offender full-contract-re-derivation rule (Phase 0 above) was
  being applied only to functions with a fresh diff that round, not to
  every function in a file that already qualified as a repeat offender --
  `data()` was never touched by any fix, so it was never individually
  re-examined across three separate review rounds on the same file.
- **Lenient parse used as validation (V-specific):** V's `string.int()`,
  `.u64()`, etc. stop at the first non-digit and return the leading number
  (`'200 OK'` → 200, `'12x'` → 12, `'abc'` → 0); they do **not** reject trailing
  garbage or signal failure. Never treat a successful parse as format validation.
  When parsing untrusted input (a protocol field, header value, user string) and a
  later check assumes a clean value, verify the raw string first (exact length,
  digit-only charset). Missed on PR #27413: `:status` validated via `f.value.int()`
  accepted `'200 OK'` as 200 and delivered a malformed response as success.
- **A missing map key reads as the value type's zero value (V-specific):** `m[k]`
  on a `map[K]Enum` returns the enum's first member when `k` is absent, not an
  error. A guard written as `m[k] != .some_kind` therefore treats an undeclared
  key as that first member. Any check that reads a map of enum kinds (declared
  kinds, flags, categories) must test membership (`k in m`) before comparing the
  value. Missed on the fastc `$new(T)` lowering (`declared_kinds`, first member
  `struct_`): `$new(int)` passed the struct guard and built a value that the
  guard was meant to reject. Grep every `m[...] ==`/`!=` on a map whose value
  type is an enum and confirm each one is guarded by `in` or is provably keyed.
- **Guard completeness (else-branch correctness):** For every new `if`/guard the
  diff introduces, name the invariant it enforces, then trace what happens when the
  guard rejects the value. Does the else branch leave the caller in a well-defined
  state, or does a "success" path still fire and deliver a zero/default that looks
  like success? Never treat "the guard didn't set the field" as "the field was set
  and valid." Ask: is the downstream consumer protected, or does it silently receive
  a zero-value and proceed? Missed on PR #27413: `all_digits(f.value)` guard added
  to `:status` parsing in `h2_conn.v`, but `got_headers = true` still fired on
  rejection — caller received `status == 0` with no error. Run the detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_status_fallthrough.v <file>` (for a past revision: `run_detectors.sh --at <rev> <file>`)
  (exits 1 if `:status` guard is present but `got_headers = true` is reachable
  without an error return when the guard fails).
- **Singleton wire field extracted in a loop (validate EVERY occurrence):** when a
  loop over repeated header fields assigns a value that must be singleton
  (`content_length = f.value.int()`, `method = f.value`, …), the last occurrence
  silently wins. A field that is repeatable on the wire but must appear at most once
  (content-length, the request pseudo-headers) needs a duplicate/conflict check, not
  a bare assignment. Missed on PR #27569: `build_request` validated only the last
  `content-length`, so `content-length: 5` then `content-length: 0` was accepted
  (RFC 9110 §8.6 — differing duplicates are malformed). Ask of every `x = f.value`
  in a header loop: "what if this field appears twice with different values?"
- **Error code dropped when carried across a thread/struct-field boundary:**
  when an `IError` caught in one `or {}` block must be replayed later — via a
  singleflight result struct, a deferred callback, a stored "last error" field
  — extracting only `.msg()` into a `string` field and reconstructing with
  plain `error(...)` silently discards `.code()`. Outer retry logic
  (`request.v`'s `is_no_need_retry_error`) decides whether to give up early
  based on specific codes (`net.err_connect_timed_out`, `net.err_timed_out_code`,
  …); losing the code turns a fundamentally hopeless failure into one that
  retries up to `max_retries` times. Grep for a `string`-typed error field with
  no sibling `int`/`_code int` field on the same struct, and for any
  `error(some_var.msg())` where `some_var` came from a caught `or { ... }`
  block rather than being constructed fresh in this function. Missed on
  vlang/v#27643 (Codex P2, pullrequestreview-4627654418): `H2DialCall.err`
  carried only the message; `h2_dial_failed` reconstructed via `error(msg)`.
  Fix: thread the `IError` itself (or its `.msg()`+`.code()` pair) through,
  reconstructing with `error_with_code(msg, code)` when `code != 0`.
- **A NEW cross-cutting error-classification requirement must be threaded
  through EVERY producer of that failure class, not just the one call site
  the finding named.** This generalizes the bullet above from "one struct
  field losing a code across one boundary" to "one FAILURE CLASS needs one
  consistent code across the whole codebase." When a fix introduces a new
  portable/classified error code so a shared consumer (retry logic,
  a caller-facing error message) can recognize a failure uniformly, grep
  every OTHER place that can produce the SAME logical failure — every TLS
  backend, every parser, every async path — and confirm each one maps into
  the SAME code, not just the backend the original report touched. Missed
  repeatedly on vlang/v#28406: a "certificate validation failed, don't
  retry" error code had to be independently re-applied across `net.mbedtls`,
  `net.openssl`, SChannel, HTTP/3's async path, pooled/waiter error
  delivery, AND several distinct mbedTLS failure sites (CA-bundle parse,
  client-cert/key parse, SNI setup) — each missed instance was a SEPARATE
  external-review round on the same PR, not one review that swept the
  whole failure class at once. Before considering such a fix complete: list
  every producer of the failure class by grepping the classified error
  code's own name/constant, not just the file the finding cited.
- **Every new/modified `pub fn` must carry a doc comment (mandatory, not
  optional-if-obvious):** this repo's own `report-missing-fn-doc` CI check
  enforces this, and AGENTS.md's style rule ("Doc comments start with the
  function name") only specifies the FORMAT once a comment exists — it does
  not by itself remind a reviewer that EVERY pub fn needs one. For every
  `pub fn`/`pub struct` method the diff adds or whose signature it changes,
  confirm a doc comment starting with the function name immediately precedes
  it. This is a pure grep, not a judgment call — do not skip it because the
  function "looks self-explanatory". Missed 3 times in one round on
  vlang/v#27881 (Copilot review pullrequestreview-4885595852):
  `new_packet_number_spaces`, `KeyUpdateState.current_phase_bit`, and
  `new_handshake_completion_state` were all new/existing pub fns with no doc
  comment, something CI itself would have flagged, that a normal Angle A
  pass reading "new-code lines" for logic bugs walked right past because it
  wasn't looking for absence-of-comment as its own category of defect.
- **A path interpolated into `os.execute()` needs `os.quoted_path()`, not a
  hand-written quote character — and "I tested it" must name WHICH shell-
  quoting property was tested.** Shell quoting has (at least) three
  independent properties: word-splitting on whitespace, glob expansion, and
  parameter/command substitution (`$VAR`, `` `cmd` ``, `$(cmd)`). POSIX
  double quotes block only the first two; POSIX single quotes (what
  `os.quoted_path()` emits on non-Windows) block all three. A literal
  `"${value}"` wrapper inside an `os.execute('...')` string looks safe and
  passes an argv-boundary probe (does the shell still see it as one
  argument?) while remaining open to `$`/backtick expansion if `value` ever
  contains those characters — which a repo checkout path can, without any
  attacker involved. Before treating a quoting fix as complete, enumerate
  all three properties and confirm the chosen wrapper defends against each,
  rather than testing the first one that comes to mind and calling a green
  result sufficient. Missed on vlang/v#28185 (Codex round 2,
  pullrequestreview-5044197146) on my own prior-round fix
  (pullrequestreview-5033468734): I'd fixed word-splitting on every
  `os.execute()` path argument in `heap_attr_struct_alloc_test.v` except a
  compound `-path "${vlib_dir}|@vlib|@vmodules"` value, deliberately left
  hand-quoted because an argv-boundary probe said it was fine — that probe
  never touched substitution at all. See reference/code-review-misses.md for the
  full repro (`echo "${evil}|@vlib|@vmodules"` with `evil='/tmp/repo$HOME'`
  expands to the real home directory; the same value through
  `os.quoted_path()` does not).
  **Escalation rule: if the SAME file/function absorbs a second narrow fix
  for this SAME bug class, stop patching properties one at a time and ask
  whether an existing sibling eliminates the whole class.** `v3.cmdexec.run()`
  (an argv-based `os.new_process()` wrapper — never invokes a shell on any
  platform) was sitting one file away in `secure_command_test.v` the entire
  time; three separate rounds each patched one more shell-quoting property
  (word-splitting, then substitution, then Windows `%VAR%` expansion)
  instead of noticing the pattern and switching tools. See
  reference/code-review-misses.md (the "third round" row) for the full history.
- **A fallback/retry's trigger must encode the case it was written for, not a
  proxy that also matches other inputs.** For every new "if the primary path
  finds nothing, try X" branch, write down the ONE motivating case, then the
  trigger predicate as the code states it, then enumerate every OTHER input that
  satisfies that predicate. Each is a candidate: the fallback now runs for it
  too, usually through a more permissive path than the primary. Two red flags:
  (a) the trigger is "primary returned none" plus a property the motivating case
  merely HAS (the call name contains `__static__`) instead of one only it has
  (the name came from a selective import); (b) the trigger is a WHOLE-PROGRAM
  scan standing in for a caller-local fact ("no module anywhere ends with this
  import name" for "this caller's import names no module") — any unrelated
  match anywhere flips it. Missed on graphify#149 (adversarial review round 1,
  2026-11-01): a bare-name retry meant for `import zmod_foo { Foo }` fired for
  every qualified static call into a module outside the tree, linking
  `extmod.Config.new()` to an unimported module's `Config.new`; and an
  unrelated `other/zmod_foo/` directory turned it off, losing a call master
  resolved. Phase R of the fix only exercised the motivating case.
- **Widening what reaches a permissive tier is a behavior change for every
  input newly let through.** When a diff makes MORE inputs reach an existing
  lenient fallback (a unique-name match, a first-match lookup, a default
  branch) — by stripping more wrapper layers, admitting more symbol kinds into
  a candidate table, or loosening a prefix test — list what newly reaches it
  and ask what the lenient tier does with each. This is the inverse of
  "impact analysis before narrowing": the new code is correct for its
  motivating input, and the regression is the lenient tier acting on the
  others. Missed three times on graphify#149 (round 3): `callee()` stripping
  every index level let `get().table[0][1](3)` reach the global unique-name
  tier as a method call `table`; a `starts_with('fn')` gate admitted a global
  typed `fnv1a.Sum` as callable.
- **An empty result proves only what its producer can see.** When new code
  concludes something from an empty or missing result ("no instances", "no
  callers", "nothing matched"), read the code that fills it and list everything
  it skips. Each skipped case reaches the new branch with the opposite truth.
  If "none" and "could not tell" can differ, track them apart. Missed on
  graphify#161 (adversarial round 1, 2026-11-04, 2 findings): an empty instance
  list made `str()` on a `T` undeclared, but `collect_call_sites` records only
  parameters typed `T`, `[]T` or `fn () T`, so `g_map({'a': Foo{}})` with a
  `map[K]V` parameter called `Foo.str` and was claimed as V's. The inline review
  had noted the case as a limit, imagining only callers outside the tree.
- **A new rule must not overwrite something more precise.** For each new line
  that replaces a value, type or state, ask what it holds before that line, for
  every input and not just the motivating one. If it can already be more exact
  than the new fact, the new fact is a fallback, not a replacement. When a
  comment gives the reason for an exemption, check who else that reason covers.
  Missed on graphify#161 (4 findings): `$if v is $map` replaced any variable's
  type with builtin `map`, so `type Own = map[string]int` lost its own `clone`
  and `map[string]Foo` its elements. The comment said an alias of a map has its
  own methods, and exempted only a variable typed `T`.
- **A helper given a new kind of input was only ever right for the old kinds.**
  When new code passes a helper a form it never received before, read the helper
  against that form. Missed on graphify#161: `fn_return` took the text after the
  last `)`, right for a parameter's function type, wrong for a literal's
  `fn () fn () Foo` (`Foo`) and `fn () (int, Foo)` (none).
- **A recursive walk that calls itself twice on the same child is
  exponential in nesting depth.** In any tree/AST walker, when a new branch
  re-calls the walker on a child that an earlier line already walked (a
  "fallback to the else branch" after a loop that already computed it),
  compute it once. Ask of every recursive call the diff adds: can this node
  nest inside itself (`$else $if` chains, nested expressions), and does each
  level call the walker on its child more than once? Missed on graphify#149
  (round 1): the `$if`-value fallback recomputed `recipe(kids[1])`, doubling
  the work per `$else $if` level (depth 40: 3.1 s vs 0.34 s once fixed).

- **Carried state needs a reset at every boundary the loop can cross.** When a loop
  stores a value from one token and consumes it at a later token (a pending flag set by an
  attribute and read by the next field), list every token that can sit between them
  (separators, section keywords such as `mut:`/`pub:`, a closing brace, another attribute
  group) and state, for each, whether the value is consumed, kept, or cleared. A boundary
  with no answer is a candidate. Missed on vlang/v PR 31981 (adversarial r3,
  2026-11-07): the pending `skip` flag survived `mut:` and was never tested there.
  Accumulation is also a boundary: `x = x || y` and `x = y` differ exactly when two sources
  feed one slot. Test both, with two sources on the same slot.
- **A predicate matched by token text must check the token's position, not only its
  spelling.** A flag set when a bare word such as `skip` appears anywhere inside an
  attribute misfires on `@[foo: skip]`, where `skip` is an argument. Before accepting a
  match on a name, list the positions the same token can occupy (attribute name, argument,
  string-content, enum member, field name) and check the match against the one it means.
  Missed on vlang/v PR 31981 (adversarial r3, signatures.v:70): the leading-attribute path
  started calling a helper that matched that word anywhere; the trailing path already did.
- **A check on a type name must run on the form the producer writes, not only the resolved
  one.** A new branch that asks "is this a callable" (or boxed, pointer, enum) on the
  resolved layout (`underlying_alias_type(typ)`) misses a named alias whose layout no longer
  carries the name the check reads. For every new name-based predicate, write the named
  alias of the type next to the unnamed form, and run both. Missed on the fastc `$zero`
  callable branch (`comptime.v:1540`, rev 96): `type Cb = fn (int) int` followed by
  `$zero(Cb)` failed, though the unnamed `$zero(fn (int) int)` worked; `/vreview` read the
  branch and the unnamed test only.

### Angle B — Removed-behavior audit
For every line the diff **deletes or replaces**: name the invariant it enforced,
then find where the new code re-establishes it. If you can't, that's a candidate.
- Removed guard → now-reachable bad state
- Dropped error path → silent failure on a reachable code path
- Narrowed validation leaving a gap
- Rerouted case: when a value moves from one branch to another (an added member
  of an `in [...]` list, a new early return), list the forms the old branch
  handled and confirm the new one handles each. No line is deleted, so read the
  branch it left. Missed on graphify#161 (2 findings): adding `.lock_expr` to the
  tuple path lost the `#i` path that typed `a, b := rlock s { s.pair() }`.

### Angle C — Cross-file caller/callee trace
For each changed function, grep for its callers. Does the change break a
precondition, return shape, timing assumption, or ordering dependency at any call
site? Also check callees: does a parallel change in the diff make a downstream
call unsafe?

**A renamed EMITTED symbol has "callers" too: every place the generator
spells that name, not only the V callers of the function you changed.** When
a diff changes the C (or any target-language) name a definition is emitted
under — an entry point, an exported wrapper, a mangled helper — the callers
to trace are not the V functions that invoke the generator, but every
rendering path that produces a reference to the renamed symbol: calls,
function values, prototypes, `&name` takes, string tables keyed by C name.
Grep for the OLD spelling as a KEY or string literal across the generator
(`'main'`, `function_c_names[key]`, `fastc_c_function_name_for_key`) and
confirm each path resolves through the same function the definition does;
a rename applied at the definition site only is wrong by construction when
a second resolver exists. Fix shape: put the platform/mode-specific name
into the ONE resolution funnel both the definition and the references call,
never into the definition's own branch. Missed on vlang/v#30672
(medvednikov, pullrequestreview-5541265161): the fastc entry became
`wmain` on Windows at its definition in `parse_function`, while every
reference (`fn again() { main() }`, `f := main`) still rendered `main`
through `c_function_name_for_key('main')` — an unresolved symbol under the
MinGW `-municode` startup the PR was written for. The round's own `/vreview`
Angle C traced the V callers of `fastc_synthesized_main` and stopped there.
Regression test: `vlib/v/gen/fastc/windows_entry_call_test.v` (fails on
`d2c3084ada`, passes once `c_function_name_or` owns the entry name).

**"Which files call this function" is a graph-reachability question, not a
grep-scope question — prefer a real call graph when one is available.** A
single-file grep for a function's callers only ever proves "no callers in
THIS file"; it says nothing about callers elsewhere, and treating that as "no
other callers" is an unverified assumption, not a finding. When the Graphify
MCP (or its standalone CLI, `graphify explain <fn> --graph <graph.json>` —
no MCP restart needed) has a graph extracted for the branch/worktree under
review, use it to get the REAL whole-codebase caller list before asserting a
function's callers are confined to one file. Concretely proven necessary,
not hypothetical: `mbedtls.build_certificate_chain` (vlang/v#27680) is called
from SIX different files across two modules — a single-file check on any ONE
of them sees only a fraction of its true callers. Note Graphify's own graph
is built from whatever source tree was pointed at extraction time — a graph
built against `master` will silently return "no symbols match" for code that
only exists on an unmerged branch/worktree; confirm which tree is indexed
(`graphify overview`) before concluding a symbol doesn't exist. See
reference/code-review-misses.md for the full worked example (`detect_struct_wrapped_
resource_leak.sh`'s `GRAPHIFY_EXE`/`GRAPHIFY_GRAPH` mode) and for the
distinction this drew out: a call-graph question ("who calls X") a symbol
graph answers directly, versus a local-dataflow question ("does this specific
variable get reassigned before that free call") which it structurally cannot
— Graphify's own symbol-kind list has no local-variable node at all, so that
class of question still needs a real AST/dataflow pass, not a graph query.

**Every reader of an event must apply the rule (the divergent-reader miss):** When
the diff adds/changes handling for a protocol event (a frame type, a message), the
same event may be read in more than one place. Grep every caller of the low-level
read (`read_frame`, `recv`, the socket read) and confirm the new rule applies on
each. A second reader that hand-picks a subset ("service control frames, ignore
anything else defensively") is the smell — any rule added to the main dispatch
silently fails there. Missed on #27589: the h2 server reads frames in TWO places —
`serve`→`dispatch_frame` and `send_body`→`pump_for_window` (the flow-control
stall). PR2 added refuse/idle/closed handling to `dispatch_frame` only, so a HEADERS
arriving during a stall went through `pump_for_window`, which dropped it (HPACK
desync, no refuse). Fix: the second reader DELEGATES to the one dispatch. Run the
detector: `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_pump_delegates_dispatch.v <file>`
(flags `pump_for_window` reading frames without `dispatch_frame`; exit 1 on
`6024da169c`, 0 after). **Rule: prefer one dispatch funnel over N parallel readers;
when there must be two, the second delegates to the first.**

**Cross-file protocol handler parity (the empty-arm miss):** When the diff
touches a function that dispatches on a protocol event via `match` (e.g.
`apply_peer_settings`, `apply_settings`, `dispatch_frame`, any match over frame
type or settings ID), find every sibling function in other files that handles the
same event. Compare every `match` arm: an arm that has executable code in the
reference implementation but is comment-only (or absent) in the reviewed function
is a definitive miss — the comment convinced the author nothing was needed, but
the reference file proves otherwise. Canonical missed pattern: `H2MuxConn.
apply_peer_settings` had a comment-only `h2_settings_header_table_size` arm
claiming "nothing to constrain"; both `H2Conn.apply_settings` and
`H2ServerConn.apply_settings` had the same arm with three lines of executable code
setting `encoder.pending_max_table_size` — the mux path was silently skipping the
RFC 7541 §6.3 Dynamic Table Size Update requirement.

**Mandatory mechanical gate** — run for every diff touching an `apply_*settings`
or frame-dispatch function. Do not eyeball; do not skip:
`v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_settings_arm_parity.v <file>`
Exits 1 when any `h2_settings_*` arm in the reviewed file is comment-only/empty
while a sibling `h2_*.v` file has executable code for the same arm. Exits 0 when
all arms with code in one file also have code in siblings (or the arm is
intentionally empty everywhere). Repro: exit 1 on `5be13c6431`, exit 0 after fix.

**Sync vs mux client parity (response validation):** The two HTTP/2 client paths
— synchronous `H2Conn.read_response` (h2_conn.v) and multiplexed
`H2MuxConn.on_response_headers`/`on_response_data` (h2_mux_conn.v) — must enforce
the SAME response-validation invariants. They drift because they are written
separately. When either path adds or has a protocol check, verify the other has
the equivalent. The mux path is usually the stricter/more-complete reference;
audit `read_response` against `on_response_headers` for EACH of: `:status` missing
/ non-3-digit / `<100` / `>599` / `==101`; a 1xx interim carrying END_STREAM;
trailers (a second HEADERS after headers-done) lacking END_STREAM; DATA before the
first HEADERS; DATA after END_STREAM. A gap is a hang (loops in `next_frame()`
waiting for a frame a well-formed stream can no longer send) or a silent-accept of
a malformed response. Canonical missed pattern (commit `a6884cef9d`, Codex on
#27413): `read_response` discarded a 1xx HEADERS with a bare `continue`, so a 1xx
+ END_STREAM hung the request; the mux path already rejected it. **Lesson: when a
reviewer flags ONE instance of a parity gap, audit the WHOLE surface — Codex
flagged only 1xx+END_STREAM, but `read_response` was missing 5 of the mux path's
response-validation invariants.** Mechanical gates:
`v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_h2conn_1xx_end_stream.v` (1xx interim
branch must reject `frame.end_stream` before `continue`) and
`v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_h2conn_response_parity.v` (read_response
must enforce trailers-END_STREAM, DATA-before-HEADERS, and `:status` range/101).
Both exit 1 on the pre-fix commits and 0 after.

**Parity is bidirectional — also audit what the SYNC path does that the MUX path
doesn't.** The mux path isn't always the more-complete reference: it can drop
response *data/metadata* the sync path preserves, not just validation checks.
`H2Conn.read_response` appends non-pseudo trailer fields (a second HEADERS block)
to `H2ClientResponse.headers`, but `H2MuxConn.on_response_headers` HPACK-decoded
the trailer block and dropped every field, only marking the stream ended — so
`grpc-status`/`digest`/etc. were silently lost while the stream "completed
normally" (Codex P2 `a65240ffb0`, discussion_r3477245531). Subtlety: `wait_response`
snapshots `resp_headers` once at headers-done, so trailers need a separate
per-stream `resp_trailers` list flushed into `resp.headers` at stream-end. Gate:
`v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_mux_trailers_preserved.v` (the trailers
branch must append the decoded fields, not merely set `s.ended`).

**A changed REPRESENTATION has consumers too: every reader that parses the
value, not just the producer you edited.** The renamed-emitted-symbol rule above
is one case of a general one. When a diff changes the shape of a value that
other code later takes apart — an edge's target string (`Kind__static__m`
becoming `mod.Kind__static__m`), an id format, a key layout, a recipe step —
grep the RAW shape across the whole tree (`__static__`, `all_before('@')`,
`split(sep)`), not the function you changed, and confirm each reader handles
the new form. Readers that branch on the shape (`if to.contains('.')`) are the
likeliest to silently take a different path. Missed on graphify#149 (round 1,
two findings): qualifying selective-import static calls changed `Edge.to`, and
`call_result` (which types `x := Foo.new()`) and `generated_enum_mod` both
took the qualified path and lost what the bare form had resolved; only the
resolver the diff was written for got a compensating fallback.

**A value that used to be empty has readers too: the ones that test for empty.**
When an expression that returned nothing now returns a weak answer, grep for
`!= ''`, `or {`, "first non-empty" loops and similar, as well as readers of the
new text. Those readers took the empty value as "ask someone else". Also read
what the weak answer does when followed further, and check any comment claiming
it is harmless. Missed on graphify#161 (2 findings): a map literal stating no
type became bare `t:map`, so `map_entries_recipe`'s first-non-empty loop stopped
on it and hid a later entry's `Foo`; and its `keys().first()` reached builtin's
erased `voidptr`, under a comment saying its methods don't depend on the types.

### Angle D — Full-file holistic (the Codex angle)
**This angle reads the whole file, not just the diff.** It is the primary fix for
findings our incremental review misses.

For each touched file, after reading it in full:
- What invariants is this module supposed to maintain? Which functions guarantee
  them, and does the diff weaken any guarantee?
- For functions **not** in the diff: do they access state the diff changes? Is that
  access still correct under the new invariants?
- Goroutine/thread lifecycle: for every goroutine spawned, trace all exit paths.
  Is there a path where the goroutine blocks forever (no interrupt, no timeout)?
  Is there a path where the owning resource is closed before the goroutine exits?
- Resource cleanup on error: for every early `return err`, are all acquired
  resources (locks, file handles, refs) released before the return?
- Lock-guarded fields: for each field and its declared guard, scan the whole file
  for accesses outside that guard.
- **Admission-gate invariant (the cross-function miss):** Find every function that
  gates access to a resource — a boolean check like `can_take_new_request()`,
  `can_use_conn()`, or any `if !c.shutting_down` guard. List every condition it
  tests. For each condition, enumerate *all* code paths that are supposed to set it
  — including error sub-paths, early returns, and functions that run adjacent to the
  one that contains the primary setter. Flag any path where the system enters a
  state that *should* make the gate return false, but the gate field isn't set yet.
  The canonical missed pattern: gate checks field F in function A; field F is set in
  function B's happy path, but NOT in B's error sub-paths or in a helper C that runs
  before B's setter. Codex found this twice: `can_take_new_request()` missing the
  stream-ID-exhaustion path, and `cancel_stream`'s WINDOW_UPDATE failure not setting
  `shutting_down` before the RST write that eventually does.
- **Flag-contract invariant (the new-setter miss):** When the diff introduces a new
  code path that sets a shared boolean or status field (e.g. `s.send_dead = true`,
  `c.shutting_down = true`), enumerate every function in the file that reads that
  field. For each reader, identify its implicit contract — what OTHER state must also
  be set when the flag is true? (A flag meaning "stream failed" usually implies
  `s.fail()` was called first, which sets the error message that readers extract via
  `send_failure_reason()`.) Verify the new setter satisfies every reader's contract.
  The canonical missed pattern: diff adds `wake_send(s)` which sets `s.send_dead`;
  `send_body_on_stream` sees `send_dead` and calls `send_failure_reason()`, assuming
  `s.fail()` was called first — but the new path never called it, so
  `send_failure_reason()` returned `('', false)` and the valid server response was
  discarded.
- **Central-scheduler aggregator completeness (the new-deadline-field miss):**
  When a struct has ONE function whose job is "compute the single next time the
  caller must act" by taking the min of several independent optional deadline
  fields (a repeated `if x := opt_field { if d := deadline {...} else {...} }`
  merge pattern — a caller-driven event-loop scheduler is the canonical case,
  but any "aggregate N optional timers into 1" function qualifies), a NEW
  deadline-shaped field added anywhere in the same struct is a candidate the
  aggregator must also merge in — grep the struct definition for every OTHER
  `?u64`/`?time.Duration`-typed field alongside the new one, and confirm each
  one's name actually appears inside the aggregator's body. This is the
  DEADLINE-FIELD sibling of "Flag-contract invariant" above (that bullet
  covers a new WRITER satisfying existing READERS' contracts for a boolean;
  this one covers a new/existing WRITTEN field that has NO reader at all in
  the one place required to actually schedule around it) — the two are easy
  to conflate but the fix shape differs: there, you trace what the reader
  expects; here, you trace whether a reader exists in the right place at all.
  Grep-only check, do not eyeball: list every `?`-typed field on the struct,
  then confirm each name appears in the aggregator function's source. Missed
  TWICE on the same code, by two separate reviews: `QuicConn.closing_deadline`
  and `compute_next_timeout()` were both written in the SAME original commit
  (vlang/v#28083 Phase 9) — the aggregator merged `idle_timeout_deadline()`
  and `loss_detection.next_timeout()` but never `closing_deadline`, so a
  connection reaching `.closing`/`.draining` with nothing else armed returned
  `next_timeout = none` and a real caller-driven event loop would never learn
  to call `process_timeouts()` again despite the RFC 9000 §10.2.2 bound being
  correctly recorded. A LATER, targeted Phase-R fix (adding the missing
  `c.closing_deadline = ...` assignment to `enter_draining`) touched
  `closing_deadline`'s WRITE side and fixed the reported symptom (the field
  wasn't being SET) without ever tracing its READ side — the aggregator gap
  predated that fix and survived it untouched, because the fix was scoped to
  the one reported gap, not to the field's whole read/write contract. Only a
  maintainer's own separate "Local AI Review" pass caught the aggregator gap.
  The integration test masked this too: it always had a stale, never-acked
  PTO timer armed (the fixture never constructs ACK frames back to the
  client), so `next_timeout` was coincidentally non-`none` even with the bug
  present — a same-module white-box test that force-zeroes the OTHER sources
  (`bytes_in_flight = 0`) was needed to isolate the true "nothing else armed"
  scenario and get a clean repro.
- **Action-before-flag race (write-then-flag TOCTOU):** When a flag records that a
  network action has happened (e.g. `sent_headers = true` set after the HEADERS
  write completes), there is a window between the action completing and the flag
  being set. A concurrent reader that checks the flag in that window can reach an
  incorrect conclusion (e.g. "HEADERS not sent → request is retryable" even though
  HEADERS may have already reached the server). The fix is to set the flag BEFORE
  the action reaches the transport — under the write lock if the flag is read under
  a lock. Ask: for every flag that records a network action, is the flag set before
  or atomically with the action? Missed on #27413 commit 46d814f5ef: `sent_headers`
  was set after `send_header_block_locked` returned, opening a TOCTOU where a
  concurrent `fail_conn` could see `!sent_headers` and wrongly mark the request
  as retryable even though HEADERS had been sent.
- **Sibling handler scan (the adjacent-arm miss):** When the diff adds a guard or
  fix to one arm of a `match`/`if-else` chain, scan every other arm for the same
  class of deficiency. Fixes applied to one handler are rarely the only handler with
  the problem. Canonical missed pattern: `dispatch_frame` SETTINGS arm got a
  `!handshaked` guard for preface ordering; the PING arm in the same match had the
  identical gap and was never checked. Run the mechanical detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_sibling_arms.v <file> <pattern>`
  where `<pattern>` is the guard/check just introduced (e.g. `handshaked`,
  `flow_size`, `reset_stream`). Output lists every arm with [HAS] or [MISSING];
  review each [MISSING] arm for the same deficiency.
- **Error-scope consistency (the stream-vs-connection miss):** Enumerate every site
  that handles the *same logical error class* and confirm they resolve to the same
  scope. In a multiplexed protocol, a per-stream fault must be a STREAM error
  (RST_STREAM + wake that one waiter), never a `return error` that escapes to the
  connection reader and tears down every in-flight stream. Build a table: for each
  RFC error class (flow control, protocol, stream-closed, …), list every handler and
  whether it does `reset_stream(...)` (stream-scoped) or `return error` (connection-
  scoped); any class handled both ways is a bug. Canonical missed pattern: the stream
  WINDOW_UPDATE overflow path correctly did `reset_stream(.flow_control_error)`, but
  `on_response_data`'s stream-receive-window violation did `return error`, killing the
  whole connection for one stream's fault. Run the mechanical detector — do **not**
  eyeball: `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_error_scope.v <file>` (exits 1
  on any `return error` found inside a reader-thread function; each candidate is
  annotated with its enclosing function name so you can confirm whether it is a
  genuine connection-level fault or a misplaced stream-level error). The detector's
  `READER_FNS` list must include EVERY per-stream handler — on the single-threaded
  *server* that is `on_headers`/`on_continuation`/`on_trailers`/`finalize_headers`/
  `finalize_trailers`/`on_data`, not just the client mux fns. Missed on PR #27569:
  `on_trailers` wasn't in the list, so its "trailers without END_STREAM" `return
  error` (which GOAWAYs the whole connection instead of RST-ing the one stream)
  wasn't flagged — and the detector wasn't even run. When a new per-stream handler
  is added to a protocol driver, add it to `READER_FNS`. (Note: the detector is
  slow on Windows git-bash — per-line subshells — run it in WSL/Linux.)
  **Error-scope is bidirectional.** `detect_error_scope.v` catches a connection
  error (`return error`) that should be per-stream. The INVERSE also misses: a
  per-stream `send_rst_stream` for a fault that must be a CONNECTION error. The
  canonical case is an HPACK `decode()` failure — the decoder mutates the dynamic
  table as it runs, so a failure desyncs it with the peer and corrupts every later
  header block; RFC 9113 §4.3 mandates GOAWAY(COMPRESSION_ERROR), not RST. Missed on
  PR #27569 (`finalize_headers`/`finalize_trailers` RST'd decode failures). For any
  fault that desyncs connection-global state (HPACK table, flow-control accounting),
  ask: "is this per-stream RST really a connection error?" Run
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_hpack_decode_scope.v <file>` (in WSL).
- **Event multiplicity (the bool-for-repeated-event miss):** When the diff
  introduces a boolean flag to record a deferred or pending event (e.g.
  `pending_settings_ack = true`), ask: can this event occur more than once before
  the flag is consumed? A bool is only correct for single-occurrence events; if the
  event can repeat, a counter is required so each occurrence gets its own response.
  Canonical missed pattern: `pending_settings_ack bool` collapsed any number of
  server SETTINGS frames into one deferred ACK — RFC 7540 requires one ACK per
  SETTINGS frame, so N frames before the preface produced only 1 ACK.
- **Accumulating-buffer capacity claims require a drain path (the never-shrinks
  miss):** for any struct field that only ever grows (`buf << data`, no
  reslice/truncate/delete anywhere in the file) but has a byte-size cap
  described in its own doc comment as a "backstop" or "rarely binds in
  practice" defense — check whether that claim is actually TRUE by asking:
  does this field ever get SMALLER? If nothing in the file (or its known
  future caller, per PROGRESS.md/plan docs) ever shrinks it, the cap is NOT a
  backstop on transient/pending data — it is a hard ceiling on the TOTAL
  amount that field will ever hold over its whole lifetime, and the doc
  comment's own "rarely matters" framing is provably false today, regardless
  of what a later phase might add. This is easy to miss because the doc
  comment reads as reasonable and the cap value ("1 MiB is generous") sounds
  plausible in isolation — the miss is in not tracing whether the buffer's
  own lifecycle actually supports the claim. Grep the field name across the
  whole file for anything besides `<<`/append (a reslice assigning a shorter
  slice, `.delete()`, `.clear()`, a separate `discard`/`consume`/`drain`
  method) — if nothing shrinks it, the cap bounds total lifetime size, not
  "buffered but unconsumed" data, and any caller whose legitimate use case
  exceeds the cap (e.g. a single QUIC stream over 1 MiB, an entirely normal
  size) is silently and permanently broken. Missed on vlang/v#27882 (Copilot
  review pullrequestreview-4888843234): `StreamReassembler.received` only
  ever appended; `max_stream_buffered_bytes`'s own doc comment claimed real
  flow control would make the cap "rarely matter in practice," but with no
  drain path at all, the cap WAS the effective total-stream-size ceiling for
  every stream, not a rarely-hit backstop — even fully in-order data hit it.
- **Terminal state protection (the reordered-event-clobbers-terminal-state
  miss):** for any state enum where a specific value is TERMINAL or absorbing
  (the type's own doc comment, or the protocol spec it implements, says so —
  e.g. RFC 9000 §3.2's Receive Stream State Machine makes `Reset Recvd`
  terminal), enumerate EVERY function that writes to that state field, not
  just the one that sets the terminal value. For each OTHER writer, ask: if
  this function runs AFTER the terminal value has already been set (a
  reordered/stray event arriving late is normal in any packet-based
  protocol, not a corruption signal), does it silently overwrite the
  terminal state with something else? A function that promotes state based
  on an unrelated condition (e.g. "enough bytes have now arrived") without
  first checking "is the current state already terminal" will do exactly
  that. Fix: each such writer either no-ops or explicitly rejects once the
  field already holds a terminal value, mirroring how a caller-facing state
  machine is supposed to work at every entry point, not just the one most
  directly associated with reaching that terminal value. Missed on
  vlang/v#27882 (Copilot review pullrequestreview-4888843234, all 3
  instances the SAME finding at 3 lines): `mark_reset_recvd` set
  `.reset_recvd`, but `note_size_known`/`note_data` — triggered by ordinary
  STREAM-frame arrival, unaware that a RESET_STREAM had already raced ahead
  of a reordered STREAM frame on the wire — unconditionally promoted state
  to `.data_recvd` whenever enough bytes had accumulated, with no check for
  the stream already being reset.
- **Lenient-parse, locally guarded (run the detector, don't eyeball):** V's
  `string.int()/.u64()/...` stop at the first non-digit and return the leading
  number (`'200 OK'`→200, `'12junk'`→12); a successful parse is NOT validation.
  Rule: **every parse of a wire-derived value MUST have a digit/charset guard at
  the parse site** (upstream validation is not enough — it can be refactored away).
  Run the mechanical detector, do not scan by eye:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_lenient_parse.v <file>` (exits non-zero
  on any unguarded parse). Missed twice on #27413 — `:status`, then its twin
  `content-length` — because the angle was treated as a thing to remember instead
  of a grep to run.
- **HPACK decode applies to ALL branches of the same function (decode-then-RST):**
  When a function that may decode an HPACK block has multiple branches — including
  error / state-violation branches — every branch that receives a HEADERS fragment
  must route it through the decoder before disposing of the stream. Skipping the
  decode on an "early exit" RST path desyncs the connection-wide dynamic table (RFC
  7541 §2.2) and silently corrupts every subsequent request. Pattern: if a branch
  sends RST_STREAM without first calling `decoder.decode(fragment)`, ask whether
  there is any HEADERS fragment in scope that the decoder has not yet consumed.
  Run `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_hpack_skip_on_half_closed.v <file>`.
- **Decode-then-discard state must be tracked per FRAME TYPE, not per code path:**
  when a fix adds new state to correctly drain in-flight frames for an
  already-terminated stream (e.g. a server-sent-RST tracking map), check EVERY
  frame type that can still carry a HEADERS fragment for that same stream id
  (HEADERS, CONTINUATION) — not just the frame type the original bug report
  happened to mention (e.g. DATA). The stream struct is gone by this point (it
  was deleted to keep concurrency-limit accounting correct), so a further
  HEADERS/CONTINUATION for it needs its own connection-level scratch buffer,
  decoded then thrown away, mirroring the live-stream decode-then-RST pattern.
- **A per-stream scratch buffer must be cleared at the start of each new logical
  sequence, not just accumulated within one:** `trailer_block`/`hpack_block`
  populated once (e.g. a legitimate trailer section, already decoded) and left
  on the stream struct because the stream lingers (response stalled on flow
  control) will be silently redecoded if a LATER, separate HEADERS sequence
  appends onto the same buffer without clearing it first — reapplying the same
  HPACK incremental-indexing insertions twice desyncs the dynamic table. Any
  code path that starts a brand-new HEADERS block on an existing stream (not a
  CONTINUATION of one already in progress) must clear the accumulator first.
- **Stream-id monotonicity is not a proxy for frame ARRIVAL order:** HTTP/2
  guarantees stream IDs are allocated in increasing order, not that a client
  transmits all of stream N's frames before opening stream N+2 — a client can
  legally interleave HEADERS(N+2) ahead of a queued DATA(N) in its own send
  buffer. Never prune a per-connection tracking map/set keyed by stream id using
  "id < highest-seen-id" as a stand-in for "already delivered"; that reintroduces
  exactly the race the tracking structure was built to close.
- **Bump an exclusion-tracking field at the point the exclusion is DECIDED, not
  at the point the excluded/included work happens to run:** e.g. GOAWAY's
  last_stream_id must exclude streams refused purely for concurrency (RFC 9113
  §5.1.2) but include everything else the server "might have taken action on"
  (§6.8) — including a stream still mid-CONTINUATION. Bumping the tracking field
  only inside the function that runs AFTER a HEADERS block fully assembles
  under-reports for any stream an unrelated connection-level error catches
  before that function ever runs. Bump at stream-creation time, gated by
  whatever decides the exclusion, not at stream-completion time.
  Missed on PR #27589 review 4588368602 (Codex): `on_headers` RST-ed post-END_STREAM
  HEADERS without decoding the fragment; fixed with `over_end` flag routing through
  `finalize_trailers` first. Secondary consequence of the same fix: if a decoder-sync
  path sets `c.awaiting_cont`, a client RST_STREAM during the CONTINUATION wait must
  be passed through as a legal stream cancel (RFC 9113 §6.4) not treated as a
  connection error — always special-case RST_STREAM in the `awaiting_cont != 0` guard.
- **Helper generalization must migrate ALL pre-existing consumers of the old
  idiom (the un-migrated-sibling miss):** when a fix generalizes a helper
  function (e.g. `classify_stream`) to subsume a condition that raw code
  elsewhere in the file used to test directly (`in c.locally_reset`), grep the
  WHOLE file for every OTHER occurrence of that raw idiom the moment the
  generalization lands — do not wait for a reviewer to find the next one.
  Some occurrences may be a genuinely different question in disguise (see the
  `on_data`/`on_headers`/`on_continuation` cases below, which test "have we
  already reacted to this stream once," not "is this stream closed"), but each
  needs an explicit per-site confirmation, not an assumption that a fix in one
  place automatically covers the rest. Missed on #27627 (pullrequestreview-
  4620220448): `classify_stream` was generalized to treat `locally_reset` ids
  as closed in one commit; a SIBLING pre-existing check (the H2PriorityFrame
  self-dependency guard in `dispatch_frame`, `frame.stream_id !in
  c.locally_reset`) predated the generalization and was never migrated — found
  only in the NEXT Codex round. Run the mechanical detector — do not rely on
  memory of which sites were already audited:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_locally_reset_consumers.v <file>`
  (enumerate-and-verify: lists every direct `locally_reset` check outside
  `classify_stream`/`mark_locally_reset` for per-site confirmation).
- **Sibling boolean-flag priority (the two-flags-one-function miss):** when a
  function gates on two or more independent boolean flags on the same struct,
  each with its own early-return branch (e.g. `if s.refused { RST(refused_
  stream); return }` then `if s.self_dep { RST(protocol_error); return }`),
  the CHECK ORDER encodes an implicit priority: whichever flag is tested first
  wins when BOTH are true. Whenever a diff adds or touches ONE such check,
  explicitly ask "what happens if this flag AND every other flag already
  checked in this function are true — is the resulting priority correct?" A
  reviewer skimming only the new/changed lines has no structural reason to
  look at sibling checks that weren't touched. Missed on #27627
  (pullrequestreview-4620412384): `finalize_headers` checked `s.refused` (over
  the concurrency limit — RFC 9113 §5.1.2, implies "safe to retry") before
  `s.self_dep` (RFC 7540 §5.3.1, always malformed) — a stream that was both
  reported the misleadingly retry-safe REFUSED_STREAM instead of the correct,
  more specific PROTOCOL_ERROR. Fix: swap the order so the more-specific/
  always-fatal condition is checked first. Run the mechanical detector — do
  not eyeball function bodies for this by hand:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_flag_priority_order.v <file>`
  (enumerate-and-verify: lists every function with 2+ early-return single-
  field boolean checks, in source order, for an explicit both-true review).
- **A per-branch `locally_reset` check is not a substitute for a dispatch-level
  CONTINUATION gate:** RFC 9113 §6.10 requires rejecting ANY CONTINUATION frame
  when no HEADERS/CONTINUATION block is currently incomplete (`awaiting_cont ==
  0`), regardless of whether the frame's stream id happens to be in a
  reset-tracking set. Fixing this inside one consumer (e.g. `on_continuation`'s
  discard branch, by adding `&& c.awaiting_cont == frame.stream_id`) only closes
  the hole for THAT branch — a live, non-reset stream that already completed its
  HEADERS has the identical gap and is not covered by a locally_reset check at
  all. The invariant belongs at the single call-site gate that already exists
  (`dispatch_frame`'s `if c.awaiting_cont != 0 { ... }` guard) — add the
  symmetric `else if frame is H2ContinuationFrame { return error(...) }` arm
  there so every consumer downstream is guaranteed `awaiting_cont ==
  frame.stream_id` before it ever runs. Missed on PR #27589 review
  4613845079 (Codex found the locally_reset instance; a human reviewer caught
  that the branch-local fix was still incomplete). Run
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_orphan_continuation_gate.v`.
- **A map keyed by id is only per-declaration when the id is unique for EVERY
  kind that reaches the lookup.** When new code reads an attribute of a
  candidate through a map keyed by its id (`site_of[c.id].is_main`), find
  where that map is filled and where ids are de-duplicated, and check the
  de-duplication covers every kind the new lookup sees. A table that renames
  colliding functions and types but not constants returns ANOTHER
  declaration's attribute for a constant, and one that drops colliding ids
  (re-keying them per file) returns nothing. Read the attribute from the
  candidate's own record (its file) instead, or use the per-file key. Missed
  twice on graphify#149: round 2, `find_const` read a module-main status for a
  const from `site_of[c.id]`, though every file of a directory declaring that
  const shares the id, so a test could take a `module X` const's recipe;
  round 3, `resolve_callee` read the same map for a function declared once per
  build branch, whose id `site_of` keeps only under `site_key(id, file)`.
- **An inline copy of a shared rule diverges from it.** When new code needs a
  rule a sibling already states as a function (or that the same diff adds as
  one), call it rather than re-typing its condition; if it can't be called,
  every negative half of the copy needs its own test. Missed on graphify#149
  (round 2): `find_const` re-typed `sees_in_module`'s condition, the copy
  drifted from it within one commit, and neither negative half was tested.
- **A value copied out of an arena is not all that survives its free.** When code
  frees a whole arena (`prealloc_scope_end`, `prealloc_scope_free_after`) or any pool
  it cannot enumerate, listing the locals and struct fields it copies out covers only
  what the code names. Runtime state set up on first use survives too, wherever that
  first use happened: a global table, a lazily built cache, a map that grows. For each
  arena, list what the code inside it can touch for the first time, reading the runtime
  (`vlib/builtin`, `os`, the closure runtime) rather than only the modules the diff
  imports. A capturing closure, a first `go`/`spawn`, or a first lazy init inside the
  arena each need an answer. Then test in the mode that unmaps freed memory
  (`-d prealloc_no_recycle`), in a fresh process that has not already set such state up:
  a test binary that ran other tests first, and `MallocScribble`, which does not touch
  mmap blocks, both hide this. Missed twice by `/vreview` on graphify#157 (found by
  `/adversarial-review` round 1, 2026-11-03): `resolve_edges`' `world_build`, the first
  capturing closure of an extract, set up V's `g_closure` table inside `resolve_arena`.
  The artifact listed every copied value, and the `__global` grep covered only the
  compiler modules a worker imports, so the table was left dangling for the next closure
  to write through, and four copies of `vlib/v` segfaulted. Regression test:
  `test_a_prealloc_extract_uses_nothing_it_has_freed` (signal 11 before `a4cdb56`).

### Angle E — Protocol / RFC compliance (H2 and QUIC)
**Requirements-driven, not diff-driven.** A diff-driven review cannot find a
*missing* MUST — an absent requirement produces no diff to react to. For HTTP/2
changes, walk the standing conformance matrix at
`${CLAUDE_PLUGIN_ROOT}/skills/code-review/h2_conformance_matrix.md` for the area touched, not
just the changed lines. It maps every RFC 9113 / 7541 normative requirement to a
`file:line` or commit (CONFORMS / GAP / ADVISORY). A new MUST you discover → add a
GAP row, then close it (fix + detector + test) and flip it to CONFORMS. This is
the proactive complement to the reactive miss corpus; the audit that created it
(2026-06-26) found gaps G1/G2/G4 that no external review had flagged.

For `vlib/net/quic/` changes, walk `${CLAUDE_PLUGIN_ROOT}/skills/code-review/
quic_conformance_matrix.md` the same way — it maps RFC 9000/9001/8446/7301
normative requirements to file:line for the QUIC transport and QUIC-scoped
TLS 1.3 handshake. **This file replaces the "write a checklist before reading
the diff" advice this section used to give for any new protocol integration
(the old G8 note below described that ad-hoc technique).** The ad-hoc version
was tried on vlang/v#27680's own full-file holistic review and it STILL missed
the Fixed Bit check (RFC 9000 §17.2/§17.3.1 — one sentence, easy to state, easy
to forget mid-review) — a third Codex round caught it after the ad-hoc
checklist-in-your-head pass had already run. A standing, maintained file you
walk row-by-row does not depend on recalling every MUST from memory while also
reading a diff; that's the entire lesson H2's matrix already encoded and QUIC's
lacked until this file existed (2026-07-26). When `quic_conformance_matrix.md`
itself doesn't yet cover the area touched (packet protection, streams, loss
detection — later phases not yet on the matrix), fall back to the old
technique (write the checklist by hand from the relevant RFC section) but ALSO
add the new section to the matrix file itself once you've done that work, so
the next review of that area doesn't have to re-derive it from scratch again.

**This is NOT optional advisory text — it is a required step of the review,
same weight as running the test suite, whenever a `vlib/net/quic/` file being
reviewed is not yet in the matrix's own "Files:" list.** Concretely missed on
vlang/v#28083 (net.quic Phase 9, `conn.v`): this exact instruction already
existed in this paragraph, unchanged, the entire time `conn.v` was being
reviewed across MULTIPLE separate `/vreview` invocations that session — and
was skipped every single time, because each invocation was scoped reactively
("check this one finding," "review this specific diff") rather than as a full
canonical pass that would reach this instruction. The result: two real
security gaps (RFC 9000 §17.2.2.1/§7.2 discarded-key and destination-CID
rejection) were found by an EXTERNAL reviewer instead, and a third
(source-CID consistency, RFC 9000 §7.2) was still sitting there unfound until
someone finally executed this exact instruction properly — see
`quic_conformance_matrix.md`'s own "Connection-level state machine" section
for the full writeup. **A narrowly-scoped review invocation does not exempt
you from this step if the file under review has no matrix section** — either
do the RFC-text audit and add the section as part of THAT invocation, or
explicitly state in the review's output that this step was skipped and why,
so the gap is visible rather than silently repeated.

**Artifact: matrix rows checked.** For any H2 or QUIC change, list the
matrix rows walked: `row (requirement) — file:line or commit — status
(CONFORMS/GAP/ADVISORY)`. Include rows confirmed unaffected by this diff,
not only rows touched by it — the matrix's value is in the walk being
exhaustive for the area, not just diff-adjacent. If the diff touches no
H2/QUIC code, state "N/A — no H2/QUIC changes in this diff."

**A diff that introduces a brand-new frame/message TYPE has, by
definition, zero existing matrix rows for it — that is not a reason to
skip the walk, it is the strongest possible trigger for it.** Adding a new
`parse_x_frame`/`encode_x_frame` pair is exactly the "quic_conformance_
matrix.md doesn't yet cover the area touched" case this section already
names as requiring a new section to be added as part of THIS review, not
deferred. For every new frame type, before trusting any hand-written test
as coverage: pull the RFC section defining its wire format and enumerate
EVERY field, in two passes — (1) every FIXED-length field needs an
explicit length/truncation check with the RFC's own error code
(`FRAME_ENCODING_ERROR` for a malformed QUIC frame) BEFORE it is read, not
inferred from "the varint decoder already bounds things"; (2) every field
with a stated value CONSTRAINT (MUST NOT be zero, MUST NOT exceed N) needs
its own rejection, independent of the length check. Missed on vlang/v#28406
(external review, 2026-09-07): this session added five new QUIC frame
parsers (NEW_TOKEN, NEW_CONNECTION_ID, RETIRE_CONNECTION_ID, PATH_CHALLENGE,
PATH_RESPONSE) in one PR; external review subsequently found EVERY one of
them missing at least one of these two checks — NEW_TOKEN accepted a
zero-length token (RFC 9000 §19.7 says MUST NOT be empty) and even had a
regression test LOCKING IN the wrong behavior
(`test_new_token_frame_accepts_zero_length_token`); NEW_CONNECTION_ID's
CID/reset-token/sequence-number/retire-prior-to/length fields and RETIRE_
CONNECTION_ID's sequence-number field all lacked truncation checks; none
of the five ever got a `quic_conformance_matrix.md` row before shipping.
A test asserting the HAPPY-PATH round-trip works is not evidence the
malformed-input paths were considered — write the matrix row (or at least
the RFC-field enumeration) BEFORE writing the parser's tests, not after,
so "what does a truncated/zero/oversized wire value do here" is asked for
every field once, up front, rather than rediscovered field-by-field across
a dozen separate external-review rounds.

The specific H2 checks below are the high-frequency subset:

For changes to HTTP/2 code, check RFC 7540 requirements that are easy to miss in
incremental review:
- **Flow control:** Are send/receive windows bounded to `[0, 2^31-1]`? Does a
  SETTINGS `INITIAL_WINDOW_SIZE` delta that would push any stream window past
  `2^31-1` trigger `FLOW_CONTROL_ERROR` before being applied?
- **WINDOW_UPDATE zero-increment error scope (RFC 7540 §6.9):** A zero-increment
  frame on `stream_id == 0` is a *connection* error (PROTOCOL_ERROR → GOAWAY). A
  zero-increment on `stream_id != 0` is a *stream* error (RST_STREAM on that
  stream), NOT a connection error. For streams the receiver does not track (no entry
  in a stream map, or a single-stream client that only owns one active id), a
  zero-increment frame is silently ignored rather than killing the connection. Check:
  the `inc == 0` guard must live INSIDE the `stream_id == 0` / `stream_id != 0`
  branches, never in a single check that fires before the dispatch. Caught in h2_conn.v
  after commit 42da3499ee: the guard fired before the branch, so a zero-increment on
  an untracked stream fatally killed the connection.
- **Validate-before-mutate in SETTINGS handlers:** When a SETTINGS value triggers
  both a validation check AND a state mutation, compute ALL new values into locals
  first, verify ALL constraints, THEN commit mutations. Never write to a shared field
  before a guard that may `return error` — on the error path, the caller sees a
  half-updated connection with inconsistent state and may retry on it. The canonical
  miss (h2_conn.v `apply_settings`): `peer.initial_window_size` and
  `stream_send_window` were both written before the delta-overflow guard; a
  catch-and-retry caller then called `do()` again on a connection whose
  `initial_window_size` still held the rejected (large) value, giving the new stream
  an overflow-magnitude send window.
- **Frame ordering:** Can any control frame (SETTINGS ACK, PING ACK) be emitted
  before the client connection preface? After a GOAWAY?
- **State machine:** Can a stream ID be reused or exceed `0x7fff_ffff`? Is
  `RST_STREAM` with `REFUSED_STREAM` treated as retryable?
- **Stream-state classifier keyed on a monotonic counter must test id PARITY:**
  A server tracks `last_stream_id` for *client*-initiated (odd) ids only. Any
  classifier that decides idle-vs-closed by `id <= last_stream_id` alone is wrong
  for the *other* parity: a never-opened EVEN (server-initiated) id below the
  counter is still **idle**, not closed — a frame on it is a connection
  PROTOCOL_ERROR (RFC 9113 §5.1), not STREAM_CLOSED / silently-ignored. "Closed"
  must be `id & 1 == 1 && id <= last_stream_id`. Missed on #27589
  (`classify_stream` had no `& 1` guard). Run the mechanical detector — do not
  eyeball: `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_stream_state_even_idle.v <file>`
  (flags a `classify_stream` returning `.closed` with no parity guard; exit 1 on
  `e97d398e02`, exit 0 after fix). General lesson: a counter advances over only one
  peer's id space, so "below the counter" still contains never-opened ids of the
  opposite parity.
- **Error handling:** On a connection error, are all in-flight streams woken with
  an appropriate error before the reader exits? Are non-idempotent requests whose
  HEADERS may have been delivered marked non-retryable?
- **Preface ordering:** Does the connection preface (magic + SETTINGS) always
  arrive before any stream frame or ACK from the client?
- **Flow-control credit gate — `flow_size` not `data.len` (padding miss):** In
  every DATA frame handler, `send_window_update` and `conn_recv_window` debits/
  credits MUST be conditioned on `frame.flow_size > 0` and use `frame.flow_size`
  as the amount — NOT `frame.data.len`. `flow_size` is the full wire payload
  (padding included); `data.len` is the stripped body (padding excluded). A
  padding-only DATA frame has `data.len == 0` but `flow_size > 0`; gating on
  `data.len` silently skips window credit for those bytes, permanently shrinking
  the receive window and eventually stalling unrelated streams. Run the mechanical
  detector — do **not** eyeball:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_padding_credit.v <file>`.
  Missed on #27413: H2Conn and H2ServerConn wrapped correct `flow_size` update
  calls inside `if frame.data.len > 0 { }`, so padding-only frames leaked window.
- **HPACK direction — `SETTINGS_HEADER_TABLE_SIZE` constrains the encoder:**
  When a SETTINGS frame from the peer contains `SETTINGS_HEADER_TABLE_SIZE`, it
  limits the dynamic table our *encoder* may use for outgoing request headers
  (RFC 7541 §6.3 / RFC 7540 §6.5.2). It does NOT constrain our *decoder*, which
  handles incoming response headers. Check: every handler for this setting must
  (a) call `encoder.dyn_table.set_max_size(n)` to evict entries exceeding the new
  limit immediately, AND (b) schedule a Dynamic Table Size Update prefix (5-bit
  integer, high_bits=`0x20`) to be emitted at the start of the next header block
  (`encoder.pending_max_table_size = n`) — omitting (b) desyncs the peer's decoder
  even when (a) is present. Do NOT update `decoder.set_max_dynamic_size()` here.
  Missed on #27413 commit 37f86172ff: the SETTINGS handler called
  `c.decoder.set_max_dynamic_size(st.value)` — backwards. A server setting this to
  0 silently broke HPACK response decoding when entries were later referenced under
  a table the decoder had no longer stored.
- **Body completeness — validate content-length at END_STREAM:** If a response
  header `content-length` is present, the body bytes delivered by the peer MUST
  equal that declared length when END_STREAM arrives. Any code path that returns
  the response object after `ended == true` without comparing `body_so_far` to
  `body_expected` silently delivers truncated (or overlong) bodies as success.
  Check: at every early-return on `ended`, either there is no content-length
  (`body_expected == 0`) or `body_so_far == body_expected`. Missed on #27413
  commit 0aa2c8d543: `wait_response` returned `resp` on `ended && got_headers`
  with no length check, so a server that sent END_STREAM prematurely produced a
  silent partial body.
- **1xx informational responses — do not latch `headers_done` early:** HTTP/2
  permits a server to send one or more 1xx HEADERS frames (100 Continue, 103 Early
  Hints) before the final non-1xx response HEADERS. Any code that sets a "headers
  received" flag (e.g. `headers_done`, `got_headers`) on the *first* HEADERS frame
  will treat the final 200/40x response as trailers, and the caller receives the
  wrong status. Rule: only set `headers_done`/`got_headers` when `:status >= 200`.
  For `1 ≤ status < 200`, re-wait for another HEADERS block. Missed on #27413
  commit 0aa2c8d543: `on_response_headers` set `s.headers_done = true`
  unconditionally on the first HEADERS block; `wait_response` latched `got_headers`
  on that first 1xx, then when the final 200 HEADERS arrived it fell into the
  trailers path and was silently discarded.
- **Trailer-field scope for `content-length`:** HEADERS frame processing loops
  that handle both initial response headers and trailers must guard `content-length`
  (and other "response body sizing" fields) with `!got_headers` — i.e. only apply
  these fields from the FIRST non-1xx HEADERS block. A `content-length` field
  appearing in a trailer HEADERS frame (second HEADERS after DATA, `got_headers`
  already true) must NOT overwrite `body_expected` or `has_content_length`. If it
  does, the body-completeness check at stream end compares the full body against the
  trailer's content-length (likely 0 or unrelated), producing a spurious truncation
  error on a fully-received response. Caught in h2_conn.v after commit 42da3499ee.
- **Upload half-close after early final response:** When a server sends a final
  response HEADERS with END_STREAM while the client is still uploading a large body
  (flow-control blocked), the server's END_STREAM closes only the server-to-client
  half of the HTTP/2 stream. The client upload half is still open from the server's
  perspective — the server keeps the stream counted against
  `SETTINGS_MAX_CONCURRENT_STREAMS` until the client closes it. Any code path that
  detects `server_ended` and returns without either (a) sending RST_STREAM or
  (b) sending the remaining DATA with END_STREAM causes a stream slot leak on the
  server, eventually causing REFUSED_STREAM or connection stalls. Missed on #27413
  commit 85267dd17b: `send_body_on_stream` returned cleanly on `server_ended`
  without RST_STREAM, so the server held the stream open indefinitely.

### Angle F — Concurrency / race matrix

**This angle produces three required matrices, not a prose impression.** A
race-review claim like "looks safe" or "I checked the locking" isn't
auditable — a second reader has no way to tell whether it was actually
enumerated or eyeballed. A filled-in table is: every row is either right or
wrong, checkable by anyone who reads the code, the same shift Angle E made
by replacing a from-memory protocol checklist with a maintained matrix.

**Matrix 1 — Shared-state matrix** (`shared field → readers → writers →
lock`): for every shared field/data structure touched by the diff, one row
naming every reader, every writer, and the lock declared to guard it. A
reader/writer pair not separated by that lock is a Matrix-1 finding.

**Matrix 2 — Wait/wake matrix** (`wait predicate → all mutators →
wake/broadcast path`): for every condition-variable wait predicate in the
file (`for !cond { cv.wait() }`), one row listing every variable in the
predicate, every code path that mutates ANY of them (full-file, not just
the diff), and whether each mutator's path actually reaches a
`cv.broadcast()`/`cv.signal()` call. A mutator with no wake path is a
permanent-hang finding — see the "Condition-variable liveness" bullet below
for the full technique and three historical instances.

**Matrix 3 — Lock-scope commit matrix** (`action sized under lock →
committed under same protection?`): for every place a value, capacity
check, or decision is computed WHILE a lock is held, one row naming that
action and whether the corresponding mutation/commit happens under the
SAME critical section — or whether the lock is released in between (a
TOCTOU gap). This is the general shape behind the singleflight-registration
TOCTOU, the wmu→fmu recheck-completeness gap, and the partial-guard-miss
bullets below: something is decided under protection, then acted on after
that protection lapsed.

**Artifact: concurrency matrices.** All three tables above, one set per
diff. State "none" for a matrix with no applicable rows (e.g. a diff with
no condition variables gets "none" for Matrix 2) rather than omitting it —
an omitted matrix and a genuinely empty one must not look the same.

**Run the race detector on the tests the concurrent code reaches (rev 95).** When the
diff touches threads, locks, channels, atomics or a field shared between threads, run
`v -race test <the test files that exercise the changed code>` and record the command,
the exit code and the races reported. `-race` builds with ThreadSanitizer. A test file
that hits a data race is marked `FAIL` even when its asserts pass, the runner exits 1, and
the output holds `WARNING: ThreadSanitizer: data race` with the V `file:line` of both
accesses (a race-built program run directly exits 66 instead). Read the output for that
warning rather than trusting the exit code, since a plain test failure also exits 1. Each
race is a Matrix 1 candidate, triaged like any other. It builds only on Linux, macOS,
FreeBSD and NetBSD; native Windows refuses (`` `-race` is not supported on windows/amd64 ``),
and so does Clang itself (`-fsanitize=thread` is unsupported for both the windows-gnu and
windows-msvc targets), so on Windows run it in WSL
(`wsl -e bash -lc 'cd <checkout> && v -race test <files>'`) with a `v` built from the same
commit as the checkout (compare `v version`). State its limits with the result: it finds
only races the run actually interleaves, so a clean run does not clear Matrix 1; it cannot
see a missed or late wake, or a TOCTOU across a released lock, so Matrices 2 and 3 stay
manual; race builds drop the GC and `-prealloc`, so code that depends on them runs
differently; and code behind `$if windows` (SChannel, Win32 threading) never runs in WSL,
so list it as not race-checked rather than covered. Checked 2026-11-07 in WSL: a test whose
two threads do an unguarded `c.n++` was marked FAIL with exit 1 and both stacks at the
increment; the same program built and run directly exited 66; native Windows refused it.

**Artifact: race detector run.** The command, where it ran, the exit code and the races
reported; or "N/A — no concurrent code in this diff"; or "not run — reason".

For each shared data structure touched by the diff, enumerate every writer and
every reader. For each writer/reader pair, verify they are always separated by the
declared lock. Pay special attention to:
- **Lock-nesting vs sequential — verify before claiming:** Before surfacing a
  "lock A held while B acquired" candidate, scan the actual code between the
  `A.lock()` and `B.lock()` calls for an `A.unlock()`. If an `A.unlock()`
  appears between the two, the acquisitions are *sequential* (no overlap) — drop
  the candidate. Only surface lock-order candidates where both locks demonstrably
  overlap (A.lock() … B.lock() … with no intervening A.unlock()). False-positive
  example: two `lock()` calls six lines apart with an `unlock()` at line N+9
  — looks nested on a fast scan, is sequential on careful reading.
- Fields updated by the reader goroutine and read by request goroutines
- Fields set on one goroutine's error path and checked on another's happy path
- **Condition-variable liveness (wake invariant) — fills Matrix 2:** For each condition variable
  in the file, find its wait predicate (`for !cond { cv.wait() }`). Enumerate
  ALL variables in that predicate — not just the ones the diff touches. Every
  code path that modifies ANY of those variables MUST call `cv.broadcast()` or
  `cv.signal()`. This is a full-file check, not just a diff check: credit returned
  to `c.send_window`, a flag like `s.send_dead` set to true, or `s.ended` set to
  true are all predicate modifications that require a broadcast. Missed cases
  on #27413:
  - `send_window += excess` in `send_body_on_stream` recheck block without
    `fcv.broadcast()` — upload goroutines in `fcv.wait()` stayed blocked
    forever (commit 90e221f6e4, caught by detector).
  - Final response `on_response_headers` set `s.headers_done` and called
    `s.cv.signal()` but did NOT call `c.fcv.broadcast()` — upload goroutines
    blocked in `fcv.wait()` on `s.send_dead` never woke when the server sent
    an early final response with END_STREAM (commit dc488c9965).
  - RST_STREAM handler signaled `s.cv` and called `s.fail()` but did NOT call
    `c.fcv.broadcast()` — upload goroutines blocked in `fcv.wait()` on
    `s.send_dead` never woke when the server reset the stream (commit 4390e1773f).
  Run the mechanical detector for the send_window case:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_missing_fcv_broadcast.v <file>` (for a past revision: `run_detectors.sh --at <rev> <file>`)
  (exits 1 if `send_window += excess` appears in `send_body_on_stream` without
  `fcv.broadcast()` before the following `fmu.unlock()`). For the broader check,
  list the full predicate of every `cv.wait()` call in the file and verify every
  modifier of each predicate variable calls broadcast. Connection-death paths must
  also broadcast (covered under goroutine lifecycle above).
- **Singleflight wake timing (broadcasts, but too late):** the cv-liveness check
  above only asks "does every path eventually wake waiters" — a coordinator that
  does `unshareable_work(); wake()` instead of `wake(); unshareable_work()` passes
  that check every time (it DOES broadcast) while still head-of-line-blocking
  every waiter behind however long the unshareable work takes. Separately ask:
  once the FACT a waiter's own branch depends on is known (e.g. "this origin
  speaks h1, not h2"), is the wake positioned immediately after that fact is
  settled, or after some ADDITIONAL work that only this caller — not the waiters
  — actually needs? A resource that cannot be shared across concurrent callers
  (an HTTP/1.1 connection mid-exchange) should never be the reason waiters keep
  sleeping once the routing decision they need is already final. Missed on
  vlang/v#27643 (Codex P2, pullrequestreview-4631763931): `h2_dial_and_do`'s
  h1-fallback branch delayed `call.cv.broadcast()` until after ITS OWN
  `conn.exchange()` fully completed (a round-3 choice to let one waiter reuse the
  connection), serializing unrelated concurrent requests behind one response —
  a regression from ordinary h1 pooling, where concurrent first-time callers to a
  fresh origin dial independently (RFC 9112 §9.4 names this exact failure mode as
  the reason multiple connections exist). No mechanical detector: whether a wake
  is positioned "early enough" requires knowing what the waiter's post-wake branch
  depends on, which is a semantic question — trace it by hand for every
  singleflight/coordinator pattern the diff touches.
- **Singleflight registration TOCTOU across a caller/callee boundary — a Matrix 3 instance:** the
  existing lock-scope TOCTOU bullets below all look for a gap WITHIN one function
  between reading shared state and acting on it. A distinct shape: function A
  checks shared state under a lock, releases it, then calls function B, which
  independently checks a DIFFERENT piece of shared state (e.g. "is anyone
  currently registering a new resource for this key") before committing to
  expensive/exclusive work (a new handshake, a new singleflight coordinator). If
  B's check doesn't ALSO re-verify the state A originally checked, a state change
  in the window between A's check and B's entry is invisible — B commits to
  redundant work and can orphan whatever just won the race. Missed on
  vlang/v#27643 (Codex P2, pullrequestreview-4631763931): `h2_round_trip` checked
  `t.h2_conns[key]` under a lock it released before calling `h2_dial_and_do`,
  which only checked `t.dialing[key]` — a concurrent dial that finished in that
  window went undetected, causing a redundant handshake and an orphaned
  connection. Fix: the callee rechecks the CALLER's original state under its own
  fresh lock before committing. Ask, for any fast-path/slow-path split across two
  functions: does the slow path re-verify everything the fast path already ruled
  out, or does it trust a now-stale snapshot?
- **Transport / external-object thread-safety:** When the design calls a shared
  external object (a socket, a TLS `SSL*`, a DB handle, a C library) from more than
  one thread — e.g. a reader thread in `read()` while request threads `write()` —
  do NOT assume the object is full-duplex-safe. Raw TCP sockets are; a TLS
  connection is NOT (one OpenSSL/mbedTLS `SSL*` must not be read and written
  simultaneously). For every backend that satisfies the transport interface, check
  its concurrency contract; if any isn't safe for the access pattern, the design
  needs a serialized/non-blocking I/O adapter (a naive single I/O mutex deadlocks a
  blocking reader). Missed on #27413: `H2MuxConn`'s reader/writer threads share one
  transport; safe for the test pipe and raw TCP, unsafe for `SSLConn`.
- **A socket-level readiness poll cannot see library-internal buffered data:**
  when a transport adapter wraps a library that can hold more decrypted/decoded
  data internally than one call hands back (mbedTLS/OpenSSL: `ssl_read`/`SSL_read`
  return at most the caller's buffer size per call; any remainder from an
  already-received TLS record stays buffered, needing no new socket bytes), an
  outer raw `select()`-style readiness poll run BEFORE the wrapped call is
  unsound: the socket can correctly report "nothing new" while the library
  already has data ready to hand back immediately. If the poll's timeout is
  propagated as the read's own result, a consumer that treats read timeouts as
  benign (a mux reader retrying) never drains the buffered data until unrelated
  new socket bytes arrive — or never. Fix: delete the outer poll and let the
  wrapped call's own internal bounded wait (its configured read_timeout) drive
  it — it always tries the non-blocking-in-effect buffered path first. Missed on
  #27643 (Codex P1, pullrequestreview-4626225521): `H2PooledTransport.read()`
  polled the socket before calling `SSLConn.read()`. Run
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_tls_read_precheck_poll.v <file>`
  (flags a `read(mut buf ...) !int` method on a struct wrapping `ssl.SSLConn`
  whose first data-availability check is an outer `wait_for_read()` before the
  wrapped `conn.read()` call).
- **Unbounded peer-controlled accumulation (DoS):** Enumerate every connection-
  level buffer, counter, or MAP the reader appends to / increments / inserts into
  per incoming frame (`<recv>.<field> <<`, `++`, `+=`, or `<recv>.<field>[...] =`,
  for ANY of the file's own mut receiver names, not just `c` — H3Conn's receiver
  is `h`). Each MUST have a size cap OR active pruning (a `.delete(` call for that
  field elsewhere in the file), or a peer exhausts memory / sets up a burst —
  precedent: `h2_max_recv_header_block` bounds the CONTINUATION buffer;
  `request_streams`/`request_decoders` are bounded by deletion, not a cap. Run the
  enumerate-and-verify aid (not a clean gate — it surfaces candidates; some are
  bounded by an admission limit, the protocol, or a cross-file check this
  single-file detector can't see):
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_unbounded_accum.v <file>`. For each
  accumulator with no cap, confirm it is bounded by other means; if it is
  peer-driven and not drained in-handler, it needs a cap. Missed on #27413:
  `pending_ping_acks`/`pending_settings_acks` grew unbounded while a peer held the
  connection pre-preface. Missed on #28129 (dead_request_streams, 2026-08-21, see
  reference/code-review-misses.md): the detector was scoped to H2 only (`^h2_.*\.v` in
  `run_detectors.sh`'s manifest — now `.*\.v`) AND hardcoded to receiver `c` with
  no map-assignment pattern, so it matched literally nothing in h3_conn.v; the
  SAME bug class had already been found and fixed twice in the same function, on
  the two fields sitting right next to the missed one — an inline comment
  rationalizing the miss ("deliberately left alone, it's tiny") is exactly the
  shape that suppresses a sibling-search re-check. When you fix an unbounded
  accumulator, grep the same struct's OTHER fields for the same growth pattern —
  don't stop at the one the finding named, especially if a neighbor has its own
  confident-sounding comment explaining why it's fine.
  **A `NO CAP FOUND` flag is cleared only by a bound on EVERY path, never by a
  partial cap or an in-code waiver.** Two dismissals that are both findings:
  (1) a cap keyed on a peer-chosen discriminator (frame type, stream type,
  setting ID) must name a bound for every value, unknown/grease values
  included; a cap on DATA/HEADERS only leaves every other type unbounded.
  (2) a comment such as "deliberately unbounded for v1" on a map keyed by
  pre-authentication input (source address, unvalidated connection ID) is a
  finding to report, not a waiver to accept. Missed twice on vlang/v#28164
  (Codex, reviewed commit `29a933e6c3`, rev 72), with the detector flagging both:
  `H3FrameDecoder.pending` capped only DATA/HEADERS, so any other frame type
  declaring a huge length buffered every byte; `H3Server.peer_by_str` stored
  every datagram's source address before QUIC routing and was never pruned.
- **A new pool/cache on an existing parent object must inherit ALL of that
  object's public capacity limits, not just its own new map:** when a diff
  adds a second pooled/cached resource alongside an existing one on the same
  parent (e.g. a second connection pool on `Transport`, next to the h1 pool),
  audit every one of the parent's documented capacity/lifetime knobs
  (`max_idle_conns`, `max_idle_conns_per_host`, `idle_timeout`) against the NEW
  structure individually — "it's tracked in its own separate map" does not
  exempt it from limits the parent's own contract already promises callers.
  Missed on vlang/v#27643 (Codex P2, pullrequestreview-4627654418): `h2_conns`
  (a new per-origin connection pool added alongside the existing `h1_idle`
  pool) had no eviction of its own, so a client touching many distinct h2
  origins accumulated one live TLS socket + reader thread per origin forever,
  ignoring `Transport.max_idle_conns` — a limit the h1 pool in the SAME
  `Transport` already enforces. Fix: an eviction helper mirroring the existing
  pool's own (only evicting a currently-idle entry, oldest-idle first),
  invoked from the same locked section that registers each new entry.
  **The general rule this instance is one case of, easy to miss when only the
  ORIGINAL gap (h2 had zero eviction) is what gets fixed:** a limit shared
  across sibling pools must be enforced SYMMETRICALLY — the CHECK that decides
  "are we over budget" and the ACTION that frees budget must reference the
  SAME set of pools. It is not enough for the check to be pool-complete
  (`total_idle_locked() + h2_conns.len` correctly counts both) if the action
  only ever acts on one of them. This is easy to miss on a re-touch of the
  same function because the check line reads correctly in isolation. Run
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_pool_cap_scope_symmetry.v
  vlib/net/http/transport.v` — do not eyeball this one either: on
  vlang/v#27643 round 4, the eviction helper that fixed the ORIGINAL gap
  still only ever evicted from `h2_conns` even after a budget filled
  entirely by `h1_idle`, and separately, `checkout()`'s `idle_timeout`
  expiry had no `h2_conns` equivalent at all — the SAME class of gap,
  caught by this detector, still open as of round 4 and finally fixed in
  round 5 (a separate `H2MuxConn.is_idle_expired`, checked in
  `h2_round_trip`'s own fast path — `checkout()` itself stays h1-only by
  design, since it returns `&H1PooledConn`; the detector still flags it
  when scoped to `transport.v` alone, but passes clean when scoped to
  `transport_h2.v`, confirming the sibling enforcement lives there).
  **A second, narrower dimension of the same "check vs action" symmetry,
  found in round 5 (Codex P3, pullrequestreview-4631763931):** even when a
  check correctly references BOTH pools, it must also apply the SAME
  ELIGIBILITY FILTER as the action for connections WITHIN one of those
  pools. `evict_oldest_idle_locked`'s cap check counted `h2_conns.len` —
  every h2 connection, busy or idle — while its own eviction scan two dozen
  lines below only ever considers entries with `active_streams == 0`. A
  busy h2 connection inflated the check's total without ever being
  something the scan could act on, so an unrelated genuinely-idle h1
  connection got evicted to "fix" a budget that was never actually over.
  Run `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_idle_cap_counts_busy_conns.v
  vlib/net/http/transport.v` (narrow, function-specific — flags a bare
  `h2_conns.len` in `evict_oldest_idle_locked`'s cap-check section). **A
  fix for this exact bug can ITSELF get the eligibility filter subtly
  wrong** — excluding a just-registered entry from the CHECK the same way
  it's excluded from CANDIDACY under-counts the pool (the entry still
  occupies a slot even though it can never be picked as its own victim);
  verify a fix like this against the FULL existing test suite, not just
  the one scenario the finding named.
- **A per-request watchdog/timer thread must be bounded by its OWN poll
  granularity, not just by the configured deadline:** when a diff spawns one
  background goroutine per request to enforce a caller-configured timeout, ask
  whether that goroutine's lifetime is bounded by the deadline alone (one bare
  `time.sleep(timeout)`) or by something shorter. If the deadline defaults to a
  large value (e.g. 30s) but most requests complete in milliseconds, "one
  thread per request" becomes "one thread per request lingering for the full
  deadline" under any sustained throughput — self-caught while reviewing the
  read-timeout enforcement fix for vlang/v#27643 (pullrequestreview-4627654418)
  before push. Fix: poll in short bounded steps, checking the request's
  completion state after each, so the watchdog exits shortly after the request
  actually finishes rather than always waiting out the configured timeout.
- **A network-wait timeout's clock must exclude non-network work that
  deliberately runs during its window:** when a watchdog/deadline is documented
  as bounding I/O wait time, but the design deliberately lets OTHER work (a
  caller-supplied callback, a downstream write, disk I/O) run concurrently or
  unlocked during that same window for an unrelated, legitimate reason (e.g. so
  a slow callback doesn't stall delivery to other consumers), ask: is that other
  work's duration excluded from the timeout's clock, or does the clock keep
  running through it? If the "since" timestamp the watchdog reads is only
  updated by network events (a frame arriving), any non-network work sharing
  that window gets silently counted against the network budget. Missed on
  vlang/v#27643 (Codex P2, pullrequestreview-4631763931): the h2 pooled-client
  response watchdog stayed armed while `wait_response()` ran a caller's
  `on_data` callback outside the stream lock — a callback slower than
  `read_timeout` got its stream falsely reset even though nothing was waiting
  on the network. Fix: a boolean flag set around the excluded work's span; the
  watchdog's "since" function reports "now" (clock paused) while the flag is
  true. **Testing note:** if the design's OTHER mechanisms (e.g. a reader thread
  that races ahead of a slow consumer by design) can independently satisfy the
  watchdog's exit condition before the timing bug would ever fire, a normal
  end-to-end test is a FALSE GUARD regardless of chosen delays — verify this by
  tracing what ELSE could make the watchdog exit cleanly before concluding a
  peer/timing-based repro will actually exercise the bug; a direct unit test of
  the clock-pausing mechanism itself may be the only reliable option.
- **Lock scope vs. committed action (TOCTOU):** When a lock is acquired to read a
  value that determines a frame size or write payload, the lock must remain held
  until the write completes — not just until the value is read. A lock released
  after reading but before writing creates a TOCTOU window: the value can be
  updated by another thread (under the same lock), the peer ACK'd, and the
  resulting frame may then violate a new protocol constraint. Ask: in any path
  where lock A is held to compute chunk/payload size, is lock A still held when
  the write lock (lock B) is acquired and the frame goes on the wire? If not, can
  the sizing value change between A.unlock() and B.lock()? Canonical missed pattern:
  `send_body_on_stream` read `peer_max_frame` under `fmu`, released `fmu`, then
  acquired `wmu` to write DATA — reader could shrink `peer_max_frame` + send
  SETTINGS ACK in the window, causing an oversized DATA frame after the peer
  started enforcing the new limit. Run the mechanical detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_fmu_scope.v <file>` (for a past revision: `run_detectors.sh --at <rev> <file>`)
  (exits 1 if `c.fmu.unlock()` precedes `c.wmu.lock()+H2DataFrame` in
  `send_body_on_stream` with no intervening `return` or `fmu.lock()`).
- **wmu→fmu recheck completeness (all fmu-protected state) — a Matrix 3 instance:** When a `wmu→fmu`
  recheck block exists (a nested `fmu.lock()` taken while holding `wmu`), the
  block was added to handle ONE known race. Enumerate ALL reader-mutable
  fmu-protected state that can change in the same TOCTOU window — not just the
  field named in the comment. Common sources: `peer_max_frame` (SETTINGS_MAX_FRAME_SIZE),
  `s.send_window` (INITIAL_WINDOW_SIZE delta applied per-stream), connection flags.
  For each field: if the reader can change it between the outer `fmu.unlock()` and
  this inner `fmu.lock()`, it needs its own recheck guard. Missed on commit 42da3499ee:
  the `wmu→fmu` block in `send_body_on_stream` already handled `peer_max_frame` but
  not `s.send_window`; an INITIAL_WINDOW_SIZE reduction in the window drove
  `s.send_window` negative after the debit, causing DATA to exceed the peer's new
  stream window → FLOW_CONTROL_ERROR. Run the mechanical detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_initial_window_recheck.v <file>` (for a past revision: `run_detectors.sh --at <rev> <file>`)
  (exits 1 if the wmu→fmu block in `send_body_on_stream` lacks an `s.send_window < 0`
  guard).
- **A reader-side recheck only closes a TOCTOU if the WRITER serializes too —
  check the SETTER's lock:** A re-read of shared state right before a "committed
  action" only helps if the re-read lock is held *until* the action, OR the writer
  of that state takes the lock the action is fenced by. The `peer_max_frame`
  senders re-read it under `fmu`, **release `fmu`**, then write the frame under
  `wmu` (held across both) — so the re-read only *minimises* the window (the
  comments admit "to minimise the TOCTOU window"). The residual race stayed open
  because the SETTER (`apply_peer_settings`'s `h2_settings_max_frame_size` arm)
  updated `peer_max_frame` under `fmu`-only: a lowered value could land in the
  `fmu`-release → write gap. So when you see a reader-side recheck guarding a write,
  trace the field's SETTER: does it hold the lock the writer holds across
  read→use (here `wmu`)? If the writer fences the action with lock A but the setter
  only takes lock B (used for the re-read), the A-fenced region still races — make
  the setter take lock A too (here: update `peer_max_frame` under `wmu`→`fmu`, like
  the `header_table_size` arm fences the HPACK encoder under `wmu`). Detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_peer_max_frame_wmu.v <file>` (exits 1 if
  the SETTINGS_MAX_FRAME_SIZE arm sets `peer_max_frame` without holding `wmu`).
  vlang/v#27413 discussion_r3474404838.
- **Pre-loop TOCTOU: fix the loop, fix the entry too — a Matrix 3 instance:** When a TOCTOU is fixed by
  adding per-iteration `lock/read/unlock` re-reads inside a loop, immediately ask:
  does the code BEFORE the loop entry use the same snapshot at the same vulnerable
  point? A loop fix scoped to "iterations 2…N" silently leaves "iteration 0" (the
  first write before the loop) with the original race. Canonical missed pattern
  (commit 42da3499ee): `send_header_block_locked` CONTINUATION loop was fixed with
  per-iteration `fmu.lock/read/unlock` re-reads — but the first multi-frame HEADERS
  write (immediately before the loop) still used the stale `max` snapshot from
  function entry. Run the mechanical detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_headers_max_reread.v <file>` (for a past revision: `run_detectors.sh --at <rev> <file>`)
  (exits 1 if the first multi-frame HEADERS write in `send_header_block_locked` has
  no `fmu` re-read between the function-entry snapshot and the write).
- **Swallowed write-error windows:** For each `or {}` on a write/IO operation, ask:
  is there an admission gate (e.g. `shutting_down`, `closed`) that *should* be set
  when this write fails? Verify that either (a) the `or {}` is replaced by a handler
  that sets the gate, or (b) a subsequent operation in the *same code path* always
  sets the gate before returning. A dangerous window exists when write A fails
  silently (`or {}`), then write B follows in the same path and *also* fails, and
  only B's failure sets the gate — because between A and B the admission gate is
  unset and another goroutine can observe the resource as healthy. Run the mechanical
  detector: `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_swallowed_write.v <file>` (exits
  1 on any `or {}` on a write/send/IO call; for each candidate, verify the enclosing
  function calls `note_write_failure()` / `teardown_transport()` or sets
  `shutting_down`/`closed` on its failure path).
- **Admission-flag setter serialization (recheck must be authoritative):** When a
  write critical section rechecks a terminal/admission flag (`goaway`, `closed`,
  `shutting_down`) under lock S while holding write-lock W, then *releases S but
  keeps W* and performs the wire write — the recheck only closes the race if EVERY
  setter of that flag also serializes on W. Enumerate every writer of each flag the
  recheck tests (Grep `<flag> = true`). For each setter ask: does it acquire W before
  setting, or is it self-healing (e.g. the setter implies transport death, so the
  pending write fails anyway)? A setter that runs on the reader thread, leaves the
  transport alive, and takes only S is the bug: it can land in the window between the
  recheck (S released) and the write (W still held). Canonical missed pattern (commit
  4496950803): `do_on_stream` rechecks `closed||goaway||shutting_down` under `smu`
  while holding `wmu`, but the `H2GoawayFrame` handler set `c.goaway` under `smu` only
  — a GOAWAY in that window opened a stream after the peer said stop (RFC 7540 §6.8).
  Fix: the GOAWAY handler takes `wmu` before `smu`. Run the mechanical detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_goaway_wmu_serialize.v <file>`
  (exits 1 if the `H2GoawayFrame` arm sets `c.goaway` without a `c.wmu.lock()`).
- **Double-close / who-owns-the-close (and "safe because local-scope" comments):**
  When a teardown path closes a fd/handle that another thread ALSO closes, ask who
  owns the single close. A classic shape: a shutdown routine force-closes a socket
  to wake a worker blocked in a read (on Windows `net.shutdown` does NOT wake
  `select()`; only `net.close`/closesocket does), and the woken worker's `defer`
  then closes the SAME fd again. That is a double-close: between the two closes the
  fd/SOCKET value can be REUSED by any socket the process opens, so the second
  close lands on an unrelated socket. A SOCKET handle is a process-global resource;
  any safety comment that argues "this is safe because <local scope>" (e.g. "the
  accept loop already stopped") is a RED FLAG — it reasons about one subsystem while
  the resource is shared process-wide. Require an explicit ownership transfer: the
  force-closer records what it closed and the worker skips its close (or vice
  versa), so the fd is closed exactly once. Canonical missed pattern (commit
  ae40710fe8, re-flagged by Codex after an earlier WRONG "double-close is safe"
  comment): `close_idle` called `net.close` on Windows AND the worker's `handle_conn`
  defer called `conn.shutdown()` on the same handle. Fix: `was_force_closed` ownership
  set; keep the tracker lock across the loop so the POSIX sole-closer stays ordered
  after `net.shutdown`. **Then enumerate ALL side effects of the call you gate
  away.** The first attempt at the ownership transfer *skipped* `conn.shutdown()`
  entirely on the force-closed path — but `shutdown()` does two things: free the
  mbedtls TLS resources (SSL ctx, config, certs, RNG, ALPN) AND `net.close` the
  socket. Skipping it to avoid the second close leaked all the TLS state (Codex,
  #27542, commit 31405a6150). When you gate a call to suppress ONE side effect,
  list its other side effects and preserve them: here, relinquish socket ownership
  (`conn.owns_socket = false`, since `shutdown` gates `net.close` on `owns_socket`)
  and STILL call `conn.shutdown()` so the TLS free always runs. Run the mechanical
  detector: `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_close_idle_double_close.v`
  (exits 1 if the worker does not relinquish ownership via `owns_socket = false`,
  or if `conn.shutdown()` is gated away on the force-closed path — catching both
  the double-close and the TLS-cleanup leak).
- **A TOCTOU guard on ONE side effect does not protect every OTHER side effect
  in the same branch (partial-guard miss) — a Matrix 3 instance:** when a branch performs an
  "exactly once, only by whichever caller wins a race" cleanup — deleting a
  shared-map entry after an identity/ownership check confirms this caller
  still owns the entry — enumerate EVERY OTHER statement in that same branch
  that shares the identical "exactly once" requirement (a `.release()` call,
  a refcount decrement, closing a resource). Each one needs the SAME win/lose
  boolean, not just the first statement a fix happened to guard. A dangerous
  tell: an idempotent call (`shutdown_when_idle()` — just sets a bool, safe to
  call twice) sitting right next to a non-idempotent one (`release()` —
  decrements a shared counter) with only the delete gated makes it easy to
  reason "this block is all safe to call twice" without checking that EVERY
  statement in it actually has that property. Missed on vlang/v#27643
  (self-caught in review, not Codex, pullrequestreview-4636271901):
  `h2_round_trip`'s idle-expiry eviction guarded `t.h2_conns.delete(key)`/
  `t.h2_dial_id.delete(key)` with `if voidptr(existing) == voidptr(conn)`
  (added specifically so a caller that lost the removal race skips the
  delete), but the following `conn.shutdown_when_idle()`/`conn.release()` ran
  UNCONDITIONALLY. Two concurrent callers racing the same idle-expired
  connection — or a concurrent `Transport.close_idle()`, which releases every
  h2 conn unconditionally by design — both fell through to the ungated
  `release()`, over-decrementing `H2MuxConn.refs` (verified empirically:
  `refs == -1` with two racers). This is the sibling of `close_idle()`'s own
  "clear the map atomically with collection, so no caller can ever re-release
  a connection this call has already claimed" pattern and of
  `evict_oldest_idle_locked`'s atomic delete-and-return-victim pattern,
  applied to only HALF of the branch's side effects — the branch that
  introduced the gap (round 5) was itself the fix for a DIFFERENT finding,
  and neither that round's own `/vreview` pass nor Codex caught it; it
  surfaced only on a later, unprompted fresh-eyes re-review with no code
  changes to react to. Fix: compute the win/lose boolean once
  (`won_removal := voidptr(existing) == voidptr(conn)`), gate every
  "exactly once" side effect on it, not just the map mutation. Run the
  mechanical detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_ungated_release_after_conditional_delete.v <file>`
  (enumerate-and-verify: flags a `.release()`/`.shutdown_when_idle()`/
  `.close()`/`.free()`/`.shutdown()` call that runs unconditionally after an
  identity-guarded `.delete()` earlier in the same function).
- **Shutdown-driving thread blocking on a full resource (wake/cleanup self-deadlock):**
  When the SAME thread both (a) blocks on a bounded resource and (b) is responsible
  for the shutdown wake/cleanup, a full resource wedges shutdown. Classic shape: an
  accept loop does `ch <- conn` (blocking send to a worker pool) and, after the loop,
  runs the shutdown sequence (`ch.close` → `close_idle` → `ws.wait`) — all on one
  thread — while `stop()`/`close()` only flip `s.state` from another thread. If every
  worker is busy and the channel buffer fills, the accept thread blocks on the send,
  never re-checks `s.state`, and never reaches the cleanup, so `stop()` is delayed
  until a worker frees a slot (up to a handshake/operation timeout). For every
  blocking call on a thread that also drives shutdown, require a state-polling escape
  (a `select` with a timeout branch that re-checks the stop flag), and have that
  thread clean up the in-hand item it could not enqueue. Detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_tls_accept_send_interruptible.v` (exits 1
  on a bare `ch <- conn` with no interruptible `select`). vlang/v#27552
  (discussion_r3474019355). **Testing note:** a shutdown/liveness test that PASSES on
  the buggy commit is a FALSE GUARD — Phase R (reproduce → exit 1 on the buggy commit)
  is mandatory here; force the timing assert to fail once to read the real measured
  value. To genuinely stall an mbedtls server handshake a client must send a *valid*
  ClientHello then withhold the rest (a bare `dial_tcp` fails fast), and the handshake
  budget comes from `accept_timeout` when finite (not the `tls_handshake_timeout`
  fallback) — see reference/code-review-misses.md.
- **Spawned blocking reader needs a guaranteed wake path at teardown:** When a
  constructor `spawn`s a background thread that blocks in `transport.read()` (or any
  blocking I/O on a handle it does not own), there must be a teardown path that is
  GUARANTEED to close/interrupt that handle — otherwise an idle retirement or
  last-reference release leaks the thread and the connection forever (a blocking read
  on a silent transport never returns). Red flags: a close/shutdown callback that is
  *optional* (`fn () = unsafe { nil }`) or a transport abstraction with no `close()`,
  so the only wake mechanism can be absent; teardown that guards the close with
  `!= unsafe { nil }` and silently no-ops when nil. Require the closer to be non-nil
  (panic/assert at construction) so the teardown→close→reader-exit chain always exists.
  Detector: `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_mux_requires_closer.v` (exits 1 if
  `new_h2_mux_conn` accepts a nil `close_transport`). vlang/v#27413
  (discussion_r3475761576). **Testing note:** if the fix makes the bad input panic, the
  nil case can't be exercised at runtime (panic aborts the V test binary) — reproduce it
  STATICALLY with the detector; a runtime test that passes a *valid* closer is a false
  guard for the nil bug (it works on the buggy commit too). See reference/code-review-misses.md.

### Angle G — Security
For changes that touch TLS/crypto, `unsafe {}` blocks, or protocol parsing arithmetic, check the
security-specific surface. Skip this angle for pure doc/test-only changes with no C interop and no
wire-parsing code.
- **G1 TLS/crypto config:** In any file that creates or configures an `SslConfig` or connects via
  mbedTLS, verify: (a) `min_version` is explicitly set; (b) the cert validation callback is
  non-null for production code; (c) the ALPN list is complete and ordered (`h2` before `http/1.1`).
  Plaintext fallback paths must be guarded or documented. Run the mechanical detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_tls_weak_config.v`
  (exits 1 if any changed file creates `SslConfig{}` or assigns `ssl_config` with no `min_version`
  anywhere in that file).
- **G2 unsafe{} block scrutiny:** Every `unsafe {}` block in changed files is a potential
  memory-safety hole. For each block: (a) trace pointer arithmetic for out-of-bounds access;
  (b) verify slice length/capacity bounds before indexing; (c) check C-interop object lifetime —
  does the V GC own the pointed-to object, or did C allocate it? Run the mechanical detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_unsafe_blocks.v`
  (exits 1 and lists every changed file containing `unsafe {}`; review each occurrence).
- **G3 Wire-integer arithmetic overflow:** Protocol arithmetic on wire-derived values (window
  sizes, content-length, frame sizes) wraps silently for `u32`/`i32` in V. For every arithmetic
  expression that adds or multiplies wire-derived fields: verify the result cannot exceed the V
  type's max before reaching a range guard. The canonical miss pattern: `u32 + u32` wraps to a
  small value that passes a guard comparing against the same `u32` max — the guard sees the
  wrapped result and incorrectly accepts it.
  **This check is NOT limited to wire-decoded (parse-side) values — encode-side, caller-supplied
  values are the RISKIER case, not a safer one to skip.** A parse-side `a + b > limit` check is
  often provably overflow-safe because `a`/`b` both come from a bounded decoder (e.g.
  `decode_varint`, itself capped at 2^62-1) — but the identical-LOOKING check on the ENCODE side,
  where the value is an arbitrary caller-supplied parameter with no such bound, is NOT
  automatically safe just because it mirrors a parse-side check that IS. When a new
  offset+length-style bound check is added by copying an existing sibling check (parse→encode or
  vice versa), re-derive whether the safety argument's PRECONDITION (each operand individually
  bounded) actually holds at the NEW call site — do not assume "the sibling already proved this
  pattern safe" transfers across the parse/encode boundary. If it doesn't hold, use an
  overflow-safe form instead (bound the unconstrained operand alone first, then a subtraction-
  based comparison: `if a > limit { reject }` then `if b > 0 && a > limit - b { reject }`, never
  `if a + b > limit`). Missed on vlang/v#27882 (Copilot review pullrequestreview-4888843234,
  self-inflicted): `encode_stream_frame`'s `offset + u64(data.len) > max_varint` check was copied
  verbatim from `parse_crypto_frame`'s own (correctly overflow-safe, since both its operands come
  from `decode_varint`) check in an EARLIER round of this same review — the copy carried the
  check's SHAPE but not its precondition, since `encode_stream_frame`'s `offset` is caller-
  supplied and can be arbitrarily close to `u64::MAX`, making the sum itself wrap.
- **G4 Information leakage:** `eprintln`, `println`, and log calls that interpolate internal state
  risk leaking session IDs, keys, or user data. For every log/print call in the diff, verify the
  interpolated variables are safe to expose (frame types, error codes, byte counts are fine; keys,
  tokens, passwords, session IDs are not). Run the mechanical detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_info_leak.v`
  (exits 1 if any log/print call interpolates a variable whose name contains `token`, `key`,
  `secret`, `password`, `nonce`, or `credential`).
- **G5 Request smuggling:** HTTP/2 forbids Transfer-Encoding (RFC 7540 §8.1.2.2 — connection-
  specific headers are prohibited). Any `transfer-encoding` header forwarded to an HTTP/1.1 backend
  without stripping creates a request-smuggling vector. Grep changed handler files for
  `'transfer-encoding'`; flag any occurrence that is not actively stripped or rejected.
- **G6 Timing-safe comparisons:** V's `==` on strings is NOT timing-safe — it leaks shared-prefix
  length via timing side-channel. Any `==` comparison where either operand is named `token`,
  `key`, `secret`, `password`, `nonce`, or `credential` must use a constant-time comparison
  function. Grep changed files for `== .*token`, `token.* ==`, and analogues for the other names.
- **G7 Self-referential C-interop struct stored by value:** a C-interop wrapper struct whose
  setup call (`dial`/`connect`/`accept`/`init`) wires an internal pointer to the struct's OWN
  address (e.g. mbedtls's `mbedtls_ssl_set_bio(&s.ssl, &s.server_fd, ...)`) becomes unsafe to
  copy afterward — assigning it into a value-typed struct field bitwise-copies the bytes,
  leaving the copy's internal pointer aimed at the ORIGINAL object's fields, not its own. Any
  struct meant to OWN such a connection for later reuse (pooling, handing to a background
  reader) must store it by pointer. Before writing a NEW pooled/long-lived wrapper around a
  connection type, grep for how an EXISTING pooled wrapper in the same file/module stores the
  identical type — a fresh wrapper written without that sibling-search check is exactly how
  this class of bug gets introduced. Run the mechanical detector:
  `v run \"${CLAUDE_PLUGIN_ROOT}\"/detectors/detect_pooled_conn_stored_by_value.v <file>`
  (exits 1 if a struct field is `ssl.SSLConn`/`mbedtls.SSLConn`/`openssl.SSLConn` by value
  instead of `&ssl.SSLConn` etc). Missed on vlang/v#27643 (Codex P1,
  pullrequestreview-4631763931): `H2PooledTransport.conn` was a bare value field while the
  sibling `H1PooledConn.ssl` (same file family) was already `&ssl.SSLConn`.
- **G8 Hand-rolled/standalone crypto path — G1's checks re-derived, not grepped:** G1's own
  detector (`detect_tls_weak_config.v`) is keyed on `SslConfig{}`/`ssl_config` construction —
  it is BLIND to any TLS/handshake implementation that deliberately bypasses that construct
  (a hand-rolled protocol state machine, a "standalone" X.509 call that never builds an
  `mbedtls_ssl_context`, a from-scratch TLS 1.3 layered under something else). For ANY new file
  whose own doc comments say "standalone", "does not construct an SSL context", or "bypasses
  the SSLConn-mediated path" — this is not a hint to relax G1, it is a signal to run G1's
  checklist BY HAND since the detector cannot: (a) is the hostname/SAN/CN actually checked
  against the peer's certificate somewhere, by SOME caller, with a REAL hostname value (not
  `nil`/empty by default)? (b) is ALPN (or whatever protocol-selection mechanism the spec
  requires) actually sent AND the peer's selection actually validated against what was
  offered? (c) is every MUST-level authentication/binding value the spec defines (e.g. a
  connection-ID or session-binding field meant to detect a MITM/off-path attacker) actually
  compared, not merely parsed and stored? (d) **is the certificate actually AUTHORIZED for
  the role it's being accepted in** — chain-of-trust and hostname say nothing about whether
  a leaf cert's KeyUsage permits digitalSignature or its ExtendedKeyUsage permits serverAuth;
  a real TLS stack enforces this via a SEPARATE call (mbedTLS: `mbedtls_ssl_check_cert_usage`)
  that a standalone `mbedtls_x509_crt_verify`-only path never gets for free. And (e) does the
  claimed algorithm/scheme actually match the peer's REAL key properties, not just its general
  TYPE — a signature-verification call that only checks "is this an EC key" (not "is this
  SPECIFICALLY the curve the claimed scheme name requires") accepts a P-384/P-521 key under a
  scheme name that names P-256 specifically; this is a protocol-identity mismatch, not broken
  crypto, and just as invisible to a diff-driven read as (a)-(d). A verification FUNCTION existing and being fully
  correct in isolation is not evidence any of this holds — trace its actual call sites and
  confirm a real value reaches it end-to-end; an unwired or nil-defaulted parameter at any
  point downgrades a implemented check to a no-op. Missed on vlang/v#27680
  pullrequestreview-4781706846 (Codex, 3 rounds after this exact file had already been through
  `/vreview`): `net.mbedtls.verify_certificate_chain` passed `cn: nil` to
  `mbedtls_x509_crt_verify` (no caller ever had a hostname to give it — the standalone design
  didn't expose one), so ANY certificate for ANY hostname passed as long as the CA chain
  validated; `net.quic`'s ClientHello never sent an `application_layer_protocol_negotiation`
  extension at all (RFC 9001 §8.1 makes this mandatory for QUIC — no diff-driven angle
  reacted, because there was no "wrong" line, only an absent one); server transport
  parameters were correctly checked for `initial_source_connection_id` but never for
  `original_destination_connection_id`/`retry_source_connection_id` (RFC 9000 §7.3's own
  anti-tampering authentication, exactly the "off-path attacker" scenario G8 asks about).
  **A FOURTH round (pullrequestreview-4783410111) found checklist items (d) and (e) above —
  both added AS A RESULT of this round, meaning the checklist that existed at review time
  still didn't cover them.** `verify_server_certificate_chain` checked chain-of-trust and
  hostname (G8's original (a)) but never KeyUsage/ExtendedKeyUsage (P1 — the highest severity
  finding on this PR so far); the ECDSA CertificateVerify path confirmed a key was SOME EC
  key but never that it was the SPECIFIC curve (secp256r1) the SignatureScheme name claims.
  Both fixed by wiring up EXISTING, unmodified mbedTLS library functions
  (`mbedtls_x509_crt_check_key_usage`/`check_extended_key_usage`, `mbedtls_pk_ec`+
  `mbedtls_ecp_keypair_get_group_id`) that a standalone caller simply never invoked — this
  codebase added no new crypto, only closed a wiring gap, the same shape as G8's original
  ALPN/hostname findings. **Honest limitation, stated rather than glossed over:** neither fix
  could be regression-tested against the ACTUAL rejection case with a real certificate — this
  repo has no fixture with a restrictive KeyUsage/EKU or a non-P256 EC key, and fabricating
  one requires either a full X.509-writing binding or an external tool, neither done here.
  Tests cover the positive path (existing certs still accepted) and the closest available
  negative proxy (an RSA key exercises the same "not the expected key shape" guard clause a
  wrong-curve EC key would also hit) — genuine coverage, but not a substitute for a real
  wrong-curve/restricted-EKU certificate exercising the literal reported scenario. When a
  finding's rejection path can't be proven with an available fixture, SAY SO explicitly in
  the fix's own commit/test comments rather than presenting adjacent-case coverage as if it
  were the same thing.
  **This is now a standing matrix, not an ad-hoc technique.** The original advice here was
  "write out every MUST/MUST NOT as a checklist BEFORE reading the diff" — an ephemeral,
  reconstruct-it-from-memory-every-time checklist. That ad-hoc version was tried on this exact
  PR's own subsequent full-file holistic review and it STILL missed the Fixed Bit check (RFC
  9000 §17.2/§17.3.1), caught only by a third Codex round (pullrequestreview-4782360314) —
  proof that recall-driven checklisting isn't reliable even right after being named as the
  fix for a related miss. `${CLAUDE_PLUGIN_ROOT}/skills/code-review/quic_conformance_matrix.md` is the
  closed version of this: a maintained file, walked row-by-row like Angle E's H2 matrix,
  not re-derived from scratch each review. Walk it for any `vlib/net/quic/` change; extend it
  (new section, not a new file) when a later phase (packet protection, streams, loss
  detection) adds requirements it doesn't cover yet.
- **G9 Time-unit-scale mismatch — verify the convention via an EXISTING TEST
  ASSERTION, not by inspecting one sibling's conversion call:** when a module
  combines a computed `time.Duration` (real, nanosecond-scale per V's `time`
  package) with a raw `u64`/`i64` clock value (`now`, a stored timestamp) via
  arithmetic, the raw value's OWN scale (nanoseconds? milliseconds? something
  else entirely) is easy to get backwards, and a WRONG assumption about it is
  self-reinforcing: once one function in the module gets it wrong, every
  later function "fixed" to match that function's own (wrong) pattern looks
  locally consistent while being wrong in the same direction. The reliable
  source of truth is NOT a doc comment phrase like "milliseconds, matching
  every other deadline in this file" (that can itself be the author's own
  wrong assumption, restated with confidence) — it's an EXISTING TEST that
  already asserts a concrete before/after relationship between the raw value
  and a named `time.*` constant (e.g. `assert x == 1000 * time.nanosecond`
  for a `now`-delta of exactly 1000, or `assert smoothed_rtt == 100 *
  time.millisecond` for a 100_000_000-unit delta) — that assertion is already
  passing, so it is empirical proof of the TRUE convention, not an opinion
  about it. Before writing OR reviewing any fix that adds/removes a
  `.milliseconds()`/`* time.millisecond`/similar conversion at a boundary
  between a `Duration` and a raw clock value, grep the module's own test
  files for an assertion of this shape and let it settle the question — do
  not infer the convention from a neighboring function's own conversion
  call, since that function can be the FIRST instance of the exact same
  mistake. Missed and then self-caught on vlang/v#28083 (net.quic Phase 9):
  `idle_timeout_deadline()`'s original `baseline + u64(timeout)` (no
  conversion) was actually CORRECT — `now` throughout the module is a
  `time.sys_mono_now()`-sourced nanosecond instant (documented in
  `IdleTimeoutState.last_reset`'s own doc comment, one line the author had
  already read but not weighted correctly) — but a fix session, working from
  an assumption carried over from an EARLIER, ALSO-WRONG fix elsewhere in the
  same file (`closing_or_draining_deadline`'s pre-existing `.milliseconds()`
  call, which looked like established precedent), "corrected" it to ADD
  `.milliseconds()`, making the deadline arrive almost immediately instead
  of after the real timeout. The regression test written to Phase-R this
  even PASSED against the (actually broken) pre-fix code on the first
  attempt, because its own `now`-delta magnitudes were ALSO chosen under the
  same wrong millisecond assumption — a variant of the stale-timer-masks-the-
  gap pattern, but caused by BOTH the code and the test sharing one
  incorrect premise rather than one masking the other. The convention was
  only settled by grepping `loss_detection_test.v`'s own pre-existing,
  already-passing assertions (`assert ld.rtt.latest_rtt == 1000 *
  time.nanosecond` for a `now`/`time_sent` delta of exactly 1000), which
  independently and unambiguously proved nanosecond-scale. No mechanical
  detector for this one — the correct convention is a semantic fact about
  the module, not a syntactic pattern; the actionable habit is "grep for an
  existing `assert ... == N * time.<unit>` in the module's own test suite
  before trusting any doc comment or sibling conversion call."

### Angle H — Absence search (what MUST exist but doesn't)

**A diff only shows what changed — it cannot show what should have changed
and didn't, or what was never there at all.** Every angle above (A–G) reacts
to a line that exists; this one is different in kind, not degree — for each
question below, the finding IS the silence, not a line. This exact
principle already runs the two most mature systematic mechanisms in this
skill: Angle E's H2/QUIC conformance matrices (a MUST with no matching
`file:line` is a GAP row) and Angle G's G8 hand-rolled-crypto checklist (a
verification step no call site actually reaches is a no-op). Angle H names
the general frame those two specialize, so the same discipline gets applied
everywhere — not only to protocol and crypto — instead of staying buried
inside one security sub-bullet where it's easy to forget applies more
broadly.

Ask, for every file/function touched or newly introduced:

- **What MUST exist but has no diff line?** A mandatory extension, a
  required validation step, a spec-mandated field the code silently never
  sets or sends. Angle E's matrices are the maintained answer for H2/QUIC —
  walk them. For anything else, derive the requirement from the relevant
  spec/contract by hand and write it down as a checklist item BEFORE
  searching for it, the same way Angle G's G8 does for crypto; do not trust
  recall alone (rev 23's own retrospective: an ad-hoc "checklist from
  memory" pass on this exact code still missed a one-sentence MUST).
- **What field/extension/authentication check is absent?** Not "is this
  check wrong" but "is this check missing entirely" — a certificate
  property never verified, an identity binding never compared, a
  capability gate that some but not all callers pass through. Angle G's G8
  is the maintained answer for TLS/crypto identity; the same question
  applies to any other authorization/authentication surface this codebase
  grows.
- **What error path/wakeup/free is required but missing?** For every
  condition-variable a waiter blocks on, does EVERY state transition it
  depends on actually signal it (a missed transition is a permanent hang,
  not a wrong value)? For every acquired resource, does EVERY return/error
  path release or free it? For every admission gate, does EVERY code path
  that touches the guarded resource actually check it? This is Angle F's
  own territory (swallowed-write-error windows, admission-gate invariants,
  `.free()` audits) — Angle H's contribution is running it as an
  EXHAUSTIVE enumeration (every waiter, every path, every caller), not just
  the one site a diff happened to touch. **No maintained matrix exists for
  this domain yet**, unlike E and G8 — state that limitation rather than
  implying equivalent coverage, and enumerate by hand each time until one
  gets built.
- **Does a "this is out of scope" note actually name what it exempts, or
  does it just READ like it covers more than it does?** A scope-narrowing
  comment ("connection migration is out of v1 scope") is a claim about ONE
  capability, not a blanket exemption for every requirement that happens to
  mention the same wire object. Before writing (or trusting) such a note:
  pull the relevant RFC section and list every MUST/SHOULD that names the
  object in question, then mark each one "exempted by this scope note" or
  "applies regardless of the deferral" — explicitly, not by implication.
  The failure mode is specifically that the note READS as if it justifies
  skipping everything nearby, and nobody re-checks which requirements are
  actually independent of the deferred capability. Missed on vlang/v#28406
  (external review, 2026-09-07): new NEW_CONNECTION_ID/RETIRE_CONNECTION_ID
  frame handling was written to a generic no-op `else` branch with a
  comment that connection migration is out of v1 scope — true for the
  capability of USING an alternate connection ID, but RFC 9000 §5.1.2's
  "when Retire Prior To increases, the receiver MUST stop using the
  corresponding connection IDs" and §19.16's "a RETIRE_CONNECTION_ID naming
  a sequence number this endpoint never issued MUST be treated as
  PROTOCOL_VIOLATION" are both independent of whether migration itself is
  implemented — this endpoint has exactly one locally-issued CID (sequence
  0) regardless, so the §19.16 validation was fully actionable, deferred
  only because the scope note read as broader than it actually was.

- **Does every cache key cover every input that can change the cached
  output?** A key over an external tool's output (a precompiled header, an
  object, a probe result) that names the tool and its argument vector still
  leaves out what the tool reads from its environment: `CPATH`,
  `C_INCLUDE_PATH`, `INCLUDE`, `PATH` (which picks the toolchain and the
  headers it brings), and the working directory a relative `-I` resolves
  against. Enumerate every input of the tool (command line, environment,
  cwd, the files it reads) and name where each one enters the key, or why
  it cannot change the output. The sibling is usually another key over the
  same tool already in the codebase: diff the two input lists. Missed on
  vlang/v#31581 (medvednikov, review 5725704734, comment 4433887205):
  `v3_windows_pch_key(identity, args)` hashed the compiler identity, the
  header text and the arguments, while the sibling `v3_include_search`
  already keyed on the include environment. Switching `CPATH` from `sdk1`
  to `sdk2` reused the old PCH: a fresh unit emitted `ret i32 101` where a
  plain compile gave `102`. Run the mechanical enumerate-and-verify check
  on every changed file: `detect_cache_key_environment.v` (flags a
  `*_key`/`*_identity`/`*_signature` function that takes an argument vector
  and names no `getenv`/`environ`/`environment`/`getwd`; exit 1 on
  `035f15b229`'s `windows_pch.v`, 0 on `67dbd968cd`'s). A flag is a
  candidate, not a bug: confirm it by naming where each environment input
  enters, for example a cache directory that already carries it.

- **Does a broad delete's target contain something another pass decided to
  keep?** A recursive delete of a parent folder undoes every protection applied
  below it. For each `rmdir_all` or equivalent, list what that folder can hold
  that some other pass keeps (a held lock, an in-use entry, a pinned file), from
  every configuration that can place it there: the configured path as well as
  the default one. Also list every other folder the
  same run clears, and every keeper that can sit inside another keeper. When a
  finding names one path, the fix protects the list that path came from, and
  its test takes the path as a parameter. Missed on vlang/v#31848 (medvednikov,
  comment 6688815559, reviewed `fa9eed702f`): the fix for the same bug one round
  earlier exempted the literal `<VTMP>/tools`, while `tool_cache_wipe_targets()`
  in the same file also returns `VTOOLS_CACHE_DIR`, so
  `VTOOLS_CACHE_DIR=<VTMP>/custom-tools` still lost the stage and lock of a live
  build while the output said it had kept them. The same shape held for
  `<VCACHE>/tools`, `<V3CACHE>/tools` and a root inside another root. A list from
  the environment was not enough either: the next round removed the only spelling that
  led to a root, so the wipe after it deleted the build. Ask what marks the thing on
  disk, and find it there. Regression test:
  `test_wipe_cache_keeps_a_live_build_wherever_the_tool_root_is` in
  `cmd/tools/vwipe-cache_test.v`. No detector: which folders can hold what is a
  fact about the configuration, not a syntactic pattern.

**Artifact: absence-search checklist.** One line per question above: the
requirement/check/path considered, whether it's present (`file:line`) or a
GAP, and — if a GAP — whether it was fixed this review or logged. State
"none applicable to this diff" explicitly for a question that genuinely
doesn't apply, rather than omitting it.

### Angle I — Doc-contract-to-call-site parity

**A function can be 100% correct and still lie to the next reader.**
Angles A–H all ask questions about the CODE — is it right, is a check
absent. This angle asks a different question: does the function's DOC
COMMENT fully and accurately describe the contract its real callers
already depend on? A doc comment that under-specifies a parameter's
semantics, or states a calling-order rule an existing caller doesn't
follow, is invisible to every other angle — the code is correct, the
behavior is correct, no test fails.

For every function this diff introduces or whose doc comment this diff
changes:
- **Parameter semantics vs. real call sites.** If the doc describes what a
  parameter must contain (a length, a composed value, a specific
  encoding), pull up every actual call site's expression for that argument
  and confirm the doc's description matches it exactly — not "close
  enough." A doc that says "the header's length" when every caller
  actually passes `header.len + something_else` will mislead the next
  caller who reads only the doc. Missed on vlang/v#27880 (GitHub Copilot,
  pullrequestreview-4875246955): `pad_initial_payload`'s `header_len` doc
  never mentioned it must include the packet-number field length, even
  though its one real caller already did.
- **MUST-X-before-Y ordering vs. existing callers.** If the doc states a
  required call order ("callers MUST call A before B"), grep every
  existing caller of B (including test files) and confirm each one
  actually calls A first. Do this both when the function is new AND
  — separately — every time a LATER commit tightens or adds such an
  ordering rule to an EXISTING function's doc comment; a caller written
  before the rule existed is not automatically compliant with it. Missed
  on the same PR: `parse_retry_packet`'s "MUST call
  verify_retry_integrity_tag first" sentence was added in a later round
  than the test that called it in the wrong order — the repeat-offender
  contract re-derivation (Phase 0) checked the tightened function's own
  body against the new rule, but never swept its existing callers.
- **Two specific triggers to watch for, since neither is caught by any
  other angle:** (1) a NEW function written inside a FIX commit — fix
  verification checks "does this satisfy the reported finding," not "does
  this new function's doc fully specify its contract"; (2) a doc-only
  contract-tightening edit to an EXISTING function that changes no runtime
  behavior — the "impact analysis before narrowing behavior" check (Phase
  4 of `/codex-respond`) only fires on BEHAVIORAL changes, so a doc-only
  clarification slips past it with no test to catch the resulting
  inconsistency.
- **A claim that something doesn't exist is a search result: search for the
  concept.** Before writing "X has none" in a comment or doc, grep the concept
  and read the hits, rather than one guessed name. Missed on graphify#161:
  "`params` has none builtin declares" came from a grep for `MethodParam`, and
  builtin declares `FunctionParam`.
- **A comment that hands a guarantee to another function is a claim about
  THAT function — read it.** "X stays private (test_private)", "bounded by
  the caller's cap", "validated upstream" each name a delegate. Open the
  delegate and confirm it covers every case the new code lets through. Two
  predicates for one concept (`is_test_file`, any `*_test.*.v`, versus
  `test_private`, `_test.v` only) are the usual gap. Missed on graphify#149
  (round 2): `sees_in_module`'s doc said another test's declarations stay
  private through `test_private`, which does not cover `b_test.c.v`.
- **A field's doc that names its consumers goes stale when the diff adds
  one.** When new code starts reading an existing field, grep the field's own
  doc for "only", "used by", or a named function, and update it. Missed on
  graphify#149 (round 2): `DeclSite.no_main` still said only a type alias's
  lookup used it.
- **Prose docs (README, design notes, changelog lines) state behavior too.**
  Check each sentence the diff adds against the code's actual condition, word
  for word: "a `-d` option" for a predicate that also accepts `prod`, `test`
  and `js` understates it. Missed on graphify#149 (round 3).

- **A diagnostic names the token the user wrote.** For each error message a change adds or
  reuses, build the smallest program that triggers it and read the text: the name it prints
  must be the spelling in the source (`os.Result`, not `os`). Missed on PR 31981 (adversarial
  r3, decl.v:3170): the refusal named the module for a qualified embed.

**Artifact:** for every doc comment touched or introduced this diff that
states a parameter's composition or a MUST-order rule, one line: the
stated contract, and confirmation (or a logged gap) that every real call
site/existing caller actually satisfies it. Add one line per delegated
guarantee (the delegate read, and whether it covers the case) and per field
or prose doc touched.

### Angle J — Test discrimination (would the tests catch the plausible wrong version?)

**A passing test proves the code does something; it does not prove the test
can tell the right behavior from the nearest wrong one.** Angles A–I review
the code. This angle reviews the tests the diff adds or relies on, and it is
the angle the adversarial review's test lens kept beating `/vreview` on: 11 of
26 confirmed findings across three rounds of graphify#149 were tests that
would stay green under a plausible regression. For every behavior the diff
adds or changes:

- **Both sides of every new gate.** For each new boolean condition (a filter,
  an admission check, a dedupe), name the input that must pass and the one that
  must be rejected, and point at the test asserting each. A gate tested only on
  its passing side survives being replaced by `true`. graphify#149: the global
  gate (untyped vs typed non-fn), `named_fn_type`'s "resolves to a function"
  guard, `enum_mods`' de-duplication.
- **Every clause of a compound condition.** For `a && b && c`, each clause
  needs a test that fails when that clause ALONE is dropped. graphify#149:
  `csite.no_main && csite.is_main && is_test_file(file)` had a positive test
  only, so dropping either of the last two clauses passed everything.
- **Inputs on which the alternatives differ.** If the code chooses between two
  branches, results or targets, the fixture must make the wrong choice give a
  DIFFERENT observable result. graphify#149: the `$if` fallback test's two
  branches both returned `int`, so taking the wrong branch gave the same edge.
- **Each branch of each changed lookup.** A function with an unqualified and a
  qualified path, an exact and a fuzzy match, or a per-file and a per-id key
  needs a case down each. graphify#149: `zero()` on a qualified flag enum, the
  exact-vs-reaches tie-break, the per-file site key.
- **Phase R with the nearest wrong implementation, not only `if false`.**
  Disabling a fix outright shows the test notices the fix's absence. Also
  mutate it to the most plausible WRONG version — the old key, the looser
  prefix, the other branch, a dropped clause — and confirm a test fails for
  each. A fix that survives "plausible wrong" mutations is pinned; one that
  only fails `if false` is not.
- **A rejection test must observe the rejection, not a successful build.** For
  a gate that refuses an input, assert the failing exit AND the diagnostic text.
  A test that only checks the program runs passes when the gate is missing,
  because the input then compiles through another path. Run the test on the buggy
  code and confirm the test fails there. The refused input itself usually builds
  there, since the gate is what's missing, so only the exit and the diagnostic
  tell the two versions apart.
  Missed on the fastc `$new(int)` case: the build succeeded and printed `0` before
  the guard fix, so an assertion on the run output would have been green.
- **Test the consumer that reads the type, not only the producer.** A value whose
  static type comes from a new lowering (a pointer, an alias) must be exercised
  through every consumer that needs that type: a printing or interpolation
  context, a field access, a deref. Bind it to a local first, because an
  unbound expression can lose its type on a path the test never takes. Missed on
  the fastc `$new` change: `q := $new(Foo); println((*q).a)` failed to compile
  while the assert-only and return-position tests passed.
- **Mutate the writers, not only the reader.** When the fix keeps a counter or
  invariant consistent at N sites (resets, re-syncs, guards), a mutation of
  the site that READS the state proves the fixture notices a broken read; it
  says nothing about writers the fixture never passes through. List every
  writer of that state, add one fixture shape per writer the test does not
  yet reach, and drop each fix site in turn to confirm a test fails.
  vlang/v#31797: mutating only `target_type := u32(0)` passed review while
  `.filter`, `$d`, `${}` and `if` targets were untested, and all four were
  still broken.
- **One row per branch, with the configuration that reaches it.** Every
  `x or { fallback }`, `if ... else`, early `continue` and per-mode path in the
  new code gets its own row, naming the test AND the mode, flag or naming
  scheme under which that test reaches it. A test that runs a program in two
  modes does not cover a branch that only one mode reaches; one row per
  condition hides that. If writing the test showed that a mode cannot reach
  the case (it passed with the fix disabled), record that mode as not covering
  the branch, do not let it count. vlang/v#31799 (adversarial review round 1,
  2026-11-03): the FastC rename's `function_c_names[key] or { fastc_signature_c_name(...) }`
  fallback, the path of the real `builtin` collision, had no row; the test
  collided only with target libc headers, where the table is always
  populated, so dropping the fallback or gating the rename on that mode still
  passed. The author had seen the compact mode pass without the fix while
  writing the test. The undotted main-module key path had no row either.
- **A GAP must name every observable and show none differs.** Before writing
  "GAP: cannot be pinned" for a rejecting side or a mutation, list the
  observables: program output, return values, AND the artifacts the code
  writes (generated C, emitted files, logs, cache entries). For a compiler,
  code generator or formatter, the generated text is always an observable:
  assert on it. vlang/v#31799 round 2: "the method keeps its name" was
  recorded as a GAP ("needs a builtin collision"), and a mutant renaming the
  method instead of the free function passed; four lines asserting on the
  generated C pinned it.
- **Assert that the incidental path was taken.** When the fixture reaches the
  code under test only through a property incidental to the test (a name
  prefix, a size threshold, a module that happens to keep conventional
  names), assert that the path ran (a marker in the output, a symbol in the
  generated text), not only the end result. Otherwise a change to that
  property makes the test pass trivially. vlang/v#31799 round 2: compact-mode
  coverage depended on `starts_with('math')` in the compact-naming rule; the
  test now asserts `__vf_function_mathgeom__Pair_sum(i64 ` in each mode.
- **An assertion of "nothing changed" must read the thing that could change.**
  A negative case has to put the state under test on the path it asserts about.
  graphify `resolve-regular-sites`: a test that a branch of values narrows nothing
  read a field of another variable than the match subject, so it could not fail.
  Mutate every `or { return }` of the new code, since each is a branch with a row.
- **No row counts without a targeted test and a tried mutation.** "No mutation
  tried", or an untargeted suite ("all 223 existing tests") as the
  rejecting-side test, is a GAP row, not evidence. vlang/v#31799 pass 1 counted
  both.

- **An assertion must hold on every target its guard admits.** For each
  literal in an assertion (a type spelling, a width, a path separator, a symbol
  prefix), ask which platform or configuration fixed it, and whether the test
  can run anywhere that value differs. Read the value from the code that decides
  it, or run the case under the differing target. Passing on the author's host
  says nothing about this. vlang/v#31799 (medvednikov,
  pullrequestreview-5759552885, P3): the collision test asserted `i64` for
  `int`, true on the 64-bit host and false on linux/x86; it now reads
  `fastc_output_c_type('int')`, with a generate-only linux/x86 case.

- **Compare base and head on variations, not only your own tests.** For a change
  to what a program's input yields (a resolver, extractor, generator or parser),
  write down the shapes the rule was not written for, then run each on BOTH base
  and head and read the difference. At least: a user type with a method named as
  a builtin's; an alias of the builtin type with its own method; a concrete and a
  generic value; a nested and a multi-value form; a sibling that states less
  coming first; a value the rule's own guard exempts; and a call the existing
  collector can't read. Every difference gets a compiled program showing head is
  right, or it is a finding. This is cheap: one fixture and two builds. A real
  tree doesn't replace it, since it only exercises the shapes it happens to hold,
  and mutants only test the gates the author thought of. Missed on graphify#161:
  39 of 39 mutants were caught and vlang showed none newly unresolved, then
  `/adversarial-review` confirmed 18 findings, nearly all by this comparison.
  **Also run these shapes.** Each has one row in the variation table, whatever the
  rule looks like. Missed by a `/vreview` that wrote this table with 15 rows and
  passed on the graphify `resolve-regular-sites` branch (2026-11-05); together
  they are 15 of the 20 findings `/adversarial-review` then confirmed there:
  - **What else the rule's mark reaches.** A rule written for one case that marks
    or filters every case (a guard recorded for all `$if T is X` so an interface
    can use it): run each other value the mark now touches, an alias of the named
    type and another type parameter in particular, and read what the mark does to
    the old result, in both the positive and the negative branch.
  - **A value that fails the rule's condition but passes its shortcut.** Where the
    code writes "not read here" or "keeps every X", give it an X the program itself
    rejects (an instance that doesn't implement the interface). A shortcut that
    was harmless on an unresolved edge is a wrong edge once the rule resolves it.
  - **Every spelling of the condition, on both sides.** List the forms the parser
    and the old readers accept (`T`, `T.unaliased_typ`, `mut x T`, `[]Iface`, `|`
    unions) and run each through every new reader. A parity row that says "guard
    parsing" without naming each normalization the sibling does is not a row.
  - **A set the rule accepts with a member it can't answer.** A loop that collects
    answers for a set and skips what it doesn't know returns a partial answer that
    reads as complete. Run the mixed set, and grep the real tree for it.
  - **The name as something other than the rule assumed.** A field of that name,
    function-typed and data-typed, as well as a method.
  - **A new key form and everything that clears it.** For each new map or cache,
    list the forms its writers use as keys (a path, not only a name) and check each
    invalidator against each form, then rebind the root of a path in a closure and
    a nested `it`.
  - **Types named from two modules.** Anything that compares types: first grep for
    the module's existing comparator (`same_type`) and use it. Written text plus
    module disagrees on `Foo` and `lib.Foo`, and on `[]string` across modules.
  After fixing a finding from this list, re-run the real-tree comparison before
  calling it done. There, two of the fixes broke sites the rule was written for:
  the corpus diff caught both, the tests caught neither.
  **And these, from round 2 of the same branch** (2026-11-05: 22 confirmed findings
  that came down to 6 defects and 5 test gaps; 5 of the defects were these shapes,
  all in code the round 1 fixes wrote):
  - **A lookup's "none" read as "absent".** A negative conclusion drawn from a
    lookup that also returns none for "can't pick one" or "stopped looking" (two
    embeds, a copy per platform, a depth limit, a type outside the graph, a file it
    may not see). Run each. Conclude absence only from a search that finished.
  - **A set built by owner holds more than its comment says.** For each new
    collection, list what else its filter admits and compare with the comment's
    claim (`iface_fns`, "the methods it declares", also took methods written with
    a body on the interface, so real implementers were dropped).
  - **A made-up value through every reader of the real one.** A stand-in or default
    must meet every test applied after it, nested ones and their `else` included
    (a bare `map` stand-in failed `$map`, so the `else` kept it).
  - **Widening a pattern to a representation two source forms share.** Before
    accepting a wider encoded form, list every source form that encodes to it and
    run each (`t:&T` is both `mut x T` and `x &T`, and V's `is` differs on them).
    Then grep every caller of the widened predicate: splitting the forms at one
    caller leaves the others (the fix guarded the `$if x is Foo` retype, while
    `$if x is $map` kept the wider check, and `x &T` lost base's fallback to an
    unrelated type's method, found by the next pass's full-file read). Run every
    form at every caller against base, and again after each fix to one of them
    (the fix restored `x &T` only, so `mut x T` still linked `Own.clone` where V
    calls builtin's, found by the rerun; the fix that held matched base).
  - **Seeing through one wrapper when the code strips another.** New unwrapping
    composed with existing stripping: run an alias of each wrapper the stripper
    takes off (`type Pint = &int` became `int` and met `$int`).
  - **A new early return ahead of a function's "undecided" exits.** A `return false`
    added before a `none` path turns "can't tell" into a decision for every test
    that path used to leave alone. Run a value the function doesn't decide (the fix
    for `Pint` above also made `$alias` and `$pointer` false, and V holds both).
  - **A test helper that skips a pipeline stage can't reach what that stage makes.**
    If a branch depends on a later or earlier stage (ids made unique per file), a
    fixture through a helper that skips it passes on the bug. Phase R on the buggy
    code is what shows this: the first test of the alias case above passed there,
    because `graph_of` doesn't run `disambiguate_ids`.
  **And these, from the graphify plain-names batch** (2026-11-05 to 06, rounds of 22,
  13, 20 and 12 confirmed findings):
  - **A node the parser wrote has no source of its own.** Code that reads the file's
    text at a node's position assumes the node came from that text. List what the parser
    lowers or generates into that node kind, and run each in every syntactic position:
    a statement and an expression can lower differently. `literal_captures` read
    `fn [a, b]` at a literal's offset, and a `$tmpl` in an expression is a literal the
    parser writes (vlib/v/parser/tmpl.v), so every local was dropped. The risk had been
    written down and tried only on `return $tmpl(...)`, which lowers another way. A
    reader that finds no such text must leave the old result alone, not take "nothing".
  - **A gate on one path, and the tier the call falls to.** A rule that stops one path
    hands the input to whatever comes next. List every later tier that can give the same
    answer and run the rejected input through to the end. `conversion()` returned none
    because the caller could see functions, then a later tier linked the type anyway when
    the lookup couldn't pick between two copies. Grep every caller of the helper the gate
    wraps (`type_conversion`), not only the path you changed.
  - **A tree with two copies of what the program assumes is one.** A real-tree comparison
    only exercises what that tree holds. Also run a root with two clones of a project or a
    vendored copy of a core module. Dropping an unseen candidate from a tier turned "two
    copies, leave it open" into "one left, link it": 164 false edges between the clones in
    S:/vProjects/native-backend, while the V tree alone showed none.

- **Shapes for attribute and field-declaration changes.** Run each of these on base and head
  before writing the variation table: a keyword or flag word used as an argument inside
  another attribute (`@[foo: skip]`); a leading attribute followed by a section keyword; two
  attribute groups before one field; a grouped declaration after a flagged one; each embedded
  route (plain, qualified, default-carrying, trailing semicolon, closing brace, generic).

- **Shapes for code that models another tool's input (an assembler, a register
  allocator, a shell).** Run each on base and head and, where they disagree, on the
  tool itself (`as` and `objdump`, `gcc -S` with a `# %0 %1` template comment):
  - **Every literal spelling the tool accepts**: decimal, `0x`, leading-zero octal
    (`010` is 8 in GNU as), `0b`, a sign and a doubled sign (`-8`, `+-8`, `--8`),
    a negative immediate (`$-8`), a character literal, an expression (`8+8`), a symbol.
    A parser that reads fewer spellings than the tool reads the rest wrong, not
    nothing.
  - **The size the instruction really moves**, for every place the model takes a size
    from an operand: a count operand (`shlq %cl, mem`), a scalar view of a vector
    register (`movsd`/`movq %xmm0, mem` move 8 bytes), an operand reference, and the
    fallback for an unknown form placed in a scratch slot next to a tracked one.
  - **Each tracked construct nested in itself and in each other one**: a frame in a
    frame, a save of the frame register inside the frame, a save inside a gap.
    One state slot for a construct that can nest is a finding.
  - **Each operand position of each form the model handles**: memory first and memory
    last (`xchg mem, reg` and `xchg reg, mem`), through each base register it tracks.
  - **A directive or prefix alone between the two halves** of anything carried across
    statements (`rep` then `.p2align` then `movsb`).
  Missed on vlang/v#31407 (adversarial round 4, 2026-11-07): 17 of 19 confirmed findings
  were one of these five shapes, and the stack model's tests held none of them.

**Artifact: base-vs-head variation table.** One row per shape: `rule — shape —
base result — head result — same, or the program that justifies the change, or
finding`. State "N/A — reason" for a diff that changes no program's output.

- **A killed mutant shows the clause matters, not that a given line tests it.** For
  each mutant, record the fixture lines that failed, then check that every line written
  to pin that path is among them. A line that never fails tests nothing, whatever its
  comment says. Run an unmutated control through the same build and test path first,
  and confirm the mutation changed the intended site, not an earlier textual match.
  Missed on vlang/v#31407 (medvednikov, comment 6686391495): adding a second output made
  `movl %1, %0` in `const_operands()` name `other` instead of the constant. The
  const-skip mutant was still killed, by lines 86 and 88 to 91, never by line 85. For
  operands written by position, count them again after any edit to the operand list.
- **Read a run's result past its noise, not its first lines.** A filter that keeps the
  first N lines of a compiler's output shows warnings and hides the assertion, so a real
  failure reads as an environment failure, or the reverse. Filter the noise out by pattern,
  and print the count of what was dropped. graphify plain-names round 4: `Select-Object
  -First 3` showed only a C warning on eight tests that had in fact run, and another run
  credited every mutant to an unrelated test that was already failing, because the control
  wasn't enforced by the script: make the script stop when the control fails.

- **An accumulating assignment is a compound condition.** `x = x || y` over several
  attribute groups or several sources needs a fixture where each operand alone decides the
  result, and a fixture where a later source would overwrite an earlier one if `||` became
  `=`. Mutate `||` to `=` and confirm a test fails. Missed on PR 31981 (adversarial r3,
  test-adequacy): the OR-to-assignment mutation passed the whole test file.
- **Every spelling of an entry condition gets a row, not only the common one.** A branch
  reached through several grammar routes (a default-carrying form, a qualified name, a
  trailing semicolon, a closing brace on the same line, a generic) needs one fixture per
  route. A mutation that deletes the check must fail a test for each route, or the table
  names the untested route as a GAP. Missed on PR 31981 (adversarial r3): one spelling of the
  embedded refusal was tested; deleting the check for the other routes passed.
- **A mutation row cites the command that was run.** "Mutation tried" with no command, or
  "not run", is a GAP; the table's last column records the result of the run, not an
  expectation.
- **A block-valued operand keeps its grouping in every operand position.** When an
  emitter wraps a block or statement-expression value (`unsafe { … }`, `lock x { … }`,
  `({ … })`) and adds parens only before some following tokens (`.`, `[`), every other
  position is a candidate: as the LEFT operand of a binary operator (`unsafe { a + b } * c`
  emitted as `a + b * c`), as a RIGHT operand (the inner operator binds to the left
  operand), and nested inside another block. Run each operator in both positions, nested
  and not, against base; a wrong value is a finding even when base shares it, because the
  change's own grouping is what should have covered it. Missed on the fastc transparent
  unsafe regroup (`expr.v:2615`, `$zero`/`$new` branch, rev 96): four confirmed findings
  from `/adversarial-review` (left operand, nested, right operand, plus the alias
  `$zero`) that `/vreview` passed, because the angle that reviews a regroup read the
  `.`/`[` branch only. Mechanical gate: run `vlib/v/gen/fastc` probes `unsafe { a + b } * c`,
  `2 * unsafe { a + b }`, `unsafe { unsafe { a } + b } * c` with `-b fastc` and compare with
  the expected value.

**Artifact: test discrimination table.** One row per new gate, clause, branch
or choice: `condition — mode/configuration reaching it — passing-side test —
rejecting-side test (or GAP, with the observables considered) — plausible-wrong
mutation tried — result — fixture lines that failed`. State "no new conditions"
explicitly when the diff adds none.

### Angle K — Acceptance regression (what the old build accepted that this diff now rejects)

**A diff that adds a diagnostic, a rejection or a validation gate fails in two
directions, and every angle above hunts only one of them.** Angles A–J ask
whether the new check misses a case it should report (a false negative). The
other direction is the one a maintainer finds first: a program the previous
build compiled and ran correctly, now refused (a false positive). vlang/v#31407
(medvednikov, comment 6633807070, 2026-11-04): six rounds — three `/vreview`,
three `/adversarial-review` — on the raw-asm clobber check found nothing, then
the maintainer built the pre-PR revision and the PR head side by side and ran
four ordinary programs through both: a named `const` operand (typed by V at
native width, emitted by cgen as an uncast value, so GCC used 32 bits), the
`flags` clobber (already listed beside `cc` in `util.asm_clobber_is_special`),
an `.intel_syntax` region (operand order reversed, so "the last operand is the
destination" was wrong), and an `.if 0` body (never assembled). All four passed
on the old build and were rejected by the PR. None was exotic: each was a word
from the input vocabulary the old build already accepted that nobody had
enumerated, because every lens was pointed at the new check and none at the
old acceptance surface.

For every diff that adds or widens a rejection:

- **Acceptance widening is a regression surface too, and the reference is the target base's
  parser, built fresh.** A backend that accepts a construct the frontend refuses is a
  defect when the target base's own diagnostics refuse it: grep the diagnostic text in the
  parser (for example `cannot use attributes on embedded structs`) and build the reference
  from the PR base, not from the worktree's own binary, which can be older than the base.
  Do not exclude widening from scope on the grounds that the program is "invalid" until the
  parser diagnostics for that input have been checked. vlang/v PR 31981 (2026-11-07): the
  fastc change accepted `Inner @[json: '-']` on an embedded field; a reviewer pointed at the
  parser's diagnostic. The review had scoped widening out, and the parity check ran against a
  stale binary, so neither step read the parser.
- **Refusals must cover every entry point to a construct, not only the common one.** When a
  refusal applies to a construct (embedded fields refuse @[skip] and @[required]), list each
  spelling that reaches it (trailing, default-carrying, leading) and check each one refuses.
  A leading flag that is dropped silently on an embedded field is the same defect as a
  trailing one that is refused. PR 31981, finding 2.

- **Enumerate the accepted vocabulary first, from the code, not from memory.**
  Find every list the OLD code uses to accept or classify this input: keyword
  tables, synonym lists (`asm_clobber_is_special`), directive sets, constraint
  letters and their modifiers (`=`, `+`, `&`, `%`), each modifier beside each
  other operand kind it can share a register with, every expression kind an operand may be, every binding an
  identifier may resolve to (local, parameter, const, global, enum value).
  Write the list down as an artifact BEFORE judging the new check. For each
  entry state whether the new check handles it, ignores it correctly, or
  misclassifies it. An entry the new check never considers is a candidate,
  not a pass.
- **A gate that tests spelling admits more than its name says.** When a condition
  decides from text or shape (`is_ident`, `starts_with`, a character class, a regex),
  list what else has that spelling, then read how the real AST classifies each one:
  keywords, literals, type names, enum values. Each is a vocabulary entry with its own
  program. Prefer deciding from the AST node. Missed on vlang/v#31407 (medvednikov,
  comment 6686391495): `inline_asm_is_ident` was treated as "a named variable", but
  `true` and `false` pass it too, so `"r" (true)` was rejected as 8-bit. Round two had
  already shown `const flag = true` as a C `int`; the fix covered constants, and the
  same reasoning was never tried on the bare literal.
- **Build the list from the source, then keep it open.** Name the old-code location
  each entry came from, one entry per row. A list written from memory, or handed to
  finders in a prompt, repeats the author's blind spots: #31407's round-four finders
  got a list of binding kinds with no literal in it, and none tried one.
- **Build the pre-PR program, not the test.** For each vocabulary entry, write
  the smallest valid program that uses it and that the old build accepts; run
  it through both builds (or through the checker's fixture mode when the host
  cannot execute it). The maintainer's method on #31407 is the template:
  `git worktree add` at the merge-base, build both, run every program through
  both. A fixture in the PR that contains only the inputs the author thought of
  is not this step.
- **Scope directives and modes, not lines.** When the checked input has
  region-changing constructs (a syntax switch, an assembler or preprocessor
  conditional, a macro definition, a mode flag, `$if`), ask what each one does
  to the lines AFTER it, not whether skipping the construct's own line is
  right. "The directive is skipped" was true on #31407 and irrelevant.
- **Treat your own grounding as a hypothesis.** The CONTEXT handed to finders
  on #31407 asserted "AT&T templates" and "an identifier is a typed variable"
  as facts; both were the bugs. Any sentence in a review brief that begins
  "the input is always…" or "X is a…" is a claim the review must test, not a
  premise finders may rely on. Put such sentences into the vocabulary list as
  entries to attack.
- **Read what the next stage actually emits; never infer it from the type.** A
  rule that predicts another tool's behaviour (what register GCC picks, what an
  assembler does with a directive) is a claim about that tool's real input and
  semantics. Generate the output (`-o out.c`) and run the tool. The first fix for
  #31407's const finding reasoned from V types ("a typed constant keeps its type"):
  round-two probes showed `bool` constants as C `int`, `sizeof` as `size_t`, enum
  constants as `int`, and `u16(1) + 2` promoted to `int`. Modelling `.previous` as
  "return to the site" was wrong the same way: it swaps, and `.popsection` restores
  both sections. When the prediction cannot be made reliable, stay silent on that
  input rather than guess; the downstream tool still rejects the real mismatch.
- **A model of another tool that keeps failing is the bug.** If two review rounds
  in a row find new defects in code that re-implements another tool's rules, stop
  patching and replace the model with an allow-list of inputs you can prove, staying
  silent on the rest. On #31407 the assembler state machine took 18, 15 and 13
  confirmed defects across three rounds. The allow-list that replaced it is about
  half the size, and its next round found 14 narrower gaps, closed by tightening the
  list or disclosed as limits. A diagnostic can always say less. State what the
  silence gives up in the PR. The rule binds at the second round even when each finding has a one-clause fix, and it
  covers a resolver or analyzer as well as a diagnostic: anything that picks one reading
  of what another tool would do. graphify's call resolver modelled V's order between a
  function, a type and a const through 22, 13 and 20 confirmed findings, each with a compiled
  program behind it. Replacing the model with "only where the caller can see no function of
  the name" removed the clauses, changed none of the 14 real edges it existed for, and
  brought differences from base on the fixtures from 102 to 40. Disclose what it gives up.
  **Keep a model ledger, because nobody counts rounds by memory.** For every function
  that models another tool (a stack or register tracker, a constraint allocator, an
  assembler or parser state machine), keep one row per review round that touched it,
  inline `/vreview` passes included: the round, how many confirmed findings landed in
  the function, and whether the fix added a clause or removed one. Two consecutive
  rows with findings stop the fix: the next step is the allow-list question, asked
  before any patch. Missed on vlang/v#31407 (adversarial round 4, 2026-11-07, 19
  confirmed): the push/pop save model added for round 1 took findings in four inline
  passes and two adversarial rounds, and each was patched with a new clause (slot
  widths, gaps, frames, stores, one-operand stores) while this rule sat unapplied two
  bullets up.
- **Sweep the real corpus.** Run a new rejection over every real use in the tree
  (`git grep` the construct, one checker run per file) before reviewing it by hand.
- **The sibling may share the bug.** Sibling parity (Phase 0 step 7) reported
  "matches" for the const case because the alias path had the same defect
  before the PR. A parity match with a sibling that has never been through
  this angle is evidence of consistency, not of correctness: run the
  vocabulary list against the sibling too.

**Artifact: acceptance-regression table.** One row per vocabulary entry, never
several entries in a row: `entry — where the old code accepts it (file:line) — valid
program exercising it — old build result — new build result — disposition (pass /
false positive / out of scope, with reason)`. A result cell not produced by running
the program this review is a GAP. State "no new or widened rejection in this diff"
explicitly when the angle does not apply; a diagnostic-adding diff with this
table marked N/A is itself a GAP.

---

## Phase 2 — Triage (inline, no sub-agents)

Dedup near-duplicates (same defect, same location → keep one).

For each remaining candidate:
- **CONFIRMED** — you can construct the triggering input/state/timing from the code
- **PLAUSIBLE** — realistic race, nil on error path, or boundary the code doesn't
  exclude; do not refute for being "speculative"
- **REFUTED** — factually impossible: quote the line that prevents it, or show the
  type/constant/invariant that makes it unreachable

Drop REFUTED. Keep **every** CONFIRMED and PLAUSIBLE candidate — do not cap
this list. A hard cap at triage silently discards real findings past the Nth,
throwing away work Phase 1's fresh-eyes pass and A–I angles just did
specifically to surface everything; a candidate dropped here for being
past a count limit fails exactly the same way as one "silently dropped for
being half-believed" (Phase 1's own dominant-cause-of-misses warning) — the
mechanism differs, the lost finding doesn't. Rank most-severe first.

If the **final report** needs to be shortened for readability (e.g. an
unusually large PR), truncate the *presentation* only — state the true total
count and how many were omitted from the list shown, never truncate
silently. Findings past the presented cutoff are still findings; note them,
don't discard them.

**PLAUSIBLE by default** for: concurrency races, nil/zero on reachable error paths,
off-by-one on boundaries the code doesn't explicitly exclude, protocol edge cases
the server is permitted (but unlikely) to exercise.

---

## Phase 3 — Optional sub-agent verification

Only if the effort level is `max` AND sub-agent session limits are not exhausted:
spawn one verification agent per CONFIRMED finding to independently confirm.
If agents hit session limits, skip Phase 3 and mark those findings "unverified —
verify manually before acting."

---

## Phase R — Reproduce a Codex (or human) miss, then close the gap

**STOP. Complete Phase R in full BEFORE applying any code fix.** The chosen
remediation must reproduce against the buggy code. If you fix the code
first, the reproduction step (step 4) cannot distinguish a working check
from a broken one. The order is: pick the remediation → reproduce on buggy
code → fix the code → confirm the check clears. Applying the fix first
collapses steps 4 and 5 into a single unverifiable check and defeats the
regression purpose entirely.

Run this whenever an external reviewer finds a bug this review missed. The point
is not just to fix the bug — it is to prove the *review* would now catch it, and
to leave a permanent regression behind. Treat every miss as a failing test for
the review.

1. **Record** the miss: the commit the reviewer reviewed, `file:line`, and the
   bug class (lenient-parse, error-scope, sibling-arm, flag-contract, …).
2. **Diagnose the flaw — present-but-not-run vs missing, with evidence, not
   a default.** This corpus's own history shows the answer is
   present-but-not-run most of the time — that is useful context, not
   license to assume it. Concluding present-but-not-run without naming the
   rule is exactly the kind of unevidenced claim Phase 2 would REFUTE if a
   code candidate made it this loosely. Produce three fields:
   - **Existing rule that should have caught it** — name it precisely: the
     angle letter + bullet name, the detector script, or the matrix row.
     If you cannot name one, the honest answer is "none" — that is the
     *missing* branch, not a softer version of present-but-not-run; do not
     round up to present-but-not-run just because it is usually the
     answer.
   - **Why it failed** — the actual mechanism, evidenced by what you did
     or didn't do THIS review: never run at all? run but eyeballed instead
     of executed to a real pass/fail? the rule/detector has a structural
     blind spot for this exact input shape (confirm this by Phase-R'ing
     the detector against the shape, don't assume it)? the rule's stated
     scope is narrower than this instance (quote the rule's wording next
     to the defect to show the gap)?
   - **New enforcement mechanism** — which Phase R step 3 remediation type
     closes THIS specific failure mode. "Run it next time" is not a
     mechanism; it is the prose reminder this whole phase exists to
     replace.
   If the answer to the first field is "none," the angle/bullet/matrix
   row/artifact is missing — go straight to adding one; this is a
   different outcome from present-but-not-run, not a fallback phrasing of
   it.
3. **Pick the remediation that actually fits the defect — a detector is the
   default, not the only option.** Forcing every miss into "write a grep
   script" produces high-false-positive detectors nobody trusts, or worse,
   no detector at all because the defect genuinely can't be expressed that
   way. Choose from:
   - **Detector** (default) — a grep or small script that exits non-zero on
     the defect (see `detect_lenient_parse.v`). Use when the defect has a
     stable syntactic signature a script can find without dataflow
     analysis.
   - **Conformance matrix row** — when the miss is an absent MUST from a
     spec Angle E already tracks (H2/QUIC). Add a GAP row citing the buggy
     commit as evidence, close it (fix + test), flip to CONFORMS.
   - **Regression test** — when the defect needs runtime or dataflow
     evidence a static grep can't see (a leak, a race, a wrong value only
     visible at runtime). The test itself is the check: it must fail
     against the buggy code and pass after the fix, same discipline as a
     detector, just executed by `v test` instead of a shell script.
   - **Required artifact/table** — when the miss reveals an existing
     REQUIRED artifact's schema is missing the column or row-type that
     would have surfaced this exact finding (the sibling parity table
     gaining a "sibling caller guards" column after a caller-guard miss is
     the precedent). The fix changes the review PROCESS artifact, not the
     code under review.
   - **Checklist rule** — when the defect needs semantic judgment no
     script can make (does this design choice match the file's own
     precedent?). A new, concrete prose bullet in the relevant angle, with
     the historical miss written in as its worked example — most of Angle
     F's existing bullets are exactly this shape.
   - **Documented detector limitation** — when an existing detector
     genuinely CANNOT be extended to this shape, confirmed rather than
     assumed (re-aliasing before a free, 2+ levels of struct nesting, a
     re-aliased local — patterns with no syntactic signature to grep for).
     State the limitation explicitly in the detector's own output/comment
     and in the corpus row, so a future reviewer knows not to trust it for
     that shape instead of re-discovering the gap by hand.
   Detector, matrix row, and regression test are mechanical — they are the
   ones that survive "I forgot to think about it," and are still the right
   default whenever the defect has a checkable signature. Reach for
   checklist rule or documented limitation only when it genuinely doesn't;
   using either to skip the work of a real mechanical check is exactly the
   prose-reminder failure this step exists to prevent, not a loophole
   around it.
4. **Reproduce against the reviewed commit (the diagnostic test) — adapt to
   the chosen remediation:**
   - *Detector / regression test:* run it against the code *as the
     reviewer saw it* — `bash "${CLAUDE_PLUGIN_ROOT}"/skills/code-review/<detector>.sh
     <file> <reviewed-commit>`, or the test against a checkout/stash of
     that commit. It MUST surface the finding (non-zero / failing test).
     If it does not, the fix is insufficient — iterate on step 3. For a
     regression test, also run it against the most plausible WRONG fix (the
     old key, the looser predicate, the other branch), not only against the
     code with the fix removed; see Angle J.
   - *Conformance matrix row:* confirm the row, filed as GAP, correctly
     cites the buggy commit/`file:line` as the evidence the requirement
     went unmet.
   - *Required artifact/table:* confirm the OLD schema, applied to the PR
     that introduced this miss, would not have surfaced the finding —
     name the specific column/row-type that was missing.
   - *Checklist rule / documented limitation:* confirm the commit this
     rule or limitation is written about is cited as the worked example,
     with enough concrete detail that a future reviewer applying it by
     hand would actually catch the same class again.
5. **Confirm the fix clears it — adapt to the chosen remediation:**
   - *Detector / regression test:* run it against the working tree; it
     must pass. (A green detector with the bug still present means the
     detector, not the code, is wrong — e.g. an upstream-only guard the
     local check can't see; fix at the parse/use site so the invariant
     holds locally.)
   - *Conformance matrix row:* flip GAP → CONFORMS, citing the fix commit.
   - *Required artifact/table:* confirm the NEW schema, applied to this
     same diff, surfaces the finding that the old schema missed.
6. **Log it** in `${CLAUDE_PLUGIN_ROOT}/reference/code-review-misses.md` with the reproduction command (or
   matrix row / artifact-schema change / rule citation) AND step 2's three
   fields verbatim (existing rule / why it failed / new enforcement
   mechanism), so the corpus of past misses becomes a standing regression
   set to replay — and so a later reader can audit whether "present-but-
   not-run" was actually evidenced for this row or just assumed.

---

## Output format

```
### Findings

**[CONFIRMED|PLAUSIBLE]** `path/to/file.v:line` — One-sentence summary
> Scenario: concrete inputs/state → wrong output or hang

(repeat for each finding, ranked most-severe first)

### Artifacts

Diff scope: <files changed>
Review mode: <Lite/Standard/High-risk/Regression — files/domains that justify it>
Full-file read: <yes/no — which files>
Angles run: A B C D E F G H I J K [+ Phase 3 if applicable]

Per-file contracts:
<file> — <one-paragraph contract>
(repeat per file read in full — Phase 0 step 4)

Repeat-offender list:
<function — file:line — prior commits — pass/fail> (or "none")

New type/function contract list:
<type/function — file:line — one-paragraph contract> (or "none")

Sibling parity table (columns: new path | sibling | sibling caller guards | matched behavior | intentional divergence | unresolved divergence):
<one row per new type/function/branch checked> (or "no new code requiring a sibling check")

Detector run log:
<command run — output/exit summary> (or "not run — <reason>")

Matrix rows checked:
<row — file:line/commit — status> (or "N/A — no H2/QUIC changes")

Concurrency matrices (Angle F):
Matrix 1 (shared field — readers — writers — lock): <rows> (or "none")
Matrix 2 (wait predicate — all mutators — wake/broadcast path): <rows> (or "none")
Matrix 3 (action sized under lock — committed under same protection?): <rows> (or "none")
Race detector run (Angle F, rev 95): <command — where it ran — exit code — races reported> (or "N/A — no concurrent code in this diff", or "not run — reason")

Negative evidence / skipped areas:
<what was excluded and why> (or "none — full scope covered")

Absence-search checklist:
<requirement/check/path — present (file:line) or GAP — fixed/logged> (or "none applicable to this diff")

Test discrimination table (Angle J):
<condition — mode/configuration reaching it — passing-side test — rejecting-side test or GAP (observables considered) — plausible-wrong mutation — result — fixture lines that failed> (or "no new conditions")

Model ledger (Angle K):
<function — rounds with confirmed findings — clauses added/removed — allow-list question asked?> (or "no model of another tool in this diff")

Acceptance-regression table (Angle K):
<vocabulary entry — where the old code accepts it (file:line) — valid program — old build result — new build result — disposition> (or "no new or widened rejection in this diff")
Base-vs-head variation table (Angle J):
<rule — shape — base result — head result — same / program justifying the change / finding> (or "N/A — reason")
```

Every artifact above is required output, not optional detail — an item left
blank instead of explicitly marked "none"/"N/A"/"not run" is indistinguishable
from a step that silently never happened, which is the exact failure mode
this block exists to close (see Phase M). The Phase 0 fields (per-file
contracts, repeat-offender list, new type/function contract list, sibling
parity table, negative evidence) should already exist verbatim from the
Phase 0 checklist — copy them forward rather than re-deriving them from
memory here.

If `--fix` was passed: apply CONFIRMED fixes after the finding list.
If `--comment` was passed: post findings as inline PR comments via:
`gh api repos/<owner>/<repo>/pulls/<N>/reviews -X POST`

---

## Phase M — record the review marker (REQUIRED, last step)

The `require_code_review` PreToolUse hook (`${CLAUDE_PLUGIN_ROOT}/hooks/require_code_review.sh`,
wired in `.claude/settings.local.json`) **blocks `git commit`/`git push` until the
current working-tree diff has been reviewed.** It checks a fingerprint the review
must write. If you skip this step, every commit stays blocked.

After the review completes (findings reported AND any `--fix` edits applied), run
**exactly** this so the fingerprint matches the hook's computation byte-for-byte:

```
git diff HEAD | sha256sum | cut -d' ' -f1 > "$(git rev-parse --absolute-git-dir)/.last_code_review"
```

Use `--absolute-git-dir`, not `"$(git rev-parse --show-toplevel)/.git"` — in a
git worktree, `.git` is a FILE (a gitdir pointer), not a directory, so that path
is unwritable and every marker write silently fails there (caught 2026-07-04).
`--absolute-git-dir` resolves correctly in both a normal checkout and a worktree.

Rules:
- Write the marker only after the diff is in its final reviewed state. If you
  applied fixes during the review, those are part of the diff being blessed — run
  the command after the last edit.
- Do **not** write the marker as a shortcut to get past the gate without actually
  reviewing. The marker means "I ran the full A–I review on this exact diff."
  Phase R (a single targeted remediation for one Codex finding) is **not** a review
  and must not be used to satisfy the gate — run the whole thing.
- The marker means the Output format's Artifacts block was actually filled in
  for this diff, not just the findings list. An Artifacts block with items
  silently left blank (instead of explicitly marked "none"/"N/A"/"not run") is
  not a completed review — fill it in before writing the marker.
- If you change the code after writing the marker, the fingerprint goes stale and
  the gate re-blocks (by design) — re-review and re-write.
