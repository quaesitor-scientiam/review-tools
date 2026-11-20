#!/usr/bin/env bash
# Cases for tools/install_answer_rules.sh. Every target is a scratch file; nothing under the
# user's home is touched.
# Usage: bash tests/install_answer_rules/run.sh      (from anywhere; exits with the failure count)
set -uo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
script="$repo/tools/install_answer_rules.sh"
rules="$repo/global/answer-rules.md"
format="$repo/global/answer-format.md"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mark='### A weakness you list is work to do, not a disclosure'
fails=0
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; fails=$((fails + 1)); fi; }
# install <case> <target>: runs the installer; its output goes to $work/<case>.out, its exit to rc.
# The installer runs under the same bash as this file, so `/bin/bash run.sh` tests bash 3.2.
install() { "$BASH" "$script" "$2" > "$work/$1.out" 2>&1; rc=$?; }
# says <case> <text>: the installer's output starts with that text.
says() { [ "$(head -c ${#2} "$work/$1.out")" = "$2" ]; }
count() { grep -c "$1" "$2" || true; }

# A machine's file before the install: its own Answer Format section (worded its own way), then
# other sections.
{
  printf '# Global Preferences\n\n## Answer Format (standing rule, applies everywhere)\n\n'
  printf '1. Give the answer.\n2. **Skeptical review:** list the gaps.\n3. **Revised answer:** the delta.\n\n'
  printf 'Applies to all substantive answers; this machine has its own hook.\n\n'
} > "$work/head.md"
printf '## Environment\n\n- **Shell:** zsh\n\n## Notes\n\n- one\n' > "$work/tail.md"
cat "$work/head.md" "$work/tail.md" > "$work/before.md"
{ cat "$work/head.md" "$rules"; printf '\n'; cat "$work/tail.md"; } > "$work/after.md"

echo "A. no file yet"
install a "$work/a/CLAUDE.md"
check "exit 0 and says created" "[ $rc -eq 0 ] && says a 'created: '"
{ printf '# Global Preferences\n\n'; cat "$format"; printf '\n'; cat "$rules"; } > "$work/a.want"
check "a title, the format block, the rules, byte for byte" "cmp -s \"$work/a/CLAUDE.md\" \"$work/a.want\""
check "no backup made" "[ ! -e \"$work/a/CLAUDE.md.bak-answer-rules\" ]"

echo "B. an Answer Format section followed by other sections"
mkdir -p "$work/b"; cp "$work/before.md" "$work/b/CLAUDE.md"
install b "$work/b/CLAUDE.md"
check "exit 0 and says added" "[ $rc -eq 0 ] && says b 'added to the Answer Format section of '"
check "the rules sit at the end of that section, byte for byte" "cmp -s \"$work/b/CLAUDE.md\" \"$work/after.md\""
check "the backup is the file as it was" "cmp -s \"$work/b/CLAUDE.md.bak-answer-rules\" \"$work/before.md\""

echo "C. run again on the result of B"
install c "$work/b/CLAUDE.md"
check "exit 0 and says already there" "[ $rc -eq 0 ] && says c 'already there: '"
check "the file is unchanged" "cmp -s \"$work/b/CLAUDE.md\" \"$work/after.md\""

echo "D. the Answer Format section is the last one"
mkdir -p "$work/d"; cp "$work/head.md" "$work/d/CLAUDE.md"
install d "$work/d/CLAUDE.md"
{ cat "$work/head.md"; printf '\n'; cat "$rules"; } > "$work/d.want"
check "exit 0, the rules follow it, byte for byte" "[ $rc -eq 0 ] && cmp -s \"$work/d/CLAUDE.md\" \"$work/d.want\""

echo "E. a file with neither the heading nor the format"
mkdir -p "$work/e"; printf '# Mine\n\n## Shell\n\n- use zsh\n' > "$work/e/CLAUDE.md"
install e "$work/e/CLAUDE.md"
check "exit 0 and says appended the format and the rules" "[ $rc -eq 0 ] && says e 'appended the format and the rules to '"
{ printf '# Mine\n\n## Shell\n\n- use zsh\n\n'; cat "$format"; printf '\n'; cat "$rules"; } > "$work/e.want"
check "own content, then the format block and the rules, byte for byte" "cmp -s \"$work/e/CLAUDE.md\" \"$work/e.want\""

echo "F. a target path with a space"
install f "$work/f dir/CLAUDE.md"
check "exit 0 and created" "[ $rc -eq 0 ] && says f 'created: ' && grep -qF \"$mark\" \"$work/f dir/CLAUDE.md\""

echo "G. the rules file is missing"
mkdir -p "$work/g/tools" "$work/g/global"; cp "$script" "$work/g/tools/"; cp "$format" "$work/g/global/"
"$BASH" "$work/g/tools/install_answer_rules.sh" "$work/g/CLAUDE.md" > "$work/g.out" 2>&1; rc=$?
check "exit 2 and no target written" "[ $rc -eq 2 ] && [ ! -e \"$work/g/CLAUDE.md\" ]"

echo "H. the heading written another way: other letter case, other level"
n=0
for heading in '## Answer format' '# ANSWER FORMAT (mine)' '### Answer Format'; do
  n=$((n + 1)); mkdir -p "$work/h$n"
  printf '# T\n\n%s\n\n2. **Skeptical review:** x\n\n# Next top\n\n- z\n' "$heading" > "$work/h$n/CLAUDE.md"
  install "h$n" "$work/h$n/CLAUDE.md"
  { printf '# T\n\n%s\n\n2. **Skeptical review:** x\n\n' "$heading"; cat "$rules"; printf '\n# Next top\n\n- z\n'; } > "$work/h$n.want"
  check "[$heading] added inside that section, no second format block" "[ $rc -eq 0 ] && says h$n 'added to ' && cmp -s \"$work/h$n/CLAUDE.md\" \"$work/h$n.want\""
done

echo "I. a section ends at a heading of its own level or above, not at a deeper one"
mkdir -p "$work/i"
body='1. a\n\n### Answer Format details\n\n- d\n\n#not-a-heading, no space after the hash\n\n### More of it\n\n- m\n\n'
printf "# T\n\n## Answer Format\n\n${body}## Next\n\n- z\n" > "$work/i/CLAUDE.md"
install i "$work/i/CLAUDE.md"
{ printf "# T\n\n## Answer Format\n\n${body}"; cat "$rules"; printf '\n## Next\n\n- z\n'; } > "$work/i.want"
check "the rules come after the deeper headings, before the next section" "[ $rc -eq 0 ] && cmp -s \"$work/i/CLAUDE.md\" \"$work/i.want\""

echo "J. two Answer Format headings"
mkdir -p "$work/j"
printf '# T\n\n## Answer Format\n\n1. a\n\n## Other\n\nx\n\n## Answer Format (again)\n\n2. b\n' > "$work/j/CLAUDE.md"
install j "$work/j/CLAUDE.md"
{ printf '# T\n\n## Answer Format\n\n1. a\n\n'; cat "$rules"; printf '\n## Other\n\nx\n\n## Answer Format (again)\n\n2. b\n'; } > "$work/j.want"
check "the rules go into the first one, once" "[ $rc -eq 0 ] && cmp -s \"$work/j/CLAUDE.md\" \"$work/j.want\""

echo "K. a # line inside a code fence is not a heading"
mkdir -p "$work/k"
printf '# T\n\n## Answer Format\n\n```sh\n# Answer Format in a comment\n## not a heading\necho x\n```\n\n## Next\n\n- z\n' > "$work/k/CLAUDE.md"
install k "$work/k/CLAUDE.md"
{ printf '# T\n\n## Answer Format\n\n```sh\n# Answer Format in a comment\n## not a heading\necho x\n```\n\n'; cat "$rules"; printf '\n## Next\n\n- z\n'; } > "$work/k.want"
check "the rules come after the fence, before the next section" "[ $rc -eq 0 ] && cmp -s \"$work/k/CLAUDE.md\" \"$work/k.want\""
mkdir -p "$work/k2"
printf '# T\n\n```md\n## Answer Format\n```\n\n## Shell\n\n- z\n' > "$work/k2/CLAUDE.md"
install k2 "$work/k2/CLAUDE.md"
check "a heading that is only inside a fence does not count as the section" "[ $rc -eq 0 ] && says k2 'appended the format and the rules to '"

echo "L. the format is there under another heading"
mkdir -p "$work/l"
printf '# T\n\n## How I answer\n\n1. Give the answer.\n2. **Skeptical Review:** x\n3. **Revised answer:** y\n\n## Env\n\n- z\n' > "$work/l/CLAUDE.md"
cp "$work/l/CLAUDE.md" "$work/l.before"
install l "$work/l/CLAUDE.md"
check "exit 0 and says appended the rules" "[ $rc -eq 0 ] && says l 'appended the rules to '"
{ cat "$work/l.before"; printf '\n'; cat "$rules"; } > "$work/l.want"
check "the rules alone are appended: no second format block" "cmp -s \"$work/l/CLAUDE.md\" \"$work/l.want\""

echo "M. a file whose lines end in CRLF"
mkdir -p "$work/m"
printf '# T\r\n\r\n## Answer Format\r\n\r\n1. a\r\n\r\n## Env\r\n\r\n- z\r\n' > "$work/m/CLAUDE.md"
install m "$work/m/CLAUDE.md"
check "exit 0, the rules once, before the next section" "[ $rc -eq 0 ] && [ \$(count \"^### A weakness\" \"$work/m/CLAUDE.md\") -eq 1 ] && [ \$(grep -n '^### A weakness' \"$work/m/CLAUDE.md\" | cut -d: -f1) -lt \$(grep -n '^## Env' \"$work/m/CLAUDE.md\" | cut -d: -f1) ]"
check "its own lines still end in CRLF" "[ \$(grep -c \$'\\r\$' \"$work/m/CLAUDE.md\") -eq 9 ]"

echo "N. a target that is a link, and one that is a folder"
mkdir -p "$work/n"; cp "$work/before.md" "$work/n/real.md"; ln -s "$work/n/real.md" "$work/n/CLAUDE.md"
install n "$work/n/CLAUDE.md"
check "the link stays a link and the file behind it gets the rules" "[ $rc -eq 0 ] && [ -L \"$work/n/CLAUDE.md\" ] && cmp -s \"$work/n/real.md\" \"$work/after.md\""
mkdir -p "$work/n2/CLAUDE.md"
install n2 "$work/n2/CLAUDE.md"
check "a folder at the target is an error, and nothing is put in it" "[ $rc -ne 0 ] && [ -z \"\$(ls -A \"$work/n2/CLAUDE.md\")\" ]"
check "it says the target is not a file, and never that it created it" "grep -q 'is not a regular file' \"$work/n2.out\" && ! grep -q '^created' \"$work/n2.out\""

echo "O. a file this account cannot write"
if [ "$(id -u)" -eq 0 ]; then
  echo "  skipped: root can write every file"
else
  mkdir -p "$work/o"; cp "$work/before.md" "$work/o/CLAUDE.md"; chmod a-w "$work/o/CLAUDE.md"
  install o "$work/o/CLAUDE.md"
  check "refused with exit 1, and it says why" "[ $rc -eq 1 ] && grep -q 'cannot be written' \"$work/o.out\""
  check "the file is unchanged and no backup is left" "cmp -s \"$work/o/CLAUDE.md\" \"$work/before.md\" && [ ! -e \"$work/o/CLAUDE.md.bak-answer-rules\" ]"
  chmod u+w "$work/o/CLAUDE.md"
  # A new file in a folder this account cannot write: the write fails, and bash 3.2 does not
  # stop for that under `set -e`, so only the write's own `|| exit 1` keeps "created" unsaid.
  mkdir -p "$work/o2"; chmod a-w "$work/o2"
  install o2 "$work/o2/CLAUDE.md"
  check "a new file in a folder it cannot write fails, and never says created" "[ $rc -ne 0 ] && ! grep -q '^created' \"$work/o2.out\" && [ ! -e \"$work/o2/CLAUDE.md\" ]"
  chmod u+w "$work/o2"
fi

echo "P. a link at the target that another account made"
if [ "$(id -u)" -ne 0 ]; then
  echo "  skipped: making a link for another account needs root (run this file as root to cover it)"
else
  mkdir -p "$work/p"; cp "$work/before.md" "$work/p/real.md"; ln -s "$work/p/real.md" "$work/p/CLAUDE.md"
  chown -h 65534 "$work/p/CLAUDE.md"
  install p "$work/p/CLAUDE.md"
  check "refused with exit 1, and it says why" "[ $rc -eq 1 ] && grep -q 'a link that another account made' \"$work/p.out\""
  check "the file behind the link is unchanged and no backup is left" "cmp -s \"$work/p/real.md\" \"$work/before.md\" && [ ! -e \"$work/p/CLAUDE.md.bak-answer-rules\" ]"
  # The owner is asked about for a link only: a plain file that this account can write is
  # changed whoever owns it.
  mkdir -p "$work/p2"; cp "$work/before.md" "$work/p2/CLAUDE.md"; chown 65534 "$work/p2/CLAUDE.md"
  install p2 "$work/p2/CLAUDE.md"
  check "a plain file of another account that can be written gets the rules" "[ $rc -eq 0 ] && says p2 'added to ' && cmp -s \"$work/p2/CLAUDE.md\" \"$work/after.md\""
  # A dangling link of another account: no file yet, so the create path is the one that runs.
  mkdir -p "$work/p3"; ln -s "$work/p3/elsewhere.md" "$work/p3/CLAUDE.md"
  chown -h 65534 "$work/p3/CLAUDE.md"
  install p3 "$work/p3/CLAUDE.md"
  check "a dangling link of another account is refused, and nothing is made where it points" "[ $rc -eq 1 ] && grep -q 'a link that another account made' \"$work/p3.out\" && [ ! -e \"$work/p3/elsewhere.md\" ]"
fi
# The same dangling link made by this account is followed, and the file is made where it points.
echo "Q. a dangling link this account made"
mkdir -p "$work/q"; ln -s "$work/q/elsewhere.md" "$work/q/CLAUDE.md"
install q "$work/q/CLAUDE.md"
check "the file is made where the link points, and the link stays" "[ $rc -eq 0 ] && says q 'created: ' && [ -L \"$work/q/CLAUDE.md\" ] && [ -f \"$work/q/elsewhere.md\" ]"

# Case P needs root to make a link another account owns. Here the installer runs with an `id`
# that reports another account's number, so this account's own links look like someone else's:
# the owner check is reached on every path without root.
echo "R. a link seen as another account's, without root"
mkdir -p "$work/shim"; printf '#!/bin/sh\necho 65534\n' > "$work/shim/id"; chmod +x "$work/shim/id"
mkdir -p "$work/r"; ln -s "$work/r/elsewhere.md" "$work/r/CLAUDE.md"
PATH="$work/shim:$PATH" "$BASH" "$script" "$work/r/CLAUDE.md" > "$work/r.out" 2>&1; rc=$?
check "a dangling link is refused before the file is made where it points" "[ $rc -eq 1 ] && grep -q 'a link that another account made' \"$work/r.out\" && [ ! -e \"$work/r/elsewhere.md\" ]"
mkdir -p "$work/r2"; cp "$work/after.md" "$work/r2/real.md"; ln -s "$work/r2/real.md" "$work/r2/CLAUDE.md"
PATH="$work/shim:$PATH" "$BASH" "$script" "$work/r2/CLAUDE.md" > "$work/r2.out" 2>&1; rc=$?
check "a link to a file that already has the rules is refused too, not reported as there" "[ $rc -eq 1 ] && ! grep -q '^already there' \"$work/r2.out\""

echo "failures: $fails"
exit $fails
