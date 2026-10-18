# Detector weaknesses found while writing fixtures and porting (2026-10-18)

Observed while fixturing and then porting every detector to V. The ports
preserve these quirks on purpose (a port had to pass exactly the fixtures its
shell twin passed); each remains a candidate fix. Fixtures exercise the
path that works today, so fixing any of these needs a NEW known_bad case first.

## Argument-contract bugs (silent no-ops via the runner)

- FIXED (Step 4, runner owns git): `detect_info_leak.sh`, `detect_tls_weak_config.sh`
  took a BASE revision as `$1` while the runner passed a file, so via the runner
  they exited 0 without scanning. Both are per-file now. Same step: the four
  `<file...>` detectors (error_scope, hpack_decode_scope, padding_credit,
  swallowed_write) scanned the base copy in `$2` as a second target; the fixture
  runner now passes a decoy `$2` to every single-file case so this cannot recur.
- `detect_settings_arm_parity.sh` ignores argv beyond `$1` and finds its sibling by
  `h2_*.v` in the target's directory; the fixture needs an explicit `args`.
- `detect_quic_test_missing_openssl_gate.sh` reads `cmd/tools/vtest-self.v` relative
  to `git rev-parse --show-toplevel` from cwd; its skip-list grep requires a trailing
  comma after the entry.

## Pattern gaps (false negatives)

- `detect_ungated_release_after_conditional_delete.sh`: the `won := voidptr(a) ==
  voidptr(b)` capture is anchored at column 0, but statements are tab-indented, so a
  named guard variable is never recognised; only the inline `if voidptr(..) == ..`
  form works.
- `detect_flag_priority_order.sh` scans only functions starting `fn ` at column 0;
  `pub fn` is never scanned.
- `detect_pooled_write_duration_reuse.sh`, `detect_tls_read_precheck_poll.sh`: fn
  header must be exactly `fn (mut x T) write(` / `read(mut b []u8) !int {` at column
  0; `pub fn` or a non-mut receiver is invisible.
- `detect_struct_wrapped_resource_leak.sh`: only parenthesised tuple returns
  `fn f() (S, int)` are checked; `fn f() S` / `!S` is skipped. Uses gawk 3-arg
  `match()` (not mawk/BSD-awk portable).
- `detect_locally_reset_consumers.sh`: function names keyed on `/^fn /` (misses
  `pub fn`), and only receiver `c` is matched.
- `detect_close_idle_double_close.sh`: leak check looks only 2 lines after the `if`;
  exits 0 with SKIP when a hardcoded file is missing, so a rename passes silently.
- `detect_close_idle_windows_double_close.sh`: inspects only 20 lines after
  `for handle in handles`.
- Token-presence detectors that a comment would satisfy:
  `detect_h2conn_response_parity.sh` (message strings), `detect_h2conn_1xx_end_stream.sh`
  (`end_stream` + `return error|reset_stream` in branch, no ordering),
  `detect_hpack_skip_on_half_closed.sh` (`over_end` anywhere in the file).

## Exit-code inconsistencies

- `detect_headers_max_reread.sh` exits 2 when the function has fewer than two
  `H2HeadersFrame{` writes (a helper refactor would error instead of pass/fail).
- `detect_server_window_single_pass.sh` uses `set -e` + `content=$(cat ...)`: a
  missing file exits 1 (reads as "bug present"), not 2.
- `detect_mux_table_size_update.sh` and `detect_close_idle_windows_double_close.sh`
  exit 2 on a missing file while their siblings exit 0 with SKIP.

## Portability

- `detect_padding_credit.sh` uses `\b` under `grep -E` (GNU only).
- `detect_status_fallthrough.sh` spawns `tr`/`wc` per line (slow on git-bash).
- `detect_flag_priority_order.sh` is enumerate-only: any function with two
  early-return flag checks trips it, by design.

## Carried into the V ports (noted by the porting pass)

- `detect_struct_wrapped_resource_leak`: FIXED in the port only: `$2` was the
  resource regex, so through the runner the base-copy path became the regex and
  the detector was always clean. The port ignores a `$2` that is an existing path.
- `detect_info_leak`: the `log\.` alternative must be directly followed by `(`,
  so `log.info(...)` is never flagged.
- `detect_settings_arm_parity`, `detect_flag_priority_order`,
  `detect_locally_reset_consumers`, `detect_fmu_scope` (and siblings): only
  column-0 `fn ` headers are recognised, so `pub fn` is invisible or mis-attributed.
- `detect_goaway_wmu_serialize`, `detect_settings_arm_parity`, `detect_pool_*`:
  braces inside strings and comments count toward depth.
- `detect_h2conn_response_parity`, `detect_h2conn_1xx_end_stream`,
  `detect_hpack_skip_on_half_closed`: satisfied by the presence of a token
  anywhere in the file, a comment included.
- `detect_status_fallthrough`, `detect_missing_fcv_broadcast`: an unreadable
  file exits 1 (reads as "bug present"); siblings exit 2 or SKIP with 0.
- `detect_sibling_arms` (port of the .ps1): PowerShell `-match` was a
  case-insensitive .NET regex; the port matches a metacharacter-free pattern as
  a case-insensitive substring and anything else with a small ERE subset.
- The V `regex` module could not be trusted for grouped alternations
  (`^(a|b)\.v$` never matched), so no detector and not the runner manifest uses it.