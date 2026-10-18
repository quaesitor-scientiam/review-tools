#!/usr/bin/env bash
# Detect: H2MuxConn.on_response_headers appends a HEADERS-after-END_STREAM as
# trailers instead of treating it as a frame on a closed stream.
#
# A second HEADERS block is trailers; but a THIRD HEADERS (or any HEADERS after a
# prior END_STREAM already set s.ended) is a frame on a half-closed/closed stream
# (RFC 9113 §5.1) and must be reset, not appended to resp.headers. The trailers
# branch only gated on `was_headers_done`, so back-to-back trailer + extra HEADERS
# in one read buffer would be delivered in resp.headers before wait_response
# flushed. The DATA path already checks s.ended; the HEADERS path must too.
# (Codex P2 on vlang/v#27413, discussion_r... comment 3482020777.)
#
# Fix: at the top of on_response_headers (after locking the stream), if s.ended is
# already set, reset_stream and return — before the trailers (was_headers_done)
# handling.
#
# Usage: bash detect_mux_headers_after_end.sh [file]
# Exit 1 if on_response_headers does not guard on s.ended before the trailers branch.

set -uo pipefail

FILE="${1:-vlib/net/http/h2_mux_conn.v}"
if [ ! -f "$FILE" ]; then
    echo "SKIP: $FILE not found" >&2
    exit 0
fi

# Extract on_response_headers from its signature to the trailers branch
# (`if was_headers_done {`), and require an `if s.ended {` guard within it.
region=$(awk '
    /fn \(mut c H2MuxConn\) on_response_headers\(/ { capture=1 }
    capture { print }
    capture && /if was_headers_done \{/ { exit }
' "$FILE")

if [ -z "$region" ]; then
    echo "SKIP: could not locate on_response_headers / its trailers branch in $FILE" >&2
    exit 0
fi

if echo "$region" | grep -qE 'if[[:space:]]+s\.ended[[:space:]]*\{'; then
    echo "OK: $FILE guards on s.ended before the trailers branch (HEADERS-after-end is reset)" >&2
    exit 0
fi

echo "BUG: $FILE on_response_headers does not check s.ended before appending trailers." >&2
echo "  A HEADERS frame after the stream already ended (a prior END_STREAM) is a frame on a" >&2
echo "  closed stream (RFC 9113 §5.1), not more trailers — it must reset the stream, else its" >&2
echo "  fields can be delivered in resp.headers. Add an 'if s.ended { reset_stream; return }'" >&2
echo "  guard after locking, before the was_headers_done trailers handling." >&2
exit 1
