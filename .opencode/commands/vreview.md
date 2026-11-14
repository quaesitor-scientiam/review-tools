---
description: Run the vreview code-review process (OpenCode port of /vreview)
---

Load the `vreview` skill and execute it with these arguments: $ARGUMENTS.

OpenCode runtime: the skill text names `${CLAUDE_PLUGIN_ROOT}` (a Claude Code
substitution). It means the review-tools repo root — the checkout holding
`skills/`, `detectors/`, `probes/` and `reference/` (from the skill's base
directory `skills/vreview/`, two levels up). On Windows PowerShell prefer the V
runner from the target repo: `v run <review-tools>/detectors/run_detectors.v
<files>`. Do not run `bash .../run_detectors.sh` on Windows PowerShell.
