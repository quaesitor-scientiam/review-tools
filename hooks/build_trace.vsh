#!/usr/bin/env -S v

// build_trace builds hooks/require_trace.v into bin/require_trace.exe (that name on every
// system) when the binary is missing or was built from other source text: the SHA-256 of the
// source it was built from is kept in bin/require_trace.src.sha256. (A modification time counts
// whole seconds, and a checkout can give older text an older time.) hooks.json runs it at session
// start, with `v` started directly, so the PreToolUse hook that runs the binary finds a current
// one. It prints nothing when the binary is current or was built, and a warning when the build
// fails: Claude Code cannot start a missing hook binary, so until a build succeeds writes of
// scratchpad scripts go unchecked. It always exits 0, so a failed build never stops a session.
//
// It builds into a temporary file and then moves that into place, so a hook never runs a
// half-written binary.

import crypto.sha256
import os

const root = os.real_path(os.join_path(@DIR, '..'))
const src = os.join_path(root, 'hooks', 'require_trace.v')
const bin = os.join_path(root, 'bin', 'require_trace.exe')
const stamp = os.join_path(root, 'bin', 'require_trace.src.sha256')

source := os.read_file(src) or {
	println('review-tools: cannot read ${src}: ${err}; scratchpad scripts are not checked')
	exit(0)
}
want := sha256.hexhash(source)
if os.is_file(bin) && (os.read_file(stamp) or { '' }).trim_space() == want {
	exit(0)
}
os.mkdir_all(os.dir(bin)) or {
	println('review-tools: cannot make ${os.dir(bin)}: ${err}; scratchpad scripts are not checked')
	exit(0)
}
// The name ends in .exe, as V on Windows adds .exe to an output name without it.
tmp := os.join_path(os.dir(bin), 'require_trace.${os.getpid()}.tmp.exe')
res := os.exec([@VEXE, '-o', tmp, src])
if res.exit_code != 0 || !os.is_file(tmp) {
	os.rm(tmp) or {}
	then := if os.is_file(bin) {
		'the previous build of it stays in use'
	} else {
		'scratchpad scripts are not checked this session'
	}
	println('review-tools: building the trace hook failed (exit ${res.exit_code}); ${then}:')
	println(res.output.trim_space().split_into_lines()#[..10].join('\n'))
	exit(0)
}
// On macOS and Linux the rename replaces the binary in one step. Where it cannot replace an
// existing file (Windows), the old binary is removed first, and a hook that starts in between
// finds no binary and checks nothing; a binary a running hook holds open is kept.
os.mv(tmp, bin) or {
	if os.is_file(bin) {
		os.rm(bin) or {
			os.rm(tmp) or {}
			println('review-tools: the trace hook binary is in use and was not replaced: ${err}')
			exit(0)
		}
	}
	os.mv(tmp, bin) or {
		os.rm(tmp) or {}
		println('review-tools: cannot move the built trace hook into place: ${err}; scratchpad scripts are not checked')
		exit(0)
	}
}
// The stamp names the source the binary now holds; without it the next session rebuilds.
os.write_file(stamp, want + '\n') or {}
