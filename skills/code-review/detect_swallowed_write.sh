#!/usr/bin/env bash
# detect_swallowed_write.sh — flag or{} on write/IO operations that should
# set an admission gate when they fail.
#
# A dangerous window exists when:
#   1. Write A fails silently (or {})
#   2. No gate (shutting_down/closed) is set on that path
#   3. Another goroutine can observe the resource as healthy between A and the
#      next operation that eventually does set the gate
#
# This is an ENUMERATE-AND-VERIFY heuristic: every flagged line is a candidate
# for human review — check whether the enclosing function calls
# note_write_failure(), teardown_transport(), or sets shutting_down/closed
# on its failure path. If none of these follow, the write error is silently
# dropped and the admission gate stays open.
#
# Usage: bash detect_swallowed_write.sh <file> [base_copy_or_empty] [file...]
# Exit 0 = no candidates; Exit 1 = candidates found (review required).

set -euo pipefail
found=0

# $2 is the base-revision copy passed by run_detectors.sh: never a scan target.
for f in "$1" "${@:3}"; do
    # Match write/IO operations that swallow their error with or {}
    # Patterns: write_all_locked, send_frame, send_window_update, send_rst_stream,
    # send_ping, send_goaway, transport.write, write_all
    hits=$(grep -nE \
      '(write_all_locked|send_frame|send_window_update|send_conn_window_update|send_window_updates|send_rst_stream|send_ping|send_goaway|transport\.write|write_all|note_write_failure)\s*\(.*\)\s+or\s*\{\s*\}' \
      "$f" 2>/dev/null || true)

    if [ -n "$hits" ]; then
        echo "=== SWALLOWED-WRITE candidates in $f ==="
        echo "$hits"
        echo ""
        echo "  For each line above, verify the enclosing function either:"
        echo "    (a) calls note_write_failure() / teardown_transport() on the failure path, OR"
        echo "    (b) a subsequent operation in the same path always sets shutting_down/closed."
        echo "  A silent or{} is safe ONLY when write failure is benign (e.g., best-effort ping)."
        echo ""
        found=1
    fi
done

[ "$found" -eq 1 ] && echo "RESULT: review the SWALLOWED-WRITE candidates above." && exit 1
echo "RESULT: no swallowed write operations found." && exit 0
