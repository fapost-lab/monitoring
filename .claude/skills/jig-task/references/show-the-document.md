# Show the document, not a retelling

Whatever a human is asked to agree to reaches them as the document itself. The work will
follow the document, not your summary of it, and a summary drops exactly what you judged
unimportant — the thing the human is there to judge. An approval recorded against a
document they never saw approves nothing.

## When

- **A decision is asked for**: a human gate, the `jig-map` gate, `jig-accept`.
- **A step wrote something others will rely on without rereading it**: analysis notes in
  `task.md`, `plan.md`, knowledge written by `jig-init` or `jig-consolidate`. Show what was
  written. This adds no stop: the route continues unless it already stops here.

Reports that are themselves the result — review findings, verification output — are not
covered.

## How

1. The document, verbatim, as Markdown — not inside a code block, so it renders — between
   horizontal rules, with a link to its file.
2. After it, separately and labelled as yours: what you would do differently, what you
   are least sure of, what undoing it costs.
3. The task's other artifacts as a list: a link and one line each, in full only on
   request.

No length threshold. A long document is shown whole; if you think it is too long, say so
in your comments and propose what to cut. A threshold would be the way back to a summary.

Do not paraphrase, reorder or tidy while copying. If the document needs a change, change
the file, then show the file.

## A repeated gate

After revisions, show every changed section whole — a section is the block under one
heading — verbatim, and name the sections that did not change. Not a line diff: lines out
of context do not read. Not a description of the edits: that is a retelling again.
Workspace files are not in git, so you know what changed because you changed it; if you
do not know, show the whole document.

## Record the decision

At a gate, write in `task.md` (`jig task artifact append <id> task --from <file>`): the date, which documents were shown in full, and the
human's decision in their words — approved, change, or rejected. This is a claim, not
proof (ADR-0020): no script sees the conversation.

An approval covers the document as it was shown. If the document changes afterwards, the
approval no longer covers it: go back to the gate with the changed sections.
