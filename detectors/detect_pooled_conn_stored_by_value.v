// detect_pooled_conn_stored_by_value -- V port of
// skills/code-review/detect_pooled_conn_stored_by_value.sh.
//
// Contract: flag every line that is exactly `<ident> <ssl|mbedtls|openssl>.SSLConn`
// (optional surrounding blanks, nothing else): a struct field holding a dialed TLS
// connection by value instead of by pointer. Prints each hit as
// `  <file>:<line>:<raw line>`.
//
// Usage: detect_pooled_conn_stored_by_value <file> [base_copy_or_empty]  ($2 is never scanned)
// Exit: 1 flagged, 0 clean, 2 unreadable (or empty) file.
module main

import os

const conn_types = ['ssl.SSLConn', 'mbedtls.SSLConn', 'openssl.SSLConn']

fn is_by_value_field(line string) bool {
	f := line.fields()
	if f.len != 2 {
		return false
	}
	id := f[0]
	if id.len == 0 || !(id[0].is_letter() || id[0] == `_`) {
		return false
	}
	for c in id {
		if !(c.is_letter() || c.is_digit() || c == `_`) {
			return false
		}
	}
	return f[1] in conn_types
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_pooled_conn_stored_by_value <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or { '' }
	if content.trim_right('\n') == '' {
		eprintln('detect_pooled_conn_stored_by_value: could not read ${file}')
		exit(2)
	}
	lines := content.trim_right('\n').split('\n').map(it.trim_right('\r'))
	mut hits := []string{}
	for i, l in lines {
		if is_by_value_field(l) {
			hits << '  ${file}:${i + 1}:${l}'
		}
	}
	if hits.len > 0 {
		println('BUG: connection field stored by VALUE, not pointer (self-referential TLS context will point at the wrong object after a copy):')
		for h in hits {
			println(h)
		}
		exit(1)
	}
	println('OK: no by-value SSLConn/mbedtls.SSLConn/openssl.SSLConn struct fields found in ${file}')
}
