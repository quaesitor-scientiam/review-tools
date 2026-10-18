// detect_sibling_arms — V port of skills/code-review/detect_sibling_arms.ps1.
//
// For every `match` block that contains a line matching <pattern>, lists all
// typed arms (`H2Xxx ...` or `else ...` labels one tab deeper than the match)
// and marks each [HAS] / [MISSING] the pattern. Enumerate-and-verify tool, not a
// gate: always exits 0 (exit 2 only for usage errors / unreadable file).
//
// Pattern semantics: PowerShell's -match is a case-insensitive .NET regex. A
// pattern with no regex metacharacters is matched as a case-insensitive
// substring (exact for plain identifiers like `handshaked`); anything else goes
// through V's `regex` module (case-SENSITIVE and matched line by line: the
// documented deviation).
//
// Quirks preserved from the .ps1: the enclosing `match` is searched backwards
// from the line BEFORE the hit (`^\t*match\b`); the block-end test is skipped for
// the first scanned line; arm labels need trailing whitespace after the label.
//
// Usage: detect_sibling_arms <file> <pattern>
module main

import os
import regex

struct Arm {
	line_no int
	label   string
mut:
	body []string
}

fn main() {
	if os.args.len < 3 {
		eprintln('usage: detect_sibling_arms <file> <pattern>')
		exit(2)
	}
	file := os.args[1]
	pat := os.args[2]
	if !os.is_file(file) {
		eprintln('File not found: ${file}')
		exit(2)
	}
	raw := os.read_lines(file) or {
		eprintln('File not found: ${file}')
		exit(2)
	}
	lines := raw.map(it.trim_right('\r'))
	total := lines.len
	m := new_matcher(pat)
	println("=== sibling-arm scan: ${file}  pattern='${pat}' ===")

	mut hit_lines := []int{}
	for i, l in lines {
		if m.is_match(l) {
			hit_lines << i + 1
		}
	}
	if hit_lines.len == 0 {
		println("(no lines matching '${pat}' found)")
		exit(0)
	}
	mut processed := map[int]bool{}
	for hit in hit_lines {
		mut match_line := 0
		for i := hit - 1; i >= 1; i-- {
			if is_match_line(lines[i - 1]) {
				match_line = i
				break
			}
		}
		if match_line == 0 {
			continue
		}
		if match_line in processed {
			continue
		}
		processed[match_line] = true

		match_sig := lines[match_line - 1].trim_left(ws)
		println('')
		println('Match block at line ${match_line} : ${match_sig}')

		match_tabs := leading_tabs(lines[match_line - 1])
		arm_tabs := match_tabs + 1
		mut arms := []Arm{}
		mut cur := ?Arm(none)
		for j := match_line; j < total; j++ {
			line := lines[j]
			stripped := line.trim_left(ws)
			if stripped == '' {
				if mut c := cur {
					c.body << line
					cur = c
				}
				continue
			}
			line_tabs := leading_tabs(line)
			if line_tabs <= match_tabs && j > match_line {
				break
			}
			if line_tabs == arm_tabs && is_arm_label(stripped) {
				if c := cur {
					arms << c
				}
				cur = Arm{
					line_no: j + 1
					label:   stripped
					body:    [line]
				}
				continue
			}
			if mut c := cur {
				c.body << line
				cur = c
			}
		}
		if c := cur {
			arms << c
		}
		if arms.len == 0 {
			println('  (no typed arms found — check manually)')
			continue
		}
		for arm in arms {
			has := arm.body.any(m.is_match(it))
			flag := if has { '[HAS]    ' } else { '[MISSING]' }
			mut ln := arm.line_no.str()
			for ln.len < 5 {
				ln += ' '
			}
			println('  line ${ln} ${flag}  ${arm.label}')
		}
		println('  ---')
		println("  [MISSING] arms may have the same deficiency as the arm with '${pat}'.")
	}
	println('')
}

const ws = ' \t\r\n\v\f'

fn leading_tabs(l string) int {
	mut n := 0
	for n < l.len && l[n] == `\t` {
		n++
	}
	return n
}

fn is_word(c u8) bool {
	return c == `_` || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
}

// is_match_line mirrors `^\t*match\b`.
fn is_match_line(l string) bool {
	t := l.trim_left('\t')
	if !t.starts_with('match') {
		return false
	}
	return t.len == 5 || !is_word(t[5])
}

// is_arm_label mirrors `^(H2[A-Za-z]+|else)\s`.
fn is_arm_label(s string) bool {
	if s.starts_with('else') {
		return s.len > 4 && ws.contains(s[4].ascii_str())
	}
	if !s.starts_with('H2') {
		return false
	}
	mut i := 2
	for i < s.len && s[i].is_letter() {
		i++
	}
	return i > 2 && i < s.len && ws.contains(s[i].ascii_str())
}

struct Matcher {
	literal string
	re      ?regex.RE
}

fn new_matcher(pat string) Matcher {
	if !pat.contains_any('\\^$.|?*+()[]{}') {
		return Matcher{
			literal: pat.to_lower()
		}
	}
	re := regex.regex_opt(pat) or {
		eprintln('invalid pattern: ${err}')
		exit(2)
	}
	return Matcher{
		re: re
	}
}

fn (m &Matcher) is_match(s string) bool {
	if mut re := m.re {
		start, _ := re.find(s)
		return start >= 0
	}
	return s.to_lower().contains(m.literal)
}
