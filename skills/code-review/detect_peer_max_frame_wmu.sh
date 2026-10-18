#!/usr/bin/env bash
# Detect: H2MuxConn.apply_peer_settings updates c.peer_max_frame under fmu ONLY.
#
# The send paths (send_header_block_locked, send_body_on_stream) re-read
# peer_max_frame under fmu and then write the frame under wmu, RELEASING fmu in
# between. They hold wmu across that re-read-and-write. If the reader applies a
# lowered SETTINGS_MAX_FRAME_SIZE under fmu-only, it can change peer_max_frame in
# the fmu-release -> write gap, so a sender emits a frame larger than the peer's
# new limit and the peer kills the connection with FRAME_SIZE_ERROR.
# (Codex P2 on vlang/v#27413, discussion_r3474404838.)
#
# Fix: update peer_max_frame under wmu (then fmu) so it serializes with the
# senders that hold wmu, exactly like the h2_settings_header_table_size arm
# already does for the HPACK encoder. apply_peer_settings holds no connection
# lock at entry, so wmu -> fmu is the permitted nesting.
#
# Usage: bash detect_peer_max_frame_wmu.sh [file]
# Exit 1 if the max_frame_size arm sets peer_max_frame without holding wmu.

set -uo pipefail

FILE="${1:-vlib/net/http/h2_mux_conn.v}"
if [ ! -f "$FILE" ]; then
    echo "SKIP: $FILE not found" >&2
    exit 0
fi

# Extract the h2_settings_max_frame_size arm: from its header to the next arm
# (the `else {}` catch-all of the same match) or the assignment region. Capture a
# generous window after the arm header and inspect the lines up to and including
# the `c.peer_max_frame = st.value` assignment.
arm=$(awk '
    /h2_settings_max_frame_size[[:space:]]*\{/ { capture=1 }
    capture { print }
    capture && /c\.peer_max_frame[[:space:]]*=[[:space:]]*st\.value/ { exit }
' "$FILE")

if [ -z "$arm" ]; then
    echo "SKIP: could not locate the h2_settings_max_frame_size arm in $FILE" >&2
    exit 0
fi

# The assignment (and its surrounding lock acquisition) must be guarded by wmu.
if echo "$arm" | grep -qE 'c\.wmu\.lock\(\)'; then
    echo "OK: $FILE updates peer_max_frame under wmu (serialized with the send paths)" >&2
    exit 0
fi

echo "BUG: $FILE sets c.peer_max_frame in the SETTINGS_MAX_FRAME_SIZE arm without holding wmu." >&2
echo "  Senders hold wmu across their peer_max_frame re-read and the frame write; an fmu-only" >&2
echo "  update can lower the limit in the fmu-release -> write gap, emitting an oversized frame" >&2
echo "  (FRAME_SIZE_ERROR). Take wmu (then fmu) like the header_table_size arm." >&2
exit 1
