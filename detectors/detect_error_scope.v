// detect_error_scope — V port of skills/code-review/detect_error_scope.sh.
//
// Flags `return error(` inside reader-thread functions of the multiplexed HTTP/2
// connection: such an error propagates to read_loop and tears down EVERY in-flight
// stream; per-stream faults must use reset_stream / cancel_stream instead.
//
// Heuristic (as in the shell version): for each `^\s*return\s+error\s*\(` line, scan
// backward at most 60 lines (hit line included) for the nearest line that starts with
// `fn (` (methods only); if that signature contains one of the reader-function names
// followed by optional blanks and `(`, the hit is a CANDIDATE.
//
// Quirk preserved: the shell prints the enclosing fn's line number zero-padded to six
// digits (it comes from `nl -nrz`), e.g. `enclosing fn (line 000003)`.
// Quirk preserved: names match as substrings (`read_frame` also matches `mux_read_frame`).
//
// Usage: detect_error_scope <file> [base_copy_or_empty] [file...]
//   The second argument is never scanned; further arguments are extra files.
// Exit: 1 = candidates found, 0 = none, 2 = usage error.
module main

import os

// on_data / on_headers have a `\b` in the shell list; it is implied by the required
// following blank-or-`(`, so plain names are equivalent.
const reader_fns = ['dispatch_frame', 'handle_control_frame', 'mux_read_frame', 'on_response_data',
	'on_response_headers', 'on_rst_stream', 'on_settings', 'on_ping', 'on_window_update', 'on_goaway',
	'on_push_promise', 'read_frame', 'read_loop', 'on_data', 'on_headers', 'on_continuation',
	'on_trailers', 'finalize_headers', 'finalize_trailers']

fn is_ws(c u8) bool {
	return c == ` ` || (c >= 9 && c <= 13)
}

// is_return_error: ^\s*return\s+error\s*\(
fn is_return_error(l string) bool {
	mut i := 0
	for i < l.len && is_ws(l[i]) {
		i++
	}
	if !l[i..].starts_with('return') {
		return false
	}
	i += 6
	j := i
	for i < l.len && is_ws(l[i]) {
		i++
	}
	if i == j || !l[i..].starts_with('error') {
		return false
	}
	i += 5
	for i < l.len && is_ws(l[i]) {
		i++
	}
	return i < l.len && l[i] == `(`
}

// is_reader_sig: ($READER_FNS)\s*\(
fn is_reader_sig(sig string) bool {
	for name in reader_fns {
		mut start := 0
		for {
			idx := sig.index_after(name, start) or { break }
			start = idx + 1
			mut p := idx + name.len
			for p < sig.len && is_ws(sig[p]) {
				p++
			}
			if p < sig.len && sig[p] == `(` {
				return true
			}
		}
	}
	return false
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_error_scope <file> [base_copy_or_empty] [file...]')
		exit(2)
	}
	mut files := [os.args[1]]
	if os.args.len > 3 {
		files << os.args[3..]
	}
	mut found := false
	for f in files {
		println('=== error-scope scan: ${f} ===')
		mut any := false
		raw_lines := os.read_lines(f) or { []string{} }
		lines := raw_lines.map(it.trim_right('\r'))
		for idx, l in lines {
			if !is_return_error(l) {
				continue
			}
			hit := idx + 1 // 1-based
			mut lo := hit - 60
			if lo < 1 {
				lo = 1
			}
			mut fn_sig := ''
			mut fn_line := 0
			for n := hit; n >= lo; n-- {
				content := lines[n - 1]
				if content.starts_with('fn (') {
					fn_sig = content.trim_left(' \t\n\v\f\r')
					fn_line = n
					break
				}
			}
			if fn_sig != '' && is_reader_sig(fn_sig) {
				println('  line ${hit}: CANDIDATE')
				println('    enclosing fn (line ${fn_line:06}): ${fn_sig}')
				println('    ${l.trim_left(' \t\n\v\f\r')}')
				println('    -> per-stream fault? use reset_stream/cancel_stream; connection-level fault? return error is correct')
				any = true
				found = true
			}
		}
		if !any {
			println('  clean — no return error in reader-thread functions')
		}
		println('')
	}
	if found {
		println('RESULT: review ERROR-SCOPE candidates — confirm each is a true connection-level fault.')
		exit(1)
	}
	println('RESULT: no error-scope candidates in reader-thread functions.')
}
