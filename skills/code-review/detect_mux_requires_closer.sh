#!/usr/bin/env bash
# Detect: new_h2_mux_conn accepts a nil close_transport, leaking the reader.
#
# H2MuxConn's reader thread (spawned in new_h2_mux_conn) blocks in
# transport.read(). The H2Transport interface is read/write ONLY (no close), so
# the close_transport callback is the SOLE mechanism that can interrupt that
# blocking read at teardown. teardown_transport guards the call with
# `c.close_transport != unsafe { nil }`, so a nil closer makes teardown a no-op:
# drop_ref / shutdown_when_idle then leak the reader thread and the underlying
# connection forever (the reader never sees a read error on a silent transport).
# drop_ref's own comment warns of exactly this leak. (Codex P2 on vlang/v#27413,
# discussion_r3475761576.)
#
# Fix: require a non-nil close_transport in new_h2_mux_conn (panic on nil) so the
# teardown -> closer -> reader-exit chain is always available. The interface
# cannot gain a close() method without breaking "SSLConn satisfies H2Transport
# directly" (SSLConn has shutdown(), not close()), so the closer is the contract.
#
# Usage: bash detect_mux_requires_closer.sh [file]
# Exit 1 if new_h2_mux_conn does not reject a nil close_transport.

set -uo pipefail

FILE="${1:-vlib/net/http/h2_mux_conn.v}"
if [ ! -f "$FILE" ]; then
    echo "SKIP: $FILE not found" >&2
    exit 0
fi

# Extract the new_h2_mux_conn function body: from its signature to the spawn of
# the reader (the reader must not be started before the nil-closer guard runs).
body=$(awk '
    /pub fn new_h2_mux_conn\(/ { capture=1 }
    capture { print }
    capture && /spawn c\.read_loop\(\)/ { exit }
' "$FILE")

if [ -z "$body" ]; then
    echo "SKIP: could not locate new_h2_mux_conn in $FILE" >&2
    exit 0
fi

# The body must reject a nil closer before spawning the un-wakeable reader.
if echo "$body" | grep -qE 'close_transport[[:space:]]*==[[:space:]]*unsafe[[:space:]]*\{[[:space:]]*nil[[:space:]]*\}'; then
    echo "OK: $FILE rejects a nil close_transport (reader is always wakeable at teardown)" >&2
    exit 0
fi

echo "BUG: $FILE new_h2_mux_conn accepts a nil close_transport." >&2
echo "  The reader thread blocks in transport.read() and the H2Transport interface has no" >&2
echo "  close(); teardown_transport no-ops when close_transport is nil, so an idle retirement" >&2
echo "  or last-reference release leaks the reader thread and the connection. Require a non-nil" >&2
echo "  closer (panic on nil) before spawning the reader." >&2
exit 1
