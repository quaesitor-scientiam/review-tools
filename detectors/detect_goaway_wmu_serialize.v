// detect_goaway_wmu_serialize — V port of
// skills/code-review/detect_goaway_wmu_serialize.sh.
//
// The H2GoawayFrame handler must set the c.goaway admission flag while holding
// wmu, else it can race the HEADERS write in do_on_stream (RFC 7540 §6.8).
// The arm body is extracted from each line containing `H2GoawayFrame\s*{` until
// the brace depth returns to 0 (every `{`/`}` char counts, strings included; a
// re-match inside the arm resets the depth, as in the awk original).
//
// Exit 1 when the arm sets `c.goaway = true` without `c.wmu.lock()`; 0 when it
// is serialized, or when no arm / no assignment exists (SKIP); 2 if unreadable.
//
// Usage: detect_goaway_wmu_serialize [file] [base_copy_or_empty]
//   file defaults to vlib/net/http/h2_mux_conn.v; $2 is never scanned.
module main

import os

fn main() {
	file := if os.args.len > 1 && os.args[1] != '' {
		os.args[1]
	} else {
		'vlib/net/http/h2_mux_conn.v'
	}
	if !os.is_file(file) {
		eprintln('Usage: detect_goaway_wmu_serialize <v-source-file>')
		exit(2)
	}
	lines := os.read_lines(file) or {
		eprintln('Usage: detect_goaway_wmu_serialize <v-source-file>')
		exit(2)
	}
	mut arm := []string{}
	mut in_arm := false
	mut depth := 0
	for raw in lines {
		l := raw.trim_right('\r')
		if has_goaway_open(l) {
			in_arm = true
			depth = 0
		}
		if !in_arm {
			continue
		}
		arm << l
		for c in l {
			if c == `{` {
				depth++
			} else if c == `}` {
				depth--
				if depth == 0 {
					in_arm = false
					break
				}
			}
		}
	}
	if arm.len == 0 {
		eprintln('SKIP: no H2GoawayFrame arm found in ${file}')
		exit(0)
	}
	if !arm.any(sets_goaway(it)) {
		eprintln('SKIP: H2GoawayFrame arm does not set c.goaway in ${file}')
		exit(0)
	}
	if arm.any(it.contains('c.wmu.lock()')) {
		eprintln('OK: H2GoawayFrame arm serializes on wmu before setting c.goaway')
		exit(0)
	}
	eprintln('BUG: H2GoawayFrame arm in ${file} sets c.goaway without taking c.wmu.lock() — races the HEADERS write in do_on_stream (RFC 7540 §6.8: opens a stream after observing GOAWAY)')
	exit(1)
}

fn is_ws(c u8) bool {
	return c == ` ` || c == `\t` || c == `\v` || c == `\f` || c == `\r` || c == `\n`
}

fn skip_ws(s string, from int) int {
	mut i := from
	for i < s.len && is_ws(s[i]) {
		i++
	}
	return i
}

// has_goaway_open mirrors `H2GoawayFrame[[:space:]]*\{`.
fn has_goaway_open(l string) bool {
	mut from := 0
	for {
		i := l.index_after('H2GoawayFrame', from) or { return false }
		from = i + 1
		j := skip_ws(l, i + 'H2GoawayFrame'.len)
		if j < l.len && l[j] == `{` {
			return true
		}
	}
	return false
}

// sets_goaway mirrors `c\.goaway[[:space:]]*=[[:space:]]*true`.
fn sets_goaway(l string) bool {
	mut from := 0
	for {
		i := l.index_after('c.goaway', from) or { return false }
		from = i + 1
		j := skip_ws(l, i + 'c.goaway'.len)
		if j < l.len && l[j] == `=` {
			k := skip_ws(l, j + 1)
			if l[k..].starts_with('true') {
				return true
			}
		}
	}
	return false
}
