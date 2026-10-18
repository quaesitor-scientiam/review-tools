#!/usr/bin/env bash
# struct-wrapped resource leak detector (a mechanical review angle, see SKILL.md "Phase R").
#
# Companion to detect_ecdsa_key_missing_free.sh, which only catches a leak at the
# CONSTRUCTOR's own call site (`x := ecdsa.PrivateKey.new()` ... `x.free()` in the
# same file). It is structurally blind whenever the resource is bundled into a
# struct field and returned from a helper function, because the freed identifier
# is then a DIFFERENT name (`server.priv_key`, not `server_priv`) -- see that
# script's own documented false positive on tls13_handshake_test.v.
#
# This script closes that ONE-HOP case: a struct with a field of the given
# resource type, returned (possibly among other values) by a function, consumed
# by N call sites in the same file. It does this by chaining two lookups the
# other script doesn't attempt:
#   1. struct field declaration  -> (struct name, field name)
#   2. function return signature -> (function name, which position in the
#      return tuple is that struct type)
# then, for every call site of that function, checks whether the LHS binding at
# that SAME position is `_` (an immediate, certain discard) or a captured name
# `X` with a matching `X.<field>.free()` somewhere in the file.
#
# WHAT THIS IS NOT: this is not general data-flow/alias analysis. Even with
# the graphify-backed cross-file mode below, it resolves exactly ONE hop of
# struct-field indirection and ONE hop of call-site binding. It will NOT
# catch:
#   - the struct being reassigned/aliased to a DIFFERENT variable before the
#     free (e.g. `other := server; h.free()` with `server.priv_key.free()`
#     never reached because `other` is what's actually live). This is a
#     genuine limit, not a missing feature: graphify's own symbol model (see
#     `graphify overview`) has module/import/fn/struct/field/const/method/
#     enum/interface nodes -- NO local-variable/assignment node at all -- so
#     no graph query can ever answer "does this SPECIFIC local get reassigned
#     before this SPECIFIC free call." That needs a real AST/dataflow pass
#     over the function body, a different class of tool than a symbol graph.
#   - the resource nested TWO OR MORE struct levels deep. This case is REAL,
#     not hypothetical, in this same codebase: `VerifiedCertificateChain`
#     (itself a one-hop wrapper around a raw `&C.mbedtls_x509_crt`) is a field
#     of `Tls13ClientHandshake` (`tls13_handshake.v:159`) -- confirmed via
#     `graphify explain VerifiedCertificateChain`'s "referenced by" list.
#     Already handled correctly BY HAND (`Tls13ClientHandshake.free()` calls
#     `h.verified_chain.free()`, which internally frees the mbedtls chain) --
#     not a live bug, but proof the shape exists. Generalizing this script to
#     walk N levels recursively is a deliberate scope cut, not an oversight:
#     it would need to recurse "does this field's OWN type contain a
#     resource, transitively" using graphify's reference edges, which is
#     buildable but not done here because no live 2-level bug motivates it
#     today -- do this properly (recursive closure over "referenced by") if a
#     future finding needs it, rather than a rushed one-off special case.
#   - a resource stored in a container (array/map) and freed via a loop whose
#     coverage can't be verified statically
#
# CROSS-FILE callers ARE now handled, when a graphify graph is available: set
# GRAPHIFY_EXE and GRAPHIFY_GRAPH (env vars) to use `graphify explain <fn>`
# for the REAL whole-codebase "called by" list instead of a same-file grep.
# This was proven necessary, not hypothetical: `mbedtls.build_certificate_chain`
# (a sibling resource-constructing function, same file family) is called from
# SIX different files (x509_standalone_chain_test.v, x509_standalone_signature_
# test.v, tls13_certificate_chain.v, tls13_certificate_chain_test.v,
# tls13_handshake_test.v, tls13_quiche_vector_test.v) -- a single-file-scoped
# run against any ONE of them would see only a fraction of its true callers.
# Falls back to the original single-file grep when the env vars are unset, so
# existing invocations (including run_detectors.sh's manifest) are unaffected.
#
# Usage:
#   detect_struct_wrapped_resource_leak.sh <file> [resource_type_regex] [gitrev]
#   e.g. detect_struct_wrapped_resource_leak.sh vlib/net/quic/tls13_handshake_test.v
#   e.g. detect_struct_wrapped_resource_leak.sh vlib/net/quic/tls13_handshake_test.v 'ecdsa\.(PrivateKey|PublicKey)'
#   e.g. GRAPHIFY_EXE=/path/graphify.exe GRAPHIFY_GRAPH=/path/graph.json \
#        detect_struct_wrapped_resource_leak.sh vlib/net/quic/tls13_handshake_test.v
# `resource_type_regex` defaults to `ecdsa\.(PrivateKey|PublicKey)` (this
# detector's original motivating case) so it can be registered in
# run_detectors.sh's <file>-only manifest like any other detector; pass an
# explicit regex to check for a different manually-freed C-interop type.
# `GRAPHIFY_REPO_ROOT` overrides the auto-detected (`git rev-parse
# --show-toplevel`) root used to resolve graphify's repo-relative paths.
#
# Exit status: 1 if any call site either discards the wrapping struct via `_`
# or binds it to a name with no matching `<name>.<field>.free()` anywhere in
# its own file; else 0.

set -u
file="${1:?usage: detect_struct_wrapped_resource_leak.sh <file> [resource_type_regex] [gitrev]}"
resource_re="${2:-ecdsa\.(PrivateKey|PublicKey)}"
rev="${3:-}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
if [ -n "$rev" ]; then
  git show "${rev}:${file}" > "$tmp" || { echo "cannot read $file @ $rev"; exit 2; }
  label="$file @ $rev"
else
  cp "$file" "$tmp"
  label="$file (working tree)"
fi

echo "=== struct-wrapped resource leak detector: $label (resource: $resource_re) ==="
found=0
any_struct=0

# Step 1: find every struct field of the resource type, and its enclosing struct.
while IFS=: read -r field_ln field_rest; do
  [ -z "$field_ln" ] && continue
  field_name="$(echo "$field_rest" | sed -nE 's/^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]+.*/\1/p')"
  [ -z "$field_name" ] && continue

  # Walk backward from field_ln to the nearest enclosing `struct Name {`.
  struct_name="$(awk -v target="$field_ln" '
    /^[[:space:]]*(pub[[:space:]]+)?(mut:[[:space:]]*)?struct[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\{/ {
      match($0, /struct[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)/, m); name = m[1]; start = NR
    }
    NR == target { print name; exit }
  ' "$tmp")"
  [ -z "$struct_name" ] && continue
  any_struct=1
  echo "--- struct $struct_name.$field_name ($resource_re), declared line $field_ln ---"

  # Step 2: find every function whose return signature mentions struct_name,
  # and which comma-separated position (1-indexed) it occupies.
  while IFS=: read -r sig_ln sig_rest; do
    [ -z "$sig_ln" ] && continue
    func_name="$(echo "$sig_rest" | sed -nE 's/^[[:space:]]*(pub[[:space:]]+)?fn[[:space:]]+(\([^)]*\)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)\(.*/\3/p')"
    [ -z "$func_name" ] && continue
    ret_types="$(echo "$sig_rest" | sed -nE 's/.*\)[[:space:]]*!?\(([^{]*)\)[[:space:]]*\{?[[:space:]]*$/\1/p')"
    [ -z "$ret_types" ] && continue
    pos=0
    struct_pos=0
    IFS=',' read -ra rt_parts <<< "$ret_types"
    for part in "${rt_parts[@]}"; do
      pos=$((pos + 1))
      if echo "$part" | grep -qE "\\b${struct_name}\\b"; then
        struct_pos=$pos
      fi
    done
    [ "$struct_pos" -eq 0 ] && continue
    echo "  fn ${func_name}(...) returns ${struct_name} at position ${struct_pos}/${pos}"

    # Step 3: every call site of func_name -- which FILE(S) to scan for call
    # sites depends on whether a graphify graph is available. Default:
    # single-file (the target file only, matching this script's original
    # scope). With GRAPHIFY_EXE+GRAPHIFY_GRAPH set: every file graphify's
    # call graph reports as an actual caller of func_name, anywhere in the
    # codebase -- closing the cross-file gap documented above.
    scan_files=("$tmp")
    scan_labels=("$file")
    if [ -n "${GRAPHIFY_EXE:-}" ] && [ -n "${GRAPHIFY_GRAPH:-}" ]; then
      repo_root="${GRAPHIFY_REPO_ROOT:-$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null)}"
      if [ -n "$repo_root" ] && [ -x "$GRAPHIFY_EXE" -o -f "$GRAPHIFY_EXE" ]; then
        called_by_line="$("$GRAPHIFY_EXE" explain "$func_name" --graph "$GRAPHIFY_GRAPH" 2>/dev/null | grep '^called by')"
        if [ -n "$called_by_line" ]; then
          mapfile -t caller_paths < <(echo "$called_by_line" | grep -oE '\([^()]*:[0-9]+\)' | sed -E 's/^\(//; s/:[0-9]+\)$//' | sort -u)
          scan_files=()
          scan_labels=()
          for p in "${caller_paths[@]}"; do
            abs="$repo_root/$p"
            [ -f "$abs" ] || continue
            scan_files+=("$abs")
            scan_labels+=("$p")
          done
          echo "  (graphify: ${#scan_files[@]} caller file(s) across the codebase, not just ${file})"
        fi
      fi
    fi

    for idx in "${!scan_files[@]}"; do
      scan_file="${scan_files[$idx]}"
      scan_label="${scan_labels[$idx]}"
      while IFS=: read -r call_ln call_rest; do
        [ -z "$call_ln" ] && continue
        [ "$scan_label" = "$file" ] && [ "$call_ln" -eq "$sig_ln" ] && continue
        echo "$call_rest" | grep -qE '^\s*//' && continue
        lhs="$(echo "$call_rest" | sed -nE 's/^[[:space:]]*(mut[[:space:]]+)?([a-zA-Z_][a-zA-Z0-9_[:space:]]*(,[[:space:]]*(mut[[:space:]]+)?[a-zA-Z_][a-zA-Z0-9_[:space:]]*)*)[[:space:]]*:=.*/\2/p')"
        [ -z "$lhs" ] && continue
        IFS=',' read -ra lhs_parts <<< "$lhs"
        [ "${#lhs_parts[@]}" -lt "$struct_pos" ] && continue
        raw="${lhs_parts[$((struct_pos - 1))]}"
        var="$(echo "$raw" | sed -E 's/^[[:space:]]*(mut[[:space:]]+)?//; s/[[:space:]]*$//')"
        [ -z "$var" ] && continue
        if [ "$var" = "_" ]; then
          echo "    ${scan_label}:${call_ln}: DISCARDED -> _ (call to ${func_name} discards its ${struct_name} return, dropping .${field_name})"
          found=1
          continue
        fi
        if grep -qE "\\b${var}\\.${field_name}\\.free\\(\\)" "$scan_file"; then
          echo "    ${scan_label}:${call_ln}: FREED     -> ${var}.${field_name}"
        else
          echo "    ${scan_label}:${call_ln}: LEAKED    -> ${var} (no \`${var}.${field_name}.free()\` anywhere in ${scan_label})"
          found=1
        fi
      done < <(grep -nE "\\b${func_name}\\(" "$scan_file")
    done
  done < <(grep -nE '^[[:space:]]*(pub[[:space:]]+)?fn[[:space:]]' "$tmp")
done < <(grep -nE "^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+${resource_re}[[:space:]]*\$" "$tmp")

if [ "$any_struct" -eq 0 ]; then
  echo "RESULT: no struct field of type matching '${resource_re}' found -- nothing to check."
  exit 0
fi

if [ "$found" -eq 1 ]; then
  echo "RESULT: a struct-wrapped resource is discarded or unfreed at some call site -- resource leak."
  exit 1
fi
echo "RESULT: every call site captures and frees the struct-wrapped resource."
exit 0
