// detect_orphan_continuation_gate — V port of
// skills/code-review/detect_orphan_continuation_gate.sh.
//
// dispatch_frame must reject a CONTINUATION frame when no header sequence is in
// progress: after an `if c.awaiting_cont != 0 {` guard line there must be an
// `else if frame is H2ContinuationFrame` arm before the `\tmatch frame {` line
// (RFC 9113 §6.10).
//
// Usage: detect_orphan_continuation_gate   (no arguments; the path is hardcoded)
// Exit: 0 when the arm is present (or the file is missing: SKIP on stderr),
//       1 when it is absent. OK/BUG lines go to stdout.
// Quirk preserved: the scan stops at the first line that starts with a TAB then
// `match frame {` once the guard line was seen (awk `exit` runs END with `found`).
module main

import os

const target_file = 'vlib/net/http/h2_server.v'

fn main() {
	if !os.is_file(target_file) {
		eprintln('SKIP: ${target_file} not found')
		exit(0)
	}
	lines := (os.read_lines(target_file) or { []string{} }).map(it.trim_right('\r'))
	mut in_guard := false
	mut found := false
	for l in lines {
		if l.contains('if c.awaiting_cont != 0 {') {
			in_guard = true
		}
		if in_guard && l.contains('else if frame is H2ContinuationFrame') {
			found = true
		}
		if in_guard && l.starts_with('\tmatch frame {') {
			break
		}
	}
	if found {
		println('OK: dispatch_frame rejects an orphan CONTINUATION when awaiting_cont == 0')
		exit(0)
	}
	println('BUG: dispatch_frame has no awaiting_cont==0 rejection for H2ContinuationFrame — an orphan CONTINUATION on a locally_reset stream id is silently decoded and discarded')
	exit(1)
}
