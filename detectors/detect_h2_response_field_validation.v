// detect_h2_response_field_validation — V port of
// skills/code-review/detect_h2_response_field_validation.sh.
//
// Both HTTP/2 client paths (mux and sync) must validate received response/trailer
// field names with h2_response_field_error(f.name): at least two call-site lines
// per file (response path + trailer path), RFC 9113 §8.2.
//
// Usage: detect_h2_response_field_validation [mux_file] [base_copy_or_empty]
//   mux_file defaults to vlib/net/http/h2_mux_conn.v. The sync sibling is
//   <dir of mux_file>/h2_conn.v unless $2 itself ends in h2_conn.v (explicit form).
// Exit 1 if either file has fewer than two call-site lines; a missing file is a
// SKIP (stderr) for that file only. Diagnostics go to stderr like the .sh.
module main

import os

fn main() {
	mux := if os.args.len > 1 { os.args[1] } else { 'vlib/net/http/h2_mux_conn.v' }
	mut sync := '${shell_dirname(mux)}/h2_conn.v'
	if os.args.len > 2 && os.args[2].ends_with('h2_conn.v') {
		sync = os.args[2]
	}
	mut fail := false
	for f in [mux, sync] {
		if !os.is_file(f) {
			eprintln('SKIP: ${f} not found')
			continue
		}
		lines := os.read_lines(f) or { []string{} }
		calls := lines.filter(it.contains('h2_response_field_error(f.name)')).len
		if calls < 2 {
			eprintln('BUG: ${f} validates < 2 received header blocks (response + trailers) for malformed')
			eprintln('  field names (RFC 9113 §8.2): found ${calls} h2_response_field_error(f.name) call(s).')
			fail = true
		} else {
			eprintln('OK: ${f} rejects malformed received response/trailer field names (${calls} call sites)')
		}
	}
	if fail {
		exit(1)
	}
}

// shell_dirname mimics dirname(1) for the simple cases used here.
fn shell_dirname(p string) string {
	i := p.last_index('/') or { return '.' }
	if i == 0 {
		return '/'
	}
	return p[..i]
}
