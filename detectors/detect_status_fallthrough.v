// detect_status_fallthrough — V port of skills/code-review/detect_status_fallthrough.sh.
//
// State machine over H2Conn.read_response: the `':status'` handler must reach a
// `return error`, and `got_headers = true` must not be reachable while the guard
// has been seen but no error path has.
//   0 = looking for a line containing `fn ` and `read_response`
//   1 = inside read_response (function end = a line made only of `}` characters)
//   2 = inside the ':status' block, tracking brace depth
//
// Usage: detect_status_fallthrough [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_conn.v; $2 is never scanned.
// Exit: 0 OK; 1 FALLTHROUGH / WARN, or the file cannot be read (the .sh runs under
//       `set -e`, so a failing `cat` exits 1, not 2). All output on stdout except
//       the unreadable-file message.
// Quirks preserved: in state 1 the ':status' line switches to state 2 WITHOUT
// counting its own braces (depth starts at 0 on the next line); the
// `got_headers = true` check of state 1 still runs on the line that switched
// state; the function-end check runs before the ':status' check on the same line.
module main

import os

fn main() {
	file := if os.args.len > 1 { os.args[1] } else { 'vlib/net/http/h2_conn.v' }
	raw := os.read_file(file) or {
		eprintln('cat: ${file}: No such file or directory')
		exit(1)
	}
	lines := raw.trim_right('\n').split('\n').map(it.trim_right('\r'))

	mut state := 0
	mut found_guard := false
	mut found_error := false
	mut status_depth := 0
	mut fn_found := false
	mut fn_ok := false

	for idx, line in lines {
		lineno := idx + 1
		match state {
			0 {
				if line.contains('fn ') && line.contains('read_response') {
					state = 1
					fn_found = true
					found_guard = false
					found_error = false
				}
			}
			1 {
				if is_only_braces(line) {
					if found_guard && found_error {
						fn_ok = true
					} else if !found_guard {
						println('WARN: no :status guard found in read_response — lenient .int() parse still in use')
						exit(1)
					}
					state = 0
					found_guard = false
					found_error = false
				}
				if line.contains("':status'") {
					found_guard = true
					state = 2
					status_depth = 0
				}
				if line.contains('got_headers = true') {
					if found_guard && !found_error {
						println('FALLTHROUGH at line ${lineno}: got_headers = true reachable when :status guard rejects value (no error returned)')
						exit(1)
					}
				}
			}
			2 {
				status_depth += line.count('{') - line.count('}')
				if line.contains('return error') {
					found_error = true
				}
				if status_depth < 0 {
					state = 1
					status_depth = 0
				}
				if line.contains('got_headers = true') {
					if found_guard && !found_error {
						println('FALLTHROUGH at line ${lineno}: got_headers = true inside :status block with no error guard')
						exit(1)
					}
				}
			}
			else {}
		}
	}

	if !fn_found {
		println('WARN: read_response not found in ${file}')
		exit(1)
	}
	if !fn_ok {
		println('WARN: read_response found but :status guard or error path incomplete')
		exit(1)
	}
	println('OK: :status fallthrough guarded')
}

// is_only_braces mirrors `^"}" && ! =~ [^}]`: non-empty and every char is `}`.
fn is_only_braces(l string) bool {
	if l.len == 0 {
		return false
	}
	for c in l {
		if c != `}` {
			return false
		}
	}
	return true
}
