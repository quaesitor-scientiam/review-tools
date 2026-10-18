#!/usr/bin/env bash
# Detects: send_window += excess in send_body_on_stream without fcv.broadcast()
# before fmu.unlock() — excess credit returned to connection window won't wake
# threads sleeping in fcv.wait() (blocked because send_window was drained).
#
# Usage: bash detect_missing_fcv_broadcast.sh [file] [commit]
#   commit: git object (hash/branch) to read file from; defaults to working tree
#
# Exit 0 = OK (broadcast present or pattern not found)
# Exit 1 = RACE (excess returned without broadcast)

set -euo pipefail

file="${1:-vlib/net/http/h2_mux_conn.v}"
commit="${2:-}"

if [[ -n "$commit" ]]; then
    content=$(git show "${commit}:${file}")
else
    content=$(cat "$file")
fi

# State machine:
#   0 = looking for send_body_on_stream fn header
#   1 = inside function, looking for 'c.send_window += excess'
#   2 = saw credit-return; looking for fcv.broadcast() or fmu.unlock()
state=0
lineno=0
credit_line=0

while IFS= read -r line; do
    lineno=$((lineno + 1))

    case $state in
    0)
        if [[ "$line" =~ "send_body_on_stream" && "$line" =~ "fn " ]]; then
            state=1
        fi
        ;;
    1)
        # Function end resets search
        if [[ "$line" =~ ^"}" ]]; then
            state=0
        elif [[ "$line" =~ "send_window +=" && "$line" =~ "excess" ]]; then
            state=2
            credit_line=$lineno
        fi
        ;;
    2)
        if [[ "$line" =~ "fcv.broadcast()" ]]; then
            # Broadcast found — OK for this occurrence; keep scanning function
            state=1
        elif [[ "$line" =~ "fmu.unlock()" ]]; then
            echo "RACE at line $lineno: send_window credited at line $credit_line but no fcv.broadcast() before fmu.unlock()"
            exit 1
        elif [[ "$line" =~ ^"}" ]]; then
            state=0
        fi
        ;;
    esac
done <<< "$content"

echo "OK: fcv.broadcast() present after every excess credit return"
exit 0
