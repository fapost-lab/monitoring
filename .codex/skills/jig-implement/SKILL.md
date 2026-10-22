---
name: jig-implement
description: Implement a Jig task — write the change against the project's rules and conventions, then prove it with evidence. Use after analysis or an approved design, or when the user says "implement", "write the code", "make the change", "continue implementation".
---

# jig-implement — make the change

When `jig task route <id>` prints `delegate: implement` for this session's runtime, a helper
on that model does this stage and follows this skill; you hand it over and check its report
([delegation](../jig-task/references/delegation.md)).
An `executor: implement` line selecting another runtime takes precedence: follow the
external-process contract in the same reference, then complete this stage's checks here.

## 1. Know what binds you

```
.ai/scripts/jig context resolve --task <id> --stage implement --catalog
```

Read every `required:` document before writing code. Conventions and invariants are not
suggestions: a change that violates one is wrong even when it works. A `catalog:` line is
metadata only — decide whether it matters, and pull it in with `--ids <id>` when it does.

Then say what you read:

```
.ai/scripts/jig context acknowledge --task <id> --files <list>|-
.ai/scripts/jig context guard --task <id> --stage implement
```

Run the guard before the first edit and again whenever the planned file list grows.
Acknowledge only what you actually read — the ledger records your claim, not your
comprehension, so a guard you satisfied without reading buys nothing and reports a
check that did not happen. When the task has no workspace the guard says so and exits 0;
that line is the honest result, not a pass to quote as one.

For T3 and T4, check that the human approved the design as it was shown to them, in this
conversation, and that `design.md` has not changed since. If there is no approval, or the
document changed after it, go back to the gate with the changed sections
([show the document](../jig-task/references/show-the-document.md)).

## 2. Follow the plan, one step at a time

Before editing, record starting HEAD and existing changes in the task artifact
(`jig task artifact append <id> plan --from -`, never your editing tools — see
[jig-task](../jig-task/SKILL.md) §3); distinguish pre-existing work using the
[scope reference](../jig-review/references/change-scope.md).
Use [requirements and planning](../jig-task/references/requirements-and-planning.md):
if `plan.md` exists, work through it and tick each step after its named check succeeds. If the plan
turns out wrong, fix the plan first and say what changed. Do not silently diverge.

## 3. Write like the codebase, not like yourself

Match the surrounding style, the naming in `GLOSSARY.md`, and the patterns the
conventions describe. Prefer the boring solution that fits the existing shape over a
better one that does not. Where you must introduce a new pattern, say why.

Scope discipline: implement the task, not the improvements you notice on the way. Note
those separately and let the user decide.

## 4. Prove it as you go

Every change carries its evidence: a test for new behaviour, a failing-then-passing test
for a defect, a check that the build still runs. During implementation, run the smallest
relevant checks provided by the project.
Run the checks `jig verify` runs once against the final change in `jig-verify`; do not run
the whole suite after each edit or start another copy while a run is still active.

An unproven claim is not done. If a check cannot run, say so plainly instead of
declaring success.

For UI criteria, follow the [state inventory](../jig-task/references/ui-states.md) and
retain UI evidence for applicable failure states as well as the happy path.

## 5. Report

Update the single acceptance map with real evidence and unresolved checks. Use the
[handoff](../jig-task/references/handoff.md) when the executor/session changes.
Say what changed, in which files, and what the evidence is. For each review finding you
fixed, set it `fixed` (`jig task finding set <id> <F-id> fixed`); closing it is the
re-review's, never yours ([findings](../jig-review/references/findings.md)). Then move to review for T2
and above, or straight to `jig-verify` for T0 and T1.
