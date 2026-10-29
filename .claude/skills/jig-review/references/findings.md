# Findings — record them, so completion can refuse

A finding said only in the conversation stops nothing. Record every finding in the task's
ledger, and the scripts refuse to mark the task `ready`, to record its knowledge decision and
to ship it while a serious one is unresolved. A task without a workspace has no ledger;
report its findings in the conversation as before.

```
.ai/scripts/jig task finding add <id> --severity P1 --where <path:line> --summary "<one line>"
.ai/scripts/jig task finding set <id> <F-id> fixed|closed|open
.ai/scripts/jig task finding set <id> <F-id> dismissed --reason "<why>"
.ai/scripts/jig task findings <id> [--blocking]
```

## Severity

| | Means | Blocks completion |
|---|---|---|
| P0 | Breaks data or security, or violates an invariant or an accepted ADR | yes |
| P1 | A wrong result or a broken path that will be hit | yes |
| P2 | Worth fixing; the code is correct without it | no |
| P3 | A nit | no |

A P3 is never fixed after the review, at any depth: it stays `open` and is listed in the pull
request. P2 is fixed at full depth, and only left open on lean. When the task ships, `task ship`
hands every P2 and P3 still `open` to one triage task, `<id>-findings`, filed not started: a person
decides each one there. A gap in durable knowledge is not a finding at all — the review lists it
for consolidation, which writes it before the commit. A fix the human asks for after the
review is an ordinary edit followed by a re-review.

State the concrete input that breaks it, or it is not a P0 or P1. When unsure between two
levels, pick the higher one: a blocking finding costs a re-review, a missed one ships.

## Who moves a finding

- **Review records** every finding as `open`.
- **Implementation fixes** it and sets `fixed`. The author never closes a finding.
- **Re-review closes**: it starts from `jig task receipt <id> --since-review`, which says whether
  it may read only what changed. After the fixes, the reviewer reads each `fixed` finding against the
  new code and sets `closed`, or `open` when it is not fixed. A P0 or P1 in `fixed` still
  blocks until then.
- **Dismissing** — the finding is wrong, or the human decided not to fix it — needs a reason.
  A P2 or P3 you may dismiss on your own. A P0 or P1 only with the human's yes in the
  conversation: show the finding, say why, and put their decision in the reason.

`closed` and `dismissed` are final; a regression reopens the finding with `open`.

## Sign the review: the receipt

A review ends with a receipt, written after its findings are recorded — a re-review writes it
again:

```
.ai/scripts/jig task receipt <id> --stage review|architecture-review
```

It pins what the review read: the task's own change against its base (everything but
`.ai/knowledge/` and `.ai/specs/`, which consolidation writes afterwards), the knowledge `jig
context` resolves for that change, the approved `design.md`, and the ledger as it stands. A change
to any of them afterwards — code edited, a convention the review applied rewritten, a finding closed
by its author — makes the receipt stale (merging the base into the branch does not, unless it moves
the task's diff or that knowledge), and `ready`, the knowledge decision and `task ship` refuse until a re-review writes a new
one. A commit that changes no content leaves it current. A T4 task cannot be finished without one.
`jig task receipt <id> --check` says whether it still holds.

Never write a receipt for a review that did not happen, and never rewrite one to get past a
refusal: the refusal means the change is not the one that was reviewed.

