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
  local reason; reason="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR > 1 {printf "\\n"} {printf "%s", $0}')"
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
#   - any uncommitted change under skills/ or detectors/ (tracked, or a new
#     untracked file in skills/ or a new top-level detectors/*.v), with no
#     uncommitted change to the HTML reference itself  -> stale;
#   - else any commit touching skills/ or detectors/ that comes AFTER the last
#     commit touching the HTML reference, by ancestry (rev-list), not by
#     timestamp: a rebase, amend or cherry-pick gives commits the same second,
#     and a merge can bring in an older-dated skill commit  -> stale.
# Only the HTML counts as the sync, not the rest of reference/: the corpus
# (code-review-misses.md, code-review-misses-data.js) lives there too, and a
# skill change committed with only a corpus edit used to pass. The gate checks
# that the HTML changed, not that it changed enough: revs 75, 76 and 79 each
# touched the HTML but left some of their rules off it, which only a review of
# the page catches. Other untracked files are ignored, since detectors/
# collects compiled binaries from local runs.
# Known approximation: an uncommitted HTML edit counts even if the commit will
# not include it (the hook cannot tell what `git add ... && git commit` will
# stage), so such a commit passes; the next commit or push then fails the
# history check, because the skill commit sits after the last HTML commit.
# Outside a git checkout (plain copy of the plugin) it falls back to mtimes.
#
# Scope: only commits/pushes made INSIDE the plugin repo are gated on this. The
# skills now have their own commits, so that is where "skill changed, HTML not"
# is caught; gating every other repo on the plugin's working-tree state blocked
# an unrelated vlang push the first day (2026-10-18) while the plugin was being
# edited. A plain copy of the plugin (no git) keeps the old everywhere-mtime rule,
# since it has no commit of its own to gate.
html="$plugin_root/reference/code-review-reference.html"
misses="${CODE_REVIEW_MISSES_MD:-$plugin_root/reference/code-review-misses.md}"
plugin_is_git=0
git -C "$plugin_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && plugin_is_git=1
# Same repository when both resolve to one git common dir, so a git worktree of
# the plugin repo is gated too (its toplevel differs from plugin_root). The
# queries then run in repo_root, the checkout actually being committed.
same_repo=0
if [ "$plugin_is_git" -eq 1 ]; then
  plugin_common="$(git -C "$plugin_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  repo_common="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [ -n "$plugin_common" ] && [ "$plugin_common" = "$repo_common" ] && same_repo=1
fi
[ "$(cd "$plugin_root" && pwd -P)" = "$(cd "$repo_root" && pwd -P)" ] && same_repo=1
# The hook runs in the session's directory, not where the command cds to, so a
# session working in a vlang checkout that runs `cd ~/repo/review-tools && git
# commit` (or `git -C <dir> commit`, `pushd <dir>`) commits to the plugin while
# repo_root still names the vlang checkout, and the doc checks below were
# skipped. Revs 93, 94, 97 and 98 went in that way with no page entry. Find
# such a directory in the command and gate the commit there.
doc_root="$repo_root"
if [ "$plugin_is_git" -eq 1 ] && [ "$same_repo" -eq 0 ]; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in "~"*) d="$HOME${d#\~}" ;; '$HOME'*) d="$HOME${d#\$HOME}" ;; esac
    case "$d" in *\\*) d="$(cygpath -u "$d" 2>/dev/null || printf '%s' "$d" | tr '\\' '/')" ;; esac
    [ -d "$d" ] || continue
    d_common="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    if [ -n "$d_common" ] && [ "$d_common" = "$plugin_common" ]; then
      doc_root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)"
      same_repo=1
      break
    fi
  done <<<"$(printf '%s' "$payload" |
    grep -oE '(cd|pushd|Set-Location|-C) +(\\"[^"\\]+\\"|'"'"'[^'"'"']+'"'"'|[^ ;&|"'"'"'()]+)' |
    sed -E 's/^(cd|pushd|Set-Location|-C) +//; s/^\\"//; s/\\"$//; s/^'"'"'//; s/'"'"'$//; s/\\\\/\\/g')"
fi
if [ -f "$html" ] && { [ "$plugin_is_git" -eq 0 ] || [ "$same_repo" -eq 1 ]; }; then
  stale=""
  if [ "$plugin_is_git" -eq 1 ]; then
    html_rel="reference/code-review-reference.html"
    dirty_src="$( { git -C "$doc_root" status --porcelain --untracked-files=no -- skills detectors
                    git -C "$doc_root" status --porcelain --untracked-files=all -- skills ':(glob)detectors/*.v'
                  } 2>/dev/null | head -1)"
    dirty_ref="$(git -C "$doc_root" status --porcelain --untracked-files=no -- "$html_rel" 2>/dev/null | head -1)"
    if [ -n "$dirty_src" ] && [ -z "$dirty_ref" ]; then
      stale="uncommitted change: ${dirty_src#???}"
    else
      last_html="$(git -C "$doc_root" log -1 --format=%H -- "$html_rel" 2>/dev/null)"
      if [ -n "$last_html" ]; then
        late="$(git -C "$doc_root" rev-list -1 --full-history "$last_html..HEAD" -- skills detectors 2>/dev/null)"
        if [ -n "$late" ]; then
          stale="commit $(git -C "$doc_root" log -1 --format=%h "$late") touched skills/ or detectors/ after the last change to $html_rel"
        fi
      fi
    fi
  else
    for src in "$plugin_root/skills/vreview/SKILL.md" \
               "$plugin_root"/skills/code-review/*.sh \
               "$plugin_root"/detectors/*.v \
               "$plugin_root/skills/code-review/h2_conformance_matrix.md" \
               "$plugin_root/skills/code-review/quic_conformance_matrix.md"; do
      [ -f "$src" ] && [ "$src" -nt "$html" ] && { stale="$src is newer than the HTML"; break; }
    done
    # In a git plugin the corpus is under reference/, and checkout mtimes mean nothing.
    [ -z "$stale" ] && [ -f "$misses" ] && [ "$misses" -nt "$html" ] && stale="$misses is newer than the HTML"
  fi
  # What the page and corpus must hold, checked by content: the page's rev,
  # changelog and cards for the newest rev, four-cell corpus rows, and the same
  # rows in both corpus copies. Touching the HTML is not enough on its own.
  # Reported with the staleness reason, so one denial lists everything to fix.
  ref_problems=""
  if [ "$plugin_is_git" -eq 1 ] && [ -f "$plugin_root/hooks/check_reference.sh" ]; then
    commit_rev="$(printf '%s' "$payload" | grep -oE 'vreview: rev [0-9]+' | head -1 | awk '{print $NF}')"
    ref_problems="$(bash "$plugin_root/hooks/check_reference.sh" "$doc_root" "$commit_rev" 2>&1)" && ref_problems=""
  fi
  if [ -n "$stale" ] || [ -n "$ref_problems" ]; then
    msg="Blocked by require_code_review: the reference page or corpus is not in step with this change. Follow CONTRIBUTING.md in the review-tools repo (page subtitle rev, changelog entry, angle cards and angleData panels, corpus rows in both copies), commit the page with the skill change, then retry. Check by hand with: bash hooks/check_reference.sh . <rev>"
    [ -n "$stale" ] && msg="$msg
- review docs changed ($stale) but the page was not updated"
    [ -n "$ref_problems" ] && msg="$msg
$ref_problems"
    deny "$msg"
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
