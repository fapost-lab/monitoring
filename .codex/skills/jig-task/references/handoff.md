# Compact handoff

At pause, executor/session change or human gate, leave enough in an existing task artifact:
- Task ID and stage, including actual approval and lifecycle state.
- Completed work, changed files, evidence and artifact links.
- Unresolved issues, deferred questions with owner/trigger, and blockers.
- Exact next action and the inputs the next executor must read.

Create handoff.md only when it improves retrieval; otherwise name the existing owner.
Either way it is written with `jig task artifact write|append <id> <kind>`, like every
other task document.
Resume reads that owner plus current state and checks drift before using old conclusions.
A same-session transition needs only a brief update. No mandatory user command, context
reset or runtime-specific /clear. A handoff never supplies approval that was not given.
