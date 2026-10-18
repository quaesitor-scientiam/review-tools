#!/usr/bin/env bash
# .bytes()-plus-manual-NUL detector (a mechanical review angle, see SKILL.md "Phase R").
#
# mbedtls_x509_crt_parse/mbedtls_pk_parse_key's PEM path needs a REAL
# NUL-terminated buffer (it scans for "-----BEGIN CERTIFICATE-----" and
# buf[buflen-1]=='\0'). A V string's own `.str` field is always NUL-terminated
# internally for C interop, but `.bytes()` allocates a FRESH []u8 of exactly
# `.len` bytes with NO trailing NUL -- so `<string>.bytes()` combined with a
# manually added `+ 1` on the length passed to a parse call reads one byte past
# the heap allocation (confirmed via ASan: heap-buffer-overflow in
# mbedtls_x509_crt_parse, byte-for-byte matching the .bytes() allocation size).
# The correct, established pattern (vlib/net/mbedtls/ssl_connection.c.v) is to
# pass `<string>.str` directly, never `<string>.bytes()`, when the length
# includes a `+ 1`.
#
# Usage:
#   detect_bytes_nul_terminator_mismatch.sh <file>            # working-tree file
#   detect_bytes_nul_terminator_mismatch.sh <file> <gitrev>   # file at a git revision
#
# Exit status: 1 if any `<var> := <expr>.bytes()` is followed within 5 lines by
# `<var>.len + 1` or `<var>.len+1`, else 0.

set -u
file="${1:?usage: detect_bytes_nul_terminator_mismatch.sh <file> [gitrev]}"
base="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cp "$file" "$tmp" || { echo "cannot read $file"; exit 2; }
label="$file"

echo "=== .bytes()+NUL-terminator-mismatch detector: $label ==="
found=0
total_lines=$(wc -l < "$tmp")
while IFS=: read -r ln rest; do
  [ -z "$ln" ] && continue
  var="$(echo "$rest" | sed -nE 's/^[[:space:]]*(mut[[:space:]]+)?([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:=.*\.bytes\(\).*/\2/p')"
  if [ -z "$var" ]; then
    continue
  fi
  hi=$((ln+5)); [ "$hi" -gt "$total_lines" ] && hi=$total_lines
  window="$(sed -n "${ln},${hi}p" "$tmp")"
  if echo "$window" | grep -qE "\\b${var}(_len)?\\.len[[:space:]]*\\+[[:space:]]*1\\b|\\b${var}_len[[:space:]]*:=[[:space:]]*${var}\\.len[[:space:]]*\\+[[:space:]]*1\\b"; then
    echo "  line $ln: MISMATCH  -> '$var := ...bytes()' followed by a manual +1 length (no real NUL byte exists)"
    found=1
  else
    echo "  line $ln: OK        -> '$var := ...bytes()', no manual +1 length nearby"
  fi
done < <(grep -nE '\.bytes\(\)' "$tmp" | grep -v '//')

if [ "$found" -eq 1 ]; then
  echo "RESULT: .bytes()-derived buffer used with a manual +1 length -- heap-buffer-overflow (use .str instead)."
  exit 1
fi
echo "RESULT: no .bytes()+manual-NUL-terminator mismatch found."
exit 0
