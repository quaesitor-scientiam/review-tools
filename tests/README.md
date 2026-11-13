# Detector fixture suite

`run_fixtures.sh` is the Phase-R gate for every `detect_*.sh` / `detect_*.ps1` in
`skills/code-review/`: a detector only counts as working if it exits 1 on a
known-bad input and 0 on a known-good one. Replacing a detector with a no-op
makes the suite fail.

## Layout

```
tests/<detector-name>/known_bad/<case>/...   expected exit 1
tests/<detector-name>/known_good/<case>/...  expected exit 0
```

A case directory is a miniature working tree. The runner `cd`s into it and runs
the detector with each regular file in the case as an argument (sorted, relative
paths). A single-file case also gets a second argument, mirroring the
`<file> <base_copy_or_empty>` contract of `run_detectors.sh`: the empty string
for known_bad, and for known_good a decoy (the detector's first known_bad file),
so a detector that scans `$2` as a target fails its known_good case. Detectors whose
target path is hardcoded (e.g. `vlib/net/http/h2_server.v`) get the file at that relative path inside the case and an empty `args` file.

Control files inside a case (all optional):

| File | Meaning |
| --- | --- |
| `args` | one argument per line; an empty file means no arguments |
| `needs_git` | build a throwaway repo: `master` has an empty baseline commit, `feature` adds the case files (for detectors that call `git merge-base`/`diff`/`show`) |
| `expect_rc` | override the expected exit code |
| `expect_out` | extended regex the output must match (known_bad) / must not match (known_good); for enumerate-and-verify tools that always exit 0 |

## Running

```bash
bash tests/run_fixtures.sh                      # everything + coverage check
bash tests/run_fixtures.sh detect_lenient_parse # one detector
VERBOSE=1 bash tests/run_fixtures.sh            # print passing cases too
```

Runs under WSL, macOS bash and git-bash (`timeout` and `git` required; `pwsh`
optional: `.ps1` detector cases are skipped without it). On Windows prefer WSL,
since several detectors spawn per-line subshells that are pathologically slow on
git-bash: `wsl -e bash -lc 'cd /mnt/s/repo/review-tools && bash tests/run_fixtures.sh'`.

With no arguments the runner also fails for any detector on disk that has neither a
`tests/<name>/` directory nor a row in `UNFIXTURED.md`, so a new detector cannot be
added without a fixture or a written reason; for any detector that calls `git`
(the runner owns all git access); and it runs a smoke test of `run_detectors.sh`
itself on a throwaway repo (no-arg change detection, `--at <rev>`, path
normalisation).

Every detector is a V program in `detectors/<name>.v`, compiled once per run
(cases are labelled `[v]`); a `.sh`/`.ps1` twin in `skills/code-review/`, if one
still exists, is tested too. The compiler is `$DETECT_V` or `v` on PATH; without
one the `[v]` cases are skipped. The runner smoke test exercises both
`run_detectors.sh` and the compiled `run_detectors.v`.

## Writing a fixture

Read the detector's header comment for the exact pattern it greps. The known_bad
case should be the smallest V file that trips that pattern; the known_good case
should be the same file with the bug fixed the way the detector expects (the cap,
the guard, the `.clone()`), not a file the detector cannot see at all. A
known_good that is merely "unrelated code" proves nothing about the fix path.

## The probe self-test

`tests/vprobe/selftest.sh [path/to/v]` builds `probes/vprobe.v` and runs each of its four
commands on inputs whose right answer is known: a mutant a helper kills, a flaky test, a test that
fails whenever its source file is edited, a hang, a crash, a held-open window, a per-caller gap.
Every case states the line the probe must print and its exit code, so a probe that gives the wrong
verdict, or ends "nothing flagged" for something it did not run, fails. It needs a POSIX shell
(Linux, WSL or macOS). It is separate from `run_fixtures.sh`, which covers the detectors only.
