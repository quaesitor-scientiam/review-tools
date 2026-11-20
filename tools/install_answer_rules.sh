#!/usr/bin/env bash
# install_answer_rules.sh: puts the standing answer rules of global/answer-rules.md into the
# user's global Claude Code instructions, on a machine that does not have them yet.
#
# Usage: bash tools/install_answer_rules.sh [target]
#   [target]  the instructions file; default ~/.claude/CLAUDE.md
#
# What it does, by what the target holds. Each prints its own first word:
#   the rules already                 nothing ("already there")
#   no file                           creates it: a title, the Answer Format block, the rules
#                                     ("created")
#   a heading "Answer Format"         inserts the rules at the end of that section, the first one
#   (any level, any letter case)      if there are several ("added")
#   no such heading, but the words    appends the rules alone: the format is there under another
#   "skeptical review"                heading and is left as it is ("appended the rules")
#   neither                           appends the Answer Format block and the rules ("appended
#                                     the format and the rules")
# A section ends at the next heading of its own level or above; a `#` line inside a ``` fence is
# not a heading. A changed file is first copied to <target>.bak-answer-rules, replacing an
# earlier backup. Run it again any time: it changes nothing once the rules are there. It does
# not update rules that are already there; for that, delete the old section from the target by
# hand and run it again. The lines it adds end in LF, also in a file whose own lines end in
# CRLF. A target that is a link of this account's own stays one, and the file behind it is
# changed; a link that another account made is refused. A file this account cannot write is
# refused too, before any backup is made (exit 1 in both cases).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
rules="$root/global/answer-rules.md"
format="$root/global/answer-format.md"
target="${1:-$HOME/.claude/CLAUDE.md}"
mark='### A weakness you list is work to do, not a disclosure'

for f in "$rules" "$format"; do
  [ -f "$f" ] || { echo "install_answer_rules: missing $f" >&2; exit 2; }
done

if [ -f "$target" ] && grep -qF "$mark" "$target"; then
  echo "already there: $target"
  exit 0
fi

mkdir -p "$(dirname "$target")"

if [ ! -f "$target" ]; then
  {
    printf '# Global Preferences\n\n'
    cat "$format"
    printf '\n'
    cat "$rules"
  } > "$target"
  echo "created: $target"
  exit 0
fi

# Nothing is written, a backup included, when the result could not be.
if [ -L "$target" ] && [ -z "$(find "$target" -maxdepth 0 -user "$(id -u)" 2>/dev/null)" ]; then
  echo "install_answer_rules: $target is a link that another account made; not followed" >&2
  exit 1
fi
if [ ! -w "$target" ]; then
  echo "install_answer_rules: $target cannot be written by this account" >&2
  exit 1
fi

backup="$target.bak-answer-rules"
cp "$target" "$backup"

# 1 when the file has an Answer Format heading outside every ``` fence, else 0.
has_section="$(awk '
  /^```/ { fence = !fence; next }
  !fence && tolower($0) ~ /^#+ +answer format/ { found = 1 }
  END { print found + 0 }
' "$backup")"

if [ "$has_section" = 1 ]; then
  awk -v rules="$rules" '
    function emit(   line) {
      while ((getline line < rules) > 0) print line
      close(rules)
    }
    # level: how many # a heading line starts with, 0 for any other line.
    function level(s,   n) {
      n = 0
      while (substr(s, n + 1, 1) == "#") n++
      return (n > 0 && substr(s, n + 1, 1) == " ") ? n : 0
    }
    /^```/ { fence = !fence; print; next }
    fence { print; next }
    { lv = level($0) }
    !done && !in_format && tolower($0) ~ /^#+ +answer format/ {
      in_format = 1; format_level = lv; print; next
    }
    in_format && lv > 0 && lv <= format_level { emit(); print ""; in_format = 0; done = 1 }
    { print }
    END { if (in_format) { print ""; emit() } }
  ' "$backup" > "$target"
  echo "added to the Answer Format section of $target (backup: $backup)"
elif grep -qi 'skeptical review' "$backup"; then
  {
    cat "$backup"
    printf '\n'
    cat "$rules"
  } > "$target"
  echo "appended the rules to $target, which has the format under another heading (backup: $backup)"
else
  {
    cat "$backup"
    printf '\n'
    cat "$format"
    printf '\n'
    cat "$rules"
  } > "$target"
  echo "appended the format and the rules to $target (backup: $backup)"
fi
