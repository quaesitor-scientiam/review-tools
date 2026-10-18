// detect_unsafe_blocks — V port of skills/code-review/detect_unsafe_blocks.sh.
//
// Exits 1 if any given .v/.vv file contains an unsafe{} block (`unsafe` followed
// by optional whitespace and `{`); lists each file and line. Exits 0 otherwise.
//
// Usage: detect_unsafe_blocks <file> [base_copy_or_empty] [file...]
//   run_detectors.sh passes one changed file per call plus the base-revision
//   copy as the second argument, which is never scanned. Further arguments that
//   are existing files are scanned too.
module main

import os

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_unsafe_blocks <file> [base_copy_or_empty] [file...]')
		exit(2)
	}
	mut files := [os.args[1]]
	if os.args.len > 3 {
		files << os.args[3..]
	}
	mut found := 0
	for f in files {
		if f == '' || !os.is_file(f) {
			continue
		}
		lines := os.read_lines(f) or { continue }
		mut hits := []string{}
		for i, raw in lines {
			l := raw.trim_right('\r')
			if has_unsafe_block(l) {
				hits << '  ${i + 1}:${l}'
			}
		}
		if hits.len > 0 {
			println('UNSAFE_BLOCKS: ${f}')
			for h in hits {
				println(h)
			}
			found = 1
		}
	}
	exit(found)
}

// has_unsafe_block reports whether `unsafe` is followed, after optional
// whitespace, by `{` anywhere in the line.
fn has_unsafe_block(l string) bool {
	mut rest := l
	for {
		i := rest.index('unsafe') or { return false }
		mut j := i + 'unsafe'.len
		for j < rest.len && rest[j].is_space() {
			j++
		}
		if j < rest.len && rest[j] == `{` {
			return true
		}
		rest = rest[i + 'unsafe'.len..]
	}
	return false
}
