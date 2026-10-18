#!/usr/bin/env bash
# detect_scheduler_field_coverage.sh — flag an Option-typed (`?T`) struct
# field that a "central scheduler" function never references, when that
# function's own job is to merge several such optional deadline/timer fields
# into one return value (a caller-driven event-loop's next_timeout()-style
# aggregator).
#
# Bug class (vlang/v#28083, Phase 9 QuicConn): `closing_deadline ?u64` and
# `compute_next_timeout()` were both written in the SAME commit, but the
# aggregator merged `idle_timeout_deadline()`/`loss_detection.next_timeout()`
# and never `closing_deadline` -- a connection reaching .closing/.draining
# with nothing else armed returned next_timeout=none, so a real caller-driven
# event loop never learned to poll again. A later Phase-R fix that added the
# missing WRITE to closing_deadline (a different, narrower reported gap) did
# not re-trace the field's READ side and left this exact gap in place.
#
# Scoped to `?`-typed fields whose NAME contains "deadline" or "timeout"
# (case-insensitive), not every Option-typed field on the struct -- an
# earlier draft of this detector matched any `?`-typed field and flagged 11
# unrelated fields (key material, connection IDs, pending-crypto buffers) on
# QuicConn alongside the 1 real gap, making it useless as a clean gate. The
# name-based filter is still a heuristic (a deadline field with an unusual
# name, or a non-deadline field named `*_timeout` for something else, is
# possible) -- confirm any candidate by reading its doc comment/type before
# treating it as a real gap.
#
# Two invocation modes:
#   detect_scheduler_field_coverage.sh <file> [git-commit]
#     Auto-detect mode (what run_detectors.sh's manifest calls, one arg only):
#     finds a function named compute_next_timeout/next_timeout/next_deadline
#     in <file> and infers its receiver struct from the signature.
#   detect_scheduler_field_coverage.sh <file> <struct_name> <fn_name> [git-commit]
#     Explicit mode, for Phase-R testing against a specific struct/fn pair.
# Exit: 1 if any `?`-typed deadline/timeout-named field of the struct is
#       never referenced inside the aggregator fn's body (candidate found);
#       0 if every such field is referenced, or no aggregator/struct is
#       found; 2 on a read error.
set -uo pipefail
file="${1:?usage: detect_scheduler_field_coverage.sh <file> [struct_name fn_name] [commit]}"
if [ $# -ge 3 ]; then
    struct_name="$2"
    fn_name="$3"
    base="${4:-}"  # base-revision copy from run_detectors.sh (unused here)
else
    struct_name=""
    fn_name=""
    base="${2:-}"  # base-revision copy from run_detectors.sh (unused here)
fi

src="$(cat "$file" 2>/dev/null)"
if [ -z "$src" ]; then
    echo "detect_scheduler_field_coverage: cannot read $file" >&2
    exit 2
fi

if [ -z "$fn_name" ]; then
    fn_sig="$(printf '%s\n' "$src" | grep -E '^(pub )?fn \([a-zA-Z_ &*]+\) *(compute_next_timeout|next_timeout|next_deadline)\(' | head -1)"
    if [ -z "$fn_sig" ]; then
        echo "SKIP: no compute_next_timeout/next_timeout/next_deadline-style aggregator found in $file"
        exit 0
    fi
    fn_name="$(printf '%s\n' "$fn_sig" | grep -oE '(compute_next_timeout|next_timeout|next_deadline)' | head -1)"
    receiver="$(printf '%s\n' "$fn_sig" | sed -E 's/^(pub )?fn \(([^)]*)\).*/\2/')"
    struct_name="$(printf '%s\n' "$receiver" | awk '{print $NF}' | tr -d '&')"
    if [ -z "$struct_name" ]; then
        echo "SKIP: could not determine receiver struct for $fn_name in $file"
        exit 0
    fi
fi

label="$file — struct ${struct_name}, fn ${fn_name}"
echo "=== scheduler-field-coverage detector: $label ==="

struct_body="$(printf '%s\n' "$src" | awk -v s="$struct_name" '
    $0 ~ ("struct " s "( |\\{|$)") { instruct=1 }
    instruct { print; if (/^}/) exit }
')"
if [ -z "$struct_body" ]; then
    echo "SKIP: struct $struct_name not found in $file"
    exit 0
fi

fn_body="$(printf '%s\n' "$src" | awk -v f="$fn_name" '
    $0 ~ ("fn .*\\)[ \t]*" f "\\(") {
        infn=1; depth=1; print; next
    }
    infn {
        print
        n=gsub(/\{/, "{"); depth+=n
        n=gsub(/\}/, "}"); depth-=n
        if (depth <= 0) exit
    }
')"
if [ -z "$fn_body" ]; then
    echo "SKIP: fn $fn_name not found in $file"
    exit 0
fi

fields="$(printf '%s\n' "$struct_body" | grep -E '^\s*[a-zA-Z_][a-zA-Z0-9_]*\s+\?' | awk '{print $1}' | grep -iE 'deadline|timeout')"

missing=0
while IFS= read -r field; do
    [ -z "$field" ] && continue
    if ! printf '%s\n' "$fn_body" | grep -qE "\b${field}\b"; then
        echo "CANDIDATE: optional field '${field}' on ${struct_name} is never referenced in ${fn_name}()"
        missing=1
    fi
done <<< "$fields"

if [ "$missing" -eq 1 ]; then
    exit 1
fi
echo "OK: every optional field on ${struct_name} is referenced in ${fn_name}()"
exit 0
