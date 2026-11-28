// detect_in_place_file_write — lists the functions of a V file that create a file
// with `os.create` and publish it under no other name: no `os.rename`, `os.mv` or
// `atomic_replace` in the function. Such a function writes the file a later run
// reads in place, so a process that stops partway (killed, out of memory, an abort,
// a panic) leaves a cut file there, and a write that fails before the end does too
// unless it is removed. vreview Angle B, rev 146: a writer that replaces a file
// another run reads lists "the process stops at each point" among its failures, and
// is compared with a sibling that writes a temp file and renames it.
//
// Missed on graphify a7b43ac (adversarial round of 2026-11-27): save_cache, which had
// built the whole cache and then written it with one os.write_file, began to empty
// the live cache with os.create and write it line by line, so an extract killed while
// it encoded left a cut cache, and load_cache read the cut line back as a file's
// results. save_graph in the same file wrote a temp file and renamed it.
//
// This is an enumerate-and-verify aid: a listed function is a candidate, not a bug.
// A function that creates a temp file its caller renames is listed too; its answer
// names that caller. A test file (`_test.v`) is not scanned.
//
// Usage: detect_in_place_file_write <file> [base_copy_or_empty]
//   The second argument is accepted and never scanned.
// Exit: 1 = at least one function listed; 0 = none or not a V source; 2 = usage error.
module main

import os

const publishers = ['os.rename(', 'os.mv(', 'atomic_replace(']

// code_of joins the lines of a function without their comments and without the text
// of their single-quoted strings, so a call named in a message is not a call.
fn code_of(lines []string) string {
	mut out := []string{}
	for line in lines {
		if line.trim_space().starts_with('//') {
			continue
		}
		mut kept := []u8{}
		mut quoted := false
		for b in line.bytes() {
			if b == `'` {
				quoted = !quoted
			} else if !quoted {
				kept << b
			}
		}
		out << kept.bytestr()
	}
	return out.join('\n')
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_in_place_file_write <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	if !file.ends_with('.v') || file.ends_with('_test.v') {
		println('=== in-place file write detector: ${file} (not a V source, skipping) ===')
		exit(0)
	}
	println('=== in-place file write detector: ${file} ===')
	lines := os.read_lines(file) or {
		eprintln('cannot read ${file}')
		exit(2)
	}
	mut found := 0
	mut i := 0
	for i < lines.len {
		line := lines[i]
		if !line.starts_with('fn ') && !line.starts_with('pub fn ') {
			i++
			continue
		}
		// a top-level function runs to the next line that is a lone `}`, or is one line
		start := i
		mut end := i
		if !line.trim_right(' \t').ends_with('}') {
			end = i + 1
			for end < lines.len && lines[end] != '}' {
				end++
			}
			if end >= lines.len {
				end = lines.len - 1
			}
		}
		body := code_of(lines[start..end + 1])
		if body.contains('os.create(') && !publishers.any(body.contains(it)) {
			mut rest := line.all_after('fn ')
			if rest.starts_with('(') {
				rest = rest.all_after(') ') // a method: skip its receiver
			}
			name := rest.all_before('(').trim_space()
			println('  line ${start + 1}: ${name} creates a file with os.create and renames it nowhere')
			found++
		}
		i = end + 1
	}
	if found == 0 {
		println('RESULT: no function writes a created file in place.')
		exit(0)
	}
	println('RESULT: ${found} function(s) write a created file in place; a process that stops partway leaves it cut. Name for each the caller that renames it, or why a cut file is harmless.')
	exit(1)
}
