// detect_lenient_parse — V port of skills/code-review/detect_lenient_parse.sh.
//
// V's string.int()/.u64()/... stop at the first non-digit and return the leading
// number ('200 OK' -> 200, '12junk' -> 12), so a successful parse is NOT input
// validation. Every parse of a wire-derived value must have a local digit/charset
// guard (all_digits / is_digit / .len == / len == N) within three lines.
//
// Usage: detect_lenient_parse <file> [base_copy_or_empty]
// Exit: 1 if any UNGUARDED parse is found, 0 otherwise, 2 if the file is unreadable.
module main

import os

const parse_methods = ['.int()', '.u64()', '.i64()', '.i32()', '.u32()', '.f32()', '.f64()']

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_lenient_parse <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	lines := os.read_lines(file) or {
		println('cannot read ${file}')
		exit(2)
	}
	println('=== lenient-parse detector: ${file} ===')
	mut found := false
	for i, raw in lines {
		l := raw.trim_right('\r')
		// The shell version drops every line containing `//` (comments and
		// anything else on such a line), so this does too.
		if l.contains('//') {
			continue
		}
		if !parse_methods.any(l.contains(it)) {
			continue
		}
		lo := if i - 3 < 0 { 0 } else { i - 3 }
		hi := if i + 3 >= lines.len { lines.len - 1 } else { i + 3 }
		window := lines[lo..hi + 1].join('\n')
		guarded := window.contains('all_digits') || window.contains('is_digit')
			|| window.contains('.len ==') || has_len_eq_digit(window)
		if guarded {
			println('  line ${i + 1}: GUARDED   -> ${l.trim_space()}')
		} else {
			println('  line ${i + 1}: UNGUARDED -> ${l.trim_space()}')
			found = true
		}
	}
	if found {
		println('RESULT: UNGUARDED lenient parse(s) found — add a local digit/charset guard.')
		exit(1)
	}
	println('RESULT: all wire-value parses are locally guarded.')
}

// has_len_eq_digit reports whether `len == ` is directly followed by a digit.
fn has_len_eq_digit(s string) bool {
	mut rest := s
	for {
		i := rest.index('len == ') or { return false }
		j := i + 'len == '.len
		if j < rest.len && rest[j].is_digit() {
			return true
		}
		rest = rest[j..]
	}
	return false
}
