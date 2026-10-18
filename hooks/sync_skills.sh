#!/bin/bash
# Two-way sync of .claude/{skills,hooks,scripts} between this Mac checkout
# (~/repo/vlang/.claude) and the Windows checkout, reached over the SSData
# share mount (/Volumes/SSData/repo/vlang/.claude == S:\repo\vlang\.claude
# on the Windows box). Run this from the Mac; nothing needs to run on
# Windows for this leg since the mount makes both sides directly writable
# from here.
#
# Rule: newer mtime wins, per file. A file missing on one side that has a
# manifest record from a prior sync is treated as a deletion and removed
# from the other side too (so removing a skill doesn't make it reappear on
# the next run). A file missing on one side with no manifest record is
# treated as new and copied across.
#
# Does NOT touch settings.local.json (machine-specific) or worktrees/
# (huge, local git worktree checkouts) -- only skills/hooks/scripts.
#
# Usage: .claude/hooks/sync_skills.sh [-n|--dry-run]

set -euo pipefail

LOCAL_ROOT="$HOME/repo/vlang/.claude"
REMOTE_ROOT="/Volumes/SSData/repo/vlang/.claude"
STATE_DIR="$REMOTE_ROOT/.sync-state"
DIRS=(skills hooks scripts)
MTIME_TOLERANCE=2   # seconds; SMB mtime resolution can be coarse
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [ ! -d "$REMOTE_ROOT" ]; then
  echo "error: remote root not found at $REMOTE_ROOT -- is the SSData share mounted?" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"

act() {
  # act <description> <cmd...>
  local desc="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  (dry-run) $desc"
  else
    echo "  $desc"
    "$@"
  fi
}

sync_dir() {
  local name="$1"
  local local_dir="$LOCAL_ROOT/$name"
  local remote_dir="$REMOTE_ROOT/$name"
  local manifest="$STATE_DIR/${name}.manifest"

  mkdir -p "$local_dir" "$remote_dir"
  touch "$manifest"

  local tmp
  tmp=$(mktemp -d)
  ( cd "$local_dir" && find . -type f ) | sed 's#^\./##' | sort > "$tmp/local_paths"
  ( cd "$remote_dir" && find . -type f ) | sed 's#^\./##' | sort > "$tmp/remote_paths"
  cut -f1 "$manifest" | sort > "$tmp/manifest_paths"
  cat "$tmp/local_paths" "$tmp/remote_paths" "$tmp/manifest_paths" | sort -u | sed '/^$/d' > "$tmp/all_paths"

  local new_manifest="$tmp/new_manifest"
  : > "$new_manifest"
  local changed=0

  while IFS= read -r rel; do
    local lpath="$local_dir/$rel"
    local rpath="$remote_dir/$rel"
    local lmtime="" rmtime="" lastmtime=""
    [ -f "$lpath" ] && lmtime=$(stat -f %m "$lpath")
    [ -f "$rpath" ] && rmtime=$(stat -f %m "$rpath")
    lastmtime=$(awk -F'\t' -v p="$rel" '$1==p{print $2}' "$manifest")

    if [ -n "$lmtime" ] && [ -z "$rmtime" ]; then
      if [ -n "$lastmtime" ]; then
        act "[mac]  delete (removed on Windows side): $name/$rel" rm -f "$lpath"
      else
        act "[mac -> win] new: $name/$rel" bash -c 'mkdir -p "$(dirname "$1")" && cp -p "$2" "$1"' _ "$rpath" "$lpath"
        [ "$DRY_RUN" -eq 0 ] && echo -e "$rel\t$lmtime" >> "$new_manifest"
      fi
      changed=1
    elif [ -z "$lmtime" ] && [ -n "$rmtime" ]; then
      if [ -n "$lastmtime" ]; then
        act "[win]  delete (removed on Mac side): $name/$rel" rm -f "$rpath"
      else
        act "[win -> mac] new: $name/$rel" bash -c 'mkdir -p "$(dirname "$1")" && cp -p "$2" "$1"' _ "$lpath" "$rpath"
        [ "$DRY_RUN" -eq 0 ] && echo -e "$rel\t$rmtime" >> "$new_manifest"
      fi
      changed=1
    elif [ -n "$lmtime" ] && [ -n "$rmtime" ]; then
      local diff=$(( lmtime > rmtime ? lmtime - rmtime : rmtime - lmtime ))
      if [ "$diff" -le "$MTIME_TOLERANCE" ]; then
        [ "$DRY_RUN" -eq 0 ] && echo -e "$rel\t$lmtime" >> "$new_manifest"
      elif [ "$lmtime" -gt "$rmtime" ]; then
        act "[mac -> win] newer: $name/$rel" cp -p "$lpath" "$rpath"
        [ "$DRY_RUN" -eq 0 ] && echo -e "$rel\t$lmtime" >> "$new_manifest"
        changed=1
      else
        act "[win -> mac] newer: $name/$rel" cp -p "$rpath" "$lpath"
        [ "$DRY_RUN" -eq 0 ] && echo -e "$rel\t$rmtime" >> "$new_manifest"
        changed=1
      fi
    fi
    # both missing: stale manifest entry, dropped by not re-adding it
  done < "$tmp/all_paths"

  if [ "$DRY_RUN" -eq 0 ]; then
    mv "$new_manifest" "$manifest"
  fi
  rm -rf "$tmp"
  if [ "$changed" -eq 0 ]; then
    echo "  (up to date)"
  fi
}

for d in "${DIRS[@]}"; do
  echo "== $d =="
  sync_dir "$d"
done
echo "done."
