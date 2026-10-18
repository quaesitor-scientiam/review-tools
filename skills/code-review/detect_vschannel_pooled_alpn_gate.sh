#!/usr/bin/env bash
# detect_vschannel_pooled_alpn_gate.sh <file> [commit]
#
# Flags h2_dial_probe_vschannel dialing (via new_vschannel_pooled_transport,
# which unconditionally advertises ALPN) without FIRST checking
# vschannel_alpn_supported(). Pre-Windows 8.1 / Server 2012 R2 SChannel has no
# client-side ALPN: injecting a SECBUFFER_APPLICATION_PROTOCOLS buffer into
# the handshake can fail it outright, so the pooled probe must report the
# origin as h1-only WITHOUT dialing there (mirroring vschannel_ssl_do's own
# `C.vschannel_alpn_supported() != 0` guard on the one-shot path -- the gate
# lives in the sibling's CALLER, which is exactly why a function-scoped
# sibling-parity diff against vschannel_h2_do missed it).
#
# Codex P1, vlang/v#27712 pullrequestreview-4729311285 (comment 3609206168).
# Repro: exit 1 on e0368d7a2d, exit 0 after the fix.
#
# Deliberately scoped to h2_dial_probe_vschannel: vschannel_h2_do (one-shot)
# also sets ALPN with no in-file gate, but is only reachable through
# vschannel_ssl_do's guard; schannel_alpn_probe is a capability prober whose
# whole purpose is advertising ALPN. A file-scope rule would false-flag both.
set -uo pipefail

file="${1:?usage: detect_vschannel_pooled_alpn_gate.sh <file> [commit]}"
commit="${2:-}"

src() {
	if [ -n "$commit" ]; then
		git show "$commit:$file"
	else
		cat "$file"
	fi
}

body="$(src | awk '/^fn h2_dial_probe_vschannel/{f=1} f{print} f && /^}/{exit}')"
if [ -z "$body" ]; then
	echo "SKIP: h2_dial_probe_vschannel not found in $file"
	exit 0
fi

dial_line="$(printf '%s\n' "$body" | grep -n 'new_vschannel_pooled_transport' | head -1 | cut -d: -f1)"
if [ -z "$dial_line" ]; then
	echo "SKIP: no pooled dial in h2_dial_probe_vschannel"
	exit 0
fi

gate_line="$(printf '%s\n' "$body" | grep -n 'vschannel_alpn_supported' | head -1 | cut -d: -f1)"
if [ -z "$gate_line" ] || [ "$gate_line" -gt "$dial_line" ]; then
	echo "FLAG: h2_dial_probe_vschannel dials new_vschannel_pooled_transport (which always advertises ALPN) without a preceding vschannel_alpn_supported() gate -- pre-8.1 SChannel can fail the whole handshake on the ALPN buffer; return is_h2:false without dialing there instead."
	exit 1
fi

echo "OK: h2_dial_probe_vschannel gates the pooled (ALPN-advertising) dial on vschannel_alpn_supported()."
exit 0
