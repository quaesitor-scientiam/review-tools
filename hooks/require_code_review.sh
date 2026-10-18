#!/usr/bin/env bash
# PreToolUse gate: block `git commit` / `git push` unless /code-review has run on
# the CURRENT working-tree diff. The review writes a fingerprint of the diff it
# reviewed to .git/.last_code_review; this hook recomputes the fingerprint and
# denies the commit/push when it is missing or stale (diff changed since review).
#
# Wired on the Bash AND PowerShell tools (commits here often go through pwsh, e.g.
# `$m | git commit -F -`, which is exactly why the old Bash-only reminder never
# fired). Reads the tool payload on stdin; greps the raw JSON for a git commit/
# push invocation (no jq dependency — git-bash has no jq).
set -uo pipefail

payload="$(cat)"

# Only gate git commit / git push. Match the literal subcommand anywhere in the
# command string (covers `git commit`, `git push`, `$m | git commit -F -`,
# `git -C path commit`, etc.). Over-matching is safe — it only adds a review gate.
if ! printf '%s' "$payload" | grep -Eq 'git( +-[A-Za-z]+( +[^ ]+)?)* +(commit|push)([^A-Za-z]|$)'; then
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$repo_root" ] || exit 0
# --absolute-git-dir (not "$repo_root/.git") so this resolves correctly in a
# git worktree, where .git is a FILE (a gitdir pointer) rather than a
# directory — "$repo_root/.git/.last_code_review" is unwritable there, which
# silently made every worktree session's marker write fail and every commit
# get falsely blocked (caught 2026-07-04 in a worktree session on #27643).
git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
[ -n "$git_dir" ] || exit 0
marker="$git_dir/.last_code_review"

# main_checkout_root: the MAIN checkout's own working directory, always --
# distinct from $repo_root, which is the CURRENT worktree's path when this
# hook fires from inside one. .claude/ is gitignored, so it only exists in
# the main checkout; `git worktree add` never populates it into a worktree.
# --git-common-dir resolves to the shared .git shared by every worktree
# (unlike --show-toplevel, which is per-worktree), so its parent directory
# is reliably the main checkout regardless of which worktree invoked this
# hook. Both the doc-sync staleness check below and sync_skills.sh need
# this, not $repo_root -- using $repo_root there was a latent bug (caught
# 2026-08-27): every worktree session silently no-op'd the staleness check,
# since `$repo_root/.claude/skills/...` never existed to compare.
common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
[ -n "$common_dir" ] || exit 0
main_checkout_root="$(cd "$(dirname "$common_dir")" && pwd)" || exit 0

# De-doubled 2026-09-10: each skill now lives in exactly one place. The
# pure-SKILL.md skills (vreview, codex-respond, luna-respond, phase-r,
# adversarial-review) are global-only ($HOME/.claude/skills/) -- Claude Code
# discovers them there regardless of cwd. code-review/ stays repo-local only
# ($main_checkout_root/.claude/skills/code-review/) because vreview's SKILL.md
# and settings.local.json permissions invoke its detectors by repo-relative
# path. sync_skills.sh (the old mtime reconciler for the dual copies) was
# removed -- with one copy each there is nothing to reconcile. See
# vreview-global-repo-sync-2026-08-27 memory.

# Doc-sync gate: if the review skill, any detector, the conformance matrix, or
# the miss corpus is newer than code-review-reference.html, the HTML was not
# synced (standing rule feedback_update_code_review_html — forgotten twice).
# Block the commit until it is.
html="/s/Code Review/code-review-reference.html"
misses="/c/Users/john3/.claude/projects/S--repo-vlang/memory/code-review-misses.md"
if [ -f "$html" ]; then
  stale=""
  for src in "$HOME/.claude/skills/vreview/SKILL.md" \
             "$main_checkout_root"/.claude/skills/code-review/*.sh \
             "$main_checkout_root"/.claude/skills/code-review/*.ps1 \
             "$main_checkout_root/.claude/skills/code-review/h2_conformance_matrix.md" \
             "$misses"; do
    [ -f "$src" ] && [ "$src" -nt "$html" ] && { stale="$src"; break; }
  done
  if [ -n "$stale" ]; then
    reason="Blocked by require_code_review: review docs changed ($stale is newer than code-review-reference.html) but the HTML reference was not synced. Update "S:/Code Review/code-review-reference.html" (angle cards, detectors tab, miss corpus, counts, subtitle date) per feedback_update_code_review_html, then retry."
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
    exit 0
  fi
fi

# Nothing uncommitted (e.g. pushing already-committed, already-reviewed work):
# there is no unreviewed change to gate, so allow.
if [ "$(git -C "$repo_root" diff HEAD 2>/dev/null | wc -c)" -eq 0 ]; then
  exit 0
fi

# vfmt-clean gate: block commit/push if any .v/.vsh/.vv file in the current
# diff (added or modified) is not vfmt'ed. Feedback 2026-08-26 (PR
# vlang/v#28164, 13e): a fix edited AFTER its file's last `./vnew fmt -w` pass
# shipped through /vreview and this hook's review-marker gate straight to CI,
# which then failed on every platform job running `v fmt -verify` — purely
# cosmetic (one ternary vfmt line-wraps), but wasted a full CI cycle and
# looked like a universal compile break at a glance. "Remember to reformat"
# is not enforceable — this makes it mechanical instead
# (see fmt-w-is-last-step-not-per-edit memory).
vnew_bin=""
for candidate in "$repo_root/vnew" "$repo_root/vnew.exe"; do
  [ -x "$candidate" ] && { vnew_bin="$candidate"; break; }
done
if [ -n "$vnew_bin" ]; then
  vfmt_files="$(git -C "$repo_root" diff HEAD --name-only --diff-filter=ACMR -- '*.v' '*.vsh' '*.vv' 2>/dev/null || true)"
  if [ -n "$vfmt_files" ]; then
    unformatted=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$repo_root/$f" ] || continue
      if ! "$vnew_bin" fmt -verify "$repo_root/$f" >/dev/null 2>&1; then
        unformatted="$unformatted $f"
      fi
    done <<<"$vfmt_files"
    if [ -n "$unformatted" ]; then
      reason="Blocked by require_code_review: not vfmt'ed:$unformatted — run './vnew fmt -w <file>' on each as the LAST step before commit (even if you already formatted it earlier this session — a later edit can un-format it), then retry."
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
      exit 0
    fi
  fi
fi

# Fingerprint by piping `git diff HEAD` straight into sha256sum — IDENTICAL to the
# marker-writing command the review runs (`git diff HEAD | sha256sum`). Do NOT route
# the diff through a $(...) variable: command substitution strips trailing newlines,
# so the hashes would diverge and every commit would be falsely blocked.
current_fp="$(git -C "$repo_root" diff HEAD 2>/dev/null | sha256sum | cut -d' ' -f1)"
saved_fp="$(cat "$marker" 2>/dev/null || true)"

if [ "$current_fp" = "$saved_fp" ]; then
  exit 0
fi

# Deny: the pending diff was not reviewed (or changed since the review).
reason='Blocked by require_code_review: the current uncommitted diff has not passed the project review (no review marker, or the diff changed since the last review). Run /vreview on this diff first — it records .git/.last_code_review — then retry. Phase R alone does NOT satisfy this; run the full review.'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
exit 0
