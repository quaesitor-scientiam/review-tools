#!/usr/bin/env bash
# detect_stream_state_even_idle.sh — flag a server stream-state classifier that
# can return `.closed` for a never-opened, server-initiated (EVEN) stream id.
#
# Bug class (Codex P2, vlang/v#27589 discussion_r3488271404): a server that never
# opens push streams must treat ANY id that is not in its stream map and is not a
# client-initiated (ODD) id <= last_stream_id as IDLE. `last_stream_id` tracks
# only client (odd) ids, so classifying "closed" by `id <= last_stream_id` alone
# misreads an even id (e.g. DATA/RST/WINDOW_UPDATE on stream 2 after odd stream 3
# opened) as closed → wrong RFC 9113 §5.1 scope (STREAM_CLOSED / silently ignored
# instead of the required connection-level PROTOCOL_ERROR).
#
# Rule: a `classify_stream`-style function that returns `.closed`/`closed` MUST
# also test the id's parity (`& 1`) — only an ODD id can be a closed CLIENT
# stream. Returning `.closed` with no `& 1` guard in the function is the defect.
#
# Usage: detect_stream_state_even_idle.sh <file> [git-commit]
#   With a commit, checks the file as of that commit (for Phase-R reproduction).
# Exit: 1 if the defect is present, 0 if clean (or no classifier in the file).
set -uo pipefail
file="${1:?usage: detect_stream_state_even_idle.sh <file> [commit]}"
base="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

src="$(cat "$file" 2>/dev/null)"
if [ -z "$src" ]; then
    echo "detect_stream_state_even_idle: cannot read $file" >&2
    exit 2
fi

# Extract each classify_stream function body (from its `fn ...classify_stream`
# line through the next line starting with `}`) and check the parity guard.
fn_body="$(printf '%s\n' "$src" | awk '
    /fn .*classify_stream/ {grab=1}
    grab {print}
    grab && /^}/ {grab=0}
')"

if [ -z "$fn_body" ]; then
    echo "detect_stream_state_even_idle: no classify_stream in $file — nothing to check"
    exit 0
fi

if printf '%s\n' "$fn_body" | grep -qE 'return[[:space:]]+\.?closed' \
    && ! printf '%s\n' "$fn_body" | grep -qE '&[[:space:]]*1'; then
    echo "FLAG: classify_stream returns .closed with no odd-id (\`& 1\`) parity guard."
    echo "  A never-opened EVEN (server-initiated) id is IDLE, not closed; a frame on"
    echo "  it must be a connection PROTOCOL_ERROR (RFC 9113 §5.1), not STREAM_CLOSED."
    echo "  File: $file"
    exit 1
fi

echo "OK: classify_stream gates 'closed' on stream-id parity ($file)"
exit 0
