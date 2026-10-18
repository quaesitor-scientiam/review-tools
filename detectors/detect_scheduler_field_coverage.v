// detect_scheduler_field_coverage — V port of
// skills/code-review/detect_scheduler_field_coverage.sh.
//
// Flags an Option-typed (`?T`) struct field whose name contains "deadline" or
// "timeout" that the struct's central scheduler function
// (compute_next_timeout / next_timeout / next_deadline) never references.
// Bug class: vlang/v#28083 (QuicConn.closing_deadline never merged into
// compute_next_timeout()).
//
// Usage:
//   detect_scheduler_field_coverage <file> [base_copy_or_empty]
//     auto-detect mode (what run_detectors.sh calls): finds the aggregator fn and
//     infers its receiver struct.
//   detect_scheduler_field_coverage <file> <struct_name> <fn_name> [base_copy]
//     explicit mode, for Phase-R testing against a specific struct/fn pair.
// Exit: 1 if a candidate field is found; 0 if every field is referenced or no
//       aggregator/struct is found (SKIP); 2 on a read error.
module main

import os

const aggregator_names = ['compute_next_timeout', 'next_timeout', 'next_deadline']

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_scheduler_field_coverage <file> [struct_name fn_name] [base_copy]')
		exit(2)
	}
	file := os.args[1]
	mut struct_name := ''
	mut fn_name := ''
	if os.args.len - 1 >= 3 {
		struct_name = os.args[2]
		fn_name = os.args[3]
	}
	raw := os.read_lines(file) or { []string{} }
	lines := raw.map(it.trim_right('\r'))
	if lines.len == 0 {
		eprintln('detect_scheduler_field_coverage: cannot read ${file}')
		exit(2)
	}

	if fn_name == '' {
		sig := lines.filter(is_aggregator_signature(it))
		if sig.len == 0 {
			println('SKIP: no compute_next_timeout/next_timeout/next_deadline-style aggregator found in ${file}')
			exit(0)
		}
		fn_name = first_aggregator_name(sig[0])
		receiver := receiver_text(sig[0])
		parts := receiver.split_any(' \t').filter(it != '')
		struct_name = if parts.len > 0 { parts.last().replace('&', '') } else { '' }
		if struct_name == '' {
			println('SKIP: could not determine receiver struct for ${fn_name} in ${file}')
			exit(0)
		}
	}
	println('=== scheduler-field-coverage detector: ${file} — struct ${struct_name}, fn ${fn_name} ===')

	struct_body := struct_lines(lines, struct_name)
	if struct_body.len == 0 {
		println('SKIP: struct ${struct_name} not found in ${file}')
		exit(0)
	}
	fn_body := fn_lines(lines, fn_name).join('\n')
	if fn_body.len == 0 {
		println('SKIP: fn ${fn_name} not found in ${file}')
		exit(0)
	}

	mut missing := false
	for field in option_deadline_fields(struct_body) {
		if !has_word(fn_body, field) {
			println("CANDIDATE: optional field '${field}' on ${struct_name} is never referenced in ${fn_name}()")
			missing = true
		}
	}
	if missing {
		exit(1)
	}
	println('OK: every optional field on ${struct_name} is referenced in ${fn_name}()')
}

fn is_ident_char(c u8) bool {
	return c.is_alnum() || c == `_`
}

// is_aggregator_signature mirrors
// `^(pub )?fn \([a-zA-Z_ &*]+\) *(compute_next_timeout|next_timeout|next_deadline)\(`.
fn is_aggregator_signature(l string) bool {
	mut rest := l
	if rest.starts_with('pub ') {
		rest = rest[4..]
	}
	if !rest.starts_with('fn (') {
		return false
	}
	rest = rest[4..]
	close := rest.index(')') or { return false }
	recv := rest[..close]
	if recv.len == 0 {
		return false
	}
	for c in recv {
		if !(c.is_letter() || c == `_` || c == ` ` || c == `&` || c == `*`) {
			return false
		}
	}
	mut after := rest[close + 1..]
	after = after.trim_left(' ')
	for name in aggregator_names {
		if after.starts_with(name + '(') {
			return true
		}
	}
	return false
}

// first_aggregator_name returns the leftmost aggregator name occurring in the line.
fn first_aggregator_name(l string) string {
	for i := 0; i < l.len; i++ {
		for name in aggregator_names {
			if l[i..].starts_with(name) {
				return name
			}
		}
	}
	return ''
}

// receiver_text returns the text inside the first parenthesised group.
fn receiver_text(l string) string {
	open := l.index('(') or { return '' }
	close := l.index(')') or { return '' }
	if close <= open {
		return ''
	}
	return l[open + 1..close]
}

// struct_lines returns the lines from `struct <name>` (followed by a space, `{`
// or end of line) through the first line that starts with `}`.
fn struct_lines(lines []string, name string) []string {
	mut res := []string{}
	mut inside := false
	for l in lines {
		if !inside {
			needle := 'struct ${name}'
			i := l.index(needle) or { -1 }
			if i < 0 {
				continue
			}
			end := i + needle.len
			if end < l.len && l[end] != ` ` && l[end] != `{` {
				continue
			}
			inside = true
		}
		res << l
		if l.starts_with('}') {
			break
		}
	}
	return res
}

// fn_lines returns the aggregator function's lines: the header matching
// `fn .*\)[ \t]*<name>\(` (counted as depth 1 without scanning its braces, like
// the awk original) and following lines until the brace depth returns to zero.
fn fn_lines(lines []string, name string) []string {
	mut res := []string{}
	mut depth := 0
	mut inside := false
	for l in lines {
		if !inside {
			if !is_fn_header(l, name) {
				continue
			}
			inside = true
			depth = 1
			res << l
			continue
		}
		res << l
		depth += l.count('{')
		depth -= l.count('}')
		if depth <= 0 {
			break
		}
	}
	return res
}

fn is_fn_header(l string, name string) bool {
	fn_pos := l.index('fn ') or { return false }
	needle := name + '('
	mut rest := l[fn_pos..]
	mut off := fn_pos
	for {
		i := rest.index(needle) or { return false }
		// walk back over spaces/tabs; the previous char must be `)`
		mut k := off + i - 1
		for k >= 0 && (l[k] == ` ` || l[k] == `\t`) {
			k--
		}
		if k > fn_pos && l[k] == `)` {
			return true
		}
		rest = rest[i + 1..]
		off += i + 1
	}
	return false
}

// option_deadline_fields lists struct fields declared as `<name> ?<T>` whose
// name contains deadline or timeout (case-insensitive).
fn option_deadline_fields(body []string) []string {
	mut res := []string{}
	for l in body {
		t := l.trim_left(' \t')
		if t.len == 0 || !(t[0].is_letter() || t[0] == `_`) {
			continue
		}
		mut j := 0
		for j < t.len && is_ident_char(t[j]) {
			j++
		}
		name := t[..j]
		mut k := j
		for k < t.len && (t[k] == ` ` || t[k] == `\t`) {
			k++
		}
		if k == j || k >= t.len || t[k] != `?` {
			continue
		}
		low := name.to_lower()
		if low.contains('deadline') || low.contains('timeout') {
			res << name
		}
	}
	return res
}

// has_word reports whether `w` occurs in `s` bounded by non-word characters.
fn has_word(s string, w string) bool {
	mut rest := s
	mut off := 0
	for {
		i := rest.index(w) or { return false }
		start := off + i
		end := start + w.len
		before_ok := start == 0 || !is_ident_char(s[start - 1])
		after_ok := end >= s.len || !is_ident_char(s[end])
		if before_ok && after_ok {
			return true
		}
		rest = rest[i + 1..]
		off += i + 1
	}
	return false
}
