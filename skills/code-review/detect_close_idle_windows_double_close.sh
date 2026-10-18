#!/usr/bin/env bash
# Detect: close_idle missing net.close on Windows — workers won't be woken promptly
#
# On Windows, net.shutdown(SD_BOTH) alone does NOT unblock a concurrent select()
# waiting on the fd in another thread. Only closesocket() (net.close) does.
# The wait_for_read path in mbedtls ssl_connection.c.v uses C.select() with 1ms
# slices (line 944); without closesocket(), workers sleep up to 41 s (the
# mbedtls_server_read_timeout_ms deadline) before noticing shutdown.
#
# The double-close from the worker's deferred conn.shutdown() is safe: in
# listen_and_serve_tls, ch.close() is called before close_idle(), so the accept
# loop has already stopped; no new connection can claim the recycled handle
# before conn.shutdown() runs (WSAENOTSOCK from the second closesocket is
# swallowed by or {}).
#
# Exit 1 (bug) when server_tls_idle.v close_idle loop lacks the
#   $if windows { net.close(handle) or {} } block.
# Exit 0 (clean) when that block is present.

FILE="${1:-vlib/net/http/server_tls_idle.v}"

if [ ! -f "$FILE" ]; then
    echo "File not found: $FILE" >&2
    exit 2
fi

# Find the close_idle function body
fn_start=$(grep -n "fn.*close_idle" "$FILE" | head -1 | cut -d: -f1)
if [ -z "$fn_start" ]; then
    echo "SKIP: close_idle not found in $FILE" >&2
    exit 0
fi

# Find the for-loop line inside close_idle
loop_line=$(tail -n +"$fn_start" "$FILE" | grep -n "for handle in handles" | head -1 | cut -d: -f1)
if [ -z "$loop_line" ]; then
    echo "SKIP: for loop not found in close_idle" >&2
    exit 0
fi

# Absolute line of loop start
loop_abs=$((fn_start + loop_line - 1))

# Extract from the loop line to end of function (next top-level `}`)
body=$(tail -n +"$loop_abs" "$FILE" | head -20)

if echo "$body" | grep -q "net\.close\b"; then
    echo "OK: net.close present in close_idle loop — Windows wakeup intact" >&2
    exit 0
fi

echo "BUG: close_idle is missing net.close inside its Windows shutdown loop ($FILE line ~$loop_abs) — workers blocked in select() will not be woken on Windows; they will hang until the 41s mbedtls_server_read_timeout_ms expires" >&2
exit 1
