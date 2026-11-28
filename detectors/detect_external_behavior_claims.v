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
// An operating system or its C library is another tool too (rev 144): a comment that
// names Windows, Linux, the system or glibc states what they do. And a claim's
// subject can sit on another line of its comment block, so a new line is listed
// when any line of its block (consecutive whole-line `//` comments) names a tool.
// Missed on vlang/v PR 31848 (adversarial round 13, 2026-11-26): "without the dots
// and spaces at the end of each name", said of GetFullPathNameW in the doc comment
// of a new public function and beside a line that names Windows, is false for every
// name but the last; both comments were listed by no detector.
//
// A workflow or shell file (`.yml`, `.yaml`, `.sh`) has `#` comments, read like a V
// file's `//` ones, and the garbage collector V links (Boehm, libgc) is another tool
// too (rev 146). Missed on graphify a7b43ac (adversarial round of 2026-11-27): two
// comments in ci.yml said the warnings it counts are for "a large block it refused";
// Boehm prints that warning for a block it gives out, and no detector read the file.
//
// This is an enumerate-and-verify aid: a listed line is a candidate, not a bug.
// It reads whole-line comments only; a trailing comment after code is not listed.
//
// Usage: detect_external_behavior_claims <file> [base_copy_or_empty]
// Exit: 1 = at least one new claim line listed; 0 = none; 2 = usage error.
module main

import os

const tool_words = ['V', "V's", 'GCC', "GCC's", 'gcc', 'Clang', 'clang', 'TCC', 'tcc', 'MSVC',
	'cgen', 'checker', "checker's", 'parser', "parser's", 'mirrors', 'mirror', 'matches', 'Boehm',
	"Boehm's", 'libgc', 'bdwgc', 'GC']

// system_words are the systems of V's target list (vlib/v/pref/os_targets.v, as
// written in prose) and the names of their C libraries and interfaces.
const system_words = ['Windows', "Windows'", 'Linux', "Linux's", 'macOS', 'Darwin', 'iOS', 'FreeBSD',
	'OpenBSD', 'NetBSD', 'DragonFly', 'BSD', 'BSDs', 'Solaris', 'QNX', 'Haiku', 'SerenityOS', 'Vinix',
	'Emscripten', 'Android', 'Termux', 'WSL', 'POSIX', 'glibc', 'musl', 'Bionic', 'libc', 'kernel',
	"kernel's"]

const tool_phrases = ['C backend', 'default V', 'as V ', 'like V ', 'the system', 'The system',
	'system call', 'Plan 9']

// comment_text is the text of a whole-line comment: `//` in a V file, `#` (not a
// `#!` line) in a workflow or shell file (`hash`).
fn comment_text(line string, hash bool) ?string {
	trimmed := line.trim_space()
	if hash {
		if trimmed.starts_with('#') && !trimmed.starts_with('#!') {
			return trimmed.trim_left('#').trim_space()
		}
		return none
	}
	if trimmed.starts_with('//') {
		return trimmed.trim_left('/').trim_space()
	}
	return none
}

// hash_comments reports whether `file` takes `#` comments: a workflow or shell file.
fn hash_comments(file string) bool {
	return file.ends_with('.yml') || file.ends_with('.yaml') || file.ends_with('.sh')
}

// claim_lines maps each line index to the text that can hold a claim: a whole-line
// comment in a V, workflow or shell file, a prose line outside ``` fences in a
// Markdown file.
fn claim_lines(lines []string, markdown bool, hash bool) map[int]string {
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
		} else if text := comment_text(line, hash) {
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
		if word in tool_words || word in system_words {
			return true
		}
	}
	return false
}

// blocks_naming_a_tool gives the indexes of the comment lines whose block, a run of
// consecutive whole-line comments, has a line that names another tool.
fn blocks_naming_a_tool(lines []string, hash bool) map[int]bool {
	mut out := map[int]bool{}
	mut start := 0
	for start < lines.len {
		if _ := comment_text(lines[start], hash) {
		} else {
			start++
			continue
		}
		mut end := start
		mut names := false
		for end < lines.len {
			text := comment_text(lines[end], hash) or { break }
			if names_another_tool(text) {
				names = true
			}
			end++
		}
		if names {
			for i in start .. end {
				out[i] = true
			}
		}
		start = end
	}
	return out
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
	hash := hash_comments(file)
	mut old := map[string]bool{}
	if base != '' {
		base_lines := os.read_lines(base) or { []string{} }
		for _, text in claim_lines(base_lines, markdown, hash) {
			old[text] = true
		}
	}
	texts := claim_lines(lines, markdown, hash)
	in_naming_block := if markdown { map[int]bool{} } else { blocks_naming_a_tool(lines, hash) }
	mut found := 0
	for i in 0 .. lines.len {
		text := texts[i] or { continue }
		if text in old || (!markdown && !names_another_tool(text) && !in_naming_block[i]) {
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
