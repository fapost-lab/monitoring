---
name: jig-release
description: Plan the next release with the user and carry it out — pick which filed tasks go in and at what version level, order them in the queue, write the release notes against the diffs as the last pull request from the fresh default branch, and ship the release. Use when the user says "plan a release", "plan the next release", "what goes into the next release", "cut a release".
---

# jig-release — plan a release, then make it

A **release** is the pull request that raises the version, and nothing else raises it: feature work
— a task, or an epic's final pull request — reaches the default branch without a version change.
The release is the **notes task**: cut last from the freshest default branch, it describes
everything since the last tag, raises the version and records which commit of the default branch
its notes describe. `jig task ship` refuses a release whose notes do not reach the default
branch's tip (adr-20261112-release-notes-name-the-commit-they-describe). This skill decides **what
goes in** and when the notes start.

How a version is raised, where the changelog lives and who merges a release are the project's own
rules: read them first (`CONTRIBUTING.md`, a release section of the docs, `jig context`). Where
the project says nothing, ask once.

## 1. Look

```
.ai/scripts/jig task list --goals
.ai/scripts/jig spec list
.ai/scripts/jig queue
git describe --tags --abbrev=0
```

Live tasks with the first paragraph of their `## Goal`, open specs and epics, the queue, and the
last release. A task whose goal is `(none)` has a gap in its brief: name it, do not invent one.
Also read what reached the default branch since that tag (`git log <tag>..origin/<default>`): it
is in the release whatever you pick.

## 2. Propose

One document, shown verbatim as [show the document](../jig-task/references/show-the-document.md)
says:

- **What goes in, in order.** Unless the project's knowledge orders work its own way: first what
  **breaks work**, then what **lies about state**, then what **slows work down**; "an agent could
  cheat here" goes last. Within a step, the order the owner gave. One line per task or epic: id,
  goal, class.
- **What is already in.** What reached the default branch since the last tag, by merged pull
  request: it goes out with this release and the notes describe it.
- **The level** — patch, minor or major by the project's rule, over everything since the last tag,
  with one sentence of reason. It is a proposal: the notes check it against the diffs (§5).
- **The shape.** By default the tasks merge into the default branch one by one, as any task does,
  and the notes task is the last pull request. A **release epic** only when the tasks must reach
  the default branch together — none of them may be on it without the others; say why.
- **The notes task** — the last item, filed as T2 so its claims are reviewed in a fresh context.

## 3. The gate

The person approves, changes or rejects the document. Nothing is created before that. In an
unattended run nobody can answer: go on, and put the document verbatim in the notes task's pull
request under `## Release plan — approved by the agent, not a human`. No agent merges a release
outside an unattended run at `merge`, so a person still sees it before the tag.

## 4. Set it up

**By default (no epic):**

1. Give each task going in its priority and order in the queue (`jig queue set`, `jig queue move`).
2. File the notes task (`jig task new release-notes-<YYYY-MM-DD> --class T2`), its goal naming the
   level and the tasks. Make it wait for them: `jig queue depend <notes> --on <task> --reason
   "the notes describe it"` for each. It is not started until §5.

**A release epic** (only when the tasks must ship together): a spec with an epic, as before —
`jig spec new release-<YYYY-MM-DD>` with one phase, an item per task and the notes task last;
`jig spec epic <id> --release <level>` (the `Release:` line is what makes the epic a release); `jig
spec link <id> <task-id>` for each filed task (a started or closed task is refused and stays out);
ship the declaration and cut the epic as `jig-idea` §8 says.

## 5. The notes

When every task going in has merged — into the default branch, or into the release epic with the
latest default branch merged into the epic — start the notes task from the freshest base and give
it the most urgent number of the release (its lowest). It writes the notes as
[release notes](references/release-notes.md) says, raises the version, and records the commit of
the default branch its notes describe:

```
git fetch origin <default>
.ai/scripts/jig task set <notes-task> notes_through <sha of origin/<default>>
```

`jig task ship` writes that into the commit as `Release-Notes-Through: <sha>` and refuses the
release, before anything is sent, while the default branch has commits after it. Something
merged in the meantime is not a failure: describe it, record the new tip, ship again.

It never edits a spec: when the diffs disagree with the planned level, it says so in its pull
request. The level is the person's; unattended, keep the higher of the two — a release is never
made smaller than a person approved, and a `major` still waits for one.

## 6. Release

The notes task's pull request is the release. Who merges it is unchanged: the person — except an
unattended run at level `merge` (`autopilot.git`, else `agent.git`) with `release.merge: agent`
(the default), which merges on green CI after checking the notes again; `release.merge: human`
leaves it to the person; a `major` release is always a draft for a person. A release epic is
finished as `jig-idea` §11 says, and its final pull request carries the notes task's commit, so the
same check holds there.

Then watch CI on the merge commit of the default branch until the release exists (a tag, a
package — whatever the project's CI makes). Some checks run only there. Red is not a release:
file the fix as an ordinary task from the default branch, and release it as a patch from there.

## A fix that cannot wait

A fix needed now is an ordinary task from the default branch, then a release of its own: a notes
task over everything since the last tag. When unreleased work is already on the default branch,
that release carries it too, and the level is read over all of it — a fix after a merged feature
is a minor release, not a patch.
