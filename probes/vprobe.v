// vprobe: executed probes for /vreview. A rule that asks the reviewer to imagine a case (another
// account, a second copy of the program, a mutated line) is applied unevenly from one review to
// the next. These probes run the case and print what happened, so the row is measured.
//
// Usage (`-w` hides the compiler's warnings: the probe uses `os.execute` on purpose, since a spec
// holds shell commands):
//   v -w run probes/vprobe.v matrix <spec.json> [--all]
//   v -w run probes/vprobe.v race   <spec.json>
//   v -w run probes/vprobe.v mutate <spec.json> [--list]
//   v -w run probes/vprobe.v trace  <spec.json>
//
// matrix: runs `cmd` once per (place, kind of object, account) with the base build and with the
//   head build, each time over a fresh copy of the same tree, and prints the cells where the two
//   differ: the object kept by one and removed by the other, another exit code, other paths kept or
//   removed because the object was there, or a change outside the tree's own folders.
//   Kinds: own_file, own_dir, own_empty_dir, link_to_file, link_to_dir; started as root on Linux
//   or WSL (`wsl -u root`) also other_file, other_dir (uid 65534), root_file, root_dir.
//   Accounts: user; started as root also root, with the same environment (HOME kept), which is
//   what `sudo` does where HOME is preserved.
//   `places` are folders an object is put inside; `named` are paths an object is created at (a
//   name pattern the code looks for, exact and near-miss).
// race: runs `copies` copies of `cmd` at once over a fresh tree, `rounds` times per build, with an
//   optional `actor` command looping beside them. Prints the rounds where a copy failed, the
//   rounds whose final tree differs from the tree one copy alone leaves, the actor's own failures
//   and what the copies printed. `base` may be left out.
//   A window timing cannot hit is held open: `edits` put `{pause}` at a line of a scratch copy of
//   the source, `build` builds the program from it (the source is restored right after), and
//   `in_pause` is run once per round while the program waits at that line. `{pause}` is V code.
// mutate: applies each one-line mutant, runs `test`, restores the file, and prints KILLED or
//   SURVIVED. A killed mutant names the tests that newly fail, so "killed only by a test of
//   something else" is visible. Its own controls: the unmutated tests run twice first and again
//   after every fourth mutant, a null mutant (a comment appended) runs once per file, and every
//   killed mutant runs a second time. A test that fails without a mutant, under the null mutant,
//   or in only one of two runs of the same code is named and shows no kill.
// trace: wraps every call of the named bool functions of `source`, and of the bool functions
//   that call them, runs `test` once, restores the files, and prints for each shape of input which
//   caller brought it to the function and in which tests. An input one caller is tested with and
//   another never sees is a missing test for that caller. With `test_file`, each test function
//   announces itself, so the tests are named. Only tests that run the code in their own process
//   are seen. The first argument of each wrapped call is evaluated twice (once to print it).
//
// Spec (JSON; paths in `places` and `named` are relative to the tree's root):
//   base, head   the two executables (matrix, race)
//   cmd          the command; {bin}, {root} and {work} are replaced
//   env          environment for every command; {root} is replaced. Set every variable the
//                command reads to a path under {root}, or to "" to clear it.
//   prepare      run once with the head build in the empty root, then kept as the template every
//                cell starts from (for a tree only real commands can build)
//   setup        run in every fresh root before the object is placed; must be deterministic
//   work         scratch folder (default: a new one under the temp folder). It must be new, empty
//                or one vprobe made: vprobe deletes `root` and `template` inside it
//   user         matrix as root: the account that owns the tree
//   places, named, shapes, kinds, accounts  matrix. Write a place or name as `label: path`, the
//                label being its kind of place (private, shared, ...): rows are grouped by it.
//                shapes: [{at, label, shape, values}] makes the names from a pattern the code
//                parses, `{name}-{id}.ext` with values {name, id}: the exact name and its
//                malformed forms (a field empty, dropped, not digits, with a leading zero).
//   copies (2), rounds (20), actor          race
//   edits [{file, line, find, replace}], build, in_pause   race with a held-open window: `replace`
//                is `find` with `{pause}` in front; `head` names the program `build` produces
//   test, build, mutants [{file, line, find, replace, note}], fail_regex, control_may_fail   mutate
//   source, functions   mutate: also generate the mutants of these functions of `source`, one per
//                clause of each `&&`/`||` condition and one per early-return guard. Name every
//                new or changed predicate and name parser here; `--list` prints them unrun.
//   source, functions, test, test_file      trace
//
// Exit: 0 nothing flagged; 1 something flagged (rows to read, not automatically defects) or
// something could not be run (a skipped cell, an untested mutant, a pause never reached);
// 2 usage or environment errors.
module main

import os
import json2
import regex
import time

const user_kinds = ['own_file', 'own_dir', 'own_empty_dir', 'link_to_file', 'link_to_dir']
const root_kinds = ['other_file', 'other_dir', 'root_file', 'root_dir']
const outside = 'zz_outside'
const other_uid = 65534

struct Mutant {
	file    string
	line    int
	find    string
	replace string
	note    string
}

// Shape is a name pattern the code under test parses, such as `{name}-{id}.ext` in folder `at`.
struct Shape {
	at     string
	label  string
	shape  string
	values map[string]string
}

struct Spec {
mut:
	base             string
	head             string
	cmd              string
	prepare          string
	setup            string
	env              map[string]string
	work             string
	user             string
	places           []string
	named            []string
	shapes           []Shape
	kinds            []string
	accounts         []string
	copies           int
	rounds           int
	actor            string
	build            string
	test             string
	fail_regex       string
	control_may_fail bool
	mutants          []Mutant
	source           string
	functions        []string
	ignore_tests     []string
	test_file        string
	edits            []Mutant
	in_pause         string
}

struct Ctx {
	spec      Spec
	work      string
	root      string
	template  string
	root_mode bool
	uid       int
	gid       int
}

struct Cell {
	target  string
	label   string // the kind of place: private, shared, ...
	named   bool
	kind    string
	account string
}

// split_label splits a `places` or `named` entry written as `label: path`.
fn split_label(entry string) (string, string) {
	if entry.contains(': ') {
		return entry.all_before(': ').trim_space(), entry.all_after(': ').trim_space()
	}
	return 'unlabelled', entry
}

// shape_variants returns the exact name of a shape and its malformed forms: each field empty,
// each field dropped with the separator before it, every field dropped, a digit field with a
// letter, with a leading zero and with trailing text, and the whole name with trailing text.
fn shape_variants(s Shape) []string {
	mut fields := []string{}
	mut rest := s.shape
	for rest.contains('{') && rest.contains('}') {
		fields << rest.all_after('{').all_before('}')
		rest = rest.all_after('}')
	}
	fill := fn [s] (shape string, overrides map[string]string) string {
		mut out := shape
		for field, value in s.values {
			out = out.replace('{${field}}', overrides[field] or { value })
		}
		return out
	}
	drop := fn (shape string, field string) string {
		at := shape.index('{${field}}') or { return shape }
		end := at + field.len + 2
		if at > 0 && !shape[at - 1].is_alnum() {
			return shape[..at - 1] + shape[end..]
		}
		if end < shape.len && !shape[end].is_alnum() {
			return shape[..at] + shape[end + 1..]
		}
		return shape[..at] + shape[end..]
	}
	mut names := [fill(s.shape, map[string]string{})]
	mut bare := s.shape
	for field in fields {
		value := s.values[field] or { '' }
		names << fill(s.shape, {
			field: ''
		})
		names << fill(drop(s.shape, field), map[string]string{})
		bare = drop(bare, field)
		if value != '' && value.bytes().all(it.is_digit()) {
			names << fill(s.shape, {
				field: 'x' + value
			})
			names << fill(s.shape, {
				field: '0' + value
			})
			names << fill(s.shape, {
				field: value + 'x'
			})
		}
	}
	names << bare
	names << names[0] + '.bak'
	mut unique := []string{}
	for name in names {
		if name != '' && name !in unique {
			unique << name
		}
	}
	return unique
}

struct Outcome {
mut:
	rc      int
	present bool
	removed []string
	created []string
	escaped []string
	output  []string
	skipped string
}

fn fail(msg string) {
	eprintln('vprobe: ${msg}')
	exit(2)
}

fn quoted(s string) string {
	return "'" + s.replace("'", "'\\''") + "'"
}

fn is_root() bool {
	$if windows {
		return false
	} $else {
		return os.getuid() == 0
	}
}

fn load_spec(path string) Spec {
	text := os.read_file(path) or {
		fail('cannot read ${path}: ${err}')
		return Spec{}
	}
	spec := json2.decode[Spec](text) or {
		fail('cannot parse ${path}: ${err}')
		return Spec{}
	}
	return spec
}

fn new_ctx(spec Spec) Ctx {
	work := if spec.work != '' {
		spec.work
	} else {
		os.join_path(os.temp_dir(), 'vprobe_${os.getpid()}')
	}
	// vprobe deletes `root` and `template` inside the work folder, so it only uses a folder that
	// is new, empty, or carries its own marker.
	marker := os.join_path(work, '.vprobe-work')
	if os.exists(work) {
		entries := os.ls(work) or { ['?'] }
		if entries.len > 0 && !os.exists(marker) {
			fail('the work folder ${work} is not empty and was not made by vprobe. Name a new or empty folder: vprobe deletes `root` and `template` inside it.')
		}
	}
	os.mkdir_all(work) or { fail('cannot make ${work}: ${err}') }
	if !os.exists(marker) {
		os.write_file(marker, '') or { fail('cannot write in ${work}: ${err}') }
	}
	mut uid := 0
	mut gid := 0
	root_mode := is_root()
	if root_mode {
		if spec.user == '' {
			fail('started as root: the spec needs "user", the account that owns the tree')
		}
		u := os.execute('id -u ${quoted(spec.user)}')
		g := os.execute('id -g ${quoted(spec.user)}')
		uid_text := u.output.trim_space()
		gid_text := g.output.trim_space()
		if u.exit_code != 0 || g.exit_code != 0 || uid_text == '' || gid_text == ''
			|| !uid_text.bytes().all(it.is_digit()) || !gid_text.bytes().all(it.is_digit()) {
			fail('no such user: ${spec.user}')
		}
		uid = uid_text.int()
		gid = gid_text.int()
		if uid == 0 {
			fail('"user" is root: name the ordinary account that owns the tree')
		}
		os.execute('chmod 755 ${quoted(work)}')
	}
	os.chdir(work) or {}
	return Ctx{
		spec:      spec
		work:      work
		root:      os.join_path(work, 'root')
		template:  os.join_path(work, 'template')
		root_mode: root_mode
		uid:       uid
		gid:       gid
	}
}

fn (c Ctx) set_env() {
	for name, value in c.spec.env {
		os.setenv(name, value.replace('{root}', c.root), true)
	}
}

fn (c Ctx) expand(cmd string, bin string) string {
	return cmd.replace('{bin}', bin).replace('{root}', c.root).replace('{work}', c.work)
}

fn (c Ctx) own(path string) {
	if c.root_mode {
		os.execute('chown -Rh ${c.uid}:${c.gid} ${quoted(path)}')
	}
}

fn (c Ctx) script_for(tag string) string {
	return os.join_path(c.work, 'run_${tag}.sh')
}

// run runs `cmd` as `account` and returns its exit code and output. On Windows there is one account.
fn (c Ctx) run(account string, cmd string, tag string) os.Result {
	$if windows {
		return os.execute(cmd)
	} $else {
		script := c.script_for(tag)
		os.write_file(script, '#!/bin/sh\n${cmd}\n') or {
			return os.Result{
				exit_code: 125
				output:    'cannot write ${script}: ${err}'
			}
		}
		os.chmod(script, 0o755) or {}
		if c.root_mode && account == 'user' {
			return os.execute('timeout 600 setpriv --reuid=${c.uid} --regid=${c.gid} --init-groups sh ${quoted(script)}')
		}
		return os.execute('timeout 600 sh ${quoted(script)}')
	}
}

fn remove_tree(path string) {
	$if windows {
		os.rmdir_all(path) or {}
	} $else {
		os.execute('rm -rf ${quoted(path)}')
	}
}

fn copy_tree(from string, to string) {
	$if windows {
		os.cp_all(from, to, true) or { fail('cannot copy ${from}: ${err}') }
	} $else {
		os.mkdir_all(to) or {}
		res := os.execute('cp -a ${quoted(from)}/. ${quoted(to)}/')
		if res.exit_code != 0 {
			fail('cannot copy ${from}: ${res.output}')
		}
	}
}

// prepare builds the template tree once, with the head build, at the path every cell will use.
fn (c Ctx) prepare() {
	remove_tree(c.root)
	remove_tree(c.template)
	if c.spec.prepare == '' {
		return
	}
	os.mkdir_all(c.root) or { fail('cannot make ${c.root}: ${err}') }
	c.own(c.root)
	c.set_env()
	res := c.run('user', c.expand(c.spec.prepare, c.spec.head), 'prepare')
	if res.exit_code != 0 {
		fail('prepare failed (exit ${res.exit_code}):\n${res.output}')
	}
	os.mv(c.root, c.template) or { fail('cannot keep the template: ${err}') }
}

// fresh puts a new copy of the tree at the root and runs `setup` in it.
fn (c Ctx) fresh(bin string) string {
	remove_tree(c.root)
	if os.is_dir(c.template) {
		copy_tree(c.template, c.root)
	} else {
		os.mkdir_all(c.root) or { return 'cannot make ${c.root}: ${err}' }
		c.own(c.root)
	}
	out_dir := os.join_path(c.root, outside)
	if !os.is_dir(out_dir) {
		os.mkdir_all(os.join_path(out_dir, 'dir')) or {}
		os.write_file(os.join_path(out_dir, 'victim.txt'), 'victim') or {}
		os.write_file(os.join_path(out_dir, 'dir', 'child.txt'), 'child') or {}
		c.own(out_dir)
	}
	c.set_env()
	if c.spec.setup != '' {
		res := c.run('user', c.expand(c.spec.setup, bin), 'setup')
		if res.exit_code != 0 {
			return 'setup failed (exit ${res.exit_code}): ${first_line(res.output)}'
		}
	}
	return ''
}

fn first_line(text string) string {
	for line in text.split_into_lines() {
		if line.trim_space() != '' {
			return line.trim_space()
		}
	}
	return ''
}

fn snapshot(root string) map[string]string {
	mut out := map[string]string{}
	walk_tree(root, '', mut out)
	return out
}

fn walk_tree(root string, rel string, mut out map[string]string) {
	dir := if rel == '' { root } else { os.join_path(root, rel) }
	names := os.ls(dir) or {
		out[rel + '/?'] = 'unreadable'
		return
	}
	for name in names {
		child := if rel == '' { name } else { rel + '/' + name }
		full := os.join_path(root, child)
		if os.is_link(full) {
			out[child] = 'l'
		} else if os.is_dir(full) {
			out[child] = 'd'
			walk_tree(root, child, mut out)
		} else {
			out[child] = 'f'
		}
	}
}

fn minus(a []string, b []string) []string {
	mut set := map[string]bool{}
	for x in b {
		set[x] = true
	}
	mut out := []string{}
	for x in a {
		if !set[x] {
			out << x
		}
	}
	return out
}

fn sample(list []string, n int) string {
	if list.len <= n {
		return list.join(', ')
	}
	return list[..n].join(', ') + ' ... (+${list.len - n} more)'
}

fn under(path string, prefix string) bool {
	return path == prefix || path.starts_with(prefix + '/')
}

// make_owned_dirs makes `path` and returns the topmost folder it had to create, or ''.
fn (c Ctx) make_owned_dirs(path string) string {
	mut first_missing := ''
	mut p := path
	for p.len > c.root.len && !os.exists(p) {
		first_missing = p
		p = os.dir(p)
	}
	os.mkdir_all(path) or {}
	if first_missing != '' {
		c.own(first_missing)
	}
	return first_missing
}

fn (c Ctx) place_object(object string, kind string) ! {
	if os.exists(object) || os.is_link(object) {
		return error('something is already at that path')
	}
	match kind {
		'own_file', 'other_file', 'root_file' {
			os.write_file(object, 'probe')!
		}
		'own_dir', 'other_dir', 'root_dir' {
			os.mkdir_all(object)!
			os.write_file(os.join_path(object, 'child.txt'), 'probe')!
		}
		'own_empty_dir' {
			os.mkdir_all(object)!
		}
		'link_to_file', 'link_to_dir' {
			target := os.join_path(c.root, outside, if kind == 'link_to_dir' {
				'dir'
			} else {
				'victim.txt'
			})
			if c.root_mode {
				// Made as the user: `chown -h` leaves the owner of a link to a folder unchanged on
				// some systems (uutils coreutils) and still exits 0.
				res := os.execute('setpriv --reuid=${c.uid} --regid=${c.gid} --init-groups ln -s ${quoted(target)} ${quoted(object)}')
				if res.exit_code != 0 {
					return error('ln -s as the user failed: ${first_line(res.output)}')
				}
			} else {
				os.symlink(target, object)!
			}
		}
		else {
			return error('unknown kind ${kind}')
		}
	}
	if !c.root_mode {
		return
	}
	wanted := if kind.starts_with('other_') {
		other_uid
	} else if kind.starts_with('root_') {
		0
	} else {
		c.uid
	}
	if !kind.starts_with('link_') {
		group := if wanted == c.uid { c.gid } else { wanted }
		os.execute('chown -R ${wanted}:${group} ${quoted(object)}')
	}
	// A cell whose object has the wrong owner would report a difference that is the probe's.
	st := os.lstat(object)!
	if int(st.uid) != wanted {
		return error('its owner is uid ${st.uid}, wanted ${wanted}')
	}
}

fn object_rel(cell Cell) string {
	target := cell.target.replace('\\', '/').trim_right('/')
	if cell.named {
		return target
	}
	return target + '/zz_probe_' + cell.kind
}

fn (c Ctx) run_cell(bin string, cell Cell) Outcome {
	problem := c.fresh(bin)
	if problem != '' {
		return Outcome{
			skipped: problem
		}
	}
	rel := object_rel(cell)
	mut made_above := ''
	if cell.kind != 'none' {
		object := os.join_path(c.root, rel)
		created := c.make_owned_dirs(os.dir(object))
		if created != '' {
			made_above = created[c.root.len..].replace('\\', '/').trim_left('/')
		}
		c.place_object(object, cell.kind) or {
			return Outcome{
				skipped: 'not placed: ${err}'
			}
		}
	}
	before := snapshot(c.root)
	res := c.run(cell.account, c.expand(c.spec.cmd, bin), 'cmd')
	after := snapshot(c.root)
	mut o := Outcome{
		rc:      res.exit_code
		present: rel in after
	}
	mut gone := minus(before.keys(), after.keys())
	mut made := minus(after.keys(), before.keys())
	gone.sort()
	made.sort()
	for path in gone {
		if under(path, outside) {
			o.escaped << '-' + path
		} else if made_above != '' && under(path, made_above) && under(rel, path) {
			// A folder the probe itself made above the object: the control run never had it.
			continue
		} else if cell.kind == 'none' || !under(path, rel) {
			o.removed << path
		}
	}
	for path in made {
		if under(path, outside) {
			o.escaped << '+' + path
		} else {
			o.created << path
		}
	}
	for line in res.output.split_into_lines() {
		if line.trim_space() != '' {
			o.output << line.replace(c.root, '{root}')
		}
	}
	return o
}

fn cell_key(build string, cell Cell) string {
	// `named` is part of the key: a place and a name may share one path.
	return '${build}|${cell.account}|${cell.named}|${cell.target}|${cell.kind}'
}

fn state(o Outcome) string {
	if o.skipped != '' {
		return 'skipped'
	}
	return if o.present { 'kept' } else { 'removed' }
}

fn cmd_matrix(spec Spec, show_all bool) int {
	if spec.base == '' || spec.head == '' || spec.cmd == '' {
		fail('matrix needs base, head and cmd')
	}
	c := new_ctx(spec)
	mut kinds := user_kinds.clone()
	mut accounts := ['user']
	if c.root_mode {
		kinds << root_kinds
		accounts << 'root'
	}
	if spec.kinds.len > 0 {
		kinds = kinds.filter(it in spec.kinds)
	}
	if spec.accounts.len > 0 {
		accounts = accounts.filter(it in spec.accounts)
	}
	// A spec that asks only for what cannot run here must not end as "nothing flagged".
	if accounts.len == 0 {
		fail('none of the accounts in the spec can run here: `root` needs the probe started as root')
	}
	if kinds.len == 0 && spec.places.len + spec.named.len + spec.shapes.len > 0 {
		fail('none of the kinds in the spec can run here: the other-owner kinds need the probe started as root')
	}
	mut control_problems := 0
	mut cells := []Cell{}
	for account in accounts {
		cells << Cell{
			target:  '(nothing placed)'
			kind:    'none'
			account: account
		}
		for entry in spec.places {
			label, place := split_label(entry)
			for kind in kinds {
				cells << Cell{
					target:  place
					label:   label
					kind:    kind
					account: account
				}
			}
		}
		mut named := spec.named.clone()
		for shape in spec.shapes {
			label := if shape.label != '' { shape.label } else { 'unlabelled' }
			for variant in shape_variants(shape) {
				named << '${label}: ${shape.at.trim_right('/')}/${variant}'
			}
		}
		for entry in named {
			label, name := split_label(entry)
			for kind in kinds {
				cells << Cell{
					target:  name
					label:   label
					named:   true
					kind:    kind
					account: account
				}
			}
		}
	}
	c.prepare()
	mut results := map[string]Outcome{}
	for build in ['base', 'head'] {
		bin := if build == 'base' { spec.base } else { spec.head }
		for cell in cells {
			results[cell_key(build, cell)] = c.run_cell(bin, cell)
		}
	}
	println('# place matrix: ${cells.len} cells, each run with the base build and the head build')
	if c.root_mode {
		println('Accounts: user (${spec.user}) and root with the same environment (HOME kept).')
	} else {
		println('NOT RUN: the other-owner kinds (${root_kinds.join(', ')}) and the root account.')
		println('Those rows are unverified. On Linux or WSL start the probe as root (`wsl -u root`).')
	}
	println('')
	println('## Control runs (nothing placed)')
	for account in accounts {
		control := Cell{
			target:  '(nothing placed)'
			kind:    'none'
			account: account
		}
		b := results[cell_key('base', control)]
		h := results[cell_key('head', control)]
		if b.skipped != '' || h.skipped != '' {
			println('- ${account}: NOT RUN: ${if h.skipped != '' { h.skipped } else { b.skipped }}')
			control_problems++
			continue
		}
		println('- ${account}: base exit ${b.rc}, removed ${b.removed.len} paths; head exit ${h.rc}, removed ${h.removed.len} paths')
		if b.rc != h.rc {
			println('  - DIFF exit: base ${b.rc}, head ${h.rc}')
			control_problems++
		}
		head_keeps := minus(b.removed, h.removed)
		head_removes := minus(h.removed, b.removed)
		if head_keeps.len > 0 {
			println('  - head KEEPS ${head_keeps.len} that base removed: ${sample(head_keeps, 8)}')
		}
		if head_removes.len > 0 {
			println('  - head REMOVES ${head_removes.len} that base kept: ${sample(head_removes, 8)}')
		}
		if h.rc != 0 {
			println('  - head output: ${sample(h.output, 3)}')
		}
	}
	println('')
	mut rows := []string{}
	mut row_targets := map[string][]string{}
	mut flagged := 0
	mut details := []string{}
	mut claims := []string{}
	mut claim_cells := map[string]string{}
	mut claim_counts := map[string]int{}
	mut same := 0
	mut skipped := []string{}
	for cell in cells {
		if cell.kind == 'none' {
			continue
		}
		b := results[cell_key('base', cell)]
		h := results[cell_key('head', cell)]
		label := '${cell.account} | ${cell.label} | ${cell.target} | ${cell.kind}'
		if b.skipped != '' || h.skipped != '' {
			skipped << '${label}: ${if h.skipped != '' { h.skipped } else { b.skipped }}'
			continue
		}
		control := Cell{
			target:  '(nothing placed)'
			kind:    'none'
			account: cell.account
		}
		bc := results[cell_key('base', control)]
		hc := results[cell_key('head', control)]
		head_kept_more := minus(hc.removed, h.removed)
		head_removed_more := minus(h.removed, hc.removed)
		base_kept_more := minus(bc.removed, b.removed)
		base_removed_more := minus(b.removed, bc.removed)
		mut flags := []string{}
		if b.present != h.present {
			flags << 'DIFF object: base ${state(b)}, head ${state(h)}'
		}
		if b.rc != h.rc {
			flags << 'DIFF exit: base ${b.rc}, head ${h.rc}'
		} else if h.rc != 0 {
			flags << 'FAILS on both (exit ${h.rc})'
		}
		if h.escaped.len > 0 {
			flags << 'ESCAPE: ${sample(h.escaped, 4)}'
		}
		if head_kept_more.len > 0 && head_kept_more.join('|') != base_kept_more.join('|') {
			flags << 'DIFF others: head keeps paths its control run removed'
		}
		if head_removed_more.len > 0 && head_removed_more.join('|') != base_removed_more.join('|') {
			flags << 'DIFF others: head removes paths its control run kept'
		}
		// A line that names the object, or the place it was put in, is a claim about it.
		name := object_rel(cell).all_after_last('/')
		place := '{root}/' + cell.target.replace('\\', '/').trim_right('/')
		for line in h.output {
			if line.contains(name) || (!cell.named && line.contains(place)) {
				claim := '`${line}` -> object ${state(h)}'
				if claim !in claims {
					claims << claim
					claim_cells[claim] = label
				}
				claim_counts[claim]++
			}
		}
		if flags.len == 0 {
			same++
			if !show_all {
				continue
			}
			flags << 'same'
		} else {
			flagged++
		}
		// Cells that end the same way for one account and kind share a row.
		row := '| ${cell.account} | ${cell.label} | ${cell.kind} | ${b.rc} ${state(b)} | ${h.rc} ${state(h)} | ${flags.join('; ')} |'
		if row in row_targets {
			row_targets[row] << cell.target
			continue
		}
		rows << row
		row_targets[row] = [cell.target]
		if flags == ['same'] {
			continue
		}
		details << '### ${label}'
		// Only the lines this cell adds to its control run's output.
		head_says := minus(h.output, hc.output)
		base_says := minus(b.output, bc.output)
		if head_says.len > 0 {
			details << '- head says: ${sample(head_says, 3)}'
		}
		if base_says.len > 0 {
			details << '- base says: ${sample(base_says, 2)}'
		}
		if head_kept_more.len > 0 {
			details << '- head keeps, though its control run removed them: ${sample(head_kept_more, 5)}'
		}
		if head_removed_more.len > 0 {
			details << '- head removes, though its control run kept them: ${sample(head_removed_more, 5)}'
		}
	}
	println('## Cells that differ (${flagged} flagged, ${same} same)')
	println('One disposition per row. A row is one account, one kind of place and one kind of object.')
	if cells.any(it.label == 'unlabelled') {
		println('WARNING: some places have no label (`private: path`, `shared: path`). Their rows mix kinds of place, so no single disposition can cover them: label them and rerun.')
	}
	println('')
	println('| account | place kind | object kind | base: exit, object | head: exit, object | verdict | targets |')
	println('|---|---|---|---|---|---|---|')
	for row in rows {
		println('${row} ${row_targets[row].join(', ')} |')
	}
	println('')
	if details.len > 0 {
		println('## Details (the first cell of each row)')
		for line in details {
			println(line)
		}
		println('')
	}
	if claims.len > 0 {
		println('## What the head output says about the object or its place, against the final state')
		println('A line that says "wiped" over an object that was kept, or "kept" over one that is gone, is a false claim.')
		for line in claims {
			println('- ${line} (${claim_counts[line]} cells, first: ${claim_cells[line]})')
		}
		println('')
	}
	if skipped.len > 0 {
		println('## Skipped cells (unverified)')
		for line in skipped {
			println('- ${line}')
		}
	}
	remove_tree(c.root)
	// A cell that did not run is not a clean cell.
	return if flagged > 0 || skipped.len > 0 || control_problems > 0 { 1 } else { 0 }
}

// bounded wraps a command so that one that never returns cannot hang the probe.
fn bounded(cmd string) string {
	$if windows {
		return cmd
	} $else {
		return 'timeout 600 sh -c ${quoted(cmd)}'
	}
}

fn exec_one(cmd string) os.Result {
	return os.execute(cmd)
}

struct ActorRuns {
mut:
	runs    int
	failed  int
	first   string
	reached bool
}

// act runs `cmd` again and again until the copies are done, and counts its failures.
fn act(cmd string, stop string) ActorRuns {
	mut a := ActorRuns{}
	for !os.exists(stop) {
		res := os.execute(cmd)
		a.runs++
		if res.exit_code != 0 {
			a.failed++
			if a.first == '' {
				a.first = first_line(res.output)
			}
		}
	}
	return a
}

// act_in_pause waits until the program under test stops at its `{pause}` point, runs `cmd` once,
// and lets the program go on.
fn act_in_pause(cmd string, at string, go_on string, stop string) ActorRuns {
	mut a := ActorRuns{}
	for !os.exists(stop) {
		if os.exists(at) {
			a.reached = true
			res := os.execute(cmd)
			a.runs++
			if res.exit_code != 0 {
				a.failed++
				a.first = first_line(res.output)
			}
			os.write_file(go_on, '') or {}
			return a
		}
		time.sleep(2 * time.millisecond)
	}
	return a
}

fn digits_folded(line string) string {
	mut out := []u8{}
	mut in_digits := false
	for ch in line.bytes() {
		if ch.is_digit() {
			if !in_digits {
				out << `#`
			}
			in_digits = true
		} else {
			in_digits = false
			out << ch
		}
	}
	return out.bytestr()
}

// build_with_edits applies the spec's edits to their files, runs `build`, and restores the files:
// the program that `build` produces keeps the edits, the source tree does not.
fn build_with_edits(spec Spec, pause_code string) {
	if spec.build == '' {
		fail('"edits" need "build", the command that builds the program from the edited files')
	}
	// Read every file before writing anything, so a file that cannot be read leaves no backup.
	mut originals := map[string]string{}
	for e in spec.edits {
		if e.file !in originals {
			if os.exists(e.file + '.vprobe-orig') {
				fail('${e.file}.vprobe-orig exists: an earlier run stopped half way. Copy it back over ${e.file}, delete it, then rerun.')
			}
			text := os.read_file(e.file) or {
				fail('cannot read ${e.file}: ${err}')
				return
			}
			originals[e.file] = text
		}
	}
	for file, text in originals {
		os.write_file(file + '.vprobe-orig', text) or { fail('cannot write the backup: ${err}') }
	}
	mut problem := ''
	for e in spec.edits {
		current := os.read_file(e.file) or { '' }
		mut lines := current.split('\n')
		if e.line < 1 || e.line > lines.len || e.find == '' || lines[e.line - 1].count(e.find) != 1 {
			problem = '${e.file}:${e.line}: the text `${e.find}` is not on that line exactly once'
			break
		}
		lines[e.line - 1] = lines[e.line - 1].replace_once(e.find, e.replace.replace('{pause}',
			pause_code))
		os.write_file(e.file, lines.join('\n')) or { problem = 'cannot write ${e.file}: ${err}' }
	}
	mut built := os.Result{}
	if problem == '' {
		built = os.execute(spec.build)
	}
	for file, text in originals {
		restore_file(file, text)
	}
	if problem != '' {
		fail(problem)
	}
	if built.exit_code != 0 {
		fail('the build with the edits failed (exit ${built.exit_code}): ${sample(built.output.split_into_lines(), 6)}')
	}
}

fn cmd_race(spec Spec) int {
	if spec.head == '' || spec.cmd == '' {
		fail('race needs head and cmd (base is optional)')
	}
	c := new_ctx(spec)
	copies := if spec.copies > 0 { spec.copies } else { 2 }
	rounds := if spec.rounds > 0 { spec.rounds } else { 20 }
	stop := os.join_path(c.work, 'stop_actor')
	at := os.join_path(c.work, 'at_pause')
	go_on := os.join_path(c.work, 'go_on')
	if spec.edits.len > 0 {
		// The pause, as V statements: say "here", then wait for "go on" (bounded, so a run with
		// nobody answering still ends).
		// Raw strings: a Windows path holds backslashes.
		pause_code := "os.write_file(r'${at}', '') or {}\n\tfor vprobe_n := 0; vprobe_n < 3000000 && !os.exists(r'${go_on}'); vprobe_n++ {}\n\t"
		build_with_edits(spec, pause_code)
	}
	c.prepare()
	builds := if spec.base != '' { ['base', 'head'] } else { ['head'] }
	mut flagged := false
	println('# race: ${copies} copies at once, ${rounds} rounds per build')
	if spec.edits.len > 0 {
		println('The head build carries ${spec.edits.len} edit(s) from the spec; the source files were restored.')
	}
	for build in builds {
		bin := if build == 'base' { spec.base } else { spec.head }
		problem := c.fresh(bin)
		if problem != '' {
			fail(problem)
		}
		command := c.expand(spec.cmd, bin)
		$if !windows {
			os.write_file(c.script_for('race'), '#!/bin/sh\n${command}\n') or {}
		}
		line := $if windows {
			command
		} $else {
			'timeout 600 sh ${quoted(c.script_for('race'))}'
		}
		// One copy alone, with nothing happening in the pause.
		os.rm(at) or {}
		os.write_file(go_on, '') or {}
		single := os.execute(line)
		mut alone := snapshot(c.root).keys()
		alone.sort()
		mut failing := 0
		mut differing := 0
		mut errors := map[string]int{}
		mut example := ''
		mut actor_runs := 0
		mut actor_failed := 0
		mut actor_first := ''
		mut pauses := 0
		mut printed := []string{}
		for round in 0 .. rounds {
			again := c.fresh(bin)
			if again != '' {
				fail(again)
			}
			os.rm(stop) or {}
			os.rm(at) or {}
			os.rm(go_on) or {}
			mut actors := []thread ActorRuns{}
			if spec.actor != '' {
				actors << spawn act(bounded(c.expand(spec.actor, bin)), stop)
			}
			if spec.in_pause != '' {
				actors << spawn act_in_pause(bounded(c.expand(spec.in_pause, bin)), at,
					go_on, stop)
			}
			mut threads := []thread os.Result{}
			for _ in 0 .. copies {
				threads << spawn exec_one(line)
			}
			results := threads.wait()
			os.write_file(stop, '') or {}
			for a in actors.wait() {
				actor_runs += a.runs
				actor_failed += a.failed
				if a.first != '' && actor_first == '' {
					actor_first = a.first
				}
				if a.reached {
					pauses++
				}
			}
			mut failed := false
			for res in results {
				if res.exit_code != 0 {
					failed = true
					errors[digits_folded(first_line(res.output).replace(c.root, '{root}'))]++
				}
				if round == 0 {
					for text in res.output.split_into_lines() {
						if text.trim_space() != '' && printed.len < 10 {
							printed << text.replace(c.root, '{root}')
						}
					}
				}
			}
			if failed {
				failing++
			}
			mut now := snapshot(c.root).keys()
			now.sort()
			missing := minus(alone, now)
			extra := minus(now, alone)
			if missing.len > 0 || extra.len > 0 {
				differing++
				if example == '' {
					example = 'missing: ${sample(missing, 4)}; extra: ${sample(extra, 4)}'
				}
			}
		}
		println('')
		println('## ${build}: one copy alone exits ${single.exit_code}')
		println('- rounds with a failing copy: ${failing}/${rounds}')
		for text, count in errors {
			println('  - ${count}x `${text}`')
		}
		println('- rounds whose final tree differs from one copy alone: ${differing}/${rounds}')
		if example != '' {
			println('  - first: ${example}')
		}
		if spec.actor != '' || spec.in_pause != '' {
			println('- the other party (actor, in_pause): ${actor_runs} runs, ${actor_failed} failed')
			if actor_first != '' {
				println('  - first failure: `${actor_first.replace(c.root, '{root}')}`')
			}
		}
		if spec.in_pause != '' {
			println('- the pause was reached in ${pauses}/${rounds} rounds')
			if pauses < rounds {
				println('  - NOT MEASURED in ${rounds - pauses} rounds: the program never stopped at the pause, so nothing ran in the window')
				if build == 'head' {
					flagged = true
				}
			}
		}
		if printed.len > 0 {
			println('- what the copies printed in the first round:')
			for text in printed {
				println('  - `${text}`')
			}
		}
		if build == 'head' && (failing > 0 || differing > 0 || actor_failed > 0) {
			flagged = true
		}
	}
	os.rm(stop) or {}
	os.rm(at) or {}
	os.rm(go_on) or {}
	remove_tree(c.root)
	return if flagged { 1 } else { 0 }
}

fn signature(output string, pattern string) []string {
	mut re := regex.regex_opt(pattern) or {
		fail('bad fail_regex ${pattern}: ${err}')
		return []
	}
	mut seen := map[string]bool{}
	for found in re.find_all_str(output) {
		// Keep the function name alone, so a shifted line number is not a new failure.
		seen[found.all_after_last(' ')] = true
	}
	mut names := seen.keys()
	names.sort()
	return names
}

// fn_name returns the name in a `fn` header line, without a receiver.
fn fn_name(header string) string {
	mut rest := header.all_after('fn ').trim_space()
	if rest.starts_with('(') {
		rest = rest.all_after(') ')
	}
	mut end := 0
	for end < rest.len && (rest[end].is_alnum() || rest[end] == `_`) {
		end++
	}
	return rest[..end]
}

// clause_drops returns, for a line whose condition joins clauses with `&&` or `||`, the texts
// whose removal drops one clause each.
fn clause_drops(line string) []string {
	code := line.trim_space()
	if code == '' || code.starts_with('//') {
		return []
	}
	start := line.len - line.trim_left(' \t').len
	lead := code.starts_with('&& ') || code.starts_with('|| ')
	mut s := start
	if !lead {
		for word in ['} else if ', 'return ', 'if ', 'for ', 'assert '] {
			if code.starts_with(word) {
				s = start + word.len
				break
			}
		}
		if s == start {
			if at := line.index(':= ') {
				s = at + 3
			} else if at := line.index(' = ') {
				s = at + 3
			}
		}
	}
	mut e := line.len
	if code.ends_with(' {') {
		e = line.trim_right(' \t').len - 2
	}
	mut ops := []int{}
	mut depth := 0
	mut quote := u8(0)
	for i := s; i < e; i++ {
		ch := line[i]
		if quote != 0 {
			if ch == quote && line[i - 1] != `\\` {
				quote = 0
			}
			continue
		}
		if ch in [`'`, `"`, `\``] {
			quote = ch
		} else if ch in [`(`, `[`] {
			depth++
		} else if ch in [`)`, `]`] {
			depth--
		} else if depth == 0 && i + 4 <= e && line[i..i + 4] in [' && ', ' || '] && i > s {
			ops << i
		}
	}
	mut drops := []string{}
	if lead {
		first_end := if ops.len > 0 { ops[0] + 1 } else { e }
		drops << line[s..first_end]
	} else if ops.len > 0 {
		drops << line[s..ops[0] + 4]
	}
	for k, at in ops {
		end := if k + 1 < ops.len { ops[k + 1] } else { e }
		drops << line[at..end]
	}
	return drops
}

// generate_mutants lists, for the named functions of `path`, one mutant per clause of every
// condition and one per guard that returns early, so a predicate's checks are covered in full.
fn generate_mutants(path string, names []string) []Mutant {
	text := os.read_file(path) or {
		fail('cannot read ${path}: ${err}')
		return []
	}
	lines := text.split('\n')
	mut out := []Mutant{}
	mut current := ''
	mut seen := map[string]bool{}
	for i, raw in lines {
		line := raw.trim_right('\r')
		if line.starts_with('fn ') || line.starts_with('pub fn ') {
			current = fn_name(line)
			seen[current] = true
			continue
		}
		if line == '}' {
			current = ''
			continue
		}
		if current !in names {
			continue
		}
		drops := clause_drops(line)
		for find in drops {
			out << Mutant{
				file:    path
				line:    i + 1
				find:    find
				replace: ''
				note:    '${current}: clause dropped'
			}
		}
		code := line.trim_space()
		if drops.len == 0 && code.starts_with('if ') && code.ends_with(' {') && !code.contains(':=')
			&& i + 1 < lines.len {
			next := lines[i + 1].trim_space()
			if next.starts_with('return') || next in ['continue', 'break'] {
				out << Mutant{
					file:    path
					line:    i + 1
					find:    code
					replace: 'if false {'
					note:    '${current}: guard never fires'
				}
			}
		}
	}
	for name in names {
		if !seen[name] {
			fail('no function ${name} in ${path}')
		}
	}
	return out
}

struct MutantRun {
mut:
	row     string
	invalid string
	exit    int
	names   []string
	first   string
	crash   string
}

// crash_line returns the line that says the test program itself died (a panic, a fault), or ''.
// A crash ends the run before later tests print anything, so it is a kill whatever else failed.
fn crash_line(output string) string {
	for line in output.split_into_lines() {
		for mark in ['V panic:', 'Segmentation fault', 'signal 11', 'runtime error', 'core dumped'] {
			if line.contains(mark) {
				return digits_folded(line.trim_space())
			}
		}
	}
	return ''
}

// control_pass runs the unmutated tests once: the exit code, the failing names, the first line
// and the crash line, if any.
fn control_pass(test string, pattern string) (int, []string, string, string) {
	res := os.execute(test)
	return res.exit_code, signature(res.output, pattern), first_line(res.output), crash_line(res.output)
}

fn cmd_mutate(given Spec, list_only bool) int {
	mut spec := given
	if spec.functions.len > 0 {
		if spec.source == '' {
			fail('"functions" needs "source", the file they are in')
		}
		spec.mutants << generate_mutants(spec.source, spec.functions)
	}
	if list_only {
		println('| # | file:line | mutant |')
		println('|---|---|---|')
		for i, m in spec.mutants {
			println('| ${i + 1} | ${m.file}:${m.line} | `${m.find}` -> `${m.replace}` (${m.note}) |')
		}
		return 0
	}
	if spec.test == '' || spec.mutants.len == 0 {
		fail('mutate needs test and mutants')
	}
	// A failing V assert prints `file.v:LINE: fn name`, the test or a helper it called; a passing
	// test prints no name.
	pattern := if spec.fail_regex != '' { spec.fail_regex } else { r'\.v:\d+: fn \w+' }
	for m in spec.mutants {
		if os.exists(m.file + '.vprobe-orig') {
			fail('${m.file}.vprobe-orig exists: an earlier run stopped half way. Copy it back over ${m.file}, delete it, then rerun.')
		}
	}
	if spec.build != '' {
		b := os.execute(spec.build)
		if b.exit_code != 0 {
			fail('the build command fails before any mutant: ${first_line(b.output)}')
		}
	}
	// The unmutated tests run twice before the mutants and once more after every fourth one, and
	// the mutants are judged at the end: a test that fails in any unmutated run shows no kill.
	mut control_exits := []int{}
	mut failing_runs := map[string]int{}
	mut control_crashes := []string{}
	for _ in 0 .. 2 {
		code, names, first, crash := control_pass(spec.test, pattern)
		if code != 0 && names.len == 0 {
			fail('the test command fails before any mutant and no failing test name matches fail_regex `${pattern}`: ${first}')
		}
		if crash != '' {
			control_crashes << crash
		}
		control_exits << code
		for name in names {
			failing_runs[name]++
		}
	}
	if !control_exits.all(it == 0) && !spec.control_may_fail {
		fail('the test command fails before any mutant (exits ${control_exits}; ${sample(failing_runs.keys(), 4)}). Use a green command, or set control_may_fail to judge by newly failing names.')
	}
	// A null mutant per file: a comment appended and nothing else. A test that fails under it
	// fails because the file was edited, not because of what a mutant changes.
	mut null_names := []string{}
	mut files := []string{}
	for m in spec.mutants {
		if m.file !in files {
			files << m.file
		}
	}
	for file in files {
		original := os.read_file(file) or { continue }
		os.write_file(file + '.vprobe-orig', original) or { fail('cannot write the backup: ${err}') }
		os.write_file(file, original + '\n// vprobe: null mutant\n') or {
			fail('cannot write ${file}: ${err}')
		}
		if spec.build != '' {
			os.execute(spec.build)
		}
		_, names, _, _ := control_pass(spec.test, pattern)
		os.write_file(file, original) or { fail('COULD NOT RESTORE ${file}: ${err}') }
		back := os.read_file(file) or { '' }
		if back != original {
			fail('COULD NOT RESTORE ${file}: copy ${file}.vprobe-orig back by hand')
		}
		os.rm(file + '.vprobe-orig') or {}
		for name in names {
			if name !in null_names {
				null_names << name
			}
		}
	}
	mut runs := []MutantRun{}
	mut unstable := []string{}
	mut tested := 0
	for i, m in spec.mutants {
		what := '`${m.find}` -> `${m.replace}`' + if m.note != '' { ' (${m.note})' } else { '' }
		mut run := MutantRun{
			row: '| ${i + 1} | ${m.file}:${m.line} | ${what} |'
		}
		original := os.read_file(m.file) or {
			run.invalid = 'INVALID: cannot read the file'
			runs << run
			continue
		}
		mut lines := original.split('\n')
		if m.line < 1 || m.line > lines.len {
			run.invalid = 'INVALID: no such line'
			runs << run
			continue
		}
		hits := lines[m.line - 1].count(m.find)
		if m.find == '' || hits != 1 {
			run.invalid = 'INVALID: the text occurs ${hits} times on that line'
			runs << run
			continue
		}
		lines[m.line - 1] = lines[m.line - 1].replace_once(m.find, m.replace)
		os.write_file(m.file + '.vprobe-orig', original) or { fail('cannot write the backup: ${err}') }
		os.write_file(m.file, lines.join('\n')) or { fail('cannot write ${m.file}: ${err}') }
		if spec.build != '' {
			b := os.execute(spec.build)
			if b.exit_code != 0 {
				run.invalid = 'INVALID: does not build (${first_line(b.output)})'
			}
		}
		if run.invalid == '' {
			res := os.execute(spec.test)
			run.exit = res.exit_code
			run.names = signature(res.output, pattern)
			run.first = first_line(res.output)
			run.crash = crash_line(res.output)
			if res.exit_code != 0 && run.names.len == 0 && res.output.contains(': error: ') {
				run.invalid = 'INVALID: does not compile (${run.first})'
			} else if run.names.len > 0 && res.exit_code !in [124, 137, 139] {
				// A kill is confirmed by a second run of the same mutant. A test that fails in only
				// one of the two runs of the same code is flaky, and shows no kill anywhere.
				again := os.execute(spec.test)
				names2 := signature(again.output, pattern)
				unstable << minus(run.names, names2)
				unstable << minus(names2, run.names)
				run.names = run.names.filter(it in names2)
				if run.names.len == 0 {
					run.exit = again.exit_code
					run.first = first_line(again.output)
				}
			}
		}
		os.write_file(m.file, original) or { fail('COULD NOT RESTORE ${m.file}: ${err}') }
		back := os.read_file(m.file) or { '' }
		if back != original {
			fail('COULD NOT RESTORE ${m.file}: copy ${m.file}.vprobe-orig back by hand')
		}
		os.rm(m.file + '.vprobe-orig') or {}
		runs << run
		tested++
		if tested % 4 == 0 && i + 1 < spec.mutants.len {
			code, names, _, crash := control_pass(spec.test, pattern)
			control_exits << code
			if crash != '' {
				control_crashes << crash
			}
			for name in names {
				failing_runs[name]++
			}
		}
	}
	if spec.build != '' {
		os.execute(spec.build)
	}
	mut ignored := spec.ignore_tests.clone()
	mut flaky := []string{}
	for name, count in failing_runs {
		if name !in ignored {
			ignored << name
		}
		if count < control_exits.len {
			flaky << name
		}
	}
	for name in unstable {
		if name !in ignored {
			ignored << name
		}
		if name !in flaky {
			flaky << name
		}
	}
	println('# mutants: ${spec.mutants.len}; the unmutated tests ran ${control_exits.len} times, exits ${control_exits}')
	if ignored.len > 0 {
		println('Failing without a mutant (or listed in ignore_tests), so they show no kill: ${ignored.join(', ')}')
	}
	if flaky.len > 0 {
		println('FLAKY, failed in one run and passed in another run of the same code: ${flaky.join(', ')}. Report it.')
	}
	edit_only := minus(null_names, ignored)
	if edit_only.len > 0 {
		println('Failing whenever the file is edited (a comment appended, nothing else), so they show no kill: ${edit_only.join(', ')}. Report it: such a test depends on the source file, not on the code.')
		ignored << edit_only
	}
	println('')
	println('| # | file:line | mutant | result |')
	println('|---|---|---|---|')
	mut survived := 0
	mut untested := 0
	mut kills := map[string]int{}
	for run in runs {
		mut verdict := run.invalid
		if verdict != '' {
			untested++
		}
		if verdict == '' {
			newly := minus(run.names, ignored)
			if newly.len > 0 {
				verdict = 'KILLED by ${sample(newly, 6)}'
				for name in newly {
					kills[name]++
				}
			} else if run.crash != '' && run.crash !in control_crashes {
				// The test program died part way: the tests after that point never ran.
				verdict = 'KILLED (the tests crashed: ${run.crash})'
			} else if run.exit in [124, 137, 139] {
				// `timeout` ended it, or a signal did: a hang or a crash, whatever failed before it.
				verdict = 'KILLED (exit ${run.exit}: the tests hung or crashed)'
			} else if run.exit == 0 || run.names.len > 0 {
				// Green, or only the tests that fail without the mutant too.
				verdict = '**SURVIVED**'
				survived++
			} else {
				// A failure with no test name: a crash or a timeout.
				verdict = 'KILLED (exit ${run.exit}, no test named: ${run.first})'
			}
		}
		println('${run.row} ${verdict} |')
	}
	println('')
	println('${survived} survived. A survivor is a line no test checks; a mutant killed only by a test of something else is a gap too.')
	if untested > 0 {
		println('${untested} could not be tested (the INVALID rows): they are neither killed nor survived. Correct them and rerun.')
	}
	for name, count in kills {
		if count >= 3 {
			println('`${name}` is among the killers of ${count} mutants: if they are unrelated, check that it is not flaky (rerun, or list it in ignore_tests).')
		}
	}
	// A mutant that was not tested is not a killed mutant.
	return if survived > 0 || untested > 0 { 1 } else { 0 }
}

struct FnInfo {
	name         string
	start        int // index of the header line
	end          int // index of the closing brace line
	is_bool      bool
	first_string bool
}

struct CallSite {
mut:
	id     int
	line   int // index of the line
	start  int
	end    int // index after the closing parenthesis
	name   string
	arg1   string
	caller string
}

// parse_fns lists the top-level functions of a V file: name, lines, whether it returns a plain
// `bool`, and whether its first parameter is a string.
fn parse_fns(lines []string) []FnInfo {
	mut out := []FnInfo{}
	mut i := 0
	for i < lines.len {
		line := lines[i]
		if line.starts_with('fn ') || line.starts_with('pub fn ') {
			mut end := i
			for end < lines.len - 1 && lines[end] != '}' {
				end++
			}
			name := fn_name(line)
			after_name := line.all_after(name + '(')
			first := after_name.all_before(')').all_before(',').trim_space()
			ret := after_name.all_after(')').trim_space().trim_right('{').trim_space()
			out << FnInfo{
				name:         name
				start:        i
				end:          end
				is_bool:      ret == 'bool'
				first_string: first.ends_with(' string')
			}
			i = end
		}
		i++
	}
	return out
}

fn is_ident_char(c u8) bool {
	return c.is_alnum() || c == `_`
}

// matching_paren returns the index of the parenthesis that closes the one at `open`, or -1 when it
// is not on this line.
fn matching_paren(line string, open int) int {
	mut depth := 0
	mut quote := u8(0)
	for i := open; i < line.len; i++ {
		ch := line[i]
		if quote != 0 {
			if ch == quote && line[i - 1] != `\\` {
				quote = 0
			}
			continue
		}
		if ch in [`'`, `"`, `\``] {
			quote = ch
		} else if ch in [`(`, `[`] {
			depth++
		} else if ch in [`)`, `]`] {
			depth--
			if depth == 0 {
				return i
			}
		}
	}
	return -1
}

// find_calls lists the calls of plain function `name` on one line. A call inside the arguments of
// another listed call is left alone.
fn find_calls(line string, name string) []CallSite {
	mut out := []CallSite{}
	needle := name + '('
	mut i := 0
	for i + needle.len <= line.len {
		if line[i..i + needle.len] == needle
			&& (i == 0 || (!is_ident_char(line[i - 1]) && line[i - 1] != `.`)) {
			open := i + needle.len - 1
			close := matching_paren(line, open)
			if close > 0 {
				args := line[open + 1..close]
				mut arg1 := args
				mut depth := 0
				for k, ch in args.bytes() {
					if ch in [`(`, `[`] {
						depth++
					} else if ch in [`)`, `]`] {
						depth--
					} else if ch == `,` && depth == 0 {
						arg1 = args[..k]
						break
					}
				}
				out << CallSite{
					start: i
					end:   close + 1
					name:  name
					arg1:  arg1.trim_space()
				}
				i = close + 1
				continue
			}
		}
		i++
	}
	return out
}

// input_class folds an argument into its shape: the file name alone, the running account's id as
// `<me>`, long hex runs as `<hex>`, other digit runs as `#`, and every word that is not one the
// traced functions themselves spell out as `a`.
fn input_class(arg string, me string, keep []string) string {
	name := arg.all_after_last('/').all_after_last('\\')
	mut out := []string{}
	mut i := 0
	for i < name.len {
		ch := name[i]
		if ch.is_alnum() || ch == `_` {
			mut j := i
			for j < name.len && (name[j].is_alnum() || name[j] == `_`) {
				j++
			}
			word := name[i..j]
			if word == me && me != '' {
				out << '<me>'
			} else if word.bytes().all(it.is_digit()) {
				out << '#'
			} else if word.len >= 16 && word.bytes().all(it.is_hex_digit()) {
				out << '<hex>'
			} else if word in keep {
				out << word
			} else {
				out << 'a'
			}
			i = j
		} else {
			out << ch.ascii_str()
			i++
		}
	}
	return out.join('')
}

fn restore_file(path string, original string) {
	os.write_file(path, original) or { fail('COULD NOT RESTORE ${path}: ${err}') }
	back := os.read_file(path) or { '' }
	if back != original {
		fail('COULD NOT RESTORE ${path}: copy ${path}.vprobe-orig back by hand')
	}
	os.rm(path + '.vprobe-orig') or {}
}

// cmd_trace runs the tests once over an instrumented copy of `source` and prints, for each traced
// function, which shapes of input reached it through which caller, and in which tests.
fn cmd_trace(spec Spec) int {
	if spec.source == '' || spec.test == '' || spec.functions.len == 0 {
		fail('trace needs source, functions and test')
	}
	for path in [spec.source, spec.test_file] {
		if path != '' && os.exists(path + '.vprobe-orig') {
			fail('${path}.vprobe-orig exists: an earlier run stopped half way. Copy it back over ${path}, delete it, then rerun.')
		}
	}
	original := os.read_file(spec.source) or {
		fail('cannot read ${spec.source}: ${err}')
		return 2
	}
	mut lines := original.replace('\r\n', '\n').split('\n')
	fns := parse_fns(lines)
	mut by_name := map[string]FnInfo{}
	for f in fns {
		by_name[f.name] = f
	}
	for name in spec.functions {
		if name !in by_name {
			fail('no function ${name} in ${spec.source}')
		}
		if !by_name[name].is_bool {
			fail('${name} does not return a plain bool: trace follows bool functions only')
		}
	}
	// The traced set: the named functions, and every bool function that calls one of the set.
	mut traced := spec.functions.clone()
	for {
		mut grew := false
		for f in fns {
			if !f.is_bool || f.name in traced {
				continue
			}
			for k in f.start + 1 .. f.end {
				if lines[k].trim_space().starts_with('//') {
					continue
				}
				if traced.any(find_calls(lines[k], it).len > 0) {
					traced << f.name
					grew = true
					break
				}
			}
		}
		if !grew {
			break
		}
	}
	// Words the named functions spell out in their own string literals stay visible in a class.
	// Split on the quote, the odd pieces are the insides of the literals.
	mut keep := []string{}
	for name in spec.functions {
		f := by_name[name]
		for k in f.start .. f.end {
			for n, piece in lines[k].split("'") {
				if n % 2 == 0 {
					continue
				}
				for word in piece.split_any('.-_ /\\') {
					if word.len >= 3 && word.bytes().all(it.is_letter()) && word !in keep {
						keep << word
					}
				}
			}
		}
	}
	mut sites := map[int]CallSite{}
	for f in fns {
		for k in f.start + 1 .. f.end {
			if lines[k].trim_space().starts_with('//') {
				continue
			}
			mut found := []CallSite{}
			for name in traced {
				found << find_calls(lines[k], name)
			}
			found.sort(a.start < b.start)
			for n, _ in found {
				found[n].id = (k + 1) * 10 + n
				found[n].line = k
				found[n].caller = f.name
			}
			for n := found.len - 1; n >= 0; n-- {
				site := found[n]
				// The first argument is written out a second time to be printed, so it is
				// evaluated twice: the traced functions take a name or a path, not a side effect.
				shown := if by_name[site.name].first_string && site.arg1 != '' {
					site.arg1
				} else {
					"''"
				}
				call := lines[k][site.start..site.end]
				lines[k] = lines[k][..site.start] +
					'vprobe_out(${site.id}, ${shown}, vprobe_in(${site.id}) && ${call})' +
					lines[k][site.end..]
				sites[site.id] = site
			}
		}
	}
	if sites.len == 0 {
		fail('no call of ${traced.join(', ')} found in ${spec.source}')
	}
	lines << 'fn vprobe_in(site int) bool {'
	lines << "\teprintln('VPROBE|in|\${site}')"
	lines << '\treturn true'
	lines << '}'
	lines << ''
	lines << 'fn vprobe_out(site int, arg string, res bool) bool {'
	lines << "\teprintln('VPROBE|out|\${site}|\${res}|\${arg}')"
	lines << '\treturn res'
	lines << '}'
	lines << ''
	mut test_original := ''
	if spec.test_file != '' {
		test_original = os.read_file(spec.test_file) or {
			fail('cannot read ${spec.test_file}: ${err}')
			return 2
		}
		mut marked := []string{}
		for line in test_original.replace('\r\n', '\n').split('\n') {
			marked << line
			if line.starts_with('fn test_') && line.trim_space().ends_with('{') {
				marked << "\teprintln('VPROBE|test|${fn_name(line)}')"
			}
		}
		os.write_file(spec.test_file + '.vprobe-orig', test_original) or {
			fail('cannot write the backup: ${err}')
		}
		os.write_file(spec.test_file, marked.join('\n')) or {
			fail('cannot write ${spec.test_file}: ${err}')
		}
	}
	os.write_file(spec.source + '.vprobe-orig', original) or { fail('cannot write the backup: ${err}') }
	os.write_file(spec.source, lines.join('\n')) or { fail('cannot write ${spec.source}: ${err}') }
	res := os.execute(spec.test)
	restore_file(spec.source, original)
	if spec.test_file != '' {
		restore_file(spec.test_file, test_original)
	}
	me := $if windows {
		''
	} $else {
		os.getuid().str()
	}
	mut test := '(before any test)'
	mut tests := []string{}
	mut stack := []int{}
	mut hits := map[string][]string{} // function|class|result@root -> tests
	mut examples := map[string]string{} // function|class|result -> one argument
	mut roots := map[string][]int{} // function -> root sites that reached it
	mut reached := map[int]bool{}
	mut events := 0
	for line in res.output.split_into_lines() {
		if !line.starts_with('VPROBE|') {
			continue
		}
		parts := line.split('|')
		events++
		if parts[1] == 'test' && parts.len >= 3 {
			test = parts[2]
			tests << test
			stack.clear()
		} else if parts[1] == 'in' && parts.len >= 3 {
			// Only a line the instrumented code printed: a known site, written as digits.
			if parts[2].bytes().all(it.is_digit()) && parts[2].int() in sites {
				stack << parts[2].int()
			}
		} else if parts[1] == 'out' && parts.len >= 5 {
			if !parts[2].bytes().all(it.is_digit()) {
				continue
			}
			id := parts[2].int()
			at := stack.last_index(id)
			if at >= 0 {
				stack = stack[..at].clone()
			}
			site := sites[id] or { continue }
			root := if stack.len > 0 { stack[0] } else { id }
			reached[id] = true
			reached[root] = true
			if site.name !in spec.functions {
				continue
			}
			if root !in roots[site.name] {
				roots[site.name] << root
			}
			arg := parts[4..].join('|')
			if arg == '' {
				continue
			}
			key := '${site.name}|${input_class(arg, me, keep)}|${parts[3]}'
			if key !in examples {
				examples[key] = arg.all_after_last('/')
			}
			slot := '${key}@${root}'
			if test !in hits[slot] {
				hits[slot] << test
			}
		}
	}
	if events == 0 {
		fail('the test run printed no trace line. Did the instrumented file compile? First line: ${first_line(res.output)}')
	}
	place := fn [sites] (id int) string {
		site := sites[id] or { return '${id}' }
		return '${site.caller}:${site.line + 1}'
	}
	println('# trace: ${sites.len} call sites of ${traced.join(', ')}; ${tests.len} tests ran (exit ${res.exit_code})')
	println('A class is the shape of an argument: `<me>` is the running account, `#` other digits, `<hex>` a long hex run, `a` any other word.')
	mut unreached := []string{}
	for id, _ in sites {
		if !reached[id] {
			unreached << place(id)
		}
	}
	unreached.sort()
	if unreached.len > 0 {
		println('Call sites no test reached: ${unreached.join(', ')}')
	}
	mut gaps := []string{}
	mut refused_gaps := 0
	for name in spec.functions {
		println('')
		println('## ${name}')
		mut via := roots[name].clone()
		via.sort()
		println('Reached through: ${via.map(place(it)).join(', ')}')
		println('')
		println('| input class | example | result | through (tests) | never through |')
		println('|---|---|---|---|---|')
		mut keys := examples.keys().filter(it.starts_with(name + '|'))
		keys.sort()
		for key in keys {
			parts := key.split('|')
			mut seen := []string{}
			mut never := []string{}
			for root in via {
				found := hits['${key}@${root}']
				if found.len > 0 {
					seen << '${place(root)} (${found.len}: ${sample(found, 2)})'
				} else {
					never << place(root)
				}
			}
			println('| `${parts[1]}` | `${examples[key]}` | ${parts[2]} | ${seen.join('; ')} | ${never.join(', ')} |')
			if never.len == 0 {
				continue
			}
			if parts[2] == 'true' {
				gaps << '`${name}` accepts `${parts[1]}` (such as `${examples[key]}`); no test brings that input through: ${never.join(', ')}.'
			} else {
				refused_gaps++
			}
		}
	}
	println('')
	println('## Gaps: an accepted input that one caller is tested with and another never sees (${gaps.len})')
	println('Each line is a missing test, or a caller that cannot receive that input: say which, per line.')
	for gap in gaps {
		println('- ${gap}')
	}
	if refused_gaps > 0 {
		println('${refused_gaps} more rows are refused inputs some caller never sees: the "never through" column of the tables.')
	}
	println('Only tests that run the code in their own process are seen; a test that starts a separately built program shows nothing here.')
	return if gaps.len > 0 || unreached.len > 0 { 1 } else { 0 }
}

fn main() {
	args := os.args[1..]
	paths := args.filter(!it.starts_with('--'))
	if paths.len != 2 || paths[0] !in ['matrix', 'race', 'mutate', 'trace'] {
		eprintln('usage: v run vprobe.v matrix|race|mutate|trace <spec.json> [--all] [--list]')
		eprintln('The header of vprobe.v describes the spec.')
		exit(2)
	}
	spec := load_spec(paths[1])
	code := match paths[0] {
		'matrix' { cmd_matrix(spec, '--all' in args) }
		'race' { cmd_race(spec) }
		'trace' { cmd_trace(spec) }
		else { cmd_mutate(spec, '--list' in args) }
	}
	exit(code)
}
