// detect_hpack_decode_scope — V port of skills/code-review/detect_hpack_decode_scope.sh.
//
// An HPACK decode failure must be a CONNECTION error (GOAWAY COMPRESSION_ERROR,
// RFC 9113 4.3), never a per-stream RST_STREAM. For each line matching
//   \.decode\(.*\)[[:space:]]*or[[:space:]]*\{
// the 7 lines starting at the hit are inspected: `send_rst_stream` -> BUG,
// else `compression_error` -> OK, else REVIEW.
//
// Usage: detect_hpack_decode_scope <file> [base_copy_or_empty] [file...]
//   The second argument is never scanned; further arguments are extra files.
// Exit: 1 = per-stream RST found on a decode failure, 0 = otherwise, 2 = usage error.
module main

import os

fn is_ws(c u8) bool {
	return c == ` ` || (c >= 9 && c <= 13)
}

// is_decode_or: \.decode\(.*\)\s*or\s*\{
fn is_decode_or(l string) bool {
	mut start := 0
	for {
		idx := l.index_after('.decode(', start) or { return false }
		start = idx + 1
		for j := idx + '.decode('.len; j < l.len; j++ {
			if l[j] != `)` {
				continue
			}
			mut p := j + 1
			for p < l.len && is_ws(l[p]) {
				p++
			}
			if !l[p..].starts_with('or') {
				continue
			}
			p += 2
			for p < l.len && is_ws(l[p]) {
				p++
			}
			if p < l.len && l[p] == `{` {
				return true
			}
		}
	}
	return false
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_hpack_decode_scope <file> [base_copy_or_empty] [file...]')
		exit(2)
	}
	mut files := [os.args[1]]
	if os.args.len > 3 {
		files << os.args[3..]
	}
	mut found := false
	for f in files {
		println('=== hpack-decode-scope: ${f} ===')
		mut any := false
		raw_lines := os.read_lines(f) or { []string{} }
		lines := raw_lines.map(it.trim_right('\r'))
		for i, l in lines {
			if !is_decode_or(l) {
				continue
			}
			ln := i + 1
			hi := if i + 7 > lines.len { lines.len } else { i + 7 }
			blk := lines[i..hi].join('\n')
			if blk.contains('send_rst_stream') {
				println('  line ${ln}: BUG — decode() failure handled with send_rst_stream (per-stream)')
				println('    -> must be send_goaway(.compression_error) + return (connection error, RFC 9113 §4.3)')
				any = true
				found = true
			} else if blk.contains('compression_error') {
				println('  line ${ln}: OK — decode() failure -> connection COMPRESSION_ERROR')
			} else {
				println('  line ${ln}: REVIEW — decode() failure handler unclear; confirm it closes the connection')
			}
		}
		if !any {
			println('  clean — every decode() failure is connection-scoped')
		}
		println('')
	}
	if found {
		println('RESULT: HPACK decode failure handled per-stream — must be a connection COMPRESSION_ERROR.')
		exit(1)
	}
	println('RESULT: all HPACK decode failures are connection-scoped.')
}
