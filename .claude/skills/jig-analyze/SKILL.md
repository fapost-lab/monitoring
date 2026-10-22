---
name: jig-analyze
description: Understand a task's problem and blast radius before changing code, using Jig's resolved knowledge. Use after jig-task for T1 and above, or when the user says "analyze", "investigate", "why does this happen", "what does this touch".
---

# jig-analyze — understand before changing

Output is understanding, not code. Finish when you can state the cause and the blast
radius in a few sentences.

## 1. Context first, repository second

```
.ai/scripts/jig context resolve --task <id> --stage analyze --catalog
```

Read every `required:` document; treat `catalog:` lines as a menu, and pull one in with
`--ids <id>` when it looks relevant. Re-run `resolve` whenever the investigation reaches
a file or a domain the first call did not cover — that is what makes the resolution
progressive rather than a single guess at the start. Add `--topics <a,b>` to reach
conceptual knowledge that owns no path.

The resolved set already tells you which decisions and constraints apply, so you do not
have to rediscover them from the code. Only then read code, starting from the entry
points the knowledge names.

## 2. Answer four questions

- **Cause.** For a defect: what actually produces the behaviour, proven by reading the
  code path or by a failing test. Not a guess that fits the symptom.
- **Blast radius.** Which components, contracts and data the change touches. Name them.
- **Constraints.** Which invariants in `RULES.md`, accepted ADRs and conventions bind
  this change. Quote the one that binds hardest.
- **Options.** Where a real choice exists, name the alternatives in one line each.

Run the [ambiguity sweep](references/ambiguity.md) and identify criteria/behavior deltas
using [requirements guidance](../jig-task/references/requirements-and-planning.md).
Standalone research uses `--no-task` and explicit relevance selectors; it need not
classify work or edit task notes. Continue independent investigation while clarifying.

## 3. Check the class

Analysis often reveals the work is bigger or riskier than it looked. If it now matches a
higher class in `jig-task/references/classification.md`, say so and re-classify:

```
.ai/scripts/jig task set <id> class T3
```

## 4. Report

For T2 and above, write the analysis in `task.md` under Notes (append it through jig) so the next session does not
redo the work:

```
.ai/scripts/jig task artifact append <id> task --from <file>
```

Then show the user what you wrote, verbatim
([show the document](../jig-task/references/show-the-document.md)) — not a second, shorter
version of it. Without a workspace, a few sentences to the user are the report. For T3
and T4 this feeds `design.md`.

Stop here. Implementation is the next stage, and for T3 and T4 a human gate stands
between them.
