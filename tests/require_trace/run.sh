#!/usr/bin/env bash
# Cases for hooks/require_trace.sh. Each case feeds the hook a PreToolUse payload for a Write,
# an Edit or a Bash call, and checks whether the hook denies it. The first two cases are the
# controls: a Write of a declared script must pass and one of an undeclared script must be
# denied; the run stops if either is wrong, as then no other row means anything.
# Usage: bash tests/require_trace/run.sh      (from anywhere; exits 1 when a case fails)
#
# trace: case write_bad: `write <pad>/scratchpad/new_bad.sh 'echo bad'` builds
#   {"tool_name":"Write","tool_input":{"file_path":".../scratchpad/new_bad.sh","content":"echo bad"}};
#   the hook reads tool_name Write, the path is a scratchpad .sh file outside any tree copy, the
#   content has neither line, so it prints a deny; `expect` sees "deny" and wants deny.
# controls: write_ok must pass, write_bad must be denied.
set -uo pipefail
hook="$(cd "$(dirname "$0")/../.." && pwd)/hooks/require_trace.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pad="$work/session/scratchpad"
out_of_pad="$work/elsewhere"
mkdir -p "$pad" "$out_of_pad"
# HOME is outside the scratchpad, except in the row about `~/` (HOOK_HOME).
mkdir -p "$work/home"
export HOME="$work/home"
decl='# trace: one case
# controls: a pass row and a fail row'
# Files an Edit acts on. Every name says what the file holds.
printf '#!/bin/bash\n%s\necho declared\n' "$decl" > "$pad/declared.sh"
printf '#!/bin/bash\necho undeclared\n' > "$pad/undeclared.sh"
printf "#!/bin/bash\n# trace: only\n" > "$pad/trace_only.sh"
printf 'notes\n' > "$pad/notes.txt"
mkdir -p "$pad/tree/sub" "$pad/gittree/.git" "$pad/maketree" "$pad/vtree/vlib" "$pad/vtree/cmd" \
  "$pad/vlibonly/vlib"
printf 'Module { name: "tree" }\n' > "$pad/tree/v.mod"
printf 'all:\n' > "$pad/maketree/Makefile"
fails=0; n=0

# json STRING: STRING as a JSON string body.
json() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
# expect <case> allow|deny <payload>
expect() {
  local out got
  out="$(printf '%s' "$3" | HOME="${HOOK_HOME:-$HOME}" bash "$hook" 2>&1)"
  if [[ "$out" == *'"permissionDecision":"deny"'* ]]; then got=deny; else got=allow; fi
  n=$((n + 1))
  if [ "$got" = "$2" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1: got $got, wanted $2; printed: $out"; fails=$((fails + 1))
  fi
}
write() {
  printf '{"session_id":"t","cwd":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":"%s"}}' \
    "$(json "$work")" "$(json "$1")" "$(json "$2")"
}
edit() {
  printf '{"session_id":"t","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"%s","new_string":"%s"}}' \
    "$(json "$work")" "$(json "$1")" "$(json "$2")" "$(json "$3")"
}
# run <command> [cwd]
run() {
  printf '{"session_id":"t","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s","description":"d"}}' \
    "$(json "${2:-$work}")" "$(json "$1")"
}

expect write_ok allow "$(write "$pad/new_ok.sh" "#!/bin/bash
$decl
echo ok")"
expect write_bad deny "$(write "$pad/new_bad.sh" 'echo bad')"
if [ "$fails" -ne 0 ]; then echo "controls failed: the other rows prove nothing"; exit 1; fi

# Write
expect write_trace_only deny "$(write "$pad/half.sh" '# trace: only this')"
expect write_controls_only deny "$(write "$pad/half2.sh" '# controls: only this')"
expect write_v_slashes allow "$(write "$pad/probe.v" '// trace: a case
// controls: pass and fail
fn main() {}')"
expect write_v_bad deny "$(write "$pad/probe_bad.v" 'fn main() {}')"
expect write_vsh_bad deny "$(write "$pad/s.vsh" 'println(1)')"
expect write_py_bad deny "$(write "$pad/s.py" 'print(1)')"
expect write_ps1_bad deny "$(write "$pad/s.ps1" 'Write-Output 1')"
expect write_not_a_script allow "$(write "$pad/notes2.txt" 'text')"
expect write_outside_scratchpad allow "$(write "$out_of_pad/s.sh" 'echo out')"
expect write_windows_path deny "$(write 'C:\Users\x\scratchpad\win.sh' 'echo win')"
expect write_project_copy allow "$(write "$pad/tree/sub/x.sh" 'echo tree')"
expect write_git_copy allow "$(write "$pad/gittree/x.sh" 'echo git')"
expect write_make_copy allow "$(write "$pad/maketree/x.sh" 'echo make')"
expect write_v_tree_copy allow "$(write "$pad/vtree/vlib/x_test.v" 'fn test_x() {}')"
expect write_vlib_alone deny "$(write "$pad/vlibonly/vlib/x_test.v" 'fn test_x() {}')"

# Edit
expect edit_body_of_declared allow "$(edit "$pad/declared.sh" 'echo declared' 'echo changed')"
expect edit_removes_trace deny "$(edit "$pad/declared.sh" '# trace: one case' '# nothing')"
expect edit_removes_controls deny "$(edit "$pad/declared.sh" '# controls: a pass row and a fail row' '')"
expect edit_moves_trace allow "$(edit "$pad/declared.sh" '# trace: one case' '# trace: another case')"
expect edit_adds_both allow "$(edit "$pad/undeclared.sh" 'echo undeclared' "$decl
echo undeclared")"
expect edit_adds_trace_only deny "$(edit "$pad/undeclared.sh" 'echo undeclared' '# trace: x')"
expect edit_keeps_undeclared deny "$(edit "$pad/undeclared.sh" 'echo undeclared' 'echo still')"
expect edit_missing_file allow "$(edit "$pad/gone.sh" 'a' 'b')"
expect edit_not_a_script allow "$(edit "$pad/notes.txt" 'notes' 'more')"

# Bash heredocs
expect heredoc_declared allow "$(run "cat > $pad/h_ok.sh <<'EOF'
#!/bin/bash
$decl
echo ok
EOF
bash $pad/h_ok.sh")"
expect heredoc_bad deny "$(run "cat > $pad/h_bad.sh <<'EOF'
echo bad
EOF")"
expect heredoc_target_after deny "$(run "cat <<'EOF' > $pad/h_after.sh
echo after
EOF")"
expect heredoc_tee deny "$(run "tee $pad/h_tee.sh <<EOF >/dev/null
echo tee
EOF")"
expect heredoc_tee_a deny "$(run "tee -a $pad/h_teea.sh <<EOF
echo tee
EOF")"
expect heredoc_append deny "$(run "cat >> $pad/h_app.sh << \"EOF\"
echo app
EOF")"
# An append keeps the lines a file already has; an overwrite does not.
expect append_to_declared allow "$(run "cat >> $pad/declared.sh <<'EOF'
echo more
EOF")"
expect tee_a_to_declared allow "$(run "tee -a $pad/declared.sh <<'EOF'
echo more
EOF")"
expect append_to_undeclared deny "$(run "cat >> $pad/undeclared.sh <<'EOF'
echo more
EOF")"
expect append_to_trace_only deny "$(run "cat >> $pad/trace_only.sh <<'EOF'
echo more
EOF")"
expect overwrite_declared deny "$(run "cat > $pad/declared.sh <<'EOF'
echo replaced
EOF")"
expect tee_overwrite_declared deny "$(run "tee $pad/declared.sh <<'EOF'
echo replaced
EOF")"
expect heredoc_dash_tab deny "$(run "cat > $pad/h_tab.sh <<-EOF
	echo tab
	EOF")"
expect heredoc_dash_tab_ok allow "$(run "cat > $pad/h_tab_ok.sh <<-EOF
	# trace: x
	# controls: y
	EOF")"
expect heredoc_body_ends_at_delimiter deny "$(run "cat > $pad/h_end.sh <<'EOF'
echo end
EOF
# trace: not in the file
# controls: not in the file")"
expect heredoc_var deny "$(run "S=$pad; cat > \$S/h_var.sh <<'EOF'
echo var
EOF")"
expect heredoc_braced_var deny "$(run "S=$pad; cat > \${S}/h_var2.sh <<'EOF'
echo var
EOF")"
HOOK_HOME="$pad" expect heredoc_tilde deny "$(run "cat > ~/h_tilde.sh <<'EOF'
echo tilde
EOF" "$out_of_pad")"
expect heredoc_relative_after_cd deny "$(run "cd $pad && cat > h_rel.sh <<'EOF'
echo rel
EOF" "$out_of_pad")"
expect heredoc_relative_from_cwd allow "$(run "cat > h_rel2.sh <<'EOF'
echo rel
EOF" "$out_of_pad")"
expect heredoc_relative_cwd_pad deny "$(run "cat > h_rel3.sh <<'EOF'
echo rel
EOF" "$pad")"
expect heredoc_cd_out_of_pad allow "$(run "cd $out_of_pad && cat > h_out.sh <<'EOF'
echo out
EOF" "$pad")"
expect heredoc_relative_cd deny "$(run "cd session/scratchpad && cat > h_rel4.sh <<'EOF'
echo rel
EOF" "$work")"
expect heredoc_trace_only deny "$(run "cat > $pad/h_half.sh <<'EOF'
# trace: only this
EOF")"
# A heredoc that writes no file is text too: a `cd` in it moves nothing.
expect heredoc_body_not_parsed deny "$(run "python3 - <<'EOF'
cd $out_of_pad
EOF
cat > h_rel5.sh <<'EOF'
echo rel
EOF" "$pad")"
expect heredoc_after_cd_dash allow "$(run "cd $pad && cd - && cat > h_dash.sh <<'EOF'
echo dash
EOF" "$out_of_pad")"
expect heredoc_unresolved_var allow "$(run "cat > \$NOPE/scratchpad/h_nope.sh <<'EOF'
echo nope
EOF")"
expect heredoc_stderr_redirect_first deny "$(run "cat 2>/dev/null > $pad/h_err.sh <<'EOF'
echo err
EOF")"
expect heredoc_stdin_program allow "$(run "python3 - $pad/s.py <<'EOF'
print(open('x.sh').read())
EOF")"
expect heredoc_not_a_script allow "$(run "cat > $pad/h.txt <<'EOF'
text
EOF")"
expect heredoc_project_copy allow "$(run "cat > $pad/tree/h.sh <<'EOF'
echo tree
EOF")"
expect heredoc_second_bad deny "$(run "cat > $pad/h1.sh <<'EOF'
$decl
EOF
cat > $pad/h2.sh <<'EOF'
echo second
EOF")"
expect run_only_is_not_checked allow "$(run "bash $pad/undeclared.sh")"
expect no_heredoc allow "$(run "git status --short")"

echo "$n cases, $fails failed"
[ "$fails" -eq 0 ]
