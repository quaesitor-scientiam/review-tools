---
name: advreview
description: Shortcut for /review-tools:adversarial-review run as cheaply as it can be, with subagents that use graphify, ending in a token usage report. Usage: /review-tools:advreview [target] (uncommitted, a PR#, a branch, or claims to check).
---

# Efficient adversarial review

Invoke the Skill tool with skill `review-tools:adversarial-review` and args `$ARGUMENTS`, then
follow that skill's instructions exactly, its ask before each round included. Do not run any
other review process in its place.

Run it as efficiently as possible, with subagents, and with graphify:

- Keep the lenses and refuters to the fewest that cover the change, and give each agent only
  the files and diff hunks it needs.
- Tell every subagent to use the graphify MCP tools (`get_node`, `get_body`, `get_neighbors`,
  `shortest_path`, `query_graph`) before Grep or reading whole files, passing the reviewed
  tree's full path as `folder` when it is not the session's tree.
- End the report with a token usage section: tokens per agent (finders and refuters), the
  total, and the main session's share where it is known. Say which numbers are measured and
  which are estimates.
