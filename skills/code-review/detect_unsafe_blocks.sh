#!/usr/bin/env bash
# Exits 1 if any changed .v/.vv file in the working tree contains an unsafe{} block; lists each file and line.
# Changed means tracked files that differ from BASE (committed or uncommitted) plus untracked files.
# Exits 2 if git cannot compare against BASE, so a bad base never reads as clean.
#
# Usage: detect_unsafe_blocks.sh [BASE-revision | file.v ...]
#   No args           — scan every .v/.vv changed vs merge-base(master, HEAD).
#   BASE revision     — scan every .v/.vv changed vs that revision.
#   one or more FILES — scan exactly those files (how run_detectors.sh's
#                       manifest calls it: one target file per run). An
#                       existing path is never treated as a revision.
set -euo pipefail
if [ "$#" -ge 1 ] && [ -f "$1" ]; then
    files=$(printf '%s\n' "$@" | sort -u)
else
    BASE=${1:-$(git merge-base master HEAD)}
    changed=$(git diff --name-only "$BASE" -- '*.v' '*.vv') || { echo "detect_unsafe_blocks: git diff against $BASE failed" >&2; exit 2; }
    untracked=$(git ls-files --others --exclude-standard -- '*.v' '*.vv') || { echo "detect_unsafe_blocks: git ls-files failed" >&2; exit 2; }
    files=$(printf '%s\n%s\n' "$changed" "$untracked" | sed '/^$/d' | sort -u)
fi
[ -z "$files" ] && exit 0
found=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    hits=$(grep -nE 'unsafe[[:space:]]*\{' "$f" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        echo "UNSAFE_BLOCKS: $f"
        echo "$hits" | sed 's/^/  /'
        found=1
    fi
done <<< "$files"
exit $found
