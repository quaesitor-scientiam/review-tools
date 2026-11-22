// Tests of the mutants `vprobe mutate` generates and of the marker groups of `vprobe siblings`.
// Run: v test probes/vprobe_mutants_test.v
module main

import os

fn test_release_statement_takes_only_a_statement_that_gives_a_resource_back() {
	// The first, a middle and the last name of each list.
	assert release_statement('\tC.FindClose(h_find_files)') or { '' } == 'C.FindClose(h_find_files)'
	assert release_statement('\tC.CloseHandle(pi.h_process)') or { '' } == 'C.CloseHandle(pi.h_process)'
	assert release_statement('\tunsafe { free(wpattern) }') or { '' } == 'unsafe { free(wpattern) }'
	assert release_statement('\tf.close()') or { '' } == 'f.close()'
	assert release_statement('\t\tc.mu.unlock()') or { '' } == 'c.mu.unlock()'
	assert release_statement('\tc.mu.runlock()') or { '' } == 'c.mu.runlock()'
	assert release_statement('\tunsafe { wide.free() }') or { '' } == 'unsafe { wide.free() }'
	// A comment, with and without a space after the slashes.
	assert release_statement('\t// C.FindClose(h)') == none
	assert release_statement('\t//f.close()') == none
	// Not the whole statement: the call's parenthesis closes before the end of the line.
	assert release_statement('\tC.close(fd) == check(1)') == none
	assert release_statement('\tfree(a) + size(b)') == none
	// Not a release: another function whose text only ends like a call.
	assert release_statement('\tclose_all(f)') == none
	// A method call with something around it.
	assert release_statement('\tok := f.close()') == none
	assert release_statement('\treturn f.close()') == none
	assert release_statement('\tif done { f.close() }') == none
	assert release_statement('\tf.close() or { panic(err) }') == none
}

fn test_check_dispositions_reads_each_row_and_checks_what_its_kind_needs() {
	source := tmp_file('disp.v', 'fn f(a bool, b bool) bool {\n\tif a && b {\n\t\treturn true\n\t}\n\treturn a\n}\n')
	first := Mutant{
		file: source
		line: 2
		find: 'a && '
		note: 'f: clause dropped'
	}
	second := Mutant{
		file: source
		line: 2
		find: ' && b'
		note: 'f: clause dropped'
	}
	both := {
		1: first
		2: second
	}
	check := fn [both] (name string, rows string) int {
		path := tmp_file(name, rows)
		defer {
			os.rm(path) or {}
		}
		return check_dispositions(path, both)
	}
	defer {
		os.rm(source) or {}
	}
	// Every row is read, the first and the last; blank lines and `#` lines are skipped.
	assert check('ok.tsv', '# two survivors\n\n1\tlimit\tno test yet\n2\tfinding\ta real gap\n') == 0
	assert check('first_only.tsv', '1\tlimit\tno test yet\n') == 1
	assert check('last_only.tsv', '2\tlimit\tno test yet\n') == 1
	// A row needs an id, a kind and a reason that is not blank. Such a row is one problem, and
	// the survivor it leaves without a disposition is another.
	assert check('no_reason.tsv', '1\tlimit\t \n2\tlimit\tx\n') == 2
	assert check('two_fields.tsv', '1\tlimit\n2\tlimit\tx\n') == 2
	// An equivalent row quotes code that is in the file, on another line than the mutant's.
	assert check('eq_ok.tsv', '1\tequivalent\tsee `return a`\n2\tlimit\tx\n') == 0
	assert check('eq_same_line.tsv', '1\tequivalent\tsee `if a && b {`\n2\tlimit\tx\n') == 1
	assert check('eq_not_in_file.tsv', '1\tequivalent\tsee `zzz_not_there`\n2\tlimit\tx\n') == 1
	assert check('eq_empty_quote.tsv', '1\tequivalent\tsee `` nothing quoted\n2\tlimit\tx\n') == 1
}

fn test_loop_iterable_wants_a_for_loop_over_a_named_value() {
	assert loop_iterable('\tif name in names {') == none
	assert loop_iterable('\tfor name in  {') == none
}

fn test_loop_iterable_leaves_a_loop_over_a_literal_alone() {
	assert loop_iterable('\tfor name in names {') or { '' } == 'names'
	// The literal starts on the loop's own line: there is no name to slice. This used to panic,
	// which vprobe found when it was run on its own source.
	assert loop_iterable('\t\tfor slice, what in {') == none
	assert loop_iterable('\tfor i in 0 .. n {') == none
}

// tmp_file writes `text` to a file of this test's own and returns its path.
fn tmp_file(name string, text string) string {
	path := os.join_path(os.vtmp_dir(), 'vprobe_test_${os.getpid()}_${name}')
	os.write_file(path, text) or { panic(err) }
	return path
}

fn test_a_dropped_release_can_not_be_filed_as_equivalent() {
	source := tmp_file('held.v', 'fn list() {\n\th := open()\n\tC.FindClose(h)\n\tprintln(h)\n}\n')
	release := Mutant{
		file: source
		line: 3
		find: 'C.FindClose(h)'
		note: 'list: the release is dropped'
	}
	clause := Mutant{
		file: source
		line: 2
		find: 'open()'
		note: 'list: clause dropped'
	}
	as_equivalent := tmp_file('eq.tsv', '1\tequivalent\tnothing reads it, see `println(h)`\n')
	as_limit := tmp_file('limit.tsv', '1\tlimit\tno test counts handles\n')
	defer {
		os.rm(source) or {}
		os.rm(as_equivalent) or {}
		os.rm(as_limit) or {}
	}
	assert check_dispositions(as_equivalent, {
		1: release
	}) == 1
	assert check_dispositions(as_limit, {
		1: release
	}) == 0
	// Another kind of mutant may still be equivalent, when the reason quotes code of the file.
	assert check_dispositions(as_equivalent, {
		1: clause
	}) == 0
}

fn test_siblings_takes_either_text_of_a_grouped_marker_as_a_site() {
	base := tmp_file('sib_base.v', 'fn look_at_root(p string) bool {\n\treturn is_folder(p)\n}\n\nfn look_at_entry(p string) bool {\n\treturn kind_of(p)\n}\n\nfn other_spelling(p string) string {\n\treturn p\n}\n')
	head := tmp_file('sib_head.v', 'fn look_at_root(p string) bool {\n\treturn is_folder(p)\n}\n\nfn look_at_entry(p string) bool {\n\tq := other_spelling(p)\n\treturn kind_of(q)\n}\n\nfn other_spelling(p string) string {\n\treturn p\n}\n')
	defer {
		os.rm(base) or {}
		os.rm(head) or {}
	}
	// Each text alone marks one site, so there is nothing to compare.
	assert cmd_siblings(Spec{
		source:       head
		changed_from: base
		markers:      ['is_folder(', 'kind_of(']
	}) == 0
	// As one situation, the entry's look gained a call that the root's look lacks.
	assert cmd_siblings(Spec{
		source:       head
		changed_from: base
		markers:      ['is_folder(<or>kind_of(']
	}) == 1
	// An empty alternative marks nothing.
	assert cmd_siblings(Spec{
		source:       head
		changed_from: base
		markers:      ['<or>']
	}) == 0
}

fn test_generate_mutants_drops_each_release_of_a_named_function() {
	path := os.join_path(os.vtmp_dir(), 'vprobe_release_${os.getpid()}.v')
	os.write_file(path, 'fn list(dir string) int {\n\th := open(dir)\n\tn := count(h)\n\tC.FindClose(h)\n\treturn n\n}\n\nfn other() {\n\tf.close()\n}\n')!
	defer {
		os.rm(path) or {}
	}
	mutants := generate_mutants(path, ['list'])
	releases := mutants.filter(it.note.contains('the release is dropped'))
	assert releases.len == 1
	assert releases[0].line == 4
	assert releases[0].find == 'C.FindClose(h)'
	assert releases[0].replace == ''
}

fn test_field_write_takes_only_a_statement_that_stores_in_a_field() {
	assert field_write('\tld.timer_set_at = now') or { '' } == 'ld.timer_set_at = now'
	assert field_write('\t\tc.handshake_ack_received = true') or { '' } == 'c.handshake_ack_received = true'
	assert field_write('\tc.peer_cids[seq] = next.clone()') or { '' } == 'c.peer_cids[seq] = next.clone()'
	// Not a field: a local name, a declaration, a comparison, a compound operator.
	assert field_write('\tx = 1') == none
	assert field_write('\tx := a.b') == none
	assert field_write('\tif a.b == c {') == none
	assert field_write('\ta.b += 1') == none
	assert field_write('\tok := a.b != c') == none
	// Something besides a name before the ` = `, at its start, middle and end.
	assert field_write('\t*a.b = x') == none
	assert field_write('\tunsafe { a.b = x }') == none
	assert field_write('\ta.b() = x') == none
	// A comment, and a value that goes on to a further line.
	assert field_write('\t// c.x = 1') == none
	assert field_write('\tc.state = Foo{') == none
	assert field_write('\tc.x = compute(a,') == none
	assert field_write('\tc.x = match y {') == none
}

fn test_generate_mutants_drops_each_field_write_of_a_named_function() {
	path := os.join_path(os.vtmp_dir(), 'vprobe_field_${os.getpid()}.v')
	os.write_file(path, 'fn ack(mut c Conn, now u64) {\n\tc.acked = true\n\tn := c.count\n\tc.at = now\n}\n\nfn other(mut c Conn) {\n\tc.acked = false\n}\n')!
	defer {
		os.rm(path) or {}
	}
	writes := generate_mutants(path, ['ack']).filter(it.note.contains('the field write is dropped'))
	assert writes.map(it.line) == [2, 4]
	assert writes.map(it.find) == ['c.acked = true', 'c.at = now']
	assert writes.all(it.replace == '')
}
