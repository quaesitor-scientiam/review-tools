#!/usr/bin/env bash
# net.quic test file missing the present_openssl? build gate (a mechanical
# review angle, see SKILL.md "Phase R").
#
# Every file in vlib/net/quic/ compiles as ONE translation unit (they all
# share `module quic`), and tls13_handshake.v transitively imports
# crypto.ecdsa, which has UNCONDITIONAL OpenSSL C-interop requirements (see
# memory: openssl-ecdsa-mingw-dynamic-triplet.md / project_http3_quic.md).
# On docker-ubuntu-musl CI, that means literally ANY *_test.v file in this
# module fails to compile (`fatal error: sys/cdefs.h: No such file or
# directory`) unless it is EXCLUDED from the run via one of two mechanisms:
#   1. `// vtest build: present_openssl?` as the file's first line (checked
#      by cmd/tools/modules/testing/common.v's check_openssl_present(), and
#      confirmed empirically to ALSO be respected by `test-self` -- the
#      command docker-ubuntu-musl actually runs), or
#   2. an entry in cmd/tools/vtest-self.v's musl skip list (an older,
#      parallel mechanism from before the gate convention existed; still
#      honored, but new files should just use the gate).
#
# This bug has been missed TWICE by two consecutive phases of the same
# project (Phase 7 / PR #27884, then Phase 8 / PR #27885) -- both times a
# brand-new *_test.v file was added without the gate, and both times CI (not
# review) was what caught it. This detector exists so a future new quic test
# file gets caught BEFORE push, not after a ~35min docker-ubuntu-musl run.
#
# Usage:
#   detect_quic_test_missing_openssl_gate.sh <file>            # working tree
#   detect_quic_test_missing_openssl_gate.sh <file> <gitrev>   # at a revision
#
# Only meaningful for files under vlib/net/quic/*_test.v -- a file outside
# that path is a no-op pass (so it's safe to wire into a path-based manifest
# with a slightly loose glob).
#
# Exit status: 1 if the file is a vlib/net/quic/*_test.v file with NEITHER
# the gate nor a vtest-self.v skip-list entry; else 0.

set -u
file="${1:?usage: detect_quic_test_missing_openssl_gate.sh <file> [gitrev]}"
base="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

case "$file" in
  vlib/net/quic/*_test.v) ;;
  *)
    echo "=== quic openssl-gate detector: $file (not a vlib/net/quic/*_test.v file, skipping) ==="
    exit 0
    ;;
esac

# The skip list is read relative to the CURRENT DIRECTORY: run_detectors.sh
# cd's to the repo root (or to its --at extraction tree) before calling us.
skip_list="cmd/tools/vtest-self.v"

get_first_line() {
  head -1 "$file" 2>/dev/null
}

get_skip_list() {
  cat "$skip_list" 2>/dev/null
}

label="$file"
echo "=== quic openssl-gate detector: $label ==="

first_line="$(get_first_line)"
if [ "$first_line" = "// vtest build: present_openssl?" ]; then
  echo "  RESULT: gated via '// vtest build: present_openssl?' (line 1)."
  exit 0
fi

if get_skip_list | grep -qF "'$file',"; then
  echo "  RESULT: not gated, but listed in cmd/tools/vtest-self.v's musl skip list."
  exit 0
fi

echo "  MISSING: no '// vtest build: present_openssl?' gate as line 1, and not"
echo "           present in cmd/tools/vtest-self.v's musl skip list."
echo "  FIX: add '// vtest build: present_openssl?' as this file's first line"
echo "       (before 'module quic')."
echo "RESULT: net.quic test file will hard-fail docker-ubuntu-musl CI."
exit 1
