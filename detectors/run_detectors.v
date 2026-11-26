// run_detectors — V port of skills/code-review/run_detectors.sh: run every
// applicable mechanical review detector in one shot, with no bash involved.
//
// The runner OWNS ALL GIT ACCESS. It computes the target file list and the base
// revision once, extracts base-revision copies into a new private folder (mode
// 0700, a random name under the OS temp dir), compiles each detectors/detect_*.v
// the run needs once (cached by source and compiler in the user's own cache folder,
// os.cache_dir()/review-tools-bin, never in the shared temp dir, where another
// account could plant a build under the predictable name) and hands every
// detector plain paths only:
//
//     detect_x <file> <base_copy_or_empty>
//
// Usage:
//   v run detectors/run_detectors.v [--base <rev>] [--at <rev>] [file.v ...]
//
//   file.v ...   target files (repo-relative or absolute; Windows separators and
//                CRLF-polluted args are normalised). With no files, the target
//                set is every changed .v and .md file (working tree vs HEAD, plus
//                the branch diff vs the merge base with the default branch). A .md
//                target goes to the detectors whose manifest globs name *.md (the
//                claims detector, which lists a doc's new prose lines), with its
//                base copy. A named file that does not exist is reported as
//                skipped, and a target no detector takes says so.
//   --base <rev> revision the base copies come from (default: the merge base of
//                HEAD and the default branch: master, else main, else the branch
//                origin/HEAD names; no base copies if none of them exists).
//   --at <rev>   scan the targets AS THEY WERE at <rev>: the runner extracts
//                every target plus the other .v files of each target's directory
//                (and cmd/tools/vtest-self.v) at <rev> into a temp tree that
//                mirrors the repo layout, and scans there.
//   --only <s>   run only detectors whose name contains <s> (debug aid).
//
// Environment: DETECT_V names the V compiler used for the detectors (default: `v` on
// PATH, then the target repo's own ./v or v.exe). Run from inside the
// target repo. From a Windows-created git worktree under WSL the drive-letter
// `gitdir:` pointer is resolved to /mnt/<drive>/... and GIT_DIR/GIT_WORK_TREE
// are exported for the git calls.
//
// Exit: 0 if no detector flagged; 1 if any detector exited 1 (candidates to
// review — for enumerate-and-verify detectors that is not automatically a bug);
// 2 on usage/environment errors, and when a detector the run needs could not be built
// or ended with any other exit: the rest still run and print, and the summary line
// names those that gave no verdict.
module main

import os
import crypto.rand
import crypto.sha256

// Manifest: detector stem -> space-separated basename globs (one `*` each)
// the detector applies to. A detector runs once per matching target file. See the shell runner's manifest for the
// rationale behind each scope.
const manifest = {
	'detect_lenient_parse':                            '*.v'
	'detect_info_leak':                                '*.v'
	'detect_unsafe_blocks':                            '*.v'
	'detect_unshared_getter_return':                   '*.v'
	'detect_unbounded_accum':                          '*.v'
	'detect_scheduler_field_coverage':                 '*.v'
	'detect_cache_key_environment':                    '*.v'
	'detect_external_behavior_claims':                 '*.v *.md'
	'detect_platform_gated_tests':                     '*_test.v'
	'detect_look_then_recursive_remove':               '*.v'
	'detect_partial_dedup_return':                     '*.v'
	'detect_numeric_text_compare':                     '*.v'
	'detect_error_scope':                              'h2_*.v'
	'detect_hpack_decode_scope':                       'h2_*.v'
	'detect_swallowed_write':                          'h2_*.v'
	'detect_settings_arm_parity':                      'h2_*.v'
	'detect_flag_priority_order':                      'h2_*.v'
	'detect_padding_credit':                           'h2_conn.v h2_server.v h2_mux_conn.v'
	'detect_malformed_content_length':                 'h2_conn.v h2_mux_conn.v'
	'detect_h2_response_field_validation':             'h2_conn.v h2_mux_conn.v'
	'detect_hpack_skip_on_half_closed':                'h2_server.v'
	'detect_orphan_continuation_gate':                 'h2_server.v'
	'detect_stream_state_even_idle':                   'h2_server.v'
	'detect_pump_delegates_dispatch':                  'h2_server.v'
	'detect_server_window_single_pass':                'h2_server.v'
	'detect_locally_reset_consumers':                  'h2_server.v'
	'detect_status_fallthrough':                       'h2_conn.v'
	'detect_h2conn_1xx_end_stream':                    'h2_conn.v'
	'detect_h2conn_response_parity':                   'h2_conn.v'
	'detect_fmu_scope':                                'h2_mux_conn.v'
	'detect_initial_window_recheck':                   'h2_mux_conn.v'
	'detect_headers_max_reread':                       'h2_mux_conn.v'
	'detect_missing_fcv_broadcast':                    'h2_mux_conn.v'
	'detect_goaway_wmu_serialize':                     'h2_mux_conn.v'
	'detect_peer_max_frame_wmu':                       'h2_mux_conn.v'
	'detect_mux_table_size_update':                    'h2_mux_conn.v'
	'detect_mux_trailers_preserved':                   'h2_mux_conn.v'
	'detect_mux_headers_after_end':                    'h2_mux_conn.v'
	'detect_mux_requires_closer':                      'h2_mux_conn.v'
	'detect_close_idle_double_close':                  'server_tls*.v ssl_connection.c.v'
	'detect_close_idle_windows_double_close':          'server_tls*.v ssl_connection.c.v'
	'detect_tls_accept_send_interruptible':            'server_tls*.v'
	'detect_tls_weak_config':                          'server_tls*.v ssl_connection.c.v'
	'detect_tls_read_precheck_poll':                   'h2_pooled_transport.v'
	'detect_pooled_write_duration_reuse':              'h2_pooled_transport.v'
	'detect_pooled_conn_stored_by_value':              'h2_pooled_transport.v'
	'detect_vschannel_pooled_alpn_gate':               'vschannel_pooled_transport_windows.c.v'
	'detect_pool_cap_scope_symmetry':                  'transport.v transport_h2.v'
	'detect_pool_collect_release_clear':               'transport.v transport_h2.v'
	'detect_idle_cap_counts_busy_conns':               'transport.v'
	'detect_ungated_release_after_conditional_delete': 'transport.v transport_h2.v h2_mux_conn.v'
	'detect_ecdsa_key_missing_free':                   'tls13_*_test.v'
	'detect_struct_wrapped_resource_leak':             'tls13_*_test.v'
	'detect_quic_test_missing_openssl_gate':           '*_test.v'
}

struct Ctx {
mut:
	repo_root string
	base_rev  string
	at_rev    string
	only      string
	files     []string
	tmp       string
	scan_root string
	base_copy map[string]string
	vexe      string
	bins      map[string]string
	unbuilt   []string
}

fn main() {
	mut c := Ctx{}
	mut args := []string{}
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		match a {
			'--base' {
				i++
				c.base_rev = os.args[i] or { usage_error('--base needs a revision') }
			}
			'--at' {
				i++
				c.at_rev = os.args[i] or { usage_error('--at needs a revision') }
			}
			'--only' {
				i++
				c.only = os.args[i] or { usage_error('--only needs a regex') }
			}
			'-h', '--help' {
				println(usage_text())
				exit(0)
			}
			else {
				if a.starts_with('--base=') {
					c.base_rev = a['--base='.len..]
				} else if a.starts_with('--at=') {
					c.at_rev = a['--at='.len..]
				} else if a.starts_with('--only=') {
					c.only = a['--only='.len..]
				} else if a.starts_with('-') {
					usage_error('unknown option ${a}')
				} else {
					args << a
				}
			}
		}
		i++
	}

	start_dir := os.getwd()
	// Read before the move to the repo root: a relative TMPDIR is below the start folder.
	temp := temp_parent()
	c.repo_root = resolve_repo_root() or {
		eprintln('run_detectors: ${err}')
		exit(2)
	}
	os.chdir(c.repo_root) or {
		eprintln('run_detectors: cannot cd to ${c.repo_root}')
		exit(2)
	}

	// Targets. The base branch is master, else main, else the branch origin/HEAD
	// names: without a fallback a repo whose default branch is main had no base.
	base_branch := default_base_branch()
	mb := if base_branch != '' { git(['merge-base', base_branch, 'HEAD']) or { '' } } else { '' }
	if args.len > 0 {
		c.files = args.map(normalise(c.repo_root, it))
	} else {
		mut set := map[string]bool{}
		for l in (git(['diff', '--name-only', 'HEAD']) or { '' }).split_into_lines() {
			if is_target_kind(l) {
				set[l] = true
			}
		}
		if mb != '' {
			for l in (git(['diff', '--name-only', '${mb}...HEAD']) or { '' }).split_into_lines() {
				if is_target_kind(l) {
					set[l] = true
				}
			}
		}
		c.files = set.keys()
		c.files.sort()
	}
	mut base_from := ''
	if c.base_rev == '' && mb != '' {
		c.base_rev = mb
		base_from = base_branch
	}

	// Temp dir, extraction.
	c.tmp = make_private_dir(temp) or {
		eprintln('run_detectors: ${err}')
		exit(2)
	}
	// From here on every exit goes through c.quit, which removes the folder: V's
	// exit() runs no defer, so a defer left it behind after every flagged run.
	c.scan_root = c.repo_root
	if c.at_rev != '' {
		git(['rev-parse', '--verify', '--quiet', '${c.at_rev}^{commit}']) or {
			eprintln("run_detectors: --at: unknown revision '${c.at_rev}'")
			c.quit(2)
		}
		c.scan_root = os.join_path(c.tmp, 'at')
		mut dirs := map[string]bool{}
		for f in c.files {
			// Each target itself, whatever its kind (a .md doc is in no .v listing).
			c.extract_at(f)
			dirs[os.dir(f)] = true
		}
		for d in dirs.keys() {
			listing := git(['ls-tree', '--name-only', c.at_rev, '--', '${d}/']) or { '' }
			for p in listing.split_into_lines() {
				if p.ends_with('.v') {
					c.extract_at(p)
				}
			}
		}
		c.extract_at('cmd/tools/vtest-self.v')
	}
	mut existing := []string{}
	mut skipped := []string{}
	for f in c.files {
		if f != '' && os.is_file(os.join_path(c.scan_root, f)) {
			existing << f
		} else if args.len > 0 {
			skipped << f
		}
	}
	missing := if c.at_rev != '' { 'not in ${c.at_rev}' } else { 'no such file' }
	if existing.len == 0 {
		for f in skipped {
			eprintln('run_detectors: skipped: ${f} (${missing})')
		}
		eprintln('run_detectors: no target .v or .md files (pass paths explicitly or make changes first)')
		c.quit(2)
	}
	if c.base_rev != '' {
		for f in existing {
			_ = git(['cat-file', '-e', '${c.base_rev}:${f}']) or { continue }
			dst := os.join_path(c.tmp, 'base', f)
			os.mkdir_all(os.dir(dst)) or { continue }
			content := git_raw(['show', '${c.base_rev}:${f}']) or { continue }
			os.write_file(dst, content) or { continue }
			c.base_copy[f] = dst
		}
	}

	// Compile the detectors.
	c.vexe = find_v(c.repo_root, start_dir)
	if c.vexe == '' {
		eprintln('run_detectors: no V compiler found (set DETECT_V, put v on PATH, or run from a repo with ./v)')
		c.quit(2)
	}
	compiler := compiler_id(c.vexe) or {
		eprintln('run_detectors: ${err}')
		c.quit(2)
	}
	det_dir := os.dir(os.real_path(@FILE))
	mut names := manifest.keys()
	names.sort()
	// Only the detectors this run can start are built: a glob names a target, and
	// --only lets the detector run.
	mut needed := map[string]bool{}
	for det in names {
		if c.only != '' && !det.contains(c.only) {
			continue
		}
		globs := manifest[det].split(' ')
		for f in existing {
			bn := os.base(f)
			if globs.any(glob_match(it, bn)) {
				needed[det] = true
				break
			}
		}
	}
	c.compile_needed(det_dir, needed, compiler)

	os.chdir(c.scan_root) or { c.quit(2) }

	// Run.
	mut flagged := 0
	mut ran := 0
	mut errored := []string{}
	mut skipped_all := true
	suffix := if c.at_rev != '' { ' @ ${c.at_rev}' } else { '' }
	mut base_label := if c.base_rev != '' { c.base_rev } else { 'none' }
	if base_from != '' {
		base_label += ' (merge base of ${base_from} and HEAD)'
	}
	println('=== run_detectors: ${existing.len} target file(s)${suffix}, base ${base_label} ===')
	for f in skipped {
		println('--- skipped: ${f} (${missing})')
	}
	for f in existing {
		println('--- target: ${f}')
		bn := os.base(f)
		mut applies := false
		for det in names {
			if !manifest[det].split(' ').any(glob_match(it, bn)) {
				continue
			}
			applies = true
			if c.only != '' && !det.contains(c.only) {
				continue
			}
			bin := c.bins[det] or { continue }
			skipped_all = false
			base := c.base_copy[f] or { '' }
			res := os.exec([bin, f, base])
			ran++
			out := res.output.trim_right('\r\n')
			mut last := ''
			for l in out.split_into_lines().reverse() {
				if l.trim_space() != '' {
					last = l
					break
				}
			}
			label := det + '.v'
			match res.exit_code {
				0 {
					println('  [ OK ] ${label:-46} ${last}')
				}
				1 {
					println('  [FLAG] ${label:-46} ${last}')
					for l in out.split_into_lines() {
						println('         | ${l}')
					}
					flagged++
				}
				else {
					println('  [ERR${res.exit_code}] ${label:-45} ${last}')
					if det !in errored {
						errored << det
					}
				}
			}
		}
		if !applies {
			println('  (no detector applies to this file)')
		}
	}
	mut no_verdict := ''
	if c.unbuilt.len > 0 {
		no_verdict += ', ${c.unbuilt.len} not built: ${c.unbuilt.join(', ')}'
	}
	if errored.len > 0 {
		no_verdict += ', ${errored.len} ended in error: ${errored.join(', ')}'
	}
	println('=== summary: ${ran} detector runs, ${flagged} flagged${no_verdict} ===')
	if no_verdict != '' {
		// What those detectors would have said is unknown, so neither 0 nor 1 is true.
		c.quit(2)
	}
	if skipped_all {
		eprintln('(no detector matched any target file — nothing was checked)')
		c.quit(2)
	}
	c.quit(if flagged > 0 { 1 } else { 0 })
}

// quit removes the per-run folder and ends the run with `code`. V's exit() runs no
// defer, so before rev 122 a flagged or failed run left the folder, with the base
// copies of its targets, in the temp dir. The folder is left from the repo root:
// Windows cannot remove a folder that is the current one (`--at` scans inside it).
@[noreturn]
fn (c &Ctx) quit(code int) {
	os.chdir(c.repo_root) or {}
	os.rmdir_all(c.tmp) or {}
	exit(code)
}

// default_base_branch returns the branch the no-arg target set and the base copies
// are measured from: `master`, else `main`, else the branch `origin/HEAD` names
// (such as `origin/trunk`), or '' when none of them names a commit.
fn default_base_branch() string {
	for cand in ['master', 'main'] {
		if _ := git(['rev-parse', '--verify', '--quiet', '${cand}^{commit}']) {
			return cand
		}
	}
	remote := git(['symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD']) or {
		return ''
	}
	if _ := git(['rev-parse', '--verify', '--quiet', '${remote}^{commit}']) {
		return remote
	}
	return ''
}

// temp_parent returns the temp folder the per-run folder is made in: `TMPDIR` when it is set
// and not empty, else `os.temp_dir()`. On Linux and Windows that is what `os.temp_dir()` returns
// already; on macOS `os.temp_dir()` is always /tmp, shared by every account, while the system
// sets `TMPDIR` to a folder of this account's own. A `TMPDIR` that names no folder makes
// `make_private_dir` fail, and the run stops with exit 2, on macOS as on Linux. A relative one
// is joined to the current folder, except on Windows, where it is left as it is. Not with
// `os.abs_path`: it removes a `..` by text, also one after a link.
fn temp_parent() string {
	mut t := ''
	$if macos {
		t = os.getenv('TMPDIR')
	}
	if t == '' {
		t = os.temp_dir()
	}
	$if !windows {
		if !os.is_abs_path(t) {
			return os.join_path(os.getwd(), t)
		}
	}
	return t
}

// make_private_dir makes a new folder under `parent` that only this user can use
// (mode 0700) and whose name nobody can predict, and fails rather than use a path
// that already exists: in a shared temp folder another account could have made
// the old `run_detectors_<pid>` first, or put a link there. `parent` is resolved once, as
// the system reads it: one absolute path with no link and no `..`. Under --at the runner
// works inside the folder, where a relative path led nowhere (rev 129).
fn make_private_dir(parent string) !string {
	// bytes, not read: read's signature changed between V releases, bytes did not.
	suffix := rand.bytes(8) or { return error('cannot read random bytes: ${err}') }
	path := os.join_path(os.real_path(parent), 'run_detectors_${os.getpid()}_${suffix.hex()}')
	os.mkdir(path, mode: 0o700) or {
		return error('cannot create a private folder ${path}: ${err}')
	}
	return path
}

// is_target_kind reports whether no-arg mode selects a changed path: V sources,
// and Markdown docs for the claims detector.
fn is_target_kind(path string) bool {
	return path.ends_with('.v') || path.ends_with('.md')
}

// glob_match matches a basename against a pattern with at most one `*`.
fn glob_match(pat string, s string) bool {
	star := pat.index('*') or { return pat == s }
	pre := pat[..star]
	suf := pat[star + 1..]
	return s.len >= pre.len + suf.len && s.starts_with(pre) && s.ends_with(suf)
}

fn usage_text() string {
	src := os.read_file(@FILE) or { return 'run_detectors [--base rev] [--at rev] [file...]' }
	mut out := []string{}
	for l in src.split_into_lines()[1..] {
		if !l.starts_with('//') {
			break
		}
		out << l.trim_string_left('//').trim_string_left(' ')
	}
	return out.join('\n')
}

@[noreturn]
fn usage_error(msg string) {
	eprintln('run_detectors: ${msg}')
	exit(2)
}

// git runs git with the given arguments and returns trimmed stdout; a non-zero
// exit is an error.
fn git(args []string) !string {
	mut cmd := ['git']
	cmd << args
	res := os.exec(cmd)
	if res.exit_code != 0 {
		return error(res.output.trim_space())
	}
	return res.output.trim_space()
}

// git_raw is git without trimming (file contents).
fn git_raw(args []string) !string {
	mut cmd := ['git']
	cmd << args
	res := os.exec(cmd)
	if res.exit_code != 0 {
		return error(res.output.trim_space())
	}
	return res.output
}

// resolve_repo_root returns the target repo's toplevel, with the WSL fallback
// for a Windows-created worktree whose .git pointer file holds a drive-letter
// path that Linux git cannot read.
fn resolve_repo_root() !string {
	if root := git(['rev-parse', '--show-toplevel']) {
		return os.real_path(root)
	}
	mut dir := os.real_path(os.getwd())
	for dir != '' && dir != '/' && !dir.ends_with(':\\') {
		dotgit := os.join_path(dir, '.git')
		if os.is_dir(dotgit) {
			break
		}
		if os.is_file(dotgit) {
			content := os.read_file(dotgit) or { break }
			mut gitdir := ''
			for l in content.split_into_lines() {
				if l.starts_with('gitdir:') {
					gitdir = l['gitdir:'.len..].trim_space()
					break
				}
			}
			if gitdir.len > 2 && gitdir[1] == `:` {
				conv := os.exec(['wslpath', '-u', gitdir])
				if conv.exit_code == 0 && conv.output.trim_space() != '' {
					gitdir = conv.output.trim_space()
				} else {
					drive := gitdir[..1].to_lower()
					rest := gitdir[2..].replace('\\', '/').trim_string_left('/')
					gitdir = '/mnt/${drive}/${rest}'
				}
			}
			if os.is_dir(gitdir) {
				os.setenv('GIT_DIR', gitdir, true)
				os.setenv('GIT_WORK_TREE', dir, true)
				if root := git(['rev-parse', '--show-toplevel']) {
					eprintln('run_detectors: resolved Windows worktree gitdir -> ${gitdir}')
					return os.real_path(root)
				}
			}
			break
		}
		parent := os.dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return error('not inside a git repository (run from within the target repo)')
}

// normalise makes a path repo-relative with forward slashes, no CR, no ./.
fn normalise(repo_root string, p0 string) string {
	mut p := p0.replace('\r', '').replace('\\', '/')
	root := repo_root.replace('\\', '/')
	if p.starts_with(root + '/') {
		p = p[root.len + 1..]
	}
	// Under WSL an absolute Windows path may be given for a repo mounted at /mnt.
	if p.len > 2 && p[1] == `:` {
		conv := os.exec(['wslpath', '-u', p])
		if conv.exit_code == 0 {
			p = conv.output.trim_space()
			if p.starts_with(root + '/') {
				p = p[root.len + 1..]
			}
		}
	}
	return p.trim_string_left('./')
}

fn (mut c Ctx) extract_at(p string) {
	git(['cat-file', '-e', '${c.at_rev}:${p}']) or { return }
	dst := os.join_path(c.scan_root, p)
	os.mkdir_all(os.dir(dst)) or { return }
	content := git_raw(['show', '${c.at_rev}:${p}']) or { return }
	os.write_file(dst, content) or { return }
}

// find_v picks the V compiler: $DETECT_V (a name without a separator is looked up on
// PATH, a relative path is from `start_dir`, the folder the run was started in), else
// `v` on PATH, else the target repo's own binary (v.exe on Windows, v elsewhere; never
// a Windows v.exe from Linux), else ''. PATH comes first because a target repo that is
// a V checkout holds the compiler under development there: it would build the review's
// own tools (rev 131).
fn find_v(repo_root string, start_dir string) string {
	env := os.getenv('DETECT_V')
	if env != '' {
		if os.is_abs_path(env) {
			return env
		}
		if env.contains_any('/\\') {
			return os.join_path(start_dir, env)
		}
		return os.find_abs_path_of_executable(env) or { env }
	}
	if on_path := os.find_abs_path_of_executable('v') {
		return on_path
	}
	$if windows {
		for cand in ['v.exe', 'v'] {
			p := os.join_path(repo_root, cand)
			if os.is_file(p) {
				return p
			}
		}
	} $else {
		p := os.join_path(repo_root, 'v')
		if os.is_file(p) && os.is_executable(p) {
			return p
		}
	}
	return ''
}

// compiler_id returns the SHA-256 of the compiler's executable, as hex, for the key of
// the builds it makes. It is the content and not what `v version` prints: a compiler
// built from uncommitted edits prints the same version as a clean one, and some print
// no commit at all. A compiler that cannot be read, or is no regular file (reading a
// FIFO or an endless device would hang the run), is an error.
fn compiler_id(vexe string) !string {
	st := os.stat(vexe) or { return error('cannot read the V compiler ${vexe}: ${err}') }
	if st.get_filetype() != .regular {
		return error('cannot read the V compiler ${vexe}: not a regular file')
	}
	data := os.read_bytes(vexe) or {
		return error('cannot read the V compiler ${vexe}: ${err}')
	}
	return sha256.sum(data).hex()
}

// compile_needed builds each detector named in `needed` (detectors/<stem>.v) once
// into a cache keyed by the hash of its source and of `compiler` (its `compiler_id`), so
// repeated runs do not recompile unchanged detectors. The compiler is read once, before
// the builds: one replaced during the run can leave a build under the old one's key. The
// cache is in the user's own cache folder: a build found there is run as this user, so it
// must not sit where another account can write. A detector whose source cannot be read or
// does not compile has no entry in c.bins and its stem is in c.unbuilt.
fn (mut c Ctx) compile_needed(det_dir string, needed map[string]bool, compiler string) {
	cache := os.join_path(os.cache_dir(), 'review-tools-bin')
	os.mkdir_all(cache, mode: 0o700) or {
		eprintln('run_detectors: cannot create ${cache}: ${err}')
	}
	// Compile from the cache dir, not from the target repo: with the vlang
	// checkout as cwd, V resolves vlib through that checkout, which over a WSL
	// /mnt mount made every compile take ~20 s instead of ~1.5 s.
	os.chdir(cache) or {}
	defer {
		os.chdir(c.repo_root) or {}
	}
	mut stems := needed.keys()
	stems.sort()
	for stem in stems {
		name := stem + '.v'
		src := os.join_path(det_dir, name)
		content := os.read_file(src) or {
			eprintln('run_detectors: cannot read ${src}: ${err}')
			c.unbuilt << stem
			continue
		}
		key := sha256.hexhash('${content}\n${compiler}')[..16]
		mut bin := os.join_path(cache, '${stem}-${key}')
		$if windows {
			bin += '.exe'
		}
		if !os.is_file(bin) {
			res := os.exec([c.vexe, '-o', bin, src])
			if res.exit_code != 0 {
				eprintln('run_detectors: ${name} failed to compile:\n${res.output}')
				c.unbuilt << stem
				continue
			}
		}
		c.bins[stem] = bin
	}
}
