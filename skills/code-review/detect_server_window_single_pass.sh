#!/usr/bin/env bash
# detect_server_window_single_pass.sh
# Detects single-pass INITIAL_WINDOW_SIZE delta application in H2ServerConn
# apply_settings: if c.peer.initial_window_size is assigned BEFORE the stream
# send_window loop, a delta overflow on stream N leaves streams 1..N-1 with
# inflated windows and the error return emits the wrong GOAWAY code
# (PROTOCOL_ERROR instead of FLOW_CONTROL_ERROR).
#
# The fix is two-pass: validate all streams first (no mutations), then commit
# c.peer.initial_window_size and apply deltas — matching H2MuxConn.apply_peer_settings.
#
# Usage: bash detect_server_window_single_pass.sh [file] [commit]
#   file   defaults to vlib/net/http/h2_server.v
#   commit if given, checks that git revision instead of the working tree
# Exit 0 = clean (two-pass: assignment after the validation loop)
# Exit 1 = single-pass: assignment before the loop (bug present)

set -euo pipefail

FILE="${1:-vlib/net/http/h2_server.v}"
BASE="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

content=$(cat "$FILE") || { echo "ERROR: cannot read ${FILE}"; exit 2; }

# Strategy: find apply_settings, then find h2_settings_initial_window_size arm.
# Within that arm, record the line of `c.peer.initial_window_size = ` (the
# assignment) and the first `for ` loop line.  If the assignment line < first
# loop line, the mutation precedes validation -> single-pass bug.

in_fn=0
in_arm=0
assignment_line=0
first_loop_line=0
lineno=0

while IFS= read -r line; do
    lineno=$((lineno + 1))

    if [[ "$line" =~ "fn ".*"apply_settings" ]]; then
        in_fn=1; in_arm=0; assignment_line=0; first_loop_line=0
        continue
    fi
    [[ "$in_fn" -eq 0 ]] && continue
    if [[ "$line" =~ ^"fn " ]]; then
        in_fn=0; break
    fi

    if [[ "$line" == *"h2_settings_initial_window_size"* ]]; then
        in_arm=1; continue
    fi
    # Next setting arm or closing brace ends the arm.
    if [[ "$in_arm" -eq 1 ]]; then
        if [[ "$line" =~ ^[[:space:]]*"h2_settings_" || "$line" =~ ^[[:space:]]*"else " ]]; then
            in_arm=0
        fi
    fi
    [[ "$in_arm" -eq 0 ]] && continue

    if [[ "$line" == *"c.peer.initial_window_size ="* && "$line" != *"i64("* ]]; then
        # Exclude the delta calc line which reads initial_window_size.
        if [[ "$assignment_line" -eq 0 ]]; then
            assignment_line=$lineno
        fi
    fi
    if [[ "$line" =~ ^[[:space:]]+"for " && "$first_loop_line" -eq 0 ]]; then
        first_loop_line=$lineno
    fi
done <<< "$content"

if [[ "$assignment_line" -eq 0 ]]; then
    echo "ERROR: could not find c.peer.initial_window_size assignment in apply_settings"
    exit 2
fi
if [[ "$first_loop_line" -eq 0 ]]; then
    echo "ERROR: could not find for loop in h2_settings_initial_window_size arm"
    exit 2
fi

if [[ "$assignment_line" -lt "$first_loop_line" ]]; then
    echo "SINGLE-PASS: c.peer.initial_window_size assigned at line ${assignment_line} BEFORE stream loop at line ${first_loop_line}."
    echo "  A delta overflow on stream N leaves streams 1..N-1 with inflated windows and emits PROTOCOL_ERROR instead of FLOW_CONTROL_ERROR."
    exit 1
fi

echo "OK: c.peer.initial_window_size assigned after validation loop (two-pass)."
exit 0
