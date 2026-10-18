// detect_close_idle_windows_double_close — V port of
// skills/code-review/detect_close_idle_windows_double_close.sh.
//
// close_idle must call net.close inside its `for handle in handles` loop: on Windows
// net.shutdown alone does not wake a worker blocked in select().
//
// Usage: detect_close_idle_windows_double_close [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/server_tls_idle.v; $2 is never scanned.
// Exit: 0 clean (or SKIP), 1 bug, 2 file not found. Diagnostics go to stderr.
// Quirks preserved: the function is the FIRST line containing `fn` ... `close_idle`
// (not column-0 anchored); the loop is the first `for handle in handles` at/after it;
// the window is exactly 20 lines from the loop line; `net.close` must end on a
// word boundary (so net.closed does not count).
module main

import os

fn main() {
	file := if os.args.len > 1 { os.args[1] } else { 'vlib/net/http/server_tls_idle.v' }
	if !os.is_file(file) {
		eprintln('File not found: ${file}')
		exit(2)
	}
	lines := (os.read_lines(file) or { []string{} }).map(it.trim_right('\r'))

	mut fn_start := -1 // 0-based index
	for i, l in lines {
		if has_in_order(l, ['fn', 'close_idle']) {
			fn_start = i
			break
		}
	}
	if fn_start < 0 {
		eprintln('SKIP: close_idle not found in ${file}')
		exit(0)
	}
	mut loop_idx := -1
	for i in fn_start .. lines.len {
		if lines[i].contains('for handle in handles') {
			loop_idx = i
			break
		}
	}
	if loop_idx < 0 {
		eprintln('SKIP: for loop not found in close_idle')
		exit(0)
	}
	loop_abs := loop_idx + 1
	hi := if loop_idx + 20 > lines.len { lines.len } else { loop_idx + 20 }
	if lines[loop_idx..hi].any(has_net_close_word(it)) {
		eprintln('OK: net.close present in close_idle loop — Windows wakeup intact')
		exit(0)
	}
	eprintln('BUG: close_idle is missing net.close inside its Windows shutdown loop (${file} line ~${loop_abs}) — workers blocked in select() will not be woken on Windows; they will hang until the 41s mbedtls_server_read_timeout_ms expires')
	exit(1)
}

// has_in_order mirrors a grep pattern `a.*b` on one line.
fn has_in_order(l string, parts []string) bool {
	mut pos := 0
	for p in parts {
		i := l[pos..].index(p) or { return false }
		pos += i + p.len
	}
	return true
}

fn is_word_char(c u8) bool {
	return c.is_alnum() || c == `_`
}

// has_net_close_word mirrors grep `net\.close\b`.
fn has_net_close_word(l string) bool {
	mut off := 0
	for {
		i := l[off..].index('net.close') or { return false }
		end := off + i + 'net.close'.len
		if end >= l.len || !is_word_char(l[end]) {
			return true
		}
		off += i + 1
	}
	return false
}
