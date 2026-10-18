# review-tools

The vlang code-review tooling, moved out of per-checkout `.claude/` directories
into one git repository so it runs identically on Windows (PowerShell / git-bash),
WSL and macOS. Git is the sync mechanism; nothing is copied by hand.

## What is here

| Path | Contents |
| --- | --- |
| `skills/vreview/` | The `/vreview` review process (SKILL.md) |
| `skills/code-review/` | ~50 `detect_*.sh` mechanical detectors, `detect_sibling_arms.ps1`, `run_detectors.sh` (batch runner + manifest), H2/QUIC conformance matrices, `rfc-texts/` |
| `skills/phase-r/`, `skills/codex-respond/`, `skills/luna-respond/`, `skills/adversarial-review/` | Companion skills |
| `detectors/` | V ports of the detectors (`detect_*.v`), one program each, same `<file> <base_copy_or_empty>` contract; the runner prefers a port over its `.sh` twin when a V compiler is available |
| `hooks/` | `hooks.json` (plugin hook wiring), `require_code_review.sh` (commit gate), `check_powershell_parse.ps1`, `check_ps1_file_parse.ps1` (reference copies, wired globally) |
| `reference/` | `code-review-reference.html` quick reference and its `code-review-misses-data.js` miss corpus |

## Install and update

See [MIGRATION.md](MIGRATION.md). Short form: clone, `claude plugin marketplace add <clone>`,
`claude plugin install review-tools@review-tools-local --scope user`; update with `git pull`.
Run the detector fixture suite with `bash tests/run_fixtures.sh` (see `tests/README.md`).

## History

The first commit is a verbatim copy of the canonical files as of 2026-10-18:
`C:\Users\john3\.claude\skills\{vreview,code-review,phase-r,codex-respond,luna-respond,adversarial-review}`,
`S:\repo\vlang\.claude\hooks\`, `C:\Users\john3\.claude\hooks\check_*.ps1` and
`S:\Code Review\`. The HTML reference was at rev 66.

Later commits (in order): fixture suite (`tests/`), Claude Code plugin packaging
(`.claude-plugin/`), retirement of `sync_skills.sh`, runner-owns-git rewrite of
`run_detectors.sh`, and the port of detectors to V (`detectors/*.v`).
