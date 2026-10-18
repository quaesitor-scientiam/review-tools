// detect_pool_collect_release_clear -- V port of
// skills/code-review/detect_pool_collect_release_clear.sh.
//
// Contract: SKIP (exit 0) unless the file contains `t.mu.unlock()` (word boundary
// before the `t`). For each column-0 `[pub ]fn (<[a-zA-Z_ &]*Transport>)` method
// (depth seeded at 1; header not scanned; new header resets state): note
// `for a, b in t.h1_idle {` / `for a, b in t.h2_conns {` range loops and
// `t.h1_idle.clear()` / `t.h2_conns.clear()` calls. At the FIRST `t.mu.unlock()`
// line (checked once per function, after that line's own loop/clear updates),
// report each ranged pool whose clear() has not been seen yet (h1 first, then h2).
//
// Usage: detect_pool_collect_release_clear <file> [base_copy_or_empty]  ($2 is never scanned)
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

// has_unlock_word reports `t.mu.unlock()` with a word boundary before the `t`.
fn has_unlock_word(line string) bool {
	needle := 't.mu.unlock()'
	mut from := 0
	for {
		i := line.index_after(needle, from) or { return false }
		if i == 0 || !is_word(line[i - 1]) {
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

// word_run returns the length of the leading [A-Za-z_0-9]+ run of s.
fn word_run(s string) int {
	mut n := 0
	for n < s.len && is_word(s[n]) {
		n++
	}
	return n
}

// ranges_over matches `for <id>, <id> in t.<pool>[ ]*{` anywhere in the line.
fn ranges_over(line string, pool string) bool {
	mut from := 0
	for {
		i := line.index_after('for ', from) or { return false }
		from = i + 1
		mut r := line[i + 4..]
		n1 := word_run(r)
		if n1 == 0 || !r[n1..].starts_with(', ') {
			continue
		}
		r = r[n1 + 2..]
		n2 := word_run(r)
		if n2 == 0 {
			continue
		}
		r = r[n2..]
		pre := ' in t.${pool}'
		if !r.starts_with(pre) {
			continue
		}
		r = r[pre.len..].trim_left(' ')
		if r.starts_with('{') {
			return true
		}
	}
	return false
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_pool_collect_release_clear <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or { '' }
	if content.trim_right('\n') == '' {
		eprintln('detect_pool_collect_release_clear: cannot read ${file}')
		exit(2)
	}
	lines := content.trim_right('\n').split('\n').map(it.trim_right('\r'))
	println('=== pool-collect-release-clear detector: ${file} ===')
	if !lines.any(has_unlock_word(it)) {
		println('SKIP: ${file} has no t.mu.unlock() call')
		return
	}
	mut out := []string{}
	mut infn := false
	mut fname := ''
	mut depth := 0
	mut collect_h1 := false
	mut collect_h2 := false
	mut clear_h1 := false
	mut clear_h2 := false
	mut checked := false
	for l in lines {
		if is_transport_header(l) {
			infn = true
			fname = header_name(l)
			depth = 1
			collect_h1 = false
			collect_h2 = false
			clear_h1 = false
			clear_h2 = false
			checked = false
			continue
		}
		if !infn {
			continue
		}
		depth += count_char(l, `{`)
		depth -= count_char(l, `}`)
		if ranges_over(l, 'h1_idle') {
			collect_h1 = true
		}
		if ranges_over(l, 'h2_conns') {
			collect_h2 = true
		}
		if l.contains('t.h1_idle.clear()') {
			clear_h1 = true
		}
		if l.contains('t.h2_conns.clear()') {
			clear_h2 = true
		}
		if !checked && l.contains('t.mu.unlock()') {
			checked = true
			if collect_h1 && !clear_h1 {
				out << '  ${fname} -- ranges over t.h1_idle but never clears it before t.mu.unlock()'
			}
			if collect_h2 && !clear_h2 {
				out << '  ${fname} -- ranges over t.h2_conns but never clears it before t.mu.unlock()'
			}
		}
		if depth <= 0 {
			infn = false
		}
	}
	if out.len > 0 {
		for o in out {
			println(o)
		}
		println('RESULT: candidate(s) found — a function ranges over a pool map for release outside the lock but does not clear that map first. Confirm: can the SAME entry be observed and re-released by a later/concurrent call?')
		exit(1)
	}
	println('RESULT: every function ranging over h1_idle/h2_conns and unlocking t.mu also clears the map it ranged over.')
}
