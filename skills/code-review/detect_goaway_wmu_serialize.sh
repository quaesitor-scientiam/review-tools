#!/usr/bin/env bash
# Detect: the H2GoawayFrame handler sets the c.goaway admission flag without
# serializing on wmu, so it can race the HEADERS write in do_on_stream.
#
# do_on_stream rechecks the terminal flags (c.closed || c.goaway ||
# c.shutting_down) under smu *while holding wmu*, then releases smu and writes
# the request HEADERS still under wmu. If the GOAWAY handler sets c.goaway
# while taking only smu (not wmu), it can land between that recheck and the
# write — the client then opens one more stream after observing GOAWAY,
# violating RFC 7540 §6.8. Serializing the GOAWAY handler on wmu makes the
# recheck authoritative: c.goaway cannot be set while any writer holds wmu.
#
# Usage:
#   bash detect_goaway_wmu_serialize.sh <file_under_review>
#
# Exit 1 when the H2GoawayFrame arm sets c.goaway without a c.wmu.lock() in
# the same arm. Exit 0 when wmu is taken (serialized) or no GOAWAY arm exists.

set -uo pipefail

FILE="${1:-vlib/net/http/h2_mux_conn.v}"
if [ ! -f "$FILE" ]; then
    echo "Usage: $0 <v-source-file>" >&2
    exit 2
fi

# Extract the body of the H2GoawayFrame match arm (from the arm label to its
# closing brace at the same depth).
arm_body=$(awk '
    /H2GoawayFrame[[:space:]]*\{/ { in_arm=1; depth=0 }
    in_arm {
        print
        for (i=1; i<=length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") depth++
            else if (c == "}") {
                depth--
                if (depth == 0) { in_arm=0; break }
            }
        }
    }
' "$FILE")

if [ -z "$arm_body" ]; then
    echo "SKIP: no H2GoawayFrame arm found in $FILE" >&2
    exit 0
fi

# Does the arm set the goaway admission flag?
if ! printf '%s\n' "$arm_body" | grep -qE 'c\.goaway[[:space:]]*=[[:space:]]*true'; then
    echo "SKIP: H2GoawayFrame arm does not set c.goaway in $FILE" >&2
    exit 0
fi

# Does the arm serialize on wmu? Setting c.goaway under wmu makes do_on_stream's
# recheck (performed while holding wmu) authoritative.
if printf '%s\n' "$arm_body" | grep -qE 'c\.wmu\.lock\(\)'; then
    echo "OK: H2GoawayFrame arm serializes on wmu before setting c.goaway" >&2
    exit 0
fi

echo "BUG: H2GoawayFrame arm in $FILE sets c.goaway without taking c.wmu.lock() — races the HEADERS write in do_on_stream (RFC 7540 §6.8: opens a stream after observing GOAWAY)" >&2
exit 1
