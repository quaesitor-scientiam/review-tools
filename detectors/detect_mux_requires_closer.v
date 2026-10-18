// detect_mux_requires_closer — V port of
// skills/code-review/detect_mux_requires_closer.sh.
//
// new_h2_mux_conn must reject a nil close_transport before it spawns the reader,
// else teardown can never interrupt the reader's blocking transport.read().
//
// Body = from the first line containing `pub fn new_h2_mux_conn(` through the
// first following line containing `spawn c.read_loop()` (or EOF). Required in
// that body: `close_transport\s*==\s*unsafe\s*{\s*nil\s*}`.
//
// Usage: detect_mux_requires_closer [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_mux_conn.v; $2 is never scanned.
// Exit: 1 if a nil closer is accepted; 0 if rejected, or SKIP (not found).
module main

import os

fn main() {
	file := if os.args.len > 1 && os.args[1] != '' {
		os.args[1]
	} else {
		'vlib/net/http/h2_mux_conn.v'
	}
	if !os.is_file(file) {
		eprintln('SKIP: ${file} not found')
		exit(0)
	}
	lines := os.read_lines(file) or {
		eprintln('SKIP: ${file} not found')
		exit(0)
	}
	mut body := []string{}
	mut capture := false
	for raw in lines {
		l := raw.trim_right('\r')
		if l.contains('pub fn new_h2_mux_conn(') {
			capture = true
		}
		if capture {
			body << l
			if l.contains('spawn c.read_loop()') {
				break
			}
		}
	}
	if body.len == 0 {
		eprintln('SKIP: could not locate new_h2_mux_conn in ${file}')
		exit(0)
	}
	if body.any(rejects_nil_closer(it)) {
		eprintln('OK: ${file} rejects a nil close_transport (reader is always wakeable at teardown)')
		exit(0)
	}
	eprintln('BUG: ${file} new_h2_mux_conn accepts a nil close_transport.')
	eprintln('  The reader thread blocks in transport.read() and the H2Transport interface has no')
	eprintln('  close(); teardown_transport no-ops when close_transport is nil, so an idle retirement')
	eprintln('  or last-reference release leaks the reader thread and the connection. Require a non-nil')
	eprintln('  closer (panic on nil) before spawning the reader.')
	exit(1)
}

fn is_ws(c u8) bool {
	return c == ` ` || c == `\t` || c == `\v` || c == `\f` || c == `\r` || c == `\n`
}

fn skip_ws(s string, from int) int {
	mut i := from
	for i < s.len && is_ws(s[i]) {
		i++
	}
	return i
}

// rejects_nil_closer mirrors
// `close_transport[[:space:]]*==[[:space:]]*unsafe[[:space:]]*\{[[:space:]]*nil[[:space:]]*\}`.
fn rejects_nil_closer(l string) bool {
	mut from := 0
	for {
		i := l.index_after('close_transport', from) or { return false }
		from = i + 1
		mut j := skip_ws(l, i + 'close_transport'.len)
		if !l[j..].starts_with('==') {
			continue
		}
		j = skip_ws(l, j + 2)
		if !l[j..].starts_with('unsafe') {
			continue
		}
		j = skip_ws(l, j + 6)
		if j >= l.len || l[j] != `{` {
			continue
		}
		j = skip_ws(l, j + 1)
		if !l[j..].starts_with('nil') {
			continue
		}
		j = skip_ws(l, j + 3)
		if j < l.len && l[j] == `}` {
			return true
		}
	}
	return false
}
