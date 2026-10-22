---
name: jig-consolidate
description: Decide what a finished Jig task should leave behind in durable knowledge, record that decision, and close the task once its change has landed. Use at the end of every task route, before committing or opening a PR; when `jig status` or housekeeping reports a task under needs-consolidation; or when the user says "consolidate", "what should we document", "update the knowledge", "close the task".
---

# jig-consolidate — what survives the task

One question:

> What discovered or created during this task would future developers and agents lose if
> it disappeared?

Code already records behaviour. Knowledge records intent. Answering
`NO_DURABLE_KNOWLEDGE` is a correct outcome, not a failure.

This is the last stage of **every** route, T0 included, and it has two entries (ADR-0030):

- **Record the decision** (§1–§5) — after implementation and required review/verification,
  before the commit, so code and the intent behind it enter the repository together.
- **Close the task** (§6) — after its change has landed. A merge is not the end of a task:
  fixes can follow it, and only the close says the task is done.

Finishing analysis, a backlog, or a design does not complete its implementation task: keep
it active or explicitly paused. Resolve/read context with `--stage consolidate`.

A T0/T1 task without a workspace has no state to record: state the decision in the report
and stop there.

## 1. Review what happened

Read the task's workspace artifacts and the diff. Look for: a decision with alternatives,
a constraint discovered the hard way, a term used inconsistently, an assumption that
turned out wrong, a rule the codebase now depends on.

Found nothing? That is `NO_DURABLE_KNOWLEDGE`: skip to §5.

## 2. Route each finding

| Finding | Destination |
|---|---|
| A decision with real alternatives and consequences | `jig knowledge new adr <slug>` |
| Why a feature is shaped this way; its constraints | `jig knowledge new feature <slug>`, or the document that already owns it |
| A dependency direction or system-wide rule | `ARCHITECTURE.md` |
| What implementations of a component boundary may, must and must not do | a `convention` on the interface and its implementations ([boundaries](../jig-task/references/component-boundaries.md)) |
| Something that must always hold | `RULES.md` invariants |
| A practice the project now follows | `jig knowledge new convention <slug>` |
| A term used for a core concept | `GLOSSARY.md` |
| Orientation, terms or rules that bind one domain only | `jig knowledge new domain\|glossary\|rule <domain>` |
| Process notes, task history, what you tried | nothing; it dies with the workspace |

Never copy `plan.md`, `review.md`, `verification.md`, acceptance maps, or behavior deltas
into knowledge because they exist. Retain only the accepted intent in its durable owner.

## 3. Write into existing documents

Update the document that owns the topic instead of adding a parallel one. Several tasks
over time shape one feature document. When a decision replaces an earlier one, mark the
old ADR `superseded` rather than editing history.

A part of `ARCHITECTURE.md` under **Intended — not built yet** that this task built moves out
of that heading and is described as built — as it is, where it differs from the intention.

**A rule adopted from the project lives in its source.** When `jig context` gave you a file
`linked by <id>`, that file owns the topic: edit it, and leave the stub its metadata. Then show
the changed section verbatim and ask; only on the human's yes run
`.ai/scripts/jig knowledge reviewed <id>`, which records the new text as approved. Without that
yes, record nothing: the source stays counted under `sources changed:` for `jig-accept`. An agent
never approves its own edit.

**A team's decision record is never edited** — the source of a stub with `type: adr`, typo
included. A changed decision is a new one. Where the project keeps its own:

```
.ai/scripts/jig knowledge adr-convention
```

For an `adr-dir:` line (ask which, if several), write the new record in that directory with the
`next` number, following the structure and language of the `example`, `git add` that file, then
`.ai/scripts/jig knowledge new adr <slug> --source <file> --proposed`. With `adr-dir: none`, use
`jig knowledge new adr` as always.

## 4. Keep the frontmatter true

`paths` and `domains` are how `jig context` finds a document later; a document nobody can
find is worse than no document. Ask what this task changed about coverage:

```
.ai/scripts/jig knowledge paths --task <id>
```

`uncovered` is code no document claims — either a document should claim it, or the code
genuinely carries no intent worth recording. `unmatched` is a glob that points at nothing
— the code moved or was deleted.

```
.ai/scripts/jig knowledge paths add <id> <glob>
.ai/scripts/jig knowledge paths remove <id> <glob>
```

Then stamp every document you edited as reconciled with the code:

```
.ai/scripts/jig knowledge reviewed <id>
```

That stamp is the whole basis of `jig knowledge stale`. Skipping it does not save time,
it degrades the document to "never reconciled".

A document you edited that has no `summary` gets one now — it is the single line another
agent reads in the context catalog before deciding whether to open the file, and
`knowledge check` warns until it is there. One sentence saying what the document is for,
not a restatement of its title.

Frontmatter is never hand-edited: the commands above own it (ADR-0001, ADR-0010).

## 5. Verify and record the decision

```
.ai/scripts/jig knowledge check
.ai/scripts/jig task set <id> knowledge_consolidated true
```

`task set … knowledge_consolidated true` refuses while a P0 or P1 review finding is unresolved,
or when the change moved after its review; resolve the finding or re-review first ([findings](../jig-review/references/findings.md)).

**In a phase run this task is not yours to finish.** When `jig task show <id>` has an
`autopilot_phase` line, a coordinator started this task as one of a roadmap wave
(adr-20260922-a-phase-run-is-coordinated). Then **stop here**: the rest of this section and §6
are the coordinator's. Stage the change, write the commit message and the pull request body with
`jig task artifact write <id> commit-message --from <file>` and `… pr-body --from <file>`, and report
back. The coordinator ships one task at a time so that two of them cannot merge past each
other, runs `jig task ship` and `jig task autopilot <id> end` itself, and checks the roadmap
item after the merge — `spec done` below refuses in this branch, by design.

Every other run checks the roadmap here, before the commit:

```
.ai/scripts/jig spec done <id>
```

It checks the roadmap items that name the task when its `task.md` carries a `Spec:` line, so
the checkmark reaches the base branch in the same change as the work; for a task with no link
it says so and changes nothing. If it reports that no roadmap item names the task, the roadmap
and the task disagree: ask the human, and do not edit the roadmap by hand.

When it prints `roadmap complete`, the spec is closed in this same change: its decisions are knowledge
now. Run the command it names. It first lists what knowledge does not hold — unchecked items, fog,
open questions, untested assumptions; ask the human about each one, move it where they say (another
spec through `jig-idea`, or a task) or drop it, and run it again with `--leftovers-handled`. A spec on
an epic is closed on the epic by `--finish`, not here.

Then hand the change over. Stage the task's changes — only this task's, hunk by hunk when
the tree holds other work — write the commit message with
`jig task artifact write <id> commit-message --from <file>` (it prints the path, in the task's
workspace and not in a shared directory), and run:

```
.ai/scripts/jig task ship <id> --message-file <the path it printed>
```

It commits, pushes and opens the pull request into the task's base as far as this clone allows —
`agent.git`, or `autopilot.git` for a task in an autopilot run — names the key on its
`git level` line, and says where it stopped. At `merge` it then waits for CI and prints
`merged <url>` or `not merged: <why>`; a pull request left open is an ordinary end — say why.
Exit 3 means `none`: tell the human the change is ready for their review and commit. The step it stopped at is the human's; never finish
it by hand with git. The first line of the message is the pull request's title, the rest its
body: the task's goal and what verified it. When the task edited a file a stub links, the body carries
the block `jig knowledge changed --task <id> --to-review` prints, as it is (an autopilot run's
report holds the same block): only a human approves the new text, in `jig-accept`.

The status stays `ready`: the task is still current, and fixes from review of the commit
or PR continue in it — stage the fix and run `task ship` again. If review changes the implementation, update the same documents; do
not start a new task document for it.

A task cut from an epic (`base_branch: epic/…`) lands when its pull request is merged into the
epic, and closes then like any other. Housekeeping keeps its workspace until the epic reaches the
default branch, so the final review can still read it.

A task whose landing cannot be observed closes now, in §6: `jig task list` shows no
`branch` for it, or the base branch. Housekeeping never sees such a task land (ADR-0025).

## 6. Close the task

Close when the change has landed: `jig-task` found the task flagged `needs-consolidation`
at session start and the user agreed, `jig status` counts it under `needs consolidation`,
or the human says the work is finished.

1. `knowledge_consolidated` must already be `true`. If it is not, run §1–§5 first; the
   knowledge then reaches the repository in a follow-up change.
2. If fixes after the commit changed the intent, update the documents they touched.
3. Ask the human whether a fix is still expected on this task. If one is, leave it open. Two
   exceptions, where the human already said yes: an unattended autopilot run whose `task ship`
   printed `merged`, and a coordinator closing a task of its phase run whose pull request
   merged (adr-20260922-a-phase-run-is-coordinated). Nowhere else does a merge close a task
   without the human.

```
.ai/scripts/jig task set <id> status consolidated
```

The script refuses this while the knowledge decision is unrecorded. Once the task's branch
is confirmed merged, housekeeping moves the workspace to trash; a task whose landing
cannot be observed keeps its workspace, closed and unflagged, because housekeeping never
destroys on `unknown`. A problem found after the close is a new task.

## 7. Report

Ask the repository what changed, rather than reporting from memory:

```
.ai/scripts/jig knowledge changed --task <id>
```

It lists the documents created, modified and deleted since the task forked, untracked ones
included — a document written minutes ago is usually not committed yet — and the sources of
linked documents, marked `source of <id>`; `a decision record` on one of those means a rule
above was broken. Pass `--base <ref>` instead when the task has no fork point.

The command supplies the facts; you supply the meaning. Show what was written — each new
document, and each changed section of an existing one — verbatim, as
[show the document](../jig-task/references/show-the-document.md) says: it binds every agent
that resolves it. After it, say **why it earned a place**, or say `NO_DURABLE_KNOWLEDGE`
and why the task left nothing behind. A list of paths is not a report. Say too whether the
task is closed or waits for its change to land.
