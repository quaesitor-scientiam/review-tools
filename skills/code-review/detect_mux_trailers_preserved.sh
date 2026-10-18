#!/usr/bin/env bash
# Detect: H2MuxConn drops trailing HEADERS (trailers) instead of surfacing them.
#
# A muxed response can be followed by a second HEADERS block carrying trailers
# (grpc-status, digest, ...). on_response_headers HPACK-decodes that block (it
# must, to keep decoder state in sync) but the trailer path only marked the
# stream ended ("only its END_STREAM matters for this client") and never
# appended the decoded fields anywhere, so callers lost every trailer field.
# The synchronous H2Conn.read_response appends non-pseudo trailer fields to
# H2ClientResponse.headers, so a caller switched to H2MuxConn silently loses
# response metadata even though the stream completed normally. (Codex P2 on
# vlang/v#27413, discussion_r3477245531; the sync/mux response-parity class.)
#
# Fix: in the trailers branch (was_headers_done), append the non-pseudo decoded
# fields to a per-stream trailer list and flush it into resp.headers when the
# stream ends in wait_response — mirroring the sync path.
#
# Usage: bash detect_mux_trailers_preserved.sh [file]
# Exit 1 if the trailer-handling branch sets s.ended without preserving fields.

set -uo pipefail

FILE="${1:-vlib/net/http/h2_mux_conn.v}"
if [ ! -f "$FILE" ]; then
    echo "SKIP: $FILE not found" >&2
    exit 0
fi

# Extract the trailer-handling region of on_response_headers: from the
# trailers-without-END_STREAM check (the first line that is specific to a second
# HEADERS block) to the cv signal that ends the function's locked section.
region=$(awk '
    /was_headers_done[[:space:]]*&&[[:space:]]*!frame\.end_stream/ { capture=1 }
    capture { print }
    capture && /s\.cv\.signal\(\)/ { exit }
' "$FILE")

if [ -z "$region" ]; then
    echo "SKIP: could not locate the trailer-handling region in $FILE" >&2
    exit 0
fi

# The fixed code appends the decoded trailer fields to a response header/trailer
# list in this region. The buggy code only sets s.ended (no append).
if echo "$region" | grep -qE 'resp_(trailers|headers)[[:space:]]*<<'; then
    echo "OK: $FILE preserves trailer fields on the mux path (sync/mux parity)" >&2
    exit 0
fi

echo "BUG: $FILE drops trailing HEADERS on the mux path." >&2
echo "  The second-HEADERS (trailers) branch in on_response_headers sets s.ended but never" >&2
echo "  appends the decoded fields, so grpc-status/digest/etc. are lost. The sync" >&2
echo "  H2Conn.read_response appends non-pseudo trailers to the response headers; mirror it" >&2
echo "  (append to a per-stream trailer list, flush into resp.headers when the stream ends)." >&2
exit 1
