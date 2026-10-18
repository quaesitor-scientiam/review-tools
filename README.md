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
| `hooks/` | `require_code_review.sh` (commit gate), `check_powershell_parse.ps1`, `check_ps1_file_parse.ps1`, `sync_skills.sh` (legacy Mac/Windows mtime sync, retired in Step 3) |
| `reference/` | `code-review-reference.html` quick reference and its `code-review-misses-data.js` miss corpus |

## History

The first commit is a verbatim copy of the canonical files as of 2026-10-18:
`C:\Users\john3\.claude\skills\{vreview,code-review,phase-r,codex-respond,luna-respond,adversarial-review}`,
`S:\repo\vlang\.claude\hooks\`, `C:\Users\john3\.claude\hooks\check_*.ps1` and
`S:\Code Review\`. The HTML reference was at rev 66.

Later commits (in order): fixture suite (`tests/`), Claude Code plugin packaging
(`.claude-plugin/`), retirement of `sync_skills.sh`, runner-owns-git rewrite of
`run_detectors.sh`, and the port of detectors to V (`detectors/*.v`).
