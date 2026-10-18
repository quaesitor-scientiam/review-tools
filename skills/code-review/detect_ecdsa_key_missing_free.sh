#!/usr/bin/env bash
# ecdsa key resource-leak detector (a mechanical review angle, see SKILL.md "Phase R").
#
# vlib/crypto/ecdsa's PrivateKey/PublicKey wrap an OpenSSL EVP_PKEY with NO
# finalizer -- every constructor (`ecdsa.PrivateKey.new()`, `<priv>.public_key()`,
# `ecdsa.generate_key()`, `ecdsa.PublicKey.from_uncompressed_bytes()`) MUST be
# paired with a `.free()` call in the SAME function, or the EVP_PKEY leaks
# (confirmed via ASan LeakSanitizer: CRYPTO_zalloc leaked from
# crypto__ecdsa__PrivateKey__static__new). This is the established, universally
# followed convention in every existing ecdsa test file and every other net.quic
# test file (tls13_handshake_test.v, tls13_certificate_chain_test.v) -- one test
# missed it (tls13_client_hello_test.v's test_build_client_hello_structure).
#
# `generate_key()` was ADDED to this detector's constructor list after a second,
# related miss: 7 test functions in tls13_handshake_test.v called
# `drive_to_wait_encrypted_extensions` (whose OWN body correctly frees its two
# local generate_key() results) and discarded its returned FakeServerHandshake
# struct via `_`, dropping the only reference to the struct's embedded
# ecdsa.PrivateKey field. The ORIGINAL version of this detector didn't recognize
# `generate_key(` as a constructor at all, so it could not have caught this even
# if run -- see vlang/v#27680 commit d263f9195f and [[code-review-misses]].
# KNOWN REMAINING GAP: this detector only catches a leak at the constructor's
# OWN call site (a local var with no matching `.free()` anywhere in the file). It
# does NOT trace a key threaded through a struct field, out through a return,
# and into N different callers that may or may not capture-and-free it -- that
# shape (exactly what caused the second miss above) needs a caller-enumeration
# check, not a single-file grep, and is not implemented here. Do not treat a
# clean run of this detector as proof no ecdsa key leaks exist in a file that
# returns one wrapped in a struct.
#
# CONFIRMED FALSE POSITIVE on tls13_handshake_test.v, even on the FIXED tree:
# `server_priv := ecdsa.generate_key(...)` is real, correctly freed (12 of the
# file's callers now do `unsafe { server.priv_key.free() }`), but that text is
# `server.priv_key.free()`, not `server_priv.free()` -- a different identifier,
# because the key is stored under a struct field (FakeServerHandshake.priv_key)
# and threaded through a return before being freed. This detector's "same name,
# same file" heuristic cannot see through that renaming and will always report
# `server_priv` as LEAKED on this file, fixed or not. Do not "fix" this by
# special-casing this one field/struct name -- that would be brittle,
# file-specific pattern-matching dressed up as a general check. Verify a
# struct-threaded case like this one by hand (enumerate every caller of the
# helper that returns the struct) or via CI's own ASan/LeakSanitizer run, not
# via this script.
#
# Usage:
#   detect_ecdsa_key_missing_free.sh <file>            # scan the working-tree file
#   detect_ecdsa_key_missing_free.sh <file> <gitrev>   # scan that file at a git revision
#
# Exit status: 1 if any ecdsa key variable has no `.free()` call anywhere in the
# file, else 0. Note: this is a whole-file heuristic (constructor and matching
# free are usually in the same test function, but the check doesn't require
# same-function scoping) -- a false negative is possible if a DIFFERENT variable
# of the same name is freed elsewhere; in practice this hasn't occurred in this
# corpus and keeps the check simple and grep-able.

set -u
file="${1:?usage: detect_ecdsa_key_missing_free.sh <file> [gitrev]}"
base="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cp "$file" "$tmp" || { echo "cannot read $file"; exit 2; }
label="$file"

echo "=== ecdsa key missing-free detector: $label ==="
found=0
while IFS=: read -r ln rest; do
  [ -z "$ln" ] && continue
  # Extract the LHS identifier list of `a := ...` or `a, b := ...` (V allows
  # multi-value destructuring, e.g. `server_pub, server_priv := ecdsa.generate_key(...)`),
  # with an optional leading `mut` on the whole list or per-identifier.
  lhs="$(echo "$rest" | sed -nE 's/^[[:space:]]*(mut[[:space:]]+)?([a-zA-Z_][a-zA-Z0-9_[:space:]]*(,[[:space:]]*(mut[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_[:space:]]*)*)[[:space:]]*:=.*/\2/p')"
  if [ -z "$lhs" ]; then
    echo "  line $ln: could not extract variable name -> $(echo "$rest" | sed 's/^[[:space:]]*//')"
    continue
  fi
  # A bare `_` discards the value -- if the constructor result feeds a struct
  # field (e.g. FakeServerHandshake.priv_key) that later gets `_`-discarded by
  # a DIFFERENT caller several functions away, this per-declaration-site check
  # cannot see it (see the KNOWN REMAINING GAP note above); it can only flag
  # the case where `_` is used directly at the constructor call itself.
  IFS=',' read -ra vars <<< "$lhs"
  for raw_var in "${vars[@]}"; do
    var="$(echo "$raw_var" | sed -E 's/^[[:space:]]*(mut[[:space:]]+)?//; s/[[:space:]]*$//')"
    [ -z "$var" ] && continue
    if [ "$var" = "_" ]; then
      echo "  line $ln: DISCARDED -> _ (constructor result discarded at its own call site)"
      found=1
      continue
    fi
    if grep -qE "\\b${var}\\.free\\(\\)" "$tmp"; then
      echo "  line $ln: FREED     -> $var"
    else
      echo "  line $ln: LEAKED    -> $var (no \`${var}.free()\` anywhere in file)"
      found=1
    fi
  done
done < <(grep -nE '\.(PrivateKey\.new|public_key|generate_key|from_uncompressed_bytes)\(' "$tmp" | grep -v '//')

if [ "$found" -eq 1 ]; then
  echo "RESULT: ecdsa key(s) created with no matching .free() -- resource leak."
  exit 1
fi
echo "RESULT: every ecdsa key in this file has a matching .free()."
exit 0
