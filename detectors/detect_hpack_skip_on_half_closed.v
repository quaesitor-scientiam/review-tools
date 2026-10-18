// detect_hpack_skip_on_half_closed — V port of
// skills/code-review/detect_hpack_skip_on_half_closed.sh.
//
// on_headers must route a post-END_STREAM HEADERS block through the HPACK decoder
// before RST. The fix introduces an `over_end` field; its absence means the buggy
// RST-without-decode path is still present.
//
// Usage: detect_hpack_skip_on_half_closed   (no arguments; the path is hardcoded)
// Exit: 0 when `over_end` appears in vlib/net/http/h2_server.v (or the file is
//       missing: SKIP on stderr), 1 when it is absent. OK/BUG lines go to stdout.
module main

import os

const target_file = 'vlib/net/http/h2_server.v'

fn main() {
	if !os.is_file(target_file) {
		eprintln('SKIP: ${target_file} not found')
		exit(0)
	}
	content := os.read_file(target_file) or {
		eprintln('SKIP: ${target_file} not found')
		exit(0)
	}
	if content.contains('over_end') {
		println('OK: over_end present — post-END_STREAM HEADERS routed through decoder before RST')
		exit(0)
	}
	println('BUG: over_end absent — on_headers RSTs post-END_STREAM HEADERS without HPACK decode (dynamic table desyncs)')
	exit(1)
}
