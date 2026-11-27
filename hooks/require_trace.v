// require_trace is a PreToolUse gate for the standing rule "No assumed meanings: trace before
// running" (~/.claude/CLAUDE.md): a script Claude writes in a session scratchpad must declare, in
// its own text, one case traced by hand and its control rows:
//
//   # trace: <one concrete case, and what each name holds where it is used>
//   # controls: <the row that must pass and the row that must fail>
//
// (`//` in place of `#` for V). The rule came from a probe whose wrapper function read `"$@"` as
// its own arguments, so all 28 rows failed (vlang/v discussion 29269, PR 4, 2026-11-27).
//
// It checks a script when it is written, not when it runs:
//   - Write: the new content of a scratchpad file ending in .sh, .py, .ps1, .v or .vsh holds both
//     lines.
//   - Edit: the file as it will be after the edit holds both lines: each line is in the new text,
//     or it is in the file now and the replaced text does not hold it.
//   - Bash: the body of a heredoc written into such a file (`cat > f <<EOF`, `cat <<EOF > f`,
//     `tee f <<EOF`, `>>` too) holds both lines; an append (`>>`, `tee -a`) to a file that
//     already holds both lines passes. `$NAME` and `${NAME}` in the file's path are expanded from
//     `NAME=value` in the same command, a leading `~/` is the home folder, and a relative path is
//     taken from the last `cd` before it, else from the cwd; after `cd -` or a `cd` to a path this
//     reading cannot expand, relative paths are not checked until the next `cd`.
// Only paths with a `scratchpad` folder in them are checked, and not a file below a folder in the
// scratchpad that holds v.mod, .git, a Makefile, or both vlib and cmd (a copy of a project tree,
// or of the V tree).
//
// Not seen: a script written another way (`printf > f`, `echo > f`, `cp`, `sed -i`, MultiEdit),
// a heredoc whose path this reading cannot expand, a path with a space in it. It checks that the
// lines exist, not that they are true.
//
// hooks/build_trace.vsh builds it to bin/require_trace.exe (that name on every system), and
// hooks.json starts that file directly, with no shell. It reads the payload on stdin, prints a
// deny decision or nothing, and always exits 0. A payload it cannot read is allowed.
module main

import os
import x.json2

const script_exts = ['.sh', '.py', '.ps1', '.v', '.vsh']

fn main() {
	payload := os.get_raw_lines_joined()
	home := slashes(os.getenv_opt('HOME') or { os.home_dir() })
	// Most calls have nothing to check; leave before decoding them.
	if !payload.contains('scratchpad') && !home.contains('scratchpad') {
		return
	}
	if !script_exts.any(payload.contains(it)) {
		return
	}
	missing := check_payload(payload, home)
	if missing.len == 0 {
		return
	}
	reason := 'trace before running (~/.claude/CLAUDE.md, "No assumed meanings"): a script written to the scratchpad needs a \'# trace:\' line (one concrete case traced by hand: what each name holds where it is used) and a \'# controls:\' line (the row that must pass and the row that must fail, run first); missing in: ${missing.join(' ')}'
	println('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${json2.encode(reason)}}}')
}

// check_payload returns the scratchpad scripts the call in `payload` writes without both lines;
// `home` is the folder `~/` names. A payload that is not a JSON object gives none.
fn check_payload(payload string, home string) []string {
	root := json2.decode[json2.Any](payload) or { return [] }
	m := root.as_map()
	input := (m['tool_input'] or { json2.Any(map[string]json2.Any{}) }).as_map()
	cwd := slashes(text_of(m, 'cwd'))
	match text_of(m, 'tool_name') {
		'Write' {
			path := slashes(text_of(input, 'file_path'))
			if is_scratch_script(path) && !declared(text_of(input, 'content')) {
				return [path]
			}
		}
		'Edit' {
			path := slashes(text_of(input, 'file_path'))
			if is_scratch_script(path) {
				// A file that does not exist yet cannot be edited; the Edit fails on its own.
				now := os.read_file(path) or { return [] }
				old := text_of(input, 'old_string')
				new := text_of(input, 'new_string')
				trace_kept := has_line(new, 'trace:') || (has_line(now, 'trace:') && !has_line(old, 'trace:'))
				controls_kept := has_line(new, 'controls:')
					|| (has_line(now, 'controls:') && !has_line(old, 'controls:'))
				if !trace_kept || !controls_kept {
					return [path]
				}
			}
		}
		'Bash' {
			return check_heredocs(text_of(input, 'command'), cwd, home)
		}
		else {}
	}
	return []
}

// text_of returns the string field `key` of `m`, or '' when it is missing.
fn text_of(m map[string]json2.Any, key string) string {
	return (m[key] or { return '' }).str()
}

// slashes returns `p` with `/` for every `\`.
fn slashes(p string) string {
	return p.replace('\\', '/')
}

// declared reports whether `text` holds both a trace line and a controls line.
fn declared(text string) bool {
	return has_line(text, 'trace:') && has_line(text, 'controls:')
}

// has_line reports whether `text` holds `word` right after `#` or `//` and optional spaces.
fn has_line(text string, word string) bool {
	mut from := 0
	for {
		i := text.index_after(word, from) or { return false }
		mut j := i - 1
		for j >= 0 && text[j] == ` ` {
			j--
		}
		if j >= 0 && text[j] == `#` {
			return true
		}
		if j >= 1 && text[j] == `/` && text[j - 1] == `/` {
			return true
		}
		from = i + 1
	}
	return false
}

// is_absolute reports whether `p` starts at a root (`/x`) or a drive (`C:/x`).
fn is_absolute(p string) bool {
	return p.starts_with('/') || (p.len >= 3 && p[0].is_letter() && p[1] == `:` && p[2] == `/`)
}

// is_scratch_script reports whether `p` is a script file in a scratchpad and outside any copy of
// a project tree there.
fn is_scratch_script(p string) bool {
	if !p.contains('/scratchpad/') || !is_script_name(p) {
		return false
	}
	mut d := p.all_before_last('/')
	for d.contains('/scratchpad/') {
		for marker in ['v.mod', '.git', 'Makefile'] {
			if os.exists(d + '/' + marker) {
				return false
			}
		}
		if os.is_dir(d + '/vlib') && os.is_dir(d + '/cmd') {
			return false
		}
		d = d.all_before_last('/')
	}
	return true
}

// unquote returns `w` without its `"` and `'` characters.
fn unquote(w string) string {
	return w.replace('"', '').replace("'", '')
}

// lookup returns the value of the last `NAME=value` (or `export NAME=value`) in `cmd`, or ''.
fn lookup(cmd string, name string) string {
	mut value := ''
	mut from := 0
	for {
		i := cmd.index_after(name + '=', from) or { break }
		from = i + 1
		if i > 0 && cmd[i - 1] !in [` `, `;`, `&`, `|`, `(`, `\n`, `\t`] {
			continue
		}
		mut j := i + name.len + 1
		start := j
		for j < cmd.len && cmd[j] !in [` `, `;`, `&`, `|`, `)`, `\n`, `\t`] {
			j++
		}
		value = unquote(cmd[start..j])
	}
	return value
}

// expand returns `w` with a leading `~/` and every `$NAME` or `${NAME}` replaced, or '' when a
// name has no value in `cmd`.
fn expand(w string, cmd string, home string) string {
	mut t := w
	if t.starts_with('~/') {
		t = home + t[1..]
	}
	for _ in 0 .. 8 {
		i := t.index('$') or { break }
		mut j := i + 1
		braced := j < t.len && t[j] == `{`
		if braced {
			j++
		}
		start := j
		for j < t.len && (t[j].is_letter() || t[j].is_digit() || t[j] == `_`) {
			j++
		}
		name := t[start..j]
		if braced && j < t.len && t[j] == `}` {
			j++
		}
		value := lookup(cmd, name)
		if name == '' || value == '' {
			return ''
		}
		t = t[..i] + value + t[j..]
	}
	return if t.contains('$') { '' } else { t }
}

// Heredoc is one heredoc of a command: the file it is written to (or '' for none), whether it
// appends, its delimiter, whether `<<-` strips leading tabs, and which lines its body holds.
struct Heredoc {
mut:
	file     string
	append   bool
	delim    string
	strip    bool
	trace    bool
	controls bool
}

// heredoc_start finds a heredoc operator in `line` (not a `<<<` here-string) and returns its
// start, its end and the heredoc it opens, the file not yet known.
fn heredoc_start(line string) ?(int, int, Heredoc) {
	mut from := 0
	for {
		i := line.index_after('<<', from) or { return none }
		from = i + 2
		if i + 2 < line.len && line[i + 2] == `<` {
			from = i + 3
			continue
		}
		mut j := i + 2
		strip := j < line.len && line[j] == `-`
		if strip {
			j++
		}
		for j < line.len && line[j] in [` `, `\t`] {
			j++
		}
		if j < line.len && line[j] in [`'`, `"`] {
			j++
		}
		start := j
		for j < line.len && (line[j].is_letter() || line[j].is_digit() || line[j] == `_`) {
			j++
		}
		if j == start || line[start].is_digit() {
			continue
		}
		delim := line[start..j]
		if j < line.len && line[j] in [`'`, `"`] {
			j++
		}
		return i, j, Heredoc{
			delim: delim
			strip: strip
		}
	}
	return none
}

// redirect_target returns the first file `s` writes that names a script, and whether it is
// written by appending: the word after `>` or `>>`, or a file argument of `tee` (`-a` or
// `--append` makes it append). `2>/dev/null` and the like are passed over, as their file is no
// script.
fn redirect_target(s string) (string, bool) {
	mut i := 0
	for i < s.len {
		mut j := i + 1
		if s[i] == `>` {
			w, next := word_at(s, i + 1)
			if is_script_name(w) {
				append := i > 0 && s[i - 1] == `>`
				return w, append
			}
			j = next
		} else if is_command_word(s, i, 'tee') {
			mut append := false
			j = i + 3
			for {
				w, next := word_at(s, j)
				if w == '' {
					break
				}
				j = next
				if w in ['-a', '--append'] {
					append = true
				} else if is_script_name(w) {
					return w, append
				}
			}
		}
		i = if j > i { j } else { i + 1 }
	}
	return '', false
}

// word_at skips the spaces and tabs at `i` in `s` and returns the word there without quotes and
// the index after it; the word is '' at the end of `s` and at an operator.
fn word_at(s string, i int) (string, int) {
	mut j := i
	for j < s.len && s[j] in [` `, `\t`] {
		j++
	}
	start := j
	for j < s.len && s[j] !in [` `, `\t`, `;`, `&`, `|`, `<`, `>`] {
		j++
	}
	return unquote(s[start..j]), j
}

// is_command_word reports whether `name` stands at `i` in `s` as a word of its own.
fn is_command_word(s string, i int, name string) bool {
	if !s[i..].starts_with(name) {
		return false
	}
	if i > 0 && s[i - 1] !in [` `, `\t`, `|`, `;`, `&`, `(`] {
		return false
	}
	end := i + name.len
	return end == s.len || s[end] in [` `, `\t`]
}

// is_script_name reports whether `w` ends in a script extension.
fn is_script_name(w string) bool {
	return script_exts.any(w.ends_with(it))
}

// cd_targets returns the folders `cd` changes to in `line`, in order; '' stands for `cd -`.
fn cd_targets(line string) []string {
	mut out := []string{}
	mut from := 0
	for {
		i := line.index_after('cd', from) or { break }
		from = i + 2
		if i > 0 && line[i - 1] !in [` `, `\t`, `;`, `&`, `|`, `(`] {
			continue
		}
		mut j := i + 2
		if j >= line.len || line[j] !in [` `, `\t`] {
			continue
		}
		for j < line.len && line[j] in [` `, `\t`] {
			j++
		}
		start := j
		for j < line.len && line[j] !in [` `, `\t`, `;`, `&`, `|`, `)`] {
			j++
		}
		if j == start {
			continue
		}
		d := unquote(line[start..j])
		out << if d == '-' { '' } else { d }
		from = j
	}
	return out
}

// check_heredocs returns the scratchpad scripts the heredocs of `cmd` write without both lines,
// for a command run in `cwd`.
fn check_heredocs(cmd string, cwd string, home string) []string {
	if !cmd.contains('<<') {
		return []
	}
	mut missing := []string{}
	mut base := cwd
	mut doc := Heredoc{}
	mut in_body := false
	for line in cmd.split('\n') {
		if in_body {
			probe := if doc.strip { line.trim_left('\t') } else { line }
			if probe == doc.delim {
				in_body = false
				if p := written_path(doc.file, cmd, base, home) {
					if !is_ok(doc, p) {
						missing << p
					}
				}
				continue
			}
			doc.trace = doc.trace || has_line(line, 'trace:')
			doc.controls = doc.controls || has_line(line, 'controls:')
			continue
		}
		for d in cd_targets(line) {
			e := if d == '' { '' } else { expand(slashes(d), cmd, home) }
			base = if e == '' {
				'/nowhere-known'
			} else if is_absolute(e) {
				e
			} else {
				base + '/' + e
			}
		}
		if s, e, h := heredoc_start(line) {
			file, append := redirect_target(line[..s] + ' ' + line[e..])
			// Every heredoc body is text, not commands, whether or not it goes to a script file.
			doc = Heredoc{
				...h
				file:   file
				append: append
			}
			in_body = true
		}
	}
	return missing
}

// written_path returns the path a heredoc writes `file` to, or none when it is no scratchpad
// script, including when `file` is '' or cannot be expanded (then `p` names a folder).
fn written_path(file string, cmd string, base string, home string) ?string {
	mut p := expand(slashes(file), cmd, home)
	if !is_absolute(p) {
		p = base + '/' + p
	}
	return if is_scratch_script(p) { p } else { none }
}

// is_ok reports whether heredoc `doc` leaves the file at `p` with both lines.
fn is_ok(doc Heredoc, p string) bool {
	if doc.trace && doc.controls {
		return true
	}
	if doc.append {
		now := os.read_file(p) or { return false }
		return declared(now)
	}
	return false
}
