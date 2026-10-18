// detect_mux_table_size_update — V port of
// skills/code-review/detect_mux_table_size_update.sh.
//
// H2MuxConn.apply_peer_settings must reference encoder.pending_max_table_size so
// a lowered SETTINGS_HEADER_TABLE_SIZE emits a Dynamic Table Size Update at the
// start of the next HEADERS block (RFC 7541 §6.3).
//
// Function = from the FIRST line matching `fn.*apply_peer_settings` through the
// first following line that is exactly `}` (or EOF). Required: the text
// `pending_max_table_size` in that range.
//
// Quirk preserved (see tests/DETECTOR_NOTES.md): a missing file exits 2 while
// sibling detectors SKIP with 0.
//
// Usage: detect_mux_table_size_update [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_mux_conn.v; $2 is never scanned.
// Exit: 1 bug, 0 clean (or SKIP: function not found), 2 file not found.
module main

import os

fn main() {
	file := if os.args.len > 1 && os.args[1] != '' {
		os.args[1]
	} else {
		'vlib/net/http/h2_mux_conn.v'
	}
	if !os.is_file(file) {
		eprintln('File not found: ${file}')
		exit(2)
	}
	lines := os.read_lines(file) or {
		eprintln('File not found: ${file}')
		exit(2)
	}
	mut start := -1
	for i, raw in lines {
		l := raw.trim_right('\r')
		fi := l.index('fn') or { continue }
		if l[fi + 2..].contains('apply_peer_settings') {
			start = i
			break
		}
	}
	if start < 0 {
		eprintln('SKIP: apply_peer_settings not found in ${file}')
		exit(0)
	}
	mut found := false
	for i := start; i < lines.len; i++ {
		l := lines[i].trim_right('\r')
		if l.contains('pending_max_table_size') {
			found = true
		}
		if l == '}' {
			break
		}
	}
	if found {
		eprintln('OK: apply_peer_settings sets encoder.pending_max_table_size')
		exit(0)
	}
	eprintln('BUG: apply_peer_settings in ${file} does not set encoder.pending_max_table_size — RFC 7541 §6.3 requires a Dynamic Table Size Update at the start of the next HEADERS block when peer lowers SETTINGS_HEADER_TABLE_SIZE; H2Conn.apply_settings handles this correctly but the mux path is missing the same update')
	exit(1)
}
