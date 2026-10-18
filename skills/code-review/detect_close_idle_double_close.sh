#!/usr/bin/env bash
# Detect: close_idle force-closes an idle handle on Windows (net.close, to wake
# a worker blocked in select(), which net.shutdown does not do there), but the
# woken worker's handle_conn defer closes the SAME fd again (conn.shutdown)
# with no ownership coordination.
#
# That is a double-close: between close_idle's net.close and the worker's
# conn.shutdown, the SOCKET value can be reused by ANY socket the process opens
# (handle reuse is process-wide on Windows, not limited to this server's accept
# loop), so the worker's second close can hit an unrelated socket.
#
# The fix is an ownership transfer: close_idle records the handles it
# force-closed, and the worker consults that (e.g. was_force_closed) and skips
# its own close. This detector flags the absence of that mechanism.
#
# Usage: bash detect_close_idle_double_close.sh
#
# Exit 1 when close_idle force-closes on Windows (net.close) but no ownership
# guard (was_force_closed or equivalent) gates the worker's conn.shutdown.
# Exit 0 when the guard is present, or close_idle does not force-close.

set -uo pipefail

IDLE="vlib/net/http/server_tls_idle.v"
WORKER="vlib/net/http/server_tls_notd_use_openssl.v"

if [ ! -f "$IDLE" ] || [ ! -f "$WORKER" ]; then
    echo "SKIP: expected TLS server files not found" >&2
    exit 0
fi

# Extract the close_idle function body.
close_idle_body=$(awk '
    /fn .*close_idle\(/ { in_fn=1; depth=0 }
    in_fn {
        print
        for (i=1; i<=length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") depth++
            else if (c == "}") { depth--; if (depth == 0) { in_fn=0; break } }
        }
    }
' "$IDLE")

if [ -z "$close_idle_body" ]; then
    echo "SKIP: no close_idle function in $IDLE" >&2
    exit 0
fi

# Does close_idle force-close the fd on Windows (net.close / closesocket)?
if ! printf '%s\n' "$close_idle_body" | grep -qE 'net\.close\('; then
    echo "OK: close_idle does not force-close (net.close); no double-close hazard" >&2
    exit 0
fi

# close_idle force-closes, so the worker must do an ownership *transfer*, not a
# cleanup *skip*. conn.shutdown() does two jobs: (1) free the mbedtls TLS objects
# (SSL ctx, config, certs, RNG, ALPN alloc) and (2) close the socket fd. The
# correct fix relinquishes socket ownership (owns_socket = false) on the
# force-closed path and STILL calls conn.shutdown() — so the fd is closed once
# (by close_idle) and the TLS resources are always freed.
#
# Two ways to get this wrong, both flagged here:
#   - double-close: worker calls conn.shutdown() unconditionally with no
#     ownership relinquish (the original bug).
#   - TLS leak: worker skips conn.shutdown() entirely on force-close (e.g.
#     `if !was_force_closed { conn.shutdown() }`), freeing nothing.
# Both are caught by requiring the relinquish marker `owns_socket = false` in
# the worker AND requiring conn.shutdown() to be reachable unconditionally.

# Must relinquish socket ownership rather than skip cleanup.
if ! grep -qE 'owns_socket[[:space:]]*=[[:space:]]*false' "$WORKER"; then
    echo "BUG: close_idle force-closes (net.close) but $WORKER never relinquishes socket ownership (owns_socket = false) — either a double-close (unconditional conn.shutdown) or a TLS-resource leak (conn.shutdown skipped on force-close)" >&2
    exit 1
fi

# conn.shutdown() must still run for TLS cleanup — it must not be gated away on
# the force-closed path. Flag the leak pattern: conn.shutdown() reachable only
# when NOT force-closed.
if grep -qE 'if[[:space:]]*!.*was_force_closed.*\{' "$WORKER" \
    && grep -A2 -E 'if[[:space:]]*!.*was_force_closed' "$WORKER" | grep -qE 'conn\.shutdown\(\)'; then
    echo "BUG: $WORKER gates conn.shutdown() behind !was_force_closed — TLS resources (mbedtls SSL/config/certs/RNG/ALPN) leak for every force-closed idle connection" >&2
    exit 1
fi

echo "OK: worker relinquishes socket ownership (owns_socket = false) on force-close and still calls conn.shutdown() for TLS cleanup" >&2
exit 0
