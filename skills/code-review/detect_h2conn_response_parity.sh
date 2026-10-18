#!/usr/bin/env bash
# Detect: H2Conn.read_response (synchronous HTTP/2 client) is missing response-
# validation guards that the mux path (H2MuxConn.on_response_headers /
# on_response_data) already enforces. Each gap lets a malformed server hang the
# request (loop in next_frame()) or be silently accepted.
#
# Checks read_response for three guards (the 1xx+END_STREAM guard has its own
# detector, detect_h2conn_1xx_end_stream.sh):
#   1. Trailers (a second HEADERS after got_headers) must carry END_STREAM,
#      else read_response loops forever. Marker: a got_headers + !frame.end_stream
#      rejection.
#   2. DATA before the first HEADERS is a protocol error. Marker: the H2DataFrame
#      arm rejects !got_headers.
#   3. :status must be in range and not 101 (RFC 9113 §8.1.1/§8.3.1). Marker: a
#      rejection of status > 599 or status == 101 (the <100 case rides along).
#
# Usage: bash detect_h2conn_response_parity.sh [file]
# Exit 1 if any guard is missing; exit 0 if all present.

set -uo pipefail

FILE="${1:-vlib/net/http/h2_conn.v}"
if [ ! -f "$FILE" ]; then
    echo "SKIP: $FILE not found" >&2
    exit 0
fi

missing=()

# 1. Trailers must carry END_STREAM: look for a guard mentioning trailers +
#    END_STREAM, or a got_headers && !end_stream rejection.
if ! grep -qiE 'trailers.*END_STREAM|trailer.*end_stream' "$FILE"; then
    missing+=("trailers-without-END_STREAM guard (got_headers + second HEADERS lacking END_STREAM must error)")
fi

# 2. DATA before HEADERS: the H2DataFrame handling must reject !got_headers.
if ! grep -qE 'DATA.*before.*HEADERS|before response HEADERS' "$FILE"; then
    missing+=("DATA-before-HEADERS guard (H2DataFrame arm must reject !got_headers)")
fi

# 3. status range / 101 rejection.
if ! grep -qE 'status[[:space:]]*>[[:space:]]*599|status[[:space:]]*==[[:space:]]*101' "$FILE"; then
    missing+=(":status range/101 rejection (status < 100 || status > 599 || status == 101)")
fi

if [ "${#missing[@]}" -eq 0 ]; then
    echo "OK: read_response enforces trailers-END_STREAM, DATA-before-HEADERS, and :status range/101 (parity with the mux path)" >&2
    exit 0
fi

echo "BUG: $FILE read_response is missing response-validation guards the mux path enforces:" >&2
for m in "${missing[@]}"; do
    echo "  - $m" >&2
done
exit 1
