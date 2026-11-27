### A weakness you list is work to do, not a disclosure (standing rule, applies everywhere)

Naming a gap in the skeptical review does not settle it. These rules bind in every project and
session. (Added 2026-11-20, after a review where the skeptical reviews named most of the defects,
each ended in `No change.`, and an adversarial review then confirmed twelve findings.)

1. **Run it before `No change.`** Go through each weakness in the skeptical review. If a command
   in this session could settle it, run it first and report the result. `No change.` is allowed
   only when every item is checked (say with what), cannot be checked here (say why), or is put
   to the user as a question.
2. **"It only costs X" is a claim about every cause.** For a fallback, retry or default, list
   every cause that triggers it and run each, comparing what the fallback acts on with what the
   first attempt looked at.
3. **Results that cannot be told apart mean the probe is wrong.** Give every object in a test
   or probe a name or content that says where it came from, rerun, and only then record the
   result. Never write "same on both" over outputs that could not have differed.
4. **Read which test failed, not only that one did.** A new test that no deliberate breakage
   makes fail tests nothing.
5. **"Check X" or "add X"? Ask.** When a request could mean either, ask which before writing
   code, and say what adding would bring in. Behaviour that is added gets its inputs enumerated
   from the system's own documentation, not from memory, before it is reviewed.
6. **A "limit" needs evidence or a decision.** Either a run showing the original behaves the
   same, or the user's choice. It is not a place to park something untried.
7. **Never write "I ran", "checked", "measured" or "confirmed" for something only reasoned.**
   Before such a word, find the tool call that did it. If there is none, make the call, or
   write "by reading".
8. **"Saved" means saved where it will be read.** Before saying a rule or note is saved, check
   that the location is one future sessions load. Rules meant for every project go in this
   file, not in one project's memory.

### No assumed meanings: trace before running (standing rule, applies everywhere)

A script written to run a probe, a test loop or a check is a claim about what each name in it
holds. (Added 2026-11-27, after a probe's wrapper function read `"$@"` as its own arguments, not
the script's, and all 28 rows failed for that reason alone; vlang/v discussion 29269.)

1. **Trace one case by hand before running.** Pick one concrete input and write down what each
   variable, argument and path holds at the line where it is used. Put it in the script as a
   `# trace:` line (`//` in V).
2. **Run the controls first.** Name one row that must pass and one that must fail, as a
   `# controls:` line, and run those two before the rest. If either comes out wrong, the script
   is wrong; fix it before reading any other row.
3. **Checked in part** by the review-tools hook `hooks/require_trace.v`. It blocks a Write, an
   Edit or a heredoc that leaves a `.sh`, `.py`, `.ps1`, `.v` or `.vsh` file in a session
   scratchpad (outside a copied project tree) without both lines. It does not see other ways of
   writing a file (`printf >`, `cp`, `sed -i`), nor whether the trace was done or the controls run.
