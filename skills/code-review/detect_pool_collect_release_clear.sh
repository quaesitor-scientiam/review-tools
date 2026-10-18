#!/usr/bin/env bash
# detect_pool_collect_release_clear.sh — flag a Transport method that collects
# entries from a pool map (h1_idle/h2_conns) into a local list for release
# OUTSIDE the lock, but does not clear that SAME map before releasing the
# lock — so a second/concurrent caller can observe and re-release the same
# entries.
#
# Bug class (Codex P2, vlang/v#27643 pullrequestreview-4626225521,
# discussion 3520259791): the original close_idle() collected every h2_conns
# entry under t.mu into a local list for release outside the lock (needed
# because releasing can synchronously call back into teardown, which itself
# takes t.mu — a deadlock if done under the lock), correctly cleared h1_idle
# right after collecting it, but never cleared h2_conns at all. A connection
# with a genuinely in-flight stream survives one release() call (its refcount
# drops but doesn't reach zero), so it stayed in h2_conns after the first
# close_idle() call — a second call (concurrent, or simply calling it twice)
# found the SAME connection again and released it a second time,
# over-decrementing the refcount below the number of genuinely live
# references.
#
# General rule: collect-then-release-outside-the-lock is a legitimate pattern
# (needed whenever release() can re-enter the lock), but it is only safe if
# the SOURCE map is emptied of the collected entries atomically with the
# collection — i.e. before the lock is released, not left for a later pass.
#
# This is a coarse, function-scoped heuristic like detect_pool_cap_scope_
# symmetry.sh: it only checks functions that both range over a pool map AND
# call t.mu.unlock() themselves (excluding helpers like total_idle_locked()
# or evict_oldest_idle_locked() that a caller wraps in its own lock/unlock).
#
# Usage: detect_pool_collect_release_clear.sh <file> [git-commit]
# Exit: 1 if a function ranges over h1_idle or h2_conns and calls
#       t.mu.unlock() without a preceding .clear() on that same map
#       (candidate found); 0 if none found, or the file has no t.mu.unlock()
#       call; 2 on a read error.
set -uo pipefail
file="${1:?usage: detect_pool_collect_release_clear.sh <file> [commit]}"
commit="${2:-}"

if [ -n "$commit" ]; then
    src="$(git show "${commit}:${file}" 2>/dev/null)"
else
    src="$(cat "$file" 2>/dev/null)"
fi
if [ -z "$src" ]; then
    echo "detect_pool_collect_release_clear: cannot read $file${commit:+ @ $commit}" >&2
    exit 2
fi

label="$file${commit:+ @ $commit}"
echo "=== pool-collect-release-clear detector: $label ==="

if ! printf '%s\n' "$src" | grep -qE '\bt\.mu\.unlock\(\)'; then
    echo "SKIP: $file has no t.mu.unlock() call"
    exit 0
fi

out="$(printf '%s\n' "$src" | awk '
    /^(pub )?fn \([a-zA-Z_ &]*Transport\)/ {
        infn=1; fname=$0; sub(/[ \t]*\{.*/, "", fname)
        depth=1
        collect_h1=0; collect_h2=0; clear_h1=0; clear_h2=0; checked=0
        next
    }
    infn {
        depth += gsub(/\{/, "{")
        depth -= gsub(/\}/, "}")
        if ($0 ~ /for [a-zA-Z_0-9]+, [a-zA-Z_0-9]+ in t\.h1_idle[ ]*\{/) { collect_h1=1 }
        if ($0 ~ /for [a-zA-Z_0-9]+, [a-zA-Z_0-9]+ in t\.h2_conns[ ]*\{/) { collect_h2=1 }
        if ($0 ~ /t\.h1_idle\.clear\(\)/) { clear_h1=1 }
        if ($0 ~ /t\.h2_conns\.clear\(\)/) { clear_h2=1 }
        if (!checked && $0 ~ /t\.mu\.unlock\(\)/) {
            checked=1
            if (collect_h1 && !clear_h1) { print "  " fname " -- ranges over t.h1_idle but never clears it before t.mu.unlock()" }
            if (collect_h2 && !clear_h2) { print "  " fname " -- ranges over t.h2_conns but never clears it before t.mu.unlock()" }
        }
        if (depth <= 0) { infn=0 }
    }
')"

if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "RESULT: candidate(s) found — a function ranges over a pool map for release outside the lock but does not clear that map first. Confirm: can the SAME entry be observed and re-released by a later/concurrent call?"
    exit 1
fi
echo "RESULT: every function ranging over h1_idle/h2_conns and unlocking t.mu also clears the map it ranged over."
exit 0
