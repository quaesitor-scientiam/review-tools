// detect_external_behavior_claims — lists the comment lines a change adds that
// state what another tool does: V's parser, checker or C backend, GCC, Clang,
// TCC, MSVC, or code the comment says it mirrors or matches. Each listed line
// is a claim the review must probe (vreview Angle I, comment ledger, rev 101),
// through every consumer the change names, not one.
//
// A comment line is new when its trimmed text does not occur as a comment line
// in the base copy. With no base copy (a new file) every comment line is new.
//
// Missed on vlang/v PR 31981 (adversarial round 7, 2026-11-08): four new
// comments made false claims about V ("an item starts after `;` or `,`, as V's
// parser forms it", "V accepts and ignores it", "only when a name follows").
//
// A Markdown file (`.md`) is user documentation of what the code does: every new
// prose line outside code fences is listed, whether or not it names a tool, since
// a docs sentence about a checker describes that checker's model of another tool.
// Missed on vlang/v PR 31407 (adversarial round 15, 2026-11-14): docs.md said an
// alignment directive between `rep` and a string instruction "ends the prefix",
// true only when it emits padding (`.p2align 0` emits none); no ledger row had it.
//
// This is an enumerate-and-verify aid: a listed line is a candidate, not a bug.
// In a V file it reads whole-line `//` comments only; a trailing comment after code
// is not listed.
//
// Usage: detect_external_behavior_claims <file> [base_copy_or_empty]
// Exit: 1 = at least one new claim line listed; 0 = none; 2 = usage error.
module main

import os

const tool_words = ['V', "V's", 'GCC', "GCC's", 'gcc', 'Clang', 'clang', 'TCC', 'tcc', 'MSVC',
	'cgen', 'checker', "checker's", 'parser', "parser's", 'mirrors', 'mirror', 'matches']

const tool_phrases = ['C backend', 'default V', 'as V ', 'like V ']

fn comment_text(line string) ?string {
	trimmed := line.trim_space()
	if trimmed.starts_with('//') {
		return trimmed.trim_left('/').trim_space()
	}
	return none
}

// claim_lines maps each line index to the text that can hold a claim: a whole-line
// `//` comment in a V file, a prose line outside ``` fences in a Markdown file.
fn claim_lines(lines []string, markdown bool) map[int]string {
	mut out := map[int]string{}
	mut fenced := false
	for i, line in lines {
		if markdown {
			trimmed := line.trim_space()
			if trimmed.starts_with('```') {
				fenced = !fenced
				continue
			}
			if !fenced && trimmed != '' {
				out[i] = trimmed
			}
		} else if text := comment_text(line) {
			out[i] = text
		}
	}
	return out
}

fn names_another_tool(text string) bool {
	for phrase in tool_phrases {
		if text.contains(phrase) {
			return true
		}
	}
	for raw in text.split(' ') {
		word := raw.trim('.,;:()[]`\'"!?')
		if word in tool_words {
			return true
		}
	}
	return false
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_external_behavior_claims <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	base := if os.args.len > 2 { os.args[2] } else { '' }
	println('=== external-behaviour claim detector: ${file} ===')
	lines := os.read_lines(file) or {
		eprintln('cannot read ${file}')
		exit(2)
	}
	markdown := file.ends_with('.md')
	mut old := map[string]bool{}
	if base != '' {
		base_lines := os.read_lines(base) or { []string{} }
		for _, text in claim_lines(base_lines, markdown) {
			old[text] = true
		}
	}
	texts := claim_lines(lines, markdown)
	mut found := 0
	for i in 0 .. lines.len {
		text := texts[i] or { continue }
		if text in old || (!markdown && !names_another_tool(text)) {
			continue
		}
		println('  line ${i + 1}: ${text}')
		found++
	}
	if found == 0 {
		println('RESULT: no new comment line states what another tool does.')
		exit(0)
	}
	println('RESULT: ${found} new comment line(s) state what another tool does; probe each one.')
	exit(1)
}
