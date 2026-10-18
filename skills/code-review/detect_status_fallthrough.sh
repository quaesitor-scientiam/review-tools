#!/usr/bin/env bash
# Detects: in H2Conn.read_response, the :status guard (all_digits check) can
# fail silently and got_headers is still set to true — caller receives status 0
# with no error when the server sends a malformed :status value.
#
# Usage: bash detect_status_fallthrough.sh [file] [commit]
#   commit: git object (hash/branch) to read file from; defaults to working tree
#
# Exit 0 = OK (invalid :status produces an error or got_headers is guarded)
# Exit 1 = FALLTHROUGH or guard missing

set -euo pipefail

file="${1:-vlib/net/http/h2_conn.v}"
commit="${2:-}"

if [[ -n "$commit" ]]; then
    content=$(git show "${commit}:${file}")
else
    content=$(cat "$file")
fi

# State machine:
#   0 = looking for read_response fn header
#   1 = inside read_response, scanning for :status handler and got_headers
#   2 = inside :status if-block, tracking brace depth, looking for return error
#
# Per-function bookkeeping (reset at each function-end `}`):
#   found_guard        = 1 if :status handler seen in this fn
#   found_error        = 1 if return error seen inside the :status guard
#
# Global outcome (never reset):
#   fn_found = 1 when read_response is entered
#   fn_ok    = 1 when read_response exits with guard + error both present

state=0
lineno=0
found_guard=0
found_error=0
status_depth=0
fn_found=0
fn_ok=0

while IFS= read -r line; do
    lineno=$((lineno + 1))

    case $state in
    0)
        if [[ "$line" =~ "fn " && "$line" =~ "read_response" ]]; then
            state=1
            fn_found=1
            found_guard=0
            found_error=0
        fi
        ;;
    1)
        # Function end: commit outcome, then reset for next function
        if [[ "$line" =~ ^"}" && ! "$line" =~ [^}] ]]; then
            if [[ $found_guard -eq 1 && $found_error -eq 1 ]]; then
                fn_ok=1
            elif [[ $found_guard -eq 0 ]]; then
                echo "WARN: no :status guard found in read_response — lenient .int() parse still in use"
                exit 1
            fi
            # found_guard=1 but found_error=0 means got_headers check below
            # should already have caught it; fall through to end-of-file check.
            state=0
            found_guard=0
            found_error=0
        fi

        # :status check on same line as all_digits (compact form)
        if [[ "$line" =~ "':status'" && "$line" =~ "all_digits" ]]; then
            found_guard=1
            state=2
            status_depth=0
        # :status on its own line (standard form)
        elif [[ "$line" =~ "':status'" ]]; then
            found_guard=1
            state=2
            status_depth=0
        fi

        # got_headers = true reachable with guard present but no error path
        if [[ "$line" =~ "got_headers = true" ]]; then
            if [[ $found_guard -eq 1 && $found_error -eq 0 ]]; then
                echo "FALLTHROUGH at line $lineno: got_headers = true reachable when :status guard rejects value (no error returned)"
                exit 1
            fi
        fi
        ;;
    2)
        # Track brace depth to know when we've left the :status if-block
        opens=$(echo "$line" | tr -cd '{' | wc -c)
        closes=$(echo "$line" | tr -cd '}' | wc -c)
        status_depth=$((status_depth + opens - closes))

        if [[ "$line" =~ "return error" ]]; then
            found_error=1
        fi

        # Left the :status block
        if [[ $status_depth -lt 0 ]]; then
            state=1
            status_depth=0
        fi

        # got_headers = true still inside the :status block and no error seen yet
        if [[ "$line" =~ "got_headers = true" ]]; then
            if [[ $found_guard -eq 1 && $found_error -eq 0 ]]; then
                echo "FALLTHROUGH at line $lineno: got_headers = true inside :status block with no error guard"
                exit 1
            fi
        fi
        ;;
    esac
done <<< "$content"

if [[ $fn_found -eq 0 ]]; then
    echo "WARN: read_response not found in ${file}"
    exit 1
fi

if [[ $fn_ok -eq 0 ]]; then
    echo "WARN: read_response found but :status guard or error path incomplete"
    exit 1
fi

echo "OK: :status fallthrough guarded"
exit 0
