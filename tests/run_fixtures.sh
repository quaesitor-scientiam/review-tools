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
#   FIXTURE_SMOKE_ONLY=1 with no args: skip the per-detector cases.
# Exit: 0 all green, 1 any failure, 2 usage/environment error.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
detdir="$root/skills/code-review"
timeout_s="${FIXTURE_TIMEOUT:-60}"
work="${FIXTURE_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/fixtures.XXXXXX")}"
mkdir -p "$work"

pwsh_bin=""
command -v pwsh >/dev/null 2>&1 && pwsh_bin="pwsh"
[ -z "$pwsh_bin" ] && command -v pwsh.exe >/dev/null 2>&1 && pwsh_bin="pwsh.exe"

# V compiler for the detectors/*.v ports: $DETECT_V, else `v` on PATH. Without
# one the .v implementations are reported as skipped (the .sh ones still run).
vexe="${DETECT_V:-}"
[ -z "$vexe" ] && command -v v >/dev/null 2>&1 && vexe="v"
mkdir -p "$work/bin"
to_native() { # path -> what a Windows v.exe expects (git-bash only)
    case "$vexe" in *.exe) command -v cygpath >/dev/null 2>&1 && { cygpath -w "$1"; return; } ;; esac
    printf '%s' "$1"
}

pass=0; fail=0; skip=0; failures=()

control_files='! -name args ! -name needs_git ! -name expect_rc ! -name expect_out'

run_case() { # $1=detector-name $2=known_bad|known_good $3=case-dir $4=implementation (script or compiled binary)
    local det="$1" kind="$2" case="$3" script="$4" name
    name="$det/$kind/$(basename "$case")"
    case "$script" in *.sh|*.ps1) ;; *) name="$name [v]" ;; esac

    local expect_rc=1; [ "$kind" = known_good ] && expect_rc=0
    [ -f "$case/expect_rc" ] && expect_rc="$(tr -d '[:space:]' < "$case/expect_rc")"
    local expect_out=""; [ -f "$case/expect_out" ] && expect_out="$(cat "$case/expect_out")"

    # Collect args.
    local -a args=()
    if [ -f "$case/args" ]; then
        while IFS= read -r line || [ -n "$line" ]; do [ -n "$line" ] && args+=("$line"); done < "$case/args"
    else
        while IFS= read -r f; do args+=("$f"); done < <(cd "$case" && eval find . -type f $control_files | sed 's|^\./||' | sort)
        # Contract check: run_detectors.sh passes the base-revision copy as $2
        # and a detector must never scan it. For a known_good case the decoy
        # is the detector's first known_bad file (absolute path), so a detector
        # that treats $2 as a target flips to exit 1 and fails the case; for a
        # known_bad case it is the empty string, the "no base copy" form.
        if [ "${#args[@]}" -eq 1 ]; then
            decoy=""
            if [ "$kind" = known_good ]; then
                decoy="$(find "$here/$det/known_bad" -type f ! -name args ! -name needs_git ! -name expect_rc ! -name expect_out 2>/dev/null | sort | head -1)"
            fi
            args+=("$decoy")
        fi
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
    *.sh)
        out="$(cd "$cwd" && unset GIT_DIR GIT_WORK_TREE && timeout "$timeout_s" bash "$script" "${args[@]}" 2>&1)"; rc=$? ;;
    *)  # compiled V detector
        out="$(cd "$cwd" && unset GIT_DIR GIT_WORK_TREE && timeout "$timeout_s" "$script" "${args[@]}" 2>&1)"; rc=$? ;;
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
    # FIXTURE_SMOKE_ONLY=1 skips the per-detector cases and runs the rest (the runner
    # smoke test above all), for a mutation run over run_detectors.v.
    [ -n "${FIXTURE_SMOKE_ONLY:-}" ] && dets=()
fi

for det in "${dets[@]}"; do
    det="${det%/}"; det="${det%.sh}"; det="${det%.ps1}"
    d="$here/$det"
    if [ ! -d "$d" ]; then echo "  [FAIL] $det: no tests/$det/ directory"; fail=$((fail+1)); failures+=("$det: no fixture dir"); continue; fi
    # Implementations: the shell/pwsh script, plus the V port compiled once.
    impls=()
    for ext in sh ps1; do [ -f "$detdir/$det.$ext" ] && impls+=("$detdir/$det.$ext"); done
    if [ -f "$root/detectors/$det.v" ]; then
        if [ -n "$vexe" ]; then
            if cerr="$("$vexe" -o "$(to_native "$work/bin/$det")" "$(to_native "$root/detectors/$det.v")" 2>&1)"; then
                impls+=("$work/bin/$det")
            else
                echo "  [FAIL] $det [v]: does not compile"; printf '%s
' "$cerr" | sed 's/^/         | /' | head -15
                fail=$((fail+1)); failures+=("$det [v]: compile error")
            fi
        else
            echo "  [SKIP] $det [v]: no V compiler (set DETECT_V or put v on PATH)"; skip=$((skip+1))
        fi
    fi
    if [ "${#impls[@]}" -eq 0 ]; then echo "  [FAIL] $det: no implementation found"; fail=$((fail+1)); failures+=("$det: no implementation"); continue; fi
    nbad=0
    for impl in "${impls[@]}"; do
        for kind in known_bad known_good; do
            [ -d "$d/$kind" ] || continue
            for case in "$d/$kind"/*/; do
                [ -d "$case" ] || continue
                case="${case%/}"
                [ "$kind" = known_bad ] && nbad=$((nbad+1))
                run_case "$det" "$kind" "$case" "$impl"
            done
        done
    done
    if [ "$nbad" -eq 0 ]; then echo "  [FAIL] $det: no known_bad case (a no-op detector would pass)"; fail=$((fail+1)); failures+=("$det: no known_bad case"); fi
done

# ---- coverage: every detector on disk is fixtured or explicitly excused --------
if [ "$check_coverage" -eq 1 ]; then
    for script in "$detdir"/detect_*.sh "$detdir"/detect_*.ps1 "$root"/detectors/detect_*.v; do
        [ -f "$script" ] || continue
        name="$(basename "$script")"; stem="${name%.*}"
        if [ ! -d "$here/$stem" ] && ! grep -qF "| \`$name\` |" "$here/UNFIXTURED.md" 2>/dev/null; then
            echo "  [FAIL] $name: not fixtured and not listed in tests/UNFIXTURED.md"
            fail=$((fail+1)); failures+=("$name: unfixtured")
        fi
    done
fi

# ---- no-git gate: detectors must not call git (the runner owns git) ---------
if [ "$check_coverage" -eq 1 ]; then
    for script in "$detdir"/detect_*.sh "$detdir"/detect_*.ps1 "$root"/detectors/detect_*.v; do
        [ -f "$script" ] || continue
        if grep -qE '^[^#/]*\bgit\b' "$script"; then
            o="$(basename "$script")"
            echo "  [FAIL] $o: calls git (the runner owns all git access)"
            fail=$((fail+1)); failures+=("$o: calls git")
        fi
    done
fi

# ---- runner smoke test: run_detectors.sh end to end on throwaway repos ---------
# The main repo: master holds the known_good lenient-parse fixture, feature the
# known_bad one. No-arg mode must select the changed file and FLAG it; --at master
# must scan the old content and pass; a CRLF/backslash-polluted path must be
# normalised. doc/docs.md has one line on master and one more on feature: the
# claims detector must get it with its base copy and list only the feature line
# (rev 120; the runner gave it .v files only, so a batch never listed docs).
# doc/aa.md and doc/wt.md gain lines in the working tree only, and notes.txt is a
# changed file of no target kind: no-arg mode must take the first two and leave
# the third. vlib/h2a and vlib/h2b each hold the arm-parity known_bad pair and a
# file that sorts before it, so --at must extract every sibling of every target
# folder. Two more repos have no master: one has main, the other has neither,
# only branches trunk and feature and an origin/HEAD that names origin/trunk;
# no-arg mode must take its base from main and from origin/HEAD (rev 122).
smoke() { # $1=label $2=expected rc $3=regex the output must match, rest=runner args
    local label="$1" want="$2" re="$3"; shift 3
    local out rc
    out="$(cd "$r" && unset GIT_DIR GIT_WORK_TREE && timeout "$timeout_s" "${runner[@]}" "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq "$want" ] && printf '%s\n' "$out" | grep -qE -- "$re"; then
        pass=$((pass+1)); [ -n "${VERBOSE:-}" ] && echo "  [ OK ] runner-smoke/$label (exit $rc)"
    else
        fail=$((fail+1)); failures+=("runner-smoke/$label: exit $rc, expected $want and /$re/")
        echo "  [FAIL] runner-smoke/$label: exit $rc, expected $want and /$re/"
        printf '%s\n' "$out" | sed 's/^/         | /' | head -20
    fi
}
commit_all() { git add -A && git -c user.name=f -c user.email=f@x -c commit.gpgsign=false commit -q -m "$1"; }
# The compiler the runners pick here, and its id as they put it in a build's key.
vreal="$(type -P -- "${vexe:-v}")"
vid="$([ -n "$vreal" ] && sha256sum < "$vreal" | cut -c1-64)"
check_eq() { # $1=label $2=got $3=wanted
    if [ "$2" = "$3" ]; then
        pass=$((pass+1)); [ -n "${VERBOSE:-}" ] && echo "  [ OK ] runner-smoke/$1"
    else
        fail=$((fail+1)); failures+=("runner-smoke/$1: got '$2', wanted '$3'")
        echo "  [FAIL] runner-smoke/$1: got '$2', wanted '$3'"
    fi
}
# mkwrap <file> <tag> <log>: a compiler of its own content that logs "<tag> <what it builds>"
# and runs the real one.
mkwrap() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\n# compiler %s\nfor a; do :; done\necho "%s $(basename "$a" .v)" >> "%s"\nexec "%s" "$@"\n' \
        "$2" "$2" "$3" "$vreal" > "$1" && chmod +x "$1"
}
# log_of <log> <stem prefix>: the builds of that kind in a mkwrap log, on one line.
log_of() { grep " $2" "$1" 2>/dev/null | tr '\n' ';'; }
# path_without <name> <path>: the path without any program of that name. A folder that holds
# one is replaced by links to the rest of it.
path_without() {
    local out="$work/without-$1-$RANDOM" d
    mkdir -p "$out"; local res="$out"
    local IFS=:
    for d in $2; do
        if [ -x "$d/$1" ] && [ ! -d "$d/$1" ]; then
            ln -s "$d"/* "$out/" 2>/dev/null; rm -f "$out/$1"
        else
            res="$res:$d"
        fi
    done
    printf '%s' "$res"
}
no_v_path="$(path_without v "$PATH")"
no_sha_path="$(path_without sha256sum "$PATH")"
no_hash_path="$(path_without shasum "$no_sha_path")"
# plant <dir> <stem> <source> <shell line>: an executable named as the runner names
# its cached build of <source>, so a case can see whether the runner runs it. The
# old file is removed first: one that was just run cannot be rewritten in place
# (ETXTBSY). A plant that fails is a failure, never a silently real build.
plant() {
    local key f
    if [ "$2" = run_detectors ]; then
        # The runner's key covers the folder of its source too, as run_detectors.sh computes it.
        key="$( { printf '%s\n' "$(cd "$(dirname "$3")" && pwd -P)" "$vid"; cat "$3"; } | sha256sum | cut -c1-16)"
    else
        key="$( { cat "$3"; printf '\n%s' "$vid"; } | sha256sum | cut -c1-16)"
    fi
    f="$1/$2-$key"
    if ! { mkdir -p "$1" && rm -f "$f" && printf '#!/bin/sh\n%s\n' "$4" > "$f" && chmod +x "$f"; }; then
        fail=$((fail+1)); failures+=("runner-smoke: could not plant $f")
        echo "  [FAIL] runner-smoke: could not plant $f"
    fi
}
# runner_cases <label prefix>: every case, through "${runner[@]}".
runner_cases() {
    local p="$1" n
    local saved=("${runner[@]}") lp="$root/detectors/detect_lenient_parse.v"
    r="$work/runner-smoke"
    smoke $p/no-arg-flags-changed-file 1 'FLAG\] detect_lenient_parse'
    smoke $p/at-master-passes 0 '@ master' --at master vlib/x/parse.v
    smoke $p/at-equals-form 0 '@ master' --at=master vlib/x/parse.v
    smoke $p/normalised-path 1 'target: vlib/x/parse\.v' "vlib\\x\\parse.v"$'\r'
    smoke $p/docs-target-gets-base-copy 1 "$docs_flag" doc/docs.md
    smoke $p/docs-target-lists-the-new-line 1 "$docs_line" doc/docs.md
    smoke $p/no-arg-selects-changed-docs 1 "$docs_flag"
    smoke $p/no-arg-selects-working-tree-docs 1 "$wt_flag"
    smoke $p/no-arg-skips-other-kinds 1 "$noarg_count"
    smoke $p/at-master-scans-old-docs 0 "$docs_at_ok" --at master doc/docs.md
    smoke $p/at-master-scans-every-target 0 '2 target file\(s\) @ master' --at master doc/docs.md vlib/x/parse.v
    smoke $p/at-master-extracts-target-siblings 1 'summary: 2 detector runs, 2 flagged' \
        --at master --only settings_arm_parity vlib/h2a/h2_mux_conn.v vlib/h2b/h2_mux_conn.v
    smoke $p/base-option-sets-the-base-copy 0 "$docs_at_ok" --base feature doc/docs.md
    smoke $p/base-equals-form 0 "$docs_at_ok" --base=feature doc/docs.md
    smoke $p/only-option-picks-detectors 1 'summary: 1 detector runs, 1 flagged' --only lenient_parse vlib/x/parse.v
    smoke $p/only-equals-form 1 'summary: 1 detector runs, 1 flagged' --only=lenient_parse vlib/x/parse.v
    smoke $p/missing-named-target-is-reported 1 'skipped: doc/missing\.md' doc/missing.md doc/docs.md
    smoke $p/target-no-detector-takes-is-reported 1 'no detector applies to this file' notes.txt doc/docs.md
    # The needed detectors are those of every target, not of the last one only.
    smoke $p/first-target-decides-what-is-needed-too 1 'summary: 1 detector runs, 1 flagged ===' --only settings_arm_parity vlib/h2a/h2_mux_conn.v doc/docs.md
    # A cold cache builds only what the run needs, with the compiler find_v picks.
    runner=(env "XDG_CACHE_HOME=$work/cold-$p" "${saved[@]}")
    smoke $p/cold-cache-builds-the-needed-detector 1 'summary: 1 detector runs, 1 flagged' --only lenient_parse vlib/x/parse.v
    n="$(ls "$work/cold-$p/review-tools-bin" 2>/dev/null | grep -c '^detect_')"
    if [ "$n" -eq 1 ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failures+=("runner-smoke/$p/cold-cache-holds-one-detector: $n detector builds, expected 1")
        echo "  [FAIL] runner-smoke/$p/cold-cache-holds-one-detector: $n detector builds, expected 1"
    fi
    # Builds already in the shared temp folder are never run: both caches lived there
    # before rev 122, under names anyone could predict from the sources.
    plant "$work/tmp-$p/review-tools-bin" detect_lenient_parse "$lp" 'echo PLANTED; exit 7'
    plant "$work/tmp-$p/review-tools-bin" run_detectors "$root/detectors/run_detectors.v" 'echo PLANTED; exit 7'
    runner=(env "TMPDIR=$work/tmp-$p" "XDG_CACHE_HOME=$work/cache-$p" "${saved[@]}")
    smoke $p/shared-temp-builds-are-not-run 1 'FLAG\] detect_lenient_parse' --only lenient_parse vlib/x/parse.v
    # The per-run folder is new and private: a build in the user's own cache reports it.
    plant "$work/cache-$p/review-tools-bin" detect_lenient_parse "$lp" \
        'echo "TMPDIR_SEEN $(ls -ld .. | cut -c1-10) $(basename "$(cd .. && pwd)")"'
    smoke $p/per-run-folder-is-private 0 'TMPDIR_SEEN drwx------ run_detectors_[0-9]+_[0-9a-f]{16}' \
        --at master --only lenient_parse vlib/x/parse.v
    # Every run removes its per-run folder, whatever its exit: V's exit() runs no
    # defer, and before rev 122 each flagged or failed run left its folder behind.
    mkdir -p "$work/leak-$p"
    runner=(env "TMPDIR=$work/leak-$p" "${saved[@]}")
    smoke $p/leak-flagged 1 'FLAG\] detect_lenient_parse' --only lenient_parse vlib/x/parse.v
    smoke $p/leak-clean 0 '@ master' --at master --only lenient_parse vlib/x/parse.v
    smoke $p/leak-no-target 2 'no target' doc/missing.md
    smoke $p/leak-unknown-revision 2 'unknown revision' --at no-such-rev vlib/x/parse.v
    smoke $p/leak-nothing-checked 2 'nothing was checked' notes.txt
    n="$(find "$work/leak-$p" -mindepth 1 -maxdepth 1 -name 'run_detectors_*' | wc -l)"
    if [ "$n" -eq 0 ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failures+=("runner-smoke/$p/per-run-folders-are-removed: $n left in the temp dir")
        echo "  [FAIL] runner-smoke/$p/per-run-folders-are-removed: $n left in the temp dir"
    fi
    # A relative temp folder: under --at the runner works inside its per-run folder, where
    # a relative path to the base copies leads nowhere (rev 129).
    mkdir -p "$r/reltmp-$p"
    runner=(env "TMPDIR=reltmp-$p" "${saved[@]}")
    smoke $p/relative-temp-keeps-base-copies 1 "$docs_flag" --at feature --base master doc/docs.md
    rm -rf "$r/reltmp-$p"
    # A temp folder spelled with `..` after a link: the per-run folder goes where the system
    # reads that path, in the parent of the link's target (rev 129).
    mkdir -p "$work/dd-$p/real/inside" "$work/dd-$p/top"
    ln -sfn "$work/dd-$p/real/inside" "$work/dd-$p/top/lnk"
    plant "$work/cache-$p/review-tools-bin" detect_lenient_parse "$lp" 'echo "TMPREAL $(cd .. && pwd -P)"'
    runner=(env "TMPDIR=$work/dd-$p/top/lnk/.." "XDG_CACHE_HOME=$work/cache-$p" "${saved[@]}")
    smoke $p/dotdot-temp-is-read-as-the-system-reads-it 0 "TMPREAL $(cd -P "$work" && pwd -P)/dd-$p/real/run_detectors_" \
        --at master --only lenient_parse vlib/x/parse.v
    # A relative temp folder is the one below the folder the runner is started from, not below
    # the repo root it moves to: one that is only in `sub` is used, one only at the root is not.
    mkdir -p "$r/sub/insub-$p" "$r/atroot-$p"
    runner=(env "TMPDIR=insub-$p" "XDG_CACHE_HOME=$work/cache-$p" sh -c 'cd sub && exec "$@"' sh "${saved[@]}")
    smoke $p/relative-temp-is-below-the-start-folder 0 "TMPREAL $(cd -P "$r" && pwd -P)/sub/insub-$p/run_detectors_" \
        --at master --only lenient_parse vlib/x/parse.v
    runner=(env "TMPDIR=atroot-$p" "XDG_CACHE_HOME=$work/cache-$p" sh -c 'cd sub && exec "$@"' sh "${saved[@]}")
    smoke $p/relative-temp-is-not-below-the-repo-root 2 'cannot create a private folder .*/sub/atroot-' \
        --at master --only lenient_parse vlib/x/parse.v
    # The same with `..` after a link: the link's target decides, not the text of the path.
    mkdir -p "$r/sub/reldd-$p/real/inside" "$r/sub/reldd-$p/top"
    ln -sfn ../real/inside "$r/sub/reldd-$p/top/lnk"
    runner=(env "TMPDIR=reldd-$p/top/lnk/.." "XDG_CACHE_HOME=$work/cache-$p" sh -c 'cd sub && exec "$@"' sh "${saved[@]}")
    smoke $p/relative-dotdot-temp-follows-the-link 0 "TMPREAL $(cd -P "$r" && pwd -P)/sub/reldd-$p/real/run_detectors_" \
        --at master --only lenient_parse vlib/x/parse.v
    rm -rf "$r/sub" "$r/atroot-$p"
    # An empty TMPDIR is the system's temp folder, /tmp, as before: on macOS the runner reads
    # TMPDIR itself, and an empty one must not become the folder it starts in.
    runner=(env "TMPDIR=" "XDG_CACHE_HOME=$work/cache-$p" "${saved[@]}")
    smoke $p/empty-temp-is-the-system-temp 0 "TMPREAL $(cd -P /tmp && pwd -P)/run_detectors_" \
        --at master --only lenient_parse vlib/x/parse.v
    # Two copies of review-tools with the same runner text each run their own detectors: the
    # runner finds them beside the source it was built from, so run_detectors.sh must not
    # hand one copy's cached build to the other (rev 129). Only the sh entry point caches it.
    if [ "$p" = sh ]; then
        local copy="$work/rt-copy"
        rm -rf "$copy" "$work/xc"
        mkdir -p "$copy/skills/code-review"
        cp -r "$root/detectors" "$copy/"
        cp "$detdir/run_detectors.sh" "$copy/skills/code-review/"
        printf 'module main\n\nfn main() {\n\tprintln("FROM THE COPY")\n}\n' > "$copy/detectors/detect_lenient_parse.v"
        runner=(env "XDG_CACHE_HOME=$work/xc" bash "$copy/skills/code-review/run_detectors.sh")
        smoke $p/a-copy-runs-its-own-detectors 0 'FROM THE COPY' --only lenient_parse vlib/x/parse.v
        runner=(env "XDG_CACHE_HOME=$work/xc" "${saved[@]}")
        smoke $p/the-checkout-runs-its-own-detectors-after-a-copy 1 'FLAG\] detect_lenient_parse' \
            --only lenient_parse vlib/x/parse.v
    fi
    # The compiler is part of both build keys (rev 131): a build is reused only with the same
    # compiler, whatever path it is named by. Each wrapper logs its own tag and what it built.
    local vw="$work/vw-$p" vl="$work/vlog-$p" vc
    rm -f "$vl"
    mkwrap "$vw/one" one "$vl"; mkwrap "$vw/two" two "$vl"; ln -sfn "$vw/one" "$vw/link"
    for vc in one one two one link; do
        runner=(env "XDG_CACHE_HOME=$work/vk-$p" "DETECT_V=$vw/$vc" "${saved[@]}")
        smoke $p/runs-with-compiler-$vc 1 'FLAG\] detect_lenient_parse' --only lenient_parse vlib/x/parse.v
    done
    check_eq $p/another-compiler-rebuilds-and-the-same-one-does-not "$(log_of "$vl" detect_)" \
        'one detect_lenient_parse;two detect_lenient_parse;'
    [ "$p" = sh ] && check_eq $p/another-compiler-rebuilds-the-runner "$(log_of "$vl" run_detectors)" \
        'one run_detectors;two run_detectors;'
    # A compiler that cannot be read ends the run, builds in the cache or not.
    # Not a FIFO either, or any other special file: reading one would hang the run.
    mkfifo "$vw/fifo"
    local unreadable=(/no/such/v no_such_v_name "$vw" "$vw/fifo")
    # Root reads a file without read permission, so that one is no case for root.
    mkwrap "$vw/noread" noread "$vl"; chmod 111 "$vw/noread"
    [ "$(id -u)" -ne 0 ] && unreadable+=("$vw/noread")
    for vc in "${unreadable[@]}"; do
        runner=(env "XDG_CACHE_HOME=$work/vk-$p" "DETECT_V=$vc" "${saved[@]}")
        smoke $p/unreadable-compiler-ends-the-run 2 "cannot read the V compiler $vc( |:|\$)" --only lenient_parse vlib/x/parse.v
    done
    # Which compiler: DETECT_V (a bare name is looked up on PATH), else `v` on PATH, else the
    # target repo's own. The wrapper in the target repo must not be used before the one on PATH.
    rm -f "$vl"
    mkwrap "$vw/named/vnamed" named "$vl"; mkwrap "$vw/path/v" path "$vl"; mkwrap "$r/v" repo "$vl"
    runner=(env "PATH=$vw/named:$PATH" "XDG_CACHE_HOME=$work/vn-$p" DETECT_V=vnamed "${saved[@]}")
    smoke $p/a-bare-compiler-name-is-looked-up-on-path 1 'FLAG\] detect_lenient_parse' --only lenient_parse vlib/x/parse.v
    check_eq $p/the-named-compiler-built "$(log_of "$vl" detect_)" 'named detect_lenient_parse;'
    # A DETECT_V with a separator is a path from the folder the run starts in, here two below
    # the repo root: from the cache folder, where the builds run, it leads nowhere.
    rm -f "$vl"; r="$r/vlib/x"
    runner=(env "XDG_CACHE_HOME=$work/vs-$p" "DETECT_V=../../../vw-$p/one" "${saved[@]}")
    smoke $p/a-relative-compiler-path-is-from-the-start-folder 1 'FLAG\] detect_lenient_parse' --only lenient_parse vlib/x/parse.v
    check_eq $p/the-relative-compiler-built "$(log_of "$vl" detect_)" 'one detect_lenient_parse;'
    r="$work/runner-smoke"
    rm -f "$vl"
    runner=(env -u DETECT_V "PATH=$vw/path:$PATH" "XDG_CACHE_HOME=$work/vp-$p" "${saved[@]}")
    smoke $p/with-v-on-path-and-in-the-repo 1 'FLAG\] detect_lenient_parse' --only lenient_parse vlib/x/parse.v
    check_eq $p/the-compiler-on-path-built "$(cut -d' ' -f1 "$vl" 2>/dev/null | sort -u | tr '\n' ';')" 'path;'
    rm -f "$vl"
    runner=(env -u DETECT_V "PATH=$no_v_path" "XDG_CACHE_HOME=$work/vr-$p" "${saved[@]}")
    smoke $p/with-v-in-the-repo-only 1 'FLAG\] detect_lenient_parse' --only lenient_parse vlib/x/parse.v
    check_eq $p/the-repos-own-compiler-built "$(cut -d' ' -f1 "$vl" 2>/dev/null | sort -u | tr '\n' ';')" 'repo;'
    rm -f "$r/v"
    mkdir "$r/v"
    smoke $p/a-folder-named-v-is-no-compiler 2 'no V compiler found' --only lenient_parse vlib/x/parse.v
    rmdir "$r/v"
    : > "$r/v"; chmod 644 "$r/v"
    smoke $p/a-file-that-cannot-run-is-no-compiler 2 'no V compiler found' --only lenient_parse vlib/x/parse.v
    rm -f "$r/v"
    smoke $p/no-compiler-at-all 2 'no V compiler found' --only lenient_parse vlib/x/parse.v
    # Where sha256sum is missing the script hashes with shasum; without either it says so. An
    # empty hash would give every runner text and compiler one key.
    if [ "$p" = sh ]; then
        if PATH="$no_sha_path" type -P shasum >/dev/null; then
            runner=(env "PATH=$no_sha_path" "XDG_CACHE_HOME=$work/vh-$p" "${saved[@]}")
            smoke $p/shasum-stands-in-for-sha256sum 1 'FLAG\] detect_lenient_parse' --only lenient_parse vlib/x/parse.v
            check_eq $p/the-shasum-key-is-a-key "$(ls "$work/vh-$p/review-tools-bin" | grep -cE '^run_detectors-[0-9a-f]{16}$')" 1
        fi
        runner=(env "PATH=$no_hash_path" "XDG_CACHE_HOME=$work/vi-$p" "${saved[@]}")
        smoke $p/no-hash-program 2 'neither sha256sum nor shasum' --only lenient_parse vlib/x/parse.v
    fi
    # A detector that does not build is named and the run exits 2; before rev 131 it was left
    # out and the run could exit 0. In this copy one detector does not compile, one is gone.
    local br="$work/rt-broken"
    if [ ! -d "$br" ]; then
        mkdir -p "$br/skills/code-review"
        cp -r "$root/detectors" "$br/"
        cp "$detdir/run_detectors.sh" "$br/skills/code-review/"
        printf 'module main\n\nfn main() {\n\tno_such_function()\n}\n' > "$br/detectors/detect_info_leak.v"
        rm "$br/detectors/detect_unsafe_blocks.v"
    fi
    if [ "$p" = sh ]; then
        runner=(env "XDG_CACHE_HOME=$work/xb" bash "$br/skills/code-review/run_detectors.sh")
    else
        "$vexe" -o "$work/bin/rd-broken" "$br/detectors/run_detectors.v" >/dev/null 2>&1
        runner=(env "XDG_CACHE_HOME=$work/xb" "$work/bin/rd-broken")
    fi
    smoke $p/unbuilt-detector-is-named 2 'summary: 1 detector runs, 1 flagged, 1 not built: detect_info_leak ===' --only _le vlib/x/parse.v
    smoke $p/unbuilt-detector-leaves-the-others-running 2 'FLAG\] detect_lenient_parse' --only _le vlib/x/parse.v
    smoke $p/unbuilt-detector-is-not-a-pass 2 'summary: 1 detector runs, 0 flagged, 1 not built: detect_info_leak ===' \
        --at master --only _le vlib/x/parse.v
    smoke $p/missing-detector-source-is-named 2 'summary: 0 detector runs, 0 flagged, 1 not built: detect_unsafe_blocks ===' \
        --only unsafe_blocks vlib/x/parse.v
    smoke $p/every-unbuilt-detector-is-named 2 ', 2 not built: detect_info_leak, detect_unsafe_blocks ===' vlib/x/parse.v
    # Only a detector the run needs counts: neither of the two applies to a .md target.
    smoke $p/unbuilt-detector-that-no-target-needs-does-not-count 1 'summary: 1 detector runs, 1 flagged ===' doc/docs.md
    # An unbuilt detector did match: the run must not say that none did.
    check_eq $p/unbuilt-is-not-reported-as-unmatched \
        "$(cd "$r" && unset GIT_DIR GIT_WORK_TREE && timeout "$timeout_s" "${runner[@]}" --only info_leak vlib/x/parse.v 2>&1 | grep -c 'no detector matched')" 0
    # A detector that ends in any other way than exit 0 or 1 gave no verdict: it is named, once
    # however many targets it failed on, and the run exits 2 (rev 131; it could exit 0 before).
    plant "$work/xe-$p/review-tools-bin" detect_lenient_parse "$lp" 'echo CRASHED; exit 7'
    if [ "$p" = sh ]; then
        runner=(env "XDG_CACHE_HOME=$work/xe-$p" bash "$br/skills/code-review/run_detectors.sh")
    else
        runner=(env "XDG_CACHE_HOME=$work/xe-$p" "$work/bin/rd-broken")
    fi
    smoke $p/unbuilt-and-failed-detectors-are-both-named 2 \
        ', 1 not built: detect_info_leak, 1 ended in error: detect_lenient_parse ===' --only _le vlib/x/parse.v
    runner=(env "XDG_CACHE_HOME=$work/xe-$p" "${saved[@]}")
    smoke $p/failed-detector-is-not-a-pass 2 'summary: 1 detector runs, 0 flagged, 1 ended in error: detect_lenient_parse ===' \
        --only lenient_parse vlib/x/parse.v
    smoke $p/failed-detector-is-named-once 2 'summary: 2 detector runs, 0 flagged, 1 ended in error: detect_lenient_parse ===' \
        --only lenient_parse vlib/x/parse.v vlib/h2a/h2_a.v
    plant "$work/xe-$p/review-tools-bin" detect_lenient_parse "$lp" 'kill -9 $$'
    smoke $p/killed-detector-is-not-a-pass 2 '1 ended in error: detect_lenient_parse ===' --only lenient_parse vlib/x/parse.v
    # The one that fails runs first (the order is by name), so the other one's row comes after it.
    plant "$work/xf-$p/review-tools-bin" detect_info_leak "$root/detectors/detect_info_leak.v" 'echo CRASHED; exit 7'
    runner=(env "XDG_CACHE_HOME=$work/xf-$p" "${saved[@]}")
    smoke $p/failed-detector-leaves-the-others-running 2 'FLAG\] detect_lenient_parse' --only _le vlib/x/parse.v
    runner=("${saved[@]}")
    r="$work/runner-smoke-main"
    smoke $p/no-master-falls-back-to-main 1 "$docs_flag"
    smoke $p/no-master-header-names-main 1 'base [0-9a-f]+ \(merge base of main and HEAD\)'
    r="$work/runner-smoke-origin"
    smoke $p/no-master-or-main-falls-back-to-origin-head 1 "$docs_flag"
    smoke $p/no-master-header-names-origin-head 1 'base [0-9a-f]+ \(merge base of origin/trunk and HEAD\)'
}
if [ "$check_coverage" -eq 1 ]; then
    r="$work/runner-smoke"; rm -rf "$r" "$work/runner-smoke-main" "$work/runner-smoke-origin"
    mkdir -p "$r/vlib/x" "$r/doc" "$work/runner-smoke-main/doc" "$work/runner-smoke-origin/doc"
    if ( cd "$r" && unset GIT_DIR GIT_WORK_TREE \
         && git init -q -b master . \
         && cp "$here/detect_lenient_parse/known_good/guarded/parse.v" vlib/x/parse.v \
         && printf 'Docs line written on master.\n' > doc/docs.md \
         && printf 'Working-tree docs line written on master.\n' > doc/wt.md \
         && printf 'Second working-tree docs file, written on master.\n' > doc/aa.md \
         && for d in h2a h2b; do mkdir -p vlib/$d \
              && cp "$here/detect_settings_arm_parity/known_bad/comment_only_arm/"h2_*.v vlib/$d/ \
              && printf 'module http\n' > vlib/$d/h2_a.v || exit 1; done \
         && commit_all base \
         && git checkout -q -b feature \
         && cp "$here/detect_lenient_parse/known_bad/unguarded/parse.v" vlib/x/parse.v \
         && printf 'Docs line added on feature.\n' >> doc/docs.md \
         && printf 'Not a target kind, added on feature.\n' > notes.txt \
         && commit_all feature \
         && printf 'Working-tree line one, uncommitted.\nWorking-tree line two, uncommitted.\n' >> doc/wt.md \
         && printf 'Aa line one.\nAa line two.\nAa line three.\n' >> doc/aa.md ) \
       && ( cd "$work/runner-smoke-main" && unset GIT_DIR GIT_WORK_TREE \
         && git init -q -b main . \
         && printf 'Docs line written on main.\n' > doc/docs.md && commit_all base \
         && git checkout -q -b feature \
         && printf 'Docs line added on feature.\n' >> doc/docs.md && commit_all feature ) \
       && ( cd "$work/runner-smoke-origin" && unset GIT_DIR GIT_WORK_TREE \
         && git init -q -b trunk . \
         && printf 'Docs line written on trunk.\n' > doc/docs.md && commit_all base \
         && git update-ref refs/remotes/origin/trunk HEAD \
         && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk \
         && git checkout -q -b feature \
         && printf 'Docs line added on feature.\n' >> doc/docs.md && commit_all feature ); then
        # Both runners: the shell one, and the V one compiled once (when V is available).
        # The docs cases: 1 new line in doc/docs.md, 2 in doc/wt.md and 3 in doc/aa.md mean
        # each got its base copy (one more without it); no-arg mode has 4 targets, 5 if it
        # took notes.txt, 3 if it lost one of the two working-tree files.
        docs_flag='FLAG\] detect_external_behavior_claims\.v +RESULT: 1 new'
        docs_line='\| +line 2: Docs line added on feature\.'
        wt_flag='FLAG\] detect_external_behavior_claims\.v +RESULT: 2 new'
        noarg_count='run_detectors: 4 target file\(s\), base '
        docs_at_ok='\[ OK \] detect_external_behavior_claims\.v'
        runner=(bash "$detdir/run_detectors.sh")
        runner_cases sh
        if [ -n "$vexe" ] && "$vexe" -o "$(to_native "$work/bin/run_detectors")" "$(to_native "$root/detectors/run_detectors.v")" >/dev/null 2>&1; then
            runner=("$work/bin/run_detectors")
            runner_cases v
        else
            echo "  [SKIP] runner-smoke/v: no V compiler or run_detectors.v did not compile"; skip=$((skip+1))
        fi
    else
        echo "  [FAIL] runner-smoke: could not build repo"; fail=$((fail+1)); failures+=("runner-smoke: repo")
    fi
fi

rm -rf "$work"
echo "=== fixtures: $pass passed, $fail failed, $skip skipped ==="
for f in "${failures[@]:-}"; do [ -n "$f" ] && echo "  - $f"; done
[ "$fail" -gt 0 ] && exit 1
exit 0
