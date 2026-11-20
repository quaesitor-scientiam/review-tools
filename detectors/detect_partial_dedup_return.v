// detect_partial_dedup_return — flags an "already applied" early return that
// decides a message is a repeat by comparing SOME of its fields, while code
// after that return still acts on OTHER fields of the same message.
//
// Bug class: vlang/v#31596 (maintainer review issuecomment-7044756405).
// handle_new_connection_id_frame returned early for a NEW_CONNECTION_ID whose
// sequence number, connection ID and token matched a known entry ("a
// retransmission of a frame already applied"), so the frame's fourth field,
// Retire Prior To, was never applied. RFC 9000 §19.15 ignores only a Retire
// Prior To that does not increase; an increase carried by an otherwise
// identical frame must still retire the older connection IDs.
//
// Shape detected, per function and per struct-typed parameter P:
//   - a success-path `return` (bare, or `return none`), not `return error...`,
//   - that is the only statement of an `if` whose condition compares a field
//     of P with `==` against a field or index of another variable, a stored
//     entry (the block does nothing but declare the message already handled;
//     a branch that first does work with P and then returns, or a guard
//     against a literal or enum value such as `p.len == 0`, is not this
//     shape),
//   - and, after that `if` block closes, the function still reads a field of P
//     that neither that condition nor any enclosing `if` condition mentions.
// Each hit is a candidate to verify: the skipped field must either be part of
// the identity being compared, or still be applied on the early-return path.
//
// Usage: detect_partial_dedup_return <file>
// Exit: 1 if a candidate is found; 0 if none; 2 on a read error.
module main

import os

struct Block {
	start  int // line index of the `if` header
	header string
	depth  int // brace depth inside the block
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_partial_dedup_return <file>')
		exit(2)
	}
	file := os.args[1]
	raw := os.read_lines(file) or {
		eprintln('detect_partial_dedup_return: cannot read ${file}')
		exit(2)
	}
	lines := raw.map(it.trim_right('\r'))
	println('=== partial-dedup-return detector: ${file} ===')
	mut found := 0
	mut i := 0
	for i < lines.len {
		params := struct_params(signature_text(lines, i))
		if params.len == 0 || !lines[i].trim_space().starts_with('fn ')
			&& !lines[i].trim_space().starts_with('pub fn ') {
			i++
			continue
		}
		end := body_end(lines, i)
		for p in params {
			found += scan_function(file, lines, i, end, p)
		}
		i = end + 1
	}
	if found > 0 {
		println('FOUND ${found} candidate(s).')
		exit(1)
	}
	println('OK: no early return skips a field it did not compare.')
	exit(0)
}

// signature_text joins the line `start` with the lines after it until its
// parentheses balance, so a signature vfmt wrapped is read whole.
fn signature_text(lines []string, start int) string {
	mut text := code_part(lines[start])
	mut k := start + 1
	for k < lines.len && text.count('(') > text.count(')') {
		text += ' ' + code_part(lines[k]).trim_space()
		k++
	}
	return text
}

// struct_params returns the names of parameters whose type is a plain struct
// (an identifier starting with an upper-case letter) in a fn signature.
fn struct_params(line string) []string {
	t := line.trim_space()
	if !(t.starts_with('fn ') || t.starts_with('pub fn ')) {
		return []
	}
	// Skip a method receiver `fn (mut c T) name(...)`; the parameter list is
	// the next `( ... )` group.
	mut from := 0
	if t.all_after('fn').trim_space().starts_with('(') {
		from = t.index_after(')', t.index('(') or { return [] }) or { return [] } + 1
	}
	open := t.index_after('(', from) or { return [] }
	close := t.index_after(')', open) or { return [] }
	mut names := []string{}
	for part in t[open + 1..close].split(',') {
		words := part.trim_space().split(' ').filter(it != '' && it != 'mut' && it != 'shared')
		if words.len != 2 {
			continue
		}
		typ := words[1].trim_left('&')
		if typ.len > 0 && typ[0] >= `A` && typ[0] <= `Z` {
			names << words[0]
		}
	}
	return names
}

// brace_delta counts `{` minus `}` outside string and rune literals.
fn brace_delta(line string) int {
	mut d := 0
	mut quote := u8(0)
	mut i := 0
	for i < line.len {
		c := line[i]
		if quote != 0 {
			if c == `\\` {
				i += 2
				continue
			}
			if c == quote {
				quote = 0
			}
		} else if c == `'` || c == `"` || c == `\`` {
			quote = c
		} else if c == `{` {
			d++
		} else if c == `}` {
			d--
		}
		i++
	}
	return d
}

// code_part drops a trailing `//` comment; a `//` inside a string or rune
// literal (`'https://x'`) is not one.
fn code_part(line string) string {
	mut quote := u8(0)
	mut i := 0
	for i < line.len {
		c := line[i]
		if quote != 0 {
			if c == `\\` {
				i += 2
				continue
			}
			if c == quote {
				quote = 0
			}
		} else if c == `'` || c == `"` || c == `\`` {
			quote = c
		} else if c == `/` && i + 1 < line.len && line[i + 1] == `/` {
			return line[..i]
		}
		i++
	}
	return line
}

// body_end returns the line that closes the body of the fn declared on line
// `start`, or `start` itself for a declaration with no body (`fn C.f(x T)`):
// its parentheses balance on that line and no `{` follows them.
fn body_end(lines []string, start int) int {
	sig := code_part(lines[start])
	if !sig.contains('{') && sig.count('(') == sig.count(')') {
		return start
	}
	mut depth := 0
	mut opened := false
	for j in start .. lines.len {
		depth += brace_delta(code_part(lines[j]))
		if depth > 0 {
			opened = true
		}
		if opened && depth <= 0 {
			return j
		}
	}
	return lines.len - 1
}

fn is_ident_char(c u8) bool {
	return c.is_letter() || c.is_digit() || c == `_`
}

// fields_of returns the distinct field names read as `p.field` in `text`.
fn fields_of(text string, p string) []string {
	needle := '${p}.'
	mut out := []string{}
	mut at := 0
	for {
		idx := text.index_after(needle, at) or { break }
		at = idx + needle.len
		if idx > 0 && (is_ident_char(text[idx - 1]) || text[idx - 1] == `.`) {
			continue
		}
		mut e := at
		for e < text.len && is_ident_char(text[e]) {
			e++
		}
		if e > at {
			f := text[at..e]
			if f !in out {
				out << f
			}
		}
	}
	return out
}

fn is_success_return(t string) bool {
	return t == 'return' || t.starts_with('return //') || t == 'return none'
		|| t.starts_with('return none //')
}

fn scan_function(file string, lines []string, start int, end int, p string) int {
	mut found := 0
	mut stack := []Block{}
	mut depth := 0
	for j in start .. end + 1 {
		code := code_part(lines[j])
		t := code.trim_space()
		if j > start && is_success_return(lines[j].trim_space()) && stack.len > 0 {
			inner := stack.last()
			if compares_to_stored(inner.header, p) && only_statement(lines, inner.start, j) {
				mut compared := []string{}
				for b in stack {
					for f in fields_of(b.header, p) {
						if f !in compared {
							compared << f
						}
					}
				}
				close := block_close(lines, inner.start, end)
				mut skipped := []string{}
				for k in close + 1 .. end + 1 {
					for f in fields_of(code_part(lines[k]), p) {
						if f !in compared && f !in skipped {
							skipped << f
						}
					}
				}
				if skipped.len > 0 {
					println('  ${file}:${j + 1}: early return compares ${p}.${compared.join('/')} but later code uses ${p}.${skipped.join(', ${p}.')} -- is it still applied on this path?')
					found++
				}
			}
		}
		delta := brace_delta(code)
		if delta > 0 && t.ends_with('{') && j > start {
			stack << Block{
				start:  j
				header: header_text(lines, j)
				depth:  depth + delta
			}
		}
		depth += delta
		for stack.len > 0 && depth < stack.last().depth {
			stack.pop()
		}
	}
	return found
}

fn is_operand_char(c u8) bool {
	return is_ident_char(c) || c == `.` || c == `[` || c == `]`
}

// compares_to_stored reports whether `header` has an `==` with a field of `p`
// on one side and a field or index of another variable on the other
// (`existing.cid == f.connection_id`): a repeat check against a stored entry.
// A comparison with a literal, a constant or an enum value (`f.len == 0`,
// `f.kind == .x`) is a plain guard and does not count.
fn compares_to_stored(header string, p string) bool {
	mut at := 0
	for {
		idx := header.index_after('==', at) or { return false }
		at = idx + 2
		mut l := idx
		for l > 0 && header[l - 1] == ` ` {
			l--
		}
		mut ls := l
		for ls > 0 && is_operand_char(header[ls - 1]) {
			ls--
		}
		mut r := idx + 2
		for r < header.len && header[r] == ` ` {
			r++
		}
		mut re := r
		for re < header.len && is_operand_char(header[re]) {
			re++
		}
		left := header[ls..l]
		right := header[r..re]
		mine := '${p}.'
		if (left.starts_with(mine) && is_stored_operand(right, mine))
			|| (right.starts_with(mine) && is_stored_operand(left, mine)) {
			return true
		}
	}
	return false
}

fn is_stored_operand(x string, mine string) bool {
	return x.len > 0 && !x[0].is_digit() && x[0] != `.` && !x.starts_with(mine)
		&& (x.contains('.') || x.contains('['))
}

// only_statement reports whether every line strictly between the block opener
// `start` and the return at `ret` is blank or a comment.
fn only_statement(lines []string, start int, ret int) bool {
	for k in start + 1 .. ret {
		if code_part(lines[k]).trim_space() != '' {
			return false
		}
	}
	return true
}

// header_text returns the full `if` condition whose opening brace is on line
// `j` (a condition may span several lines), or '' for any other block.
fn header_text(lines []string, j int) string {
	mut parts := []string{}
	mut k := j
	for k >= 0 {
		cur := code_part(lines[k]).trim_space()
		if k < j && (cur.ends_with('{') || cur.ends_with('}')) {
			break
		}
		parts.prepend(cur)
		if cur.starts_with('if ') || cur.starts_with('} else if ') {
			return parts.join(' ')
		}
		k--
	}
	return ''
}

fn block_close(lines []string, start int, end int) int {
	mut depth := 0
	for j in start .. end + 1 {
		depth += brace_delta(code_part(lines[j]))
		if j > start && depth <= 0 {
			return j
		}
	}
	return end
}
