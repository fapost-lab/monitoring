---
name: jig-map
description: Propose a domain-aware knowledge map for a project and route the accepted parts into `.ai/knowledge/`. Use after `jig-init` when a project has only the three global documents, when `.ai/knowledge/` does not describe the domains an agent keeps rediscovering, or when the user says "map the knowledge", "what are our domains", "propose knowledge structure".
---

# jig-map — propose the map, let a human accept it

The hard part is not collecting facts; scripts do that. It is deciding what a codebase's
domains actually are, which is a judgement, and judgements must not become project
knowledge until someone agrees with them.

## 1. Collect the facts

```
.ai/scripts/jig knowledge inventory [--scope <dir>]
.ai/scripts/jig context resolve --no-task --catalog [--domains <domains so far>]
git ls-files | .ai/scripts/jig knowledge paths --files -
```

The first names the tracked files at the repository root — where manifests live, and
recognising what `composer.json` or `go.mod` implies is your judgement, not the
command's — plus the runtime instruction files, where the tracked code sits, and the
documents that may already hold rules. The second gives what knowledge already exists; on a
first pass there are no domains to name. The third gives where knowledge is missing across the
whole repository: `uncovered` is code no document claims, `unmatched` is a document pointing at
code that moved. Without `--files` it looks only at what changed on this branch. A proposed
document's globs already count as coverage there, although nothing resolves it.

Read the code the inventory names. A map proposed from directory names alone is a guess
with a table of contents.

## 2. Adopt what the project already has

A project that adopts Jig often keeps its rules somewhere already: `docs/`, its own ADRs,
`CONTRIBUTING.md`, instruction files of other tools. Proposing new documents beside them makes
two copies of every rule. The inventory lists the candidates: `instructions:` lines, and `doc:`
lines with their git state and size. Read them. Everything below goes into the
`knowledge-map.md` §4 describes — start it now, in the task workspace, with `jig task artifact write <id> knowledge-map --from <file>` (`append` as you go); if you are not in a task,
file one with `jig-task` first.

Files `jig init` wrote — `AGENTS.md`, and `CLAUDE.md` when it only points at `AGENTS.md` — are
Jig's own, not candidates. A `skipped:` directory was not inspected: look inside the ones that
could hold rules (`notes/`, `docs-private/`), never dependency or build directories (`.venv/`,
`node_modules/`), and say which you opened.

- **Pick the rule-like documents**: conventions, ADRs, anything that helps maintain the code.
  Skip READMEs, changelogs, API references and guides for people, and name what you skipped in
  `knowledge-map.md`.
- **Instruction files, by the runtimes in `adapters` of `.ai/config.yaml`.** A file every
  configured runtime loads on its own is not linked — it would be read twice. `CLAUDE.md` in a
  project that also runs Codex is linked, unless it only points at `AGENTS.md`. Another tool's
  file (`.cursorrules`, `.cursor/rules/*.mdc`, `.github/copilot-instructions.md`) is linked.
  Only a tracked file can be linked: an instruction file marked `(untracked)` or `(ignored)` is
  copied like any other untracked candidate. `CLAUDE.local.md` is never touched.
- **Duplicates and contradictions** get their own section in `knowledge-map.md`: the rule, where
  each version is written, how they differ, and how you would reconcile them. Settle nothing
  silently — existing rules keep their authority until the human decides.
- **Link each tracked rule document in place** with a proposed stub:

  ```
  .ai/scripts/jig knowledge new <adr|convention|feature> <slug> --source <path> --proposed [--domains <a,b>] [--paths <globs>]
  .ai/scripts/jig knowledge summary <id> "<what the source is for>"
  ```

  The type is what the source is: a recorded decision is `adr`; rules for writing, structuring
  or contributing code — architecture and layering documents included — are `convention`; how
  one part of the product behaves is `feature`. A team's ADR keeps its own number in the slug
  and gets no `paths`: it stays in the catalog. Give `--domains` and `--paths` only when the
  source really is limited to them; a project-wide document gets neither, so every catalog lists
  it and it is required only through `--ids` or `load: always`; `knowledge check` warns about it. Propose
  `load: always` only with the source's size in front of the human. Replace the stub's placeholder
  heading with the source's title and give it a summary. Write the size of every source into
  `knowledge-map.md` (`doc:` lines carry it; for an instruction file, `wc -c`). A line saying
  `linked by` already has a stub — do not propose it again.
- **Untracked and ignored candidates** are copied, one at a time, when the human wants the file:
  show it whole first — it may be a private note, and it may hold a secret. Then

  ```
  .ai/scripts/jig knowledge new <adr|convention|feature> <slug> --copy <path> [--domains <a,b>] [--paths <globs>]
  ```

  It refuses a tracked file, prints another tool's frontmatter it dropped, and lists `line <n>:
  <kind>` for anything that looks like a secret, never the value. On that refusal show those lines
  to the human; real secrets are removed from the file by them, then run it again with
  `--secrets-reviewed`. The copy is proposed. Say that the original stays where it is and that the
  other tool may keep loading it; Jig never deletes it. Run `jig knowledge check`: relative links in
  a copied body may no longer resolve.

An accepted stub hands agents its source, whole, wherever the stub is selected: at the gate,
put each source's size next to what its `paths` and `domains` would make required.

## 3. Separate what you saw from what you concluded

Every statement in the proposal is labelled:

- **observed** — it is in the repository; name the file or the command that shows it.
- **inferred** — you concluded it from evidence; give the evidence and say how sure.
- **proposed** — you are suggesting it should be true. This is where rules live.

A rule with no evidence is a proposal, not an observation, however obvious it looks.
Mislabelling here is the failure this skill exists to prevent: an inference that reads as
a fact becomes a rule nobody remembers agreeing to.

## 4. Write the proposal

`knowledge-map.md` in the task workspace, written with `jig task artifact write <id> knowledge-map --from <file>`: candidate domains, their boundaries, the
evidence for each, and — as its own section — **what you could not determine**. A map
that claims complete coverage of a codebase it read for twenty minutes is not credible.

Then create the documents at their real paths, proposed from the start:

```
.ai/scripts/jig knowledge new domain <domain> --proposed
.ai/scripts/jig knowledge new glossary <domain> --proposed
.ai/scripts/jig knowledge new rule <domain> --proposed
```

Then fill them in. A proposed document is validated by `knowledge check` and visible as a
normal diff, but `jig context` will not resolve it — so nothing you inferred can reach
another agent before a human has seen it. Never create one without `--proposed` and
demote it afterwards: until the status changes, the half-written document resolves as
project knowledge.

Give every document a `summary`. It is the one line an agent reads in the catalog when
deciding whether to open the document; without it the catalog says nothing.

An interface with several implementations is a boundary. Propose its MAY / MUST / MUST NOT as a
`convention` ([boundaries](../jig-task/references/component-boundaries.md)), `--proposed`, every
line a question for the human — "promised, or incidental?" — and keep only what they confirm:
the code shows what implementations do, not what they are allowed to do.

Do not write to `GLOSSARY.md`, `ARCHITECTURE.md` or `RULES.md`. Those are the project's
own, and a map proposes domains, not project-wide law.

## 5. Human gate

Stop. Show `knowledge-map.md` whole, then the proposed documents one domain at a time,
each verbatim, as [show the document](../jig-task/references/show-the-document.md) says.
After them, yours: which proposals you are least sure of and why, and what you would drop
first if the human wants fewer. Wait.

Do not accept your own proposal. Silence is not approval.

## 6. Accept, then validate

```
.ai/scripts/jig knowledge accept <id> [<id>...]
.ai/scripts/jig knowledge reject <id> [<id>...]
.ai/scripts/jig knowledge check
```

Accept what was approved and reject what was not. Rejecting sets `status: rejected` and
leaves the document where it is: it stops resolving, and the next map to propose the same
domain can see that the argument was already had. Do not delete it.

Then report what entered `.ai/knowledge/` and what was turned down.

The gate does not have to close in this session. Anything left proposed can be decided
later with the `jig-accept` skill, which enumerates proposals so nobody has to remember
the ids.
