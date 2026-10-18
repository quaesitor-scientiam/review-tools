// detect_server_window_single_pass — V port of
// skills/code-review/detect_server_window_single_pass.sh.
//
// In H2ServerConn.apply_settings, the h2_settings_initial_window_size arm must
// validate all streams (the `for` loop) BEFORE assigning c.peer.initial_window_size
// (two-pass). Assignment before the loop is the single-pass bug.
//
// Usage: detect_server_window_single_pass [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_server.v; $2 is never scanned.
// Exit: 0 two-pass OK; 1 single-pass (assignment line < first loop line);
//       2 file unreadable, or assignment / loop not found. All output on stdout.
// Quirks preserved: a column-0 `fn ` line ends the scan; the arm ends at the next
// `h2_settings_*` or `else ` line; `c.peer.initial_window_size =` also matches `==`;
// the first assignment line (not containing `i64(`) and the first indented `for `
// line within the arm are used.
module main

import os

fn main() {
	file := if os.args.len > 1 { os.args[1] } else { 'vlib/net/http/h2_server.v' }
	raw := os.read_file(file) or {
		println('ERROR: cannot read ${file}')
		exit(2)
	}
	lines := raw.trim_right('\n').split('\n').map(it.trim_right('\r'))

	mut in_fn := false
	mut in_arm := false
	mut assignment_line := 0
	mut first_loop_line := 0
	for idx, line in lines {
		lineno := idx + 1
		if has_fn_then(line, 'apply_settings') {
			in_fn = true
			in_arm = false
			assignment_line = 0
			first_loop_line = 0
			continue
		}
		if !in_fn {
			continue
		}
		if line.starts_with('fn ') {
			in_fn = false
			break
		}
		if line.contains('h2_settings_initial_window_size') {
			in_arm = true
			continue
		}
		if in_arm {
			t := line.trim_left(' \t\v\f')
			if t.starts_with('h2_settings_') || t.starts_with('else ') {
				in_arm = false
			}
		}
		if !in_arm {
			continue
		}
		if line.contains('c.peer.initial_window_size =') && !line.contains('i64(') {
			if assignment_line == 0 {
				assignment_line = lineno
			}
		}
		if first_loop_line == 0 && line.len > 0 && (line[0] == ` ` || line[0] == `\t`)
			&& line.trim_left(' \t').starts_with('for ') {
			first_loop_line = lineno
		}
	}

	if assignment_line == 0 {
		println('ERROR: could not find c.peer.initial_window_size assignment in apply_settings')
		exit(2)
	}
	if first_loop_line == 0 {
		println('ERROR: could not find for loop in h2_settings_initial_window_size arm')
		exit(2)
	}
	if assignment_line < first_loop_line {
		println('SINGLE-PASS: c.peer.initial_window_size assigned at line ${assignment_line} BEFORE stream loop at line ${first_loop_line}.')
		println('  A delta overflow on stream N leaves streams 1..N-1 with inflated windows and emits PROTOCOL_ERROR instead of FLOW_CONTROL_ERROR.')
		exit(1)
	}
	println('OK: c.peer.initial_window_size assigned after validation loop (two-pass).')
}

// has_fn_then mirrors bash `[[ $line =~ "fn ".*"apply_settings" ]]`.
fn has_fn_then(l string, name string) bool {
	i := l.index('fn ') or { return false }
	return l[i + 3..].contains(name)
}
