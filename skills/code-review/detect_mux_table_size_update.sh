#!/usr/bin/env bash
# Detect: H2MuxConn.apply_peer_settings missing encoder pending_max_table_size update
#
# When a peer sends SETTINGS_HEADER_TABLE_SIZE, the encoder MUST emit a
# Dynamic Table Size Update at the start of the next HEADERS block (RFC 7541
# §6.3). H2Conn.apply_settings correctly sets encoder.pending_max_table_size;
# H2MuxConn.apply_peer_settings must do the same.
#
# Exit 1 (bug) when h2_mux_conn.v's apply_peer_settings function body does NOT
# contain a reference to encoder.pending_max_table_size.
# Exit 0 (clean) when the update is present.

FILE="${1:-vlib/net/http/h2_mux_conn.v}"

if [ ! -f "$FILE" ]; then
    echo "File not found: $FILE" >&2
    exit 2
fi

# Find the apply_peer_settings function
fn_start=$(grep -n "fn.*apply_peer_settings" "$FILE" | head -1 | cut -d: -f1)
if [ -z "$fn_start" ]; then
    echo "SKIP: apply_peer_settings not found in $FILE" >&2
    exit 0
fi

# Extract from fn_start to the closing `}` of the function (next `^}` line)
fn_body=$(tail -n +"$fn_start" "$FILE" | awk '/^}$/{found=1} {print} found{exit}')

if echo "$fn_body" | grep -q "pending_max_table_size"; then
    echo "OK: apply_peer_settings sets encoder.pending_max_table_size" >&2
    exit 0
fi

echo "BUG: apply_peer_settings in $FILE does not set encoder.pending_max_table_size — RFC 7541 §6.3 requires a Dynamic Table Size Update at the start of the next HEADERS block when peer lowers SETTINGS_HEADER_TABLE_SIZE; H2Conn.apply_settings handles this correctly but the mux path is missing the same update" >&2
exit 1
