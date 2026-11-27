#!/usr/bin/env -S v

// Cases for hooks/require_trace.v. Each case feeds the built hook a PreToolUse payload for a
// Write, an Edit or a Bash call, and checks whether it denies it. The first two cases are the
// controls: a Write of a declared script must pass and one of an undeclared script must be
// denied; the run stops if either is wrong, as then no other row means anything.
// Usage: v tests/require_trace/run.vsh [hook binary]   (default bin/require_trace.exe; exits 1
// when a case fails)
//
// trace: case write_bad: write(pad + '/new_bad.sh', 'echo bad') builds {"cwd":...,"tool_name":
//   "Write","tool_input":{"file_path":".../scratchpad/new_bad.sh","content":"echo bad"}} with
//   json2; the hook decodes it, the path is a scratchpad .sh outside any tree copy, the content
//   has neither line, so it prints a deny; expect() finds "deny" in the output and wants deny.
// controls: write_ok must pass, write_bad must be denied.
import x.json2
import os

const root = os.real_path(os.join_path(@DIR, '..', '..'))
const hook = if os.args.len > 1 {
	os.real_path(os.args[1])
} else {
	os.join_path(root, 'bin',
		'require_trace.exe')
}
const work = os.join_path(os.vtmp_dir(), 'require_trace_test_${os.getpid()}')
const pad = os.join_path(work, 'session', 'scratchpad').replace('\\', '/')
const out_of_pad = os.join_path(work, 'elsewhere').replace('\\', '/')
const decl = '# trace: one case\n# controls: a pass row and a fail row'

struct Run {
mut:
	n     int
	fails int
}

// payload returns a PreToolUse payload for `tool` with `input`, run in `cwd`.
fn payload(tool string, input map[string]json2.Any, cwd string) string {
	mut m := map[string]json2.Any{}
	m['session_id'] = json2.Any('t')
	m['cwd'] = json2.Any(cwd)
	m['tool_name'] = json2.Any(tool)
	m['tool_input'] = json2.Any(input)
	return json2.encode(m)
}

fn write(path string, content string) string {
	return payload('Write', {
		'file_path': json2.Any(path)
		'content':   json2.Any(content)
	}, work)
}

fn edit(path string, old string, new string) string {
	return payload('Edit', {
		'file_path':  json2.Any(path)
		'old_string': json2.Any(old)
		'new_string': json2.Any(new)
	}, work)
}

fn run(command string, cwd string) string {
	return payload('Bash', {
		'command':     json2.Any(command)
		'description': json2.Any('d')
	}, cwd)
}

// expect runs the hook on `p` with HOME set to `home` and checks its verdict is `want`. The hook
// is started directly, with the payload file as its stdin, as Claude Code starts it: no shell.
// An allow row whose payload names no scratchpad or no script extension is decided by the hook's
// first lines and tests nothing else, so such a row must be named `fast_*` on purpose.
fn (mut r Run) expect(name string, want string, p string, home string) {
	reaches_check := (p.contains('scratchpad') || home.contains('scratchpad'))
		&& ['.sh', '.py', '.ps1', '.v', '.vsh'].any(p.contains(it))
	if want == 'allow' && !reaches_check && !name.starts_with('fast_') {
		println('  FAIL: ${name}: the payload never reaches the check; name it fast_* or make it reach')
		r.n++
		r.fails++
		return
	}
	f := os.join_path(work, 'payload.json')
	os.write_file(f, p) or { panic(err) }
	mut env := os.environ()
	env['HOME'] = home
	mut process := os.new_process(hook)
	process.set_environment(env)
	process.set_stdin_path(f)
	process.set_redirect_stdio()
	process.run()
	process.wait()
	output := process.stdout_slurp() + process.stderr_slurp()
	code := process.code
	process.close()
	got := if output.contains('"permissionDecision":"deny"') { 'deny' } else { 'allow' }
	r.n++
	if code == 0 && got == want {
		println('  ok: ${name}')
	} else {
		println('  FAIL: ${name}: got ${got} (exit ${code}), wanted ${want}; printed: ${output}')
		r.fails++
	}
}

if !os.is_file(hook) {
	eprintln('no hook binary at ${hook}; build it with: v -o bin/require_trace.exe hooks/require_trace.v')
	exit(2)
}
os.rmdir_all(work) or {}
for d in [pad, out_of_pad, work + '/home', pad + '/tree/sub', pad + '/gittree/.git', pad + '/maketree',
	pad + '/vtree/vlib', pad + '/vtree/cmd', pad + '/vlibonly/vlib'] {
	os.mkdir_all(d) or { panic(err) }
}
defer {
	os.rmdir_all(work) or {}
}
// Files an Edit acts on. Every name says what the file holds.
os.write_file(pad + '/declared.sh', '#!/bin/bash\n${decl}\necho declared\n')!
os.write_file(pad + '/undeclared.sh', '#!/bin/bash\necho undeclared\n')!
os.write_file(pad + '/trace_only.sh', '#!/bin/bash\n# trace: only\n')!
os.write_file(pad + '/notes.txt', 'notes\n')!
os.write_file(pad + '/controls_only.sh', '#!/bin/bash\n# controls: only\necho c\n')!
os.write_file(out_of_pad + '/u.sh', '#!/bin/bash\necho u\n')!
os.mkdir_all(pad + '/cmdonly/cmd')!
os.write_file(pad + '/tree/v.mod', 'Module { name: "tree" }\n')!
os.write_file(pad + '/maketree/Makefile', 'all:\n')!
// HOME is outside the scratchpad, except in the row about `~/`.
home := work.replace('\\', '/') + '/home'
mut r := Run{}

r.expect('write_ok', 'allow', write(pad + '/new_ok.sh', '#!/bin/bash\n${decl}\necho ok'), home)
r.expect('write_bad', 'deny', write(pad + '/new_bad.sh', 'echo bad'), home)
if r.fails != 0 {
	println('controls failed: the other rows prove nothing')
	exit(1)
}

// Write
r.expect('write_trace_only', 'deny', write(pad + '/half.sh', '# trace: only this'), home)
r.expect('write_controls_only', 'deny', write(pad + '/half2.sh', '# controls: only this'), home)
r.expect('write_v_slashes', 'allow', write(pad + '/probe.v', '// trace: a case\n// controls: pass and fail\nfn main() {}'),
	home)
r.expect('write_v_bad', 'deny', write(pad + '/probe_bad.v', 'fn main() {}'), home)
r.expect('write_vsh_bad', 'deny', write(pad + '/s.vsh', 'println(1)'), home)
r.expect('write_py_bad', 'deny', write(pad + '/s.py', 'print(1)'), home)
r.expect('write_ps1_bad', 'deny', write(pad + '/s.ps1', 'Write-Output 1'), home)
r.expect('fast_write_not_a_script', 'allow', write(pad + '/notes2.txt', 'text'), home)
r.expect('write_outside_scratchpad', 'allow', write(out_of_pad + '/s.sh', 'echo scratchpad'), home)
r.expect('write_windows_path', 'deny', write('C:\\Users\\x\\scratchpad\\win.sh', 'echo win'), home)
r.expect('write_project_copy', 'allow', write(pad + '/tree/sub/x.sh', 'echo tree'), home)
r.expect('write_git_copy', 'allow', write(pad + '/gittree/x.sh', 'echo git'), home)
r.expect('write_make_copy', 'allow', write(pad + '/maketree/x.sh', 'echo make'), home)
r.expect('write_v_tree_copy', 'allow', write(pad + '/vtree/vlib/x_test.v', 'fn test_x() {}'), home)
r.expect('write_vlib_alone', 'deny', write(pad + '/vlibonly/vlib/x_test.v', 'fn test_x() {}'),
	home)
r.expect('not_json', 'allow', 'not json, scratchpad .sh', home)

// Edit
r.expect('edit_body_of_declared', 'allow', edit(pad + '/declared.sh', 'echo declared', 'echo changed'),
	home)
r.expect('edit_removes_trace', 'deny', edit(pad + '/declared.sh', '# trace: one case', '# nothing'),
	home)
r.expect('edit_removes_controls', 'deny', edit(pad + '/declared.sh', '# controls: a pass row and a fail row',
	''), home)
r.expect('edit_moves_trace', 'allow', edit(pad + '/declared.sh', '# trace: one case', '# trace: another case'),
	home)
r.expect('edit_adds_both', 'allow', edit(pad + '/undeclared.sh', 'echo undeclared', '${decl}\necho undeclared'),
	home)
r.expect('edit_adds_trace_only', 'deny', edit(pad + '/undeclared.sh', 'echo undeclared', '# trace: x'),
	home)
r.expect('edit_keeps_undeclared', 'deny', edit(pad + '/undeclared.sh', 'echo undeclared', 'echo still'),
	home)
r.expect('edit_missing_file', 'allow', edit(pad + '/gone.sh', 'a', 'b'), home)
r.expect('edit_not_a_script', 'allow', edit(pad + '/notes.txt', 'notes', 'see x.sh'), home)

// Bash heredocs
r.expect('heredoc_declared', 'allow', run("cat > ${pad}/h_ok.sh <<'EOF'\n#!/bin/bash\n${decl}\necho ok\nEOF\nbash ${pad}/h_ok.sh",
	work), home)
r.expect('heredoc_bad', 'deny', run("cat > ${pad}/h_bad.sh <<'EOF'\necho bad\nEOF", work), home)
r.expect('heredoc_target_after', 'deny', run("cat <<'EOF' > ${pad}/h_after.sh\necho after\nEOF",
	work), home)
r.expect('heredoc_tee', 'deny', run('tee ${pad}/h_tee.sh <<EOF >/dev/null\necho tee\nEOF', work),
	home)
r.expect('heredoc_tee_a', 'deny', run('tee -a ${pad}/h_teea.sh <<EOF\necho tee\nEOF', work), home)
r.expect('heredoc_append', 'deny', run('cat >> ${pad}/h_app.sh << "EOF"\necho app\nEOF', work),
	home)
r.expect('append_to_declared', 'allow', run("cat >> ${pad}/declared.sh <<'EOF'\necho more\nEOF",
	work), home)
r.expect('tee_a_to_declared', 'allow', run("tee -a ${pad}/declared.sh <<'EOF'\necho more\nEOF",
	work), home)
r.expect('append_to_undeclared', 'deny', run("cat >> ${pad}/undeclared.sh <<'EOF'\necho more\nEOF",
	work), home)
r.expect('append_to_trace_only', 'deny', run("cat >> ${pad}/trace_only.sh <<'EOF'\necho more\nEOF",
	work), home)
r.expect('overwrite_declared', 'deny', run("cat > ${pad}/declared.sh <<'EOF'\necho replaced\nEOF",
	work), home)
r.expect('tee_overwrite_declared', 'deny', run("tee ${pad}/declared.sh <<'EOF'\necho replaced\nEOF",
	work), home)
r.expect('heredoc_dash_tab', 'deny', run('cat > ${pad}/h_tab.sh <<-EOF\n\techo tab\n\tEOF', work),
	home)
r.expect('heredoc_dash_tab_ok', 'allow', run('cat > ${pad}/h_tab_ok.sh <<-EOF\n\t# trace: x\n\t# controls: y\n\tEOF',
	work), home)
r.expect('heredoc_body_ends_at_delimiter', 'deny', run("cat > ${pad}/h_end.sh <<'EOF'\necho end\nEOF\n# trace: not in the file\n# controls: not in the file",
	work), home)
r.expect('heredoc_var', 'deny', run("S=${pad}; cat > \$S/h_var.sh <<'EOF'\necho var\nEOF", work),
	home)
r.expect('heredoc_braced_var', 'deny', run("S=${pad}; cat > \${S}/h_var2.sh <<'EOF'\necho var\nEOF",
	work), home)
r.expect('heredoc_tilde', 'deny', run("cat > ~/h_tilde.sh <<'EOF'\necho tilde\nEOF", out_of_pad),
	pad)
r.expect('heredoc_relative_after_cd', 'deny', run("cd ${pad} && cat > h_rel.sh <<'EOF'\necho rel\nEOF",
	out_of_pad), home)
r.expect('heredoc_relative_from_cwd', 'allow', run("cat > h_rel2.sh <<'EOF'\necho scratchpad\nEOF",
	out_of_pad), home)
r.expect('heredoc_relative_cwd_pad', 'deny', run("cat > h_rel3.sh <<'EOF'\necho rel\nEOF", pad),
	home)
r.expect('heredoc_cd_out_of_pad', 'allow', run("cd ${out_of_pad} && cat > h_out.sh <<'EOF'\necho out\nEOF",
	pad), home)
r.expect('heredoc_relative_cd', 'deny', run("cd session/scratchpad && cat > h_rel4.sh <<'EOF'\necho rel\nEOF",
	work.replace('\\', '/')), home)
r.expect('heredoc_trace_only', 'deny', run("cat > ${pad}/h_half.sh <<'EOF'\n# trace: only this\nEOF",
	work), home)
// A heredoc that writes no file is text too: a `cd` in it moves nothing.
r.expect('heredoc_body_not_parsed', 'deny', run("python3 - <<'EOF'\ncd ${out_of_pad}\nEOF\ncat > h_rel5.sh <<'EOF'\necho rel\nEOF",
	pad), home)
r.expect('heredoc_after_cd_dash', 'allow', run("cd ${pad} && cd - && cat > h_dash.sh <<'EOF'\necho dash\nEOF",
	out_of_pad), home)
r.expect('heredoc_unresolved_var', 'allow', run("cat > \$NOPE/scratchpad/h_nope.sh <<'EOF'\necho nope\nEOF",
	work), home)
r.expect('heredoc_stderr_redirect_first', 'deny', run("cat 2>/dev/null > ${pad}/h_err.sh <<'EOF'\necho err\nEOF",
	work), home)
r.expect('heredoc_stdin_program', 'allow', run("python3 - ${pad}/s.py <<'EOF'\nprint(open('x.sh').read())\nEOF",
	work), home)
r.expect('here_string_is_no_heredoc', 'allow', run("cat <<< 'EOF' > ${pad}/hs.sh", work), home)
r.expect('heredoc_not_a_script', 'allow', run("cat > ${pad}/h.txt <<'EOF'\nsee x.sh\nEOF", work), home)
r.expect('heredoc_project_copy', 'allow', run("cat > ${pad}/tree/h.sh <<'EOF'\necho tree\nEOF",
	work), home)
r.expect('heredoc_second_bad', 'deny', run("cat > ${pad}/h1.sh <<'EOF'\n${decl}\nEOF\ncat > ${pad}/h2.sh <<'EOF'\necho second\nEOF",
	work), home)
r.expect('run_only_is_not_checked', 'allow', run('bash ${pad}/undeclared.sh', work), home)
r.expect('fast_no_heredoc', 'allow', run('git status --short', work), home)

// Only `#` or `//` before the word marks a line.
r.expect('write_no_comment_marker', 'deny', write(pad + '/nm.sh', 'trace: x\ncontrols: y'), home)
r.expect('write_space_then_trace', 'deny', write(pad + '/sp.sh', ' trace: x'), home)
r.expect('write_slash_at_start', 'deny', write(pad + '/sa.sh', '/trace: a\n/controls: b'), home)
r.expect('write_slash_then_letter', 'deny', write(pad + '/sx.sh', '/x trace: a\n/x controls: b'),
	home)
r.expect('write_one_slash', 'deny', write(pad + '/so.sh', 'a/ trace: a\na/ controls: b'), home)
r.expect('write_txt_names_script', 'allow', write(pad + '/notes3.txt', 'see run.sh'), home)
r.expect('write_cmd_only_tree', 'deny', write(pad + '/cmdonly/x.sh', 'echo'), home)
r.expect('edit_outside_scratchpad', 'allow', edit(out_of_pad + '/u.sh', 'echo u', 'echo scratchpad'), home)
r.expect('edit_controls_only_file', 'deny', edit(pad + '/controls_only.sh', 'echo c', 'echo d'),
	home)
r.expect('edit_backslash_path', 'deny', edit((pad + '/undeclared.sh').replace('/', '\\'), 'echo undeclared',
	'echo x'), home)

// Windows spellings: backslashes, and a drive letter makes a path absolute.
r.expect('heredoc_backslash_cwd', 'deny', run("cat > h_bs.sh <<'EOF'\necho\nEOF", 'C:\\x\\scratchpad'),
	home)
r.expect('heredoc_backslash_home', 'deny', run("cat > ~/h_bsh.sh <<'EOF'\necho\nEOF", out_of_pad),
	pad.replace('/', '\\'))
r.expect('heredoc_backslash_cd', 'deny', run("cd C:\\x\\scratchpad && cat > h.sh <<'EOF'\necho\nEOF",
	out_of_pad), home)
r.expect('heredoc_backslash_file', 'deny', run("cat > C:\\x\\scratchpad\\hb.sh <<'EOF'\necho\nEOF",
	work), home)
r.expect('cd_drive', 'allow', run("cd C:/elsewhere && cat > h.sh <<'EOF'\necho\nEOF", pad), home)
r.expect('cd_drive_only', 'deny', run("cd C: && cat > h.sh <<'EOF'\necho\nEOF", pad), home)
r.expect('cd_digit_colon', 'deny', run("cd 1:/x && cat > h.sh <<'EOF'\necho\nEOF", pad), home)
r.expect('cd_no_colon', 'deny', run("cd ab/c && cat > h.sh <<'EOF'\necho\nEOF", pad), home)
r.expect('cd_colon_no_slash', 'deny', run("cd C:x && cat > h.sh <<'EOF'\necho\nEOF", pad), home)

// Names and values in the path.
r.expect('lookup_longer_name_later', 'deny', run("S=${pad}; XS=${out_of_pad}; cat > \$S/lk.sh <<'EOF'\necho\nEOF",
	work), home)
r.expect('lookup_quoted_value', 'deny', run('S="${pad}"; cat > \$S/q.sh <<\'EOF\'\necho\nEOF',
	work), home)
r.expect('lookup_at_end', 'deny', run("cat > \$S/le.sh <<'EOF'\necho\nEOF\nS=${pad}", work), home)
r.expect('var_underscore', 'deny', run("S_1=${pad}; cat > \$S_1/u.sh <<'EOF'\necho\nEOF", work),
	home)
r.expect('var_digit', 'deny', run("S2=${pad}; cat > \$S2/d.sh <<'EOF'\necho\nEOF", work), home)
r.expect('var_brace_after_plain', 'allow', run("S=${pad}; cat > \$S}/b.sh <<'EOF'\necho\nEOF",
	work), home)
r.expect('var_brace_unclosed', 'deny', run("S=${pad}; cat > \${S/b2.sh <<'EOF'\necho\nEOF", work),
	home)
r.expect('var_dollar_no_name', 'allow', run("echo a =${pad}; cat > \$/n.sh <<'EOF'\necho\nEOF",
	work), home)

// Heredoc operators and delimiters, the ends of lines included.
r.expect('edge_heredoc_end', 'allow', run('cat > ${pad}/e1.sh <<', work), home)
r.expect('edge_heredoc_dash_end', 'allow', run('cat > ${pad}/e2.sh <<-', work), home)
r.expect('edge_heredoc_space_end', 'allow', run('cat > ${pad}/e3.sh << ', work), home)
r.expect('edge_heredoc_quote_end', 'allow', run("cat > ${pad}/e4.sh <<'", work), home)
r.expect('edge_heredoc_word_end', 'allow', run('cat > ${pad}/e5.sh <<EOF', work), home)
r.expect('edge_heredoc_open_quote_end', 'allow', run("cat > ${pad}/e6.sh <<'EOF", work), home)
r.expect('heredoc_tab_before_delim', 'deny', run('cat > ${pad}/ht.sh <<\tEOF\necho\nEOF', work),
	home)
r.expect('delim_underscore', 'deny', run('cat > ${pad}/du.sh <<END_X\necho\nEND_X', work), home)
r.expect('delim_digit', 'deny', run('cat > ${pad}/dd.sh <<END2\necho\nEND2', work), home)
r.expect('delim_missing', 'allow', run('cat > ${pad}/dm.sh << ;\necho\n\n', work), home)
r.expect('delim_digit_start', 'allow', run('cat > ${pad}/ds.sh <<1x\necho\n1x', work), home)
r.expect('delim_then_redirect', 'deny', run('cat <<EOF> ${pad}/dr.sh\necho\nEOF', work), home)

// Redirections and tee.
r.expect('redirect_at_start', 'deny', run('> ${pad}/r0.sh <<EOF\necho\nEOF', work), home)
r.expect('redirect_tab', 'deny', run('cat <<EOF >\t${pad}/rt.sh\necho\nEOF', work), home)
r.expect('redirect_at_end', 'allow', run('cat <<EOF >\necho scratchpad x.sh\nEOF', work), home)
r.expect('redirect_quoted', 'deny', run('cat > "${pad}/rq.sh" <<EOF\necho\nEOF', work), home)
r.expect('argument_is_not_written', 'allow', run('cat <<EOF abc ${pad}/t.sh\necho\nEOF', work),
	home)
r.expect('tee_inside_a_word', 'allow', run('xtee ${pad}/t1.sh <<EOF\necho\nEOF', work), home)
r.expect('tee_after_pipe', 'deny', run('true | tee ${pad}/t2.sh <<EOF\necho\nEOF', work), home)
r.expect('tee_at_end', 'allow', run('cat <<EOF | tee\necho scratchpad x.sh\nEOF', work), home)
r.expect('tee_glued', 'allow', run('tee${pad}/t3.sh <<EOF\necho\nEOF', work), home)
r.expect('tee_spaces_to_end', 'allow', run('cat <<EOF | tee   \necho scratchpad x.sh\nEOF', work), home)
r.expect('tee_tab_append', 'deny', run('tee\t-a\t${pad}/t5.sh <<EOF\necho\nEOF', work), home)
r.expect('tee_second_file', 'deny', run('tee notes.txt ${pad}/t6.sh <<EOF\necho\nEOF', work), home)
r.expect('tee_dot_declared', 'deny', run("tee ./declared.sh <<'EOF'\necho r\nEOF", pad), home)
r.expect('tee_long_append', 'allow', run("tee --append ${pad}/declared.sh <<'EOF'\necho r\nEOF",
	work), home)

// cd forms. A `cd` to a `$` word this reading cannot expand leaves the folder unknown.
r.expect('cd_dollar_alone', 'allow', run("cd \$ && cat > h.sh <<'EOF'\necho\nEOF", pad), home)
r.expect('cd_name_at_end', 'deny', run("S=${pad}; cat > ${pad}/n1.sh <<'EOF'\necho\nEOF\ncd \$S",
	work), home)
r.expect('cd_brace_open_at_end', 'deny', run("S=${pad}; cat > ${pad}/n2.sh <<'EOF'\necho\nEOF\ncd \${S",
	work), home)
r.expect('cd_glued', 'allow', run('cd${pad} && cat > h.sh <<EOF\necho\nEOF', out_of_pad), home)
r.expect('cd_at_end_of_line', 'allow', run("cat > ${pad}/ce.sh <<'EOF'\n${decl}\nEOF\necho; cd",
	work), home)
r.expect('cd_spaces_to_end', 'allow', run("cat > ${pad}/cs.sh <<'EOF'\n${decl}\nEOF\necho; cd   ",
	work), home)
r.expect('cd_tab', 'deny', run('cd\t${pad} && cat > h.sh <<EOF\necho\nEOF', out_of_pad), home)
r.expect('cd_word_at_end', 'allow', run("cat > ${pad}/cw.sh <<'EOF'\n${decl}\nEOF\ncd x", work),
	home)
r.expect('cd_empty_argument', 'deny', run('cd ; cat > h.sh <<EOF\necho\nEOF', pad), home)
r.expect('cd_quoted', 'deny', run('cd "${pad}" && cat > h.sh <<EOF\necho\nEOF', out_of_pad), home)
r.expect('two_cds_on_a_line', 'deny', run('cd ${pad} && cd sub && cat > h.sh <<EOF\necho\nEOF',
	out_of_pad), home)
r.expect('heredoc_controls_only', 'deny', run("cat > ${pad}/hc.sh <<'EOF'\n# controls: only\nEOF",
	work), home)

println('${r.n} cases, ${r.fails} failed')
exit(if r.fails == 0 { 0 } else { 1 })
