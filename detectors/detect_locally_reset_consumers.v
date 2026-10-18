// detect_locally_reset_consumers — V port of
// skills/code-review/detect_locally_reset_consumers.sh.
//
// Enumerate-and-verify aid: lists every `in c.locally_reset` / `!in c.locally_reset`
// test outside classify_stream / mark_locally_reset, for a per-consumer audit.
//
// Usage: detect_locally_reset_consumers <file> [base_copy_or_empty]   ($2 never scanned)
// Exit: 1 if any direct check is listed, 0 if none (or the file never mentions
//       locally_reset), 2 if the file is missing/unreadable/empty or no argument.
// Quirks preserved: the "current function" is updated only by lines starting with
// `fn ` at column 0 (so `pub fn` headers do NOT update it) and is cut at the
// whitespace run before the first `{`; it is never reset at function end.
module main

import os

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_locally_reset_consumers.sh <file> [commit]')
		exit(2)
	}
	file := os.args[1]
	raw := os.read_file(file) or { '' }
	if raw.trim_right('\n') == '' {
		eprintln('detect_locally_reset_consumers: cannot read ${file}')
		exit(2)
	}
	lines := raw.split_into_lines().map(it.trim_right('\r'))
	if !lines.any(it.contains('locally_reset')) {
		println('OK: no locally_reset usage in ${file} — nothing to check')
		exit(0)
	}
	println('=== locally_reset direct-consumer audit: ${file} ===')

	mut fname := ''
	mut out := []string{}
	for i, l in lines {
		if l.starts_with('fn ') {
			fname = fn_head(l)
		}
		if l.contains('locally_reset') && !(fname.contains('classify_stream')
			|| fname.contains('mark_locally_reset')) && l.contains('in c.locally_reset') {
			out << '  ${i + 1}: [${fname}] ${l.trim_left(' \t')}'
		}
	}
	if out.len > 0 {
		for o in out {
			println(o)
		}
		println('RESULT: direct locally_reset checks above — confirm each still needs its OWN test, or should route through classify_stream instead.')
		exit(1)
	}
	println('RESULT: every locally_reset check is inside classify_stream/mark_locally_reset.')
}

// fn_head mirrors awk `sub(/[ \t]*\{.*/, "", fname)`: cut at the whitespace run
// that precedes the first `{`.
fn fn_head(l string) string {
	b := l.index('{') or { return l }
	mut e := b
	for e > 0 && (l[e - 1] == ` ` || l[e - 1] == `\t`) {
		e--
	}
	return l[..e]
}
