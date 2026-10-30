---
name: jig-review
description: Review a Jig task's diff against the project's knowledge, rules and conventions before it ships. Use after implementation for T2 and above, or when the user says "review", "check this change", "is this ready".
---

# jig-review — review against the project, not against taste

## 1. Load what the change must satisfy

```
.ai/scripts/jig task changes <id> --base <ref>
files=$(.ai/scripts/jig task changes <id> --base <ref> --format paths)
printf '%s\n' "$files" | .ai/scripts/jig context resolve --task <id> --stage review --files -
printf '%s\n' "$files" | .ai/scripts/jig context guard --task <id> --stage review --files -
```

The list lives in a shell variable, not in a file: it is read twice and is not a document of the task.

Establish ownership and inspect all patches/new contents using
[change scope](references/change-scope.md), adding an explicit allowlist for unrelated work.
The context lists the ADRs, invariants and feature knowledge that bind these files.
Review against those, plus correctness. Style opinions with no rule behind them are noise.

Resolve against the *actual* diff, not the task's original file list — the change reaches
files nobody planned. If the guard reports pending documents, read and acknowledge them
before reviewing: a review that has not read the rules it is reviewing against is a
formality.

Every review is done by a reader who has not seen the implementation: a subagent or a fresh
process, not the session that wrote the change — attended or on autopilot, at every class whose
route has a review. Brief a subagent with the task id, worktree, base, this skill, `task.md` and
the design or plan, and nothing else: no implementer's report, no account of what was done. It
gathers the change and the knowledge itself, with the commands above; an external process gets
the brief [delegation](../jig-task/references/delegation.md) names. Each re-review is a new
reviewer. Who reviews is chosen as delegation says: an `executor: review` line selecting another
runtime, else a `delegate: review` line for this session's runtime, else a subagent on the
session's model. When a selected model or runtime cannot start, do what delegation says for that
runtime — a Codex model or another runtime stops the stage, a model Claude Code refuses falls
back to a subagent on the session's model — and never let this session sign its own review in
its place. Only with neither line, where no subagent can start, review here and say so in the
pull request.

**T4 is reviewed further.** The reviewer runs on another model or runtime than the
implementation when the person configured one; delegation's T4 section says how the two are
compared. Never pick one yourself. Without it, a fresh reviewer on the same model, and the pull
request says the review ran on the implementation's model; that does not stop the ship. Every
acceptance criterion is checked with evidence, and every P0 or P1 marked `fixed` is re-reviewed
by reverting the fix and watching its test go red (§3).

## 2. Look for these, in order

- **Requirements.** Check every criterion in the [acceptance map](../jig-task/references/requirements-and-planning.md),
  including omitted functionality. For UI work inspect [applicable state evidence](../jig-task/references/ui-states.md).
- **Correctness.** Wrong results, unhandled failure paths, race conditions, boundary
  cases. State a concrete input that breaks it, or it is not a finding.
- **Rule and ADR violations.** Quote the rule. An accepted ADR contradicted silently is a
  blocking finding: either the change is wrong or the ADR is stale, and both need saying.
  A MUST NOT in a resolved [boundary document](../jig-task/references/component-boundaries.md)
  is a rule: an implementation that does it is a blocking finding.
- **Contract drift.** Callers, tests and docs that the change invalidated.
- **Evidence gaps.** Behaviour claimed but not covered by a check.
- **Scope creep.** Changes unrelated to the task.

## 3. What you run

A check belongs to a review when it tests a finding. Run `jig verify` once without flags —
the project's setting decides how wide it goes, so it needs none — and targeted filters on
the files a finding names. The run that earns its time is reverting the fix and watching the
new test go red: a test that passes either way proves nothing. Never `jig verify --full` and
never the raw runner over everything (`php artisan test`, `phpunit`, `pytest`, `npm test`
without a filter); the full set is CI's job, and a rerun of a suite that
already passed cannot see the two things that actually get through it
([what a reviewer runs](references/what-to-run.md)).

## 4. Report

Findings ordered by severity, each with file and line, one line of description, and a
concrete fix. Say plainly when there are none. Record each one in the task's ledger with a
severity, as [findings](references/findings.md) says: a finding only said here blocks nothing.
On a re-review, close each `fixed` finding that is fixed and reopen the rest. Last, write the
review's receipt (`jig task receipt <id> --stage review`), which pins what you read: the task's
own change, the knowledge that applies to it, the design and the ledger.

Then either apply the fixes or hand them back, depending on what the user asked. A review
that ends without a decision on every finding is unfinished.

A gap in durable knowledge — something `.ai/knowledge/` should now say about this change and does
not, such as a new module `ARCHITECTURE.md` does not name — is not a finding. List it last, under
**For consolidation**: consolidation writes knowledge after the review, before the commit, and
that leaves the receipt current. Recorded in the ledger, it would stay open and travel past the
merge to the triage task `task ship` files for open findings.

A P3 is never fixed after the review, at any depth: it stays `open` in the ledger and is listed in
the pull request, because a fix after the review makes the receipt stale and asks for another round
for a nit. A person may still ask for the fix; then it is an ordinary edit and a re-review.

At `depth: lean` (`jig task route <id>`) a review is one round, and P2 is left `open` and listed
too. A P0 or P1 is fixed and re-reviewed as always — the ledger blocks until a re-review closes it,
and lean does not change that.

## 5. Re-review

Start with `.ai/scripts/jig task receipt <id> --since-review`; it says whether the re-review may
be narrow, and the script decides, not you.

- **`narrow`** — read the interdiff it prints (what changed since the reviewed state), every
  `fixed` finding against the new code, and the surrounding code only as far as judging the
  interdiff needs: callers of a changed function yes, the rest of the task's diff no. Record only
  findings the interdiff introduced; a P0 or P1 you notice anywhere is still recorded. A P2 or P3
  outside the interdiff is not: the first review saw that code. When it also prints
  `knowledge changed since review`, read each global document's diff too and judge the reviewed
  change against what it added or removed; a finding that diff exposes counts as introduced.
- **`full`** (exit 1, with the reason) — no usable receipt, the design moved, or the knowledge for
  the task's files did: review as for a first one, from §1.
- **`none`** — the receipt is current; there is nothing to re-review.

The receipt at the end is the same: `jig task receipt <id> --stage review`.
