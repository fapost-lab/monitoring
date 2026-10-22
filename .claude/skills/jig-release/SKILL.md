---
name: jig-release
description: Plan the next release with the user and carry it out — pick which filed tasks go in and at what version level, build them on a release epic, write the release notes against the diffs, and ship the release. Use when the user says "plan a release", "plan the next release", "what goes into the next release", "cut a release".
---

# jig-release — plan a release, then make it

A **release** here is a specification with an epic (ADR-0040): one phase whose items are the
tasks going in, an `Epic:` line, and a `Release:` line with the version level. Nothing new is
built for it — `jig spec`, a phase run and `jig spec ship` carry it
(adr-20261002-a-release-is-a-spec-with-an-epic). This skill decides **what goes in**; the rest is
the machinery `jig-idea` §8–§11 and `jig-autopilot` §6 already describe.

How a version is raised, where the changelog lives and who merges a release are the project's own
rules: read them first (`CONTRIBUTING.md`, a release section of the docs, `jig context`). Where
the project says nothing, ask once.

## 1. Look

```
.ai/scripts/jig task list --goals
.ai/scripts/jig spec list
git describe --tags --abbrev=0
```

Live tasks with the first paragraph of their `## Goal`, open specs and epics, and the last
release. A task whose goal is `(none)` has a gap in its brief: name it, do not invent one. Also
read what reached the default branch since that tag (`git log <tag>..origin/<default>`): it is
in the release whatever you pick.

## 2. Propose

One document, shown verbatim as [show the document](../jig-task/references/show-the-document.md)
says:

- **What goes in, in order.** Unless the project's knowledge orders work its own way: first what
  **breaks work**, then what **lies about state**, then what **slows work down**; "an agent could
  cheat here" goes last. Within a step, the order the owner gave. One line per task: id, goal,
  class.
- **What stays out, and why.** A **started** task is never in the epic's list — its branch was
  cut from the default branch, and `jig spec link` refuses it. It still reaches the release if it
  merges into the default branch before the epic is finished; say so.
- **The level** — patch, minor or major by the project's rule, with one sentence of reason. It is
  a proposal: the release notes check it against the diffs (§5).
- **The notes task** — the last item, filed as T2 so its claims are reviewed in a fresh context.

## 3. The gate

The person approves, changes or rejects the document. Nothing is created before that. In an
unattended run nobody can answer: go on, and put the document verbatim in the declaration's pull
request (§4) under `## Release plan — approved by the agent, not a human`. No agent merges that
pull request, so its merge is where a person agrees.

## 4. Set it up

1. `jig spec new release-<YYYY-MM-DD>` — the planning day, so the id never lies when the level
   changes. `spec.md`: the approved document. `roadmap.md`: one phase, an item per task
   (``- [ ] `<task-id>` — <goal>``), the notes task last; waves: the tasks, then the notes.
2. File the notes task (`jig task new`, the `Spec:` line as `jig-idea` §10 writes it).
3. `jig spec epic <id> --release <level>`.
4. For each task that was already filed: `jig spec link <id> <task-id>`. It reads the phase from
   the roadmap and refuses a started or closed task — a refusal is a task that stays out (§2).
5. Ship the declaration and cut the epic as `jig-idea` §8 says: `jig spec ship`, a person merges
   it, `jig spec epic <id>`, `jig spec ship <id>` again to push the epic.

## 5. Go through the list

A phase run (`jig-autopilot` §6) when the run's level (`autopilot.git:` in `jig status`) is `pr`
or more; otherwise each task through
`jig-task`, cut from the epic by `jig task start`. The notes task starts after every other item
is merged into the epic and the latest default branch was merged in: it writes the notes as
[release notes](references/release-notes.md) says. It never edits the spec: when the diffs
disagree with the planned level, it says so in its pull request.

The level is the person's. A disagreement the notes task reported is put to them, and the
`Release:` line is changed on the epic — by whoever keeps the spec there, the coordinator of a phase
run — only with their yes. Unattended, keep the higher of the two levels: a release is never
made smaller than a person approved, and a `major` still waits for one.

## 6. Release

Finish the epic as `jig-idea` §11 says: merge the latest default branch in, `--finish`, raise the
version by the recorded level, `jig spec ship`. The epic is never pushed to for this: `spec ship`
carries the finish on `finish/<id>`, cut from it, and opens the pull request from there, so an
epic protected like the default branch needs no bypass. Who merges is unchanged: the person —
except an unattended run at level `merge` (`autopilot.git`, else `agent.git`) with `release.merge: agent` (the default), which
merges on green CI; `release.merge: human` leaves it to the person; a `major` release is always a
draft for a person.

Then watch CI on the merge commit of the default branch until the release exists (a tag, a
package — whatever the project's CI makes). Some checks run only there. Red is not a release:
file the fix as an ordinary task from the default branch, and release it as a patch from there.

## A fix that cannot wait

The default branch keeps moving between releases. A fix needed now is an ordinary task from the
default branch plus a patch release from there, without the epic. The epic gets it when the
default branch is merged into it, which finishing requires anyway.
