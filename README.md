# review-tools

The vlang code-review tooling, moved out of per-checkout `.claude/` directories
into one git repository so it runs identically on Windows (PowerShell / git-bash),
WSL and macOS. Git is the sync mechanism; nothing is copied by hand.

## What is here

| Path | Contents |
| --- | --- |
| `skills/vreview/` | The `/vreview` review process (SKILL.md) |
| `skills/code-review/` | `run_detectors.sh` (thin bash runner kept for WSL/macOS habit; same manifest), H2/QUIC conformance matrices, `rfc-texts/`. The shell detectors were retired once their V ports passed the same fixtures |
| `skills/phase-r/`, `skills/review-respond/`, `skills/adversarial-review/` | Companion skills (see below) |
| `detectors/` | The detectors, one V program each (`detect_*.v`, same `<file> <base_copy_or_empty>` contract), and `run_detectors.v`, the batch runner: computes targets and base revision with git, compiles the detectors once into a hash-keyed cache under the OS temp dir, dispatches by a basename manifest. No bash needed |
| `probes/` | `vprobe.v`, the executed probes `/vreview` hard rule 4 requires: `matrix` (base build against head build per place, kind of object and account), `race` (several copies of a command at once), `mutate` (one test run per one-line mutant) and `trace` (which inputs each caller of a function is tested with). The file's header describes the spec |
| `hooks/` | `hooks.json` (plugin hook wiring), `require_code_review.sh` (commit gate), `check_powershell_parse.ps1`, `check_ps1_file_parse.ps1` (reference copies, wired globally) |
| `reference/` | `code-review-reference.html` quick reference, its `code-review-misses-data.js` table data, and the `code-review-misses.md` narrative corpus |

## The skills

| Skill | Use it for |
| --- | --- |
| `/review-tools:vreview` | Reviewing your own change before every commit. Writes the marker the commit gate checks |
| `/review-tools:phase-r` | A bug someone else found: reproduce it on the unfixed code before fixing it |
| `/review-tools:review-respond <PR#> [review or comment] [owner/repo]` | One round of review on a PR, from a maintainer, another person or a bot such as Codex: fetch the findings (review bodies, inline comments and plain PR comments), check each against the code, reproduce each real bug with `/phase-r`, fix, run `/vreview`, commit, push to your fork, and reply where each finding was posted. Replaced `/codex-respond` on 2026-11-14 |
| `/review-tools:adversarial-review` | A multi-agent pass that tries to break a finished change; run it only with the user's go-ahead |

`/luna-respond` was removed on 2026-11-14: it was a placeholder for a review service that was
never connected.

## Changing the rules

See [CONTRIBUTING.md](CONTRIBUTING.md): a rev is the rule, its reference page entry and its
corpus rows in one commit, and the commit gate checks all three.

## Install and update

See [MIGRATION.md](MIGRATION.md). Short form: clone, `claude plugin marketplace add <clone>`,
`claude plugin install review-tools@review-tools-local --scope user`; update with `git pull`.
Run the detector fixture suite with `bash tests/run_fixtures.sh` (see `tests/README.md`). Run the
probe self-test with `bash tests/vprobe/selftest.sh [path/to/v]` on Linux, WSL or macOS.

## History

The first commit is a verbatim copy of the canonical files as of 2026-10-18:
`C:\Users\john3\.claude\skills\{vreview,code-review,phase-r,codex-respond,luna-respond,adversarial-review}`,
`S:\repo\vlang\.claude\hooks\`, `C:\Users\john3\.claude\hooks\check_*.ps1` and
`S:\Code Review\`. The HTML reference was at rev 66.

Later commits (in order): fixture suite (`tests/`), Claude Code plugin packaging
(`.claude-plugin/`), retirement of `sync_skills.sh`, runner-owns-git rewrite of
`run_detectors.sh`, and the port of detectors to V (`detectors/*.v`).
