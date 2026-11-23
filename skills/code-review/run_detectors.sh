#!/usr/bin/env bash
# run_detectors.sh — thin bash entry point for WSL/macOS: builds (once, cached by
# source and compiler) and runs the V batch runner detectors/run_detectors.v with the
# same arguments. Everything else — target selection, base revision, the WSL
# worktree gitdir fallback, detector compilation and the manifest — lives in
# the V runner; see its header for usage. On Windows run the V runner directly
# from PowerShell: v.exe run <plugin>/detectors/run_detectors.v [args].
#
# Environment: DETECT_V names the V compiler (default: `v` on PATH, then the target
# repo's own ./v). The runner picks in the same order (its find_v).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
runner_src="$here/../../detectors/run_detectors.v"
[ -f "$runner_src" ] || { echo "run_detectors: $runner_src not found" >&2; exit 2; }

vexe="${DETECT_V:-}"
if [ -z "$vexe" ]; then
    vexe="$(type -P v)"
    if [ -z "$vexe" ]; then
        repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
        [ -n "$repo_root" ] && [ -f "$repo_root/v" ] && [ -x "$repo_root/v" ] && vexe="$repo_root/v"
    fi
fi
[ -n "$vexe" ] || { echo "run_detectors: no V compiler found (set DETECT_V, put v on PATH, or run from a repo with ./v)" >&2; exit 2; }
# A bare name is looked up on PATH, a relative path is from the folder the run starts in.
case "$vexe" in
    /*) ;;
    */*) vexe="$PWD/$vexe" ;;
    *) found="$(type -P -- "$vexe")"; vexe="${found:-$vexe}" ;;
esac
# sha256 prints the hash of its input, with sha256sum or, where that is missing, shasum.
sha256() { if type -P sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-64; }
type -P sha256sum >/dev/null || type -P shasum >/dev/null || { echo "run_detectors: neither sha256sum nor shasum found (run the V runner directly: v run detectors/run_detectors.v)" >&2; exit 2; }
# The compiler's content, as the V runner's compiler_id reads it: of a regular file only.
vid=""
[ -f "$vexe" ] && vid="$(sha256 2>/dev/null < "$vexe")"
[ -n "$vid" ] || { echo "run_detectors: cannot read the V compiler $vexe" >&2; exit 2; }

# The user's own cache folder, as the V runner's os.cache_dir() picks it: a build
# found here is run as this user, so it must not live in a shared temp folder,
# where another account could put a file under the predictable name first.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/review-tools-bin"
mkdir -p -m 700 "$cache"
# The key covers the folder the runner is built from as well as its text: the build finds the
# detectors beside its source (`@FILE`), so a copy of review-tools with the same runner text
# (a mutation run's scratch copy) must not hand its build, and its detectors, to this one.
# It also covers the compiler that makes the build.
src_dir="$(cd "$(dirname "$runner_src")" && pwd -P)"
key="$( { printf '%s\n' "$src_dir" "$vid"; cat "$runner_src"; } | sha256 | cut -c1-16)"
bin="$cache/run_detectors-$key"
if [ ! -x "$bin" ]; then
    # Compile from the cache dir: with the vlang checkout as cwd V resolves vlib
    # through that checkout, which is very slow over a WSL /mnt mount.
    ( cd "$cache" && "$vexe" -o "$bin" "$runner_src" ) || { echo "run_detectors: failed to compile $runner_src" >&2; exit 2; }
fi
exec "$bin" "$@"
