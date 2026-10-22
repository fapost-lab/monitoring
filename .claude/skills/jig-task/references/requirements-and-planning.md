# Requirements, deltas, and observable completion

For T2+, label in-scope acceptance criteria (AC-01, etc.) and keep one table in plan.md:

| Criterion | Intended check | Evidence reference | Outcome |
|---|---|---|---|
| AC-01: resume preserves status | Resume a paused task and inspect state | Pending | not-run |

Reuse a sufficient map in design.md/spec.md when a separate plan earns no value. Name
that owner; other artifacts link to it. At `depth: lean` (`jig task route <id>`) a T2 has no
plan.md: the map lives in the analysis (discovery.md). T0/T1 need only proportional prose, not a matrix.

For a changed contract describe relevant added, modified, removed behavior and preserved
invariants. Give before/after scenarios where needed, and compatibility consequences for
removals. Keep deltas transient; consolidation updates only the durable topic owner.

Every actionable plan step states its completion check and criterion IDs. One check can
cover several criteria and steps: reference evidence once. Checks can be inspection,
commands, tests or observed behavior; never create tests only to satisfy the table.

Keep pass, fail, not-run and blocked distinct. Skip is not pass. Tick a step only after
its named check supports completion. Unavailable checks and omitted requirements remain
visible gaps; deferring scope requires an explicit user decision, not a green suite.
Review every criterion before reviewing code quality, including behavior with no diff.

Write `plan.md` with `jig task artifact write <id> plan --from <file>`, not with your
editing tools: in a task worktree the workspace is reached through a link, and jig is what
knows where it leads. Once it is written, show it to the user verbatim
([show the document](show-the-document.md)). For T2 that adds no stop to the route.
