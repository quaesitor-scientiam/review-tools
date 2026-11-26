// detect_numeric_text_compare — lists the lines a change adds that compare a string with a
// number written as text (`text == '0'`, `x in ['\$0', '\$0x0']`, `'-1' != y`). Such a test
// decides by how the number is spelled, not by its value, so every other spelling of the same
// value (`00`, `0b0`, `0x00`, `255` for an all-ones byte) takes the other branch. Each listed line
// gets the probes of vreview Angle J's "Every literal spelling the tool accepts", one per spelling.
//
// A line is new when its trimmed text is not a line of the base copy. With no base copy (a new
// file) every line is new. A number literal is a quoted string holding an optional `$` (escaped or
// not), optional signs, then decimal digits, `0x` hex, `0b` binary or `0o` octal digits, and
// nothing else. It counts when `==` or `!=` stands right before or after it, or when it is a
// member of a list after `in` or `!in`. A whole-line `//` comment and a literal inside another
// string are not read.
//
// Missed on vlang/v PR 31407 (adversarial round of 2026-11-26, 5 of 5 confirmed): the no-change
// rule compared an immediate with `'\$0'`, `'\$0x0'` and `'\$-1'`, and a displacement with
// `['', '0', '0x0']`, so `$255`, `$0b0`, `$00` and `0x0(,R,1)` were reported as writes. The
// Angle J bullet existed; the probes took their spellings from the docs' own examples.
//
// This is an enumerate-and-verify aid: a listed line is a candidate, not a bug.
//
// Usage: detect_numeric_text_compare <file> [base_copy_or_empty]
// Exit: 1 = at least one new line listed; 0 = none; 2 = usage error or unreadable file.
module main

import os

struct Literal {
	start int // index of the opening quote
	end   int // index just after the closing quote
	text  string
}

// string_literals returns the quoted strings of a line, skipping escaped quotes, and stops at a
// `//` outside a string. An unclosed string ends the line.
fn string_literals(line string) []Literal {
	mut out := []Literal{}
	mut i := 0
	for i < line.len {
		c := line[i]
		if c == `/` && i + 1 < line.len && line[i + 1] == `/` {
			break
		}
		if c in [`'`, `"`] {
			mut j := i + 1
			for j < line.len && line[j] != c {
				if line[j] == `\\` {
					j++
				}
				j++
			}
			if j >= line.len {
				break
			}
			out << Literal{
				start: i
				end:   j + 1
				text:  line[i + 1..j]
			}
			i = j + 1
			continue
		}
		i++
	}
	return out
}

// is_number_text reports whether `text` spells a number and nothing else.
fn is_number_text(text string) bool {
	mut s := text
	if s.starts_with('\\$') {
		s = s[2..]
	} else if s.starts_with('$') {
		s = s[1..]
	}
	s = s.trim_left('+-')
	if s.len == 0 {
		return false
	}
	lower := s.to_lower()
	if lower.len > 2 && lower[0] == `0` && lower[1] in [`x`, `b`, `o`] {
		digits := lower[2..]
		return match lower[1] {
			`x` { digits.bytes().all(it.is_hex_digit()) }
			`b` { digits.bytes().all(it in [`0`, `1`]) }
			else { digits.bytes().all(it.is_oct_digit()) }
		}
	}
	return s.bytes().all(it.is_digit())
}

// compares reports whether the literal at `lit` is an operand of `==` or `!=`, or a member of a
// list after `in` or `!in`.
fn compares(line string, lit Literal) bool {
	before := line[..lit.start].trim_right(' \t')
	after := line[lit.end..].trim_left(' \t')
	if before.ends_with('==') || before.ends_with('!=') || after.starts_with('==')
		|| after.starts_with('!=') {
		return true
	}
	open := before.last_index('[') or { return false }
	if before[open..].contains(']') {
		return false
	}
	head := before[..open].trim_right(' \t')
	return head.ends_with(' in') || head.ends_with('!in')
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_numeric_text_compare <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	base := if os.args.len > 2 { os.args[2] } else { '' }
	println('=== numeric text comparison detector: ${file} ===')
	lines := os.read_lines(file) or {
		eprintln('cannot read ${file}')
		exit(2)
	}
	mut old := map[string]bool{}
	for line in os.read_lines(base) or { []string{} } {
		old[line.trim_space()] = true
	}
	mut found := 0
	for i, line in lines {
		trimmed := line.trim_space()
		if trimmed in old {
			continue
		}
		hits := string_literals(line).filter(is_number_text(it.text) && compares(line, it))
		if hits.len > 0 {
			println('  line ${i + 1}: ${trimmed} (${hits.map("'" + it.text + "'").join(', ')})')
			found++
		}
	}
	if found == 0 {
		println('RESULT: no new line compares a number as text.')
		exit(0)
	}
	println('RESULT: ${found} new line(s) compare a number as text; probe each with every spelling of its value.')
	exit(1)
}
