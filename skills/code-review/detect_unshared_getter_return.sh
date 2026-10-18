#!/usr/bin/env bash
# Unshared-getter-return detector (a mechanical review angle, see SKILL.md
# "Phase R" and the V-specific gotchas in Angle A).
#
# V's plain array/map assignment shares backing storage rather than copying
# it -- `mut x := receiver.getter(); x[0] = y` mutates the SAME backing
# buffer the receiver's own internal field points to, unless the getter
# explicitly returns `field.clone()`. A getter whose doc comment promises a
# "snapshot", "copy", or otherwise implies independence, but whose body is a
# single bare `return r.field`, is exactly the shape that slips through
# review: it reads as obviously correct ("it's just returning the field")
# right up until a caller mutates what it thinks is an independent value.
#
# Missed on vlang/v#27880 (Codex round 4): CryptoStreamReassembler.data()
# returned r.received directly; a caller doing `mut d := r.data(); d[0] = x`
# corrupted the reassembler's own CRYPTO transcript. The same module family
# (tls13_handshake.v) has two more untouched instances
# (application_secrets()/handshake_secrets(), each returning a struct with
# []u8 fields) found by pointing this detector at the whole directory.
#
# This is an ENUMERATE-AND-VERIFY aid, not a zero-false-positive gate: it
# flags every public parameterless getter whose body is a bare single-field
# return and whose return type isn't a primitive value type or `string` (V
# strings are immutable, so returning one directly is always safe). A struct
# return type is flagged even though the detector can't see whether that
# struct contains array/map fields -- confirm each candidate by hand.
#
# Usage:
#   detect_unshared_getter_return.sh <file>            # scan the working-tree file
#   detect_unshared_getter_return.sh <file> <gitrev>   # scan that file at a git revision
#
# Exit status: 1 if any candidate is found (so it can gate a commit), else 0.
# Reproduction use: point it at the commit Codex reviewed; a candidate at the
# offending line reproduces the finding the local review should have caught.

set -u
file="${1:?usage: detect_unshared_getter_return.sh <file> [gitrev]}"
rev="${2:-}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [ -n "$rev" ]; then
  git show "${rev}:${file}" > "$tmp" || { echo "cannot read $file @ $rev"; exit 2; }
  label="$file @ $rev"
else
  cp "$file" "$tmp"
  label="$file (working tree)"
fi

echo "=== unshared-getter-return detector: $label ==="
found=0
total_lines=$(wc -l < "$tmp")

# Find every line that looks like a parameterless public getter signature.
sig_lines="$(grep -n '^pub fn ([A-Za-z0-9_]* &[A-Za-z0-9_]*) [A-Za-z0-9_]*() .* {$' "$tmp" | cut -d: -f1)"

for ln in $sig_lines; do
  sig="$(sed -n "${ln}p" "$tmp")"
  next_ln=$((ln + 1))
  [ "$next_ln" -gt "$total_lines" ] && continue
  body="$(sed -n "${next_ln}p" "$tmp")"

  # Body must be EXACTLY `return r.field` (a tab-indented bare field return,
  # no .clone(), no indexing, no further method call).
  case "$body" in
  $'\t'return\ [A-Za-z0-9_]*.[A-Za-z0-9_]*) ;;
  *) continue ;;
  esac
  # Reject if it has more than one dot after 'return ' (e.g. r.field.clone()
  # or r.field.len) or any parens/brackets -- those aren't a bare return.
  rest="${body#$'\t'return }"
  case "$rest" in
  *.*.* | *\(* | *\[*) continue ;;
  esac

  # Extract the return type: everything between the closing `)` of the
  # parameter list and the trailing ` {`.
  ret_type="${sig##*) }"
  ret_type="${ret_type% \{}"

  case "$ret_type" in
  bool | string | i8 | i16 | int | i64 | u8 | u16 | u32 | u64 | f32 | f64 | rune | byte)
    continue
    ;;
  esac

  echo "  line ${next_ln}: CANDIDATE -> ${rest#return }  (getter: ${sig}; return type: ${ret_type}; verify it doesn't alias a []T/map[K]V internal field)"
  found=$((found + 1))
done

if [ "$found" -gt 0 ]; then
  echo "FOUND $found candidate(s)."
  exit 1
else
  echo "No candidates found."
  exit 0
fi
