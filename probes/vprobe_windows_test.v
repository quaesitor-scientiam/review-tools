// Tests of `run_limited_windows`, the Windows time limit of vprobe. Run on Windows:
//   v test probes/vprobe_windows_test.v
// The file name ends in `_windows_test.v`, so other systems leave it out. The tests start a copy of
// ping.exe under a name of their own as the program that runs too long, so they can count what is
// left of it by name.
module main

import os
import time

@[typedef]
struct C.JOBOBJECT_EXTENDED_LIMIT_INFORMATION {}

@[typedef]
struct C.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {}

@[typedef]
struct C.STARTUPINFOW {}

@[typedef]
struct C.PROCESS_INFORMATION {}

@[typedef]
struct C.SECURITY_ATTRIBUTES {}

const sleeper_name = 'vprobe_test_sleeper.exe'
const sleeper = os.join_path(os.vtmp_dir(), sleeper_name)

// sleepers counts the copies of the sleeper that are running.
fn sleepers() int {
	r := os.execute('tasklist /FI "IMAGENAME eq ${sleeper_name}" /NH')
	return r.output.count(sleeper_name)
}

// sleep_cmd is a command line that runs the sleeper for about `secs` seconds.
fn sleep_cmd(secs int) string {
	return '"${sleeper}" -n ${secs + 1} 127.0.0.1 >nul'
}

fn testsuite_begin() {
	if os.getenv('VPROBE_TEST_PARENT') == '1' {
		// Started by test_the_tree_ends_when_vprobe_dies: hold a long run open until killed.
		run_limited_windows(sleep_cmd(60), 600000)
		exit(0)
	}
	os.execute('taskkill /F /IM ${sleeper_name}')
	os.cp(os.join_path(os.getenv('SystemRoot'), 'System32', 'PING.EXE'), sleeper) or {
		panic('cannot copy ping.exe: ${err}')
	}
}

fn testsuite_end() {
	os.execute('taskkill /F /IM ${sleeper_name}')
	os.rm(sleeper) or {}
}

fn test_the_structs_have_the_c_layout() {
	assert sizeof(JobLimits) == sizeof(C.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
	assert sizeof(JobAccounting) == sizeof(C.JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)
	assert sizeof(WinStartup) == sizeof(C.STARTUPINFOW)
	assert sizeof(WinProcess) == sizeof(C.PROCESS_INFORMATION)
	assert sizeof(WinSecurity) == sizeof(C.SECURITY_ATTRIBUTES)
}

fn test_kernel32_has_the_job_functions() {
	api := job_api() or {
		assert false, 'kernel32 lacks a job function'
		return
	}
	assert api.query != unsafe { nil }
}

fn test_a_command_runs_as_os_execute_runs_it() {
	for c in ['echo hello "quoted world"', 'cmd /c exit 3', 'cmd /c exit 300',
		'echo out & echo err 1>&2', 'echo %USERPROFILE%', 'nonexistent_cmd_xyz', 'echo ./x'] {
		e := os.execute(c)
		l := run_limited(c)
		assert l.exit_code == e.exit_code, c
		assert l.output == e.output, c
	}
}

fn test_a_hung_command_ends_with_124_and_its_tree() {
	w := time.new_stopwatch()
	r := run_limited_windows(sleep_cmd(30), 2000)
	assert r.exit_code == 124
	assert w.elapsed().milliseconds() < 6000
	assert r.output.contains('vprobe: ended after 2 s')
	time.sleep(300 * time.millisecond)
	assert sleepers() == 0
}

fn test_the_run_waits_for_what_the_command_left_running() {
	w := time.new_stopwatch()
	r := run_limited_windows('start /b "" ${sleep_cmd(2)} & echo started', 20000)
	assert r.exit_code == 0
	assert r.output.contains('started')
	assert w.elapsed().milliseconds() >= 1500
	assert sleepers() == 0
}

fn test_what_the_command_left_running_is_ended_at_the_limit() {
	w := time.new_stopwatch()
	r := run_limited_windows('start /b "" ${sleep_cmd(30)} & echo started', 2000)
	assert r.exit_code == 124
	assert w.elapsed().milliseconds() < 6000
	time.sleep(300 * time.millisecond)
	assert sleepers() == 0
}

fn test_the_tree_ends_when_vprobe_dies() {
	mut p := os.new_process(os.executable())
	// set_environment replaces the environment, so the parent's is passed on with the marker.
	mut env := os.environ()
	env['VPROBE_TEST_PARENT'] = '1'
	p.set_environment(env)
	p.run()
	mut seen := false
	w := time.new_stopwatch()
	for w.elapsed().milliseconds() < 15000 {
		time.sleep(100 * time.millisecond)
		if sleepers() > 0 {
			seen = true
			break
		}
	}
	assert seen
	p.signal_kill()
	p.wait()
	time.sleep(500 * time.millisecond)
	assert sleepers() == 0
}

fn test_runs_at_once_keep_their_own_output() {
	mut ths := []thread os.Result{}
	for i in 0 .. 3 {
		ths << spawn run_limited_windows('echo copy${i}', 20000)
	}
	rs := ths.wait()
	for i, r in rs {
		assert r.exit_code == 0
		assert r.output.trim_space() == 'copy${i}'
	}
}
