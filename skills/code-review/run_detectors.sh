#!/usr/bin/env bash
# run_detectors.sh — run every applicable mechanical review detector in one shot.
#
# Replaces the hand-written `for d in detect_a detect_b ...` loop rebuilt from
# scratch in every review session. Selects detectors by a target-file manifest
# (a mux-only detector is not run against h2_server.v and vice versa), runs each,
# and prints a pass/flag table plus a summary.
#
# Usage:
#   bash .claude/skills/code-review/run_detectors.sh [file.v ...]
#
# With no args, the target set is every changed .v file (working tree vs HEAD,
# plus the branch diff vs merge-base with master). Run from the repo root, in
# WSL/Linux — several detectors use per-line subshells that hang on git-bash.
#
# Works from a Windows-created git WORKTREE under WSL too: when Linux git
# cannot read the worktree's drive-letter `gitdir:` pointer, the script
# resolves it to /mnt/<drive>/... itself and exports GIT_DIR/GIT_WORK_TREE
# (see the fallback below). From a worktree, invoke the script by absolute
# path (e.g. /mnt/s/repo/vlang/.claude/skills/code-review/run_detectors.sh);
# the repo-relative path in the usage line assumes the main checkout, where
# .claude/skills/code-review is a junction to ~/.claude/skills/code-review.
#
# Exit: 0 if no detector flagged; 1 if any detector exited 1 (candidates to
# review — for enumerate-and-verify detectors that is not automatically a bug);
# 2 on usage/environment errors.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
# repo_root is the TARGET repo being reviewed (from CWD via git), which is
# NOT necessarily 3 levels up from this script's own location once these
# detectors live in a global (~/.claude/skills) rather than per-project
# (.claude/skills) directory. $here stays script-location-relative (that's
# always where the sibling detector .sh files live); repo_root is resolved
# independently so this works identically from either location.
git_err="$(git rev-parse --show-toplevel 2>&1 >/dev/null)"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$repo_root" ]; then
    # WSL fallback. A worktree created on Windows has a `.git` POINTER FILE
    # containing a drive-letter path (`gitdir: S:/repo/vlang/.git/worktrees/x`)
    # that Linux git cannot interpret, so rev-parse dies with
    # "not a git repository: (null)". Walk up from CWD to that pointer, translate
    # the path to /mnt/<drive>/..., and hand git the resolved locations
    # explicitly. GIT_DIR/GIT_WORK_TREE are EXPORTED on purpose: the detectors
    # run below do their own `git show`/`git merge-base`/`git diff` and must
    # inherit the same resolution, or every one of them fails the same way.
    dir="$PWD"
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        if [ -d "$dir/.git" ]; then
            break   # a real .git directory: git itself failed for another reason
        fi
        if [ -f "$dir/.git" ]; then
            gitdir="$(sed -n 's/^gitdir: *//p' "$dir/.git" | head -1 | tr -d '\r')"
            case "$gitdir" in
                [A-Za-z]:*)
                    conv=""
                    command -v wslpath >/dev/null 2>&1 && conv="$(wslpath -u "$gitdir" 2>/dev/null)"
                    if [ -z "$conv" ]; then
                        drive="$(printf '%s' "${gitdir%%:*}" | tr 'A-Z' 'a-z')"
                        rest="$(printf '%s' "${gitdir#?:}" | tr '\\' '/')"
                        conv="/mnt/$drive/${rest#/}"
                    fi
                    gitdir="$conv"
                    ;;
            esac
            if [ -d "$gitdir" ]; then
                export GIT_DIR="$gitdir" GIT_WORK_TREE="$dir"
                repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
                [ -n "$repo_root" ] && echo "run_detectors: resolved Windows worktree gitdir -> $GIT_DIR" >&2
            fi
            break
        fi
        dir="${dir%/*}"
    done
fi
if [ -z "$repo_root" ]; then
    echo "run_detectors: not inside a git repository (run from within the target repo)" >&2
    [ -n "$git_err" ] && echo "run_detectors: git said: $git_err" >&2
    exit 2
fi
cd "$repo_root" || exit 2

# ---- target files ----------------------------------------------------------
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    base="$(git merge-base master HEAD 2>/dev/null)"
    mapfile -t files < <(
        { git diff --name-only HEAD; [ -n "$base" ] && git diff --name-only "$base"...HEAD; } \
        | grep -E '\.v$' | sort -u
    )
fi
# keep only files that exist
existing=()
for f in "${files[@]:-}"; do [ -f "$f" ] && existing+=("$f"); done
if [ "${#existing[@]}" -eq 0 ]; then
    echo "run_detectors: no target .v files (pass paths explicitly or make changes first)" >&2
    exit 2
fi

# ---- manifest: detector -> basename regex of files it applies to ------------
# A detector runs once per matching target file (the file is passed as $1;
# detectors with a hardcoded target ignore it, which is harmless).
declare -A manifest=(
    # any V file
    [detect_lenient_parse.sh]='.*\.v'
    [detect_info_leak.sh]='.*\.v'
    [detect_unsafe_blocks.sh]='.*\.v'
    [detect_unshared_getter_return.sh]='.*\.v'
    # any file with a mut-receiver connection/session struct (auto-detects
    # receiver name + growth pattern, safe to run broadly since it no-ops
    # cleanly on files with nothing to scan) -- widened from '^h2_.*\.v' after
    # that scope let h3_conn.v's dead_request_streams growth go completely
    # unscanned (PR #28129 review, 2026-08-21; see code-review-misses.md).
    # Narrower scoping is exactly how the NEXT differently-prefixed driver
    # file falls into the same blind spot again.
    [detect_unbounded_accum.sh]='.*\.v'
    # any h2 driver file
    [detect_error_scope.sh]='^h2_.*\.v'
    [detect_hpack_decode_scope.sh]='^h2_.*\.v'
    [detect_swallowed_write.sh]='^h2_.*\.v'
    [detect_settings_arm_parity.sh]='^h2_.*\.v'
    [detect_flag_priority_order.sh]='^h2_.*\.v'
    [detect_padding_credit.sh]='^h2_(conn|server|mux_conn)\.v'
    [detect_malformed_content_length.sh]='^h2_(conn|mux_conn)\.v'
    [detect_h2_response_field_validation.sh]='^h2_(conn|mux_conn)\.v'
    # h2 server only
    [detect_hpack_skip_on_half_closed.sh]='^h2_server\.v'
    [detect_orphan_continuation_gate.sh]='^h2_server\.v'
    [detect_stream_state_even_idle.sh]='^h2_server\.v'
    [detect_pump_delegates_dispatch.sh]='^h2_server\.v'
    [detect_server_window_single_pass.sh]='^h2_server\.v'
    [detect_locally_reset_consumers.sh]='^h2_server\.v'
    # sync client only
    [detect_status_fallthrough.sh]='^h2_conn\.v'
    [detect_h2conn_1xx_end_stream.sh]='^h2_conn\.v'
    [detect_h2conn_response_parity.sh]='^h2_conn\.v'
    # mux client only
    [detect_fmu_scope.sh]='^h2_mux_conn\.v'
    [detect_initial_window_recheck.sh]='^h2_mux_conn\.v'
    [detect_headers_max_reread.sh]='^h2_mux_conn\.v'
    [detect_missing_fcv_broadcast.sh]='^h2_mux_conn\.v'
    [detect_goaway_wmu_serialize.sh]='^h2_mux_conn\.v'
    [detect_peer_max_frame_wmu.sh]='^h2_mux_conn\.v'
    [detect_mux_table_size_update.sh]='^h2_mux_conn\.v'
    [detect_mux_trailers_preserved.sh]='^h2_mux_conn\.v'
    [detect_mux_headers_after_end.sh]='^h2_mux_conn\.v'
    [detect_mux_requires_closer.sh]='^h2_mux_conn\.v'
    # TLS server lifecycle
    [detect_close_idle_double_close.sh]='^(server_tls.*|ssl_connection\.c)\.v'
    [detect_close_idle_windows_double_close.sh]='^(server_tls.*|ssl_connection\.c)\.v'
    [detect_tls_accept_send_interruptible.sh]='^server_tls.*\.v'
    [detect_tls_weak_config.sh]='^(server_tls.*|ssl_connection\.c)\.v'
    # any TLS-wrapping transport adapter
    [detect_tls_read_precheck_poll.sh]='^h2_pooled_transport\.v'
    [detect_pooled_write_duration_reuse.sh]='^h2_pooled_transport\.v'
    [detect_pooled_conn_stored_by_value.sh]='^h2_pooled_transport\.v'
    # vschannel pooled dial path (Windows SChannel ALPN capability gate)
    [detect_vschannel_pooled_alpn_gate.sh]='^vschannel_pooled_transport_windows\.c\.v'
    # Transport connection pool (h1 + h2 shared cap/lifetime enforcement)
    [detect_pool_cap_scope_symmetry.sh]='^transport(_h2)?\.v'
    [detect_pool_collect_release_clear.sh]='^transport(_h2)?\.v'
    [detect_idle_cap_counts_busy_conns.sh]='^transport\.v'
    [detect_ungated_release_after_conditional_delete.sh]='^(transport(_h2)?|h2_mux_conn)\.v'
    # net.quic test files using ecdsa keys (manual-free C-interop resource, no GC)
    [detect_ecdsa_key_missing_free.sh]='^tls13_.*_test\.v'
    [detect_struct_wrapped_resource_leak.sh]='^tls13_.*_test\.v'
    # any net.quic test file (module quic compiles as one translation unit;
    # a new *_test.v with no present_openssl? gate hard-fails docker-ubuntu-musl)
    [detect_quic_test_missing_openssl_gate.sh]='.*_test\.v'
    # any file with a compute_next_timeout/next_timeout-style scheduler
    # aggregator (auto-detects the fn/struct, safe to run broadly)
    [detect_scheduler_field_coverage.sh]='.*\.v'
)

# ---- run --------------------------------------------------------------------
flagged=0
ran=0
skipped_all=1
printf '%s\n' "=== run_detectors: ${#existing[@]} target file(s) ==="
for f in "${existing[@]}"; do
    echo "--- target: $f"
    bn="$(basename "$f")"
    for det in $(printf '%s\n' "${!manifest[@]}" | sort); do
        [ -f "$here/$det" ] || continue
        if echo "$bn" | grep -qE "${manifest[$det]}"; then
            skipped_all=0
            out="$(bash "$here/$det" "$f" 2>&1)"
            rc=$?
            ran=$((ran + 1))
            last="$(printf '%s\n' "$out" | grep -v '^\s*$' | tail -1)"
            if [ "$rc" -eq 0 ]; then
                printf '  [ OK ] %-46s %s\n' "$det" "$last"
            elif [ "$rc" -eq 1 ]; then
                printf '  [FLAG] %-46s %s\n' "$det" "$last"
                printf '%s\n' "$out" | sed 's/^/         | /'
                flagged=$((flagged + 1))
            else
                printf '  [ERR%s] %-45s %s\n' "$rc" "$det" "$last"
            fi
        fi
    done
done

echo "=== summary: $ran detector runs, $flagged flagged ==="
if [ "$skipped_all" -eq 1 ]; then
    echo "(no detector matched any target file — nothing was checked)" >&2
    exit 2
fi
[ "$flagged" -gt 0 ] && exit 1
exit 0
