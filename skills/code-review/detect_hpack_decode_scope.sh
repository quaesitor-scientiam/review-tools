#!/usr/bin/env bash
# detect_hpack_decode_scope.sh — an HPACK decode failure must be a CONNECTION
# error (GOAWAY COMPRESSION_ERROR, RFC 9113 §4.3), never a per-stream RST_STREAM.
#
# Why: H2HpackDecoder.decode mutates the dynamic table AS it processes the block,
# so a failure mid-block leaves the decoder out of sync with the peer — every
# subsequent header block on the connection decodes to garbage. Resetting just the
# one stream (RST_STREAM) keeps the corrupted connection alive. This is the INVERSE
# of detect_error_scope.sh (which flags conn-errors that should be per-stream); this
# flags a per-stream handler for a fault that must be connection-level.
#
# Heuristic: for each `.decode(...) or {` block, inspect the next ~6 lines. If it
# calls send_rst_stream -> BUG; if send_goaway(.compression_error) -> OK.
#
# Canonical miss: H2ServerConn.finalize_headers/finalize_trailers RST'd the stream
# on a decode failure (Codex P2, vlang/v#27569, discussion_r3485226568). [[code-review-misses]]
#
# Usage: bash detect_hpack_decode_scope.sh <file...>   (run in WSL — see memory)
# Exit 0 = all decode failures are connection-scoped; Exit 1 = a per-stream RST found.

set -uo pipefail

found=0
for f in "$@"; do
    echo "=== hpack-decode-scope: $f ==="
    any=0
    while IFS=: read -r ln _; do
        [ -z "$ln" ] && continue
        blk=$(sed -n "${ln},$((ln + 6))p" "$f")
        if echo "$blk" | grep -q 'send_rst_stream'; then
            echo "  line $ln: BUG — decode() failure handled with send_rst_stream (per-stream)"
            echo "    -> must be send_goaway(.compression_error) + return (connection error, RFC 9113 §4.3)"
            any=1
            found=1
        elif echo "$blk" | grep -qE 'send_goaway.*compression_error|compression_error'; then
            echo "  line $ln: OK — decode() failure -> connection COMPRESSION_ERROR"
        else
            echo "  line $ln: REVIEW — decode() failure handler unclear; confirm it closes the connection"
        fi
    done < <(grep -nE '\.decode\(.*\)[[:space:]]*or[[:space:]]*\{' "$f" 2>/dev/null || true)
    [ "$any" -eq 0 ] && echo "  clean — every decode() failure is connection-scoped"
    echo ""
done

[ "$found" -eq 1 ] && \
    echo "RESULT: HPACK decode failure handled per-stream — must be a connection COMPRESSION_ERROR." && \
    exit 1
echo "RESULT: all HPACK decode failures are connection-scoped." && exit 0
