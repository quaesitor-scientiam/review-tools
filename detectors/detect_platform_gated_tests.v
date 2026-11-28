// detect_platform_gated_tests — lists the test functions in a `_test.v` file
// whose body opens with a `$if ... { return }` gate, or whose whole body is one
// `$if ... { }` block with no `$else`, so they run only on some hosts (for example
// `$if !macos && !linux { return }`, or `$if !windows { ...the test... }`). The
// second shape was added in rev 145: graphify a7b43ac's cut-cache test had it, and
// the detector did not list it (adversarial round of 2026-11-27). Not listed: a body
// that is an `$if ... { } $else $if ... { }` chain with no final `$else`.
// A mutant killed only by
// such a test is killed only on those hosts (vreview Angle J, rev 101): its
// discrimination row names the platforms, and needs an ungated test unless the
// branch it covers is itself platform-specific.
//
// Missed on vlang/v PR 31981 (adversarial round 7, 2026-11-08): the reset of
// pending leading flags at an embedded field and the embedded-with-default
// exception were pinned only by tests gated on macOS and Linux.
//
// This is an enumerate-and-verify aid: a listed test is a candidate, not a bug.
//
// Usage: detect_platform_gated_tests <file> [base_copy_or_empty]
//   The second argument is accepted and never scanned.
// Exit: 1 = at least one gated test listed; 0 = none or not a `_test.v` file;
//   2 = usage error.
module main

import os

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_platform_gated_tests <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	if !file.ends_with('_test.v') {
		println('=== platform-gated test detector: ${file} (not a _test.v file, skipping) ===')
		exit(0)
	}
	println('=== platform-gated test detector: ${file} ===')
	lines := os.read_lines(file) or {
		eprintln('cannot read ${file}')
		exit(2)
	}
	mut found := 0
	mut i := 0
	for i < lines.len {
		line := lines[i].trim_space()
		i++
		if !line.starts_with('fn test_') || !line.ends_with('{') {
			continue
		}
		name := line.all_after('fn ').all_before('(')
		// The first statement of the body.
		mut j := i
		for j < lines.len && lines[j].trim_space() == '' {
			j++
		}
		if j >= lines.len || !lines[j].trim_space().starts_with('\$if ') {
			continue
		}
		condition := lines[j].trim_space().all_after('\$if ').all_before('{').trim_space()
		// Read the `$if` block up to its closing brace; look for a return and an `$else`.
		mut depth := 0
		mut returns := false
		mut has_else := false
		mut k := j
		for k < lines.len {
			text := lines[k]
			outer := depth == 1
			depth += text.count('{') - text.count('}')
			if text.trim_space().starts_with('return') {
				returns = true
			}
			// only the gate's own `} $else`: one nested in its body still leaves the body gated
			if outer && text.trim_space().starts_with('}') && text.contains('\$else') {
				has_else = true
			}
			k++
			if depth <= 0 {
				break
			}
		}
		// The first statement after the block.
		for k < lines.len && lines[k].trim_space() == '' {
			k++
		}
		whole_body := !has_else && k < lines.len && lines[k].trim_space() == '}'
		if returns {
			println('  line ${i}: ${name} returns early when `${condition}`')
			found++
		} else if whole_body {
			println('  line ${i}: ${name} runs only when `${condition}` (its whole body is under the gate)')
			found++
		}
	}
	if found == 0 {
		println('RESULT: no test function returns early under a `\$if` gate or is wholly inside one.')
		exit(0)
	}
	println('RESULT: ${found} test(s) run only on some hosts; a mutant killed only by them is a per-platform kill.')
	exit(1)
}
