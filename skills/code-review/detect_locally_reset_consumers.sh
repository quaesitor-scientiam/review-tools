#!/usr/bin/env bash
# detect_locally_reset_consumers.sh — enumerate every direct
# `in c.locally_reset` / `!in c.locally_reset` test outside classify_stream's
# own body and mark_locally_reset's own body, for a per-consumer audit.
#
# Bug class (Codex P2, vlang/v#27627 pullrequestreview-4620220448):
# classify_stream was generalized to treat any `locally_reset` id as `.closed`
# (RFC 9113 §5.1's own definition of closed includes RST_STREAM'd streams).
# But a SIBLING check — the H2PriorityFrame self-dependency guard in
# dispatch_frame — had its OWN pre-existing, narrower `frame.stream_id !in
# c.locally_reset` test that predated the generalization and was never
# migrated to use classify_stream. It was found only because Codex flagged it
# in the NEXT review round, not because the generalization's own review
# audited every other consumer of the old idiom.
#
# General lesson this encodes: whenever a helper function (here,
# classify_stream) is generalized to subsume a condition a raw expression used
# to test directly (`in c.locally_reset`), every OTHER place in the file that
# still tests that raw expression is a migration candidate — it may now be
# redundant, subtly inconsistent with the new helper, or (as happened here)
# simply missing the new helper's broader semantics.
#
# This is an ENUMERATE-AND-VERIFY aid, not a clean pass/fail gate: a direct
# `locally_reset` check outside classify_stream is not automatically wrong —
# some of them test a genuinely different question ("have we already reacted
# to this stream once," not "is this stream closed"). The point is to force
# an explicit per-site confirmation every time this file changes, rather than
# relying on memory of which sites were already audited.
#
# Usage: detect_locally_reset_consumers.sh <file> [git-commit]
# Exit: 1 if any direct locally_reset check exists outside classify_stream/
#       mark_locally_reset (candidates to review by hand); 0 if none; 2 on
#       read error.
set -uo pipefail
file="${1:?usage: detect_locally_reset_consumers.sh <file> [commit]}"
commit="${2:-}"

if [ -n "$commit" ]; then
    src="$(git show "${commit}:${file}" 2>/dev/null)"
else
    src="$(cat "$file" 2>/dev/null)"
fi
if [ -z "$src" ]; then
    echo "detect_locally_reset_consumers: cannot read $file${commit:+ @ $commit}" >&2
    exit 2
fi
if ! printf '%s\n' "$src" | grep -q 'locally_reset'; then
    echo "OK: no locally_reset usage in $file${commit:+ @ $commit} — nothing to check"
    exit 0
fi

label="$file${commit:+ @ $commit}"
echo "=== locally_reset direct-consumer audit: $label ==="

out="$(printf '%s\n' "$src" | awk '
    /^fn / { fname=$0; sub(/[ \t]*\{.*/, "", fname) }
    /locally_reset/ && fname !~ /classify_stream|mark_locally_reset/ && $0 ~ /in c\.locally_reset/ {
        line=$0; gsub(/^[ \t]+/, "", line)
        print "  " NR ": [" fname "] " line
    }
')"

if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "RESULT: direct locally_reset checks above — confirm each still needs its OWN test, or should route through classify_stream instead."
    exit 1
fi
echo "RESULT: every locally_reset check is inside classify_stream/mark_locally_reset."
exit 0
