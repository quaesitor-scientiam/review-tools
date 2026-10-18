#!/usr/bin/env bash
# detect_error_scope.sh — flag `return error` inside reader-thread functions.
#
# In a multiplexed HTTP/2 connection, `return error` from a reader-thread
# function propagates to read_loop and triggers fail_conn(), tearing down EVERY
# in-flight stream. Per-stream faults must use reset_stream / cancel_stream
# (RST_STREAM + wake that one waiter) instead of returning a connection error.
#
# Reader-thread functions (flagged): dispatch_frame, mux_read_frame,
#   on_response_data, on_response_headers, on_rst_stream, on_settings, on_ping,
#   on_window_update, on_goaway, on_push_promise, read_frame, read_loop,
#   on_data [server-side], on_headers [server-side]
#
# Requester-thread functions (excluded): do_on_stream, wait_response,
#   send_body_on_stream, do, handle_request, run_request — their `return error`
#   returns to the caller, not to read_loop.
#
# Canonical miss (PR #27413): on_response_data's stream-receive-window violation
# did `return error` instead of reset_stream(.flow_control_error), killing all
# streams for one stream's fault.
#
# Heuristic: for each `return error` line, scan backward up to 60 lines for
# the most-recent function signature. If that signature matches a reader-thread
# function, flag it. Accuracy is high for well-structured V code (functions
# rarely exceed 60 lines in this module); false positives are possible for
# very long functions — confirm the fn signature by reading the context.
#
# Usage: bash detect_error_scope.sh <file> [base_copy_or_empty] [file...]
# Exit 0 = no candidates; Exit 1 = candidates found (review required).

set -u

# Client mux reader fns + server-side reader fns (the server runs everything on
# one reader thread, so a per-stream fault that `return error`s GOAWAYs the whole
# connection; per-stream faults must send_rst_stream + delete instead). The server
# trailer/continuation/finalize handlers were added after the first version of
# this detector — omitting them let on_trailers' "trailers without END_STREAM"
# connection-abort slip past review (Codex, vlang/v#27569). [[code-review-misses]]
READER_FNS='dispatch_frame|handle_control_frame|mux_read_frame|on_response_data|on_response_headers|on_rst_stream|on_settings|on_ping|on_window_update|on_goaway|on_push_promise|read_frame|read_loop|on_data\b|on_headers\b|on_continuation|on_trailers|finalize_headers|finalize_trailers'

found=0

# $2 is the base-revision copy passed by run_detectors.sh: never a scan target.
for f in "$1" "${@:3}"; do
    echo "=== error-scope scan: $f ==="
    any=0
    total_lines=$(wc -l < "$f" | tr -d ' ')

    while IFS=: read -r hit_line _; do
        [ -z "$hit_line" ] && continue

        # Scan backward from hit_line to find the most recent function signature
        lo=$((hit_line - 60))
        [ "$lo" -lt 1 ] && lo=1

        # Get lines lo..hit_line in reverse order, find the first fn signature
        fn_sig=""
        fn_line=""
        while IFS= read -r numbered; do
            lno=$(echo "$numbered" | cut -d: -f1)
            content=$(echo "$numbered" | cut -d: -f2-)
            if echo "$content" | grep -qE '^fn \('; then
                fn_sig=$(echo "$content" | sed 's/^[[:space:]]*//')
                fn_line=$lno
                break
            fi
        done < <(sed -n "${lo},${hit_line}p" "$f" | nl -ba -nrz -v"$lo" | tac | sed 's/^\s*\([0-9]*\)\t/\1:/')

        # Check if it's a reader-thread function
        if [ -n "$fn_sig" ] && echo "$fn_sig" | grep -qE "($READER_FNS)\s*\("; then
            echo "  line $hit_line: CANDIDATE"
            echo "    enclosing fn (line $fn_line): $fn_sig"
            echo "    $(sed -n "${hit_line}p" "$f" | sed 's/^[[:space:]]*//')"
            echo "    -> per-stream fault? use reset_stream/cancel_stream; connection-level fault? return error is correct"
            any=1
            found=1
        fi
    done < <(grep -nE '^\s*return\s+error\s*\(' "$f" 2>/dev/null || true)

    [ "$any" -eq 0 ] && echo "  clean — no return error in reader-thread functions"
    echo ""
done

[ "$found" -eq 1 ] && \
    echo "RESULT: review ERROR-SCOPE candidates — confirm each is a true connection-level fault." && \
    exit 1
echo "RESULT: no error-scope candidates in reader-thread functions." && exit 0
