// detect_unbounded_accum — V port of skills/code-review/detect_unbounded_accum.sh.
//
// A peer can drive growth of any connection-level buffer/counter/map that the
// reader appends to, increments, or inserts into per incoming frame. Each such
// accumulator must have a bound: a size cap (a max-style identifier on the same
// line as the field) or active pruning (a `.delete(` call for that field
// elsewhere in the file). ENUMERATE-AND-VERIFY aid: a field that shows NO CAP is
// a candidate for a human decision, not automatically a bug.
//
// Scans every `mut <name> <Type>` receiver the file declares (not a hardcoded
// `c`), and matches `<recv>.<field> <<`, `++`, `+=` and `<recv>.<field>[...] =`.
// Known gap (same as the shell version): a map-VALUE increment (`m[k] += 1`)
// matches neither pattern.
//
// Usage: detect_unbounded_accum <file> [base_copy_or_empty]
// Exit: 1 if any accumulator has no cap/prune, 0 otherwise, 2 if unreadable.
module main

import os

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_unbounded_accum <file> [base_copy_or_empty]')
		exit(2)
	}
	file := os.args[1]
	raw_lines := os.read_lines(file) or { exit(2) }
	lines := raw_lines.map(it.trim_right('\r'))
	println('=== unbounded-accumulation detector: ${file} ===')

	recvs := receivers(lines)
	if recvs.len == 0 {
		println('RESULT: no mut-receiver methods found -- nothing to scan.')
		exit(0)
	}
	mut fields := growth_fields(lines, recvs)
	fields.sort()

	mut need := false
	for f in fields {
		if capped_by_max(lines, f) {
			println('  ${f}: CAPPED (max-style bound co-occurs)')
		} else if lines.any(it.contains('.${f}.delete(')) {
			println('  ${f}: CAPPED (pruned via .delete() elsewhere in file)')
		} else {
			println('  ${f}: NO CAP FOUND — verify it is bounded by an admission limit / protocol, else it is peer-unbounded')
			need = true
		}
	}
	if need {
		println('RESULT: review the NO-CAP accumulators above.')
		exit(1)
	}
	println('RESULT: every accumulator co-occurs with a max-style cap or a .delete() prune.')
}

fn is_ident_start(c u8) bool {
	return c.is_letter() || c == `_`
}

fn is_ident_char(c u8) bool {
	return c.is_alnum() || c == `_`
}

// is_lower_ident_char matches the shell pattern [a-z_] used for field names.
fn is_lower_ident_char(c u8) bool {
	return (c >= `a` && c <= `z`) || c == `_`
}

// receivers lists every distinct name in `fn (mut <name> ` across the file.
fn receivers(lines []string) []string {
	mut seen := map[string]bool{}
	for l in lines {
		mut rest := l
		for {
			i := rest.index('fn (mut ') or { break }
			mut j := i + 'fn (mut '.len
			start := j
			if j < rest.len && is_ident_start(rest[j]) {
				j++
				for j < rest.len && is_ident_char(rest[j]) {
					j++
				}
				if j < rest.len && rest[j] == ` ` {
					seen[rest[start..j]] = true
				}
			}
			rest = rest[start..]
		}
	}
	return seen.keys()
}

// growth_fields lists every field grown on one of the receivers: `<recv>.<f>`
// followed by an optional space and `<<`, `++` or `+=`, or by `[...]`, an
// optional space, and a single `=` (map-key assignment).
fn growth_fields(lines []string, recvs []string) []string {
	mut seen := map[string]bool{}
	for l in lines {
		for r in recvs {
			needle := '${r}.'
			mut rest := l
			for {
				i := rest.index(needle) or { break }
				mut j := i + needle.len
				start := j
				for j < rest.len && is_lower_ident_char(rest[j]) {
					j++
				}
				if j > start {
					field := rest[start..j]
					mut k := j
					if k < rest.len && rest[k] == `[` {
						// map-key assignment: `[...]` with no `]` inside, then ` ?=` not `==`
						close := rest[k..].index(']') or { -1 }
						if close > 0 {
							mut m := k + close + 1
							if m < rest.len && rest[m] == ` ` {
								m++
							}
							if m + 1 < rest.len && rest[m] == `=` && rest[m + 1] != `=` {
								seen[field] = true
							}
						}
					} else {
						if k < rest.len && rest[k] == ` ` {
							k++
						}
						if k + 1 < rest.len {
							op := rest[k..k + 2]
							if op == '<<' || op == '++' || op == '+=' {
								seen[field] = true
							}
						}
					}
				}
				rest = rest[start..]
			}
		}
	}
	return seen.keys()
}

// capped_by_max mirrors the shell regex `f\b.*\b[a-z0-9_]*max[a-z0-9_]*\b` (and
// its mirror image): some line contains the field name ending at a word
// boundary and, in a different span, a lowercase word containing `max`.
fn capped_by_max(lines []string, f string) bool {
	for l in lines {
		f_ends := field_end_positions(l, f)
		if f_ends.len == 0 {
			continue
		}
		for span in max_word_spans(l) {
			for fe in f_ends {
				f_start := fe - f.len
				if f_start != span[0] || fe != span[1] {
					return true
				}
			}
		}
	}
	return false
}

// field_end_positions returns the end index of each occurrence of `f` that is
// followed by a non-word character or the end of the line (`f\b`).
fn field_end_positions(l string, f string) []int {
	mut res := []int{}
	mut rest := l
	mut off := 0
	for {
		i := rest.index(f) or { break }
		end := off + i + f.len
		if end >= l.len || !is_ident_char(l[end]) {
			res << end
		}
		rest = rest[i + 1..]
		off += i + 1
	}
	return res
}

// max_word_spans returns [start, end) of every maximal word-character run that
// consists only of [a-z0-9_] and contains `max`.
fn max_word_spans(l string) [][]int {
	mut res := [][]int{}
	mut i := 0
	for i < l.len {
		if !is_ident_char(l[i]) {
			i++
			continue
		}
		start := i
		for i < l.len && is_ident_char(l[i]) {
			i++
		}
		word := l[start..i]
		mut lower_only := true
		for c in word {
			if c.is_letter() && !(c >= `a` && c <= `z`) {
				lower_only = false
				break
			}
		}
		if lower_only && word.contains('max') {
			res << [start, i]
		}
	}
	return res
}
