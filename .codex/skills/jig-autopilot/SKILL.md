---
name: jig-autopilot
description: Run one Jig task through its whole route without waiting between stages, stopping only where a human is needed, and hand back an open pull request or a stop that names what is needed. Use when the user says "autopilot", "take this on autopilot", "do it end to end", "finish it without me", or hands over a task to be done unattended.
---

# jig-autopilot — one task, start to finish

The route is the same as without autopilot. What changes: you go from stage to stage without
asking "shall I continue?", and you stop only where this skill says. Asking for autopilot is
the human's consent for this one task; how far you may go with git is the run's level —
`autopilot.git` when the clone sets it, else `agent.git` — and `task ship` reads it itself.

## 1. Start

Classify, file and start the task with `jig-task` (or resume one that is filed). Then:

```
.ai/scripts/jig task autopilot <id> start
```

It prints `autopilot: on (unattended)` when this clone set `autopilot.unattended: true`: then
the run asks nothing, and §5 replaces §3. Say in one line what will happen: the class, the
route and its depth as `jig task route <id>` names them, any stage its `delegate:` lines hand to
a helper, and where the run will end by the `autopilot git:` lines `start` printed (a second,
`autopilot git on <staging>:`, is the level for a pull request into the staging branch) — merged at
`merge`, an open pull request at `pr`, pushed for CI to land at either under
`git.staging_land: external`, or "ready for your commit" at `none`. Offer to
open the status page with `.ai/scripts/jig status --open`, where the human can watch the run
and sees first what it needs from them.

## 2. Run the route

Run each stage's skill in order, and mark it as you enter it:

```
.ai/scripts/jig task autopilot <id> stage <analyze|plan|implement|review|verify|consolidate|...>
```

Exit 4 from `stage`, or from the stage's `jig context resolve`, means a person asked the task to pause: Jig paused it and the stage was not
entered. End the session there — say the task is paused at their request and how to resume
(`jig task resume <id>`, then a new session); this is not a stop, so record none.

- **Review in a fresh context.** Review and architecture review go to a reader who has not seen
  the implementation, briefed as [jig-review](../jig-review/SKILL.md) §1 says. A code review is two
  readers at either depth, Behaviour then Standards, never side by side; only a `narrow` re-review
  is one. They record findings and sign the receipt; you fix, set `fixed`, and a new reviewer does the re-review.
- **A `delegate:` line for this session's runtime hands a stage to a helper** on the model it names — implement, review or
  both ([delegation](../jig-task/references/delegation.md)). Without one, you implement, and the
  review subagent runs on the session's model.
- **An `executor:` line choosing another runtime takes precedence** for its stage. Start
  its CLI from the task worktree under the bounded permissions in the same reference,
  then check the diff, findings and receipt before moving on. A failed selected process
  stops that stage; do not replace it with this session.
- **Helpers are subagents, never sessions.** A reviewer, a delegated stage, a phase run's task
  agent, a repair of the queue: each is a subagent of your runtime (in Claude Code, the Agent
  tool in the background), never a separate session of the app (Claude Code desktop's
  `start_session`). A run goes on in turns an event began — a helper finishing, CI — and a
  runtime may refuse to start a session in a turn the person did not begin, leaving only a card
  for them to click. An `executor:` process (above) is not a session either. Without subagents,
  see phase-run.md, "A runtime without subagents". The one session the app may open is a set
  run's task, which is a run and not a helper (§7, "A session per task").
- **The full set is CI's under `verify.full_run: ci`.** Verify with `jig verify`, never with
  `--full` or the stack's runner unfiltered; `full set left to CI` is not a gap to fill.
- **Each repair costs one attempt.** A repair is one loop of fixing after a blocking finding or
  a red verification, then reviewing or verifying again. Before starting one:

  ```
  .ai/scripts/jig task autopilot <id> repair --reason "<what failed>"
  ```

  Exit 3 means the limit (2 per run) is used up and the run is stopped. Do not try again.
- **The gates are not obstacles.** When `status ready`, the knowledge decision or `task ship`
  refuses, the refusal is the process working: go back to the stage it names. A refusal that
  says `the route of <id> is missing:` names a stage of the route that left no record — the
  gate, a review receipt, verify's `status ready` — and the command that records it.
  A refusal by the project's `hooks.<gate>` is a gate too: when it names something the task's
  work left undone, doing it is a repair. A hook stopped at `hooks.timeout` is a refusal the task's
  work cannot satisfy: a stop (§3, §5), never a repair or a retry. Never run `jig task waive`: a waiver is a person's, and
  the script refuses it while the run is on.

## 3. Stop only here

In an unattended run there are no stops: §5. Otherwise, on a stop, record it, tell the human in plain words what you need from them, and wait:

```
.ai/scripts/jig task autopilot <id> stop --reason "<what is needed>"
```

| Stop | What you ask |
|---|---|
| The human gate of a T3/T4 task | Approve or answer the design, with its `## Gate questions` written (`jig-task`, human gate) — shown as [show the document](../jig-task/references/show-the-document.md) says. The person may answer at the gate from their board: that answers the stop too, and `resume` brings back `gate approved` or `gate answered: <their words>` — rework the design and stop at the gate again on the second |
| `repair` exited 3 | How to proceed: another approach, dismissing the finding (a P0/P1 only with them), dropping the task, or taking it over (§5, "A person takes the task over") |
| Re-classification to T3 or T4 | The gate for the new design. Up to T2, continue and say so in the report |
| A decision nobody made | The decision: a product choice not settled in `task.md`, the spec or knowledge. Never guess one |
| A gate hook refused and the task's work cannot satisfy it | A waiver with their reason (`jig task waive <id> <gate> <path> --reason <text>`), or a fix to the hook |
| A destructive operation | Permission, or another way |

A reason says **what you need from the human**, and nothing about the state of the task. It is
read on a phone: when the person set up Telegram messages, `stop`, `approve`, `decide` and `end`
send their `--reason` there as it is. `approve` and `decide` reach the pull request too: write those
in English. `stop` and `end` reach only the person: write those in their language. One short
sentence — what is needed, what was chosen, how it ended — never a log line like
`repair limit reached`.
It is written once and never rechecked, while the task moves on: a reason that reported
"no pull request" or "verify has not been run" was still saying it hours after both had
happened. The state the page derives itself, fresh, in the cards around the stop.

Destructive means: `push --force`, `reset --hard`, `clean`, deleting a branch or a stash,
rewriting published history, deleting files outside the task's own change, migrating or
deleting data, and anything the runtime asks permission for that the human has not given.
The scripts cannot see your commands — this stop is yours to keep.

After the human answers, quote their answer:

```
.ai/scripts/jig task autopilot <id> resume --answer "<their answer, in their words>"
```

It resets the repair count: the human gave the run a new direction. The answer goes into the
report as given, so never resume without one; in the pull request it gets an English gloss
(§4). Continue from the stage you stopped in.

A stopped run holds no slot (§7). An answer that arrives while you work on something else, or in
another session — `jig status` lists every run waiting, with its question — is recorded, not
acted on: `jig task autopilot <id> answer --answer "<their words>"`. Whoever has a free slot resumes
it with `jig task autopilot <id> resume`, which takes the recorded answer.

## 4. End

Finish with `jig-consolidate`: it records the knowledge decision and ships the change as far
as the run's level allows. Then:

```
.ai/scripts/jig task autopilot <id> end --reason "<how it ended: merged, not merged: <why>, pushed: CI lands it on <staging>, ready for your commit>"
.ai/scripts/jig task autopilot <id> report
```

A `not merged` ship does not finish the run: it stays on until you ship again once it can merge, or `end` it with the reason.

Hand back the pull request link (or "ready for your commit", or the pushed branch CI lands) and the
report. The pull request body — in the commit message when `external` leaves no pull request — is short and in English: what changed and why, the review result, the verify result, and the
report's blocks as they are — never its stage and repair lines, never a task artifact. Its
**Changed linked sources — need your review** block, when there is one, goes into the body as it
is: a file a stub links was edited, and only a human approves the new text (`jig-accept`). It never
stops the run. A person's answer quoted in **Resumed on an answer** or **Taken over by a person**
stays in their words; when it is not in English, add an English gloss after it. Closing the task
after the merge stays as `jig-consolidate` §6 says.

## 5. Unattended: ask nothing

The person who set `autopilot.unattended` cannot answer a stop. Each one becomes the safe
default below, recorded so they read it in the pull request, in plain words, not in jargon —
and on their phone as it happens, when they set up Telegram messages: one short sentence (§3).
Under `git.staging_land: external` there is no pull request: wherever this section says the pull
request or its body, write it in the commit message and the hand-back instead.

| Stop | Instead |
|---|---|
| The gate of a T3/T4 task, or a re-classification into one | Write the design as usual, its `## Gate questions` included and each one taken as recommended, then `jig task gate <id> approved --by agent`, `jig task autopilot <id> approve --reason "<what was approved>"`, and in `task.md` (`jig task artifact append <id> task --from -`): "Human gate — approved by the agent (unattended)". The approve reason, in English, says what was approved and names the ADR or knowledge holding the detail; it is the design's only trace in the pull request, which never carries `design.md` |
| A decision nobody made | The most cautious option that is easiest to undo. `jig task autopilot <id> decide --reason "<what you chose, and why>"` |
| A destructive operation | Never. Find another way or leave that part out, and say so with `decide --reason` |
| A gate hook refused and the task's work cannot satisfy it | Never waive. `stop --reason` naming the hook, then `jig task ship <id> --message-file <file> --draft` (a draft runs no hook), its body starting `Not finished: hooks.<gate> refused: <why>`. The run stays `stopped`; a person waives it and resumes with `--by human` |
| `repair` exited 3 | The run ends unfinished: stage what there is and run `jig task ship <id> --message-file <file> --draft`. The body starts with `Not finished: <why>`, in English like the rest of it. A draft is never merged — under `git.staging_land: external` it is committed and not pushed, since CI lands whatever is pushed; the run stays `stopped`, and the status page shows it waiting. `resume` is refused after the repair limit, including with `--by human`; a person who takes the task on is the one other ending (below) |
| The class turns out lower | Lower it with `jig task set <id> class <Tn> --reason "<why>"`, except out of T3/T4 below T3: the script refuses that unattended, so keep the route. `end` comes after the knowledge decision, never to start a fresh run |

If a person independently answers a run that is already `stopped` in an unattended clone,
quote their actual answer and run `jig task autopilot <id> resume --answer "<their answer>" --by human`.
This recovery is allowed only before the two-repair limit; it preserves the repair count, so a
repair-limit stop still ends in a draft. Never invent the answer to resume yourself. The run
stays unattended: if the design changed, approve the current T3/T4 gate with `--by agent`; the
quoted answer goes in the pull request as given, with its English gloss (§4).
A person's answer to one decision is not their approval of the whole design.

**A person takes the task over.** When a person says they will finish the task, or tells you or
the coordinator to go on with it without autopilot, at the repair limit or at any other stop, quote
their words:

```
.ai/scripts/jig task autopilot <id> handover --by human --answer "<their words>"
```

The run ends there and the task goes on as attended work: no `stage`, `repair`, `end` or new `start`.
If the design changed, show it as [show the document](../jig-task/references/show-the-document.md)
says: whole when the approval it had was the agent's (`gate_by: agent`), the changed sections only
when the person approved it before; then record their approval with `jig task gate <id> approved`.
Then re-review, `jig verify`, consolidate and ship as for any task, at their `agent.git`. The
report's **Taken over by a person** block goes in the pull request, with its English gloss (§4).
Never hand over on your own, or without their words: a run nobody takes over ends in its draft.

What never changes: a P0/P1 is never dismissed, the gates are never worked around, and nothing
is merged but by `task ship`. Before shipping, put `jig task autopilot <id> report`'s
**Decided without you**, **Approved by the agent, not a human** and **Changed linked sources —
need your review** blocks in the pull request body as they are. At the run's level `merge`, `task ship` merges once CI passed or prints
`not merged: <why>` — both are a finished run; say which. After `merged`, close the task
(`jig-consolidate` §6) without asking, then `end`. On the staging flow the ship lands on the
staging branch instead: exit 5 is a conflict you resolve as `jig-consolidate` §5 says, attended or
not; exit 3 on review is a stop when attended, and an unattended run is told to wait. After
`landed …` or `not landed: …`, `end --reason "<that line>"` and do not close the task: it is
**parked** — waiting for review or for "prepare for prod" — and the run is over. Never land it
`--without-review` unless the person said so — inside the unattended run, on or stopped, it is
refused; after `end` it is the person's word, as in any session — never approve its pull request, never run
`jig task promote`. `--by human` is a person's form, for the person or their UI; the agent never
passes it. `autopilot start` and `stage` refuse a parked task, and only a person's
`jig task resume <id>` takes it back for a fix. With
`git.staging_land: external` it prints `stopped at push: … CI lands …` instead: also finished, with
no pull request; end with `--reason "pushed: CI lands it on <staging>"`.

## 6. A roadmap phase

"Run phase N of `<spec>` on autopilot" is a **phase run**: a whole wave of the roadmap at once,
each task built by its own agent in its own worktree, while you act as the **coordinator**. The
mechanics — the loop, the prompt each task agent gets, what to do when one fails — are in
[phase-run.md](references/phase-run.md). Three things hold whatever happens:

- **The coordinator writes no code.** You file the wave, start the agents, ship each task and
  keep the merge queue. The work itself is theirs.
- **A task agent touches neither the spec nor the forge.** It never edits `.ai/specs/`, never
  runs `jig spec done` (the script refuses in its branch) and never runs `jig task ship`. It
  ends at consolidation, with the change staged and its commit message written.
- **A stop holds the next wave, not this one.** The wave in flight finishes; the question goes
  to the person in one message, in your session, and the wave after it waits for the answer.
  Record it with `jig spec stop <spec> --phase <n> --reason "<what is needed>"`: a phase run
  has no journal, and this is what reaches the person's Telegram (§3's one short sentence).

It needs the run's level (`autopilot.git:` in `jig status`) at `pr` or better and a spec
built on an epic. Without either, refuse the
phase run, say which is missing, and offer to run the phase's tasks one at a time instead.

## 7. Several tasks

"Take these tasks on autopilot" is a run over a **set**: each task its own run, started as a slot
frees (`autopilot.parallel`). The set is not the queue. Before each next start — the first one too —
ask:

```
.ai/scripts/jig queue next
```

- **`slots:` says whether a slot is free.** A run that stopped for a person holds none: record the
  stop, put its question to the person, and go on with the next task. Nothing waiting is ever a
  reason to stop the set, however many wait.
- **`resume first:` goes before `next:`.** An answered run resumes on the next free slot, before
  any new task, in the order the line names; never by taking a slot from a run that is on. Resume it
  with `jig task autopilot <id> resume` and continue from the stage it stopped in.

- **It names a task of the set**, or one outside it with no higher priority than the set's next:
  start the set's next. When that is not the task it names, the plain start is refused: use
  `jig task start <id> --out-of-order --reason "<the set the person named>"`. The same holds after
  the person's choice, or an unattended `decide`, below.
- **It names a task outside the set with a higher priority** (a lower number; a task without one
  comes last): start neither silently. Name it to the person and ask whether to take it or keep to
  the set — §3's "a decision nobody made". Unattended: `jig task autopilot <id> decide --reason`
  on a run of the set still on, finish the set's tasks in flight, start nothing new, and say so
  when you hand back. Never take someone else's T3/T4 task to approve its gate as the agent.
- **A task it names as taken by another session** is not free, in the set or out of it: never
  start it; skip it and name it when you hand back.

**A session per task (Claude Code desktop only).** Where the runtime can open a session, and the
person asked in words for the set to run in sessions (`start_session`, `initiation: user_asked`),
each task of a set may get one. Per task: `jig task start <id> --worktree`, then a fresh session
with `cwd` the task's worktree, `use_worktree: false` and `wake_when_done: true`, briefed with the
task id and "run it on autopilot": it begins at §1 itself. Count the sessions you opened as
building, since `slots:` sees a run only once its session has started it. The coordinator keeps
§7's queue reading; the sidebar shows who waits, and a stopped session's last message is its
question. Such a session executes a filed Jig task with its route, workspace and consolidation, so
it does not break the `spawn_task` row of `AGENTS.md`.

- **Only the turn the person began may open sessions.** A start the app refuses stays a card for
  the person: do not start that task's run; name it when you hand back.
- **An answer goes into the session that holds the run.** The person answers in the session, or you
  forward their answer there (`send_message`) and the session runs `resume`. Do not record `answer`
  for it yourself, and if `resume first:` lists it anyway, forward the answer, do not resume it here.
- **Archive its session once the task is `consolidated`**, when the person asked for that: the app
  asks them on each call. Otherwise, and at `pr`, where the set is handed back before the merge,
  name the session when you hand back.

Other runtimes, and phase runs (phase-run.md), ignore this: subagents, one session.
