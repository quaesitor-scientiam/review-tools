# Migration: from per-checkout `.claude/` copies to the review-tools plugin

Until 2026-10-18 the review tooling lived in gitignored `.claude/skills/` and
`.claude/hooks/` directories: one copy per checkout, a global copy under
`~/.claude/skills/`, Windows junctions between them, and `sync_skills.sh` (an
mtime-wins Mac to Windows reconciler over SMB) carrying changes between machines.
That design lost the whole skill set once (2026-09-07) and drifted repeatedly.

Now there is one git repository, installed as a Claude Code plugin. **Git is the
sync.** Nothing is copied by hand, no junction is needed, and a worktree sees the
same plugin as the main checkout because the plugin is user-scoped, not per-checkout.

## Install (any machine)

```bash
git clone <remote-or-path> ~/repo/review-tools        # Mac / WSL / Linux
claude plugin marketplace add ~/repo/review-tools
claude plugin install review-tools@review-tools-local --scope user
```

On Windows the clone is `S:\repo\review-tools` and the marketplace add uses that path.
A plugin installed from a local-path marketplace is **loaded in place** from the
clone: edits apply at the next session start or `/reload-plugins`, no version bump
or reinstall needed.

Skills are invoked by their plugin-qualified names:

| Old | New |
| --- | --- |
| `/vreview` | `/review-tools:vreview` |
| `/phase-r` | `/review-tools:phase-r` |
| `/codex-respond` | `/review-tools:codex-respond` |
| `/luna-respond` | `/review-tools:luna-respond` |
| `/adversarial-review` | `/review-tools:adversarial-review` |

## Updating

```bash
git -C ~/repo/review-tools pull          # or push from the machine that changed it
```

`claude plugin update review-tools@review-tools-local` re-reads the manifest; for an
in-place local plugin a `git pull` plus `/reload-plugins` is the whole update.

## What replaced what

| Before | After |
| --- | --- |
| `~/.claude/skills/{vreview,code-review,...}` and repo-local copies | `skills/` in this repo |
| `S:\repo\vlang\.claude\skills\code-review` junction | not needed; delete at cutover |
| `.claude/hooks/require_code_review.sh` wired in settings | `hooks/hooks.json` in the plugin wires `hooks/require_code_review.sh` |
| `.claude/hooks/sync_skills.sh` | deleted; `git pull` |
| `S:\Code Review\code-review-reference.html` + `code-review-misses-data.js` | `reference/` in this repo |
| `bash .claude/skills/code-review/run_detectors.sh` | `bash "${CLAUDE_PLUGIN_ROOT}"/skills/code-review/run_detectors.sh` |
| `detect_x.sh <file> <gitrev>` | `run_detectors.sh --at <rev> <file>` (detectors never call git) |
| bash-only detectors | `detectors/*.v` ports, run natively with the target repo's `./v`; `DETECT_IMPL=sh` forces the scripts |

The commit gate still writes its marker to `$(git rev-parse --absolute-git-dir)/
.last_code_review` of the repo being committed, so it works from any worktree. Its
doc-sync check (skills changed but the HTML reference not updated) now reads this
repo's git history instead of file mtimes, since a clone or pull would randomise
mtimes.

## Not migrated (still global, by choice)

`check_powershell_parse.ps1`, `check_ps1_file_parse.ps1` and
`enforce_answer_format.ps1` stay wired in `~/.claude/settings.json`: they enforce
global preferences, not review policy. Copies of the two `check_*` hooks are kept
under `hooks/` for reference; they are not declared in `hooks/hooks.json`, so they do
not fire twice.

The miss corpus narrative (`code-review-misses.md`) stays in project memory; the
commit gate reads it via `$CODE_REVIEW_MISSES_MD` or the default memory path.

## Cutover checklist (vlang checkout, needs an explicit go-ahead)

1. Remove the junction `S:\repo\vlang\.claude\skills\code-review` and the repo-local
   `vreview/` copy; remove `S:\repo\vlang\.claude\hooks\`.
2. Remove the global `~/.claude/skills/{vreview,code-review,phase-r,codex-respond,
   luna-respond,adversarial-review}` so the bare names stop shadowing the plugin.
3. Point the project memory notes at the plugin; `S:\Code Review\` becomes a
   read-only mirror or is deleted.
