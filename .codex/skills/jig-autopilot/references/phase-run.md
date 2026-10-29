# Running a roadmap phase

One phase of a spec's roadmap, wave by wave. You are the **coordinator**: you own
`.ai/specs/`, you start an agent per task in its own worktree, you ship every task and you keep
the merge queue. Nobody else writes to the spec, and nobody else merges.

Read this with `jig-autopilot` §6, which holds the three invariants. Everything here is how to
keep them.

## Before you start

Refuse the phase run, in one sentence naming what is missing, when:

| Missing | Why | Offer instead |
|---|---|---|
| the run's level (`autopilot.git`, else `agent.git`) below `pr` | the run would end as N worktrees nobody committed | the phase's tasks one at a time, as ordinary autopilot runs |
| the spec has no epic (`Epic:` in its roadmap) | a wave is filed by one commit on the epic; on a protected default branch there is nowhere to put it | the same: one task at a time |

Then: the checkout is on the epic, clean, and the epic has not diverged from `origin` (`git
fetch`, fast-forward it). Read the limit — `jig spec plan` prints it, below.

## The loop

**1. Ask the plan.**

```
.ai/scripts/jig spec plan <spec> --phase <n> --format tsv
```

Rows: `parallel <limit> <building>`, `wave <n> <merged|open|waiting>`,
`item <wave> <task-id> <state> <merged> <paused> <autopilot> <next> <title>`,
`blocker <wave> <task-id> <state> <title>`, `problem …`. A `problem` row means the waves list
and the items disagree: stop and ask (unattended: end the run with a report) — a stop of the
run, recorded as below. No open wave with
items of this phase means the phase is waiting on an earlier wave, or is done.

**2. File the wave, in one commit.** For every `item … file` of the open wave, follow
`jig-idea` §10: classify it, `jig task new … --from -` with the exact `Spec:` line, and rewrite
the roadmap item to start with `` `<task-id>` ``. Then commit the roadmap — the new tags plus
any checkmarks you owe from earlier waves — **on the local epic, and do not push it**:

```
git add .ai/specs/<spec>/roadmap.md
git commit -m "File wave <n> of <spec>"
```

`jig task start --worktree` cuts each branch from the fresher of the local epic and
`origin/<epic>`, so every branch of the wave carries this commit by the same SHA: they cannot
conflict over neighbouring roadmap lines, and `jig spec plan` sees the tasks from the first
minute. It reaches `origin` with the wave's first merged pull request.

Before starting each filed task, set its optional executor choices with
`jig task set <id> executor_implement_runtime claude|codex` and the matching
`executor_review_runtime`, `executor_implement_model` or `executor_review_model`
keys. Task state is gitignored and isolated by id: two tasks can choose different
runtimes without changing the clone's shared `config.local.yaml`.
`jig task route <id>` shows each effective choice and its source. `task start`
snapshots all four effective choices, including absent ones, so later changes
to shared local config do not redirect a task. Stop a task with a wrong
assignment and file a corrected one instead of changing the executor under a
running agent. `inherit` removes an override before start.

**3. Start agents up to the limit.** For each `item … start` of the open wave, while
`parallel`'s row leaves a slot free:

```
.ai/scripts/jig task start <id> --worktree          # prints the path
.ai/scripts/jig task autopilot <id> start --phase <spec>/<n>
```

Then start a background subagent with the prompt below — a subagent of your runtime, never a
separate session of the app (`jig-autopilot` §2 says why). A slot is held by an agent still
*building* — run `on`, knowledge not consolidated — so a task waiting its turn to ship frees
one: start the next task of the same wave then. The short-lived agents that repair the queue
(a red check, a merge conflict) are outside the limit.

**4. Collect results — from the files, not the report.** When an agent finishes, or whenever
you look:

```
.ai/scripts/jig task findings <id>       # no open P0/P1
.ai/scripts/jig task receipt <id> --check
```

An agent that reports "done" while the ledger has an open P0/P1, or the receipt is stale, is
not done: send it back. Attended, questions accumulate: when no agent of the wave is still
working (or sooner, if the person is there), send **one** message with every question, each
carrying its document whole, plus the pull requests that are ready and their CI state. Then
record the stop — the run has no journal, and this is what reaches the person's Telegram:

```
.ai/scripts/jig spec stop <spec> --phase <n> --reason "<what is needed, one short sentence>"
```

Every end of the loop that waits for the person is such a stop: questions, a `problem` row, the
forge unreachable, and — unattended — a draft ending the run.
After an answer, resume an attended task with `jig task autopilot <id> resume --answer "<the person's answer>"`.
For an already stopped unattended task with repairs still available, quote the actual answer and add
`--by human`; a repair-limit stop remains a draft and cannot resume. Then tell an agent — the same
one, or a new one — to continue task X from stage Y.

**5. Ship, one at a time.** Tasks with `knowledge_consolidated: true` queue in the order they
became ready. For the head of the queue, from its worktree:

```
.ai/scripts/jig task ship <id> --message-file .ai/workspace/tasks/<id>/commit-message.md [--body-file .ai/workspace/tasks/<id>/pr-body.md]
```

Pass `--body-file` when the task agent wrote a `pr-body.md`; without it the body is the rest of the commit message.

- level `pr` (the `task ship: git level` line) — the pull request is open. Wait for CI (`gh pr checks`) and only with it
  green tell the person it is ready. They merge, in any order; you see it by `git fetch`.
- level `merge` — `ship` waits for CI and merges, or prints `not merged: <why>`; then see
  the table below.

After each merge: `jig task set <id> status consolidated`, `jig spec done <id>` **in the epic
checkout**, `jig task autopilot <id> end --reason merged`, and fast-forward the epic. A task of the
wave that was abandoned instead (`spec plan` shows its item `abandoned`) gets `jig spec drop <id>`
in the epic checkout in place of `spec done`: its branch could not close the item, and the edit is
committed on the epic like a checkmark. Asking for a phase run is
the person's yes to closing a task whose pull request merged, attended too — otherwise the plan
cannot see the merge until housekeeping runs.

**6. Bring the rest of the wave up to date.** For every branch of the wave with work on it that
has not merged:

```
git -C <worktree> merge --no-edit origin/<epic>     # merge, never rebase, never force
```

Then the targeted tests and `jig task receipt <id> --check`. Current (only the spec came in) —
ship again. Stale — a fresh-context re-review focused on what arrived from the base and how it
meets this change, a new receipt, ship again. A conflict goes to an agent in that worktree.

**7. Close the wave.** A wave is finished when all of its tasks merged (unattended: or became
drafts). Only then:

```
.ai/scripts/jig housekeeping
```

Never in the middle of a wave: it touches what is still being worked on.

**Never push the epic yourself.** Where `epic/*` is protected like the default branch, a direct
push goes through only as an administrator's bypass. Every commit of yours on the epic — the
wave's filing, the checkmarks — stays local and reaches `origin` inside the next pull request into
it; the last ones travel in the final pull request, which `jig spec ship` opens from `finish/<id>`.

**8. Round again**, from step 1. A stop in wave N with no answer yet holds wave N+1: say so and
wait. Phase done — report it. Finishing the epic itself is `jig-idea` §11, not this loop.

## The prompt for a task agent

Give each agent its task id, the absolute path of its worktree and its base branch, and these
rules verbatim:

- Work **only** in `<worktree path>`. `cd` there in **every** Bash command — the working
  directory resets between calls. Never touch another worktree or the main checkout.
- Never edit `.ai/specs/`, and never run `jig spec done`: the coordinator checks the roadmap
  after the merge.
- Keep the journal: `jig task autopilot <id> stage <name>` on entering a stage,
  `... repair --reason "<what you are fixing>"` before every repair (exit 3 means stop and
  report), `... stop --reason "<question>"` at a stop; a gate is `jig task gate`. Exit 4 from
  `stage` or from a stage's `jig context resolve` means a person asked the task to pause and Jig paused it: stop work and report that.
- Follow the class's route as `jig-autopilot` §2–3 says (§5 when the run is unattended). Review
  and architecture review go to a subagent in a fresh context, implement and review on the model
  a `delegate:` line of `jig task route <id>` names
  ([delegation](../../jig-task/references/delegation.md)); after its report, check the
  ledger with `jig task findings <id>` — only the ledger closes a finding.
- Run only the tests that cover the changed files, and `shellcheck` at the version CI uses.
  `jig verify` without flags is right — it narrows itself to the project's setting. `--full`
  and the raw runner over everything are not: CI runs the full set
  ([what a reviewer runs](../../jig-review/references/what-to-run.md)).
- End at consolidation: the knowledge decision recorded
  (`jig task set <id> knowledge_consolidated true`), the change staged, the commit message written
  with `jig task artifact write <id> commit-message --from <file>` and the pull request body —
  with `jig task autopilot <id> report`'s blocks — with `jig task artifact write <id> pr-body --from <file>`.
- **Do not run `jig task ship` or `jig task autopilot end`.** Those are the coordinator's.
- Report back: one line of outcome, the paths, the ledger and receipt state, and what is left.

## When something goes wrong

| What | How you see it | What you do |
|---|---|---|
| The agent crashed | its process ended with no `stop` or `end` in the journal and no consolidated state | a new agent: "continue `<id>` from stage `<last stage>`". Repairs are not reset. A second crash on the same task is a stop (unattended: treat as an exhausted repair budget) |
| A person paused the task | the agent reported exit 4 from `stage`; the task is `paused`, its run still `on` | nothing until they run `jig task resume <id>`; then a new agent: "continue `<id>` from stage `<the stage it did not enter>`". The wave waits for it like for a stop |
| The agent hung | no new journal line for a long while, process still alive | attended: into the summary message. Unattended: stop the agent, then as for a crash |
| CI is red | `gh pr checks`, or `not merged: a check failed` | an agent in that worktree: `repair --reason "CI red: …"` (the run is still `on`), fix, targeted tests, re-review, ship again. Exit 3 → a stop, or a draft when unattended |
| A conflict updating the base | `git merge` stopped | an agent in that worktree resolves it keeping both intentions, runs the targeted tests, re-reviews and ships again. If the resolution needs a product decision: stop (unattended: `git merge --abort` and a draft naming the reason) |
| CI or the forge is unreachable | `not merged: …` | attended: into the message. Unattended: the pull request stays open, the wave does not close, and the run ends with a report |
| The epic diverged from origin | `jig task start` dies with "diverged" | `git merge origin/<epic>` into the local epic — never rebase — and carry on |
| A brief with no goal | `jig task start` dies with "has no goal" (T3/T4) | write the goal from the roadmap item and the spec with `jig task artifact write <id> task --from <file>`, and start again; with nothing there to write it from, a stop of the run (unattended: end the run with a report) |

Unattended, a draft ends the phase run: report what landed, what is a draft and why, and leave
the next wave to a person — and record it with `jig spec stop`, the reason naming the draft.

## A runtime without subagents

Some runtimes cannot start one. Then `parallel` is effectively 1: take each task of the wave
yourself, in its worktree, `cd`-ing there in every command, under the same contract — the spec
and `jig task ship` stay yours as coordinator, so nothing about the invariants changes. Review
in the same session, and say so plainly in the pull request body: "reviewed in the same
context". Asking the person to open a session per task is not an option — the people autopilot
is for will not do it.
