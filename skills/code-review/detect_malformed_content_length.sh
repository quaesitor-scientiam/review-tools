#!/usr/bin/env bash
# Detect: malformed Content-Length silently ignored in H2Conn
#
# When h2_conn.v receives a HEADERS frame it parses Content-Length.
# Bug: if all_digits() is the only guard and there is no else-error branch,
# a non-numeric value (e.g. "12junk") silently leaves has_content_length=false,
# skipping the body-length check and returning a corrupted response.
#
# Exit 1 (bug) when:
#   - the content-length block uses all_digits() as a silent filter
#   - AND no else branch containing return error() follows it
# Exit 0 (clean) when an else-error branch is present.
# Exit 2 on usage error.

FILE="${1:-vlib/net/http/h2_conn.v}"

if [ ! -f "$FILE" ]; then
    echo "File not found: $FILE" >&2
    exit 2
fi

# Find the line where f.name == 'content-length' is tested
cl_line=$(grep -n "f\.name == 'content-length'" "$FILE" | head -1 | cut -d: -f1)

if [ -z "$cl_line" ]; then
    echo "SKIP: content-length guard not found in $FILE" >&2
    exit 0
fi

# Grab a window of 20 lines from that point to inspect the block
window=$(tail -n +"$cl_line" "$FILE" | head -20)

# If all_digits is used anywhere in this window without an else-error, it's the bug.
# Case 1: all_digits AND else { return error( both present → clean
if echo "$window" | grep -q "all_digits" && echo "$window" | grep -qE "else\s*\{" && echo "$window" | grep -q "return error("; then
    echo "OK: content-length block has all_digits guard + else-error branch" >&2
    exit 0
fi

# Case 2: no all_digits in window (guard restructured to always-parse / always-error) → clean
if ! echo "$window" | grep -q "all_digits"; then
    echo "OK: no silent all_digits filter on content-length" >&2
    exit 0
fi

# Case 3: all_digits present without an else-error → bug
echo "BUG: content-length all_digits guard has no else-error branch (line $cl_line in $FILE)" >&2
exit 1
