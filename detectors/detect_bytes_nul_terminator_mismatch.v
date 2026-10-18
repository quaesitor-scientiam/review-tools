// detect_bytes_nul_terminator_mismatch — V port of
// skills/code-review/detect_bytes_nul_terminator_mismatch.sh.
//
// mbedtls_x509_crt_parse/mbedtls_pk_parse_key's PEM path needs a REAL
// NUL-terminated buffer. `<string>.bytes()` allocates a fresh []u8 of exactly
// `.len` bytes with NO trailing NUL, so combining it with a manual `+ 1` on the
// length passed to a parse call reads one byte past the allocation. Use
// `<string>.str` instead.
//
// Flags every `<var> := <expr>.bytes()` (lines containing `//` are skipped) that
// is followed, within the same line and the next 5 lines, by `<var>.len + 1`,
// `<var>_len.len + 1` or `<var>_len := <var>.len + 1`.
//
// Quirk preserved: the window end is clamped to the file's newline count (as
// `wc -l` reports it), so an unterminated last line past that count is not seen
// unless the window starts on it.
//
// Usage: detect_bytes_nul_terminator_mismatch <file> [base_copy_or_empty]
// Exit: 1 if any mismatch is found, 0 otherwise, 2 if the file is unreadable.
module main

import os

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_bytes_nul_terminator_mismatch <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or {
		println('cannot read ${file}')
		exit(2)
	}
	mut lines := content.split('\n').map(it.trim_right('\r'))
	if content.ends_with('\n') {
		lines.delete_last()
	}
	total_lines := content.count('\n')
	println('=== .bytes()+NUL-terminator-mismatch detector: ${file} ===')
	mut found := false
	for i, l in lines {
		if !l.contains('.bytes()') || l.contains('//') {
			continue
		}
		v := bytes_decl_var(l)
		if v == '' {
			continue
		}
		ln := i + 1
		mut hi := ln + 5
		if hi > total_lines {
			hi = total_lines
		}
		mut mismatch := false
		for k := ln; k <= hi && k <= lines.len; k++ {
			if has_plus_one(lines[k - 1], v) {
				mismatch = true
				break
			}
		}
		if mismatch {
			println("  line ${ln}: MISMATCH  -> '${v} := ...bytes()' followed by a manual +1 length (no real NUL byte exists)")
			found = true
		} else {
			println("  line ${ln}: OK        -> '${v} := ...bytes()', no manual +1 length nearby")
		}
	}
	if found {
		println('RESULT: .bytes()-derived buffer used with a manual +1 length -- heap-buffer-overflow (use .str instead).')
		exit(1)
	}
	println('RESULT: no .bytes()+manual-NUL-terminator mismatch found.')
}

fn is_word(c u8) bool {
	return c == `_` || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
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

// bytes_decl_var returns the variable of `^\s*(mut\s+)?<ident>\s*:=.*\.bytes\(\)`,
// or '' when the line has no such declaration.
fn bytes_decl_var(l string) string {
	start := skip_ws(l, 0)
	if l[start..].starts_with('mut') && start + 3 < l.len && is_ws(l[start + 3]) {
		v := ident_decl(l, skip_ws(l, start + 3))
		if v != '' {
			return v
		}
	}
	return ident_decl(l, start)
}

// ident_decl parses `<ident>\s*:=` at `pos` and requires `.bytes()` afterwards.
fn ident_decl(l string, pos int) string {
	if pos >= l.len || !(l[pos] == `_` || l[pos].is_letter()) {
		return ''
	}
	mut e := pos
	for e < l.len && is_word(l[e]) {
		e++
	}
	j := skip_ws(l, e)
	if !l[j..].starts_with(':=') {
		return ''
	}
	if !l[j + 2..].contains('.bytes()') {
		return ''
	}
	return l[pos..e]
}

// plus_one_at matches `\s*\+\s*1\b` at `pos`.
fn plus_one_at(s string, pos int) bool {
	mut j := skip_ws(s, pos)
	if j >= s.len || s[j] != `+` {
		return false
	}
	j = skip_ws(s, j + 1)
	if j >= s.len || s[j] != `1` {
		return false
	}
	return j + 1 >= s.len || !is_word(s[j + 1])
}

// len_plus_one_at matches `.len\s*\+\s*1\b` at `pos`.
fn len_plus_one_at(s string, pos int) bool {
	if !s[pos..].starts_with('.len') {
		return false
	}
	return plus_one_at(s, pos + 4)
}

// has_plus_one reports whether the line matches
// `\b<v>(_len)?\.len\s*\+\s*1\b` or `\b<v>_len\s*:=\s*<v>\.len\s*\+\s*1\b`.
fn has_plus_one(l string, v string) bool {
	mut from := 0
	for {
		i := l.index_after(v, from) or { return false }
		from = i + 1
		if i > 0 && is_word(l[i - 1]) {
			continue
		}
		j := i + v.len
		if len_plus_one_at(l, j) {
			return true
		}
		if l[j..].starts_with('_len') {
			if len_plus_one_at(l, j + 4) {
				return true
			}
			k := skip_ws(l, j + 4)
			if l[k..].starts_with(':=') {
				m := skip_ws(l, k + 2)
				if l[m..].starts_with(v) && len_plus_one_at(l, m + v.len) {
					return true
				}
			}
		}
	}
	return false
}
