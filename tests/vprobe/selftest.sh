#!/usr/bin/env bash
# Self-test of probes/vprobe.v. Each case states what the probe must print for an input whose
# right answer is known. A probe that gives the wrong verdict, or that ends "nothing flagged"
# for something it did not run, fails here.
#
# Usage: bash tests/vprobe/selftest.sh [path/to/v]      (Linux, WSL or macOS; not git-bash)
# The V compiler is the argument, else $DETECT_V, else `v` on PATH.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
V=${1:-${DETECT_V:-v}}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/vprobe-selftest.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export V_C_ERROR_BUG_REPORT_DISABLED=1

if ! "$V" -w -o "$tmp/vprobe" "$repo/probes/vprobe.v" > "$tmp/build.log" 2>&1; then
  echo "FAIL: probes/vprobe.v does not build"
  grep -m3 'error' "$tmp/build.log"
  exit 1
fi
P="$tmp/vprobe"
fails=0
cases=0

# expect <case> <wanted exit> <output file> <actual exit>
expect_exit() {
  cases=$((cases + 1))
  if [ "$4" != "$2" ]; then
    echo "FAIL $1: exit $4, wanted $2"
    sed 's/^/    | /' "$3" | head -12
    fails=$((fails + 1))
  fi
}
# has <case> <output file> <extended regex that must match>
has() {
  cases=$((cases + 1))
  if ! grep -Eq -- "$3" "$2"; then
    echo "FAIL $1: no line matches: $3"
    sed 's/^/    | /' "$2" | head -12
    fails=$((fails + 1))
  fi
}
# lacks <case> <output file> <extended regex that must not match>
lacks() {
  cases=$((cases + 1))
  if grep -Eq -- "$3" "$2"; then
    echo "FAIL $1: a line matches: $3"
    grep -E -- "$3" "$2" | sed 's/^/    | /' | head -4
    fails=$((fails + 1))
  fi
}
same_file() {
  cases=$((cases + 1))
  if [ "$(cat "$2")" != "$3" ]; then
    echo "FAIL $1: $2 was not restored"
    fails=$((fails + 1))
  fi
}

# ---------------------------------------------------------------- mutate
m="$tmp/m"
mkdir -p "$m"
src="$m/dummy.txt"
mutants_abc='[
  {"file": "'$src'", "line": 1, "find": "a", "replace": "b", "note": "really fails"},
  {"file": "'$src'", "line": 1, "find": "a", "replace": "aa", "note": "still passes"},
  {"file": "'$src'", "line": 1, "find": "zzz", "replace": "y", "note": "text not on the line"}]'

# A failure inside a helper function is a kill, named by that function.
cat > "$m/helper.sh" <<EOF
grep -q a "$src" || { echo "x_test.v:12: fn check_helper"; exit 1; }
EOF
echo a > "$src"
echo '{"test": "sh '$m'/helper.sh", "mutants": '"$mutants_abc"'}' > "$m/helper.json"
"$P" mutate "$m/helper.json" > "$m/helper.out" 2>&1
expect_exit helper 1 "$m/helper.out" $?
has helper "$m/helper.out" 'really fails\) \| KILLED by check_helper'
has helper "$m/helper.out" 'still passes\) \| \*\*SURVIVED\*\*'
has helper "$m/helper.out" 'INVALID: the text occurs 0 times'
has helper "$m/helper.out" '^1 could not be tested'
same_file helper "$src" a

# A test that fails in only some runs of the same code shows no kill.
cat > "$m/flaky.sh" <<EOF
n=\$(cat "$m/count" 2>/dev/null || echo 0)
echo \$((n + 1)) > "$m/count"
rc=0
if [ "\$n" -eq 3 ] || [ "\$n" -eq 6 ]; then echo "x_test.v:1: fn test_flaky"; rc=1; fi
if ! grep -q a "$src"; then echo "x_test.v:2: fn test_real"; rc=1; fi
exit \$rc
EOF
echo a > "$src"
rm -f "$m/count"
echo '{"test": "sh '$m'/flaky.sh", "control_may_fail": true, "mutants": [
  {"file": "'$src'", "line": 1, "find": "a", "replace": "aa", "note": "passes one"},
  {"file": "'$src'", "line": 1, "find": "a", "replace": "ab", "note": "passes two"},
  {"file": "'$src'", "line": 1, "find": "a", "replace": "b", "note": "really fails"},
  {"file": "'$src'", "line": 1, "find": "a", "replace": "ac", "note": "passes three"}]}' > "$m/flaky.json"
"$P" mutate "$m/flaky.json" > "$m/flaky.out" 2>&1
expect_exit flaky 1 "$m/flaky.out" $?
has flaky "$m/flaky.out" '^FLAKY.*test_flaky'
has flaky "$m/flaky.out" 'really fails\) \| KILLED by test_real'
lacks flaky "$m/flaky.out" 'KILLED by test_flaky'
has flaky "$m/flaky.out" '^3 survived'
same_file flaky "$src" a

# A test that fails whenever the file is edited shows no kill.
cat > "$m/edit.sh" <<EOF
rc=0
if [ "\$(cat "$src")" != "a" ]; then echo "x_test.v:1: fn test_hashes_source"; rc=1; fi
if ! grep -q a "$src"; then echo "x_test.v:2: fn test_real"; rc=1; fi
exit \$rc
EOF
echo a > "$src"
echo '{"test": "sh '$m'/edit.sh", "mutants": [
  {"file": "'$src'", "line": 1, "find": "a", "replace": "aa", "note": "only the source test fails"},
  {"file": "'$src'", "line": 1, "find": "a", "replace": "b", "note": "really fails"}]}' > "$m/edit.json"
"$P" mutate "$m/edit.json" > "$m/edit.out" 2>&1
expect_exit edit 1 "$m/edit.out" $?
has edit "$m/edit.out" '^Failing whenever the file is edited.*test_hashes_source'
has edit "$m/edit.out" 'only the source test fails\) \| \*\*SURVIVED\*\*'
has edit "$m/edit.out" 'really fails\) \| KILLED by test_real'

# A hang and a crash are kills, also when a test that was already red printed its name first.
cat > "$m/hang.sh" <<EOF
echo "x_test.v:1: fn test_always_red"
if grep -q a "$src"; then exit 1; fi
if grep -q b "$src"; then exit 124; fi
echo "V panic: substr(71, 14) out of bounds"
exit 1
EOF
echo a > "$src"
echo '{"test": "sh '$m'/hang.sh", "control_may_fail": true, "mutants": [
  {"file": "'$src'", "line": 1, "find": "a", "replace": "b", "note": "times out"},
  {"file": "'$src'", "line": 1, "find": "a", "replace": "c", "note": "panics"},
  {"file": "'$src'", "line": 1, "find": "a", "replace": "aa", "note": "only the red test"}]}' > "$m/hang.json"
"$P" mutate "$m/hang.json" > "$m/hang.out" 2>&1
expect_exit hang 1 "$m/hang.out" $?
has hang "$m/hang.out" 'times out\) \| KILLED \(exit 124'
has hang "$m/hang.out" 'panics\) \| KILLED \(the tests crashed: V panic'
has hang "$m/hang.out" 'only the red test\) \| \*\*SURVIVED\*\*'

# Tests that are red without a mutant stop the run, unless the spec allows judging by names.
echo '{"test": "exit 1", "mutants": [{"file": "'$src'", "line": 1, "find": "a", "replace": "b"}]}' > "$m/red.json"
"$P" mutate "$m/red.json" > "$m/red.out" 2>&1
expect_exit red 2 "$m/red.out" $?
has red "$m/red.out" 'fails before any mutant'

# Mutants that could not be applied are not a clean result.
echo '{"test": "true", "mutants": [{"file": "'$src'", "line": 9, "find": "a", "replace": "b"}]}' > "$m/invalid.json"
"$P" mutate "$m/invalid.json" > "$m/invalid.out" 2>&1
expect_exit invalid 1 "$m/invalid.out" $?
has invalid "$m/invalid.out" '^1 could not be tested'

# The mutants of a named function: one per clause, one per early-return guard.
cat > "$m/pred.v" <<'EOF'
module main

fn is_lock_name(name string) bool {
	if !name.starts_with('.') || !name.ends_with('.lock') {
		return false
	}
	if name.len < 7 {
		return false
	}
	return name.len > 6 && name[1] != `.`
}
EOF
echo '{"test": "true", "source": "'$m'/pred.v", "functions": ["is_lock_name"]}' > "$m/list.json"
"$P" mutate "$m/list.json" --list > "$m/list.out" 2>&1
expect_exit list 0 "$m/list.out" $?
has list "$m/list.out" "pred.v:4 \| \`!name.starts_with\('.'\) \|\| \`"
has list "$m/list.out" "pred.v:4 \| \` \|\| !name.ends_with\('.lock'\)\`"
has list "$m/list.out" 'pred.v:7 .* -> `if false \{` \(is_lock_name: guard never fires\)'
has list "$m/list.out" 'pred.v:10 \| `name.len > 6 && `'
has list "$m/list.out" 'pred.v:10 \| ` && name\[1\] != `.``'

# ---------------------------------------------------------------- matrix
x="$tmp/x"
mkdir -p "$x"
# base removes everything in cache; head keeps names ending in .keep and stops at a bare ".keep".
cat > "$x/base.sh" <<'EOF'
rm -rf "$1/cache" && mkdir "$1/cache"
echo "cache wiped"
EOF
cat > "$x/head.sh" <<'EOF'
[ -f "$1/cache/.keep" ] && { echo "panic: bare name"; exit 3; }
find "$1/cache" -mindepth 1 -maxdepth 1 ! -name '*.keep' -exec rm -rf {} +
echo "cache wiped"
EOF
echo '{"base": "'$x'/base.sh", "head": "'$x'/head.sh", "cmd": "sh {bin} {root}",
  "setup": "mkdir -p {root}/cache && echo old > {root}/cache/old.txt", "work": "'$x'/work",
  "places": ["private: cache"],
  "shapes": [{"at": "cache", "label": "private, name", "shape": "{name}.keep", "values": {"name": "x"}}]}' > "$x/matrix.json"
"$P" matrix "$x/matrix.json" > "$x/matrix.out" 2>&1
expect_exit matrix 1 "$x/matrix.out" $?
has matrix "$x/matrix.out" 'private, name \| own_file \| 0 removed \| 0 kept \| DIFF object: base removed, head kept \| cache/x.keep'
has matrix "$x/matrix.out" 'DIFF exit: base 0, head 3.*cache/\.keep'
lacks matrix "$x/matrix.out" '\| private \| own_file \|'
has matrix "$x/matrix.out" 'NOT RUN: the other-owner kinds'

# A cell that did not run is not a clean cell.
echo '{"base": "'$x'/base.sh", "head": "'$x'/head.sh", "cmd": "sh {bin} {root}", "setup": "exit 7",
  "work": "'$x'/work_skip", "places": ["private: cache"]}' > "$x/skip.json"
"$P" matrix "$x/skip.json" > "$x/skip.out" 2>&1
expect_exit skipped 1 "$x/skip.out" $?
has skipped "$x/skip.out" 'NOT RUN: setup failed'

# One cell that could not be placed is enough: the two builds agree everywhere else.
echo '{"base": "'$x'/base.sh", "head": "'$x'/base.sh", "cmd": "sh {bin} {root}",
  "setup": "mkdir -p {root}/cache && echo old > {root}/cache/old.txt", "work": "'$x'/work_occupied",
  "kinds": ["own_file"], "named": ["private: cache/old.txt"]}' > "$x/occupied.json"
"$P" matrix "$x/occupied.json" > "$x/occupied.out" 2>&1
expect_exit occupied 1 "$x/occupied.out" $?
has occupied "$x/occupied.out" 'cache/old.txt \| own_file: not placed: something is already at that path'
has occupied "$x/occupied.out" '\(0 flagged, 0 same\)'

# A difference in the control run alone (nothing placed) is flagged too.
echo '{"base": "'$x'/base.sh", "head": "'$x'/head.sh", "cmd": "sh {bin} {root}",
  "setup": "mkdir -p {root}/cache && touch {root}/cache/.keep", "work": "'$x'/work_control"}' > "$x/control.json"
"$P" matrix "$x/control.json" > "$x/control.out" 2>&1
expect_exit control 1 "$x/control.out" $?
has control "$x/control.out" 'DIFF exit: base 0, head 3'

# The work folder must be the probe's own: an existing `root` in a foreign folder is not deleted.
mkdir -p "$x/foreign/root"
echo precious > "$x/foreign/root/data"
echo '{"base": "'$x'/base.sh", "head": "'$x'/head.sh", "cmd": "sh {bin} {root}", "work": "'$x'/foreign",
  "places": ["private: cache"]}' > "$x/foreign.json"
"$P" matrix "$x/foreign.json" > "$x/foreign.out" 2>&1
expect_exit foreign 2 "$x/foreign.out" $?
has foreign "$x/foreign.out" 'was not made by vprobe'
same_file foreign "$x/foreign/root/data" precious

# ---------------------------------------------------------------- race
r="$tmp/r"
mkdir -p "$r"
# Two copies cannot both hold the folder: one of them fails in every round.
cat > "$r/head.sh" <<'EOF'
mkdir "$1/held" || { echo "could not take $1/held"; exit 1; }
sleep 0.3
rmdir "$1/held"
EOF
echo '{"head": "'$r'/head.sh", "cmd": "sh {bin} {root}", "work": "'$r'/work", "copies": 2, "rounds": 3,
  "actor": "false"}' > "$r/race.json"
"$P" race "$r/race.json" > "$r/race.out" 2>&1
expect_exit race 1 "$r/race.out" $?
has race "$r/race.out" 'rounds with a failing copy: 3/3'
has race "$r/race.out" 'could not take \{root\}/held'
has race "$r/race.out" 'the other party \(actor, in_pause\): [0-9]+ runs, [1-9][0-9]* failed'

# A held-open window: the program stops at the pause, the other party acts, the program sees it.
h="$tmp/h"
mkdir -p "$h/src"
cat > "$h/src/prog.v" <<'EOF'
module main

import os

fn main() {
	marker := os.join_path(os.args[1], 'marker')
	seen := os.exists(marker)
	println(if seen { 'the marker was there' } else { 'no marker' })
}
EOF
echo '{"head": "'$h'/prog", "cmd": "{bin} {root}", "work": "'$h'/work", "copies": 1, "rounds": 2,
  "edits": [{"file": "'$h'/src/prog.v", "line": 7, "find": "seen := ", "replace": "{pause}seen := "}],
  "build": "'$V' -w -o '$h'/prog '$h'/src/prog.v", "in_pause": "touch {root}/marker"}' > "$h/pause.json"
before=$(cat "$h/src/prog.v")
"$P" race "$h/pause.json" > "$h/pause.out" 2>&1
expect_exit pause 1 "$h/pause.out" $?
has pause "$h/pause.out" 'the pause was reached in 2/2 rounds'
has pause "$h/pause.out" 'the marker was there'
has pause "$h/pause.out" 'extra: marker'
same_file pause "$h/src/prog.v" "$before"

# A pause that is never reached is not a measurement.
echo '{"head": "'$h'/prog", "cmd": "true", "work": "'$h'/work_never", "copies": 1, "rounds": 2,
  "in_pause": "touch {root}/marker"}' > "$h/never.json"
"$P" race "$h/never.json" > "$h/never.out" 2>&1
expect_exit never 1 "$h/never.out" $?
has never "$h/never.out" 'NOT MEASURED in 2 rounds'

# ---------------------------------------------------------------- trace
t="$tmp/t"
mkdir -p "$t"
cat > "$t/lib.v" <<'EOF'
module main

fn is_lock_name(name string) bool {
	return name.starts_with('.') && name.ends_with('.lock')
}

fn walk(names []string) int {
	mut n := 0
	for name in names {
		if is_lock_name(name) {
			n++
		}
	}
	return n
}

fn lookup(folder string, name string) int {
	if is_lock_name(folder + name) {
		return 1
	}
	return 0
}
EOF
cat > "$t/lib_test.v" <<'EOF'
module main

fn test_walk_counts_any_id() {
	assert walk(['.name.7.lock', 'notes.txt']) == 1
}

fn test_lookup_finds_a_lock() {
	assert lookup('', '.tool.lock') == 1
}
EOF
before_lib=$(cat "$t/lib.v")
before_test=$(cat "$t/lib_test.v")
echo '{"test": "cd '$t' && '$V' -w lib_test.v", "source": "'$t'/lib.v", "test_file": "'$t'/lib_test.v",
  "functions": ["is_lock_name"]}' > "$t/trace.json"
"$P" trace "$t/trace.json" > "$t/trace.out" 2>&1
expect_exit trace 1 "$t/trace.out" $?
has trace "$t/trace.out" '2 tests ran'
has trace "$t/trace.out" 'accepts `\.a\.#\.lock` \(such as `\.name\.7\.lock`\); no test brings that input through: lookup:'
has trace "$t/trace.out" 'accepts `\.a\.lock` .* no test brings that input through: walk:'
has trace "$t/trace.out" '`a\.a` \| `notes\.txt` \| false'
same_file trace "$t/lib.v" "$before_lib"
same_file trace "$t/lib_test.v" "$before_test"

echo "vprobe self-test: $((cases - fails))/$cases checks passed"
[ "$fails" -eq 0 ]
