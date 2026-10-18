#!/usr/bin/env bash
# detect_pump_delegates_dispatch.sh — flag a secondary frame reader that does not
# route frames through the unified dispatch.
#
# Bug class (Codex P2, vlang/v#27589 discussion_r3488302384): the h2 server reads
# frames in TWO places — the main loop (serve -> dispatch_frame) and the
# flow-control stall (send_body -> pump_for_window). pump_for_window reimplemented
# a SUBSET of dispatch (control frames + RST), ignoring HEADERS/DATA/CONTINUATION.
# So a frame arriving while a response is stalled on flow control (e.g. HEADERS for
# an over-limit stream, sent before the WINDOW_UPDATE) was silently dropped: its
# HPACK block was never decoded (decoder desync) and the over-limit stream was
# never RST(REFUSED_STREAM)'d. Any rule added to dispatch_frame (validation,
# refuse, idle/closed handling) silently fails to apply on the second path.
#
# Rule: a function that calls read_frame() to service a stall MUST delegate to the
# single dispatch function, not hand-pick frame types. pump_for_window must call
# dispatch_frame.
#
# Usage: detect_pump_delegates_dispatch.sh <file> [git-commit]
# Exit: 1 if pump_for_window reads frames without delegating to dispatch_frame.
set -uo pipefail
file="${1:?usage: detect_pump_delegates_dispatch.sh <file> [commit]}"
commit="${2:-}"

if [ -n "$commit" ]; then
    src="$(git show "${commit}:${file}" 2>/dev/null)"
else
    src="$(cat "$file" 2>/dev/null)"
fi
if [ -z "$src" ]; then
    echo "detect_pump_delegates_dispatch: cannot read $file${commit:+ @ $commit}" >&2
    exit 2
fi

body="$(printf '%s\n' "$src" | awk '
    /fn .*pump_for_window/ {grab=1}
    grab {print}
    grab && /^}/ {grab=0}
')"

if [ -z "$body" ]; then
    echo "detect_pump_delegates_dispatch: no pump_for_window in $file — nothing to check"
    exit 0
fi

if printf '%s\n' "$body" | grep -q 'read_frame' \
    && ! printf '%s\n' "$body" | grep -q 'dispatch_frame'; then
    echo "FLAG: pump_for_window reads frames but does not delegate to dispatch_frame."
    echo "  A response stalled on flow control reads frames here; handling only a"
    echo "  subset (control + RST) drops HEADERS/DATA/CONTINUATION — HPACK desync and"
    echo "  missed RFC 9113 §5.1/§5.1.2 handling. Route through dispatch_frame."
    echo "  File: $file${commit:+ @ $commit}"
    exit 1
fi

echo "OK: pump_for_window delegates to dispatch_frame ($file${commit:+ @ $commit})"
exit 0
