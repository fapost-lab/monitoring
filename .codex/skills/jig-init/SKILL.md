---
name: jig-init
description: Bootstrap or refresh a project's durable knowledge with Jig. Use when setting up Jig in a repository, when `.ai/knowledge/` is empty or stale, or when the user says "init jig", "set up Jig for this project", "set up project knowledge", "analyze the project".
---

# jig-init — populate project knowledge

Goal: after this skill, `.ai/knowledge/` states what the project is, which terms are
canonical, how it is structured and which rules hold. Write intent, not a code tour.

## 1. Bootstrap

Run `.ai/scripts/jig status`. If it reports the project is not initialised, run
`.ai/scripts/jig init` (or `<framework>/scripts/jig init` when the scripts are not yet
installed) and show the user what it created. Never overwrite existing knowledge.

When `jig status` prints `instructions (<runtime>): no Jig section in <file>`, the project
kept its own `AGENTS.md` or `CLAUDE.md` and the agent there was never told about Jig. The
section to add lives in `.ai/templates/AGENTS.md`, between `<!-- jig:begin -->` and
`<!-- jig:end -->`. Show the user their file and that section verbatim, and with their
consent append it to `AGENTS.md` **unchanged and with both marker lines** — `jig init`
records the section only when it matches the template byte for byte, so a reworded copy
stays unmanaged; for `CLAUDE.md`, add the line
`@AGENTS.md` unless it should carry the section itself. Never rewrite what the file
already says: the markers go around the section you add, never around text the project
wrote.

Then run `.ai/scripts/jig init`. It writes nothing into `AGENTS.md` — it records the
markers it finds, and from then on `jig upgrade` keeps that section current by itself, so
improvements to what Jig tells an agent arrive without anyone running this skill again.

`instructions (<runtime>): Jig section in <file> is not marked` is the same conversation
with the text already there: show the user how the template's section differs from theirs,
and with their consent replace theirs with the marked one.

## 2. Choose the path

Knowledge is written from code or from decisions. Say in one line which applies and why:

| The repository has | Path |
|---|---|
| Application code | analyze it — §3 to §6 |
| No code yet, and a spec (`.ai/scripts/jig spec list`) | carry its decisions into knowledge — [from a spec](references/from-a-spec.md); with several specs, ask which describe this project |
| Neither code nor a spec | offer `jig-idea` first: the architecture and the stack are decided there, then this skill returns by the spec path. If the human declines, write only what they told you — purpose, terms — invent no architecture, and ask the stack for the profiles |

"No code" is your judgement: only `.ai/`, a README, docs and configuration.

## 3. Analyze the repository

Read only what is needed to answer the questions below. Prefer manifests, entry points,
directory names and existing docs over reading source files broadly.

- What does the system do, for whom?
- Which domains exist and where do they live in the tree?
- Which direction may dependencies point? Which layers exist?
- Which words are used for the core concepts, and are they used consistently?
- Which rules are already enforced (lint config, CI, tests) or clearly assumed?

## 4. Write knowledge

- `GLOSSARY.md`: one entry per core concept; pick the canonical term when the code
  uses several. Keep to terms a newcomer would get wrong.
- `ARCHITECTURE.md`: domains, boundaries, dependency direction, the two or three key
  runtime flows, system-wide invariants. Do not restate implementation.
- `RULES.md`: enforced or clearly intended rules and invariants, each with its source.
- If a decision is visible in the code and worth preserving, create an ADR with
  `.ai/scripts/jig knowledge new adr <slug>` — it names the file by the day, writes the id,
  date and status `accepted` — fill in its body, and give it a one-line summary with
  `.ai/scripts/jig knowledge summary <id> "<text>"`.

Ask the user when a term or boundary is ambiguous; do not guess canonical names.

## 5. Verify

Run `.ai/scripts/jig knowledge check` and fix every failure. Warnings about `paths`
matching nothing are acceptable only for documents that intentionally have no owning
files.

## 6. Report

Show each document you wrote — `GLOSSARY.md`, `ARCHITECTURE.md`, `RULES.md`, any ADR —
verbatim, as [show the document](../jig-task/references/show-the-document.md) says: they
bind every agent from the next session on, and no gate stands before them. Then,
separately, the questions that remain open for the user.

When the project is larger than the three global documents can honestly describe, say so
and offer `jig-map`: it proposes per-domain knowledge, and nothing it infers reaches an
agent's context until a human accepts it. Do not run it as part of init — a map is a
judgement about someone else's codebase and deserves its own gate.

Offer `jig-setup` in one line: the person's own settings — how far their agent may go with
git, whether autopilot may run without asking — are asked there, one question at a time, and
written to their `.ai/config.local.yaml` only after a yes. Never run it as part of init.
