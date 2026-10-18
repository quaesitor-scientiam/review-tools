// detect_settings_arm_parity — V port of skills/code-review/detect_settings_arm_parity.sh.
//
// Detects comment-only / empty `h2_settings_*` match arms in the target file's
// `apply*settings` function(s) where a sibling `h2_*.v` file (same directory,
// excluding the target) has executable code for the same arm.
//
// Quirks preserved from the shell/awk version:
//   * a function is picked up by `^fn .*(apply|Apply).*(settings|Settings)` (so `pub fn`
//     is not), its extent is found by counting every `{`/`}` char (strings and comments
//     included), and several matching functions are concatenated;
//   * an arm starts at ANY line that contains the label and a `{` (restarting the depth
//     count even inside an arm) and ends when the brace depth returns to 0;
//   * "executable code" = a line that, after leading blanks, does not start with `//`,
//     `{` or `}`, and is not blank, a bare `h2_settings_x {` label or a bare `else {`.
//
// Usage: detect_settings_arm_parity <file_under_review>
// Exit: 1 = disparity found, 0 = none (or SKIP), 2 = usage error.
// Diagnostics (BUG/OK/SKIP) go to stderr, as in the shell version.
module main

import os

fn is_label_char(c u8) bool {
	return c == `_` || (c >= `a` && c <= `z`)
}

// is_apply_settings_fn: ^fn .*(apply|Apply).*(settings|Settings)
fn is_apply_settings_fn(l string) bool {
	if !l.starts_with('fn ') {
		return false
	}
	mut first := -1
	for k in ['apply', 'Apply'] {
		i := l.index_after(k, 3) or { continue }
		if first < 0 || i < first {
			first = i
		}
	}
	if first < 0 {
		return false
	}
	from := first + 5
	return (l.index_after('settings', from) or { -1 }) >= 0
		|| (l.index_after('Settings', from) or { -1 }) >= 0
}

// extract_fn_body mirrors the awk extractor: matching lines from the signature to the
// line where the brace depth falls back to 0.
fn extract_fn_body(lines []string) []string {
	mut out := []string{}
	mut in_fn := false
	mut depth := 0
	for l in lines {
		if is_apply_settings_fn(l) {
			in_fn = true
			depth = 0
		}
		if in_fn {
			out << l
			for c in l {
				if c == `{` {
					depth++
				} else if c == `}` {
					depth--
					if depth == 0 {
						in_fn = false
						break
					}
				}
			}
		}
	}
	return out
}

// extract_arm mirrors the awk arm extractor for `label`.
fn extract_arm(body []string, label string) []string {
	mut out := []string{}
	mut in_arm := false
	mut depth := 0
	for l in body {
		if l.contains(label) && l.contains('{') {
			in_arm = true
			depth = 0
		}
		if in_arm {
			out << l
			for c in l {
				if c == `{` {
					depth++
				} else if c == `}` {
					depth--
					if depth == 0 {
						in_arm = false
						break
					}
				}
			}
		}
	}
	return out
}

// is_label_only: h2_settings_[a-z_]+\s*\{?\s*$ (after leading blanks)
fn is_label_only(t string) bool {
	if !t.starts_with('h2_settings_') {
		return false
	}
	mut i := 'h2_settings_'.len
	j := i
	for i < t.len && is_label_char(t[i]) {
		i++
	}
	if i == j {
		return false
	}
	rest := t[i..].trim_space()
	return rest == '' || rest == '{'
}

// is_else_only: else\s*\{?\s*$
fn is_else_only(t string) bool {
	if !t.starts_with('else') {
		return false
	}
	rest := t[4..].trim_space()
	return rest == '' || rest == '{'
}

// arm_has_code reports whether any line of the arm body is executable code.
fn arm_has_code(body []string) bool {
	for l in body {
		t := l.trim_left(' \t\n\v\f\r')
		if t.trim_space() == '' || t.starts_with('//') || t.starts_with('{') || t.starts_with('}') {
			continue
		}
		if is_label_only(t) || is_else_only(t) {
			continue
		}
		return true
	}
	return false
}

// arm_labels returns the sorted unique `h2_settings_[a-z_]+` tokens in body.
fn arm_labels(body []string) []string {
	mut set := map[string]bool{}
	for l in body {
		mut start := 0
		for {
			idx := l.index_after('h2_settings_', start) or { break }
			mut e := idx + 'h2_settings_'.len
			for e < l.len && is_label_char(l[e]) {
				e++
			}
			if e > idx + 'h2_settings_'.len {
				set[l[idx..e]] = true
				start = e
			} else {
				start = idx + 1
			}
		}
	}
	mut keys := set.keys()
	keys.sort()
	return keys
}

fn read_trimmed(path string) []string {
	raw := os.read_lines(path) or { return []string{} }
	return raw.map(it.trim_right('\r'))
}

fn main() {
	file := if os.args.len > 1 { os.args[1] } else { '' }
	if file == '' || !os.is_file(file) {
		eprintln('Usage: ${os.args[0]} <v-source-file>')
		exit(2)
	}
	dir := os.dir(file)
	base := os.base(file)
	mut siblings := []string{}
	for name in os.ls(dir) or { []string{} } {
		if name.starts_with('h2_') && name.ends_with('.v') && name != base {
			p := os.join_path(dir, name)
			if os.is_file(p) {
				siblings << p
			}
		}
	}
	siblings.sort()
	if siblings.len == 0 {
		eprintln('SKIP: no sibling h2_*.v files found in ${dir}')
		exit(0)
	}
	target_body := extract_fn_body(read_trimmed(file))
	if target_body.len == 0 {
		eprintln('SKIP: no apply_*settings function found in ${file}')
		exit(0)
	}
	labels := arm_labels(target_body)
	if labels.len == 0 {
		eprintln('SKIP: no h2_settings_* arms found in ${file}')
		exit(0)
	}
	mut sib_bodies := map[string][]string{}
	for sib in siblings {
		sib_bodies[sib] = extract_fn_body(read_trimmed(sib))
	}
	mut found_bug := false
	for arm in labels {
		if arm_has_code(extract_arm(target_body, arm)) {
			continue
		}
		for sib in siblings {
			sb := sib_bodies[sib] or { continue }
			if sb.len == 0 {
				continue
			}
			if arm_has_code(extract_arm(sb, arm)) {
				eprintln("BUG: arm '${arm}' in ${base} is comment-only/empty, but ${os.base(sib)} has executable code for the same arm — likely missing required behavior")
				found_bug = true
				break
			}
		}
	}
	if !found_bug {
		eprintln('OK: no comment-only/empty arms found where sibling files have executable code')
		exit(0)
	}
	exit(1)
}
