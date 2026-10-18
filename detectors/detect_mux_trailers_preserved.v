// detect_mux_trailers_preserved — V port of
// skills/code-review/detect_mux_trailers_preserved.sh.
//
// The second-HEADERS (trailers) branch of H2MuxConn.on_response_headers must
// append the decoded fields to a response header/trailer list, not just mark the
// stream ended (sync/mux response parity with H2Conn.read_response).
//
// Region = from the first line matching
// `was_headers_done\s*&&\s*!frame.end_stream` through the first following line
// containing `s.cv.signal()` (or EOF). Required in that region:
// `resp_(trailers|headers)\s*<<`.
//
// Usage: detect_mux_trailers_preserved [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_mux_conn.v; $2 is never scanned.
// Exit: 1 if trailers are dropped; 0 if preserved, or SKIP (not found).
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
	mut region := []string{}
	mut capture := false
	for raw in lines {
		l := raw.trim_right('\r')
		if is_trailer_start(l) {
			capture = true
		}
		if capture {
			region << l
			if l.contains('s.cv.signal()') {
				break
			}
		}
	}
	if region.len == 0 {
		eprintln('SKIP: could not locate the trailer-handling region in ${file}')
		exit(0)
	}
	if region.any(appends_resp(it)) {
		eprintln('OK: ${file} preserves trailer fields on the mux path (sync/mux parity)')
		exit(0)
	}
	eprintln('BUG: ${file} drops trailing HEADERS on the mux path.')
	eprintln('  The second-HEADERS (trailers) branch in on_response_headers sets s.ended but never')
	eprintln('  appends the decoded fields, so grpc-status/digest/etc. are lost. The sync')
	eprintln('  H2Conn.read_response appends non-pseudo trailers to the response headers; mirror it')
	eprintln('  (append to a per-stream trailer list, flush into resp.headers when the stream ends).')
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

// is_trailer_start mirrors `was_headers_done[[:space:]]*&&[[:space:]]*!frame\.end_stream`.
fn is_trailer_start(l string) bool {
	mut from := 0
	for {
		i := l.index_after('was_headers_done', from) or { return false }
		from = i + 1
		mut j := skip_ws(l, i + 'was_headers_done'.len)
		if !l[j..].starts_with('&&') {
			continue
		}
		j = skip_ws(l, j + 2)
		if l[j..].starts_with('!frame.end_stream') {
			return true
		}
	}
	return false
}

// appends_resp mirrors `resp_(trailers|headers)[[:space:]]*<<`.
fn appends_resp(l string) bool {
	for name in ['resp_trailers', 'resp_headers'] {
		mut from := 0
		for {
			i := l.index_after(name, from) or { break }
			from = i + 1
			j := skip_ws(l, i + name.len)
			if l[j..].starts_with('<<') {
				return true
			}
		}
	}
	return false
}
