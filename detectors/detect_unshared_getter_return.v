// detect_unshared_getter_return — V port of
// skills/code-review/detect_unshared_getter_return.sh.
//
// V's plain array/map assignment shares backing storage, so a public
// parameterless getter whose body is a bare `return r.field` hands the caller an
// alias of the receiver's internal buffer unless the field is a primitive or a
// string. This is an ENUMERATE-AND-VERIFY aid: every such getter with a
// non-primitive return type is a candidate to confirm by hand.
//
// Usage: detect_unshared_getter_return <file> [base_copy_or_empty]
// Exit: 1 if any candidate is found, 0 otherwise, 2 if the file is unreadable.
module main

import os

const primitive_types = ['bool', 'string', 'i8', 'i16', 'int', 'i64', 'u8', 'u16', 'u32', 'u64',
	'f32', 'f64', 'rune', 'byte']

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_unshared_getter_return <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	lines := os.read_lines(file) or {
		println('cannot read ${file}')
		exit(2)
	}
	println('=== unshared-getter-return detector: ${file} ===')
	mut found := 0
	for i, raw in lines {
		sig := raw.trim_right('\r')
		if !is_getter_signature(sig) {
			continue
		}
		if i + 1 >= lines.len {
			continue
		}
		body := lines[i + 1].trim_right('\r')
		rest := bare_field_return(body) or { continue }
		// Return type: everything after the last `) ` up to the trailing ` {`.
		p := sig.last_index(') ') or { continue }
		mut ret_type := sig[p + 2..]
		ret_type = ret_type[..ret_type.len - 2] // strip ' {'
		if ret_type in primitive_types {
			continue
		}
		println("  line ${i + 2}: CANDIDATE -> ${rest}  (getter: ${sig}; return type: ${ret_type}; verify it doesn't alias a []T/map[K]V internal field)")
		found++
	}
	if found > 0 {
		println('FOUND ${found} candidate(s).')
		exit(1)
	}
	println('No candidates found.')
}

fn is_ident_chars(s string) bool {
	for c in s {
		if !(c.is_alnum() || c == `_`) {
			return false
		}
	}
	return true
}

// is_getter_signature matches `pub fn (<recv> &<Type>) <name>() <ret> {` with
// the same shape as the shell regex
// `^pub fn ([A-Za-z0-9_]* &[A-Za-z0-9_]*) [A-Za-z0-9_]*() .* {$`.
fn is_getter_signature(l string) bool {
	if !l.starts_with('pub fn (') || !l.ends_with(' {') {
		return false
	}
	rest := l['pub fn ('.len..]
	close := rest.index(')') or { return false }
	recv := rest[..close]
	amp := recv.index(' &') or { return false }
	if !is_ident_chars(recv[..amp]) || !is_ident_chars(recv[amp + 2..]) {
		return false
	}
	after := rest[close + 1..]
	if !after.starts_with(' ') {
		return false
	}
	named := after[1..]
	p := named.index('() ') or { return false }
	if !is_ident_chars(named[..p]) {
		return false
	}
	// `() ` then anything then ` {` at the end: the remainder must still end
	// with ` {` (so `f() {` with no return type does not match).
	return named[p + 3..].ends_with(' {')
}

// bare_field_return returns `X.Y` when the body line is exactly a tab-indented
// `return X.Y` with one dot and no call, index or further member access.
fn bare_field_return(body string) ?string {
	if !body.starts_with('\treturn ') {
		return none
	}
	rest := body['\treturn '.len..]
	if rest.count('.') != 1 || rest.contains('(') || rest.contains('[') {
		return none
	}
	dot := rest.index('.') or { return none }
	left := rest[..dot]
	right := rest[dot + 1..]
	if left.len == 0 || right.len == 0 {
		return none
	}
	if !(left[0].is_alnum() || left[0] == `_`) || !(right[0].is_alnum() || right[0] == `_`) {
		return none
	}
	return rest
}
