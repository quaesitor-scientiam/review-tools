// detect_headers_max_reread — V port of
// skills/code-review/detect_headers_max_reread.sh.
//
// In send_header_block_locked, peer_max_frame is read once at function entry;
// both the single-frame HEADERS write and the first multi-frame HEADERS write
// need a `c.fmu.lock()` re-read between the entry snapshot's first
// `c.fmu.unlock()` and the write:
//   - STALE [single-frame path]: no fmu.lock() before the 1st `H2HeadersFrame{`
//   - STALE [multi-frame path]:  none between the 1st and 2nd `H2HeadersFrame{`
//
// Quirks preserved: the function header matches anywhere on the line (`fn `
// then later `send_header_block_locked`); the function ends at a column-0 `fn `;
// fewer than two `H2HeadersFrame{` writes is exit 2 (ERROR), not pass/fail.
//
// Usage: detect_headers_max_reread [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_mux_conn.v; $2 is never scanned.
// Exit: 0 clean, 1 stale snapshot, 2 unreadable / structure not found.
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
	mut reads_first := 0
	mut reads_second := 0
	mut headers_count := 0
	mut first_headers_line := 0
	mut second_headers_line := 0
	mut first_unlock_line := 0
	for i, raw in lines {
		line := raw.trim_right('\r')
		lineno := i + 1
		if is_target_fn(line) {
			in_fn = true
			state = 0
			reads_first = 0
			reads_second = 0
			headers_count = 0
			continue
		}
		if !in_fn {
			continue
		}
		if line.starts_with('fn ') {
			in_fn = false
			break
		}
		if state == 0 {
			if line.contains('c.fmu.unlock()') {
				state = 1
				first_unlock_line = lineno
			}
		} else if headers_count == 0 {
			if line.contains('c.fmu.lock()') {
				reads_first++
			}
			if line.contains('H2HeadersFrame{') {
				headers_count = 1
				first_headers_line = lineno
			}
		} else {
			if line.contains('c.fmu.lock()') {
				reads_second++
			}
			if line.contains('H2HeadersFrame{') {
				headers_count = 2
				second_headers_line = lineno
				break
			}
		}
	}
	if headers_count < 2 {
		println('ERROR: could not locate two H2HeadersFrame{ writes in send_header_block_locked (found ${headers_count})')
		exit(2)
	}
	mut exit_code := 0
	if reads_first == 0 {
		println('STALE [single-frame path]: no fmu re-read between first fmu.unlock() (line ${first_unlock_line}) and first H2HeadersFrame{ (line ${first_headers_line}).')
		println('  A peer lowering SETTINGS_MAX_FRAME_SIZE in that window -> oversized single HEADERS the peer rejects with FRAME_SIZE_ERROR.')
		exit_code = 1
	}
	if reads_second == 0 {
		println('STALE [multi-frame path]: no fmu re-read between first H2HeadersFrame{ (line ${first_headers_line}) and second H2HeadersFrame{ (line ${second_headers_line}).')
		println('  A peer lowering SETTINGS_MAX_FRAME_SIZE in that window -> oversized first multi-frame HEADERS the peer rejects.')
		exit_code = 1
	}
	if exit_code == 0 {
		println('OK: fmu re-read present before both single-frame and multi-frame HEADERS writes.')
	}
	exit(exit_code)
}

// is_target_fn mirrors `"fn ".*"send_header_block_locked"` (unanchored).
fn is_target_fn(line string) bool {
	i := line.index('fn ') or { return false }
	return line[i + 3..].contains('send_header_block_locked')
}
