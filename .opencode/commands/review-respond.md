---
description: Handle one round of review on a PR, from any reviewer (OpenCode port of /review-respond)
---

Load the `review-respond` skill and execute it with these arguments: $ARGUMENTS.

OpenCode runtime: `${CLAUDE_PLUGIN_ROOT}` in the skill means the review-tools
repo root — the checkout holding `skills/`, `detectors/`, `probes/` and
`reference/` (from the skill's base directory `skills/review-respond/`, two
levels up).
