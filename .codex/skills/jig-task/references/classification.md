# Task classification rubric

Answer the risk test first, then name the class. The class is the **highest** one whose
risk test is answered yes — not the first whose examples happen to match. The examples
under each class illustrate the test; they are not a checklist, and they never cover all
the work there is. Work that appears in none of them still has a class.

## The risk test

Three questions about this change being wrong after it ships. Answer them before you look
at any class.

1. **Reversibility.** It shipped and it was wrong — what takes it back? `git revert` is
   cheap. Data already changed, mail already sent, money already moved, another system
   already told: there is nothing to revert.
2. **Radius.** Does the mistake stop with us, or reach users, money, or somebody else's
   system?
3. **Detectability.** Do we find the mistake, or does the person it hurt tell us? Silent
   corruption costs more than a loud outage.

## T0 — Trivial

*Risk test:* one commit takes it back, the radius is this repository, a mistake is visible
at once. One obvious change, no design choice, no new behaviour.

Looks like: typo, wording, comment, formatting, a rename confined to one file, a doc fix.

Route: **implement → verify → consolidate**. No workspace, no artifacts; consolidation is
the `NO_DURABLE_KNOWLEDGE` or knowledge decision stated in the report.

## T1 — Local

*Risk test:* a revert takes it back, the radius is one component, a mistake shows up in a
test or on the next run. Behaviour changes inside one component and the shape of the
change is obvious.

Looks like: a bug fix with a known cause, a small feature inside an existing module, a
test added for existing code. No new dependency, no change to a contract another component
relies on, no data shape change.

Route: **analyze → implement → verify → consolidate**. Workspace only if the task spans
sessions.

## T2 — Structural

*Risk test:* a revert still takes it back, but the radius crosses components — code you
did not edit behaves differently. Several components move together, or an internal
contract changes.

Looks like: a new module inside existing boundaries, a signature or interface used by
other components, a refactor across files, a new command or endpoint following an existing
pattern, a change whose blast radius you cannot state without looking.

Route: **analyze → plan → implement → review → verify → consolidate**. Workspace with
`plan.md`.

## T3 — Architectural

*Risk test:* a revert restores the code but not the decision — the shape of the system
changed, and whatever was built on that shape stays built on it.

Looks like: a new domain or boundary, a change in dependency direction, a new external
dependency or service, a persistence or data-shape change, a change that touches an
invariant in `RULES.md`, or a decision with real alternatives worth recording.

**T2 against T3 is the boundary that costs most to get wrong** — more than T3 against T4,
where both classes stop at a human gate. T2 has no gate at all, so a T3 filed as T2 is an
architectural decision nobody saw. If the change makes a decision others will have to live
with after the revert, it is T3.

Route: **discover → design → HUMAN GATE → implement → architecture review → verify →
consolidate**. Workspace with `design.md`; the gate is a full stop (see SKILL.md).

## T4 — Critical

*Risk test:* a revert does not undo it — something left the machine or changed on disk —
**or** the mistake reaches people who did not ask for it, **or** nobody notices until the
harm is done. Any one of the three is enough.

Looks like: authentication, authorization, secrets; destructive or irreversible data
operations; migrations on live data; money, billing, compliance; a security fix with a
known exploit.

It also looks like these, which is where the class is usually missed, because none of them
sound dangerous:

- a mass send — email, push notifications, webhooks: what went out cannot be recalled;
- a change to permissions or visibility: who can see what;
- a write into somebody else's system (payments, warehouse, CRM);
- a background job that walks a whole table;
- a change of storage format with no migration back;
- a scheduler or cron entry: the mistake repeats itself on its own;
- an index or cache rebuild that runs for hours.

Route: **discover → specify → alternatives → design → HUMAN GATE → implement →
independent review → regression and security verification → consolidate**. Workspace
with `spec.md` and `design.md`. Every review runs in a fresh context; T4's is extended — another
model where the person set one, every acceptance criterion checked, every fixed P0/P1 reverted
until its test goes red (`jig-review`).

## Not T4, however alarming it sounds

- **Reading** any of the above: a report over payments, a query against live data, logging
  what a job would have done.
- A change behind a flag that is off, or in code nothing calls yet.
- A fixture, a seed, or a local test database.
- A rename or a wording change in a file that happens to be named `auth`. The word is not
  the test; ask what a mistake would cost.

## Tie-break

- Unsure about **scope** (how much code it touches): choose the lower class and
  re-classify when it grows. Cheap process first.
- Unsure about **risk** (what a mistake costs): choose the higher class. A wasted review
  is cheaper than an unreviewed migration.
- A task that is trivial to write but hard to undo is not T0. Risk sets the floor: a version
  bump is one line, and a release that has been published and installed cannot be recalled.

## Re-classification

Classification is a first estimate, not a verdict. When a task turns out bigger:

```
.ai/scripts/jig task set <id> class T3
```

Then run the stages the new class requires that were skipped: at minimum design and its
gate for T3, specify and alternatives for T4. Say plainly that the class changed and why.
Never keep a T1 route on work that turned out to be T3. The completion gates hold you to it:
`status ready`, the knowledge decision and `task ship` refuse while a stage of the current
route left no record, and name it.

Lowering a class sheds stages, so it takes a reason the person can read:

```
.ai/scripts/jig task set <id> class T1 --reason "<why the risk test now answers T1>"
```

The reason is kept and shown wherever the class is (`jig task route`, `jig status`, the
autopilot report). An unattended run cannot lower a T3/T4 task below T3.
