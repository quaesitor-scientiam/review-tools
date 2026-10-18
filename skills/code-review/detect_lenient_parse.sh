#!/usr/bin/env bash
# Lenient-parse detector (a mechanical review angle, see SKILL.md "Phase R").
#
# V's string.int()/.u64()/... stop at the first non-digit and return the leading
# number ('200 OK' -> 200, '12junk' -> 12), so a successful parse is NOT input
# validation. Every parse of a wire-derived value MUST have a local digit/charset
# guard (all_digits / .len == / is_digit) within a few lines.
#
# Usage:
#   detect_lenient_parse.sh <file>            # scan the working-tree file
#   detect_lenient_parse.sh <file> <gitrev>   # scan that file at a git revision
#
# Exit status: 1 if any UNGUARDED parse is found (so it can gate a commit), else 0.
# Reproduction use: point it at the commit Codex reviewed; an UNGUARDED hit at the
# offending line reproduces the finding the local review should have caught.

set -u
file="${1:?usage: detect_lenient_parse.sh <file> [gitrev]}"
base="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cp "$file" "$tmp" || { echo "cannot read $file"; exit 2; }
label="$file"

echo "=== lenient-parse detector: $label ==="
found=0
while IFS=: read -r ln rest; do
  [ -z "$ln" ] && continue
  lo=$((ln-3)); [ "$lo" -lt 1 ] && lo=1; hi=$((ln+3))
  window="$(sed -n "${lo},${hi}p" "$tmp")"
  if echo "$window" | grep -qE 'all_digits|is_digit|\.len ==|len == [0-9]'; then
    echo "  line $ln: GUARDED   -> $(echo "$rest" | sed 's/^[[:space:]]*//')"
  else
    echo "  line $ln: UNGUARDED -> $(echo "$rest" | sed 's/^[[:space:]]*//')"
    found=1
  fi
done < <(grep -nE '\.(int|u64|i64|i32|u32|f32|f64)\(\)' "$tmp" | grep -v '//')

if [ "$found" -eq 1 ]; then
  echo "RESULT: UNGUARDED lenient parse(s) found — add a local digit/charset guard."
  exit 1
fi
echo "RESULT: all wire-value parses are locally guarded."
exit 0
