#!/usr/bin/env bash
# detect_ungated_release_after_conditional_delete.sh — flags a function where
# a shared-map `.delete(...)` is guarded by an identity/ownership check (the
# caller only removes the entry if it still owns it), but a resource-release
# call later in the SAME function (`.release()`, `.shutdown_when_idle()`,
# `.close()`, `.free()`, `.shutdown()`) runs unconditionally, outside that
# same guard.
#
# Bug class (self-caught in review, not Codex, vlang/v#27643
# pullrequestreview-4636271901): a TOCTOU guard added to protect ONE side
# effect in a branch ("did I actually win the race to remove this map entry?")
# does not automatically protect every OTHER side effect in that same branch
# that shares the identical "exactly once, only by whichever caller wins"
# requirement. `h2_round_trip`'s idle-expiry eviction guarded
# `t.h2_conns.delete(key)`/`t.h2_dial_id.delete(key)` with
# `if voidptr(existing) == voidptr(conn)` (a caller that lost the removal
# race correctly skips the delete), but the following
# `conn.shutdown_when_idle()`/`conn.release()` ran UNCONDITIONALLY. The two
# calls sit right next to each other and LOOK equally safe to call twice —
# `shutdown_when_idle()` genuinely is idempotent (just sets a bool) — but
# `release()` decrements a shared refcount (`H2MuxConn.refs`) and is NOT.
# Two concurrent callers racing the same idle-expired connection (or a
# concurrent `Transport.close_idle()`, which releases every h2 conn
# unconditionally by design) both fell through to the ungated `release()`,
# over-decrementing `refs` (verified empirically: `refs == -1` with two
# racers). The guard exists precisely to prevent this class of issue and was
# just incompletely applied — this is the sibling of `close_idle()`'s own
# "clear the map atomically with collection, so no caller can ever re-release
# a connection this call has already claimed" pattern, applied to only HALF
# of the branch's side effects.
#
# This is a coarse, function-scoped heuristic (like several siblings in this
# corpus), not a semantic proof: it enumerates CANDIDATES for manual
# verification. A release-like call after the guard that is unconditionally
# correct to run twice (truly idempotent AND cannot corrupt shared state) is
# a false positive; confirm by checking what state each candidate call
# actually mutates.
#
# Usage: detect_ungated_release_after_conditional_delete.sh <file> [git-commit]
# Exit: 1 if a candidate is found; 0 if none; 2 on a read error.
set -uo pipefail
file="${1:?usage: detect_ungated_release_after_conditional_delete.sh <file> [commit]}"
commit="${2:-}"

if [ -n "$commit" ]; then
    src="$(git show "${commit}:${file}" 2>/dev/null)"
else
    src="$(cat "$file" 2>/dev/null)"
fi
if [ -z "$src" ]; then
    echo "detect_ungated_release_after_conditional_delete: cannot read $file${commit:+ @ $commit}" >&2
    exit 2
fi

label="$file${commit:+ @ $commit}"
echo "=== ungated-release-after-conditional-delete detector: $label ==="

out="$(printf '%s\n' "$src" | awk '
    /^(pub )?fn / {
        infn = 1; fname = $0; sub(/[ \t]*\{.*/, "", fname)
        won_var = ""; in_guard = 0; guard_indent = -1; guard_has_delete = 0
        guard_seen = 0; guard_base_indent = -1
        next
    }
    infn {
        match($0, /^\t*/)
        indent = RLENGTH
        trimmed = $0
        sub(/^\t*/, "", trimmed)

        if (indent == 0 && trimmed ~ /^\}/) { infn = 0; next }

        # Remember a `won_x := voidptr(a) == voidptr(b)`-style capture so a
        # LATER `if won_x {` still counts as the same identity guard, not
        # just an inline `if voidptr(a) == voidptr(b) {`.
        if (match($0, /^([a-zA-Z_][a-zA-Z0-9_]*) := .*voidptr\(.*==.*voidptr\(/, cap)) {
            won_var = cap[1]
        }

        is_guard_if = 0
        if (trimmed ~ /^if /) {
            if (trimmed ~ /voidptr\(.*==.*voidptr\(/) { is_guard_if = 1 }
            else if (won_var != "" && trimmed ~ ("\\<" won_var "\\>")) { is_guard_if = 1 }
        }

        if (!in_guard && is_guard_if) {
            in_guard = 1; guard_indent = indent; guard_has_delete = 0
            next
        }
        if (in_guard) {
            if (indent > guard_indent) {
                if (trimmed ~ /\.delete\(/) { guard_has_delete = 1 }
                next
            } else {
                in_guard = 0
                if (guard_has_delete) { guard_seen = 1; guard_base_indent = guard_indent }
                # fall through: re-check this same line below
            }
        }

        if (guard_seen && indent <= guard_base_indent) {
            if (trimmed ~ /\.release\(\)/ || trimmed ~ /\.shutdown_when_idle\(\)/ \
                || trimmed ~ /\.close\(\)/ || trimmed ~ /\.free\(\)/ || trimmed ~ /\.shutdown\(\)/) {
                print "  " fname " line " NR " -- unconditional \"" trimmed "\" runs after an identity-guarded .delete() earlier in this function; confirm it is gated the same way"
            }
            # A new, unrelated if at or below the guard'\''s own indent means
            # we'\''ve moved past the relevant branch -- stop matching further
            # lines in this function to avoid noise from later, unrelated code.
            if (trimmed ~ /^if /) { guard_seen = 0 }
        }
    }
')"

if [ -n "$out" ]; then
    printf '%s\n' "$out"
    echo "RESULT: candidate(s) found -- a resource-release call runs unconditionally after an identity-guarded map delete in the same function."
    exit 1
fi
echo "RESULT: no ungated release-after-conditional-delete pattern found."
exit 0
