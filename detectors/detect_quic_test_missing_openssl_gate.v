// detect_quic_test_missing_openssl_gate — V port of
// skills/code-review/detect_quic_test_missing_openssl_gate.sh.
//
// Every vlib/net/quic/*_test.v must either carry `// vtest build: present_openssl?`
// as its FIRST line, or be listed in cmd/tools/vtest-self.v's musl skip list
// (an entry containing `'<file>',`). Otherwise docker-ubuntu-musl CI fails to compile it.
//
// Files outside vlib/net/quic/*_test.v are a no-op pass. The skip list is read
// relative to the CURRENT DIRECTORY (run_detectors.sh cd's to the repo root).
//
// Usage: detect_quic_test_missing_openssl_gate <file> [base_copy_or_empty]
//   The second argument is accepted and never scanned.
// Exit: 1 = quic test file with neither the gate nor a skip-list entry; 0 otherwise;
//   2 = usage error.
module main

import os

const gate_line = '// vtest build: present_openssl?'
const skip_list = 'cmd/tools/vtest-self.v'

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_quic_test_missing_openssl_gate <file> [gitrev]')
		exit(2)
	}
	file := os.args[1]
	// Shell glob `vlib/net/quic/*_test.v` (`*` also matches `/`).
	if !(file.starts_with('vlib/net/quic/') && file.ends_with('_test.v')) {
		println('=== quic openssl-gate detector: ${file} (not a vlib/net/quic/*_test.v file, skipping) ===')
		exit(0)
	}
	println('=== quic openssl-gate detector: ${file} ===')
	content := os.read_file(file) or { '' }
	mut first_line := ''
	if content.len > 0 {
		first_line = content.all_before('\n').trim_right('\r')
	}
	if first_line == gate_line {
		println("  RESULT: gated via '// vtest build: present_openssl?' (line 1).")
		exit(0)
	}
	skips := os.read_file(skip_list) or { '' }
	if skips.contains("'${file}',") {
		println("  RESULT: not gated, but listed in cmd/tools/vtest-self.v's musl skip list.")
		exit(0)
	}
	println("  MISSING: no '// vtest build: present_openssl?' gate as line 1, and not")
	println("           present in cmd/tools/vtest-self.v's musl skip list.")
	println("  FIX: add '// vtest build: present_openssl?' as this file's first line")
	println("       (before 'module quic').")
	println('RESULT: net.quic test file will hard-fail docker-ubuntu-musl CI.')
	exit(1)
}
