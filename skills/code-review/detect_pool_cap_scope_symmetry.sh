#!/usr/bin/env bash
# detect_pool_cap_scope_symmetry.sh — flag a function that references a
# Transport-wide shared capacity/lifetime field (max_idle_conns, idle_timeout)
# but does not touch (iterate/index/delete/clear) BOTH sibling connection
# pools (h1_idle, h2_conns).
#
# Bug class (Codex P2, vlang/v#27643 pullrequestreview-4630174759, and its
# still-open sibling in checkout()'s idle_timeout expiry, found in the same
# review round): a function that ENFORCES a cap/lifetime limit documented as
# applying across the whole Transport is easy to write against only ONE pool
# — especially when the limit-check is hidden behind a helper call
# (total_idle_locked()) rather than a literal field reference, so a
# "does this function mention both pool names" skim looks clean even when the
# ACTION only ever touches one of them. Concretely: evict_idle_h2_if_over_cap
# (pre-fix) checked `total_idle_locked() + h2_conns.len` (aware of both pools
# in its CONDITION) but its eviction loop only ever walked h2_conns (acted on
# only one) — the asymmetry is invisible to a "mentions both pools" read
# because h1_idle never appears literally in the function at all. checkout()'s
# idle_timeout expiry has the mirror-image gap: it expires stale h1_idle
# entries but has no equivalent for h2_conns at all.
#
# This is a coarse, function-scoped heuristic, not a semantic proof: it flags
# CANDIDATES for review, not confirmed bugs. A function referencing
# max_idle_conns/idle_timeout that legitimately only needs one pool (e.g. a
# pool-specific helper that is itself called from a symmetric caller) is a
# false positive — confirm by reading the call site.
#
# Usage: detect_pool_cap_scope_symmetry.sh <file> [git-commit]
# Exit: 1 if a Transport method references max_idle_conns or idle_timeout but
#       does not touch both h1_idle and h2_conns (candidate found); 0 if none
#       found, or the file has no Transport methods; 2 on a read error.
set -uo pipefail
file="${1:?usage: detect_pool_cap_scope_symmetry.sh <file> [commit]}"
base="${2:-}"  # base-revision copy from run_detectors.sh (unused here)

src="$(cat "$file" 2>/dev/null)"
if [ -z "$src" ]; then
    echo "detect_pool_cap_scope_symmetry: cannot read $file" >&2
    exit 2
fi

label="$file"
echo "=== pool-cap-scope-symmetry detector: $label ==="

if ! printf '%s\n' "$src" | grep -qE '\b(h1_idle|h2_conns)\b'; then
    echo "SKIP: $file has no h1_idle/h2_conns pool fields"
    exit 0
fi

out="$(printf '%s\n' "$src" | awk '
    /^(pub )?fn \([a-zA-Z_ &]*Transport\)/ {
        infn=1; fname=$0; sub(/[ \t]*\{.*/, "", fname)
        # The header line'\''s own opening brace is consumed by "next" before
        # entering the infn block, so seed depth at 1 to account for it.
        depth=1; refs_cap=0; touches_h1=0; touches_h2=0
        next
    }
    infn {
        depth += gsub(/\{/, "{")
        depth -= gsub(/\}/, "}")
        # NOTE: gawk regex does not treat \b as a word boundary (it silently
        # matches nothing at all -- exactly the "detector looks right but is
        # actually a silent no-op" class of bug this detector exists to
        # catch elsewhere). Use gawk word anchors \< \> instead of \b here.
        if (/\.max_idle_conns\>/ || /\.idle_timeout\>/) { refs_cap=1 }
        if (/\<h1_idle\>/) { touches_h1=1 }
        if (/\<h2_conns\>/) { touches_h2=1 }
        if (depth <= 0) {
            if (refs_cap && !(touches_h1 && touches_h2)) {
                missing = touches_h1 ? "h2_conns" : "h1_idle"
                print "  " fname " -- references a shared cap/lifetime field but never touches " missing
            }
            infn=0
        }
    }
')"

if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "RESULT: candidate(s) found — a function enforcing a shared Transport-wide limit that only acts on one connection pool. Confirm: should this limit apply to the other pool too?"
    exit 1
fi
echo "RESULT: every function referencing max_idle_conns/idle_timeout touches both h1_idle and h2_conns."
exit 0
