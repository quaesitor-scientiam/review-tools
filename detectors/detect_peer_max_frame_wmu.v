// detect_peer_max_frame_wmu — V port of skills/code-review/detect_peer_max_frame_wmu.sh.
//
// H2MuxConn.apply_peer_settings must update c.peer_max_frame under wmu (then
// fmu), not fmu-only, so it serializes with the senders that hold wmu across
// their peer_max_frame re-read and the frame write.
//
// Arm = from the first line matching `h2_settings_max_frame_size\s*{` through
// the first following line matching `c.peer_max_frame\s*=\s*st.value` (or EOF).
// Required in the arm: `c.wmu.lock()`.
//
// Usage: detect_peer_max_frame_wmu [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_mux_conn.v; $2 is never scanned.
// Exit: 1 if the arm sets peer_max_frame without wmu; 0 if guarded, or SKIP.
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
	mut arm := []string{}
	mut capture := false
	for raw in lines {
		l := raw.trim_right('\r')
		if is_arm_start(l) {
			capture = true
		}
		if capture {
			arm << l
			if is_assign(l) {
				break
			}
		}
	}
	if arm.len == 0 {
		eprintln('SKIP: could not locate the h2_settings_max_frame_size arm in ${file}')
		exit(0)
	}
	if arm.any(it.contains('c.wmu.lock()')) {
		eprintln('OK: ${file} updates peer_max_frame under wmu (serialized with the send paths)')
		exit(0)
	}
	eprintln('BUG: ${file} sets c.peer_max_frame in the SETTINGS_MAX_FRAME_SIZE arm without holding wmu.')
	eprintln('  Senders hold wmu across their peer_max_frame re-read and the frame write; an fmu-only')
	eprintln('  update can lower the limit in the fmu-release -> write gap, emitting an oversized frame')
	eprintln('  (FRAME_SIZE_ERROR). Take wmu (then fmu) like the header_table_size arm.')
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

// is_arm_start mirrors `h2_settings_max_frame_size[[:space:]]*\{`.
fn is_arm_start(l string) bool {
	mut from := 0
	for {
		i := l.index_after('h2_settings_max_frame_size', from) or { return false }
		from = i + 1
		j := skip_ws(l, i + 'h2_settings_max_frame_size'.len)
		if j < l.len && l[j] == `{` {
			return true
		}
	}
	return false
}

// is_assign mirrors `c\.peer_max_frame[[:space:]]*=[[:space:]]*st\.value`.
fn is_assign(l string) bool {
	mut from := 0
	for {
		i := l.index_after('c.peer_max_frame', from) or { return false }
		from = i + 1
		mut j := skip_ws(l, i + 'c.peer_max_frame'.len)
		if j < l.len && l[j] == `=` {
			j = skip_ws(l, j + 1)
			if l[j..].starts_with('st.value') {
				return true
			}
		}
	}
	return false
}
