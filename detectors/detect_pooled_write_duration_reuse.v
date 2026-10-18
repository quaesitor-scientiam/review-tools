// detect_pooled_write_duration_reuse -- V port of
// skills/code-review/detect_pooled_write_duration_reuse.sh.
//
// Contract: SKIP (exit 0) unless the file contains `ssl.SSLConn`. For each
// COLUMN-0 `fn (mut <[a-zA-Z_]+> <[A-Za-z0-9_]+>) write(` (quirk kept: indented or
// pub headers are not matched), with depth seeded at 1 and header not scanned,
// record the first line with `.set_read_timeout(` and the first with
// `.conn.write(` / `.conn.write_ptr(`. When depth reaches <= 0 report the function
// if a wrapped write exists and no set_read_timeout precedes it (strictly earlier
// line). Line numbers are 1-based file lines.
//
// Usage: detect_pooled_write_duration_reuse <file> [base_copy_or_empty]  ($2 is never scanned)
// Exit: 1 bug found, 0 clean/SKIP, 2 unreadable (or empty) file.
module main

import os

fn count_char(s string, c u8) int {
	mut n := 0
	for ch in s {
		if ch == c {
			n++
		}
	}
	return n
}

// recv_rest matches ^fn \(mut [a-zA-Z_]+ [A-Za-z0-9_]+\) and returns the text after `)`.
fn recv_rest(line string) ?string {
	if !line.starts_with('fn (mut ') {
		return none
	}
	r := line[8..]
	close := r.index(')') or { return none }
	parts := r[..close].split(' ')
	if parts.len != 2 || parts[0].len == 0 || parts[1].len == 0 {
		return none
	}
	for c in parts[0] {
		if !(c.is_letter() || c == `_`) {
			return none
		}
	}
	for c in parts[1] {
		if !(c.is_letter() || c.is_digit() || c == `_`) {
			return none
		}
	}
	return r[close + 1..]
}

// header_name returns the header up to the first `{`, with trailing blanks cut.
fn header_name(l string) string {
	i := l.index('{') or { return l }
	return l[..i].trim_right(' \t')
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_pooled_write_duration_reuse <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or { '' }
	if content.trim_right('\n') == '' {
		eprintln('detect_pooled_write_duration_reuse: cannot read ${file}')
		exit(2)
	}
	lines := content.trim_right('\n').split('\n').map(it.trim_right('\r'))
	println('=== pooled-write-duration-reuse detector: ${file} ===')
	if !lines.any(it.contains('ssl.SSLConn')) {
		println('SKIP: ${file} does not wrap an ssl.SSLConn')
		return
	}
	mut out := []string{}
	mut infn := false
	mut fname := ''
	mut depth := 0
	mut set_timeout_line := 0
	mut write_line := 0
	for i, l in lines {
		nr := i + 1
		if rest := recv_rest(l) {
			if rest.starts_with(' write(') {
				infn = true
				fname = header_name(l)
				depth = 1
				set_timeout_line = 0
				write_line = 0
				continue
			}
		}
		if !infn {
			continue
		}
		depth += count_char(l, `{`)
		depth -= count_char(l, `}`)
		if set_timeout_line == 0 && l.contains('.set_read_timeout(') {
			set_timeout_line = nr
		}
		if write_line == 0 && (l.contains('.conn.write(') || l.contains('.conn.write_ptr(')) {
			write_line = nr
		}
		if depth <= 0 {
			if write_line > 0 && (set_timeout_line == 0 || set_timeout_line > write_line) {
				out << '  ${fname} (wrapped write at line ${write_line}, no preceding set_read_timeout)'
			}
			infn = false
		}
	}
	if out.len > 0 {
		for o in out {
			println(o)
		}
		println("RESULT: write() calls the wrapped conn's write() without first widening its shared duration/read-timeout field to the write-side stall budget — a healthy-but-slow peer will fail at the (much shorter) read-side interval instead.")
		exit(1)
	}
	println("RESULT: no write() function found that skips widening the wrapped conn's duration before writing.")
}
