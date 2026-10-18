// detect_malformed_content_length — V port of
// skills/code-review/detect_malformed_content_length.sh.
//
// In H2Conn the 20-line window starting at the first `f.name == 'content-length'`
// line must not use all_digits() as a silent filter: it needs an `else {` branch
// plus a `return error(` somewhere in the window (or no all_digits at all).
//
// Usage: detect_malformed_content_length [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_conn.v; $2 is never scanned.
// Exit: 0 clean (or SKIP when the content-length test is not found), 1 bug,
//       2 file not found. Diagnostics go to stderr like the .sh.
// Quirk preserved: the three window conditions are independent line-level greps,
// not required to be in the same line or block.
module main

import os

fn main() {
	file := if os.args.len > 1 { os.args[1] } else { 'vlib/net/http/h2_conn.v' }
	if !os.is_file(file) {
		eprintln('File not found: ${file}')
		exit(2)
	}
	lines := (os.read_lines(file) or { []string{} }).map(it.trim_right('\r'))
	mut cl := -1
	for i, l in lines {
		if l.contains("f.name == 'content-length'") {
			cl = i
			break
		}
	}
	if cl < 0 {
		eprintln('SKIP: content-length guard not found in ${file}')
		exit(0)
	}
	hi := if cl + 20 > lines.len { lines.len } else { cl + 20 }
	window := lines[cl..hi]
	has_digits := window.any(it.contains('all_digits'))
	if has_digits && window.any(has_else_brace(it)) && window.any(it.contains('return error(')) {
		eprintln('OK: content-length block has all_digits guard + else-error branch')
		exit(0)
	}
	if !has_digits {
		eprintln('OK: no silent all_digits filter on content-length')
		exit(0)
	}
	eprintln('BUG: content-length all_digits guard has no else-error branch (line ${cl + 1} in ${file})')
	exit(1)
}

// has_else_brace mirrors grep -E `else\s*\{`.
fn has_else_brace(l string) bool {
	mut off := 0
	for {
		i := l[off..].index('else') or { return false }
		mut p := off + i + 4
		for p < l.len && l[p].is_space() {
			p++
		}
		if p < l.len && l[p] == `{` {
			return true
		}
		off += i + 1
	}
	return false
}
