#!/usr/bin/env bash
# run_detectors.sh — thin bash entry point for WSL/macOS: builds (once, cached by
# source hash) and runs the V batch runner detectors/run_detectors.v with the
# same arguments. Everything else — target selection, base revision, the WSL
# worktree gitdir fallback, detector compilation and the manifest — lives in
# the V runner; see its header for usage. On Windows run the V runner directly
# from PowerShell: v.exe run <plugin>/detectors/run_detectors.v [args].
#
# Environment: DETECT_V names the V compiler (default: the target repo's own
# ./v, then `v` on PATH).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
runner_src="$here/../../detectors/run_detectors.v"
[ -f "$runner_src" ] || { echo "run_detectors: $runner_src not found" >&2; exit 2; }

vexe="${DETECT_V:-}"
if [ -z "$vexe" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$repo_root" ] && [ -x "$repo_root/v" ] && vexe="$repo_root/v"
fi
[ -z "$vexe" ] && command -v v >/dev/null 2>&1 && vexe="v"
[ -n "$vexe" ] || { echo "run_detectors: no V compiler found (set DETECT_V or put v on PATH)" >&2; exit 2; }

cache="${TMPDIR:-/tmp}/review-tools-bin"
mkdir -p "$cache"
key="$(sha256sum "$runner_src" | cut -c1-16)"
bin="$cache/run_detectors-$key"
if [ ! -x "$bin" ]; then
    # Compile from the cache dir: with the vlang checkout as cwd V resolves vlib
    # through that checkout, which is very slow over a WSL /mnt mount.
    ( cd "$cache" && "$vexe" -o "$bin" "$runner_src" ) || { echo "run_detectors: failed to compile $runner_src" >&2; exit 2; }
fi
exec "$bin" "$@"