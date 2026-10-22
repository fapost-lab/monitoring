---
name: jig-verify
description: Verify a Jig task with evidence — run the project's checks and confirm the task's goal is actually met. Use before declaring work done, or when the user says "verify", "check it works", "run the tests", "are we done".
---

# jig-verify — evidence, not claims

Resolve context with `--stage verify` and the task's explicit selectors before verification;
read required knowledge and use the same selectors for pending/guard.

## 1. Run the project's checks

Reuse completed checks when their code, test inputs, and relevant environment have not
changed. Run missing or invalidated checks; a stage transition alone is not a reason to
repeat them. Documentation-only work needs relevant document checks, not an unrelated
full code suite. Keep required regression coverage for behavioral changes.

```
.ai/scripts/jig verify
```

`jig verify` above is the evidence, run as the project configured it (`verify.full_run`
in `.ai/config.yaml`, schemas/config.md). With the default `local` it runs everything.
With `verify.full_run: ci` — the project's claim that CI runs every check on each pull
request — it narrows itself to what changed since `git.base_branch` and prints a header
naming the mode; that narrowed report is sufficient evidence here as long as it names the
mode, because the full set is proven by CI on the pull request, and a red CI sends the
task back to verify. A check that says `full set left to CI` is that, not a gap to fill: under
`ci` never run the full set yourself — not `jig verify --full`, not the stack's runner without a
filter (`php artisan test`, `phpunit`, `pytest`, `npm test`, `tests/run.sh`) — unless the person
asks for it.

`jig verify --changed` stays the tool for iteration: it narrows the run to what the diff
touches regardless of `verify.full_run`, and each profile reports whether it honoured the
scope or ran everything anyway.

Wait on the run's own handle and read that exit code: `.ai/scripts/jig verify & wait $!`
in plain shell (its report goes to the terminal; do not redirect it into a file in the
working tree), or the completion signal of the tracked background job if
the harness started one. Never poll with `pgrep -f <pattern>` — the polling command's own
command line contains the pattern, so it matches itself and waits forever.

This runs the active profiles: tests, linters, static analysis, whatever the stack
provides. A `skip` means the check did not run, which is not a pass. A missing tool is
worth reporting, not hiding.

For T4 add regression and security checks: the exact scenario that motivated the task,
plus the neighbouring paths a mistake would break.

## 2. Confirm the goal, not just the green

Read the goal in `task.md` and check the change actually delivers it. Tests passing and
the task being done are different claims. Where the goal is user-visible, exercise it the
way a user would.

For T2+, evaluate every row in the [acceptance map](../jig-task/references/requirements-and-planning.md),
link actual evidence once, and keep not-run/blocked checks visible. A green suite cannot
satisfy an omitted criterion. UI criteria require [UI state evidence](../jig-task/references/ui-states.md).

## 3. Check the knowledge still holds

```
.ai/scripts/jig knowledge check
```

Failures are blocking. Warnings about `paths` matching nothing mean a document now points
at files that moved or never existed; fix them during consolidation.

## 4. Report

State what ran, what passed, what was skipped and why. If something failed, say so with
the output before anything else, and do not describe the work as done.

When everything holds:

```
.ai/scripts/jig task set <id> status ready
```

It refuses while a P0 or P1 review finding is open or fixed but not re-reviewed
(`jig task findings <id> --blocking` lists them), and when the code, the design or the
findings changed after the review (`jig task receipt <id> --check` names what), and while a
stage of the task's route left no record — the gate's approval, a review receipt — which it names
as `the route of <id> is missing: …`. That is not a failure to work around: send
the task back to implementation or to re-review, or ask the human about dismissing it
([findings](../jig-review/references/findings.md)).

Then run `jig-consolidate`, whatever the class. `ready` is not the end of a route: a task
left there is never closed, and housekeeping never cleans it up.
