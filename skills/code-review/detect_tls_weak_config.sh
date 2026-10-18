#!/usr/bin/env bash
# Exits 1 if any changed TLS-touching file creates SslConfig without a min_version in the file.
set -euo pipefail
BASE=${1:-$(git merge-base master HEAD)}
files=$(git diff --name-only "$BASE"..HEAD -- '*.v' '*.vv' 2>/dev/null || true)
[ -z "$files" ] && exit 0
found=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    grep -qE 'ssl|tls|mbedtls|SslConfig' "$f" 2>/dev/null || continue
    if grep -qE 'SslConfig\{|ssl_config\s*=' "$f" 2>/dev/null; then
        if ! grep -q 'min_version' "$f" 2>/dev/null; then
            echo "TLS_WEAK_CONFIG: $f: SslConfig created with no min_version in file"
            grep -nE 'SslConfig\{|ssl_config\s*=' "$f" | sed 's/^/  /'
            found=1
        fi
    fi
done <<< "$files"
exit $found
