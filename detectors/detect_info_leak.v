// detect_info_leak — V port of skills/code-review/detect_info_leak.sh.
//
// Exits 1 if any given file has log/print calls interpolating sensitive-named
// variables. The shell regex is
//   (eprintln|println|log\.)\s*\(.*\$\{?(token|key|secret|password|nonce|credential)
// Quirk preserved: the `log\.` alternative must be directly followed by `(`
// (i.e. only `log.(`), so `log.info(...)` calls are NOT matched.
//
// Usage: detect_info_leak <file> [base_copy_or_empty] [more files...]
//   The second argument is never scanned; further arguments are extra files.
//   Empty / non-existent arguments are skipped.
// Exit: 1 = leak candidate found, 0 = none, 2 = usage error.
module main

import os

const words = ['token', 'key', 'secret', 'password', 'nonce', 'credential']

fn is_ws(c u8) bool {
	return c == ` ` || (c >= 9 && c <= 13)
}

fn line_matches(l string) bool {
	for name in ['eprintln', 'println', 'log.'] {
		mut start := 0
		for {
			idx := l.index_after(name, start) or { break }
			start = idx + 1
			mut p := idx + name.len
			for p < l.len && is_ws(l[p]) {
				p++
			}
			if p >= l.len || l[p] != `(` {
				continue
			}
			for j := p + 1; j < l.len; j++ {
				if l[j] != `$` {
					continue
				}
				k := j + 1
				if k < l.len && l[k] == `{` {
					// `\{?` is optional: try both with and without the brace.
					if words.any(l[k + 1..].starts_with(it)) {
						return true
					}
				}
				if words.any(l[k..].starts_with(it)) {
					return true
				}
			}
		}
	}
	return false
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_info_leak <file> [base_copy_or_empty] [file...]')
		exit(2)
	}
	mut files := [os.args[1]]
	if os.args.len > 3 {
		files << os.args[3..]
	}
	mut found := false
	for f in files {
		if f == '' || !os.is_file(f) {
			continue
		}
		lines := os.read_lines(f) or { continue }
		mut hits := []string{}
		for i, raw in lines {
			l := raw.trim_right('\r')
			if line_matches(l) {
				hits << '  ${i + 1}:${l}'
			}
		}
		if hits.len > 0 {
			println('INFO_LEAK: ${f}')
			for h in hits {
				println(h)
			}
			found = true
		}
	}
	if found {
		exit(1)
	}
}
