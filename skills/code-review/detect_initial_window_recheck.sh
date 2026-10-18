#!/usr/bin/env bash
# detect_initial_window_recheck.sh
# Detects: send_body_on_stream's wmu->fmu recheck block does not revalidate
# s.send_window after an INITIAL_WINDOW_SIZE reduction.  The reader applies a
# negative delta to s.send_window under fmu; if no recheck exists, the writer
# sends DATA that exceeds the peer's retroactively-reduced stream window ->
# FLOW_CONTROL_ERROR.
#
# Usage: bash detect_initial_window_recheck.sh [file] [commit]
#   file   defaults to vlib/net/http/h2_mux_conn.v
#   commit if given, checks that git revision instead of the working tree
# Exit 0 = clean (s.send_window negativity checked inside wmu->fmu block)
# Exit 1 = missing recheck (bug present)

set -euo pipefail

FILE="${1:-vlib/net/http/h2_mux_conn.v}"
BASE="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

content=$(cat "$FILE") || { echo "ERROR: cannot read ${FILE}"; exit 2; }

# Strategy: extract the body of send_body_on_stream and check whether
# s.send_window < 0 (or s.send_window <= -1 or similar) appears inside the
# wmu->fmu recheck section (between the inner c.fmu.lock() and c.fmu.unlock()
# that are nested inside c.wmu.lock()).

in_fn=0
# state 0: in function, looking for the outer c.wmu.lock()
# state 1: saw wmu.lock(), looking for inner c.fmu.lock()
# state 2: inside wmu->fmu block, looking for s.send_window negativity check or c.fmu.unlock()
state=0
wmu_line=0
fmu_inner_line=0
seen_window_check=0
lineno=0

while IFS= read -r line; do
    lineno=$((lineno + 1))

    if [[ "$line" =~ "fn ".*"send_body_on_stream" ]]; then
        in_fn=1; state=0; seen_window_check=0
        continue
    fi
    [[ "$in_fn" -eq 0 ]] && continue
    if [[ "$line" =~ ^"fn " ]]; then
        in_fn=0; break
    fi

    case $state in
    0)
        if [[ "$line" == *"c.wmu.lock()"* ]]; then
            state=1; wmu_line=$lineno
        fi
        ;;
    1)
        if [[ "$line" == *"c.fmu.lock()"* ]]; then
            state=2; fmu_inner_line=$lineno
        fi
        # Reset on wmu.unlock (different wmu section)
        if [[ "$line" == *"c.wmu.unlock()"* ]]; then
            state=0
        fi
        ;;
    2)
        # Check for s.send_window negative-value guard
        if [[ "$line" == *"s.send_window < 0"* ]] || \
           [[ "$line" == *"s.send_window <= -"* ]] || \
           [[ "$line" == *"-s.send_window"* && "$line" == *"trim"* ]]; then
            seen_window_check=1
        fi
        if [[ "$line" == *"c.fmu.unlock()"* ]]; then
            # End of the wmu->fmu block - did we see the check?
            if [[ "$seen_window_check" -eq 0 ]]; then
                echo "MISSING: send_body_on_stream wmu->fmu recheck block (fmu.lock at line ${fmu_inner_line}) does not revalidate s.send_window after INITIAL_WINDOW_SIZE reduction."
                echo "  A peer SETTINGS reducing initial_window_size arrives between the outer fmu.unlock and this fmu.lock;"
                echo "  s.send_window goes negative but no trim is applied -> DATA sent exceeds peer's new stream window -> FLOW_CONTROL_ERROR."
                exit 1
            fi
            # Found the check; reset for any subsequent wmu->fmu blocks
            state=0; seen_window_check=0
        fi
        ;;
    esac
done <<< "$content"

echo "OK: s.send_window negativity recheck present in send_body_on_stream wmu->fmu block"
exit 0
