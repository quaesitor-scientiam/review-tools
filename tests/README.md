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
itself on throwaway repos (no-arg change detection, `--at <rev>`, path
normalisation; and for rev 120, `.md` files changed on the branch and in the
working tree that must reach the claims detector with their base copies, a changed
file of another kind that no-arg mode leaves out, `--at` with two targets, and
`--base`). Since rev 122 it also covers the `--only`, `--base=` and `--at=` forms,
the sibling files `--at` extracts, a missing named target and one no detector takes,
the base when there is no `master` (`main`, then `origin/HEAD`), a cold cache that
builds only the needed detector, builds planted in the shared temp folder (never
run), the private per-run folder (mode 0700, random name), and its removal after
every run, flagged and failed ones included. Since rev 129 it also runs `--at` with a
relative temp folder and with one spelled with `..` after a link, and runs a copy of
review-tools and then the checkout with one build cache: each must use its own detectors.
Since rev 131 it also runs with compilers of different content (a build is reused only with one
of the same content, whatever path names it), ones that cannot be read (missing, a folder, a
FIFO), the compiler order (`DETECT_V`, then `v` on `PATH`, then the target repo's own), a
relative `DETECT_V` from a folder below the repo root, a PATH without `sha256sum` (and without
`shasum` too), and a copy with a detector that
does not compile and one whose source is gone: both are named and the run exits 2, as for a
detector that ends in any way but exit 0 or 1.
Since rev 132 it also runs with an empty `TMPDIR`, which must mean /tmp: on macOS the runner reads
`TMPDIR` itself, since V's `os.temp_dir()` there is always /tmp. Two more cases start it from
a subfolder with a relative `TMPDIR`, which is read from that subfolder. vprobe's self-test
has the `..` case and the empty case too.
`FIXTURE_SMOKE_ONLY=1 bash tests/run_fixtures.sh` runs everything but the
per-detector cases, for a mutation run over `run_detectors.v`.

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

`tests/vprobe/selftest.sh [path/to/v]` builds `probes/vprobe.v` and runs each of its five
commands on inputs whose right answer is known: a mutant a helper kills, a flaky test, a test that
fails whenever its source file is edited, a hang, a crash, the mutants generated for the functions
that changed since a base file, a held-open window, a line one copy prints about a tree that is
not there, a per-caller gap, a check one sibling site has and the other lacks. Since rev 129 it
also checks the work folder vprobe makes when a spec names none, for `matrix` and `asm`: mode
700, a random part in its name, a folder or link planted at the old name `vprobe_<pid>` left
alone, and the folder gone after a run and after a failed one. The kinds that need root (another
account's file, folder or link) are not run by it.
Every case states the line the probe must print and its exit code, so a probe that gives the wrong
verdict, or ends "nothing flagged" for something it did not run, fails. It needs a POSIX shell
(Linux, WSL or macOS). It is separate from `run_fixtures.sh`, which covers the detectors only.

## The answer-rules installer

`tests/install_answer_rules/run.sh` runs `tools/install_answer_rules.sh` against scratch files, one
case per kind of target (no file, an Answer Format section in each position and spelling, a
format under another heading, a code fence, CRLF lines, a link, a folder), and compares each
result byte for byte. It needs only bash and awk, and exits with the number of failing checks.

## The rev check

`tests/check_pr_rev/run.sh` runs `hooks/check_pr_rev.sh` on scratch repositories, one per way a PR
can stand to `main`: no rev, the next one, a skipped, lower or taken one, and titles
that do not match.
