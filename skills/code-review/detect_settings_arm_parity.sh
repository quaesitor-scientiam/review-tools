#!/usr/bin/env bash
# Detect: comment-only match arms in a settings handler where sibling
# functions in other files have executable code for the same arm.
#
# Catches the class of bug where apply_peer_settings (h2_mux_conn.v) had an
# empty h2_settings_header_table_size body while H2Conn.apply_settings and
# H2ServerConn.apply_settings both had executable code for the same arm.
#
# Usage:
#   bash detect_settings_arm_parity.sh <file_under_review>
#
# Exit 1 when any h2_settings_* arm is comment-only in the target file but
# has executable code in at least one sibling h2_*.v file.
# Exit 0 when no such disparity is found.

set -uo pipefail

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
    echo "Usage: $0 <v-source-file>" >&2
    exit 2
fi

DIR=$(dirname "$FILE")
BASE=$(basename "$FILE")

# Sibling h2_*.v files in the same directory (excluding the file under review)
mapfile -t SIBLINGS < <(find "$DIR" -maxdepth 1 -name "h2_*.v" ! -name "$BASE" 2>/dev/null | sort)

if [ "${#SIBLINGS[@]}" -eq 0 ]; then
    echo "SKIP: no sibling h2_*.v files found in $DIR" >&2
    exit 0
fi

# Extract the body of a named settings handler function from a file.
# Prints lines from fn...apply*settings to the function's closing }.
extract_fn_body() {
    local f="$1"
    awk '
        /^fn .*(apply|Apply).*(settings|Settings)/ { in_fn=1; depth=0 }
        in_fn {
            print
            for (i=1; i<=length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                else if (c == "}") {
                    depth--
                    if (depth == 0) { in_fn=0; break }
                }
            }
        }
    ' "$f"
}

# Return true (0) if the lines of text contain at least one executable V
# statement — defined as: a non-comment, non-blank line that is NOT a bare
# brace and NOT a match arm label (h2_settings_* {).
arm_has_code() {
    local body="$1"
    printf '%s\n' "$body" | grep -Ev \
        '^\s*(//|$|[{}]|h2_settings_[a-z_]+[[:space:]]*\{?[[:space:]]*$|else[[:space:]]*\{?[[:space:]]*$)' \
        | grep -qE '\S'
}

found_bug=0

target_body=$(extract_fn_body "$FILE")
if [ -z "$target_body" ]; then
    echo "SKIP: no apply_*settings function found in $FILE" >&2
    exit 0
fi

# Collect all h2_settings_* arm labels present in the target function.
mapfile -t ARM_LABELS < <(printf '%s\n' "$target_body" | grep -oE 'h2_settings_[a-z_]+' | sort -u)

if [ "${#ARM_LABELS[@]}" -eq 0 ]; then
    echo "SKIP: no h2_settings_* arms found in $FILE" >&2
    exit 0
fi

for arm in "${ARM_LABELS[@]}"; do
    # Extract the body of this arm from the target file (from arm label to closing })
    arm_body=$(printf '%s\n' "$target_body" | awk -v label="$arm" '
        $0 ~ label && /\{/ { in_arm=1; depth=0 }
        in_arm {
            print
            for (i=1; i<=length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                else if (c == "}") {
                    depth--
                    if (depth == 0) { in_arm=0; break }
                }
            }
        }
    ')

    # If the arm already has executable code, no problem.
    if arm_has_code "$arm_body" 2>/dev/null; then
        continue
    fi

    # Arm is comment-only or empty. Check whether any sibling has executable code.
    for sib in "${SIBLINGS[@]}"; do
        sib_body=$(extract_fn_body "$sib")
        [ -z "$sib_body" ] && continue

        sib_arm_body=$(printf '%s\n' "$sib_body" | awk -v label="$arm" '
            $0 ~ label && /\{/ { in_arm=1; depth=0 }
            in_arm {
                print
                for (i=1; i<=length($0); i++) {
                    c = substr($0, i, 1)
                    if (c == "{") depth++
                    else if (c == "}") {
                        depth--
                        if (depth == 0) { in_arm=0; break }
                    }
                }
            }
        ')

        if arm_has_code "$sib_arm_body" 2>/dev/null; then
            echo "BUG: arm '$arm' in $BASE is comment-only/empty, but $(basename "$sib") has executable code for the same arm — likely missing required behavior" >&2
            found_bug=1
            break
        fi
    done
done

if [ "$found_bug" -eq 0 ]; then
    echo "OK: no comment-only/empty arms found where sibling files have executable code" >&2
    exit 0
fi
exit 1
