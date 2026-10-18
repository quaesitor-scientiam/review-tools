// detect_fmu_scope — V port of skills/code-review/detect_fmu_scope.sh.
//
// Detects `c.fmu.unlock()` appearing before `c.wmu.lock()` + `H2DataFrame{` in
// send_body_on_stream (a TOCTOU window where the reader can process
// SETTINGS_MAX_FRAME_SIZE and send the ACK between chunk sizing and the write).
//
// State machine inside send_body_on_stream: 0 looking for c.fmu.unlock(); 1 saw
// it, looking for c.wmu.lock(); 2 saw that, looking for `H2DataFrame{` (= race).
// A c.fmu.lock() in state 1/2 resets to 0. A line starting with `return` (not
// `return_...`) also resets to 0.
//
// Quirks preserved: the function header matches anywhere on the line (`fn `
// then later `send_body_on_stream`); the function ends only at a column-0 `fn `
// (so a column-0 `pub fn` does not end it).
//
// Usage: detect_fmu_scope [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_mux_conn.v; $2 is never scanned.
// Exit: 0 clean, 1 race detected, 2 unreadable.
module main

import os

fn main() {
	file := if os.args.len > 1 && os.args[1] != '' {
		os.args[1]
	} else {
		'vlib/net/http/h2_mux_conn.v'
	}
	lines := os.read_lines(file) or {
		println('ERROR: cannot read ${file}')
		exit(2)
	}
	mut in_fn := false
	mut state := 0
	mut fmu_line := 0
	mut wmu_line := 0
	for i, raw in lines {
		line := raw.trim_right('\r')
		lineno := i + 1
		if is_target_fn(line) {
			in_fn = true
			state = 0
			continue
		}
		if !in_fn {
			continue
		}
		if line.starts_with('fn ') {
			in_fn = false
			state = 0
			continue
		}
		if is_return(line) {
			state = 0
		}
		match state {
			0 {
				if line.contains('c.fmu.unlock()') {
					state = 1
					fmu_line = lineno
				}
			}
			1 {
				if line.contains('c.fmu.lock()') {
					state = 0
				} else if line.contains('c.wmu.lock()') {
					state = 2
					wmu_line = lineno
				}
			}
			else {
				if line.contains('H2DataFrame{') {
					println('RACE: c.fmu.unlock() at line ${fmu_line} precedes c.wmu.lock() (line ${wmu_line}) before H2DataFrame write')
					println('  peer_max_frame can be updated + SETTINGS ACK sent in that window → oversized DATA frame.')
					exit(1)
				}
				if line.contains('c.fmu.lock()') {
					state = 0
				}
			}
		}
	}
	println('OK: fmu held across DATA write in send_body_on_stream')
}

// is_target_fn mirrors `"fn ".*"send_body_on_stream"` (unanchored).
fn is_target_fn(line string) bool {
	i := line.index('fn ') or { return false }
	return line[i + 3..].contains('send_body_on_stream')
}

// is_return mirrors `^[[:space:]]*"return"([^_]|$)`.
fn is_return(line string) bool {
	t := line.trim_left(' \t\v\f\r\n')
	if !t.starts_with('return') {
		return false
	}
	return t.len == 6 || t[6] != `_`
}
