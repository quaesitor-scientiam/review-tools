// detect_tls_accept_send_interruptible -- V port of
// skills/code-review/detect_tls_accept_send_interruptible.sh.
//
// Contract: target defaults to vlib/net/http/server_tls_notd_use_openssl.v; a
// missing file is a SKIP (exit 0). If any line is `select {` (leading blanks, any
// blanks before `{`) the accept send is interruptible: OK, exit 0. Otherwise, if a
// line starts (after blanks) with `ch <- conn` it is the bare blocking send: BUG,
// exit 1. Else OK. All messages go to stderr, as in the shell original.
//
// Usage: detect_tls_accept_send_interruptible [file] [ignored]  ($2 is never scanned)
// Exit: 1 bare send without select, 0 otherwise.
module main

import os

const default_file = 'vlib/net/http/server_tls_notd_use_openssl.v'

fn is_select_open(l string) bool {
	t := l.trim_left(' \t\v\f\r')
	if !t.starts_with('select') {
		return false
	}
	return t[6..].trim_left(' \t\v\f\r').starts_with('{')
}

fn main() {
	file := if os.args.len > 1 { os.args[1] } else { default_file }
	if !os.is_file(file) {
		eprintln('SKIP: ${file} not found')
		return
	}
	content := os.read_file(file) or {
		eprintln('SKIP: ${file} not found')
		return
	}
	lines := content.split('\n').map(it.trim_right('\r'))
	has_select := lines.any(is_select_open(it))
	has_send := lines.any(it.trim_left(' \t\v\f\r').starts_with('ch <- conn'))
	if has_select {
		eprintln('OK: ${file} enqueues raw conns through an interruptible select (accept thread can reach close_idle during a handshake flood)')
		return
	}
	if has_send {
		eprintln("BUG: ${file} hands raw conns to workers with a bare blocking 'ch <- conn' and no interruptible select.")
		eprintln('  Under a slow-handshake flood the accept thread blocks on the full channel, never reaches')
		eprintln('  close_idle(), and stop()/close() is not observed until a worker handshake times out.')
		exit(1)
	}
	eprintln("OK: no bare 'ch <- conn' accept-send found in ${file}")
}
