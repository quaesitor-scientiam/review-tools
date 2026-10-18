// detect_mux_headers_after_end — V port of
// skills/code-review/detect_mux_headers_after_end.sh.
//
// H2MuxConn.on_response_headers must guard on `if s.ended {` BEFORE the trailers
// branch (`if was_headers_done {`): a HEADERS frame after an earlier END_STREAM
// is a frame on a closed stream (RFC 9113 §5.1) and must reset the stream.
//
// Region = from the first line containing `fn (mut c H2MuxConn) on_response_headers(`
// through the first following line containing `if was_headers_done {` (or EOF).
// Required: `if\s+s.ended\s*{` somewhere in that region.
//
// Usage: detect_mux_headers_after_end [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_mux_conn.v; $2 is never scanned.
// Exit: 1 if the guard is missing; 0 if present, or SKIP (file/region not found).
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
		if l.contains('fn (mut c H2MuxConn) on_response_headers(') {
			capture = true
		}
		if capture {
			region << l
			if l.contains('if was_headers_done {') {
				break
			}
		}
	}
	if region.len == 0 {
		eprintln('SKIP: could not locate on_response_headers / its trailers branch in ${file}')
		exit(0)
	}
	if region.any(has_ended_guard(it)) {
		eprintln('OK: ${file} guards on s.ended before the trailers branch (HEADERS-after-end is reset)')
		exit(0)
	}
	eprintln('BUG: ${file} on_response_headers does not check s.ended before appending trailers.')
	eprintln('  A HEADERS frame after the stream already ended (a prior END_STREAM) is a frame on a')
	eprintln('  closed stream (RFC 9113 §5.1), not more trailers — it must reset the stream, else its')
	eprintln("  fields can be delivered in resp.headers. Add an 'if s.ended { reset_stream; return }'")
	eprintln('  guard after locking, before the was_headers_done trailers handling.')
	exit(1)
}

fn is_ws(c u8) bool {
	return c == ` ` || c == `\t` || c == `\v` || c == `\f` || c == `\r` || c == `\n`
}

// has_ended_guard mirrors `if[[:space:]]+s\.ended[[:space:]]*\{`.
fn has_ended_guard(l string) bool {
	mut from := 0
	for {
		i := l.index_after('if', from) or { return false }
		from = i + 1
		mut j := i + 2
		if j >= l.len || !is_ws(l[j]) {
			continue
		}
		for j < l.len && is_ws(l[j]) {
			j++
		}
		if !l[j..].starts_with('s.ended') {
			continue
		}
		j += 's.ended'.len
		for j < l.len && is_ws(l[j]) {
			j++
		}
		if j < l.len && l[j] == `{` {
			return true
		}
	}
	return false
}
