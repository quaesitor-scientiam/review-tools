#!/usr/bin/env bash
# detect_idle_cap_counts_busy_conns.sh — flags evict_oldest_idle_locked
# (transport.v) if its cap check counts h2_conns via a bare `.len` (every
# connection, busy or idle) instead of filtering to active_streams == 0,
# matching the eligibility the eviction scan a few lines below it already
# uses.
#
# Bug class (Codex P3, vlang/v#27643 pullrequestreview-4631763931, discussion
# 3525390899): the cap CHECK and the eviction ACTION in the same function
# must use the SAME eligibility filter for a shared pool. A bare `h2_conns.len`
# counts busy (active_streams>0) connections toward the idle budget, even
# though the eviction scan can never pick a busy connection as its victim —
# so a pool with busy h2 connections and one genuinely idle h1 connection can
# look over budget purely from the busy count, and the unrelated idle h1
# connection gets wrongly evicted to "fix" a budget that was never actually
# exceeded.
#
# This is a narrow, function-specific detector (like several siblings in this
# corpus), not a general pattern matcher — it does not catch every possible
# way to get the count wrong (e.g. filtering correctly but ALSO excluding an
# entry the scan does not exclude — see the corpus entry for the follow-up
# mistake this exact fix made on its first attempt).
#
# Usage: detect_idle_cap_counts_busy_conns.sh <file> [git-commit]
# Exit: 1 if evict_oldest_idle_locked's cap-check section contains a bare
#       h2_conns.len; 0 if it doesn't (or the function isn't found); 2 on
#       read error.
set -uo pipefail
file="${1:?usage: detect_idle_cap_counts_busy_conns.sh <file> [commit]}"
base="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

src="$(cat "$file" 2>/dev/null)"
if [ -z "$src" ]; then
    echo "detect_idle_cap_counts_busy_conns: cannot read $file" >&2
    exit 2
fi

label="$file"
echo "=== idle-cap-counts-busy-conns detector: $label ==="

if ! printf '%s\n' "$src" | grep -q 'fn (mut t Transport) evict_oldest_idle_locked'; then
    echo "SKIP: no evict_oldest_idle_locked function found in $file"
    exit 0
fi

out="$(printf '%s\n' "$src" | awk '
    /fn \(mut t Transport\) evict_oldest_idle_locked/ { infn=1; depth=1; next }
    infn {
        depth += gsub(/\{/, "{")
        depth -= gsub(/\}/, "}")
        # Stop scanning once the eviction scan (the second h2_conns loop)
        # begins -- only the CAP-CHECK section above it is in scope here.
        if (/for k, mut c in t\.h2_conns/) { infn=0; next }
        if (/h2_conns\.len/) { print "  BUG: bare h2_conns.len in cap check (line contains no active_streams filter): " $0 }
        if (depth <= 0) { infn=0 }
    }
')"

if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "RESULT: cap check counts ALL h2 connections (busy or idle) instead of filtering to active_streams==0 like the eviction scan does."
    exit 1
fi
echo "RESULT: no bare h2_conns.len found in evict_oldest_idle_locked's cap-check section."
exit 0
