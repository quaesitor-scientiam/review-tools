# OpenCode support

This repo is a Claude Code plugin, but the same skills and detectors run under
OpenCode with two shims: a `skills` config entry and slash-command files. This
is additive only on purpose: no `skills/*/SKILL.md` rule text is touched, so a
change here never trips the `require_code_review.sh` doc-sync gate (that gate
watches `skills/` and `detectors/`, and a skill edit without a reference-page
rev is blocked).

## What you get

| OpenCode | Claude Code equivalent |
| --- | --- |
| `@vreview`, `@phase-r`, `@review-respond`, `@adversarial-review` (skills) | `/review-tools:vreview` etc. |
| `/vreview`, `/phase-r`, `/review-respond`, `/adversarial-review` (commands in `.opencode/commands/`) | bare `/vreview` etc. via the plugin |
| V runner `detectors/run_detectors.v` | same (preferred on Windows PowerShell in both runtimes) |

`skills/code-review/` holds no `SKILL.md`, so it registers no skill — as in
Claude Code, it is content the `vreview` skill reads (matrices, `run_detectors.sh`).

## Install

Clone once; the plugin is loaded in place, so updates are `git pull`.

```sh
git clone https://github.com/quaesitor-scientiam/review-tools.git ~/repo/review-tools
```

Point OpenCode at the skills directory. In your global
`~/.config/opencode/opencode.json`:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "skills": [
    "<clone>/skills"
  ]
}
```

`<clone>` is the checkout path (forward slashes on Windows). Skill IDs come
from the directory names, so this exposes `vreview`, `phase-r`,
`review-respond` and `adversarial-review` to the `skill` tool and to `@skill`
mentions.

Install the slash commands (OpenCode discovers commands from files, not from
the `skills` array). Either copy the shipped shims globally:

```sh
mkdir -p ~/.config/opencode/commands
cp <clone>/.opencode/commands/*.md ~/.config/opencode/commands/
```

or copy them per project into `<project>/.opencode/commands/`. Saving a file
takes effect without restarting OpenCode.

## Runtime path mapping

Skill text names `${CLAUDE_PLUGIN_ROOT}` — a substitution only Claude Code
performs. Under OpenCode it means the review-tools repo root: the checkout
holding `skills/`, `detectors/`, `probes/` and `reference/`. Resolve it from
the loaded skill's base directory (`skills/<name>/`, two levels up); never
hard-code a machine path in a shared file. The shipped command shims carry
this mapping in their templates so the agent has it before the skill loads.

Related consequences:

- Detectors are V programs (`detectors/detect_*.v`) run through
  `detectors/run_detectors.v`, which owns all git access and compiles each
  detector once into a hash-keyed cache under the OS temp dir. From the target
  repo: `v run <clone>/detectors/run_detectors.v <files>`. The compiler is
  `$DETECT_V`, else the target repo's own `./v`, else `v` on `PATH`.
- On Windows PowerShell do not run `bash skills/code-review/run_detectors.sh`;
  use the V runner (no bash/WSL needed).
- `hooks/hooks.json` and `hooks/require_code_review.sh` are Claude Code wiring
  only. There is no OpenCode commit gate in this repo; if you want a manual
  one, set `permissions` to `ask` on `shell` with a `git commit`/`git push`
  resource.

## Verify

```sh
cd <clone>
v run detectors/run_detectors.v --help
v run detectors/detect_lenient_parse.v \
  tests/detect_lenient_parse/known_bad/unguarded/parse.v ""
# expect exit 1 (UNGUARDED); the known_good twin exits 0
```

The full detector fixture suite (`bash tests/run_fixtures.sh`) needs a POSIX
shell (Linux, WSL or macOS) plus `timeout` and `git`; see `tests/README.md`.
On Windows prefer WSL.

## Why no skill edits

`CONTRIBUTING.md` defines a rev as one commit holding the rule, its reference
entry and its corpus rows together, and the commit gate blocks a commit that
touches `skills/` or `detectors/` without the matching page sync. OpenCode
support is not a rule, so it lives in new files only (`OPENCODE.md`,
`.opencode/commands/`) plus a README pointer — nothing the gate watches, and
nothing Claude Code renders differently.
