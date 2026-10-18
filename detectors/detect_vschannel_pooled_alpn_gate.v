// detect_vschannel_pooled_alpn_gate -- V port of
// skills/code-review/detect_vschannel_pooled_alpn_gate.sh.
//
// Contract: take the body starting at the first line beginning `fn h2_dial_probe_vschannel`
// through the first following line that begins with `}` (inclusive). No such
// function -> SKIP (exit 0); an unreadable file also ends in this SKIP, as in the
// shell original (cat's error goes to stderr). Within the body find the first line
// containing `new_vschannel_pooled_transport` (none -> SKIP, exit 0) and the first
// containing `vschannel_alpn_supported`. FLAG (exit 1) when the gate is missing or
// on a LATER line than the dial; a same-line gate counts as gated.
//
// Usage: detect_vschannel_pooled_alpn_gate <file> [base_copy_or_empty]  ($2 is never scanned)
// Exit: 1 flagged, 0 OK/SKIP.
module main

import os

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_vschannel_pooled_alpn_gate <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or {
		eprintln('cannot read ${file}')
		''
	}
	lines := content.split('\n').map(it.trim_right('\r'))
	mut body := []string{}
	mut started := false
	for l in lines {
		if !started && l.starts_with('fn h2_dial_probe_vschannel') {
			started = true
		}
		if started {
			body << l
			if l.starts_with('}') {
				break
			}
		}
	}
	if body.len == 0 {
		println('SKIP: h2_dial_probe_vschannel not found in ${file}')
		return
	}
	mut dial_line := 0
	mut gate_line := 0
	for i, l in body {
		if dial_line == 0 && l.contains('new_vschannel_pooled_transport') {
			dial_line = i + 1
		}
		if gate_line == 0 && l.contains('vschannel_alpn_supported') {
			gate_line = i + 1
		}
	}
	if dial_line == 0 {
		println('SKIP: no pooled dial in h2_dial_probe_vschannel')
		return
	}
	if gate_line == 0 || gate_line > dial_line {
		println('FLAG: h2_dial_probe_vschannel dials new_vschannel_pooled_transport (which always advertises ALPN) without a preceding vschannel_alpn_supported() gate -- pre-8.1 SChannel can fail the whole handshake on the ALPN buffer; return is_h2:false without dialing there instead.')
		exit(1)
	}
	println('OK: h2_dial_probe_vschannel gates the pooled (ALPN-advertising) dial on vschannel_alpn_supported().')
}
