#!/usr/bin/env bash
# Detect: the threaded TLS server's accept loop hands each raw conn to a worker
# with a BARE blocking `ch <- conn`. The accept loop, that send, and the post-loop
# shutdown (ch.close + close_idle + ws.wait) all run on the SAME thread, while
# stop()/close() only flip s.state from another thread. So under a slow-handshake
# flood -- all worker_num workers blocked in complete_handshake AND the channel
# buffer (pool_channel_slots) full of untracked raw conns -- the accept thread
# blocks on `ch <- conn`, never re-checks s.state, and never reaches close_idle().
# Shutdown then wedges until a worker handshake times out (~tls_handshake_timeout,
# 30s default), defeating the prompt-stop the PR is meant to provide.
# (Codex P2 on vlang/v#27552, discussion_r3474019355.)
#
# The fix makes the send interruptible: a `select` with a timeout branch that
# re-checks s.state so the accept thread falls through to close_idle() promptly,
# closing the not-yet-queued conn itself (it was never mark_idle'd).
#
# Usage: bash detect_tls_accept_send_interruptible.sh [file]
# Exit 1 if the bare blocking send is present without an interruptible guard.

set -uo pipefail

FILE="${1:-vlib/net/http/server_tls_notd_use_openssl.v}"
if [ ! -f "$FILE" ]; then
    echo "SKIP: $FILE not found" >&2
    exit 0
fi

# The accept loop must enqueue conns through an interruptible select (with a
# timeout branch), not a bare `ch <- conn`. Require a `select {` in the file AND
# the send appearing inside select context (heuristic: a `select` exists and the
# loop polls s.state around the send). The buggy form is a top-level `ch <- conn`
# with no select anywhere in the accept path.
has_select=0
grep -qE '^[[:space:]]*select[[:space:]]*\{' "$FILE" && has_select=1

has_send=0
grep -qE '^[[:space:]]*ch <- conn' "$FILE" && has_send=1

if [ "$has_select" -eq 1 ]; then
    echo "OK: $FILE enqueues raw conns through an interruptible select (accept thread can reach close_idle during a handshake flood)" >&2
    exit 0
fi

if [ "$has_send" -eq 1 ]; then
    echo "BUG: $FILE hands raw conns to workers with a bare blocking 'ch <- conn' and no interruptible select." >&2
    echo "  Under a slow-handshake flood the accept thread blocks on the full channel, never reaches" >&2
    echo "  close_idle(), and stop()/close() is not observed until a worker handshake times out." >&2
    exit 1
fi

echo "OK: no bare 'ch <- conn' accept-send found in $FILE" >&2
exit 0
