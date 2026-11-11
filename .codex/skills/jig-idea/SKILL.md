---
name: jig-idea
description: Stress-test an idea with the user and keep the result as a durable specification with phases and a roadmap under `.ai/specs/<id>/`. Use when an idea's shape is not settled yet, when work is too big for one task (tens of tasks, phases), when designing a future project's architecture and stack before any code exists, or when the user says "I have an idea", "poke holes in this", "write a spec", "build a roadmap", "continue the spec".
---

# jig-idea — grow the idea, then keep the plan

A **specification** is the plan for a large piece of work: the idea as the human said it,
what survived questioning, the decisions, and a roadmap of phases and items. Tasks are filed
from it later — the next day, months later, or in a different repository.

This skill talks first and writes second. The conversation is there to make the idea larger
and sharper than it arrived — a round that only confirms what the human already said has
done half the work — and nothing is written, committed or pushed until the human says the
idea is ready to be written down (§7). Until then the conversation is kept in a **draft**
that git never sees (§4). It never starts a task, never changes code, and writes nothing
outside `.ai/specs/<id>/` and that draft. `jig-task` stays the one entry into task routes
(ADR-0009); this skill works before it.

A specification is not knowledge. `.ai/specs/` sits outside `.ai/knowledge/`, so
`jig context` never resolves it and `jig knowledge check` never reads it: an agent working
on today's code must not read tomorrow's plan as a description of the system. A spec has no
status; progress is read from its roadmap.

## 1. Open the conversation

```
.ai/scripts/jig spec list
.ai/scripts/jig spec draft list
```

- **A draft of this idea is listed.** An earlier conversation stopped before the yes. Read
  the file `draft list` names, tell the human where it stopped, and go on from there.
- **New idea.** Create no spec yet: no branch, no file under `.ai/specs/`. `jig spec new`
  runs in §7, after the human's yes. Pick a short kebab-case working id for the draft; the
  human may change it when the spec is written. Look at `git status` now: uncommitted
  tracked changes will make `spec new` refuse then, and the human would rather hear that
  before the conversation than after it.
- **Existing spec.** Before reading anything, put it back on a branch of its own:

  ```
  .ai/scripts/jig spec resume <id>
  ```

  It refuses a dirty tree by the same rule `task start` uses, then switches to `spec/<id>`
  — reusing the branch an earlier session shipped if it is still here, fetching it from
  origin if only that has it, or cutting a fresh one otherwise. A spec with an open epic is
  edited on the epic instead; `spec resume` says so and refuses, rather than cutting a
  `spec/<id>` nothing would ever ship — switch to the epic branch it names first. Only then
  read every file in the directory, starting from its open questions, its fog items and
  what it set aside — that is where the last session stopped. The files stay as they are
  until §7.

**When `spec resume` or `spec new` refuses a dirty tree**, the uncommitted changes are
somebody else's — never work around it: name what `git status` shows and ask the human to
commit or stash it, the same as `jig-task` does for `task start`. **When either refuses
"switch to `<default>` first"**, move there yourself (nothing is staged or committed by
either command, so switching costs nothing) and run it again.

## 2. Learn what is already known

```
.ai/scripts/jig context resolve --no-task --catalog --files <paths> --domains <domains>
```

Name the files and domains the idea touches. Then read what else the project has planned:
the other specs (`jig spec list`) and the filed tasks (`jig queue`) — an idea often answers,
or collides with, something already there.

In a repository with no code yet — an idea for a new product — the outside world is the
material: before the first round, look up who already solves this, how, and what they
leave out, where your runtime can search. With code, do that on deep, or when asked.

Facts are yours to find, each with its source, in parallel subagents where your runtime has
them; never ask the human something the code or a search can answer. What you find here is
what your own proposals in §4 are made of.

## 3. Propose a depth

One line: the level and why. The human may pick another. The level is the size of one
circle (§4):

- **easy** — one round. You take the reversible decisions yourself and list each as an
  assumption; you ask only about the irreversible.
- **normal** — two rounds.
- **deep** — three rounds, every decision with its trade-off visible, and the independent
  failure hunt (§5).

The level is a budget, not a verdict: it bounds a circle, not the conversation, and the
human may ask for another circle as often as they like (§7). Record the level in `spec.md`.

## 4. Circles and rounds

A **round** is one message of yours and the human's answer to it. A **circle** is a bounded
run of rounds that ends in a summary (§7). How a round is laid out, where widening looks
and how the frontier is worked out is in [rounds](references/rounds.md).

- **The first round of a circle widens.** Bring two or three thoughts of your own that the
  human did not say, each with its reason. In the first circle the same round also asks
  what you need in order to understand: the idea in one sentence, who is worse off without
  it, what success looks like.
- **The later rounds narrow.** Put weight on what is now on the table — hidden assumptions
  ("this holds only if X — and if not?"), trade-offs, vague words, the cost of being wrong —
  with the lenses in [pressure](references/pressure.md); pick the ones that fit, do not name
  them aloud. Settle the decisions the widening opened.
- **Every round asks the whole frontier:** each question that can be answered now. One that
  hangs on an answer not given yet waits for the next round.
- **A round that changed neither the idea's one sentence nor the list of decisions ends the
  circle early.** There is nothing left in it to spend the budget on.
- **After every answer, save the draft**, without asking — the whole of it, replaced:

  ```
  .ai/scripts/jig spec draft write <id> --from <file>
  ```

  It holds what a session starting cold would need: the idea in one sentence, the decisions
  and the rejected options with their reasons, your proposals and what became of each, the
  open questions, the assumptions you took, the directions not opened, and which round of
  which circle comes next. Write it in the human's language: it is theirs to read, and it
  lives outside git — `jig spec draft list` prints where. For an existing spec the id is the
  spec's, and the draft holds what this session settled and has not written yet.

When the spec is for a new project, the widening includes its architecture: two or three
approaches — a plain layered application, modules by domain, ports and adapters, or what the
human names — with what each costs and pays back at this size and expected growth, and the
lightest one always among them. Patterns combine (domain modules with ports at the edges);
none is right by default. The choice and the rejected ones go to `architecture.md`, the
stack to `stack.md`: `jig-init` carries both into knowledge.

## 5. Independent failure hunt

Always on deep, offered on normal. Give a fresh agent in a clean context — a subagent, if
your runtime has them — the idea and the leading options, with the brief in
[pressure](references/pressure.md). Without subagents, run the same pass yourself as a
separate, announced step. Run it before the circle's last round, so that round can ask
about what it found. What it finds goes into "Stress test"; the sharpest findings become
questions of that round.

## 6. Ask well

- Every question carries your recommended answer and what follows from each option, worded
  so that "yes" accepts the recommendation.
- A proposal of yours is not a question in disguise: say what you would add and why, and
  let the human take it, leave it or take it further.
- Explain a term the first time it appears.
- Read the round before sending it. If the human could answer all of it with yes or no and
  neither of you would know anything new, it only confirms: rewrite it.
- Two answers in a row of "I don't know" — ask one open question in the human's terms, then
  return to options (see the stuck protocol in [pressure](references/pressure.md)).

## 7. Close the circle, and write only after the yes

A circle always ends with the same message, laid out as
[rounds](references/rounds.md) shows: the idea in one sentence, everything you would write
down — every assumption you took instead of asking included — and the directions you see
and did not open. Then ask one thing: write it down, or another circle — and on which
direction. Wait.
Anything the human adds, corrects or widens opens a new round. You never start another
circle on your own, and you never write on your own: a "yes" to a question inside a round
is an answer to that question, not the yes to write.

**After the yes**, and not before:

- **New spec.** Choose a short kebab-case id with the human. If it is not the draft's id,
  rename the draft first — `jig spec draft rename <draft-id> <id>` — so the ship finds it.
  Then create the spec:

  ```
  .ai/scripts/jig spec new <id>
  ```

  It refuses an invalid or taken id and a dirty tree, writes `spec.md` and `roadmap.md`
  from the templates, and switches to a branch of its own, `spec/<id>`. Fill the files in,
  starting with the heading of `spec.md`, which names the spec in `jig spec list`. Write
  the idea in the human's own words, not a retelling. Other files (`architecture.md`,
  `stack.md`, `research.md`) are added when the conversation needed them.
- **Existing spec.** Edit its files on the branch §1 switched to.

Write everything the summary held. A rejected option is recorded with its reason: the next
session must not reopen the argument. What is unresolved goes to "Open questions", an
assumption you took to "Assumptions left untested". What the
human liked and put off goes to "Set aside" with the reason; a direction from the summary that
nobody opened goes there too, as `unexplored:` — the next session starts from that list.

A spec is written in the project's durable language (AGENTS.md), whatever language the
conversation was in. Show every written or changed section verbatim, as
[show the document](../jig-task/references/show-the-document.md) says, then ship it (§9).
A correction the human makes to what was shown is one more commit on the same pull request.

**If the human stops before the yes**, the draft holds the conversation: say that the next
session will go on from it, and name its id.

**The draft goes on its own.** `jig spec ship` moves it to trash once the spec is committed
and says `draft consumed`. Otherwise a draft stays until the human asks for it to go: only
then run `jig spec draft drop <id>`. Never drop one because it looks old or finished, and do
not offer to while its conversation is unfinished.

When the ship stops before it commits — exit 3 at `agent.git: none`, or a spec on an epic,
whose edits the epic's own ship carries — the draft stays although the spec is written. Say
so, and name `jig spec draft drop <id>` for the human to run once the spec is committed.

## 8. Roadmap

When the idea has held up, or when asked. The cut is part of the conversation: draft it in
a round, and write it with the rest after the yes (§7). Format: the `roadmap.md` that
`jig spec new` writes; its closing comment repeats these rules.

- A destination sentence first; without it there is nothing to check items against.
- Items are finished slices that make the product noticeably better, never layers
  ("backend", "tests").
- A dependency carries a one-line reason. No reason, no dependency: a false edge turns
  parallel work sequential.
- An area whose question cannot be stated precisely yet is a `fog:` item. Do not split or
  size it; it becomes real items once the fog lifts.
- Waves group items that can run at the same time, in separate worktrees (ADR-0029). Wave N
  depends only on earlier waves.
- No dates and no point estimates: order is the priority.
- **Released once, at the end?** When no phase gives a user anything on its own, the spec gets
  an epic branch (ADR-0040). Ask the human in a round how far the epic's final pull request raises
  the version — `patch`, `minor` or `major`, by the project's own rule, with one sentence of reason —
  while they are here to answer. The command writes `roadmap.md`, so it runs after the yes (§7), once
  the spec exists: `jig spec epic <id> --release <level>` writes the `Epic:` and `Release:` lines. A spec whose phases each ship on their own gets no line — ask when unsure.
- **Shipping the declaration and the epic.** The line reaches the default branch with the spec:
  stage `.ai/specs/<id>/` and run `jig spec ship <id> --message-file <file>`; once that is merged,
  `jig spec epic <id>` cuts the branch and `jig spec ship <id>` pushes it. `spec ship` goes as far
  as `agent.git` (in an unattended clone, `autopilot.git`) allows and says where it stopped; exit 3, or a stop, means the rest is the
  human's — say what is left, never finish it with git by hand. The same `spec ship` pushes the
  epic after the latest default branch was merged into it; resolve a conflict in that merge, then
  show the resolution to the human before pushing.

Look up the facts the cut depends on ("where does this live", "is this one part of the
code") yourself, in parallel subagents where possible, each with its source. Decide the cut
with the human: show the draft in a round, then let them merge, split and move items
between waves.

## 9. End of the session

The session ends when the human says to write, or stops. Close with three lines: the idea
after testing in one sentence, its weakest point, the next step.

Ship once, as the last step, everything the session wrote:

```
.ai/scripts/jig spec ship <id> --message-file <file>
```

One commit, one push, one pull request: the yes of §7 covers it, and nothing is committed
or pushed before that yes. It goes as far as `agent.git` (in an unattended clone,
`autopilot.git`) allows; a stop or exit 3 means the rest — push, the pull request — is the
human's, and the next step says so. A session that wrote nothing ships nothing. A request
to file a phase's tasks (§10) is its own yes for the roadmap rewrite, and that session ships
the same way. Once it is
merged, the next session opens with `jig spec resume <id>` (§1), never straight back onto
the branch left behind.

In a project with no code yet whose `ARCHITECTURE.md` and `RULES.md` are still the templates,
the next step is `jig-init`: it carries the spec's decisions into knowledge and turns on the
stack's profiles ([from a spec](../jig-init/references/from-a-spec.md)). Offer it once the
decisions are settled; without it the first tasks start knowing none of them.

Check the result:

```
.ai/scripts/jig spec list
```

## 10. File a phase's tasks — only when asked

"File the tasks for phase N": for each item of that phase with no task id and not `fog:`.
Asked in the middle of a circle, it waits: close the circle and write what it settled (§7)
first, so the roadmap is not rewritten ahead of the yes. The same when `jig spec draft list`
shows a draft of this spec from an earlier session: the ship that follows the filing would
take that draft with it, so say it is there and settle it first.

1. Classify it with [the rubric](../jig-task/references/classification.md); say the class and
   the risk-test answer that decided it in one sentence.
2. File it from an excerpt — a heading, the link line, the item's goal, its boundary, its
   dependencies with their reasons:

   ```
   .ai/scripts/jig task new <task-id> --class Tn --domains <a,b> --from - <<'EOF'
   # <title>

   Spec: .ai/specs/<spec-id>/ — Phase <n>
   ...
   EOF
   ```

   Write the `Spec:` line exactly so: `jig spec done` and `jig spec remove` read it.
   Then give it a priority: `.ai/scripts/jig queue set <task-id> --priority <0-5>`, as
   [task priority](../jig-task/references/priority.md) says.

3. Rewrite the item in `roadmap.md` to start with the id: ``- [ ] `<task-id>` — <goal>``. One task
   may cover several items; each of them then names it. Show the changed phase verbatim.

A spec with an open epic is edited only on the epic — filing included: switch to the epic
first. Anywhere else `jig spec list` says `progress is on the epic`.

Rewriting `roadmap.md` here is editing the spec: it happens on `spec/<id>` (or the epic),
never straight on the default branch — the reason §1 resumes the spec before this step is
ever reached, not after.

A task filed earlier, outside the roadmap, joins a phase the other way round: write its item
first, then `jig spec link <spec-id> <task-id>` writes the `Spec:` line for the phase that item is
in. It refuses a started task — its branch is already cut, and it stays where it was cut from.

The tasks are filed, not started. When the human wants to begin one, hand it to `jig-task`. The
item is checked later by `jig spec done`, called from consolidation — never by hand.

## 11. Moving or dropping a spec

- **Finishing an epic**, when the human says every phase is in: merge the latest default branch
  into the epic and run `jig spec epic <id> --finish` on it (or on a branch cut from it: the
  epic may be protected like the default branch, and nothing here pushes to it). It removes the spec — its decisions are
  knowledge by now — and first lists what knowledge does not hold: unchecked items, fog, open
  questions, what was set aside, untested assumptions. Ask the human about each: move it to another spec or a task, or
  drop it; then run `--finish --leftovers-handled`. It prints the recorded `release:` level; raise
  the version by it (propose one, and let the human confirm, when it says `not recorded`), stage the
  removal with the bump and run `jig spec ship <id> --message-file <file>`: it commits, pushes the
  epic's finish on a branch of its own, `finish/<id>` — the epic itself is not pushed — and opens the
  pull request into the default branch from it as far as `agent.git` (in an unattended clone, `autopilot.git`) allows. Reviewing
  and merging that pull request is the human's — the merge is the release — except in an
  unattended run, below. If review needs a fix,
  `jig spec epic <id> --reopen` on the epic brings the spec back from git; fix it as an ordinary
  task, finish again and ship again: the open pull request is reported, not duplicated.

- **Finishing an epic unattended** (`autopilot.unattended: true`, nobody to ask): finish only
  when every roadmap item that is not `fog:` is checked — otherwise report "the epic is not
  finished" and stop there. Drop fog, open questions, what was set aside and untested assumptions with
  `--leftovers-handled`, and quote each one verbatim in the pull request body under
  `## Dropped without you`. Raise the version by the recorded level, `minor` when none was
  recorded. At level `merge` (`autopilot.git`, else `agent.git`), `spec ship` merges with a merge commit once CI passed — unless
  `release.merge` is `human` in this clone, which leaves every release to the person — and
  opens a `major` release as a draft that needs a human instead; `not merged: <why>` leaves the
  pull request open — say why.

- **Starting a new project from a spec**: copy `.ai/specs/<id>/` into that project, which needs
  Jig 0.3.0 or later. From then on its own Jig tracks the spec; nothing links the two copies.
  Task ids in a copied roadmap belong to the old project.
- **Closing a spec with no epic**: `jig spec close <id>` removes it; when no task's pull request carries
  the removal, `jig spec ship <id> --message-file <file>` ships it alone (`mode: remove`, branch
  `close/<id>`), as far as `agent.git` allows.
- **Dropping a spec**: `jig spec remove <id> --dry-run` shows what would happen — open tasks
  unlinked, never-started ones abandoned only with `--abandon-unstarted`, the directory moved to
  trash. Run it without `--dry-run` once the human agrees.
