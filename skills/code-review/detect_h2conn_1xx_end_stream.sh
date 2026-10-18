#!/usr/bin/env bash
# Detect: H2Conn.read_response (the synchronous client) discards a 1xx interim
# HEADERS frame with `continue` but does not reject END_STREAM on it.
#
# A 1xx informational response is not final and must not end the stream
# (RFC 9113 §8.1). If a peer sends a 1xx HEADERS with END_STREAM, the `continue`
# skips the `if frame.end_stream { break }` handling, so read_response loops back
# to next_frame() and waits forever for a final response the stream can no longer
# send — a malformed server hangs the request instead of erroring.
#
# The mux path (h2_mux_conn.v) already rejects this:
#   if !s.headers_done && frame.end_stream { reset_stream(.protocol_error, ...) }
# This is a cross-file protocol-parity gap: the sync path must fail too.
#
# Usage: bash detect_h2conn_1xx_end_stream.sh [file]
#
# Exit 1 when the 1xx interim branch in read_response does not reject
# frame.end_stream before `continue`. Exit 0 when it does.

set -uo pipefail

FILE="${1:-vlib/net/http/h2_conn.v}"
if [ ! -f "$FILE" ]; then
    echo "SKIP: $FILE not found" >&2
    exit 0
fi

# Extract the 1xx interim branch: from the `if status >= 100 && status < 200 {`
# line to its matching closing brace.
branch=$(awk '
    /if[[:space:]]+status[[:space:]]*>=[[:space:]]*100[[:space:]]*&&[[:space:]]*status[[:space:]]*<[[:space:]]*200/ { in_b=1; depth=0 }
    in_b {
        print
        for (i=1; i<=length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") depth++
            else if (c == "}") { depth--; if (depth == 0) { in_b=0; break } }
        }
    }
' "$FILE")

if [ -z "$branch" ]; then
    echo "SKIP: no 1xx interim branch (status >= 100 && status < 200) in $FILE" >&2
    exit 0
fi

# The branch must reject END_STREAM (a return error / reset on frame.end_stream)
# before falling through to its `continue`.
if printf '%s\n' "$branch" | grep -qE 'end_stream' \
    && printf '%s\n' "$branch" | grep -qE 'return error|reset_stream'; then
    echo "OK: the 1xx interim branch rejects END_STREAM before continuing" >&2
    exit 0
fi

echo "BUG: $FILE 1xx interim branch in read_response does not reject frame.end_stream — a 1xx HEADERS with END_STREAM hangs read_response (mux path rejects it; sync path must too, RFC 9113 §8.1)" >&2
exit 1
