# Before writing code: design brief, then the V write-time sheet

Two skills of the `review-tools` plugin run before the code exists. They do not replace
`/vreview`, which still runs before every commit. (Added 2026-11-22, review-tools rev 121, after
a reading of the miss corpus: most logged defects were design and test defects that a review
found late, not V mistakes.)

1. **Design brief first.** Before the first edit of a change that adds behaviour, touches files,
   locks or processes, implements something a specification defines, reads or produces input for
   another tool, or narrows an existing check: invoke the `review-tools:design-brief` skill,
   write the one-page brief, and wait for the user's approval. No source file is edited before
   that. A fix confined to one function that has a failing test, docs, and a rename skip it.
   When unsure, write it.
2. **V sheet before any `.v` edit.** Before writing or editing a `.v` file, invoke the
   `review-tools:v-write` skill and follow its loop for each function.
3. **If a skill is not in this session's list**, say so and read its file directly in this
   machine's checkout of the review-tools repository: `skills/design-brief/SKILL.md` or
   `skills/v-write/SKILL.md`.

When starting another session or a subagent that will write code, tell it this too.
