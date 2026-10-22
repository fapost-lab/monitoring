---
name: jig-idea
description: Stress-test an idea with the user and keep the result as a durable specification with phases and a roadmap under `.ai/specs/<id>/`. Use when an idea's shape is not settled yet, when work is too big for one task (tens of tasks, phases), when designing a future project's architecture and stack before any code exists, or when the user says "I have an idea", "poke holes in this", "write a spec", "build a roadmap", "continue the spec".
---

# jig-idea — test the idea, keep the plan

A **specification** is the plan for a large piece of work: the idea as the human said it,
what survived questioning, the decisions, and a roadmap of phases and items. Tasks are filed
from it later — the next day, months later, or in a different repository.

This skill talks and writes the specification. It never starts a task, never changes code,
and writes nothing outside `.ai/specs/<id>/`. `jig-task` stays the one entry into task routes
(ADR-0009); this skill works before it.

A specification is not knowledge. `.ai/specs/` sits outside `.ai/knowledge/`, so
`jig context` never resolves it and `jig knowledge check` never reads it: an agent working
on today's code must not read tomorrow's plan as a description of the system. A spec has no
status; progress is read from its roadmap.

## 1. Open the specification

```
.ai/scripts/jig spec list
```

- **Existing spec.** Before reading or touching anything, put it back on a branch of its own:

  ```
  .ai/scripts/jig spec resume <id>
  ```

  It refuses a dirty tree by the same rule `task start` uses, then switches to `spec/<id>`
  — reusing the branch an earlier session shipped if it is still here, fetching it from
  origin if only that has it, or cutting a fresh one otherwise. A spec with an open epic is
  edited on the epic instead; `spec resume` says so and refuses, rather than cutting a
  `spec/<id>` nothing would ever ship — switch to the epic branch it names first. Only then
  read every file in the directory, starting from its open questions and fog items — that is
  where the last session stopped.
- **New spec.** Choose a short kebab-case id with the user, then create it:

  ```
  .ai/scripts/jig spec new <id>
  ```

  It refuses an invalid or taken id and a dirty tree (the same rule as `task start`), writes
  `spec.md` and `roadmap.md` from the templates, and switches to a branch of its own,
  `spec/<id>` — a spec lives there from its first minute, exactly as a task does once
  started. Fill the files in, starting with the heading of `spec.md`, which names the spec
  in `jig spec list`. Write the idea in the human's own words, not a retelling. Other files
  (`architecture.md`, `stack.md`, `research.md`) are added when the conversation needs them.

**When either refuses a dirty tree**, the uncommitted changes are somebody else's — never
work around it: name what `git status` shows and ask the human to commit or stash it, the
same as `jig-task` does for `task start`. **When `spec new` refuses "switch to `<default>`
first"**, or `spec resume` does, move there yourself (nothing is staged or committed by
either command, so switching costs nothing) and run it again.

A spec is written in the project's durable language (AGENTS.md): it is committed, on its own
branch, and shipped like one — §9 says when.

## 2. Learn what the project already knows

```
.ai/scripts/jig context resolve --no-task --catalog --files <paths> --domains <domains>
```

Name the files and domains the idea touches. In a repository with no code yet, the global
documents are what there is. Facts about the repository you find yourself; never ask the
human something the code can answer.

## 3. Propose a depth

One line: the level and why. The human may pick another.

- **easy** — you take the reversible decisions yourself and list each as an assumption; you
  ask only about the irreversible. Before writing, one question: accept or reject the
  assumptions.
- **normal** — one question per real decision.
- **deep** — every decision with its trade-off visible, every pressure lens that fits, and
  the independent failure hunt (§5).

The level is a budget, not a verdict. When more is open than it allows, say so and offer to
go deeper. Record the level in `spec.md`.

## 4. Three phases, in order

1. **Understand.** The idea in one sentence, who is worse off without it, what success
   looks like. Do not argue yet.
2. **Put weight on it.** Hidden assumptions ("this holds only if X — and if not?"),
   trade-offs, vague words, the cost of being wrong. Use the lenses in
   [pressure](references/pressure.md); pick the ones that fit, do not name them aloud.
3. **Offer other shapes.** Two or three alternatives — another audience, scale or form — or
   a twist (invert it, constrain it, cut it down), each with your recommendation.

Do not skip ahead: an alternative offered before the idea is understood answers a question
nobody asked.

When the spec is for a new project, the shapes include its architecture: two or three
approaches — a plain layered application, modules by domain, ports and adapters, or what the
human names — with what each costs and pays back at this size and expected growth, and the
lightest one always among them. Patterns combine (domain modules with ports at the edges);
none is right by default. Record the choice and the rejected ones in `architecture.md`, the
stack in `stack.md`: `jig-init` carries both into knowledge.

## 5. Independent failure hunt

Always on deep, offered on normal. Give a fresh agent in a clean context — a subagent, if
your runtime has them — the idea and the leading options, with the brief in
[pressure](references/pressure.md). Without subagents, run the same pass yourself as a
separate, announced step. What it finds goes into "Stress test"; the sharpest findings
become decisions or open questions.

## 6. Ask well

- Every question carries your recommended answer and what follows from each option.
- Explain a term the first time it appears.
- One decision per question. Batch only questions that are truly independent.
- Two answers in a row of "I don't know" — ask one open question in the human's terms, then
  return to options (see the stuck protocol in [pressure](references/pressure.md)).

## 7. Write it down as you go

What is decided goes into the spec files immediately — not at the end, where half of it is
lost. Show every written or changed section verbatim, as
[show the document](../jig-task/references/show-the-document.md) says. A rejected option is
recorded with its reason: the next session must not reopen the argument. What is unresolved
goes to "Open questions".

## 8. Roadmap

When the idea has held up, or when asked. Format: the `roadmap.md` that `jig spec new` wrote; its closing
comment repeats these rules.

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
  an epic branch (ADR-0040). Ask the human now how far the epic's final pull request raises the
  version — `patch`, `minor` or `major`, by the project's own rule, with one sentence of reason —
  while they are here to answer; then `jig spec epic <id> --release <level>` writes the `Epic:` and
  `Release:` lines. A spec whose phases each ship on their own gets no line — ask when unsure.
- **Shipping the declaration and the epic.** The line reaches the default branch with the spec:
  stage `.ai/specs/<id>/` and run `jig spec ship <id> --message-file <file>`; once that is merged,
  `jig spec epic <id>` cuts the branch and `jig spec ship <id>` pushes it. `spec ship` goes as far
  as `agent.git` (in an unattended clone, `autopilot.git`) allows and says where it stopped; exit 3, or a stop, means the rest is the
  human's — say what is left, never finish it with git by hand. The same `spec ship` pushes the
  epic after the latest default branch was merged into it; resolve a conflict in that merge, then
  show the resolution to the human before pushing.

Look up the facts the cut depends on ("where does this live", "is this one part of the
code") yourself, in parallel subagents where possible, each with its source. Decide the cut
with the human: show the draft as prose and verbatim in the file, then let them merge, split
and move items between waves.

## 9. End of the session

The session ends when nothing is left open for the chosen depth, or when the human stops.
Close with three lines: the idea after testing in one sentence, its weakest point, the next
step. Leftovers stay in "Open questions"; the next session starts there.

The spec has been on `spec/<id>` since step 1 (`spec new` or `spec resume`); ship what
changed before stopping, so it does not sit uncommitted on a branch only this checkout knows
about — the trap this skill exists to close:

```
.ai/scripts/jig spec ship <id> --message-file <file>
```

It commits, and goes as far as `agent.git` (in an unattended clone, `autopilot.git`) allows from there; a stop or exit 3 means the
rest — push, the pull request — is the human's, and the next step says so. Once it is
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
  questions, untested assumptions. Ask the human about each: move it to another spec or a task, or
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
  finished" and stop there. Drop fog, open questions and untested assumptions with
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
