// detect_struct_wrapped_resource_leak — V port of
// skills/code-review/detect_struct_wrapped_resource_leak.sh.
//
// One-hop struct-wrapped resource leak check. For every struct field whose type matches
// the resource regex (default `ecdsa\.(PrivateKey|PublicKey)`):
//   1. take the enclosing struct (the last `struct Name {` header at or above the field),
//   2. find every fn whose parenthesised return tuple mentions that struct and note the
//      tuple position,
//   3. for every call site `fn_name(` (same file; or the callers graphify reports when
//      GRAPHIFY_EXE and GRAPHIFY_GRAPH are set) whose `:=` LHS binds that position to
//      `_` (DISCARDED) or to a name without a matching `<name>.<field>.free()` anywhere
//      in the scanned file (LEAKED), report it.
//
// Usage: detect_struct_wrapped_resource_leak <file> [resource_type_regex] [gitrev]
//   NOTE (inherited from the .sh): the SECOND argument is the resource regex, not a base
//   copy. run_detectors.sh passes a base-copy path there, which silently becomes the
//   regex and makes the detector vacuous through the runner; the port keeps that contract.
//   An empty second argument selects the default regex; a regex that does not compile
//   matches nothing (grep -E would error out and yield no hits either).
//
// Graphify integration IS ported: with GRAPHIFY_EXE and GRAPHIFY_GRAPH set it runs
// `<exe> explain <fn> --graph <graph>`, parses the `called by` lines for `(path:line)`
// entries and scans those files under GRAPHIFY_REPO_ROOT (default: current directory).
//
// Regex notes: the field line is matched as ident, blanks, <regex>, blanks. V's `regex`
// module returned no match for nested groups like the default pattern on this compiler
// (`(a\.(B|C))` never matched), so the port carries a tiny ERE-subset matcher instead:
// literals, `\x` escapes (\s \w \d classes), `.`, `[...]` classes (ranges, ^), `(...)`
// groups, `|`, and the `* + ?` quantifiers. Anything outside that subset (e.g. `{n,m}`,
// anchors, back-references) is treated as literal text; the match must cover the whole
// remainder of the line (the .sh pastes the regex raw between `\s+` and `\s*$`).
//
// Exit: 1 = a call site discards or never frees the wrapped resource, 0 = otherwise,
// 2 = unreadable file / usage error.
module main

import os

const default_re = r'ecdsa\.(PrivateKey|PublicKey)'

fn is_ws(c u8) bool {
	return c == ` ` || (c >= 9 && c <= 13)
}

fn is_word(c u8) bool {
	return c == `_` || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
}

fn is_ident_start(c u8) bool {
	return c == `_` || (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
}

fn skip_ws(s string, from int) int {
	mut i := from
	for i < s.len && is_ws(s[i]) {
		i++
	}
	return i
}

fn skip_word(s string, from int) int {
	mut i := from
	for i < s.len && is_word(s[i]) {
		i++
	}
	return i
}

// field_decl parses `^\sps.ident\s+<resource>\s*$` and returns the field name.
fn field_decl(l string, re [][]Node) ?string {
	mut i := skip_ws(l, 0)
	if i >= l.len || !is_ident_start(l[i]) {
		return none
	}
	e := skip_word(l, i)
	name := l[i..e]
	i = skip_ws(l, e)
	if i == e {
		return none
	}
	rest := l[i..].trim_right(' \t\n\v\f\r')
	if rest == '' {
		return none
	}
	if match_alts(re, rest, 0, fn [rest] (e int) bool {
		return e == rest.len
	})
	{
		return name
	}
	return none
}

// Node is one element of the ERE-subset AST: kind 0 literal byte, 1 any, 2 class,
// 3 group (alts); min/max are the quantifier bounds.
struct Node {
	kind  int
	ch    u8
	items []ClassItem
	neg   bool
	alts  [][]Node
	min   int
	max   int
}

struct ClassItem {
	lo u8
	hi u8
}

fn class_for_escape(c u8) ?([]ClassItem, bool) {
	match c {
		`s` {
			return [ClassItem{` `, ` `}, ClassItem{9, 13}], false
		}
		`S` {
			return [ClassItem{` `, ` `}, ClassItem{9, 13}], true
		}
		`w` {
			return [ClassItem{`a`, `z`}, ClassItem{`A`, `Z`}, ClassItem{`0`, `9`}, ClassItem{`_`, `_`}], false
		}
		`d` {
			return [ClassItem{`0`, `9`}], false
		}
		else {
			return none
		}
	}
}

struct Parser {
	p string
mut:
	i int
}

// parse_alts parses `seq ( '|' seq )*` until ')' or the end. ok=false on a syntax error.
fn (mut ps Parser) parse_alts(depth int) ([][]Node, bool) {
	mut alts := [][]Node{}
	mut seq := []Node{}
	for ps.i < ps.p.len {
		c := ps.p[ps.i]
		if c == `)` {
			if depth == 0 {
				return alts, false
			}
			break
		}
		if c == `|` {
			alts << seq
			seq = []Node{}
			ps.i++
			continue
		}
		mut n := Node{
			min: 1
			max: 1
		}
		if c == `(` {
			ps.i++
			sub, ok := ps.parse_alts(depth + 1)
			if !ok || ps.i >= ps.p.len || ps.p[ps.i] != `)` {
				return alts, false
			}
			ps.i++
			n = Node{
				kind: 3
				alts: sub
				min:  1
				max:  1
			}
		} else if c == `[` {
			ps.i++
			mut neg := false
			if ps.i < ps.p.len && ps.p[ps.i] == `^` {
				neg = true
				ps.i++
			}
			mut items := []ClassItem{}
			mut first := true
			for ps.i < ps.p.len && (ps.p[ps.i] != `]` || first) {
				first = false
				mut lo := ps.p[ps.i]
				ps.i++
				if lo == `\\` && ps.i < ps.p.len {
					lo = ps.p[ps.i]
					ps.i++
				}
				if ps.i + 1 < ps.p.len && ps.p[ps.i] == `-` && ps.p[ps.i + 1] != `]` {
					items << ClassItem{lo, ps.p[ps.i + 1]}
					ps.i += 2
				} else {
					items << ClassItem{lo, lo}
				}
			}
			if ps.i >= ps.p.len {
				return alts, false
			}
			ps.i++
			n = Node{
				kind:  2
				items: items
				neg:   neg
				min:   1
				max:   1
			}
		} else if c == `.` {
			ps.i++
			n = Node{
				kind: 1
				min:  1
				max:  1
			}
		} else if c == `\\` && ps.i + 1 < ps.p.len {
			e := ps.p[ps.i + 1]
			ps.i += 2
			if items, neg := class_for_escape(e) {
				n = Node{
					kind:  2
					items: items
					neg:   neg
					min:   1
					max:   1
				}
			} else {
				n = Node{
					ch:  e
					min: 1
					max: 1
				}
			}
		} else {
			ps.i++
			n = Node{
				ch:  c
				min: 1
				max: 1
			}
		}
		if ps.i < ps.p.len {
			q := ps.p[ps.i]
			if q == `*` {
				n = Node{
					...n
					min: 0
					max: 1000000
				}
				ps.i++
			} else if q == `+` {
				n = Node{
					...n
					max: 1000000
				}
				ps.i++
			} else if q == `?` {
				n = Node{
					...n
					min: 0
				}
				ps.i++
			}
		}
		seq << n
	}
	alts << seq
	return alts, true
}

fn parse_ere(src string) ?[][]Node {
	mut ps := Parser{
		p: src
	}
	alts, ok := ps.parse_alts(0)
	if !ok || ps.i != src.len {
		return none
	}
	return alts
}

fn match_one(n Node, s string, si int, k fn (int) bool) bool {
	match n.kind {
		0 {
			return si < s.len && s[si] == n.ch && k(si + 1)
		}
		1 {
			return si < s.len && k(si + 1)
		}
		2 {
			if si >= s.len {
				return false
			}
			mut hit := false
			for it in n.items {
				if s[si] >= it.lo && s[si] <= it.hi {
					hit = true
					break
				}
			}
			return hit != n.neg && k(si + 1)
		}
		else {
			return match_alts(n.alts, s, si, k)
		}
	}
}

fn match_rep(n Node, count int, s string, si int, k fn (int) bool) bool {
	if count < n.max {
		if match_one(n, s, si, fn [n, count, s, si, k] (e int) bool {
			if e == si && count >= n.min {
				return false
			}
			return match_rep(n, count + 1, s, e, k)
		})
		{
			return true
		}
	}
	return count >= n.min && k(si)
}

fn match_seq(seq []Node, ni int, s string, si int, k fn (int) bool) bool {
	if ni == seq.len {
		return k(si)
	}
	return match_rep(seq[ni], 0, s, si, fn [seq, ni, s, k] (e int) bool {
		return match_seq(seq, ni + 1, s, e, k)
	})
}

fn match_alts(alts [][]Node, s string, si int, k fn (int) bool) bool {
	for seq in alts {
		if match_seq(seq, 0, s, si, k) {
			return true
		}
	}
	return false
}

// struct_header returns the name of `^\s*(pub\s+)?(mut:\s*)?struct\s+Name\s*{`.
fn struct_header(l string) ?string {
	mut i := skip_ws(l, 0)
	if l[i..].starts_with('pub') {
		j := skip_ws(l, i + 3)
		if j > i + 3 {
			i = j
		}
	}
	if l[i..].starts_with('mut:') {
		i = skip_ws(l, i + 4)
	}
	if !l[i..].starts_with('struct') {
		return none
	}
	j := skip_ws(l, i + 6)
	if j == i + 6 || j >= l.len || !is_ident_start(l[j]) {
		return none
	}
	e := skip_word(l, j)
	k := skip_ws(l, e)
	if k < l.len && l[k] == `{` {
		return l[j..e]
	}
	return none
}

// fn_name parses `^\s*(pub\s+)?fn\s+(\([^)]*\)\s+)?ident(` and returns ident.
// ok is false when the line is not an fn line at all (the `fn\s` test).
fn fn_name(l string) (string, bool) {
	mut i := skip_ws(l, 0)
	if l[i..].starts_with('pub') {
		j := skip_ws(l, i + 3)
		if j > i + 3 {
			i = j
		}
	}
	if !l[i..].starts_with('fn') || i + 2 >= l.len || !is_ws(l[i + 2]) {
		return '', false
	}
	i = skip_ws(l, i + 2)
	if i < l.len && l[i] == `(` {
		close := l.index_after(')', i) or { return '', true }
		j := skip_ws(l, close + 1)
		if j == close + 1 {
			return '', true
		}
		i = j
	}
	if i >= l.len || !is_ident_start(l[i]) {
		return '', true
	}
	e := skip_word(l, i)
	if e < l.len && l[e] == `(` {
		return l[i..e], true
	}
	return '', true
}

// return_tuple extracts the capture of `.*\)\s*!?\(([^{]*)\)\s*\{?\s*$` (greedy `.*`).
fn return_tuple(l string) string {
	mut s := l.trim_right(' \t\n\v\f\r')
	if s.ends_with('{') {
		s = s[..s.len - 1].trim_right(' \t\n\v\f\r')
	}
	if !s.ends_with(')') {
		return ''
	}
	t := s[..s.len - 1]
	for k := t.len - 1; k >= 0; k-- {
		if t[k] != `(` {
			continue
		}
		if t[k + 1..].contains('{') {
			return ''
		}
		mut j := k - 1
		if j >= 0 && t[j] == `!` {
			j--
		}
		for j >= 0 && is_ws(t[j]) {
			j--
		}
		if j >= 0 && t[j] == `)` {
			return t[k + 1..]
		}
	}
	return ''
}

// has_word_bounded reports whether s contains name with \b on both sides.
fn has_word_bounded(s string, name string) bool {
	mut start := 0
	for {
		idx := s.index_after(name, start) or { return false }
		start = idx + 1
		if idx > 0 && is_word(s[idx - 1]) {
			continue
		}
		e := idx + name.len
		if e < s.len && is_word(s[e]) {
			continue
		}
		return true
	}
	return false
}

// call_sites returns (1-based line, line) for lines containing `\bname\(`.
fn call_sites(lines []string, name string) [][]string {
	mut out := [][]string{}
	needle := name + '('
	for i, l in lines {
		mut start := 0
		for {
			idx := l.index_after(needle, start) or { break }
			start = idx + 1
			if idx > 0 && is_word(l[idx - 1]) {
				continue
			}
			out << ['${i + 1}', l]
			break
		}
	}
	return out
}

// lhs_of parses the `:=` LHS the way the shell's sed does; '' when the line is not a
// definition with a plain-identifier LHS list.
fn lhs_of(l string) string {
	c := l.index(':') or { return '' }
	if c + 1 >= l.len || l[c + 1] != `=` {
		return ''
	}
	mut p := l[..c]
	mut i := skip_ws(p, 0)
	if p[i..].starts_with('mut') {
		j := skip_ws(p, i + 3)
		if j > i + 3 && j < p.len && is_ident_start(p[j]) {
			i = j
		}
	}
	p = p[i..]
	if p == '' {
		return ''
	}
	for n, part in p.split(',') {
		t := if n == 0 { part } else { part.trim_left(' \t\n\v\f\r') }
		if t == '' || !is_ident_start(t[0]) {
			return ''
		}
		for ch in t {
			if !is_word(ch) && !is_ws(ch) {
				return ''
			}
		}
	}
	return p
}

// strip_mut removes `^\s*(mut\s+)?` and trailing blanks.
fn strip_mut(raw string) string {
	mut s := raw.trim_left(' \t\n\v\f\r')
	if s.starts_with('mut') {
		j := skip_ws(s, 3)
		if j > 3 {
			s = s[j..]
		}
	}
	return s.trim_right(' \t\n\v\f\r')
}

// graphify_callers returns the sorted unique caller paths from `graphify explain`, or
// none when the tool printed no `called by` line.
fn graphify_callers(exe string, graph string, func_name string) ?[]string {
	res := os.exec([exe, 'explain', func_name, '--graph', graph])
	mut paths := map[string]bool{}
	mut seen_line := false
	for raw in res.output.split('\n') {
		l := raw.trim_right('\r')
		if !l.starts_with('called by') {
			continue
		}
		seen_line = true
		mut start := 0
		for {
			o := l.index_after('(', start) or { break }
			c := l.index_after(')', o + 1) or { break }
			inner := l[o + 1..c]
			start = c + 1
			if inner.contains('(') {
				continue
			}
			colon := inner.last_index(':') or { continue }
			num := inner[colon + 1..]
			if num.len == 0 || !num.bytes().all(it >= `0` && it <= `9`) {
				continue
			}
			paths[inner[..colon]] = true
		}
	}
	if !seen_line {
		return none
	}
	mut keys := paths.keys()
	keys.sort()
	return keys
}

fn main() {
	if os.args.len < 2 {
		eprintln('usage: detect_struct_wrapped_resource_leak <file> [resource_type_regex] [gitrev]')
		exit(2)
	}
	file := os.args[1]
	// $2 is a resource-type regex ONLY when it is not a path: run_detectors
	// passes the base-revision copy there, and the shell original silently used
	// that path as the regex and found nothing (see tests/DETECTOR_NOTES.md).
	resource_re := if os.args.len > 2 && os.args[2] != '' && !os.exists(os.args[2]) {
		os.args[2]
	} else {
		default_re
	}
	raw_lines := os.read_lines(file) or {
		println('cannot read ${file}')
		exit(2)
	}
	lines := raw_lines.map(it.trim_right('\r'))
	println('=== struct-wrapped resource leak detector: ${file} (resource: ${resource_re}) ===')
	graphify_exe := os.getenv('GRAPHIFY_EXE')
	graphify_graph := os.getenv('GRAPHIFY_GRAPH')
	mut repo_root := os.getenv('GRAPHIFY_REPO_ROOT')
	if repo_root == '' {
		repo_root = os.getwd()
	}
	mut re_ok := true
	re_opt := parse_ere(resource_re) or {
		re_ok = false
		[][]Node{}
	}
	mut found := false
	mut any_struct := false
	if re_ok {
		for fi, fl in lines {
			field_ln := fi + 1
			field_name := field_decl(fl, re_opt) or { continue }
			// Nearest struct header at or above the field (name is never reset).
			mut struct_name := ''
			for k := 0; k <= fi; k++ {
				if n := struct_header(lines[k]) {
					struct_name = n
				}
			}
			if struct_name == '' {
				continue
			}
			any_struct = true
			println('--- struct ${struct_name}.${field_name} (${resource_re}), declared line ${field_ln} ---')
			for si, sl in lines {
				sig_ln := si + 1
				func_name, is_fn := fn_name(sl)
				if !is_fn || func_name == '' {
					continue
				}
				ret_types := return_tuple(sl)
				if ret_types == '' {
					continue
				}
				mut parts := ret_types.split(',')
				if parts.len > 1 && parts.last() == '' {
					parts.delete_last()
				}
				mut struct_pos := 0
				for pi, part in parts {
					if has_word_bounded(part, struct_name) {
						struct_pos = pi + 1
					}
				}
				if struct_pos == 0 {
					continue
				}
				println('  fn ${func_name}(...) returns ${struct_name} at position ${struct_pos}/${parts.len}')

				mut scan_labels := [file]
				mut scan_lines := [lines]
				if graphify_exe != '' && graphify_graph != '' && repo_root != ''
					&& os.exists(graphify_exe) {
					if callers := graphify_callers(graphify_exe, graphify_graph, func_name) {
						scan_labels = []string{}
						scan_lines = [][]string{}
						for p in callers {
							abs := repo_root + '/' + p
							if !os.is_file(abs) {
								continue
							}
							content := os.read_lines(abs) or { continue }
							scan_labels << p
							scan_lines << content.map(it.trim_right('\r'))
						}
						println('  (graphify: ${scan_labels.len} caller file(s) across the codebase, not just ${file})')
					}
				}
				for idx, slines in scan_lines {
					label := scan_labels[idx]
					for site in call_sites(slines, func_name) {
						call_ln := site[0].int()
						call_rest := site[1]
						if label == file && call_ln == sig_ln {
							continue
						}
						if call_rest.trim_left(' \t\n\v\f\r').starts_with('//') {
							continue
						}
						lhs := lhs_of(call_rest)
						if lhs == '' {
							continue
						}
						lparts := lhs.split(',')
						if lparts.len < struct_pos {
							continue
						}
						v := strip_mut(lparts[struct_pos - 1])
						if v == '' {
							continue
						}
						if v == '_' {
							println('    ${label}:${call_ln}: DISCARDED -> _ (call to ${func_name} discards its ${struct_name} return, dropping .${field_name})')
							found = true
							continue
						}
						free_call := '${v}.${field_name}.free()'
						mut freed := false
						for sl2 in slines {
							mut s2 := 0
							for {
								j := sl2.index_after(free_call, s2) or { break }
								s2 = j + 1
								if j == 0 || !is_word(sl2[j - 1]) {
									freed = true
									break
								}
							}
							if freed {
								break
							}
						}
						if freed {
							println('    ${label}:${call_ln}: FREED     -> ${v}.${field_name}')
						} else {
							println('    ${label}:${call_ln}: LEAKED    -> ${v} (no `${v}.${field_name}.free()` anywhere in ${label})')
							found = true
						}
					}
				}
			}
		}
	}
	if !any_struct {
		println("RESULT: no struct field of type matching '${resource_re}' found -- nothing to check.")
		exit(0)
	}
	if found {
		println('RESULT: a struct-wrapped resource is discarded or unfreed at some call site -- resource leak.')
		exit(1)
	}
	println('RESULT: every call site captures and frees the struct-wrapped resource.')
}
