#!/usr/bin/env bash
# Detect: HTTP/2 client accepts malformed response header fields (RFC 9113 §8.2).
#
# A conformant client MUST treat a response (or trailer block) that contains an
# uppercase field name, a connection-specific field (connection, keep-alive,
# transfer-encoding, upgrade, proxy-connection), or an undefined/misplaced
# pseudo-header as MALFORMED (§8.1.1 / §8.2.1 / §8.2.2 / §8.3). Both client paths
# previously appended received fields with only :status and content-length
# validation, silently delivering malformed responses to the caller — the same
# "lenient acceptance of wire input" class as the lenient-parse family, applied
# to the whole header set. Found by the proactive RFC-conformance audit (gap G1),
# not by an external reviewer.
#
# Fix: validate every received non-pseudo field with h2_response_field_error and
# reject (mux: reset_stream PROTOCOL_ERROR; sync: fail the request) on both the
# response-headers path and the trailers path, in BOTH h2_mux_conn.v (mux) and
# h2_conn.v (sync) so the two paths stay at parity.
#
# Usage: bash detect_h2_response_field_validation.sh
# Exit 1 if either client path does not validate received response field names.

set -uo pipefail

mux="${1:-vlib/net/http/h2_mux_conn.v}"
sync="${2:-vlib/net/http/h2_conn.v}"

fail=0
for f in "$mux" "$sync"; do
    if [ ! -f "$f" ]; then
        echo "SKIP: $f not found" >&2
        continue
    fi
    # The fixed code calls h2_response_field_error(f.name) on the received fields.
    # Require at least two call sites per file (the response path and the trailer
    # path); the helper definition itself is not a call (it has no argument).
    calls=$(grep -cE 'h2_response_field_error\(f\.name\)' "$f")
    if [ "$calls" -lt 2 ]; then
        echo "BUG: $f validates < 2 received header blocks (response + trailers) for malformed" >&2
        echo "  field names (RFC 9113 §8.2): found ${calls} h2_response_field_error(f.name) call(s)." >&2
        fail=1
    else
        echo "OK: $f rejects malformed received response/trailer field names (${calls} call sites)" >&2
    fi
done

[ "$fail" -eq 1 ] && exit 1
exit 0
