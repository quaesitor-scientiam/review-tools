#!/usr/bin/env bash
# detect_fmu_scope.sh
# Detects: c.fmu.unlock() appears before c.wmu.lock()+H2DataFrame in
# send_body_on_stream, creating a TOCTOU window where the reader can process
# SETTINGS_MAX_FRAME_SIZE and send the ACK between chunk sizing and the write.
# Usage: bash detect_fmu_scope.sh [file] [commit]
#   file   defaults to vlib/net/http/h2_mux_conn.v
#   commit if given, checks that git revision instead of the working tree
# Exit 0 = clean (fmu held across DATA write); exit 1 = race detected.
set -euo pipefail

FILE="${1:-vlib/net/http/h2_mux_conn.v}"
COMMIT="${2:-}"

if [[ -n "$COMMIT" ]]; then
    content=$(git show "${COMMIT}:${FILE}" 2>/dev/null \
        || { echo "ERROR: cannot read ${COMMIT}:${FILE}"; exit 2; })
else
    content=$(cat "$FILE")
fi

# State machine inside send_body_on_stream:
#   0 -> looking for c.fmu.unlock()
#   1 -> saw c.fmu.unlock(), looking for c.wmu.lock()
#   2 -> saw c.wmu.lock() after fmu.unlock(), looking for H2DataFrame{
# A c.fmu.lock() in state 1 resets to 0 (fmu re-acquired, no race).
# H2DataFrame{ in state 2 is the race.

in_fn=0
state=0
fmu_line=0
wmu_line=0
lineno=0
found=0

while IFS= read -r line; do
    lineno=$((lineno + 1))

    if [[ "$line" =~ "fn ".*"send_body_on_stream" ]]; then
        in_fn=1; state=0; continue
    fi
    [[ "$in_fn" -eq 0 ]] && continue
    # A new top-level fn ends the function.
    if [[ "$line" =~ ^"fn " ]]; then
        in_fn=0; state=0; continue
    fi

    # A return statement closes the control-flow path; reset so we don't
    # span separate branches (e.g. early-return RST path vs DATA path).
    if [[ "$line" =~ ^[[:space:]]*"return"([^_]|$) ]]; then
        state=0
    fi

    case $state in
    0)
        if [[ "$line" == *"c.fmu.unlock()"* ]]; then
            state=1; fmu_line=$lineno
        fi
        ;;
    1)
        if [[ "$line" == *"c.fmu.lock()"* ]]; then
            state=0   # fmu re-acquired; race window closed
        elif [[ "$line" == *"c.wmu.lock()"* ]]; then
            state=2; wmu_line=$lineno
        fi
        ;;
    2)
        if [[ "$line" == *"H2DataFrame{"* ]]; then
            found=1
            echo "RACE: c.fmu.unlock() at line ${fmu_line} precedes c.wmu.lock() (line ${wmu_line}) before H2DataFrame write"
            echo "  peer_max_frame can be updated + SETTINGS ACK sent in that window → oversized DATA frame."
            break
        fi
        if [[ "$line" == *"c.fmu.lock()"* ]]; then
            state=0   # fmu re-acquired anywhere → window closed
        fi
        ;;
    esac
done <<< "$content"

if [[ "$found" -eq 1 ]]; then
    exit 1
fi

echo "OK: fmu held across DATA write in send_body_on_stream"
exit 0
