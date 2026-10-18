// detect_missing_fcv_broadcast — V port of
// skills/code-review/detect_missing_fcv_broadcast.sh.
//
// Detects `send_window += excess` in send_body_on_stream without an
// `fcv.broadcast()` before the next `fmu.unlock()`: the excess credit returned
// to the connection window would not wake threads sleeping in fcv.wait().
//
// State machine: 0 looking for a line with both `send_body_on_stream` and `fn `;
// 1 in the function, looking for a line with `send_window +=` and `excess`
// (a line starting with `}` returns to 0); 2 saw the credit, looking for
// `fcv.broadcast()` (-> 1), `fmu.unlock()` (RACE, exit 1) or `}`-line (-> 0).
//
// Quirk preserved: as in the shell version (set -e + `content=$(cat ...)`), an
// unreadable file exits 1, not 2.
//
// Usage: detect_missing_fcv_broadcast [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_mux_conn.v; $2 is never scanned.
// Exit: 0 OK, 1 RACE (or unreadable file).
module main

import os

fn main() {
	file := if os.args.len > 1 && os.args[1] != '' {
		os.args[1]
	} else {
		'vlib/net/http/h2_mux_conn.v'
	}
	lines := os.read_lines(file) or {
		eprintln('cat: ${file}: No such file or directory')
		exit(1)
	}
	mut state := 0
	mut credit_line := 0
	for i, raw in lines {
		line := raw.trim_right('\r')
		lineno := i + 1
		match state {
			0 {
				if line.contains('send_body_on_stream') && line.contains('fn ') {
					state = 1
				}
			}
			1 {
				if line.starts_with('}') {
					state = 0
				} else if line.contains('send_window +=') && line.contains('excess') {
					state = 2
					credit_line = lineno
				}
			}
			else {
				if line.contains('fcv.broadcast()') {
					state = 1
				} else if line.contains('fmu.unlock()') {
					println('RACE at line ${lineno}: send_window credited at line ${credit_line} but no fcv.broadcast() before fmu.unlock()')
					exit(1)
				} else if line.starts_with('}') {
					state = 0
				}
			}
		}
	}
	println('OK: fcv.broadcast() present after every excess credit return')
}
