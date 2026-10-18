#!/usr/bin/env bash
# Exits 1 if any changed .v/.vv file has log/print calls interpolating sensitive-named variables.
set -euo pipefail
BASE=${1:-$(git merge-base master HEAD)}
files=$(git diff --name-only "$BASE"..HEAD -- '*.v' '*.vv' 2>/dev/null || true)
[ -z "$files" ] && exit 0
found=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    hits=$(grep -nE '(eprintln|println|log\.)\s*\(.*\$\{?(token|key|secret|password|nonce|credential)' "$f" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        echo "INFO_LEAK: $f"
        echo "$hits" | sed 's/^/  /'
        found=1
    fi
done <<< "$files"
exit $found
