# review-tools

The vlang code-review tooling, moved out of per-checkout `.claude/` directories
into one git repository so it runs identically on Windows (PowerShell / git-bash),
WSL and macOS. Git is the sync mechanism; nothing is copied by hand.

## What is here

| Path | Contents |
| --- | --- |
| `skills/vreview/` | The `/vreview` review process (SKILL.md) |
| `skills/code-review/` | `run_detectors.sh` (thin bash runner kept for WSL/macOS habit; same manifest), H2/QUIC conformance matrices, `rfc-texts/`. The shell detectors were retired once their V ports passed the same fixtures |
| `skills/phase-r/`, `skills/review-respond/`, `skills/adversarial-review/` | Companion skills (see below) |
| `skills/v-write/`, `skills/design-brief/` | Write-time skills, used before the code exists: the V write-time sheet (with the programs behind each fact in `vfacts/`) and the one-page design brief (see below) |
| `detectors/` | The detectors, one V program each (`detect_*.v`, same `<file> <base_copy_or_empty>` contract), and `run_detectors.v`, the batch runner: computes targets and base revision with git, compiles the detectors a run needs once into a hash-keyed cache in the user's own cache folder (`~/.cache/review-tools-bin`), dispatches by a basename manifest. No bash needed |
| `probes/` | `vprobe.v`, the executed probes `/vreview` hard rule 4 requires: `matrix` (base build against head build per place, kind of object and account), `race` (several copies of a command at once), `mutate` (one test run per one-line mutant, generated for the functions that changed), `trace` (which inputs each caller of a function is tested with) and `siblings` (which sites of one situation lack a call another site gained). The file's header describes the spec |
| `hooks/` | `hooks.json` (plugin hook wiring), `require_code_review.sh` (commit gate), `check_powershell_parse.ps1`, `check_ps1_file_parse.ps1` (reference copies, wired globally) |
| `reference/` | `code-review-reference.html` quick reference, its `code-review-misses-data.js` table data, and the `code-review-misses.md` narrative corpus |
| `tools/` | `review_cost.v`: what `/vreview` and `/adversarial-review` runs cost, read from Claude Code session transcripts (see below). `install_answer_rules.sh`: puts the answer rules of `global/` into a machine's `~/.claude/CLAUDE.md` (see below) |
| `global/` | `answer-rules.md`, the standing rules for what follows a skeptical review ("a weakness you list is work to do"), and `answer-format.md`, the Answer Format block they belong under. One copy here, installed per machine |

## The answer rules on every machine

`~/.claude/CLAUDE.md` is per machine and nothing syncs it, so the rules that apply to every
answer in every project live here as `global/answer-rules.md`. On a machine that does not have
them yet (after `git pull`):

```sh
bash tools/install_answer_rules.sh
```

It inserts the rules at the end of the file's Answer Format section (a heading of any level or
letter case), or creates the file. A file with no such heading gets the rules appended, with the
Answer Format block in front of them unless the words "skeptical review" show that the format
is already there under another heading. It changes nothing when the rules are already there,
and its first words say which of these it did. A changed file is first copied to
`~/.claude/CLAUDE.md.bak-answer-rules`. To change a rule, edit `global/answer-rules.md` and the
machine's own file together: the script does not update a section that is already installed.

Its cases touch scratch files only, so on a system it has not run on yet (macOS, at the time of
writing) run them before the script: `bash tests/install_answer_rules/run.sh`.

## The skills

| Skill | Use it for |
| --- | --- |
| `/review-tools:vreview` | Reviewing your own change before every commit. Writes the marker the commit gate checks |
| `/review-tools:phase-r` | A bug someone else found: reproduce it on the unfixed code before fixing it |
| `/review-tools:review-respond <PR#> [review or comment] [owner/repo]` | One round of review on a PR, from a maintainer, another person or a bot such as Codex: fetch the findings (review bodies, inline comments and plain PR comments), check each against the code, reproduce each real bug with `/phase-r`, fix, run `/vreview`, commit, push to your fork, and reply where each finding was posted. Replaced `/codex-respond` on 2026-11-14 |
| `/review-tools:design-brief` | Before the first edit of a change that adds behaviour: one page with the request, the smallest change, what is out of scope, the decisions that are the user's, and where each list came from. No source file is edited until the user approves it |
| `/review-tools:v-write` | Before writing or editing a `.v` file: seventeen V language facts with a run program each, six structural defaults, and the loop for each function |
| `/review-tools:adversarial-review` | A multi-agent pass that tries to break a finished change; run it only with the user's go-ahead |

`/luna-respond` was removed on 2026-11-14: it was a placeholder for a review service that was
never connected.

## What a review costs

`v run tools/review_cost.v [projects-dir] [--since YYYY-MM-DD] [--list] [--selftest]` reads
the session transcripts under `~/.claude/projects` (or the folder given) and prints one table. A
`/vreview` run lasts from the command or Skill call to the end of that turn, with the subagents
it started. A stop that a Stop hook blocks does not end the turn, and a command typed after an
interrupted run starts a new run. An `/adversarial-review` run is one Workflow run whose name,
summary or the first 400 characters of its script mention "adversarial", counted from the
subagent transcripts of that run; the main session's work around it is left out. Weighted cost
counts input 1, cache writes 1.25 (5 min) or 2 (1 h), cache reads 0.1 and output 5. `--list`
prints each adversarial run, and `--selftest` checks the counting on made-up transcripts.

On this machine, 2026-11-15 (all projects):

| | vreview | adversarial-review |
| --- | --- | --- |
| Runs found | 228 | 80 (70 since 2026-10-15) |
| Median model calls | 14 | 237 |
| Median output tokens | 17K | 159K |
| Median new input | 97K | 1.17M |
| Median weighted cost | 900K | 4.54M |
| Recent runs (2026-10-15+) | 655K median (140K to 4.31M) | 3.82M median (134K to 44.95M) |

A `/vreview` run that goes on to fix or commit in the same turn counts that work too, so its
figures run high.

## Changing the rules

See [CONTRIBUTING.md](CONTRIBUTING.md): a rev is the rule, its reference page entry and its
corpus rows in one commit, and the commit gate checks all three.

## Install and update

See [MIGRATION.md](MIGRATION.md). Short form: clone, `claude plugin marketplace add <clone>`,
`claude plugin install review-tools@review-tools-local --scope user`; update with `git pull`.
Run the detector fixture suite with `bash tests/run_fixtures.sh` (see `tests/README.md`). Run the
probe self-test with `bash tests/vprobe/selftest.sh [path/to/v]` on Linux, WSL or macOS.

For OpenCode (skills + `/vreview` slash commands, no Claude Code needed),
see [OPENCODE.md](OPENCODE.md).

## History

The first commit is a verbatim copy of the canonical files as of 2026-10-18:
`C:\Users\john3\.claude\skills\{vreview,code-review,phase-r,codex-respond,luna-respond,adversarial-review}`,
`S:\repo\vlang\.claude\hooks\`, `C:\Users\john3\.claude\hooks\check_*.ps1` and
`S:\Code Review\`. The HTML reference was at rev 66.

Later commits (in order): fixture suite (`tests/`), Claude Code plugin packaging
(`.claude-plugin/`), retirement of `sync_skills.sh`, runner-owns-git rewrite of
`run_detectors.sh`, and the port of detectors to V (`detectors/*.v`).
