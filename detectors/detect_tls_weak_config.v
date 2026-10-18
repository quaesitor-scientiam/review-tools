// detect_tls_weak_config — V port of skills/code-review/detect_tls_weak_config.sh.
//
// Exits 1 if a TLS-touching file (mentions ssl|tls|mbedtls|SslConfig, case-sensitive)
// creates an SslConfig (`SslConfig{` or `ssl_config\s*=`) while the string
// `min_version` appears nowhere in the file. Lists the creating lines (grep -n style).
//
// Usage: detect_tls_weak_config <file> [base_copy_or_empty] [more files...]
//   The second argument is never scanned; further arguments are extra files.
//   Empty / non-existent arguments are skipped.
// Exit: 1 = weak config found, 0 = none, 2 = usage error.
module main

import os

fn is_ws(c u8) bool {
	return c == ` ` || (c >= 9 && c <= 13)
}

// creates_config: `SslConfig\{|ssl_config\s*=`
fn creates_config(l string) bool {
	if l.contains('SslConfig{') {
		return true
	}
	mut start := 0
	for {
		idx := l.index_after('ssl_config', start) or { return false }
		start = idx + 1
		mut p := idx + 'ssl_config'.len
		for p < l.len && is_ws(l[p]) {
			p++
		}
		if p < l.len && l[p] == `=` {
			return true
		}
	}
	return false
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_tls_weak_config <file> [base_copy_or_empty] [file...]')
		exit(2)
	}
	mut files := [os.args[1]]
	if os.args.len > 3 {
		files << os.args[3..]
	}
	mut found := false
	for f in files {
		if f == '' || !os.is_file(f) {
			continue
		}
		content := os.read_file(f) or { continue }
		// ssl|tls|mbedtls|SslConfig: the last two contain `tls` / `Ssl` respectively,
		// but `SslConfig` has capital S, so it must stay a separate alternative.
		if !(content.contains('ssl') || content.contains('tls') || content.contains('SslConfig')) {
			continue
		}
		lines := content.split('\n')
		mut hits := []string{}
		for i, raw in lines {
			l := raw.trim_right('\r')
			if creates_config(l) {
				hits << '  ${i + 1}:${l}'
			}
		}
		if hits.len > 0 && !content.contains('min_version') {
			println('TLS_WEAK_CONFIG: ${f}: SslConfig created with no min_version in file')
			for h in hits {
				println(h)
			}
			found = true
		}
	}
	if found {
		exit(1)
	}
}
