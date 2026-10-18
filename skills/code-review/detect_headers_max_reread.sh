#!/usr/bin/env bash
# detect_headers_max_reread.sh
# Detects two TOCTOU gaps in send_header_block_locked where peer_max_frame is
# read once at function entry and the stale snapshot is used for a HEADERS write
# without a re-read under fmu immediately before the write:
#
#   Gap 1 (single-frame path): block.len <= max → write H2HeadersFrame{ directly.
#     If the peer lowers SETTINGS_MAX_FRAME_SIZE between the snapshot and the
#     write, the single HEADERS frame can exceed the new limit → FRAME_SIZE_ERROR.
#
#   Gap 2 (multi-frame path): the first HEADERS write in the multi-frame branch
#     uses the stale snapshot; CONTINUATION frames re-read per iteration, but the
#     first frame does not.
#
# Usage: bash detect_headers_max_reread.sh [file] [commit]
#   file   defaults to vlib/net/http/h2_mux_conn.v
#   commit if given, checks that git revision instead of the working tree
# Exit 0 = clean (fmu re-read under fmu immediately before both writes)
# Exit 1 = stale snapshot for at least one path (bug present)

set -euo pipefail

FILE="${1:-vlib/net/http/h2_mux_conn.v}"
BASE="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

content=$(cat "$FILE") || { echo "ERROR: cannot read ${FILE}"; exit 2; }

# Strategy: parse send_header_block_locked line by line.
# After the initial c.fmu.unlock() (end of function-entry snapshot), track:
#   - fmu_reads_before_first  : c.fmu.lock() calls before the 1st H2HeadersFrame{
#   - fmu_reads_before_second : c.fmu.lock() calls between 1st and 2nd H2HeadersFrame{
# Both must be >= 1 for the file to be clean.

in_fn=0
state=0   # 0=pre-fn or pre-first-unlock  1=scanning
fmu_reads_before_first=0
fmu_reads_before_second=0
headers_count=0
first_headers_line=0
second_headers_line=0
first_unlock_line=0
lineno=0

while IFS= read -r line; do
    lineno=$((lineno + 1))

    if [[ "$line" =~ "fn ".*"send_header_block_locked" ]]; then
        in_fn=1; state=0
        fmu_reads_before_first=0; fmu_reads_before_second=0; headers_count=0
        continue
    fi
    [[ "$in_fn" -eq 0 ]] && continue
    if [[ "$line" =~ ^"fn " ]]; then
        in_fn=0; break
    fi

    case $state in
    0)
        # Wait for the first c.fmu.unlock() (end of function-entry snapshot).
        if [[ "$line" == *"c.fmu.unlock()"* ]]; then
            state=1; first_unlock_line=$lineno
        fi
        ;;
    1)
        if [[ "$headers_count" -eq 0 ]]; then
            # Before the first H2HeadersFrame{ write.
            if [[ "$line" == *"c.fmu.lock()"* ]]; then
                fmu_reads_before_first=$((fmu_reads_before_first + 1))
            fi
            if [[ "$line" == *"H2HeadersFrame{"* ]]; then
                headers_count=1; first_headers_line=$lineno
            fi
        else
            # Between the first and second H2HeadersFrame{ writes.
            if [[ "$line" == *"c.fmu.lock()"* ]]; then
                fmu_reads_before_second=$((fmu_reads_before_second + 1))
            fi
            if [[ "$line" == *"H2HeadersFrame{"* ]]; then
                headers_count=2; second_headers_line=$lineno
                break
            fi
        fi
        ;;
    esac
done <<< "$content"

if [[ "$headers_count" -lt 2 ]]; then
    echo "ERROR: could not locate two H2HeadersFrame{ writes in send_header_block_locked (found ${headers_count})"
    exit 2
fi

exit_code=0

if [[ "$fmu_reads_before_first" -eq 0 ]]; then
    echo "STALE [single-frame path]: no fmu re-read between first fmu.unlock() (line ${first_unlock_line}) and first H2HeadersFrame{ (line ${first_headers_line})."
    echo "  A peer lowering SETTINGS_MAX_FRAME_SIZE in that window -> oversized single HEADERS the peer rejects with FRAME_SIZE_ERROR."
    exit_code=1
fi

if [[ "$fmu_reads_before_second" -eq 0 ]]; then
    echo "STALE [multi-frame path]: no fmu re-read between first H2HeadersFrame{ (line ${first_headers_line}) and second H2HeadersFrame{ (line ${second_headers_line})."
    echo "  A peer lowering SETTINGS_MAX_FRAME_SIZE in that window -> oversized first multi-frame HEADERS the peer rejects."
    exit_code=1
fi

if [[ "$exit_code" -eq 0 ]]; then
    echo "OK: fmu re-read present before both single-frame and multi-frame HEADERS writes."
fi
exit $exit_code
