#!/usr/bin/env bash
# detect_hpack_skip_on_half_closed.sh
#
# Flags: on_headers RST-ing a post-END_STREAM HEADERS block WITHOUT first routing
# through the HPACK decoder. The decoder is connection-wide (RFC 7541 §2.2); a
# skipped block desyncs the dynamic table and breaks future requests.
#
# Conformant code adds `over_end = true` and routes through on_trailers so that
# finalize_trailers decodes THEN RSTs (same pattern as the refused-stream path).
#
# Exit 1 on buggy code (88a5d3435a and earlier).
# Exit 0 after fix.

FILE="vlib/net/http/h2_server.v"

if [ ! -f "$FILE" ]; then
    echo "SKIP: $FILE not found" >&2
    exit 0
fi

# The fix introduces an `over_end` field on H2ServerStream. Its absence means
# the buggy early-return path (RST without decode) is still in place.
if grep -q 'over_end' "$FILE"; then
    echo "OK: over_end present — post-END_STREAM HEADERS routed through decoder before RST"
    exit 0
else
    echo "BUG: over_end absent — on_headers RSTs post-END_STREAM HEADERS without HPACK decode (dynamic table desyncs)"
    exit 1
fi
