#!/usr/bin/env bash
# detect_padding_credit.sh — flag DATA-frame flow-control code that uses
# frame.data.len instead of frame.flow_size for window crediting.
#
# Two defect patterns:
#   Pattern 1 (amount): send_window_update / conn_recv_window expression uses
#              data.len as the credit amount (should always be flow_size).
#   Pattern 2 (gate):   send_window_update is inside an `if frame.data.len > 0`
#              block, so padding-only DATA frames (data.len==0, flow_size>0)
#              never return window credit and permanently shrink the window.
#
# Usage: bash detect_padding_credit.sh <file> [base_copy_or_empty] [file...]
# Exit 0 = clean; Exit 1 = defect found.

set -euo pipefail

found=0

# $2 is the base-revision copy passed by run_detectors.sh: never a scan target.
for f in "$1" "${@:3}"; do
    # Pattern 1: wrong amount — send_window_update or conn_recv_window using data.len
    if grep -nE '(send_window_update|conn_recv_window).*\bdata\.len\b' "$f"; then
        echo "PADDING-CREDIT [P1-amount]: $f — data.len used as credit amount (should be flow_size)"
        found=1
    fi

    # Pattern 2: outer gate — if frame.data.len used in a file that also calls
    # send_window_update (candidate: window update may be nested inside the gate).
    # This is a heuristic; confirm the send_window_update is actually inside the block.
    if grep -q 'send_window_update' "$f" && grep -nE 'if\s+frame\.data\.len\b' "$f"; then
        echo "PADDING-CREDIT [P2-gate]: $f — 'if frame.data.len' gate found; confirm send_window_update is NOT nested inside it (padding-only frames would skip credit)"
        found=1
    fi
done

exit $found
