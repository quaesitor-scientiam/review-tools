// detect_idle_cap_counts_busy_conns -- V port of
// skills/code-review/detect_idle_cap_counts_busy_conns.sh.
//
// Contract: inside `fn (mut t Transport) evict_oldest_idle_locked` (matched
// anywhere on a line, brace depth seeded at 1, counting every { and } on a line),
// scan the cap-check section only: stop at the first line containing
// `for k, mut c in t.h2_conns`. Any line in that section containing
// `h2_conns.len` is a BUG. SKIP (exit 0) when the function is absent.
//
// Usage: detect_idle_cap_counts_busy_conns <file> [base_copy_or_empty]  ($2 is never scanned)
// Exit: 1 bug found, 0 clean/SKIP, 2 unreadable (or empty) file.
module main

import os

const fn_marker = 'fn (mut t Transport) evict_oldest_idle_locked'

fn count_char(s string, c u8) int {
	mut n := 0
	for ch in s {
		if ch == c {
			n++
		}
	}
	return n
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_idle_cap_counts_busy_conns <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or { '' }
	if content.trim_right('\n') == '' {
		eprintln('detect_idle_cap_counts_busy_conns: cannot read ${file}')
		exit(2)
	}
	lines := content.trim_right('\n').split('\n').map(it.trim_right('\r'))
	println('=== idle-cap-counts-busy-conns detector: ${file} ===')
	if !lines.any(it.contains(fn_marker)) {
		println('SKIP: no evict_oldest_idle_locked function found in ${file}')
		return
	}
	mut out := []string{}
	mut infn := false
	mut depth := 0
	for l in lines {
		if l.contains(fn_marker) {
			infn = true
			depth = 1
			continue
		}
		if !infn {
			continue
		}
		depth += count_char(l, `{`)
		depth -= count_char(l, `}`)
		if l.contains('for k, mut c in t.h2_conns') {
			infn = false
			continue
		}
		if l.contains('h2_conns.len') {
			out << '  BUG: bare h2_conns.len in cap check (line contains no active_streams filter): ${l}'
		}
		if depth <= 0 {
			infn = false
		}
	}
	if out.len > 0 {
		for o in out {
			println(o)
		}
		println('RESULT: cap check counts ALL h2 connections (busy or idle) instead of filtering to active_streams==0 like the eviction scan does.')
		exit(1)
	}
	println("RESULT: no bare h2_conns.len found in evict_oldest_idle_locked's cap-check section.")
}
