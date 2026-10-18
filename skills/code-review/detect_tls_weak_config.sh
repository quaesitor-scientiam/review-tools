#!/usr/bin/env bash
# Exits 1 if any given TLS-touching file creates SslConfig without a min_version
# anywhere in that file.
#
# Usage: detect_tls_weak_config.sh <file> [base_copy_or_empty] [more files...]
#   File selection ("changed vs BASE") is run_detectors.sh's job: it passes one
#   changed file per call plus the base-revision copy as $2 (ignored here).
#   Until 2026-10-18 this script took a BASE revision as $1, so via the runner
#   (which passed a file) it always exited 0 without scanning anything.
set -euo pipefail
[ "$#" -ge 1 ] || { echo "usage: detect_tls_weak_config.sh <file> [base_copy_or_empty] [file...]" >&2; exit 2; }
files=("$1")
[ "$#" -ge 3 ] && files+=("${@:3}")
found=0
for f in "${files[@]}"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    grep -qE 'ssl|tls|mbedtls|SslConfig' "$f" 2>/dev/null || continue
    if grep -qE 'SslConfig\{|ssl_config\s*=' "$f" 2>/dev/null; then
        if ! grep -q 'min_version' "$f" 2>/dev/null; then
            echo "TLS_WEAK_CONFIG: $f: SslConfig created with no min_version in file"
            grep -nE 'SslConfig\{|ssl_config\s*=' "$f" | sed 's/^/  /'
            found=1
        fi
    fi
done
exit $found
