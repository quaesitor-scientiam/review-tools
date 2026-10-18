#!/usr/bin/env bash
# detect_tls_read_precheck_poll.sh — flag a TLS-transport adapter's read()
# implementation that runs an outer raw-socket wait_for_read() BEFORE calling
# the wrapped SSLConn's own read().
#
# Bug class (Codex P1, vlang/v#27643 pullrequestreview-4626225521):
# a TLS library can already hold decrypted-but-unconsumed application data
# internally (mbedtls_ssl_read()/SSL_read() return at most the caller's buffer
# size per call; any remainder from an already-received/decrypted TLS record
# stays buffered for the NEXT call, with no new bytes needed from the socket).
# An outer select()-style readiness poll cannot see that buffered data — it
# only knows about the socket's OWN pending bytes. If read() calls that outer
# poll first and propagates its timeout, a poll that (correctly, from the
# socket's point of view) reports "nothing new" can mask data the wrapped
# read() would have returned immediately. H2MuxConn.read_loop treats a read()
# timeout as a benign wake-up and just retries — so the buffered bytes are
# never drained until unrelated new socket data arrives (or never, if the peer
# sends nothing further), hanging the request.
#
# Fix shape: remove the outer poll and let the wrapped read() drive its own
# internal WANT_READ retry loop (already bounded by its configured
# read_timeout) — it tries the non-blocking-in-effect immediate decode first,
# so buffered data returns without any socket wait at all.
#
# This is a mechanical, statically-visible check: the defect is the PRESENCE
# of an unconditional pre-read poll, independent of timing/load, so a runtime
# reproduction would need to race real record boundaries and (given the
# pooled h2 path does not yet enforce req.read_timeout — a separate documented
# follow-up) risks an unbounded hang on buggy code. A static gate is the safe,
# deterministic reproduction vehicle here, matching this repo's precedent for
# other timing-shaped bugs (detect_fmu_scope.sh, detect_missing_fcv_broadcast.sh).
#
# Usage: detect_tls_read_precheck_poll.sh <file> [git-commit]
# Exit: 1 if the wrapped conn.read() call is preceded by an outer
#       wait_for_read() in the same read() function (bug present); 0 if not
#       present, or the file doesn't wrap an ssl.SSLConn (not applicable);
#       2 on a read error.
set -uo pipefail
file="${1:?usage: detect_tls_read_precheck_poll.sh <file> [commit]}"
commit="${2:-}"

if [ -n "$commit" ]; then
    src="$(git show "${commit}:${file}" 2>/dev/null)"
else
    src="$(cat "$file" 2>/dev/null)"
fi
if [ -z "$src" ]; then
    echo "detect_tls_read_precheck_poll: cannot read $file${commit:+ @ $commit}" >&2
    exit 2
fi

label="$file${commit:+ @ $commit}"
echo "=== tls-read-precheck-poll detector: $label ==="

if ! printf '%s\n' "$src" | grep -q 'ssl\.SSLConn'; then
    echo "SKIP: $file does not wrap an ssl.SSLConn"
    exit 0
fi

out="$(printf '%s\n' "$src" | awk '
    /^fn \(mut [a-zA-Z_]+ [A-Za-z0-9_]+\) read\(mut [a-zA-Z_]+ \[\]u8\) !int \{/ {
        infn=1; fname=$0; sub(/[ \t]*\{.*/, "", fname)
        wait_line=0; read_line=0
        next
    }
    infn && /^\}$/ {
        if (wait_line > 0 && (read_line == 0 || wait_line < read_line)) {
            print "  " fname " (outer poll at line " wait_line ")"
        }
        infn=0
        next
    }
    infn && wait_line == 0 && /\.wait_for_read\(/ { wait_line = NR }
    infn && read_line == 0 && /\.conn\.read\(/ { read_line = NR }
')"

if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "RESULT: outer wait_for_read() runs before the wrapped conn.read() call — remove it and let the wrapped read()'s own internal WANT_READ retry (bounded by its read_timeout) drive the wait instead."
    exit 1
fi
echo "RESULT: no pre-read outer poll found before the wrapped conn.read() call."
exit 0
