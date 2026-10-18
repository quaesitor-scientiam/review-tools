// detect_initial_window_recheck — V port of
// skills/code-review/detect_initial_window_recheck.sh.
//
// send_body_on_stream's wmu->fmu recheck block (inner c.fmu.lock() ..
// c.fmu.unlock() nested after c.wmu.lock()) must revalidate s.send_window after
// an INITIAL_WINDOW_SIZE reduction: one of `s.send_window < 0`,
// `s.send_window <= -`, or a line with both `-s.send_window` and `trim`.
//
// State machine: 0 looking for c.wmu.lock(); 1 looking for c.fmu.lock() (a
// c.wmu.unlock() resets to 0, checked after the fmu.lock test on the same line);
// 2 inside the block until c.fmu.unlock(): MISSING if no check was seen.
//
// Quirks preserved: header matches anywhere on the line (`fn ` then later
// `send_body_on_stream`); the function ends at a column-0 `fn `.
//
// Usage: detect_initial_window_recheck [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_mux_conn.v; $2 is never scanned.
// Exit: 0 clean, 1 missing recheck, 2 unreadable.
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
	mut fmu_inner_line := 0
	mut seen_window_check := false
	for i, raw in lines {
		line := raw.trim_right('\r')
		lineno := i + 1
		if is_target_fn(line) {
			in_fn = true
			state = 0
			seen_window_check = false
			continue
		}
		if !in_fn {
			continue
		}
		if line.starts_with('fn ') {
			in_fn = false
			break
		}
		match state {
			0 {
				if line.contains('c.wmu.lock()') {
					state = 1
				}
			}
			1 {
				if line.contains('c.fmu.lock()') {
					state = 2
					fmu_inner_line = lineno
				}
				if line.contains('c.wmu.unlock()') {
					state = 0
				}
			}
			else {
				if line.contains('s.send_window < 0') || line.contains('s.send_window <= -')
					|| (line.contains('-s.send_window') && line.contains('trim')) {
					seen_window_check = true
				}
				if line.contains('c.fmu.unlock()') {
					if !seen_window_check {
						println('MISSING: send_body_on_stream wmu->fmu recheck block (fmu.lock at line ${fmu_inner_line}) does not revalidate s.send_window after INITIAL_WINDOW_SIZE reduction.')
						println('  A peer SETTINGS reducing initial_window_size arrives between the outer fmu.unlock and this fmu.lock;')
						println("  s.send_window goes negative but no trim is applied -> DATA sent exceeds peer's new stream window -> FLOW_CONTROL_ERROR.")
						exit(1)
					}
					state = 0
					seen_window_check = false
				}
			}
		}
	}
	println('OK: s.send_window negativity recheck present in send_body_on_stream wmu->fmu block')
}

// is_target_fn mirrors `"fn ".*"send_body_on_stream"` (unanchored).
fn is_target_fn(line string) bool {
	i := line.index('fn ') or { return false }
	return line[i + 3..].contains('send_body_on_stream')
}
