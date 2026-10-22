# From a spec: a new project's decisions become knowledge

A project with no code can still have its decisions made: `jig-idea` left a spec in
`.ai/specs/<id>/`. A spec is a plan and `jig context` never reads it (ADR-0035), so until
its decisions are knowledge, the first tasks start without an architecture, rules or ADRs.

## Read

`spec.md` — Idea, Goal and problem, Decisions, Scope — and `architecture.md` and `stack.md`
when the spec has them. Carry **decisions** only. The roadmap, open questions and untested
assumptions stay in the spec: they are plans, and the spec lives until its roadmap is done.

## Route

| In the spec | Goes to |
|---|---|
| What the system is and for whom | the opening of `ARCHITECTURE.md` |
| Modules, layers, the direction dependencies may point | `ARCHITECTURE.md`, under a heading **Intended — not built yet** |
| What implementations of a component boundary may, must and must not do | a `convention` per [boundary](../../jig-task/references/component-boundaries.md), its `--paths` on the directories the code will live in |
| A decision with rejected alternatives — the stack choice included | an ADR: `.ai/scripts/jig knowledge new adr <slug>`; its body cites the spec |
| An invariant with a way to check it | `RULES.md`, each with its source (`spec <id>`) and how it is checked |
| A term a newcomer would get wrong | `GLOSSARY.md` |
| The stack | the profiles: `jig init --profiles generic,<the stack's profiles>` — the `jig` the installer put on `PATH`; the project's own `.ai/scripts/jig` cannot re-run `init` without `--from <framework>` |

A decision with no alternatives and no consequences does not become an ADR; it stays a line
in `ARCHITECTURE.md` or in the spec.

## Say what is not built

Knowledge in a project without code describes an intention. Write it as one:

- Everything under **Intended — not built yet** in `ARCHITECTURE.md` is a promise. The task
  that builds a part moves it out of that heading (`jig-consolidate` does).
- A boundary convention whose paths match nothing yet is reported `planned` by
  `.ai/scripts/jig knowledge stale`, not stale: nothing to reconcile until code exists.
  `knowledge check` warns that its globs match no file; for these documents that is expected.
- Profiles named explicitly are active at once, but their checks `skip` — never `pass` —
  until the project's own tools and manifests exist. Tell the human so.

Then continue with §5 and §6 of the skill: `knowledge check`, and every document shown
verbatim before anyone relies on it.
