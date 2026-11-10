#!/usr/bin/env bash
# check_reference.sh: mechanical checks that a review-tools change kept the
# reference page and both copies of the miss corpus in step. CONTRIBUTING.md
# describes the full recipe; this script checks the parts a script can see.
#
# Usage: check_reference.sh <checkout> [rev]
#   <checkout>  a checkout of the review-tools repo (main clone or worktree)
#   [rev]       the rev being committed, if known (from a "vreview: rev N"
#               commit message); the newest rev named in a SKILL.md is used too
#
# Prints one problem per line and exits 1 when anything is wrong, else exits 0.
# Called by require_code_review.sh before a commit or push in the repo; runnable
# by hand before committing. Needs only bash, git, grep, sed and awk; the JS
# parse check runs when node is on PATH.
set -uo pipefail

root="${1:?usage: check_reference.sh <checkout> [rev]}"
want_rev="${2:-}"
html="$root/reference/code-review-reference.html"
md_rel="reference/code-review-misses.md"
js_rel="reference/code-review-misses-data.js"
problems=""
add() { problems="${problems}- $1"$'\n'; }

[ -f "$html" ] || exit 0

# The rev the page must be at: the highest of the rev being committed and every
# "rev N" a SKILL.md names. A rev's skill text does not always name itself, so
# the commit message rev is the main source.
skill_rev="$(cat "$root"/skills/*/SKILL.md 2>/dev/null | grep -oE 'rev [0-9]+' | awk '{print $2}' | sort -n | tail -1)"
rev="$skill_rev"
if [ -n "$want_rev" ] && { [ -z "$rev" ] || [ "$want_rev" -gt "$rev" ]; }; then rev="$want_rev"; fi

page_rev="$(grep -oE 'Generated [0-9-]+, rev [0-9]+' "$html" | head -1 | awk '{print $NF}')"
if [ -n "$rev" ]; then
  if [ -z "$page_rev" ]; then
    add "page subtitle has no 'Generated DATE, rev N'"
  elif [ "$page_rev" -lt "$rev" ]; then
    add "page subtitle says rev $page_rev; this change is rev $rev (set 'Generated DATE, rev $rev')"
  fi
  grep -q "<div class=\"changelog-body\"><strong>rev $rev</strong>" "$html" ||
    add "no changelog entry '<div class=\"changelog-body\"><strong>rev $rev</strong>' (insert it before the previous rev's entry)"
  grep -qE "\(rev $rev\)(</strong>|</div>|</li>|\.|')" "$html" ||
    add "no page item marked '(rev $rev)': an angle card check-item and angleData panel entry per new bullet, or a Phase R <li> for a process rule"
fi

# Skill text: Claude Code replaces `$N` (a dollar sign and a digit) in a SKILL.md
# with the Nth word of the skill's arguments when it loads, so `ret $4` reached the
# reader as `ret rev` (rev 105). `$ARGUMENTS` is meant and is left alone.
dollar_digit="$(grep -nE '\$[0-9]' "$root"/skills/*/SKILL.md 2>/dev/null | sed "s|^$root/||")"
[ -n "$dollar_digit" ] && while IFS= read -r r; do
  text="${r#*:*:}"
  add "${r%%:*}:$(printf '%s' "$r" | cut -d: -f2) has a \$ and a digit, which skill loading replaces with an argument; reword it: ${text:0:80}"
done <<<"$dollar_digit"

# Corpus rows: what this change adds to the Markdown table must be four cells
# (Class | Angle | What was missed | Detector / check) and must be matched by the
# same number of rows in the data file. Compared on the uncommitted diff, or on
# the unpushed commits when the tree is clean (a push).
if [ -n "$(git -C "$root" status --porcelain --untracked-files=no -- "$md_rel" "$js_rel" 2>/dev/null)" ]; then
  range="HEAD"
elif git -C "$root" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1; then
  range="@{upstream}...HEAD"
else
  range=""
fi
if [ -n "$range" ]; then
  md_diff="$(git -C "$root" diff "$range" -- "$md_rel" 2>/dev/null)"
  js_diff="$(git -C "$root" diff "$range" -- "$js_rel" 2>/dev/null)"
  bad_rows="$(printf '%s\n' "$md_diff" | awk '
    /^\+\| / && !/^\+\|---/ && !/^\+\| Class \|/ {
      line = substr($0, 2); gsub(/\\\|/, "", line)
      sub(/^\| */, "", line); sub(/ *\| *$/, "", line)
      n = split(line, cells, "|")
      if (n != 4) printf "%d cells: %s\n", n, substr($0, 2, 90)
    }')"
  [ -n "$bad_rows" ] && while IFS= read -r r; do
    add "$md_rel row has $r (need 4: Class | Angle | What was missed | Detector / check; escape a pipe in code as \\|)"
  done <<<"$bad_rows"
  md_net="$(printf '%s\n' "$md_diff" | awk '/^\+\| / && !/^\+\|---/ && !/^\+\| Class \|/ {n++} /^-\| / && !/^-\|---/ && !/^-\| Class \|/ {n--} END {print n+0}')"
  js_net="$(printf '%s\n' "$js_diff" | awk '/^\+"<tr>/ {n++} /^-"<tr>/ {n--} END {print n+0}')"
  [ "$md_net" != "$js_net" ] &&
    add "corpus copies disagree: $md_rel gains $md_net row(s), $js_rel gains $js_net (a new row goes in both)"
fi

if command -v node >/dev/null 2>&1; then
  node -e '
    const fs = require("fs"), [js, html] = process.argv.slice(1);
    try { const r = new Function(fs.readFileSync(js, "utf8") + ";return MISS_ROWS")();
          if (!Array.isArray(r)) throw new Error("MISS_ROWS is not an array"); }
    catch (e) { console.log("- " + js + " does not parse: " + e.message); }
    const h = fs.readFileSync(html, "utf8");
    for (const m of h.matchAll(/<script>([\s\S]*?)<\/script>/g)) {
      try { new Function(m[1]); } catch (e) { console.log("- page script does not parse: " + e.message); }
    }
    const o = (h.match(/<div[\s>]/g) || []).length, c = (h.match(/<\/div>/g) || []).length;
    if (o !== c) console.log("- page has " + o + " <div> and " + c + " </div>");
  ' "$root/$js_rel" "$html" >"${TMPDIR:-/tmp}/check_reference.$$" 2>&1
  [ -s "${TMPDIR:-/tmp}/check_reference.$$" ] && problems="${problems}$(cat "${TMPDIR:-/tmp}/check_reference.$$")"$'\n'
  rm -f "${TMPDIR:-/tmp}/check_reference.$$"
fi

if [ -n "$problems" ]; then
  printf '%s' "$problems"
  exit 1
fi
exit 0
