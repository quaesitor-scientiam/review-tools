---
name: design-brief
description: Write a one-page design brief and get the user's approval before writing code for any change that adds behaviour. Use before the first edit of such a task, not at review time.
---

# Design brief

A brief is a stop: no source file is edited until the user has approved it. Its purpose is to put
the design questions to the user before the code exists. On vlang/v#31848 they were asked after
five review rounds, and the answers removed about 2,200 lines. Added 2026-11-22 and not yet
tried on a real task.

## When it is required

Write a brief when the change does any of these:

- adds behaviour (a new option, path, fallback, retry, default, message or file format);
- touches files or folders on disk, locks, processes, or anything two programs can reach at once;
- implements or changes something a specification defines;
- reads or produces input for another tool (assembler, shell, C compiler, linker, OS API);
- narrows or moves an existing check.

Skip it for a fix confined to one function that has a failing test, for docs, and for a rename.
When unsure, write it.

## The brief

Keep it to one page. Plain language; no code beyond a signature.

```
# Brief: <task>

## Request
<The maintainer's or user's own words, quoted, with where they were said.>

## Smallest change that meets it
<What will exist afterwards, in three to six sentences. Which functions change.>

## Out of scope
<Everything nearby that this does not do. Each line is something I will not build
unless asked.>

## Decisions that are yours
<Each as a question with my recommendation first. Examples: what happens on a
failure; whether two runs at once are excluded or tolerated; which platforms count.>

## Lists, and where each came from
<Callers and sibling functions: from graphify or `vprobe siblings`, with the command.
Inputs, spellings, special names: from the system's documentation, with the link.
A list from memory is labelled "from memory, incomplete".>

## What could make this wrong
<The two or three ways this design fails. For each: the test that would show it.>

## How it will be checked
<The tests, on which platforms, and the size I expect (functions, rough lines).>
```

## Rules

1. **Ask, then wait.** Put the decisions to the user with `AskUserQuestion`. Do not start on the
   parts that "do not depend on the answer"; in this kind of change they usually do.
2. **Nothing beyond the request.** A capability the request did not name goes under "Out of
   scope", or under "Decisions" as a question. It is never built on my own judgement.
3. **The structural defaults hold.** One function decides each question; no second copy; no
   model of another tool; a fallback lists its triggers; a failed look never takes the
   destructive branch. A brief that departs from one says so under "Decisions".
4. **The brief is amended, not outgrown.** If the work needs behaviour the brief does not have,
   or passes twice the expected size, stop, amend the brief and ask again. Behaviour added
   during a fix round is new behaviour and gets its own lists.
5. **A repeat means the design, not the line.** When a review finds the same class of defect a
   second time, return to the brief and ask the design question before patching. Do not wait
   for a third round.
6. **The brief goes with the review.** `/vreview` and any outside reviewer are given the brief,
   so that "out of scope" and the user's decisions are not reported as defects again.

## After approval

Follow the loop in `/review-tools:v-write` for each function: contract, failing test, code, break it on
purpose and read which test fails, detectors, format. Then `/vreview` as before.
