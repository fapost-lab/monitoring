---
name: jig-architecture-review
description: Review a Jig task against the system's architecture — boundaries, dependency directions, invariants and accepted ADRs. Use for T3 and T4 tasks after implementation, or when the user says "architecture review", "does this fit the architecture", "did we break a boundary".
---

# jig-architecture-review — does the system still hold its shape

Code review asks whether the change is correct. This asks whether the system is still the
system its documentation describes. Like every review, it is done by a reader who has not seen
the implementation, briefed and chosen as [jig-review](../jig-review/SKILL.md) §1 says: a new
subagent or process each round, never the session that wrote the change. An `executor: review`
line selecting another runtime takes precedence: use the read-only external review contract in
[delegation](../jig-task/references/delegation.md) and record its checked findings here.

## 1. Load the shape

```
.ai/scripts/jig task changes <id> --base <ref>
files=$(.ai/scripts/jig task changes <id> --base <ref> --format paths)
printf '%s\n' "$files" | .ai/scripts/jig context resolve --task <id> --stage architecture-review --files -
printf '%s\n' "$files" | .ai/scripts/jig context guard --task <id> --stage architecture-review --files -
```

Keep the paths in a shell variable, not in a file, and inspect all change layers via the same
[scope reference](../jig-review/references/change-scope.md) used by code review. Read and
acknowledge pending knowledge before the guard. Check the acceptance map for omitted
requirements too. Use a separate `jig context --task <id> --all` inspection when historical
or rejected decisions matter; diagnostic history is not binding accepted knowledge.

## 2. Check five things

- **Boundaries.** Does any component now know about something it must not? Domain code
  reaching into infrastructure, a module importing across a documented boundary, an
  implementation doing what its [boundary document](../jig-task/references/component-boundaries.md)
  says it MUST NOT.
- **Dependency direction.** Does every new dependency point the way `ARCHITECTURE.md`
  says it may?
- **Invariants.** Does the change preserve every invariant in `RULES.md`? Name the ones
  it touches and how they still hold.
- **Accepted decisions.** Does it contradict an accepted ADR? If the ADR is now wrong,
  the answer is a new ADR superseding it, never a silent departure.
- **New decisions.** Did the change make a choice that deserves recording? If so, it is
  an ADR candidate for consolidation.

An architecture violation shows in the documents and the diff, not in a test run. Where a
claim still needs executing, the review's runs are the ordinary ones — `jig verify` once,
or a targeted filter — and never the raw runner over everything
([what a reviewer runs](../jig-review/references/what-to-run.md)).

## 3. Report

For each of the five, one line: holds, or violated with the evidence. Violations are
blocking: record each as a P0 in the task's ledger
([findings](../jig-review/references/findings.md)), then write the receipt
(`jig task receipt <id> --stage architecture-review`). Escalate a conflict between the change and an accepted decision to the human
rather than resolving it yourself.

A re-review starts from `jig task receipt <id> --since-review`, as
[jig-review](../jig-review/SKILL.md) §5 says: on `narrow`, check the five things against the
interdiff, any knowledge diff it prints and the `fixed` findings instead of loading the whole change; on `full`, start from §1.
Its receipt is `--stage architecture-review` again.

Then hand the ADR candidates to `jig-consolidate`.
