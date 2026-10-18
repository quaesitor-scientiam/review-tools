// detect_flag_priority_order — V port of skills/code-review/detect_flag_priority_order.sh.
//
// ENUMERATE-AND-VERIFY aid: lists, in source order, every function containing 2+
// early-return single-field boolean-flag checks (`\tif recv.flag {`), because the
// check ORDER encodes an implicit priority when both flags are true.
//
// Quirks preserved from the awk original: only column-0 `fn ` headers are
// scanned (`pub fn` is invisible, and does not close the previous function); a
// function is flushed at the next `fn ` or a line that is exactly `}`; a final
// function with no closing `}` line is never flushed; the check pattern is
// exactly one leading tab, `[A-Za-z_]+.[a-z_]+`, ` {` and end of line.
//
// Usage: detect_flag_priority_order <file> [base_copy_or_empty]
// Exit: 1 if any function has 2+ such checks, 0 if none, 2 on read error.
module main

import os

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_flag_priority_order <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or { '' }
	if content.trim_right('\r\n').len == 0 {
		eprintln('detect_flag_priority_order: cannot read ${file}')
		exit(2)
	}
	lines := content.trim_right('\n').split('\n').map(it.trim_right('\r'))
	println('=== flag-priority-order detector: ${file} ===')

	mut out := []string{}
	mut fname := ''
	mut in_fn := false
	mut flag_lines := []int{}
	mut flag_names := []string{}
	for i, l in lines {
		if l.starts_with('fn ') {
			if in_fn && flag_lines.len >= 2 {
				flush(mut out, fname, flag_lines, flag_names)
			}
			fname = fn_name(l)
			in_fn = true
			flag_lines = []
			flag_names = []
			continue
		}
		if l == '}' {
			if in_fn && flag_lines.len >= 2 {
				flush(mut out, fname, flag_lines, flag_names)
			}
			in_fn = false
			fname = ''
			flag_lines = []
			flag_names = []
			continue
		}
		if in_fn && is_flag_check(l) {
			flag_lines << i + 1
			flag_names << l.trim_left(' \t')
		}
	}
	// $(...) in the shell version strips trailing newlines, including the blank
	// separator after the last function.
	text := out.join('\n').trim_right('\n')
	if text.len > 0 {
		println(text)
		println('RESULT: functions above have 2+ early-return flag checks — confirm the order is intentional (what happens if both are true?).')
		exit(1)
	}
	println('RESULT: no function with 2+ early-return single-field flag checks found.')
}

fn flush(mut out []string, fname string, flag_lines []int, flag_names []string) {
	out << '  ${fname}'
	for k, ln in flag_lines {
		out << '    ${ln}: ${flag_names[k]}'
	}
	out << ''
}

// fn_name mirrors awk `sub(/[ \t]*\{.*/, "", fname)`.
fn fn_name(l string) string {
	k := l.index('{') or { return l }
	mut e := k
	for e > 0 && (l[e - 1] == ` ` || l[e - 1] == `\t`) {
		e--
	}
	return l[..e]
}

// is_flag_check mirrors `^\tif [a-zA-Z_]+\.[a-z_]+ \{$`.
fn is_flag_check(l string) bool {
	if l.len < 6 || !l.starts_with('\tif ') || !l.ends_with(' {') {
		return false
	}
	mid := l[4..l.len - 2]
	dot := mid.index('.') or { return false }
	a := mid[..dot]
	b := mid[dot + 1..]
	if a.len == 0 || b.len == 0 {
		return false
	}
	for c in a {
		if !(c == `_` || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)) {
			return false
		}
	}
	for c in b {
		if !(c == `_` || (c >= `a` && c <= `z`)) {
			return false
		}
	}
	return true
}
