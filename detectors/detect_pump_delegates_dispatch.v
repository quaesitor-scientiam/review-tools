// detect_pump_delegates_dispatch — V port of
// skills/code-review/detect_pump_delegates_dispatch.sh.
//
// pump_for_window (the flow-control stall frame reader) must delegate to
// dispatch_frame rather than hand-pick frame types. Flags a pump_for_window body
// that mentions read_frame but not dispatch_frame.
//
// Usage: detect_pump_delegates_dispatch <file> [base_copy_or_empty]   ($2 never scanned)
// Exit: 1 flagged; 0 OK or no pump_for_window in the file; 2 unreadable/empty file
//       or missing argument.
// Quirks preserved: the body starts at any line containing `fn` ... `pump_for_window`
// and ends at the next line starting with `}` in column 0; matches (re)start grabbing.
module main

import os

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_pump_delegates_dispatch.sh <file> [commit]')
		exit(2)
	}
	file := os.args[1]
	raw := os.read_file(file) or { '' }
	if raw.trim_right('\n') == '' {
		eprintln('detect_pump_delegates_dispatch: cannot read ${file}')
		exit(2)
	}
	lines := raw.split_into_lines().map(it.trim_right('\r'))

	mut body := []string{}
	mut grab := false
	for l in lines {
		if has_fn_then(l, 'pump_for_window') {
			grab = true
		}
		if grab {
			body << l
		}
		if grab && l.starts_with('}') {
			grab = false
		}
	}
	if body.len == 0 {
		println('detect_pump_delegates_dispatch: no pump_for_window in ${file} — nothing to check')
		exit(0)
	}
	if body.any(it.contains('read_frame')) && !body.any(it.contains('dispatch_frame')) {
		println('FLAG: pump_for_window reads frames but does not delegate to dispatch_frame.')
		println('  A response stalled on flow control reads frames here; handling only a')
		println('  subset (control + RST) drops HEADERS/DATA/CONTINUATION — HPACK desync and')
		println('  missed RFC 9113 §5.1/§5.1.2 handling. Route through dispatch_frame.')
		println('  File: ${file}')
		exit(1)
	}
	println('OK: pump_for_window delegates to dispatch_frame (${file})')
}

// has_fn_then mirrors the awk pattern `/fn .*name/`.
fn has_fn_then(l string, name string) bool {
	i := l.index('fn ') or { return false }
	return l[i + 3..].contains(name)
}
