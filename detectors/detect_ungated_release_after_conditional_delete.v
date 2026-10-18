// detect_ungated_release_after_conditional_delete — V port of
// skills/code-review/detect_ungated_release_after_conditional_delete.sh.
//
// Flags a function where a shared-map `.delete(...)` is guarded by an
// identity/ownership check (`if voidptr(a) == voidptr(b) {`), but a
// resource-release call later in the SAME function (`.release()`,
// `.shutdown_when_idle()`, `.close()`, `.free()`, `.shutdown()`) runs at or
// below the guard's own indent, i.e. outside that guard. Coarse, function-scoped
// heuristic: it enumerates candidates for manual verification.
//
// Quirks preserved from the awk original:
//  - functions are keyed on `^(pub )?fn ` at column 0 and end at a column-0 `}`;
//  - indentation counts leading TABS only;
//  - the `won_x := voidptr(a) == voidptr(b)` capture is anchored at column 0
//    (statements are tab-indented in practice), so a named guard variable is
//    effectively never recognised; only the inline `if voidptr(..) == ..` works.
//
// Usage: detect_ungated_release_after_conditional_delete <file> [base_copy_or_empty]
// Exit: 1 if a candidate is found, 0 if none, 2 on a read error / empty file.
module main

import os

const release_calls = ['.release()', '.shutdown_when_idle()', '.close()', '.free()', '.shutdown()']

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_ungated_release_after_conditional_delete <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or { '' }
	if content.trim_right('\r\n').len == 0 {
		eprintln('detect_ungated_release_after_conditional_delete: cannot read ${file}')
		exit(2)
	}
	lines := content.trim_right('\n').split('\n').map(it.trim_right('\r'))
	println('=== ungated-release-after-conditional-delete detector: ${file} ===')

	mut out := []string{}
	mut infn := false
	mut fname := ''
	mut won_var := ''
	mut in_guard := false
	mut guard_indent := -1
	mut guard_has_delete := false
	mut guard_seen := false
	mut guard_base_indent := -1
	for i, l in lines {
		nr := i + 1
		if l.starts_with('fn ') || l.starts_with('pub fn ') {
			infn = true
			fname = fn_name(l)
			won_var = ''
			in_guard = false
			guard_indent = -1
			guard_has_delete = false
			guard_seen = false
			guard_base_indent = -1
			continue
		}
		if !infn {
			continue
		}
		trimmed := l.trim_left('\t')
		indent := l.len - trimmed.len
		if indent == 0 && trimmed.starts_with('}') {
			infn = false
			continue
		}
		if v := won_capture(l) {
			won_var = v
		}
		mut is_guard_if := false
		if trimmed.starts_with('if ') {
			if has_voidptr_eq(trimmed) {
				is_guard_if = true
			} else if won_var != '' && has_word(trimmed, won_var) {
				is_guard_if = true
			}
		}
		if !in_guard && is_guard_if {
			in_guard = true
			guard_indent = indent
			guard_has_delete = false
			continue
		}
		if in_guard {
			if indent > guard_indent {
				if trimmed.contains('.delete(') {
					guard_has_delete = true
				}
				continue
			}
			in_guard = false
			if guard_has_delete {
				guard_seen = true
				guard_base_indent = guard_indent
			}
		}
		if guard_seen && indent <= guard_base_indent {
			if release_calls.any(trimmed.contains(it)) {
				out << '  ${fname} line ${nr} -- unconditional "${trimmed}" runs after an identity-guarded .delete() earlier in this function; confirm it is gated the same way'
			}
			if trimmed.starts_with('if ') {
				guard_seen = false
			}
		}
	}
	if out.len > 0 {
		println(out.join('\n'))
		println('RESULT: candidate(s) found -- a resource-release call runs unconditionally after an identity-guarded map delete in the same function.')
		exit(1)
	}
	println('RESULT: no ungated release-after-conditional-delete pattern found.')
}

// fn_name mirrors awk `sub(/[ \t]*\{.*/, "", fname)`: cut from the whitespace
// run that precedes the first `{`.
fn fn_name(l string) string {
	k := l.index('{') or { return l }
	mut e := k
	for e > 0 && (l[e - 1] == ` ` || l[e - 1] == `\t`) {
		e--
	}
	return l[..e]
}

// has_voidptr_eq mirrors `voidptr\(.*==.*voidptr\(`.
fn has_voidptr_eq(s string) bool {
	a := s.index('voidptr(') or { return false }
	rest := s[a + 8..]
	b := rest.index('==') or { return false }
	return rest[b + 2..].contains('voidptr(')
}

// won_capture mirrors the column-0 match
// `^([a-zA-Z_][a-zA-Z0-9_]*) := .*voidptr\(.*==.*voidptr\(`.
fn won_capture(l string) ?string {
	if l.len == 0 || !(l[0] == `_` || l[0].is_letter()) {
		return none
	}
	mut e := 1
	for e < l.len && is_word(l[e]) {
		e++
	}
	if !l[e..].starts_with(' := ') {
		return none
	}
	if has_voidptr_eq(l[e + 4..]) {
		return l[..e]
	}
	return none
}

fn is_word(c u8) bool {
	return c == `_` || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
}

// has_word mirrors gawk `\<word\>`.
fn has_word(s string, w string) bool {
	mut from := 0
	for {
		i := s.index_after(w, from) or { return false }
		from = i + 1
		if i > 0 && is_word(s[i - 1]) {
			continue
		}
		e := i + w.len
		if e < s.len && is_word(s[e]) {
			continue
		}
		return true
	}
	return false
}
