---
description: Reproduce-before-fix workflow for an externally-found miss (OpenCode port of /phase-r)
---

Load the `phase-r` skill and execute it with these arguments: $ARGUMENTS.

OpenCode runtime: `${CLAUDE_PLUGIN_ROOT}` in the skill means the review-tools
repo root — the checkout holding `skills/`, `detectors/`, `probes/` and
`reference/` (from the skill's base directory `skills/phase-r/`, two levels up).
