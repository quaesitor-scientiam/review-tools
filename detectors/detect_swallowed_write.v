// detect_swallowed_write — V port of skills/code-review/detect_swallowed_write.sh.
//
// Enumerate-and-verify heuristic: flags lines where a write/IO call swallows its
// error with an empty `or {}`. The shell version greps (ERE)
//   (write_all_locked|send_frame|...|note_write_failure)\s*\(.*\)\s+or\s*\{\s*\}
// which is reproduced here with plain scanning (name, optional blanks, `(`, then
// any `)` followed by 1+ blanks, `or`, optional blanks, `{`, optional blanks, `}`).
//
// Usage: detect_swallowed_write <file> [base_copy_or_empty] [file...]
//   The second argument is never scanned; further arguments are extra files.
// Exit: 1 = candidates found, 0 = none, 2 = usage error.
module main

import os

const names = ['write_all_locked', 'send_frame', 'send_window_update', 'send_conn_window_update',
	'send_window_updates', 'send_rst_stream', 'send_ping', 'send_goaway', 'transport.write', 'write_all',
	'note_write_failure']

fn is_ws(c u8) bool {
	return c == ` ` || (c >= 9 && c <= 13)
}

fn skip_ws(s string, from int) int {
	mut i := from
	for i < s.len && is_ws(s[i]) {
		i++
	}
	return i
}

// tail_is_empty_or reports whether s[from..] is `\s+or\s*{\s*}` (prefix match).
fn tail_is_empty_or(s string, from int) bool {
	mut i := skip_ws(s, from)
	if i == from {
		return false
	}
	if i + 2 > s.len || s[i..i + 2] != 'or' {
		return false
	}
	i = skip_ws(s, i + 2)
	if i >= s.len || s[i] != `{` {
		return false
	}
	i = skip_ws(s, i + 1)
	return i < s.len && s[i] == `}`
}

fn line_matches(l string) bool {
	for name in names {
		mut start := 0
		for {
			idx := l.index_after(name, start) or { break }
			start = idx + 1
			p := skip_ws(l, idx + name.len)
			if p >= l.len || l[p] != `(` {
				continue
			}
			// `.*\)`: any later `)` that is followed by the `or {}` tail.
			for j := p + 1; j < l.len; j++ {
				if l[j] == `)` && tail_is_empty_or(l, j + 1) {
					return true
				}
			}
		}
	}
	return false
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_swallowed_write <file> [base_copy_or_empty] [file...]')
		exit(2)
	}
	mut files := [os.args[1]]
	if os.args.len > 3 {
		files << os.args[3..]
	}
	mut found := false
	for f in files {
		lines := os.read_lines(f) or { continue }
		mut hits := []string{}
		for i, raw in lines {
			l := raw.trim_right('\r')
			if line_matches(l) {
				hits << '${i + 1}:${l}'
			}
		}
		if hits.len > 0 {
			println('=== SWALLOWED-WRITE candidates in ${f} ===')
			for h in hits {
				println(h)
			}
			println('')
			println('  For each line above, verify the enclosing function either:')
			println('    (a) calls note_write_failure() / teardown_transport() on the failure path, OR')
			println('    (b) a subsequent operation in the same path always sets shutting_down/closed.')
			println('  A silent or{} is safe ONLY when write failure is benign (e.g., best-effort ping).')
			println('')
			found = true
		}
	}
	if found {
		println('RESULT: review the SWALLOWED-WRITE candidates above.')
		exit(1)
	}
	println('RESULT: no swallowed write operations found.')
}
