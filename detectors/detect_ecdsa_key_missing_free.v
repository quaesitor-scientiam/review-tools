// detect_ecdsa_key_missing_free -- V port of skills/code-review/detect_ecdsa_key_missing_free.sh.
//
// Contract: every line (without `//`) calling an ecdsa key constructor
// (.PrivateKey.new( / .public_key( / .generate_key( / .from_uncompressed_bytes()
// is expected to be a declaration `a := ...` / `a, b := ...` (optional `mut`).
// Each declared identifier must have `<ident>.free()` somewhere in the SAME FILE
// (whole-file heuristic, word boundary before the identifier). A `_` target is
// reported DISCARDED, an identifier with no free is LEAKED, a constructor line
// whose left-hand side cannot be parsed is reported and does not fail the run.
// Known gap (kept): keys threaded through struct fields/returns are not traced.
//
// Usage: detect_ecdsa_key_missing_free <file> [base_copy_or_empty]  ($2 is never scanned)
// Exit: 1 if any DISCARDED/LEAKED key, 0 otherwise, 2 if the file is unreadable.
module main

import os

const ctor_markers = ['.PrivateKey.new(', '.public_key(', '.generate_key(', '.from_uncompressed_bytes(']

fn is_ws(c u8) bool {
	return c == ` ` || c == `\t` || c == `\v` || c == `\f` || c == `\r`
}

fn is_word(c u8) bool {
	return c.is_letter() || c.is_digit() || c == `_`
}

// strip_mut removes one leading `mut` followed by whitespace, after left-trimming.
fn strip_mut(raw string) string {
	v := raw.trim_left(' \t\v\f\r')
	if v.len > 3 && v.starts_with('mut') && is_ws(v[3]) {
		return v[3..].trim_left(' \t\v\f\r')
	}
	return v
}

fn ident_ok(s string) bool {
	return s.len > 0 && (s[0].is_letter() || s[0] == `_`)
}

// extract_vars mirrors the sed LHS extraction: `[mut] id[, [mut] id]... :=`.
fn extract_vars(rest string) ?[]string {
	idx := rest.index(':=') or { return none }
	prefix := rest[..idx]
	for c in prefix {
		if !(is_word(c) || c == ` ` || c == `\t` || c == `,`) {
			return none
		}
	}
	mut vars := []string{}
	for part in prefix.split(',') {
		stripped := strip_mut(part)
		if !ident_ok(stripped) && !ident_ok(part.trim_left(' \t\v\f\r')) {
			return none
		}
		v := stripped.trim_right(' \t\v\f\r')
		if v.len > 0 {
			vars << v
		}
	}
	return vars
}

// has_free reports whether `<v>.free()` occurs with a word boundary before <v>.
fn has_free(lines []string, v string) bool {
	needle := v + '.free()'
	for l in lines {
		mut from := 0
		for {
			i := l.index_after(needle, from) or { break }
			if i == 0 || !is_word(l[i - 1]) {
				return true
			}
			from = i + 1
		}
	}
	return false
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_ecdsa_key_missing_free <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	content := os.read_file(file) or {
		println('cannot read ${file}')
		exit(2)
	}
	lines := content.split('\n').map(it.trim_right('\r'))
	println('=== ecdsa key missing-free detector: ${file} ===')
	mut found := false
	for i, l in lines {
		if l.contains('//') || !ctor_markers.any(l.contains(it)) {
			continue
		}
		ln := i + 1
		vars := extract_vars(l) or {
			println('  line ${ln}: could not extract variable name -> ${l.trim_left(' \t\v\f')}')
			continue
		}
		for v in vars {
			if v == '_' {
				println('  line ${ln}: DISCARDED -> _ (constructor result discarded at its own call site)')
				found = true
				continue
			}
			if has_free(lines, v) {
				println('  line ${ln}: FREED     -> ${v}')
			} else {
				println('  line ${ln}: LEAKED    -> ${v} (no `${v}.free()` anywhere in file)')
				found = true
			}
		}
	}
	if found {
		println('RESULT: ecdsa key(s) created with no matching .free() -- resource leak.')
		exit(1)
	}
	println('RESULT: every ecdsa key in this file has a matching .free().')
}
