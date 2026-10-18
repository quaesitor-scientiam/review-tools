// detect_close_idle_double_close — V port of
// skills/code-review/detect_close_idle_double_close.sh.
//
// close_idle force-closes an idle handle on Windows (net.close). The woken worker's
// handle_conn defer must then relinquish socket ownership (owns_socket = false)
// and STILL call conn.shutdown() for the TLS cleanup. Flags: no relinquish marker
// (double-close / TLS leak), or conn.shutdown() gated behind !was_force_closed.
//
// Usage: detect_close_idle_double_close   (no arguments; the two files are hardcoded)
// Exit: 1 on a bug; 0 when clean, when close_idle does not force-close, or when the
//       expected TLS server files are missing (SKIP).
// Quirks preserved: awk brace capture restarts at every `fn .*close_idle(` line;
// braces in comments/strings count; all diagnostics go to stderr like the .sh.
module main

import os

const idle_file = 'vlib/net/http/server_tls_idle.v'
const worker_file = 'vlib/net/http/server_tls_notd_use_openssl.v'

fn main() {
	if !os.is_file(idle_file) || !os.is_file(worker_file) {
		eprintln('SKIP: expected TLS server files not found')
		exit(0)
	}
	idle := read_trimmed(idle_file)
	worker := read_trimmed(worker_file)

	body := capture_braced(idle, fn (l string) bool {
		return has_in_order(l, ['fn ', 'close_idle('])
	})
	if body.len == 0 {
		eprintln('SKIP: no close_idle function in ${idle_file}')
		exit(0)
	}
	if !body.any(it.contains('net.close(')) {
		eprintln('OK: close_idle does not force-close (net.close); no double-close hazard')
		exit(0)
	}
	if !worker.any(has_owns_socket_false(it)) {
		eprintln('BUG: close_idle force-closes (net.close) but ${worker_file} never relinquishes socket ownership (owns_socket = false) — either a double-close (unconditional conn.shutdown) or a TLS-resource leak (conn.shutdown skipped on force-close)')
		exit(1)
	}
	// gate: `if !...was_force_closed...{` exists AND conn.shutdown() appears on a
	// matching `if !...was_force_closed` line or within the next two lines.
	mut gated := worker.any(has_gate_with_brace(it))
	if gated {
		mut leak := false
		for i, l in worker {
			if has_gate(l) {
				hi := if i + 2 >= worker.len { worker.len - 1 } else { i + 2 }
				for j in i .. hi + 1 {
					if worker[j].contains('conn.shutdown()') {
						leak = true
					}
				}
			}
		}
		gated = leak
	}
	if gated {
		eprintln('BUG: ${worker_file} gates conn.shutdown() behind !was_force_closed — TLS resources (mbedtls SSL/config/certs/RNG/ALPN) leak for every force-closed idle connection')
		exit(1)
	}
	eprintln('OK: worker relinquishes socket ownership (owns_socket = false) on force-close and still calls conn.shutdown() for TLS cleanup')
}

fn read_trimmed(path string) []string {
	return (os.read_lines(path) or { []string{} }).map(it.trim_right('\r'))
}

// has_in_order mirrors a grep pattern `a.*b.*c` on one line.
fn has_in_order(l string, parts []string) bool {
	mut pos := 0
	for p in parts {
		i := l[pos..].index(p) or { return false }
		pos += i + p.len
	}
	return true
}

// capture_braced mirrors the awk brace-depth capture: every line matching `start`
// (re)starts capture; the capture ends when the depth returns to zero on a `}`.
fn capture_braced(lines []string, start fn (string) bool) []string {
	mut res := []string{}
	mut in_fn := false
	mut depth := 0
	for l in lines {
		if start(l) {
			in_fn = true
			depth = 0
		}
		if in_fn {
			res << l
			for c in l {
				if c == `{` {
					depth++
				} else if c == `}` {
					depth--
					if depth == 0 {
						in_fn = false
						break
					}
				}
			}
		}
	}
	return res
}

fn skip_ws(l string, p int) int {
	mut i := p
	for i < l.len && (l[i] == ` ` || l[i] == `\t`) {
		i++
	}
	return i
}

// has_owns_socket_false mirrors `owns_socket[[:space:]]*=[[:space:]]*false`.
fn has_owns_socket_false(l string) bool {
	mut off := 0
	for {
		i := l[off..].index('owns_socket') or { return false }
		mut p := skip_ws(l, off + i + 'owns_socket'.len)
		if p < l.len && l[p] == `=` {
			p = skip_ws(l, p + 1)
			if l[p..].starts_with('false') {
				return true
			}
		}
		off += i + 1
	}
	return false
}

// gate_end returns the index just after `if<ws>*!...was_force_closed`, or -1.
fn gate_end(l string) int {
	mut off := 0
	for {
		i := l[off..].index('if') or { return -1 }
		p := skip_ws(l, off + i + 2)
		if p < l.len && l[p] == `!` {
			j := l[p + 1..].index('was_force_closed') or { return -1 }
			return p + 1 + j + 'was_force_closed'.len
		}
		off += i + 1
	}
	return -1
}

fn has_gate(l string) bool {
	return gate_end(l) >= 0
}

// has_gate_with_brace mirrors `if[[:space:]]*!.*was_force_closed.*\{`.
fn has_gate_with_brace(l string) bool {
	mut off := 0
	for {
		i := l[off..].index('if') or { return false }
		p := skip_ws(l, off + i + 2)
		if p < l.len && l[p] == `!` {
			j := l[p + 1..].index('was_force_closed') or { return false }
			if l[p + 1 + j + 'was_force_closed'.len..].contains('{') {
				return true
			}
		}
		off += i + 1
	}
	return false
}
