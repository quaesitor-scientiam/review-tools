#!/usr/bin/env bash
# Exits 1 if any given .v/.vv file has log/print calls interpolating
# sensitive-named variables (token, key, secret, password, nonce, credential).
#
# Usage: detect_info_leak.sh <file> [base_copy_or_empty] [more files...]
#   File selection ("changed vs BASE") is run_detectors.sh's job: it passes one
#   changed file per call plus the base-revision copy as $2 (ignored here).
#   Until 2026-10-18 this script took a BASE revision as $1, so via the runner
#   (which passed a file) it always exited 0 without scanning anything.
set -euo pipefail
[ "$#" -ge 1 ] || { echo "usage: detect_info_leak.sh <file> [base_copy_or_empty] [file...]" >&2; exit 2; }
files=("$1")
[ "$#" -ge 3 ] && files+=("${@:3}")
found=0
for f in "${files[@]}"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    hits=$(grep -nE '(eprintln|println|log\.)\s*\(.*\$\{?(token|key|secret|password|nonce|credential)' "$f" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        echo "INFO_LEAK: $f"
        echo "$hits" | sed 's/^/  /'
        found=1
    fi
done
exit $found
