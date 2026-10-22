---
name: jig-accept
description: Walk the knowledge a skill proposed but nobody agreed to yet, decide each one with a human, and apply the decisions. Use after `jig-map` or any stage that left documents in the proposed state, when `jig status` or a colleague mentions pending proposals, or when the user says "what's proposed", "review the proposals", "accept the knowledge".
---

# jig-accept — the human decides, the skill does the bookkeeping

A proposal is knowledge that was written but not agreed to. It sits at its real path and
cannot reach any agent's context until someone accepts it (ADR-0016). This skill is how
someone does that without having to remember what was proposed, when, or under which id.

The person deciding may not be the person who proposed. Assume they are seeing these
documents for the first time.

## 1. Find out what is waiting

```
.ai/scripts/jig knowledge proposed
```

Nothing proposed is a normal answer. Say so and stop.

## 2. Show the documents, then your reading

Number the list yourself and keep the numbering stable for the rest of the conversation.
**The human must never have to type an id.** They answer with numbers, or with "all", or
with the domain name — you translate that into ids.

For each proposal show, in this order:

- its body, verbatim, as [show the document](../jig-task/references/show-the-document.md)
  says. A document that will bind every future agent in this repository cannot be approved
  from a summary, nor from the part of it you judged to matter;
- what it claims, in a sentence of your own — not the document's `summary` echoed back;
- what accepting it would cause: which files its `paths` claim, and therefore which future
  tasks would be required to read it.

Group by domain, one domain's pack per message, when a map produced several packs at
once, and read the map's own
`knowledge-map.md` in the task workspace if one exists — it records the evidence and the
uncertainty behind each proposal, which is exactly what the decision needs.

**A stub that links an existing document** — `jig knowledge proposed` shows it with
`-> <source>` — has no rules in its body. Show the source's path and size
(`jig knowledge sources`) instead, and the source itself when the human asks. Accepting it hands
that file to every agent the stub selects, whole: say what its `paths`, `domains` and `load` make
required, and how large that is. `accept` refuses a stub whose source is missing or not tracked.

Say plainly which proposals you are least confident in. A skill that presents its own
guesses with uniform confidence has hidden the only thing the human is there to judge.

**A linked source changed since it was approved** — `jig status` counts it on its
`sources changed:` line. Agents already read the new text; what is missing is a human's look at it.
For each `changed` or `unrecorded` line of `jig knowledge sources`, show
`jig knowledge sources --diff <id>` (or the source whole when no approved text is stored) and ask:
keep it, which is `jig knowledge reviewed <id>`, or drop the link, which is
`jig knowledge reject <id>`. A `missing` source is fixed by moving the link, not reviewed.

## 3. Ask, and wait

Ask for a decision on every proposal. Then stop.

Do not accept your own proposals, including ones you wrote earlier in this same session.
Silence is not approval, and neither is a reply that only discusses some of them —
carry the rest forward and ask again.

Partial answers are normal and fine. A proposal nobody decided on stays proposed; that is
the state doing its job, not a failure to complete the task.

## 4. Apply

```
.ai/scripts/jig knowledge accept <id> [<id>...]
.ai/scripts/jig knowledge reject <id> [<id>...]
.ai/scripts/jig knowledge check
```

Both commands take several ids and refuse the whole batch if any id is not a proposal, so
apply each decision as one call rather than one call per document.

**Rejecting is not deleting.** The document stays at its path with `status: rejected`: it
no longer resolves, and the next map that proposes the same domain can see the argument
was already had and lost. Do not delete it to tidy up.

**Rejecting a domain pack means "not this domain", not "not this draft."** A pack's path
is fixed by its type and domain — one `OVERVIEW.md`, one `GLOSSARY.md`, one `RULES.md` per
domain — so a rejected pack keeps the only slot that domain has and no better one can be
proposed for it afterwards (ADR-0019).

So when a proposal is nearly right, revise it where it sits, while it is still proposed:
nothing has resolved it, nothing downstream can have read the discarded text, and git keeps
the draft. Then accept the revision. Reject is for the domain you do not want at all.

Which of the two a nearly-right proposal deserves is the human's call, not yours to take.

## 5. Report

State what was accepted, what was rejected, and what is still undecided and therefore
still invisible to every agent. Then run `jig knowledge check` and report it clean, or fix
what it found.

If everything was decided and the domain is now real, `jig context resolve --catalog
--domains <domain>` is the proof: the accepted documents appear, the rejected ones do not.
