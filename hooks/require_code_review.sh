#!/usr/bin/env bash
# PreToolUse gate: block `git commit` / `git push` unless /vreview has run on
# the CURRENT working-tree diff. The review writes a fingerprint of the diff it
# reviewed to <git-dir>/.last_code_review; this hook recomputes the fingerprint
# and denies the commit/push when it is missing or stale (diff changed since
# the review).
#
# Shipped as part of the review-tools plugin and wired by hooks/hooks.json on
# the Bash AND PowerShell tools (commits here often go through pwsh, e.g.
# `$m | git commit -F -`, which is exactly why a Bash-only reminder never
# fired). Reads the tool payload on stdin; greps the raw JSON for a git commit/
# push invocation (no jq dependency — git-bash has no jq).
#
# Every path this hook checks is resolved from its own location inside the
# plugin, never from the target repo's .claude/ directory, so it behaves the
# same from the main checkout, from any git worktree, and on every machine the
# plugin is installed on.
set -uo pipefail

payload="$(cat)"

# Only gate git commit / git push. Match the literal subcommand anywhere in the
# command string (covers `git commit`, `git push`, `$m | git commit -F -`,
# `git -C path commit`, etc.). Over-matching is safe — it only adds a review gate.
if ! printf '%s' "$payload" | grep -Eq 'git( +-[A-Za-z]+( +[^ ]+)?)* +(commit|push)([^A-Za-z]|$)'; then
  exit 0
fi

# plugin_root: the directory that holds skills/, hooks/ and reference/. $0 may
# arrive as a Windows path (C:\...\hooks\require_code_review.sh) when the hook
# command is expanded from ${CLAUDE_PLUGIN_ROOT} on Windows; normalise it so
# dirname works.
self="$0"
case "$self" in
  *\\*) self="$(cygpath -u "$self" 2>/dev/null || printf '%s' "$self" | tr '\\' '/')" ;;
esac
plugin_root="$(cd "$(dirname "$self")/.." 2>/dev/null && pwd)"
[ -n "$plugin_root" ] || exit 0

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

deny() {
  # $1: reason. Escape double quotes so the JSON stays valid.
  local reason; reason="$(printf '%s' "$1" | sed 's/"/\\"/g')"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

# Doc-sync gate: if the review skill, any detector, a conformance matrix, or the
# miss corpus is newer than code-review-reference.html, the HTML was not synced
# (standing rule feedback_update_code_review_html — forgotten twice). Block the
# commit until it is.
#
# Inside a git checkout of the plugin, "newer" is decided by git, not by file
# mtimes: a fresh clone or `git pull` writes every file with the same clock and
# in arbitrary order, so mtimes would produce random blocks. The check is:
#   - any uncommitted change under skills/ or the corpus, with none under
#     reference/  -> stale;
#   - else the latest commit touching skills/ is newer than the latest commit
#     touching reference/ -> stale.
# Outside a git checkout (plain copy of the plugin) it falls back to mtimes.
html="$plugin_root/reference/code-review-reference.html"
misses="${CODE_REVIEW_MISSES_MD:-$HOME/.claude/projects/S--repo-vlang/memory/code-review-misses.md}"
if [ -f "$html" ]; then
  stale=""
  if git -C "$plugin_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    dirty_src="$(git -C "$plugin_root" status --porcelain -- skills 2>/dev/null | head -1)"
    dirty_ref="$(git -C "$plugin_root" status --porcelain -- reference 2>/dev/null | head -1)"
    if [ -n "$dirty_src" ] && [ -z "$dirty_ref" ]; then
      stale="uncommitted change: ${dirty_src#???}"
    else
      t_src="$(git -C "$plugin_root" log -1 --format=%ct -- skills 2>/dev/null)"
      t_ref="$(git -C "$plugin_root" log -1 --format=%ct -- reference 2>/dev/null)"
      if [ -n "$t_src" ] && [ -n "$t_ref" ] && [ "$t_src" -gt "$t_ref" ]; then
        stale="commit $(git -C "$plugin_root" log -1 --format=%h -- skills) touched skills/ after the last reference/ change"
      fi
    fi
  else
    for src in "$plugin_root/skills/vreview/SKILL.md" \
               "$plugin_root"/skills/code-review/*.sh \
               "$plugin_root"/skills/code-review/*.ps1 \
               "$plugin_root/skills/code-review/h2_conformance_matrix.md" \
               "$plugin_root/skills/code-review/quic_conformance_matrix.md"; do
      [ -f "$src" ] && [ "$src" -nt "$html" ] && { stale="$src is newer than the HTML"; break; }
    done
  fi
  # The miss corpus lives in project memory, outside the plugin: mtime only.
  [ -z "$stale" ] && [ -f "$misses" ] && [ "$misses" -nt "$html" ] && stale="$misses is newer than the HTML"
  if [ -n "$stale" ]; then
    deny "Blocked by require_code_review: review docs changed ($stale) but the HTML reference was not synced. Update $html (angle cards, detectors tab, miss corpus, counts, subtitle date) per feedback_update_code_review_html, commit it in the review-tools repo, then retry."
  fi
fi

# Nothing uncommitted (e.g. pushing already-committed, already-reviewed work):
# there is no unreviewed change to gate, so allow.
if [ "$(git -C "$repo_root" diff HEAD 2>/dev/null | wc -c)" -eq 0 ]; then
  exit 0
fi

# vfmt-clean gate: block commit/push if any .v/.vsh/.vv file in the current
# diff (added or modified) is not vfmt'ed. Feedback 2026-08-26 (PR
# vlang/v#28164, 13e): a fix edited AFTER its file's last `fmt -w` pass
# shipped through /vreview and this hook's review-marker gate straight to CI,
# which then failed on every platform job running `v fmt -verify` — purely
# cosmetic (one ternary vfmt line-wraps), but wasted a full CI cycle and
# looked like a universal compile break at a glance. "Remember to reformat"
# is not enforceable — this makes it mechanical instead.
# The checkout's own compiler is used: `vnew` (older workflow) first, then `v`
# (the `./v self` workflow current since 2026-10).
v_bin=""
for candidate in "$repo_root/vnew" "$repo_root/vnew.exe" "$repo_root/v" "$repo_root/v.exe"; do
  [ -x "$candidate" ] && { v_bin="$candidate"; break; }
done
if [ -n "$v_bin" ]; then
  vfmt_files="$(git -C "$repo_root" diff HEAD --name-only --diff-filter=ACMR -- '*.v' '*.vsh' '*.vv' 2>/dev/null || true)"
  if [ -n "$vfmt_files" ]; then
    unformatted=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$repo_root/$f" ] || continue
      if ! "$v_bin" fmt -verify "$repo_root/$f" >/dev/null 2>&1; then
        unformatted="$unformatted $f"
      fi
    done <<<"$vfmt_files"
    if [ -n "$unformatted" ]; then
      deny "Blocked by require_code_review: not vfmt'ed:$unformatted — run '$(basename "$v_bin") fmt -w <file>' on each as the LAST step before commit (even if you already formatted it earlier this session — a later edit can un-format it), then retry."
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
deny 'Blocked by require_code_review: the current uncommitted diff has not passed the project review (no review marker, or the diff changed since the last review). Run /vreview on this diff first — it records <git-dir>/.last_code_review — then retry. Phase R alone does NOT satisfy this; run the full review.'
