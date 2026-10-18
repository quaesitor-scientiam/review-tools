// detect_h2conn_1xx_end_stream — V port of
// skills/code-review/detect_h2conn_1xx_end_stream.sh.
//
// The 1xx interim branch in H2Conn.read_response (`if status >= 100 && status < 200 {`
// through its matching brace) must reject END_STREAM: it has to mention end_stream
// AND contain `return error` or `reset_stream` (RFC 9113 §8.1).
//
// Usage: detect_h2conn_1xx_end_stream [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_conn.v; $2 is never scanned.
// Exit: 0 clean or SKIP (file/branch missing), 1 bug. Diagnostics go to stderr.
// Quirks preserved: awk-style capture restarts at every matching `if` line; braces
// in comments/strings count; the whitespace-tolerant condition match is by hand.
module main

import os

fn main() {
	file := if os.args.len > 1 { os.args[1] } else { 'vlib/net/http/h2_conn.v' }
	if !os.is_file(file) {
		eprintln('SKIP: ${file} not found')
		exit(0)
	}
	lines := (os.read_lines(file) or { []string{} }).map(it.trim_right('\r'))
	branch := capture_braced(lines, is_1xx_condition)
	if branch.len == 0 {
		eprintln('SKIP: no 1xx interim branch (status >= 100 && status < 200) in ${file}')
		exit(0)
	}
	if branch.any(it.contains('end_stream'))
		&& branch.any(it.contains('return error') || it.contains('reset_stream')) {
		eprintln('OK: the 1xx interim branch rejects END_STREAM before continuing')
		exit(0)
	}
	eprintln('BUG: ${file} 1xx interim branch in read_response does not reject frame.end_stream — a 1xx HEADERS with END_STREAM hangs read_response (mux path rejects it; sync path must too, RFC 9113 §8.1)')
	exit(1)
}

fn skip_ws(l string, p int) int {
	mut i := p
	for i < l.len && (l[i] == ` ` || l[i] == `\t`) {
		i++
	}
	return i
}

// is_1xx_condition mirrors
// `if[[:space:]]+status[[:space:]]*>=[[:space:]]*100[[:space:]]*&&[[:space:]]*status[[:space:]]*<[[:space:]]*200`.
fn is_1xx_condition(l string) bool {
	mut off := 0
	for {
		i := l[off..].index('if') or { return false }
		after_if := off + i + 2
		mut p := skip_ws(l, after_if)
		if p > after_if {
			mut ok := true
			for tok in ['status', '>=', '100', '&&', 'status', '<', '200'] {
				p = skip_ws(l, p)
				if !l[p..].starts_with(tok) {
					ok = false
					break
				}
				p += tok.len
			}
			if ok {
				return true
			}
		}
		off += i + 1
	}
	return false
}

// capture_braced mirrors the awk brace-depth capture used by the .sh.
fn capture_braced(lines []string, start fn (string) bool) []string {
	mut res := []string{}
	mut in_b := false
	mut depth := 0
	for l in lines {
		if start(l) {
			in_b = true
			depth = 0
		}
		if in_b {
			res << l
			for c in l {
				if c == `{` {
					depth++
				} else if c == `}` {
					depth--
					if depth == 0 {
						in_b = false
						break
					}
				}
			}
		}
	}
	return res
}
