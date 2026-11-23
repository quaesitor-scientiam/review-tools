#!/usr/bin/env bash
# check_pr_rev.sh: the rev a PR takes, checked against the branch it goes into. Run by
# .github/workflows/check.yml on every PR; runnable by hand after `git fetch`.
#
# Usage: check_pr_rev.sh <checkout> <base-ref> <PR title>
#
# The page (its `Generated DATE, rev N`) is either at the base's rev, for a PR that changes no
# rule, or one above it. One above needs a title `vreview: rev N - ...`, which becomes the squash
# commit's subject; at the base's rev such a title means that another PR took the number first.
# A PR that changes a SKILL.md and keeps the rev gets a notice: not every edit is a rule.
# Reads committed content only. Exit 0 when it holds, 1 when not.
set -uo pipefail

root="${1:?usage: check_pr_rev.sh <checkout> <base-ref> <PR title>}"
base="${2:?usage: check_pr_rev.sh <checkout> <base-ref> <PR title>}"
title="${3:?usage: check_pr_rev.sh <checkout> <base-ref> <PR title>}"

# page_rev <ref>: the first rev the page names at that commit, or nothing.
page_rev() {
  git -C "$root" show "$1:reference/code-review-reference.html" 2>/dev/null |
    grep -oE 'Generated [0-9-]+, rev [0-9]+' | awk 'NR == 1 {print $NF}'
}
fail() { echo "check_pr_rev: $1"; exit 1; }

have="$(page_rev HEAD)"
main="$(page_rev "$base")"
[ -n "$have" ] || fail "no rev in the page of this PR"
[ -n "$main" ] || fail "no rev in the page of $base"

if [ "$have" -eq "$main" ]; then
  if [[ "$title" =~ ^vreview:\ rev\ [0-9] ]]; then
    fail "the title names a rev, but rev $main is taken: renumber this PR to rev $((main + 1)) (page, rule text and title)"
  fi
  changed="$(git -C "$root" diff --name-only "$base...HEAD" -- 'skills/*/SKILL.md')" || fail "cannot compare with $base"
  [ -z "$changed" ] || echo "::notice::$(echo $changed) changed and the page stays at rev $have. A new or changed rule needs rev $((have + 1)); a wording fix does not."
elif [ "$have" -eq $((main + 1)) ]; then
  [[ "$title" == "vreview: rev $have - "* ]] || fail "the title of this PR must start with 'vreview: rev $have - '"
else
  fail "the page says rev $have; main is at rev $main, so this PR is rev $((main + 1))"
fi
exit 0
