// detect_look_then_recursive_remove -- flags a function that opens a folder to act through its
// handle, yet lets an earlier look at the filesystem choose a recursive removal by name.
//
// Contract: in each top-level `fn` of the file, find
//   - looks: calls of `os.is_dir(`, `os.is_link(`, `os.is_file(`, `os.exists(`, `os.lstat(`,
//     `os.stat(`, or `.item(` (a look at a name through a folder handle);
//   - opens: calls whose name starts with `open` and contains `dir` or `folder`; a variable
//     assigned from one (`x := ...open...(`) is a handle this function opened;
//   - recursive removals: `.remove_tree(`, `rmdir_all(`, `rmdir_all_settling(`, or a call of a
//     function of this file that makes one, directly or through other functions of this file.
// A recursive removal is flagged when the function makes an open, a look comes before the removal
// in the function, and the removal goes through no handle this function opened (neither its
// receiver nor its first argument is one). That is the shape of vlang/v#31848 (2026-11-14): the
// wipe opened the folders it protects through a handle, but an `lstat`-style look decided first,
// and a name seen as missing or as a link was then removed whole by name, after a build had put a
// new folder there. Removals through the opened handle decide from what was opened and pass.
// Comment lines are skipped. Each hit prints `  <file>:<look line>-><removal line>: fn <name>: ...`.
//
// Usage: detect_look_then_recursive_remove <file> [base_copy_or_empty]  ($2 is never scanned)
// Exit: 1 flagged, 0 clean, 2 unreadable (or empty) file.
module main

import os

const look_calls = ['os.is_dir(', 'os.is_link(', 'os.is_file(', 'os.exists(', 'os.lstat(', 'os.stat(',
	'.item(']
const recursive_primitives = ['.remove_tree(', 'rmdir_all(', 'rmdir_all_settling(']

struct Func {
	name  string
	start int // index of the `fn` line
	end   int // index of the closing `}` line
}

fn is_ident_char(c u8) bool {
	return c.is_letter() || c.is_digit() || c == `_`
}

// fn_name returns the name declared on a top-level `fn` line, or '' when the line declares none.
fn fn_name(line string) string {
	mut rest := line
	if rest.starts_with('pub ') {
		rest = rest[4..]
	}
	if !rest.starts_with('fn ') {
		return ''
	}
	rest = rest[3..].trim_left(' ')
	if rest.starts_with('(') {
		close := rest.index(')') or { return '' }
		rest = rest[close + 1..].trim_left(' ')
	}
	mut n := 0
	for n < rest.len && is_ident_char(rest[n]) {
		n++
	}
	if n == 0 || n >= rest.len || rest[n] !in [`(`, `[`] {
		return ''
	}
	return rest[..n]
}

// code_of returns '' for a line that is a `//` comment, and any other line as it is (a comment after
// code is kept, so a call named only there still counts).
fn code_of(line string) string {
	trimmed := line.trim_space()
	if trimmed.starts_with('//') {
		return ''
	}
	return line
}

// calls reports whether `code` calls the function `name` (not a longer name that ends with it).
fn calls(code string, name string) bool {
	mut from := 0
	for {
		at := code.index_after(name + '(', from) or { return false }
		if at == 0 || !is_ident_char(code[at - 1]) {
			return true
		}
		from = at + 1
	}
	return false
}

// open_var returns the variable a line assigns from an open call, or ''.
fn open_var(code string) string {
	at := code.index(':=') or { return '' }
	left := code[..at].trim_space().trim_string_left('mut ').trim_space()
	if left == '' || !left.bytes().all(is_ident_char(it)) {
		return ''
	}
	if is_open_call(code[at..]) {
		return left
	}
	return ''
}

// is_open_call reports whether `code` calls a function whose name starts with `open` and holds
// `dir` or `folder`.
fn is_open_call(code string) bool {
	mut from := 0
	for {
		at := code.index_after('open', from) or { return false }
		from = at + 1
		if at > 0 && is_ident_char(code[at - 1]) {
			continue
		}
		mut end := at
		for end < code.len && is_ident_char(code[end]) {
			end++
		}
		if end < code.len && code[end] == `(` {
			ident := code[at..end]
			if ident.contains('dir') || ident.contains('folder') {
				return true
			}
		}
	}
	return false
}

// through_opened reports whether the call `name(` on the line goes through one of `opened`: as the
// receiver (`h.name(`) or as the first argument (`name(h, ...` / `name(h)`).
fn through_opened(code string, name string, opened []string) bool {
	at := code.index(name + '(') or { return false }
	before := code[..at]
	for h in opened {
		if before.ends_with('${h}.') {
			return true
		}
		args := code[at + name.len + 1..].trim_left(' ')
		if args.starts_with('${h},') || args.starts_with('${h})') {
			return true
		}
	}
	return false
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_look_then_recursive_remove <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or { '' }
	if content.trim_right('\n') == '' {
		eprintln('detect_look_then_recursive_remove: could not read ${file}')
		exit(2)
	}
	lines := content.trim_right('\n').split('\n').map(it.trim_right('\r'))
	mut funcs := []Func{}
	for i, line in lines {
		name := fn_name(line)
		if name == '' {
			continue
		}
		mut end := i
		for j in i + 1 .. lines.len {
			if lines[j] == '}' {
				end = j
				break
			}
		}
		if line.trim_right(' ').ends_with('}') {
			end = i
		}
		funcs << Func{name, i, end}
	}
	// The functions of this file that remove recursively, directly or through each other.
	mut recursive := map[string]bool{}
	mut changed := true
	for changed {
		changed = false
		for f in funcs {
			if recursive[f.name] {
				continue
			}
			for k in f.start + 1 .. f.end {
				code := code_of(lines[k])
				if code == '' {
					continue
				}
				mut hit := recursive_primitives.any(code.contains(it))
				if !hit {
					for name, _ in recursive {
						if name != f.name && calls(code, name) {
							hit = true
							break
						}
					}
				}
				if hit {
					recursive[f.name] = true
					changed = true
					break
				}
			}
		}
	}
	mut hits := []string{}
	for f in funcs {
		mut opens := false
		mut opened := []string{}
		for k in f.start + 1 .. f.end {
			code := code_of(lines[k])
			if code != '' && is_open_call(code) {
				opens = true
				v := open_var(code)
				if v != '' {
					opened << v
				}
			}
		}
		if !opens {
			continue
		}
		mut first_look := -1
		for k in f.start + 1 .. f.end {
			code := code_of(lines[k])
			if code == '' {
				continue
			}
			if first_look < 0 && look_calls.any(code.contains(it)) {
				first_look = k
				// A look and a removal on one line: the look still came first.
			}
			if first_look < 0 {
				continue
			}
			mut removal := ''
			for p in recursive_primitives {
				if code.contains(p) {
					removal = p.trim_left('.').trim_right('(')
				}
			}
			if removal == '' {
				for name, _ in recursive {
					if name != f.name && calls(code, name) {
						removal = name
						break
					}
				}
			}
			if removal == '' || through_opened(code, removal, opened) {
				continue
			}
			hits << '  ${file}:${first_look + 1}->${k + 1}: fn ${f.name}: the look on line ${first_look + 1} (`${lines[first_look].trim_space()}`) comes before `${removal}` on line ${k + 1}, which removes by name, not through a folder this function opened'
		}
	}
	if hits.len > 0 {
		println("CANDIDATE: a look at the filesystem decides a recursive removal by name, in a function that otherwise acts through a folder it opened; decide from the opened folder instead, or give the pair a Matrix 3 read row with every writer of that path (the program's own first):")
		for h in hits {
			println(h)
		}
		exit(1)
	}
	println('OK: no look-then-recursive-removal by name in a function that opens folders in ${file}')
}
