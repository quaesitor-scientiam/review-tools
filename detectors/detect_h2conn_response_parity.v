// detect_h2conn_response_parity — V port of
// skills/code-review/detect_h2conn_response_parity.sh.
//
// H2Conn.read_response must carry three guards the mux path has (file-wide marker
// greps, line by line):
//   1. trailers + END_STREAM   (case-insensitive: `trailer.*end_stream`)
//   2. DATA-before-HEADERS     (`DATA.*before.*HEADERS` or `before response HEADERS`)
//   3. :status range / 101     (`status<ws>*><ws>*599` or `status<ws>*==<ws>*101`)
//
// Usage: detect_h2conn_response_parity [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_conn.v; $2 is never scanned.
// Exit: 0 all present (or SKIP when the file is missing), 1 any missing.
// Diagnostics go to stderr like the .sh.
module main

import os

fn main() {
	file := if os.args.len > 1 { os.args[1] } else { 'vlib/net/http/h2_conn.v' }
	if !os.is_file(file) {
		eprintln('SKIP: ${file} not found')
		exit(0)
	}
	lines := (os.read_lines(file) or { []string{} }).map(it.trim_right('\r'))
	mut missing := []string{}
	if !lines.any(has_in_order(it.to_lower(), ['trailer', 'end_stream'])) {
		missing << 'trailers-without-END_STREAM guard (got_headers + second HEADERS lacking END_STREAM must error)'
	}
	if !lines.any(has_in_order(it, ['DATA', 'before', 'HEADERS']) || it.contains('before response HEADERS')) {
		missing << 'DATA-before-HEADERS guard (H2DataFrame arm must reject !got_headers)'
	}
	if !lines.any(has_status_check(it)) {
		missing << ':status range/101 rejection (status < 100 || status > 599 || status == 101)'
	}
	if missing.len == 0 {
		eprintln('OK: read_response enforces trailers-END_STREAM, DATA-before-HEADERS, and :status range/101 (parity with the mux path)')
		exit(0)
	}
	eprintln('BUG: ${file} read_response is missing response-validation guards the mux path enforces:')
	for m in missing {
		eprintln('  - ${m}')
	}
	exit(1)
}

// has_in_order mirrors a grep pattern `a.*b.*c` on one line.
fn has_in_order(l string, parts []string) bool {
	mut pos := 0
	for p in parts {
		i := l[pos..].index(p) or { return false }
		pos += i + p.len
	}
	return true
}

fn skip_ws(l string, p int) int {
	mut i := p
	for i < l.len && (l[i] == ` ` || l[i] == `\t`) {
		i++
	}
	return i
}

// has_status_check mirrors `status[[:space:]]*>[[:space:]]*599|status[[:space:]]*==[[:space:]]*101`.
fn has_status_check(l string) bool {
	mut off := 0
	for {
		i := l[off..].index('status') or { return false }
		p := skip_ws(l, off + i + 'status'.len)
		rest := l[p..]
		if rest.starts_with('>') && l[skip_ws(l, p + 1)..].starts_with('599') {
			return true
		}
		if rest.starts_with('==') && l[skip_ws(l, p + 2)..].starts_with('101') {
			return true
		}
		off += i + 1
	}
	return false
}
