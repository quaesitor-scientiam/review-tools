// detect_cache_key_environment — a cache key over an external tool's command
// line that leaves out the environment the tool reads.
//
// ENUMERATE-AND-VERIFY aid. A key that names a cached output of a compiler (or
// any tool that searches for files) by its identity and argument vector alone
// selects the old output when only the environment changed: `CPATH`,
// `C_INCLUDE_PATH`, `INCLUDE`, `PATH` (which picks the toolchain and its
// headers), or the working directory a relative `-I` is resolved against.
// Missed on vlang/v#31581 (medvednikov, review 5725704734, comment 4433887205):
// `v3_windows_pch_key(identity, args)` hashed only the compiler identity, the
// header text and the arguments, so a build with `CPATH=sdk2` reused the PCH
// built with `CPATH=sdk1` and emitted `ret i32 101` where a plain compile gave
// `102`. The sibling `v3_include_search` already keyed on the environment.
//
// Flags every function whose name ends in `_key`, `_identity` or `_signature`,
// takes an argument vector (`args []string`, `flags []string`, `*_flags
// []string`, `*_args []string`) and whose body names no environment input:
// `getenv`, `environ`, `environment`, `getwd`. A flagged key may be correct
// (its caller's cache directory already carries the environment, or the tool
// reads none): confirm by naming where each environment input enters the key.
//
// Usage: detect_cache_key_environment <file> [base_copy_or_empty]
// Exit: 1 if any such function is found, 0 if none, 2 on read error.
module main

import os

const env_markers = ['getenv', 'environ', 'environment', 'getwd']

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_cache_key_environment <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or {
		eprintln('detect_cache_key_environment: cannot read ${file}')
		exit(2)
	}
	lines := content.split('\n').map(it.trim_right('\r'))
	println('=== cache-key-environment detector: ${file} ===')
	mut found := []string{}
	mut i := 0
	for i < lines.len {
		l := lines[i]
		if !(l.starts_with('fn ') || l.starts_with('pub fn ')) {
			i++
			continue
		}
		start := i
		name := fn_name(l)
		// The body runs to the first line that is exactly `}`.
		mut end := i + 1
		for end < lines.len && lines[end] != '}' {
			end++
		}
		i = end + 1
		if !is_key_name(name) || !takes_argument_vector(l) {
			continue
		}
		body := lines[start + 1..if end < lines.len { end } else { lines.len }].join('\n')
		if env_markers.any(body.contains(it)) {
			continue
		}
		found << '  ${start + 1}: ${l.trim_right(' {')}'
	}
	if found.len > 0 {
		for f in found {
			println(f)
		}
		println('RESULT: ${found.len} key function(s) over an argument vector name no environment input — confirm the include/search environment (CPATH, C_INCLUDE_PATH, INCLUDE, PATH) and the working directory reach the key, or say where they enter it.')
		exit(1)
	}
	println('RESULT: every key over an argument vector names an environment input (or none found).')
}

// fn_name returns the name of the function a `fn` header line declares,
// skipping a method receiver.
fn fn_name(l string) string {
	mut s := l.trim_string_left('pub ').trim_string_left('fn ')
	if s.starts_with('(') {
		close := s.index(')') or { return '' }
		s = s[close + 1..].trim_left(' ')
	}
	paren := s.index('(') or { return s }
	mut n := s[..paren]
	if lt := n.index('[') {
		n = n[..lt]
	}
	return n
}

fn is_key_name(name string) bool {
	return name.ends_with('_key') || name.ends_with('_identity') || name.ends_with('_signature')
}

// takes_argument_vector reports whether the header declares a parameter that
// holds a command line: `args []string`, `flags []string`, or one ending in
// `_args` / `_flags` of type `[]string`.
fn takes_argument_vector(header string) bool {
	open := header.index('(') or { return false }
	mut params := header[open + 1..]
	// A method's receiver comes first: take the parameter list after the name.
	if header.trim_string_left('pub ').trim_string_left('fn ').starts_with('(') {
		close := params.index(')') or { return false }
		rest := params[close + 1..]
		second := rest.index('(') or { return false }
		params = rest[second + 1..]
	}
	for part in params.split(',') {
		p := part.trim_space()
		sp := p.index(' ') or { continue }
		pname := p[..sp].trim_string_left('mut ')
		ptype := p[sp + 1..].trim_space()
		if !ptype.starts_with('[]string') {
			continue
		}
		if pname in ['args', 'flags'] || pname.ends_with('_args') || pname.ends_with('_flags') {
			return true
		}
	}
	return false
}
