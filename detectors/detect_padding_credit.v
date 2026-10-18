// detect_padding_credit — V port of skills/code-review/detect_padding_credit.sh.
//
// Flags DATA-frame flow-control code that credits the window with data.len
// instead of flow_size.
//   P1 [amount]: a line with send_window_update / conn_recv_window followed later on
//      the same line by `data.len` (word-bounded).
//   P2 [gate]:   the file mentions send_window_update AND has an `if frame.data.len`
//      line (a window update nested in that gate would skip padding-only frames).
// Matching lines are printed grep -n style (`N:line`) before the PADDING-CREDIT line.
//
// Usage: detect_padding_credit <file> [base_copy_or_empty] [file...]
//   The second argument is never scanned; further arguments are extra files.
// Exit: 1 = defect found, 0 = clean, 2 = usage error.
module main

import os

fn is_ws(c u8) bool {
	return c == ` ` || (c >= 9 && c <= 13)
}

fn is_word(c u8) bool {
	return c == `_` || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
}

// word_bounded_at reports whether s[i..i+needle.len] == needle with \b on both ends.
fn word_bounded_at(s string, i int, needle string) bool {
	if i + needle.len > s.len || s[i..i + needle.len] != needle {
		return false
	}
	if i > 0 && is_word(s[i - 1]) {
		return false
	}
	e := i + needle.len
	return e >= s.len || !is_word(s[e])
}

// p1_match: (send_window_update|conn_recv_window).*\bdata\.len\b
fn p1_match(l string) bool {
	for name in ['send_window_update', 'conn_recv_window'] {
		mut start := 0
		for {
			idx := l.index_after(name, start) or { break }
			start = idx + 1
			for j := idx + name.len; j < l.len; j++ {
				if word_bounded_at(l, j, 'data.len') {
					return true
				}
			}
		}
	}
	return false
}

// p2_match: if\s+frame\.data\.len\b
fn p2_match(l string) bool {
	mut start := 0
	for {
		idx := l.index_after('if', start) or { return false }
		start = idx + 1
		mut p := idx + 2
		q := p
		for p < l.len && is_ws(l[p]) {
			p++
		}
		if p == q {
			continue
		}
		needle := 'frame.data.len'
		if p + needle.len <= l.len && l[p..p + needle.len] == needle {
			e := p + needle.len
			if e >= l.len || !is_word(l[e]) {
				return true
			}
		}
	}
	return false
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_padding_credit <file> [base_copy_or_empty] [file...]')
		exit(2)
	}
	mut files := [os.args[1]]
	if os.args.len > 3 {
		files << os.args[3..]
	}
	mut found := false
	for f in files {
		raw_lines := os.read_lines(f) or { continue }
		mut p1 := []string{}
		mut p2 := []string{}
		mut has_swu := false
		for i, raw in raw_lines {
			l := raw.trim_right('\r')
			if l.contains('send_window_update') {
				has_swu = true
			}
			if p1_match(l) {
				p1 << '${i + 1}:${l}'
			}
			if p2_match(l) {
				p2 << '${i + 1}:${l}'
			}
		}
		if p1.len > 0 {
			for h in p1 {
				println(h)
			}
			println('PADDING-CREDIT [P1-amount]: ${f} — data.len used as credit amount (should be flow_size)')
			found = true
		}
		if has_swu && p2.len > 0 {
			for h in p2 {
				println(h)
			}
			println("PADDING-CREDIT [P2-gate]: ${f} — 'if frame.data.len' gate found; confirm send_window_update is NOT nested inside it (padding-only frames would skip credit)")
			found = true
		}
	}
	if found {
		exit(1)
	}
}
