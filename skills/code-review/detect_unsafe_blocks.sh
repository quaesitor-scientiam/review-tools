#!/usr/bin/env bash
# Exits 1 if any given .v/.vv file contains an unsafe{} block; lists each file
# and line. Exits 0 when none of the files has one.
#
# Usage: detect_unsafe_blocks.sh <file> [base_copy_or_empty] [more files...]
#   The file list and the "changed vs BASE" selection are the runner's job now
#   (run_detectors.sh passes one changed file per call, plus the base-revision
#   copy as $2, which this detector ignores). Any further arguments that are
#   existing files are scanned too, so the old multi-file form still works.
set -euo pipefail
[ "$#" -ge 1 ] || { echo "usage: detect_unsafe_blocks.sh <file> [base_copy_or_empty] [file...]" >&2; exit 2; }
files=("$1")
[ "$#" -ge 3 ] && files+=("${@:3}")
found=0
for f in "${files[@]}"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    hits=$(grep -nE 'unsafe[[:space:]]*\{' "$f" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        echo "UNSAFE_BLOCKS: $f"
        echo "$hits" | sed 's/^/  /'
        found=1
    fi
done
exit $found
