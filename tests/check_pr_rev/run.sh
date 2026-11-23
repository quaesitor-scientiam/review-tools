#!/usr/bin/env bash
# Cases for hooks/check_pr_rev.sh, each on a scratch repository: a `main` whose page is at rev 7,
# and one commit on a branch. Every case checks the exit code and a text only its own outcome prints.
# Usage: bash tests/check_pr_rev/run.sh      (from anywhere; exits 1 when a case fails)
set -uo pipefail
script="$(cd "$(dirname "$0")/../.." && pwd)/hooks/check_pr_rev.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset GIT_DIR GIT_WORK_TREE
fails=0; n=0
html=reference/code-review-reference.html
page() { printf '<p>Generated 2026-01-01, rev %s (see Changelog)</p>\n' "$1" > "$html"; }
commit() { git add -A && git -c user.name=c -c user.email=c@x -c commit.gpgsign=false commit -q -m "$1"; }
# repo <case>: a fresh repository on branch `pr`, cut from a `main` at rev 7.
repo() {
  mkdir -p "$work/$1/reference" "$work/$1/skills/vreview" && cd "$work/$1" && git init -q -b main . || exit 2
  page 7; echo rules > skills/vreview/SKILL.md; echo doc > README.md
  commit base && git checkout -q -b pr || exit 2
}
# expect <case> <exit code> <text the output must hold> <title> [base]
expect() {
  local out rc
  out="$(bash "$script" . "${5:-main}" "$4" 2>&1)"; rc=$?
  n=$((n + 1))
  if [ "$rc" -eq "$2" ] && { [ -n "$3" ] || [ -z "$out" ]; } && [[ "$out" == *"$3"* ]]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1: exit $rc, expected $2 and '$3'; printed: $out"; fails=$((fails + 1))
  fi
}

repo docs_only; echo more >> README.md; commit c
expect docs_only 0 '' 'docs: a line'
repo next_rev; page 8; echo r8 >> skills/vreview/SKILL.md; commit c
expect next_rev 0 '' 'vreview: rev 8 - a rule'
expect next_rev_other_title 1 "must start with 'vreview: rev 8 - '" 'rev 8: a rule'
expect next_rev_title_of_another_rev 1 "must start with 'vreview: rev 8 - '" 'vreview: rev 80 - a rule'
expect next_rev_title_not_at_the_start 1 "must start with 'vreview: rev 8 - '" 'Revert vreview: rev 8 - a rule'
repo skipped_rev; page 9; commit c
expect skipped_rev 1 'page says rev 9; main is at rev 7, so this PR is rev 8' 'vreview: rev 9 - a rule'
repo lower_rev; page 6; commit c
expect lower_rev 1 'page says rev 6; main is at rev 7' 'vreview: rev 6 - a rule'
# Two PRs took rev 8 and the other one merged: main is at 8 and this branch, not rebased, at 8 too.
repo taken_rev; page 8; echo mine >> skills/vreview/SKILL.md; commit c
git checkout -q main; page 8; echo theirs >> README.md; commit other; git checkout -q pr
expect taken_rev 1 'rev 8 is taken' 'vreview: rev 8 - mine'
repo skill_same_rev; echo typo >> skills/vreview/SKILL.md; commit c
expect skill_same_rev 0 '::notice::' 'vreview: reword a line'
expect same_rev_title_without_a_number 0 '::notice::' 'vreview: rev numbers explained'
expect same_rev_title_quotes_a_rev 0 '::notice::' 'docs: what vreview: rev 7 - says'
repo other_skill_file; echo x > skills/vreview/notes.md; commit c
expect other_skill_file_is_no_rule 0 '' 'docs: notes'
# main changed a SKILL.md after this branch was cut: not this PR's change.
repo main_moved; echo more >> README.md; commit c
git checkout -q main; echo theirs >> skills/vreview/SKILL.md; commit other; git checkout -q pr
expect skill_changed_on_main_only 0 '' 'docs: a line'
repo no_rev_on_page; echo '<p>none</p>' > "$html"; commit c
expect no_rev_on_page 1 'no rev in the page of this PR' 'docs: a line'
repo two_numbers; printf '<p>Generated 2026-01-01, rev 8</p>\n<p>Generated 2025-01-01, rev 3</p>\n' > "$html"; commit c
expect first_rev_on_the_page_counts 0 '' 'vreview: rev 8 - a rule'
repo no_base
expect unknown_base 1 'no rev in the page of no-such-ref' 'docs: a line' no-such-ref

echo "=== check_pr_rev: $((n - fails)) passed, $fails failed ==="
[ "$fails" -eq 0 ]
