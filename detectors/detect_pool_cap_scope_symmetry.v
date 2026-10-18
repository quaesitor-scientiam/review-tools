// detect_pool_cap_scope_symmetry -- V port of
// skills/code-review/detect_pool_cap_scope_symmetry.sh.
//
// Contract: SKIP (exit 0) unless the file mentions h1_idle or h2_conns as a word.
// Then for each column-0 `[pub ]fn (<[a-zA-Z_ &]*Transport>)` method (brace depth
// seeded at 1; header line itself not scanned), track whether the body references
// `.max_idle_conns` / `.idle_timeout` (word-ended) and the words h1_idle / h2_conns.
// When depth reaches <= 0: if the cap was referenced but not BOTH pools were
// touched, report the function (header up to the first `{`, trailing blanks cut)
// naming the missing pool. A new header line resets state even mid-function.
//
// Usage: detect_pool_cap_scope_symmetry <file> [base_copy_or_empty]  ($2 is never scanned)
// Exit: 1 candidate found, 0 clean/SKIP, 2 unreadable (or empty) file.
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

fn is_word(c u8) bool {
	return c.is_letter() || c.is_digit() || c == `_`
}

// has_word_at reports whether w occurs in line with a word boundary after it, and
// (when lead is true) also before it. Mirrors gawk \< \> / grep \b.
fn has_word_at(line string, w string, lead bool) bool {
	mut from := 0
	for {
		i := line.index_after(w, from) or { return false }
		e := i + w.len
		lead_ok := !lead || i == 0 || !is_word(line[i - 1])
		trail_ok := e >= line.len || !is_word(line[e])
		if lead_ok && trail_ok {
			return true
		}
		from = i + 1
	}
	return false
}

// is_transport_header matches ^(pub )?fn \([a-zA-Z_ &]*Transport\)
fn is_transport_header(l string) bool {
	mut s := l
	if s.starts_with('pub ') {
		s = s[4..]
	}
	if !s.starts_with('fn (') {
		return false
	}
	r := s[4..]
	close := r.index(')') or { return false }
	inner := r[..close]
	for c in inner {
		if !(c.is_letter() || c == `_` || c == ` ` || c == `&`) {
			return false
		}
	}
	return inner.ends_with('Transport')
}

// header_name returns the header up to the first `{`, with trailing blanks cut.
fn header_name(l string) string {
	i := l.index('{') or { return l }
	return l[..i].trim_right(' \t')
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_pool_cap_scope_symmetry <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or { '' }
	if content.trim_right('\n') == '' {
		eprintln('detect_pool_cap_scope_symmetry: cannot read ${file}')
		exit(2)
	}
	lines := content.trim_right('\n').split('\n').map(it.trim_right('\r'))
	println('=== pool-cap-scope-symmetry detector: ${file} ===')
	if !lines.any(has_word_at(it, 'h1_idle', true) || has_word_at(it, 'h2_conns', true)) {
		println('SKIP: ${file} has no h1_idle/h2_conns pool fields')
		return
	}
	mut out := []string{}
	mut infn := false
	mut fname := ''
	mut depth := 0
	mut refs_cap := false
	mut touches_h1 := false
	mut touches_h2 := false
	for l in lines {
		if is_transport_header(l) {
			infn = true
			fname = header_name(l)
			depth = 1
			refs_cap = false
			touches_h1 = false
			touches_h2 = false
			continue
		}
		if !infn {
			continue
		}
		depth += count_char(l, `{`)
		depth -= count_char(l, `}`)
		if has_word_at(l, '.max_idle_conns', false) || has_word_at(l, '.idle_timeout', false) {
			refs_cap = true
		}
		if has_word_at(l, 'h1_idle', true) {
			touches_h1 = true
		}
		if has_word_at(l, 'h2_conns', true) {
			touches_h2 = true
		}
		if depth <= 0 {
			if refs_cap && !(touches_h1 && touches_h2) {
				missing := if touches_h1 { 'h2_conns' } else { 'h1_idle' }
				out << '  ${fname} -- references a shared cap/lifetime field but never touches ${missing}'
			}
			infn = false
		}
	}
	if out.len > 0 {
		for o in out {
			println(o)
		}
		println('RESULT: candidate(s) found — a function enforcing a shared Transport-wide limit that only acts on one connection pool. Confirm: should this limit apply to the other pool too?')
		exit(1)
	}
	println('RESULT: every function referencing max_idle_conns/idle_timeout touches both h1_idle and h2_conns.')
}
