#!/usr/bin/env bash
# detect_pooled_write_duration_reuse.sh — flag a TLS-transport adapter's
# write() implementation that calls the wrapped SSLConn's write()/write_ptr
# without first widening its shared `duration`/read-timeout field to the
# write-side stall budget.
#
# Bug class (Codex P2, vlang/v#27643 pullrequestreview-4628439062,
# discussion 3522170277): both mbedTLS's and OpenSSL's write_ptr
# (vlib/net/mbedtls/ssl_connection.c.v, vlib/net/openssl/ssl_connection.c.v)
# reuse the SAME `duration` field that set_read_timeout() configures for
# their own internal WANT_READ/WANT_WRITE retry loop during the write call —
# it is not read-specific at the backend level. A pooled adapter that sets a
# short duration for bounding how long read() may hold a shared lock (so an
# idle reader cannot starve a writer) but never widens it back before calling
# the wrapped write() gets that same short budget on the WRITE side too: a
# healthy peer that is merely slow to drain (backpressure, not a dead
# connection) has its write fail after the short read-poll interval instead
# of the intended, much longer write-stall budget, killing an otherwise-fine
# connection.
#
# Fix shape: call set_read_timeout(<write stall budget>) immediately before
# the wrapped conn.write()/write_ptr() call, and restore the original
# short duration immediately after, on every exit path (success and error).
#
# This is a mechanical, statically-visible check: the defect is the ABSENCE
# of a widen-before/restore-after pair around the wrapped write call,
# independent of timing/load. A real runtime reproduction requires forcing
# the wrapped conn's underlying socket into a non-blocking WANT_WRITE state
# (client sockets in this codebase are otherwise always left blocking, on
# which mbedtls_net_send can never return WANT_WRITE at all — see
# thirdparty/mbedtls/library/net_sockets.c's net_would_block(), which is
# hard-coded to return 0 on a blocking POSIX socket), so a static gate
# complements (does not replace) the runtime regression test in
# transport_h2_test.v that exercises the effect end to end.
#
# Usage: detect_pooled_write_duration_reuse.sh <file> [git-commit]
# Exit: 1 if a write() function wrapping an ssl.SSLConn calls the wrapped
#       conn.write() without a preceding set_read_timeout() call in the same
#       function (bug present); 0 if not present, or the file doesn't wrap an
#       ssl.SSLConn (not applicable); 2 on a read error.
set -uo pipefail
file="${1:?usage: detect_pooled_write_duration_reuse.sh <file> [commit]}"
base="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

src="$(cat "$file" 2>/dev/null)"
if [ -z "$src" ]; then
    echo "detect_pooled_write_duration_reuse: cannot read $file" >&2
    exit 2
fi

label="$file"
echo "=== pooled-write-duration-reuse detector: $label ==="

if ! printf '%s\n' "$src" | grep -q 'ssl\.SSLConn'; then
    echo "SKIP: $file does not wrap an ssl.SSLConn"
    exit 0
fi

out="$(printf '%s\n' "$src" | awk '
    /^fn \(mut [a-zA-Z_]+ [A-Za-z0-9_]+\) write\(/ {
        infn=1; fname=$0; sub(/[ \t]*\{.*/, "", fname)
        # The header line contains the opening brace of this function, but the
        # "next" below skips counting it on this iteration -- seed depth at 1
        # so it is accounted for.
        depth=1; set_timeout_line=0; write_line=0
        next
    }
    infn {
        depth += gsub(/\{/, "{")
        depth -= gsub(/\}/, "}")
        if (set_timeout_line == 0 && /\.set_read_timeout\(/) { set_timeout_line = NR }
        if (write_line == 0 && /\.conn\.write(_ptr)?\(/) { write_line = NR }
        if (depth <= 0) {
            if (write_line > 0 && (set_timeout_line == 0 || set_timeout_line > write_line)) {
                print "  " fname " (wrapped write at line " write_line ", no preceding set_read_timeout)"
            }
            infn = 0
        }
    }
')"

if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "RESULT: write() calls the wrapped conn's write() without first widening its shared duration/read-timeout field to the write-side stall budget — a healthy-but-slow peer will fail at the (much shorter) read-side interval instead."
    exit 1
fi
echo "RESULT: no write() function found that skips widening the wrapped conn's duration before writing."
exit 0
