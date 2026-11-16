// review_cost.v measures what /vreview and /adversarial-review runs cost, from Claude Code
// session transcripts.
//
// Usage: v run tools/review_cost.v [projects-dir] [--since YYYY-MM-DD] [--list] [--selftest]
//   projects-dir  defaults to ~/.claude/projects
//   --since       the date that splits "recent" runs from older ones (default 2026-10-15)
//   --list        also prints one line per adversarial run
//   --selftest    checks the counting on a small set of made-up transcripts, and exits 1 if
//                 any check fails
//
// A /vreview run starts at a typed /vreview (or /review-tools:vreview) command or a Skill call
// of that skill, and ends at the first end of turn or the next message from the user. Subagents
// started inside that window count toward it. An /adversarial-review run is one Workflow run
// whose name, summary or script mentions "adversarial"; its cost is every subagent transcript
// under subagents/workflows/<runId>/. The main session's own work around a workflow (writing
// the script, reading the findings) is not counted.
//
// Weighted cost counts plain input as 1, cache writes as 1.25 (5 minute) or 2 (1 hour), cache
// reads as 0.1 and output as 5, in input-token units.
module main

import json2
import os
import time

struct Usage {
mut:
	calls      int
	out        i64
	new_in     i64
	cache_read i64
	weighted   f64
}

fn (mut s Usage) add(u map[string]json2.Any) {
	inp := get_i64(u, 'input_tokens')
	cc := get_i64(u, 'cache_creation_input_tokens')
	cr := get_i64(u, 'cache_read_input_tokens')
	out := get_i64(u, 'output_tokens')
	mut c1h := i64(0)
	if cache := u['cache_creation'] {
		c1h = get_i64(cache.as_map(), 'ephemeral_1h_input_tokens')
	}
	s.calls++
	s.out += out
	s.new_in += inp + cc
	s.cache_read += cr
	s.weighted += f64(inp) + 1.25 * f64(cc - c1h) + 2.0 * f64(c1h) + 0.1 * f64(cr) + 5.0 * f64(out)
}

struct Run {
	date string
	name string
mut:
	cost Usage
}

fn get_i64(m map[string]json2.Any, key string) i64 {
	if v := m[key] {
		return v.i64()
	}
	return 0
}

fn get_str(m map[string]json2.Any, key string) string {
	if v := m[key] {
		if v is string {
			return v
		}
	}
	return ''
}

fn get_bool(m map[string]json2.Any, key string) bool {
	if v := m[key] {
		if v is bool {
			return v
		}
	}
	return false
}

fn read_jsonl(path string) []map[string]json2.Any {
	text := os.read_file(path) or { return [] }
	mut out := []map[string]json2.Any{}
	for line in text.split_into_lines() {
		if line.trim_space() == '' {
			continue
		}
		v := json2.decode[json2.Any](line) or { continue }
		out << v.as_map()
	}
	return out
}

fn walk_files(dir string) []string {
	mut out := []string{}
	names := os.ls(dir) or { return out }
	for name in names {
		p := os.join_path(dir, name)
		if os.is_dir(p) && !os.is_link(p) {
			out << walk_files(p)
		} else {
			out << p
		}
	}
	return out
}

fn message_of(e map[string]json2.Any) map[string]json2.Any {
	if m := e['message'] {
		return m.as_map()
	}
	return map[string]json2.Any{}
}

fn content_blocks(e map[string]json2.Any) []map[string]json2.Any {
	msg := message_of(e)
	mut out := []map[string]json2.Any{}
	if c := msg['content'] {
		if c is []json2.Any {
			for b in c {
				out << b.as_map()
			}
		}
	}
	return out
}

fn text_of(e map[string]json2.Any) string {
	msg := message_of(e)
	if c := msg['content'] {
		if c is string {
			return c
		}
	}
	mut parts := []string{}
	for b in content_blocks(e) {
		if get_str(b, 'type') == 'text' {
			parts << get_str(b, 'text')
		}
	}
	return parts.join('\n')
}

fn timestamp_of(e map[string]json2.Any) i64 {
	ts := get_str(e, 'timestamp')
	if ts == '' {
		return -1
	}
	t := time.parse_iso8601(ts) or { return -1 }
	return t.unix_milli()
}

fn is_vreview_name(name string) bool {
	n := name.trim_space().trim_left('/')
	return n == 'vreview' || n.ends_with(':vreview')
}

fn command_name(text string) string {
	start := text.index('<command-name>') or { return '' }
	rest := text[start + '<command-name>'.len..]
	end := rest.index('</command-name>') or { return '' }
	return rest[..end]
}

// is_user_prompt reports whether an entry is a message the user typed, not a tool result,
// hook feedback, injected reminder or skill body.
fn is_user_prompt(e map[string]json2.Any) bool {
	if get_str(e, 'type') != 'user' || get_bool(e, 'isMeta') || get_bool(e, 'isCompactSummary') {
		return false
	}
	for b in content_blocks(e) {
		if get_str(b, 'type') == 'tool_result' {
			return false
		}
	}
	t := text_of(e).trim_space()
	if t == '' {
		return false
	}
	// A typed command: a built-in one starts with `<command-name>`, a skill with
	// `<command-message>`.
	if t.starts_with('<command-') && command_name(t) != '' {
		return true
	}
	if t.starts_with('<') {
		return false
	}
	for p in ['Stop hook', '[Request interrupted', 'This session is being continued', 'Caveat:'] {
		if t.starts_with(p) {
			return false
		}
	}
	return true
}

// stop_blocked reports whether the turn goes on after the end of turn at entries[at]: a Stop
// hook that blocks the stop adds its feedback as a user entry (marked isMeta), and the reply
// after it belongs to the same turn.
fn stop_blocked(entries []map[string]json2.Any, at int) bool {
	for e in entries[at + 1..] {
		kind := get_str(e, 'type')
		if kind == 'assistant' {
			return false
		}
		if kind != 'user' {
			continue
		}
		if text_of(e).trim_space().starts_with('Stop hook') {
			return true
		}
		if !get_bool(e, 'isMeta') {
			return false
		}
	}
	return false
}

fn is_vreview_start(e map[string]json2.Any) bool {
	kind := get_str(e, 'type')
	if kind == 'user' && !get_bool(e, 'isMeta') {
		name := command_name(text_of(e))
		if name != '' && is_vreview_name(name) {
			return true
		}
	}
	if kind == 'assistant' {
		for b in content_blocks(e) {
			if get_str(b, 'type') == 'tool_use' && get_str(b, 'name') == 'Skill' {
				if input := b['input'] {
					if is_vreview_name(get_str(input.as_map(), 'skill')) {
						return true
					}
				}
			}
		}
	}
	return false
}

// add_usage adds each model call once. A streamed reply repeats its usage on several entries,
// and only the last one has the final output count, so the last entry per call wins.
fn add_usage(mut cost Usage, entries []map[string]json2.Any) {
	mut last := map[string]map[string]json2.Any{}
	mut order := []string{}
	for e in entries {
		if get_str(e, 'type') != 'assistant' {
			continue
		}
		msg := message_of(e)
		u := msg['usage'] or { continue }
		mut key := get_str(e, 'requestId')
		if key == '' {
			key = get_str(msg, 'id')
		}
		if key == '' {
			key = get_str(e, 'uuid')
		}
		if key !in last {
			order << key
		}
		last[key] = u.as_map()
	}
	for key in order {
		cost.add(last[key])
	}
}

fn date_of(ms i64) string {
	return time.unix_milli(ms).ymmdd()
}

fn adversarial_runs(files []string) []Run {
	mut runs := []Run{}
	sep := os.path_separator
	for f in files {
		if !f.ends_with('.json') || f.contains('${sep}subagents${sep}') {
			continue
		}
		if os.file_name(os.dir(f)) != 'workflows' || !os.file_name(f).starts_with('wf_') {
			continue
		}
		text := os.read_file(f) or { continue }
		j := (json2.decode[json2.Any](text) or { continue }).as_map()
		script := get_str(j, 'script')
		label := '${get_str(j, 'workflowName')} ${get_str(j, 'summary')} ${script#[..400]}'
		if !label.to_lower().contains('adversarial') {
			continue
		}
		mut start := get_i64(j, 'startTime')
		if start == 0 {
			t := time.parse_iso8601(get_str(j, 'timestamp')) or { time.Time{} }
			start = t.unix_milli()
		}
		mut run := Run{
			date: date_of(start)
			name: get_str(j, 'workflowName')
		}
		wf_dir := os.join_path(os.dir(os.dir(f)), 'subagents', 'workflows', get_str(j, 'runId'))
		if os.is_dir(wf_dir) {
			for p in walk_files(wf_dir) {
				if p.ends_with('.jsonl') {
					add_usage(mut run.cost, read_jsonl(p))
				}
			}
		}
		if run.cost.calls > 0 {
			runs << run
		}
	}
	return runs
}

struct Sub {
	entries []map[string]json2.Any
	start   i64
}

fn vreview_runs(files []string) []Run {
	mut runs := []Run{}
	sep := os.path_separator
	for f in files {
		if !f.ends_with('.jsonl') || f.contains('${sep}subagents${sep}') {
			continue
		}
		es := read_jsonl(f)
		if !es.any(is_vreview_start(it)) {
			continue
		}
		sub_dir := os.join_path(os.dir(f), os.file_name(f).all_before_last('.'), 'subagents')
		mut subs := []Sub{}
		if os.is_dir(sub_dir) {
			for p in walk_files(sub_dir) {
				if !p.ends_with('.jsonl') || p.contains('${sep}workflows${sep}') {
					continue
				}
				x := read_jsonl(p)
				mut t := i64(-1)
				for e in x {
					t = timestamp_of(e)
					if t >= 0 {
						break
					}
				}
				subs << Sub{x, t}
			}
		}
		mut i := 0
		for i < es.len {
			if !is_vreview_start(es[i]) {
				i++
				continue
			}
			mut end := es.len
			for j in i + 1 .. es.len {
				if is_user_prompt(es[j]) {
					end = j
					break
				}
				if get_str(es[j], 'type') == 'assistant'
					&& get_str(message_of(es[j]), 'stop_reason') == 'end_turn'
					&& !stop_blocked(es, j) {
					end = j + 1
					break
				}
			}
			window := es[i..end]
			mut t0 := i64(-1)
			mut t1 := i64(-1)
			for e in window {
				t := timestamp_of(e)
				if t < 0 {
					continue
				}
				if t0 < 0 || t < t0 {
					t0 = t
				}
				if t > t1 {
					t1 = t
				}
			}
			mut run := Run{
				date: date_of(t0)
				name: os.file_name(f)
			}
			add_usage(mut run.cost, window)
			for s in subs {
				if s.start >= t0 && s.start <= t1 {
					add_usage(mut run.cost, s.entries)
				}
			}
			if run.cost.calls > 0 {
				runs << run
			}
			i = end
		}
	}
	return runs
}

fn median(values []f64) f64 {
	if values.len == 0 {
		return 0
	}
	mut v := values.clone()
	v.sort()
	m := v.len / 2
	return if v.len % 2 == 1 { v[m] } else { (v[m - 1] + v[m]) / 2 }
}

fn human(n f64) string {
	if n >= 1_000_000 {
		return '${n / 1_000_000:.2f}M'
	}
	if n >= 1000 {
		return '${n / 1000:.0f}K'
	}
	return '${n:.0f}'
}

struct Column {
	runs        int
	recent      int
	calls       string
	out         string
	new_in      string
	weighted    string
	recent_line string
}

fn column(runs []Run, since string) Column {
	recent := runs.filter(it.date >= since)
	rw := recent.map(it.cost.weighted)
	mut lo := 0.0
	mut hi := 0.0
	if rw.len > 0 {
		mut s := rw.clone()
		s.sort()
		lo = s[0]
		hi = s[s.len - 1]
	}
	return Column{
		runs:        runs.len
		recent:      recent.len
		calls:       human(median(runs.map(f64(it.cost.calls))))
		out:         human(median(runs.map(f64(it.cost.out))))
		new_in:      human(median(runs.map(f64(it.cost.new_in))))
		weighted:    human(median(runs.map(it.cost.weighted)))
		recent_line: '${human(median(rw))} median (${human(lo)} to ${human(hi)})'
	}
}

fn main() {
	mut args := os.args[1..].clone()
	mut since := '2026-10-15'
	mut list := false
	mut root := os.join_path(os.home_dir(), '.claude', 'projects')
	mut i := 0
	for i < args.len {
		a := args[i]
		if a == '--since' && i + 1 < args.len {
			since = args[i + 1]
			i += 2
			continue
		}
		if a == '--selftest' {
			exit(selftest())
		}
		if a == '--list' {
			list = true
		} else if a == '-h' || a == '--help' {
			println('usage: v run tools/review_cost.v [projects-dir] [--since YYYY-MM-DD] [--list] [--selftest]')
			return
		} else {
			root = a
		}
		i++
	}
	if !os.is_dir(root) {
		eprintln('review_cost: no such folder: ${root}')
		exit(1)
	}
	files := walk_files(root)
	v := column(vreview_runs(files), since)
	adv_runs := adversarial_runs(files)
	a := column(adv_runs, since)
	println('| | vreview | adversarial-review |')
	println('| --- | --- | --- |')
	println('| Runs found | ${v.runs} | ${a.runs} (${a.recent} since ${since}) |')
	println('| Median model calls | ${v.calls} | ${a.calls} |')
	println('| Median output tokens | ${v.out} | ${a.out} |')
	println('| Median new input | ${v.new_in} | ${a.new_in} |')
	println('| Median weighted cost | ${v.weighted} | ${a.weighted} |')
	println('| Recent runs (${since}+) | ${v.recent_line} | ${a.recent_line} |')
	if list {
		println('')
		mut sorted := adv_runs.clone()
		sorted.sort(a.date < b.date)
		for r in sorted {
			println('${r.date} calls ${r.cost.calls} out ${human(f64(r.cost.out))} new ${human(f64(r.cost.new_in))} weighted ${human(r.cost.weighted)} ${r.name}')
		}
	}
}

// selftest writes a small set of transcripts with known token counts to a temporary folder and
// checks what the tool counts from them. It returns the exit code: 0 when every check passes.
fn selftest() int {
	root := os.join_path(os.temp_dir(), 'review_cost_selftest_${os.getpid()}')
	os.rmdir_all(root) or {}
	defer {
		os.rmdir_all(root) or {}
	}
	command := st_user('00:00', '<command-message>vreview</command-message><command-name>/vreview</command-name>',
		false)
	// a: a streamed call (two entries of r1), a subagent, a workflow, and after the end of the
	// turn a hidden reminder, a turn started by a background task (r4), and a typed prompt.
	st_write(os.join_path(root, 'p', 'a.jsonl'), [command, st_assistant('00:01', 'r1', '', 10, 1),
		st_assistant('00:02', 'r1', 'tool_use', 10, 5), st_tool_result('00:03'),
		st_assistant('00:10', 'r2', 'end_turn', 100, 50), st_user('00:30', 'a reminder', true),
		st_user('00:31', '<task-notification>done</task-notification>', false),
		st_assistant('00:32', 'r4', 'end_turn', 2000, 0), st_user('01:00', 'hi', false),
		st_assistant('01:01', 'r3', 'end_turn', 1000, 0)])
	st_write(os.join_path(root, 'p', 'a', 'subagents', 'agent-1.jsonl'), [
		st_assistant('00:05', 's1', 'end_turn', 7, 1),
	])
	st_write(os.join_path(root, 'p', 'a', 'workflows', 'wf_t.json'), [
		'{"workflowName":"adversarial-review-t","summary":"","script":"","runId":"wf_t","startTime":1763200800000}',
	])
	st_write(os.join_path(root, 'p', 'a', 'subagents', 'workflows', 'wf_t', 'agent-2.jsonl'), [
		st_assistant('00:06', 'w1', 'end_turn', 1000, 100),
	])
	// b: a Stop hook blocks the end of the turn, and the reply after its feedback is the same turn.
	st_write(os.join_path(root, 'p', 'b.jsonl'), [command, st_assistant('00:01', 'b1', 'end_turn',
		10, 0), st_user('00:02', 'Stop hook feedback: add the missing sections', true),
		st_assistant('00:03', 'b2', 'end_turn', 20, 0), st_user('01:00', 'next', false),
		st_assistant('01:01', 'b3', 'end_turn', 500, 0)])
	// c: an interrupted /vreview, then a typed /vreview: two runs.
	st_write(os.join_path(root, 'p', 'c.jsonl'), [command, st_assistant('00:01', 'c1', 'tool_use',
		100, 0), st_interrupted('00:02'), st_user('05:00', '<command-message>vreview</command-message><command-name>/vreview</command-name>',
		false), st_assistant('05:01', 'c2', 'end_turn', 1000, 0)])
	files := walk_files(root)
	vreview := vreview_runs(files)
	adversarial := adversarial_runs(files)
	a := vreview.filter(it.name == 'a.jsonl')
	b := vreview.filter(it.name == 'b.jsonl')
	c := vreview.filter(it.name == 'c.jsonl')
	mut failed := 0
	failed += st_check('a streamed call counts once, a subagent counts, a workflow does not, the run ends with its turn',
		a.len == 1 && a[0].cost.calls == 3 && a[0].cost.out == 56 && a[0].cost.new_in == 117
			&& a[0].cost.weighted == 397.0, a)
	failed += st_check("a workflow's subagents make one adversarial run", adversarial.len == 1
		&& adversarial[0].cost.calls == 1 && adversarial[0].cost.out == 100
		&& adversarial[0].cost.weighted == 1500.0, adversarial)
	failed += st_check('the reply after a Stop hook blocks the end of the turn belongs to the run',
		b.len == 1 && b[0].cost.calls == 2 && b[0].cost.weighted == 30.0, b)
	failed += st_check('a typed /vreview after an interrupted one starts a run of its own', c.len == 2
		&& c[0].cost.weighted == 100.0 && c[1].cost.weighted == 1000.0, c)
	println(if failed == 0 {
		'selftest: all checks pass'
	} else {
		'selftest: ${failed} check(s) fail'
	})
	return if failed == 0 { 0 } else { 1 }
}

fn st_check(name string, ok bool, runs []Run) int {
	if ok {
		println('ok    ${name}')
		return 0
	}
	got := runs.map('${it.cost.calls} calls, ${it.cost.weighted:.0f} weighted').join('; ')
	println('FAIL  ${name}: got ${runs.len} run(s): ${got}')
	return 1
}

fn st_write(path string, lines []string) {
	os.mkdir_all(os.dir(path)) or { panic(err) }
	os.write_file(path, lines.join('\n') + '\n') or { panic(err) }
}

fn st_user(ts string, text string, meta bool) string {
	m := if meta { ',"isMeta":true' } else { '' }
	return '{"type":"user"${m},"timestamp":"2026-11-15T10:${ts}.000Z","message":{"role":"user","content":"${text}"}}'
}

fn st_tool_result(ts string) string {
	return '{"type":"user","timestamp":"2026-11-15T10:${ts}.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}'
}

fn st_interrupted(ts string) string {
	return '{"type":"user","timestamp":"2026-11-15T10:${ts}.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}'
}

fn st_assistant(ts string, request string, stop string, input int, output int) string {
	return '{"type":"assistant","timestamp":"2026-11-15T10:${ts}.000Z","requestId":"${request}","message":{"id":"${request}","stop_reason":"${stop}","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":${input},"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":${output}}}}'
}
