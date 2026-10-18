// detect_tls_read_precheck_poll -- V port of
// skills/code-review/detect_tls_read_precheck_poll.sh.
//
// Contract: SKIP (exit 0) unless the file contains `ssl.SSLConn`. For each
// COLUMN-0 `fn (mut <id> <Type>) read(mut <id> []u8) !int {` header (quirk kept:
// indented/pub headers are not matched), record the first line with
// `.wait_for_read(` and the first with `.conn.read(` until a line that is exactly
// `}` (column 0; trailing \r trimmed here). At that line report the function when
// an outer poll exists and is strictly before the wrapped read (or no wrapped read
// exists). Per line, the poll is recorded before the read, so a same-line pair is
// not flagged. Line numbers are 1-based file lines.
//
// Usage: detect_tls_read_precheck_poll <file> [base_copy_or_empty]  ($2 is never scanned)
// Exit: 1 bug found, 0 clean/SKIP, 2 unreadable (or empty) file.
module main

import os

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

// is_read_header matches the rest after the receiver: ` read(mut <[a-zA-Z_]+> []u8) !int {`.
fn is_read_header(rest string) bool {
	pre := ' read(mut '
	if !rest.starts_with(pre) {
		return false
	}
	r := rest[pre.len..]
	mut n := 0
	for n < r.len && (r[n].is_letter() || r[n] == `_`) {
		n++
	}
	return n > 0 && r[n..].starts_with(' []u8) !int {')
}

// header_name returns the header up to the first `{`, with trailing blanks cut.
fn header_name(l string) string {
	i := l.index('{') or { return l }
	return l[..i].trim_right(' \t')
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_tls_read_precheck_poll <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or { '' }
	if content.trim_right('\n') == '' {
		eprintln('detect_tls_read_precheck_poll: cannot read ${file}')
		exit(2)
	}
	lines := content.trim_right('\n').split('\n').map(it.trim_right('\r'))
	println('=== tls-read-precheck-poll detector: ${file} ===')
	if !lines.any(it.contains('ssl.SSLConn')) {
		println('SKIP: ${file} does not wrap an ssl.SSLConn')
		return
	}
	mut out := []string{}
	mut infn := false
	mut fname := ''
	mut wait_line := 0
	mut read_line := 0
	for i, l in lines {
		nr := i + 1
		if rest := recv_rest(l) {
			if is_read_header(rest) {
				infn = true
				fname = header_name(l)
				wait_line = 0
				read_line = 0
				continue
			}
		}
		if infn && l == '}' {
			if wait_line > 0 && (read_line == 0 || wait_line < read_line) {
				out << '  ${fname} (outer poll at line ${wait_line})'
			}
			infn = false
			continue
		}
		if infn && wait_line == 0 && l.contains('.wait_for_read(') {
			wait_line = nr
		}
		if infn && read_line == 0 && l.contains('.conn.read(') {
			read_line = nr
		}
	}
	if out.len > 0 {
		for o in out {
			println(o)
		}
		println("RESULT: outer wait_for_read() runs before the wrapped conn.read() call — remove it and let the wrapped read()'s own internal WANT_READ retry (bounded by its read_timeout) drive the wait instead.")
		exit(1)
	}
	println('RESULT: no pre-read outer poll found before the wrapped conn.read() call.')
}
