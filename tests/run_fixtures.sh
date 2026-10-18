#!/usr/bin/env bash
# run_fixtures.sh — Phase-R fixture suite for every detector in skills/code-review.
#
# Each detector has tests/<detector-name>/known_bad/<case>/ and known_good/<case>/
# directories. A case directory is a miniature working tree: the runner cd's into
# it (or into a throwaway git repo built from it) and invokes the detector, then
# asserts the exit code: 1 for known_bad, 0 for known_good. A detector replaced
# by a no-op (always exit 0) therefore FAILS on every known_bad case.
#
# Per-case control files (all optional):
#   args        one detector argument per line. Default: every regular file in the
#               case dir (sorted), relative to the case dir. An EMPTY args file means
#               "no arguments" (for detectors with a hardcoded target path).
#   needs_git   build a throwaway git repo: `master` has an empty baseline commit,
#               branch `feature` adds the case files. Detectors that call
#               git merge-base/diff/show work against that repo.
#   expect_rc   override the expected exit code (default 1 for known_bad, 0 for
#               known_good). Use for enumerate-and-verify tools that never exit 1.
#   expect_out  an extended regex the detector's combined stdout+stderr must match
#               (known_bad) or must NOT match (known_good).
#
# Usage: bash tests/run_fixtures.sh [detector-name ...]
#   No args: run every fixtured detector AND fail if any detect_*.sh/.ps1 in
#   skills/code-review has neither a tests/ dir nor an entry in tests/UNFIXTURED.md.
# Exit: 0 all green, 1 any failure, 2 usage/environment error.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
detdir="$root/skills/code-review"
timeout_s="${FIXTURE_TIMEOUT:-60}"
work="${FIXTURE_WORK:-$here/_work}"
rm -rf "$work"; mkdir -p "$work"

pwsh_bin=""
command -v pwsh >/dev/null 2>&1 && pwsh_bin="pwsh"
[ -z "$pwsh_bin" ] && command -v pwsh.exe >/dev/null 2>&1 && pwsh_bin="pwsh.exe"

pass=0; fail=0; skip=0; failures=()

control_files='! -name args ! -name needs_git ! -name expect_rc ! -name expect_out'

run_case() { # $1=detector-name $2=known_bad|known_good $3=case-dir
    local det="$1" kind="$2" case="$3" name
    name="$det/$kind/$(basename "$case")"
    local script=""
    for ext in sh ps1; do [ -f "$detdir/$det.$ext" ] && script="$detdir/$det.$ext"; done
    if [ -z "$script" ]; then failures+=("$name: detector script not found"); fail=$((fail+1)); return; fi

    local expect_rc=1; [ "$kind" = known_good ] && expect_rc=0
    [ -f "$case/expect_rc" ] && expect_rc="$(tr -d '[:space:]' < "$case/expect_rc")"
    local expect_out=""; [ -f "$case/expect_out" ] && expect_out="$(cat "$case/expect_out")"

    # Collect args.
    local -a args=()
    if [ -f "$case/args" ]; then
        while IFS= read -r line || [ -n "$line" ]; do [ -n "$line" ] && args+=("$line"); done < "$case/args"
    else
        while IFS= read -r f; do args+=("$f"); done < <(cd "$case" && eval find . -type f $control_files | sed 's|^\./||' | sort)
    fi

    # Working directory: the case dir, or a throwaway git repo built from it.
    local cwd="$case"
    if [ -f "$case/needs_git" ]; then
        cwd="$work/$det-$kind-$(basename "$case")"
        rm -rf "$cwd"; mkdir -p "$cwd"
        ( cd "$cwd" && unset GIT_DIR GIT_WORK_TREE \
          && git init -q -b master . \
          && git -c user.name=fixture -c user.email=f@x -c commit.gpgsign=false commit -q --allow-empty -m base \
          && git checkout -q -b feature \
          && cp -r "$case"/. "$cwd"/ \
          && rm -f "$cwd/args" "$cwd/needs_git" "$cwd/expect_rc" "$cwd/expect_out" \
          && git add -A \
          && git -c user.name=fixture -c user.email=f@x -c commit.gpgsign=false commit -q -m feature ) \
          || { failures+=("$name: could not build fixture git repo"); fail=$((fail+1)); return; }
    fi

    local out rc
    case "$script" in
    *.ps1)
        if [ -z "$pwsh_bin" ]; then echo "  [SKIP] $name (no pwsh on this host)"; skip=$((skip+1)); return; fi
        # Under WSL the only pwsh is usually Windows' pwsh.exe via interop, which
        # needs a Windows path for -File (case args stay relative, cwd is mapped).
        local ps_script="$script"
        case "$pwsh_bin" in *.exe) command -v wslpath >/dev/null 2>&1 && ps_script="$(wslpath -w "$script")" ;; esac
        out="$(cd "$cwd" && unset GIT_DIR GIT_WORK_TREE && timeout "$timeout_s" "$pwsh_bin" -NoProfile -File "$ps_script" "${args[@]}" 2>&1)"; rc=$? ;;
    *)
        out="$(cd "$cwd" && unset GIT_DIR GIT_WORK_TREE && timeout "$timeout_s" bash "$script" "${args[@]}" 2>&1)"; rc=$? ;;
    esac

    local ok=1 why=""
    [ "$rc" -eq 124 ] && { ok=0; why="timed out after ${timeout_s}s"; }
    [ "$rc" -ne "$expect_rc" ] && [ -z "$why" ] && { ok=0; why="exit $rc, expected $expect_rc"; }
    if [ -n "$expect_out" ]; then
        if [ "$kind" = known_bad ]; then
            printf '%s\n' "$out" | grep -qE -- "$expect_out" || { ok=0; why="${why:+$why; }output did not match /$expect_out/"; }
        else
            printf '%s\n' "$out" | grep -qE -- "$expect_out" && { ok=0; why="${why:+$why; }output matched /$expect_out/ but should not"; }
        fi
    fi
    if [ "$ok" -eq 1 ]; then
        pass=$((pass+1)); [ -n "${VERBOSE:-}" ] && echo "  [ OK ] $name (exit $rc)"
    else
        fail=$((fail+1)); failures+=("$name: $why")
        echo "  [FAIL] $name: $why"
        printf '%s\n' "$out" | sed 's/^/         | /' | head -30
    fi
}

# ---- select detectors --------------------------------------------------------
if [ "$#" -gt 0 ]; then
    dets=("$@")
    check_coverage=0
else
    mapfile -t dets < <(cd "$here" && find . -mindepth 1 -maxdepth 1 -type d -name 'detect_*' | sed 's|^\./||' | sort)
    check_coverage=1
fi

for det in "${dets[@]}"; do
    det="${det%/}"; det="${det%.sh}"; det="${det%.ps1}"
    d="$here/$det"
    if [ ! -d "$d" ]; then echo "  [FAIL] $det: no tests/$det/ directory"; fail=$((fail+1)); failures+=("$det: no fixture dir"); continue; fi
    nbad=0
    for kind in known_bad known_good; do
        [ -d "$d/$kind" ] || continue
        for case in "$d/$kind"/*/; do
            [ -d "$case" ] || continue
            case="${case%/}"
            [ "$kind" = known_bad ] && nbad=$((nbad+1))
            run_case "$det" "$kind" "$case"
        done
    done
    if [ "$nbad" -eq 0 ]; then echo "  [FAIL] $det: no known_bad case (a no-op detector would pass)"; fail=$((fail+1)); failures+=("$det: no known_bad case"); fi
done

# ---- coverage: every detector on disk is fixtured or explicitly excused --------
if [ "$check_coverage" -eq 1 ]; then
    for script in "$detdir"/detect_*.sh "$detdir"/detect_*.ps1; do
        [ -f "$script" ] || continue
        name="$(basename "$script")"; stem="${name%.*}"
        if [ ! -d "$here/$stem" ] && ! grep -qF "| \`$name\` |" "$here/UNFIXTURED.md" 2>/dev/null; then
            echo "  [FAIL] $name: not fixtured and not listed in tests/UNFIXTURED.md"
            fail=$((fail+1)); failures+=("$name: unfixtured")
        fi
    done
fi

rm -rf "$work"
echo "=== fixtures: $pass passed, $fail failed, $skip skipped ==="
for f in "${failures[@]:-}"; do [ -n "$f" ] && echo "  - $f"; done
[ "$fail" -gt 0 ] && exit 1
exit 0
