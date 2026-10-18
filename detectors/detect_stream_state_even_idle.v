// detect_stream_state_even_idle — V port of
// skills/code-review/detect_stream_state_even_idle.sh.
//
// A classify_stream function that returns `.closed` / `closed` must also test the
// stream id's parity (`& 1`): only an ODD id can be a closed client stream; a
// never-opened EVEN id is IDLE (RFC 9113 §5.1).
//
// Usage: detect_stream_state_even_idle <file> [base_copy_or_empty]   ($2 never scanned)
// Exit: 1 flagged; 0 OK or no classify_stream in the file; 2 unreadable/empty file
//       or missing argument.
// Quirks preserved: the body starts at any line containing `fn` ... `classify_stream`
// and ends at the next line starting with `}` in column 0; matches (re)start grabbing.
module main

import os

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_stream_state_even_idle.sh <file> [commit]')
		exit(2)
	}
	file := os.args[1]
	raw := os.read_file(file) or { '' }
	if raw.trim_right('\n') == '' {
		eprintln('detect_stream_state_even_idle: cannot read ${file}')
		exit(2)
	}
	lines := raw.split_into_lines().map(it.trim_right('\r'))

	mut body := []string{}
	mut grab := false
	for l in lines {
		if has_fn_then(l, 'classify_stream') {
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
		println('detect_stream_state_even_idle: no classify_stream in ${file} — nothing to check')
		exit(0)
	}
	if body.any(returns_closed(it)) && !body.any(has_amp_one(it)) {
		println('FLAG: classify_stream returns .closed with no odd-id (`& 1`) parity guard.')
		println('  A never-opened EVEN (server-initiated) id is IDLE, not closed; a frame on')
		println('  it must be a connection PROTOCOL_ERROR (RFC 9113 §5.1), not STREAM_CLOSED.')
		println('  File: ${file}')
		exit(1)
	}
	println("OK: classify_stream gates 'closed' on stream-id parity (${file})")
}

// has_fn_then mirrors the awk pattern `/fn .*name/`.
fn has_fn_then(l string, name string) bool {
	i := l.index('fn ') or { return false }
	return l[i + 3..].contains(name)
}

// returns_closed mirrors grep -E `return[[:space:]]+\.?closed`.
fn returns_closed(l string) bool {
	mut off := 0
	for {
		i := l[off..].index('return') or { return false }
		mut p := off + i + 'return'.len
		start := p
		for p < l.len && (l[p] == ` ` || l[p] == `\t`) {
			p++
		}
		if p > start {
			mut rest := l[p..]
			if rest.starts_with('.') {
				rest = rest[1..]
			}
			if rest.starts_with('closed') {
				return true
			}
		}
		off += i + 1
	}
	return false
}

// has_amp_one mirrors grep -E `&[[:space:]]*1`.
fn has_amp_one(l string) bool {
	for i, c in l {
		if c != `&` {
			continue
		}
		mut p := i + 1
		for p < l.len && (l[p] == ` ` || l[p] == `\t`) {
			p++
		}
		if p < l.len && l[p] == `1` {
			return true
		}
	}
	return false
}
