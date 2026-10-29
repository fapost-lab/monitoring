---
name: jig-task
description: Start or resume a task with Jig — classify it by risk, create its workspace and choose the workflow. Use when the user describes work to do ("add …", "fix …", "refactor …"), asks to start or continue a task, asks what to take next ("what next", "take the next one"), or says "jig task", "classify this", "what process does this need".
---

# jig-task — classify and route

You decide the class; scripts record it. Keep this step short: it exists to avoid
running an expensive process on cheap work, and a cheap process on risky work.

## 0. Exploration is a valid entry

For standalone research/comparison, use `jig context resolve --no-task --catalog` with
explicit files/domains/topics; do not select an unrelated task, classify implementation,
or create a workspace. Use `--files -` with empty stdin for a deliberately empty frontier.
An explicit analysis of a named task stays there. Save research only when useful/requested;
implementation intent returns to the route below.

An idea whose shape is not settled, or work too big for one task (phases, many tasks), goes
to `jig-idea` first: it tests the idea and keeps a specification with a roadmap. Specs are
listed by `jig spec list`.

## 1. Resume before starting

```
.ai/scripts/jig task current
.ai/scripts/jig task list
```

If a task for this work already exists, read its `task.md` and `plan.md`, say where it
stands, and continue from there instead of creating a second workspace. A task listed
with `worktree=<path>` continues in that worktree, not in this checkout; §3 says how to
get there.

If either command prints `checkout: HEAD here moved <a> -> <b> since you were told`,
another session checked a branch out here while you were working. **Do not switch the
branch back** — that pulls the tree out from under whoever started work on it. Say what
happened, and give the task that arrived a worktree of its own instead.

`task current` exiting 2 means several tasks are live on this branch. It prints them;
ask the user which one, and never pick for them. Suggest pausing the other:

```
.ai/scripts/jig task pause <other-id> --reason "<why>" [--stash]
```

Resuming a task that was paused: `jig task resume <id>` prints what changed while it was
dormant. Treat a long pause or an overlap line as a reason to re-check the premises of
`design.md` before building on it; the stage skills can be re-run, and re-running
`jig-analyze` is how research is restarted.

Then ask which merged tasks wait to be closed. The dry run changes nothing:

```
.ai/scripts/jig housekeeping --dry-run
```

For each task flagged `needs-consolidation`, name it and ask the user whether it can be
closed — a fix may still be expected. On yes, close it with `jig-consolidate` §6. Never
close without asking, and do not hold up the work the user came for while waiting.

When the person asks what to take next ("what next", "take the next one"), run
`.ai/scripts/jig queue next` instead of choosing. Name the task and its place, then start it
through this skill (§3). On `next: none`, report its reason and the lines under it and stop:
do not pick a task yourself.

## 2. Classify

Read `references/classification.md`, answer its risk test — what a mistake would cost and
what takes it back — and pick T0–T4 from that answer, never from whichever example reads
closest. State the class and the answer that decided it, in a single sentence. Do not
narrate the rubric.

If the description is too vague to classify, ask one question. One, not a list.

## 3. Create the workspace, then start it

T0 and T1 that fit in one session need no workspace. Otherwise:

```
.ai/scripts/jig task new <id> --class T2 --domains <a,b>
.ai/scripts/jig task start <id>
```

The id is short and kebab-case, derived from the work (`fix-trigger-idempotency`), not a
ticket number unless the project uses one. Fill in `task.md`: goal, scope, notes.

**The goal comes before the start.** `task start` warns when `## Goal` is empty or holds only the
template's comment, and refuses a T3 or T4 task until it is written. Write it from what you were
given — `task new --goal` or `--from`, or `jig task artifact write <id> task --from <file>` — and
never invent one: with nothing that says what the task is for, ask, and an unattended run that
cannot ask ends there with a report naming what is missing.

**Two commands, because filing and beginning are different acts.** `task new` records the
intent: no branch, no checkout change. `task start` cuts the branch and records the commit
it forked from, which is why it belongs at the moment work actually begins — a fork point
recorded weeks earlier is wrong by the time anything reads it.

**The base is chosen for you.** `task start` fetches, then cuts the branch from the default
branch — or, for a task linked to a spec with an open epic, from the epic — and records it as
`base_branch` (`jig task show <id>`). The task's pull request goes into that base; one merged
anywhere else is flagged `wrong-base` and kept. When start refuses because the spec is not in
this checkout, the epic branch exists nowhere, or the epic is finished, tell the user what it
said and ask. Never edit the `Spec:` line or create the branch just to get past it.

**File without starting when the work is for later.** A task with no branch is listed as
`not-started` and never becomes an ambiguous `task current` candidate, so parking an idea
costs nothing and does not need a pause to stay out of the way. Pause means "was being
worked on, set aside" — do not use it to mean "not begun".

**A worktree is not only what a refusal pushes you towards.** `task start` moves this
checkout's HEAD, and a checkout that looks free may not be: `jig status` prints
`working here: …` for work another live session is doing **in this checkout**. A task that
lives in its own worktree is not listed there — it shows as `worktree=<path>` instead, and
is no reason to go anywhere. When `working here:` names anything, or when the user is
working in this checkout themselves, start in a worktree without being asked to:

```
.ai/scripts/jig task start <id> --worktree
```

**When `task start` refuses an occupied checkout** (`this checkout is in use: …`), it names
the record it went by. Take the worktree road it offers. Delete that record only when you
know the session behind it is over; there is no override.

**When `task start` refuses a dirty tree**, the changes belong to other work — never work
around it. Ask the user which road: pause the task that owns them
(`jig task pause <owner> --stash`), or start this one in a worktree, as above. When the
refusal names `jig spec ship <id>` instead, the dirty tree is a spec `jig-idea` left
mid-session, not another task's work — run it and try again; there is no question here for
the user, Jig already answered it.

Either way it prints a path and leaves this checkout alone. From then on the task is worked on from
that path only. If your runtime can switch this session into an existing worktree, switch
and run every command from there; otherwise tell the user to open a new agent session in
that path. Either way, do not continue the task from here.

**Where your runtime can open that session itself** (Claude Code desktop's `start_session`),
do so for parallel work the person asked for: a task already filed with `jig task new` and
started in its worktree, the session opened in that path and told the task id — **in the same
turn they asked**, since a turn an event began may be refused
([jig-autopilot](../jig-autopilot/SKILL.md) §2, where autopilot uses subagents instead).

Write the task's own documents through jig, there and everywhere else — never with your
editing tools, and never with a shell redirection:

```
.ai/scripts/jig task artifact write <id> plan --from <file>
.ai/scripts/jig task artifact append <id> task --from -
```

`<kind>` is `task`, `discovery`, `spec`, `alternatives`, `design`, `plan`, `review`,
`verification`, `handoff`, `knowledge-map`, `commit-message` or `pr-body`, and the content comes from a file you wrote or from stdin.
In a worktree the workspace is only borrowed, and jig is what knows where it really is.

When the user already wrote the task as a document, take it from disk instead of
retyping it, and split it as §"When the task arrives written" says:

```
.ai/scripts/jig task new <id> --class T3 --from <path>
```

## 4. Load context

Use the first stage selected by the class so stage-aware knowledge arrives before that
stage begins (for example, `analyze` for T1/T2 and `discover` for T3/T4):

```
.ai/scripts/jig context resolve --task <id> --stage <first-stage> --catalog
```

Read exactly what it lists and nothing else. It returns global knowledge, documents
matching the affected files or domains, and the workspace artifacts.

## 5. Run the route

Announce the route, then start the first stage. Each stage is its own skill:

| Class | Route |
|---|---|
| T0 | jig-implement → jig-verify → jig-consolidate |
| T1 | jig-analyze → jig-implement → jig-verify → jig-consolidate |
| T2 | jig-analyze → plan → jig-implement → jig-review → jig-verify → jig-consolidate |
| T3 | discover → design → **human gate** → jig-implement → jig-architecture-review → jig-verify → jig-consolidate |
| T4 | discover → specify → alternatives → design → **human gate** → jig-implement → independent jig-review → jig-verify → jig-consolidate |

**Depth.** The class sets the floor; the person may want no more than that. A personal
`route.depth: lean`, or `jig task new <id> --lean` for one task, asks for a lighter route.
Add `--lean` only when the person asked for it for this task. Name the route from the script,
not from the table above:

```
.ai/scripts/jig task route <id>
```

Announce and run the `route:` it prints; its `lean:` line says what is trimmed — at T1 the
analysis is a few lines in `task.md`, at T2 the plan is part of the analysis, from T2 up one
review round. Lean never trims tests on changed files, CI before a merge, consolidation, the
gate or architecture review of T3/T4, or the class itself.

Exit 4 from a stage's `jig context resolve` means a person asked the task to pause: Jig paused
it and the stage was not entered. End the session and say so; `jig task resume <id>` continues it.

Every route ends in `jig-consolidate`, even when nothing durable came out of the task: it
records the knowledge decision before the commit and, once the change has landed, closes
the task. A task stopped at `ready` is never cleaned up.

A stage whose output the user already supplied is not re-run; see the next section.

**Giving a task up, or moving it.** When the person drops a task, or decides its work belongs in
another repository, run `jig task abandon <id> --reason "<their why>"`, adding
`--moved-to <repo>#<task-id>` (the `Linked:` form) for a move. The decision lives where the next
agent reads it — the task's `state`, and the roadmap item `jig spec drop` closes for a spec-linked
task — never only in a note in `task.md`, which is gitignored. For a spec without an epic that leaves
the checkout on `spec/<spec-id>`, with the edit committed when your git level allows; finish it with
`jig spec ship <spec-id>`, as the command's last line says. When the move also changes what the
project knows (which package owns a concern), record it in knowledge through `jig-consolidate`.

## When the task arrives written

A task handed over as a written document has usually been through discovery and design
already. Run the stage that is missing, not the ones the author has done.

- **Split it.** Goal, problem and scope go to `task.md`; the proposed solution goes to
  `design.md`. A gate cannot approve a document where the problem and the answer are
  mixed together.
- **Argue with the design before the gate.** Say what you would do differently and why,
  which questions it leaves open, and which of its claims you could not confirm. A design
  that draws no objection was not reviewed.
- **Verify its premises.** The document may assert things about this codebase that are no
  longer true. Check the ones the design rests on and report what you found. This is the
  part of discovery that is still owed.
- The gate is then the moment you and the author settle on the final shape, and
  implementation starts from that, not from the original text.
- **A task linked to a spec** carries a `Spec: .ai/specs/<id>/ — Phase <n>` line: it was filed
  from that spec's roadmap. Read every file of the spec as input and check the premises the task
  rests on, as for any written design. The roadmap items that name the task are its boundary.
- **A task that continues work in a neighbouring repository** — a package next to the project,
  a sibling service — gets a `Linked: <repo>#<task-id>` (or `<repo>#spec/<spec-id>`) line in the
  `task.md` you file, `<repo>` being the path from this clone's main checkout
  (`packages/fapost-saas`). `jig context resolve` then lists that task's documents on `linked:`
  lines; read them as input. An `unreachable:` line means they are not on this machine: say so.

## Human gate (T3, T4)

Stop. Show the document being approved — `design.md`; for T4 also `spec.md` and the
alternatives — verbatim, with your objections after it, as
[show the document](references/show-the-document.md) says. What changes, which
alternatives lost and why, and what it costs to undo belong in the document itself; if
they are missing, the document is not ready for the gate. Wait for the human to approve,
change or reject it, and record the decision in `task.md` (`jig task artifact append <id> task --from <file>`). Do not start implementing while
waiting, and do not treat silence or a general "ok, go on" from an earlier message as
approval.

When the human approves, record it for the scripts too, after the design reflects every change
they asked for:

```
.ai/scripts/jig task gate <id> approved
```

It pins the approved design, so the status page stops showing it as waiting for the human and
shows it again if `design.md` changes afterwards — then go back to the gate with what changed.

For T2+, follow [requirements and planning](references/requirements-and-planning.md).
Design UI changes with [applicable states](references/ui-states.md), and a new or changed
boundary between components with its
[MAY / MUST / MUST NOT](references/component-boundaries.md). At pause/resume or
this gate use the [handoff](references/handoff.md); continuous work needs no extra stop.
`jig task artifacts <id>` reports input facts, not approval or the next stage. If an input
lives in conversation, locate/read it before using `--provided <kind>`; never invent a
provided claim to silence a missing input.

## Artifacts

Create an artifact only when it does work: a plan someone follows, a design someone
approves, a spec someone checks against. Everything else stays in the conversation. Task
artifacts live in `.ai/workspace/tasks/<id>/` and never move into the repository; only
`jig-consolidate` writes to `.ai/knowledge/`.
