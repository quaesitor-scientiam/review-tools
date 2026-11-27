#!/usr/bin/env bash
# PreToolUse gate for the standing rule "No assumed meanings: trace before running"
# (~/.claude/CLAUDE.md): a script Claude writes in a session scratchpad must declare, in its own
# text, one case traced by hand and its control rows:
#
#   # trace: <one concrete case, and what each name holds where it is used>
#   # controls: <the row that must pass and the row that must fail>
#
# (`//` in place of `#` for V). The rule came from a probe whose wrapper function read `"$@"` as
# its own arguments, so all 28 rows failed (vlang/v discussion 29269, PR 4, 2026-11-27).
#
# The check runs when the script is written, not when it runs:
#   - Write: the new content of a scratchpad file ending in .sh, .py, .ps1, .v or .vsh holds both
#     lines.
#   - Edit: the file as it will be after the edit holds both lines: each line is in the new text,
#     or it is in the file now and the replaced text does not hold it.
#   - Bash: the body of a heredoc written into such a file (`cat > f <<EOF`,
#     `cat <<EOF > f`, `tee f <<EOF`, `>>` too) holds both lines. `$NAME` and `${NAME}` in the
#     file's path are expanded from `NAME=value` in the same command, a leading `~/` is the home
#     folder, and a relative path is taken from the last `cd` before it, else from the cwd. An
#     append (`>>`, `tee -a`) to a file that already holds both lines passes.
# Only paths with a `scratchpad` folder in them are checked, and not a file below a folder in the
# scratchpad that holds v.mod, .git, a Makefile, or both vlib and cmd (a copy of a project tree,
# or of the V tree).
#
# Not seen: a script written another way (`printf > f`, `echo > f`, `cp`, `sed -i`, MultiEdit),
# a heredoc whose path this reading cannot expand, a path with a space in it. The hook checks that
# the lines exist, not that they are true.
#
# Reads the payload on stdin with no jq (git-bash has none), as require_code_review.sh does.
# Prints a deny decision, or nothing; always exits 0.
set -uo pipefail

payload="$(cat)"
esc_ph="$(printf '\001')"
nl="$(printf '\002')"
# field NAME: the raw JSON text of the string field NAME (escapes kept).
field() {
  printf '%s' "$payload" | sed -nE "s/.*\"$1\" *: *\"(([^\"\\\\]|\\\\.)*)\".*/\\1/p" | head -1
}
# unescape: undo the JSON string escapes `\\`, `\"` and `\t`; a line break becomes the byte in `nl`.
unescape() {
  sed -e "s/\\\\\\\\/$esc_ph/g" -e "s/\\\\[nr]/$nl/g" -e 's/\\t/ /g' -e 's/\\"/"/g' \
    -e "s/$esc_ph/\\\\/g"
}
has_trace() { grep -Eq '(#|//) *trace:'; }
has_controls() { grep -Eq '(#|//) *controls:'; }
is_absolute() { [[ $1 == /* || $1 =~ ^[A-Za-z]:/ ]]; }

tool="$(field tool_name)"
cwd="$(field cwd | unescape)"
cwd="${cwd//\\//}"

# is_scratch_script PATH: PATH is a script file in a scratchpad, outside any project tree copy.
is_scratch_script() {
  local p="${1//\\//}" d
  case "$p" in
    */scratchpad/*.sh | */scratchpad/*.py | */scratchpad/*.ps1 | */scratchpad/*.v | */scratchpad/*.vsh) ;;
    *) return 1 ;;
  esac
  d="${p%/*}"
  while [[ $d == */scratchpad/* ]]; do
    [ -e "$d/v.mod" ] || [ -e "$d/.git" ] || [ -e "$d/Makefile" ] && return 1
    [ -d "$d/vlib" ] && [ -d "$d/cmd" ] && return 1
    d="${d%/*}"
  done
  return 0
}

missing=""
case "$tool" in
  Write)
    path="$(field file_path | unescape)"
    if is_scratch_script "$path"; then
      content="$(field content)"
      printf '%s' "$content" | has_trace && printf '%s' "$content" | has_controls ||
        missing=" ${path//\\//}"
    fi
    ;;
  Edit)
    path="$(field file_path | unescape)"
    # A file that does not exist yet cannot be edited; the Edit fails on its own.
    if is_scratch_script "$path" && [ -f "$path" ]; then
      old="$(field old_string)"
      new="$(field new_string)"
      kept() { # kept CHECK: the line stays after the edit, or the edit adds it
        printf '%s' "$new" | "$1" && return 0
        "$1" < "$path" && ! printf '%s' "$old" | "$1"
      }
      kept has_trace && kept has_controls || missing=" ${path//\\//}"
    fi
    ;;
  Bash)
    cmd_text="$(field command | unescape)"
    # A heredoc and a script file name in the same command, or nothing to check.
    printf '%s' "$cmd_text" | grep -q '<<' || exit 0
    printf '%s' "$cmd_text" | grep -Eq '\.(sh|py|ps1|vsh|v)([^A-Za-z0-9_]|$)' || exit 0
    # lookup NAME: the value of the last `NAME=value` (or `export NAME=value`) in the command.
    lookup() {
      printf '%s' "$cmd_text" | tr "$nl" '\n' |
        grep -oE "(^|[ ;&|(])(export +)?$1=[^ ;&|)]+" | tail -1 | sed -E "s/^.*$1=//" | tr -d "\"'"
    }
    var_re='\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?'
    # expand WORD: WORD with `~/` and `$NAME` replaced; nothing when a name has no value.
    expand() {
      local t="$1" val i
      [[ $t == '~/'* ]] && t="${HOME:-}/${t#\~/}"
      for i in 1 2 3 4 5 6 7 8; do
        [[ $t =~ $var_re ]] || break
        val="$(lookup "${BASH_REMATCH[1]}")"
        [ -n "$val" ] || return 0
        t="${t/"${BASH_REMATCH[0]}"/$val}"
      done
      [[ $t == *'$'* ]] || printf '%s' "$t"
    }
    base="$cwd"
    # The awk pass prints, in order, `CD<TAB>dir` for each `cd dir`, and
    # `W<TAB>file<TAB>t<TAB>c<TAB>e` for each heredoc written to a file, where t and c are 1 when
    # the body holds that line and e is 1 for an append. An append to a file that already holds
    # both lines keeps them.
    while IFS=$'\t' read -r kind a b c e; do
      if [ "$kind" = CD ]; then
        a="$(expand "${a//\\//}")"
        if [ -z "$a" ]; then
          base="/nowhere-known"
        elif is_absolute "$a"; then
          base="$a"
        else
          base="$base/$a"
        fi
        continue
      fi
      p="$(expand "${a//\\//}")"
      [ -n "$p" ] || continue
      is_absolute "$p" || p="$base/$p"
      is_scratch_script "$p" || continue
      [ "$b" = 1 ] && [ "$c" = 1 ] && continue
      [ "$e" = 1 ] && [ -f "$p" ] && has_trace < "$p" && has_controls < "$p" && continue
      missing="$missing $p"
    done < <(printf '%s\n' "$cmd_text" | tr "$nl" '\n' | awk '
      function target(s,    w, pre) {
        # the first file after `>` or `tee [-a]` that names a script, without quotes; for `>>`
        # the match starts at the second `>`, and `2>/dev/null` and the like are passed over.
        # Sets `app` to 1 for an append (`>>`, `tee -a`).
        while (match(s, /(>|tee[ \t]+(-a[ \t]+)?)[ \t]*[^ \t;&|<>]+/)) {
          w = substr(s, RSTART, RLENGTH)
          pre = RSTART > 1 ? substr(s, RSTART - 1, 1) : ""
          s = substr(s, RSTART + RLENGTH)
          app = (pre == ">" || w ~ /^tee[ \t]+-a/)
          sub(/^(>|tee[ \t]+(-a[ \t]+)?)[ \t]*/, "", w)
          gsub(/["\047]/, "", w)
          if (w ~ /\.(sh|py|ps1|v|vsh)$/) return w
        }
        return ""
      }
      {
        line = $0
        if (in_body) {
          probe = line
          # `<<-` drops leading tabs; the unescape has turned a tab into a space
          if (strip) sub(/^[ \t]+/, "", probe)
          if (probe == delim) {
            if (file != "") printf "W\t%s\t%d\t%d\t%d\n", file, t, c, fapp
            in_body = 0
            next
          }
          if (line ~ /(#|\/\/) *trace:/) t = 1
          if (line ~ /(#|\/\/) *controls:/) c = 1
          next
        }
        rest = line
        while (match(rest, /(^|[;&|( \t])cd[ \t]+[^ \t;&|)]+/)) {
          d = substr(rest, RSTART, RLENGTH); sub(/^[;&|( \t]?cd[ \t]+/, "", d); gsub(/["\047]/, "", d)
          if (d == "-") d = ""
          printf "CD\t%s\n", d
          rest = substr(rest, RSTART + RLENGTH)
        }
        if (match(line, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
          h = substr(line, RSTART, RLENGTH)
          strip = (h ~ /^<<-/)
          sub(/^<<-?[ \t]*/, "", h); gsub(/["\047]/, "", h)
          # Every heredoc body is text, not commands, whether or not it goes to a script file.
          file = target(substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH))
          delim = h; in_body = 1; t = 0; c = 0; fapp = app
        }
      }')
    ;;
esac

[ -n "$missing" ] || exit 0
reason="trace before running (~/.claude/CLAUDE.md, \"No assumed meanings\"): a script written to"
reason="$reason the scratchpad needs a '# trace:' line (one concrete case traced by hand: what each"
reason="$reason name holds where it is used) and a '# controls:' line (the row that must pass and"
reason="$reason the row that must fail, run first); missing in:$missing"
reason="$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
exit 0
