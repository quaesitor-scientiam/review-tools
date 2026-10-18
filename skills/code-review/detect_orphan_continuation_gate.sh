#!/usr/bin/env bash
# detect_orphan_continuation_gate.sh
#
# Flags: dispatch_frame accepting a CONTINUATION frame when no HEADERS/
# CONTINUATION sequence is in progress (c.awaiting_cont == 0). RFC 9113 §6.10:
# a CONTINUATION is only legal immediately after a block that ended without
# END_HEADERS. Without a dispatch-level rejection for the awaiting_cont==0 case,
# a standalone/orphan CONTINUATION for a stream id that happens to be in
# c.locally_reset slips into on_continuation's discard branch and gets fed
# straight into the stateful HPACK decoder — a connection error masquerading as
# a routine drain.
#
# Conformant code has an `else if frame is H2ContinuationFrame { return
# error(...) }` arm alongside the existing `if c.awaiting_cont != 0 { ... }`
# guard in dispatch_frame, so on_continuation is only ever entered with
# awaiting_cont == frame.stream_id.
#
# Exit 1 on buggy code (pre pullrequestreview-4613845079 fix).
# Exit 0 after fix.

FILE="vlib/net/http/h2_server.v"

if [ ! -f "$FILE" ]; then
    echo "SKIP: $FILE not found" >&2
    exit 0
fi

# Find the `if c.awaiting_cont != 0 {` guard block in dispatch_frame and check
# for a sibling `else if frame is H2ContinuationFrame` arm within the next few
# lines (closing the awaiting_cont==0 gap).
if awk '
    /if c\.awaiting_cont != 0 \{/ { in_guard=1 }
    in_guard && /else if frame is H2ContinuationFrame/ { found=1 }
    in_guard && /^\tmatch frame \{/ { exit }
    END { exit !found }
' "$FILE"; then
    echo "OK: dispatch_frame rejects an orphan CONTINUATION when awaiting_cont == 0"
    exit 0
else
    echo "BUG: dispatch_frame has no awaiting_cont==0 rejection for H2ContinuationFrame — an orphan CONTINUATION on a locally_reset stream id is silently decoded and discarded"
    exit 1
fi
