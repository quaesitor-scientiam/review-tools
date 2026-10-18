#!/usr/bin/env bash
# Unbounded-accumulation detector (a review angle, see SKILL.md "Phase R").
#
# A peer can drive growth of any connection-level buffer/counter/map that the
# reader appends to, increments, or inserts into per incoming frame. Each such
# accumulator MUST have a bound -- either a size cap (precedent:
# h2_max_recv_header_block bounds the CONTINUATION buffer) or active pruning
# (a `.delete(` call for that same field elsewhere in the file -- precedent:
# h3_conn.v's request_streams/request_decoders/dead_request_streams, none of
# which carry a numeric cap) -- or a malicious/buggy peer exhausts memory or
# sets up a burst.
#
# This is an ENUMERATE-AND-VERIFY aid, not a clean pass/fail gate: it lists
# every `<recv>.<field> <<`, `++`, `+=`, or `<recv>.<field>[...] =` (map-key
# assignment) for EVERY `mut` receiver name this file declares -- NOT
# hardcoded to `c` (an H2Conn-only convention: H3Conn's receiver is `h`, and
# a bare map-key assignment previously matched no growth pattern at all on
# ANY receiver, together silently exempting the whole file -- confirmed miss,
# see code-review-misses.md's dead_request_streams row, caught by an external
# PR #28129 review after this detector false-clean-passed h3_conn.v) -- and
# marks whether the file bounds that field with a max-style cap OR a
# `.delete(` call for it. Fields bounded by other means (an admission limit,
# flow-control protocol) show REVIEW -- confirm those by hand. A field that
# is peer-driven, not drained in-handler, and shows NO bound is the bug.
#
# Known gap: a map-VALUE increment (`m[k] += 1`, `m[k]++`) matches neither
# the array/counter patterns (which require the operator directly after the
# field name, not after a `[...]`) nor the map-key-assignment pattern (which
# requires a bare `=`). Rare in this codebase so far; add a third pattern if
# one shows up.
#
# Usage: detect_unbounded_accum.sh <file> [gitrev]
# Exit: 1 if any accumulator has no cap/prune (i.e. needs a human decision).

set -u
file="${1:?usage: detect_unbounded_accum.sh <file> [gitrev]}"
rev="${2:-}"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
if [ -n "$rev" ]; then git show "${rev}:${file}" > "$tmp" || exit 2; label="$file @ $rev"
else cp "$file" "$tmp"; label="$file (working tree)"; fi

echo "=== unbounded-accumulation detector: $label ==="
need=0

# Every distinct `mut <name> <Type>` receiver this file declares -- not
# hardcoded, so a file with an H3Conn-style `h` receiver (or any other name)
# is scanned exactly like an H2Conn-style `c` receiver.
recvs="$(grep -oE 'fn \(mut [a-zA-Z_][a-zA-Z0-9_]* ' "$tmp" \
  | sed -E 's/^fn \(mut ([a-zA-Z_][a-zA-Z0-9_]*) .*/\1/' | sort -u)"
if [ -z "$recvs" ]; then
  echo "RESULT: no mut-receiver methods found -- nothing to scan."; exit 0
fi
recv_alt="$(echo "$recvs" | paste -sd'|' -)"

# field names appended/incremented/map-inserted on any of this file's own
# mut receivers: `<<`/`++`/`+=` (array/counter growth, original pattern) AND
# `[...] =` (map-key-assignment growth -- the pattern dead_request_streams'
# `h.dead_request_streams[stream_id] = true` needed and the original script
# had no equivalent for at all).
fields="$( { \
  grep -oE "(${recv_alt})\.[a-z_]+ ?(<<|\+\+|\+=)" "$tmp" \
    | sed -E "s/^(${recv_alt})\.([a-z_]+).*/\2/"; \
  grep -oE "(${recv_alt})\.[a-z_]+\[[^]]*\] ?=[^=]" "$tmp" \
    | sed -E "s/^(${recv_alt})\.([a-z_]+)\[.*/\2/"; \
} | sort -u)"

for f in $fields; do
  # bounded if the field name co-occurs (same line, matching the original
  # convention) with a max-style cap constant, OR a `.delete(` call for it
  # appears anywhere in the file (active pruning).
  if grep -qE "${f}\b.*\b[a-z0-9_]*max[a-z0-9_]*\b|\b[a-z0-9_]*max[a-z0-9_]*\b.*${f}\b" "$tmp"; then
    echo "  $f: CAPPED (max-style bound co-occurs)"
  elif grep -qE "\.${f}\.delete\(" "$tmp"; then
    echo "  $f: CAPPED (pruned via .delete() elsewhere in file)"
  else
    echo "  $f: NO CAP FOUND — verify it is bounded by an admission limit / protocol, else it is peer-unbounded"
    need=1
  fi
done
[ "$need" -eq 1 ] && { echo "RESULT: review the NO-CAP accumulators above."; exit 1; }
echo "RESULT: every accumulator co-occurs with a max-style cap or a .delete() prune."; exit 0
