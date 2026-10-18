#!/usr/bin/env bash
# detect_flag_priority_order.sh — enumerate functions with 2+ early-return
# single-field boolean-flag checks and list them in source order for a
# priority review.
#
# Bug class (Codex P2, vlang/v#27627 pullrequestreview-4620412384):
# `finalize_headers` gated on TWO independent boolean flags on the same
# struct, each with its own early-return branch:
#   if s.refused  { send_rst_stream(.refused_stream);  ... ; return }
#   if s.self_dep { send_rst_stream(.protocol_error);  ... ; return }
# The check ORDER encodes an implicit priority: whichever flag is tested
# first wins when BOTH are true. `refused` was tested first, so a request
# that was both over the concurrency limit AND self-dependent reported
# REFUSED_STREAM (misleadingly "safe to retry") instead of the correct,
# more specific PROTOCOL_ERROR (always malformed, retry or not).
#
# This is an ENUMERATE-AND-VERIFY aid, not a clean pass/fail gate: two
# early-return flag checks in one function are not automatically wrong —
# sometimes the flags are genuinely mutually exclusive, or the order is
# already correct. The point is to force an explicit "what happens if BOTH
# flags are true, and is that the right priority?" question whenever a diff
# touches ONE of a multi-flag function's checks — a reviewer skimming only
# the new lines has no structural reason to look at the sibling checks
# around it.
#
# Usage: detect_flag_priority_order.sh <file> [git-commit]
# Exit: 1 if any function has 2+ early-return single-field boolean checks
#       (candidates to review by hand); 0 if none found; 2 on read error.
set -uo pipefail
file="${1:?usage: detect_flag_priority_order.sh <file> [commit]}"
base="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

src="$(cat "$file" 2>/dev/null)"
if [ -z "$src" ]; then
    echo "detect_flag_priority_order: cannot read $file" >&2
    exit 2
fi

label="$file"
echo "=== flag-priority-order detector: $label ==="

out="$(printf '%s\n' "$src" | awk '
    /^fn / {
        if (fname != "" && nflags >= 2) {
            print "  " fname
            for (i = 1; i <= nflags; i++) print "    " flaglines[i] ": " flagnames[i]
            print ""
        }
        fname=$0; sub(/[ \t]*\{.*/, "", fname); nflags=0; delete flaglines; delete flagnames
        next
    }
    /^}$/ {
        if (fname != "" && nflags >= 2) {
            print "  " fname
            for (i = 1; i <= nflags; i++) print "    " flaglines[i] ": " flagnames[i]
            print ""
        }
        fname=""; nflags=0; delete flaglines; delete flagnames
        next
    }
    fname != "" && /^\tif [a-zA-Z_]+\.[a-z_]+ \{$/ {
        line=$0; gsub(/^[ \t]+/, "", line)
        nflags++
        flaglines[nflags]=NR
        flagnames[nflags]=line
    }
')"

if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "RESULT: functions above have 2+ early-return flag checks — confirm the order is intentional (what happens if both are true?)."
    exit 1
fi
echo "RESULT: no function with 2+ early-return single-field flag checks found."
exit 0
