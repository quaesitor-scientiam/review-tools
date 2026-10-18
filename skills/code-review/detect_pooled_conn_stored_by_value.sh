#!/usr/bin/env bash
# detect_pooled_conn_stored_by_value.sh — flags a struct field of an aliased
# C-interop TLS connection type (ssl.SSLConn / mbedtls.SSLConn /
# openssl.SSLConn) declared as a bare value instead of a pointer.
#
# SSLConn.dial()/.connect() wire mbedtls_ssl_set_bio (or OpenSSL's
# SSL_set_bio) to pointers into the struct's OWN address (e.g.
# &s.server_fd) — copying the struct by value afterward leaves the copy's
# internal TLS context pointing at the ORIGINAL dialed object's fields, not
# its own. Any struct meant to OWN a dialed connection (for reuse, pooling,
# or handing to a background reader) must store it by pointer, matching the
# established idiom (H1PooledConn.ssl in transport.v is already
# &ssl.SSLConn). Codex P1, vlang/v#27643 pullrequestreview-4631763931,
# discussion 3525390891.
#
# Usage: detect_pooled_conn_stored_by_value.sh <file> [commit]
# Exit: 0 clean, 1 flagged, 2 usage error

set -u
file="${1:?usage: detect_pooled_conn_stored_by_value.sh <file> [commit]}"
commit="${2:-}"

read_source() {
    if [ -n "$commit" ]; then
        git show "$commit:$file" 2>/dev/null
    else
        cat "$file" 2>/dev/null
    fi
}

src="$(read_source)"
if [ -z "$src" ]; then
    echo "detect_pooled_conn_stored_by_value: could not read $file${commit:+ at $commit}" >&2
    exit 2
fi

pattern='^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+(ssl\.SSLConn|mbedtls\.SSLConn|openssl\.SSLConn)[[:space:]]*$'
hits="$(printf '%s\n' "$src" | grep -nE "$pattern")"

if [ -n "$hits" ]; then
    echo "BUG: connection field stored by VALUE, not pointer (self-referential TLS context will point at the wrong object after a copy):"
    printf '%s\n' "$hits" | sed "s|^|  $file:|"
    exit 1
fi

echo "OK: no by-value SSLConn/mbedtls.SSLConn/openssl.SSLConn struct fields found in $file"
exit 0
