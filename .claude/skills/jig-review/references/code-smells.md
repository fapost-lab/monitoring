# Code smells — the baseline every project has

The Standards reader checks these in every project, including one with no written standard. They
follow Fowler, *Refactoring*, chapter 3, retold here as what each looks like in a diff.

## How a smell becomes a finding

- **Only in the code the task added or changed.** A smell in code the diff merely sits next to is
  not this task's finding.
- **An assessment, never a violation.** Word it as one — "possible Feature Envy: …" — with the
  place and the change it makes harder. A name from the list with nothing behind it is not a
  finding.
- **P3, P2 at most.** P2 only when you can name the concrete change, in this task's own code, that
  the smell makes more expensive. A smell never blocks.
- **The project's rules come first.** A written rule that allows what a smell would flag
  suppresses the finding; what a configured linter or formatter already checks is skipped.
- **These are prompts, not a checklist.** Read the change, then ask whether one of them is there;
  do not walk the list looking for something to report.

## The smells

| Smell | What it looks like in a diff |
|---|---|
| Mysterious Name | A function, variable or type whose name does not say what it does or holds; the reader has to open the body to find out. |
| Duplicated Code | The same logic written twice — in the diff, or the diff copying something that already exists — so a later fix has to find both. |
| Feature Envy | A function that reads and works on another object's data more than its own; it belongs next to that data. |
| Data Clumps | The same few values passed or stored together in several places, with no type of their own. |
| Primitive Obsession | A string, number or bare array standing in for a domain idea with rules of its own — an id, an amount, a status. |
| Repeated Switches | The same condition on the same kind or type, branched on in more than one place; adding a case means finding them all. |
| Shotgun Surgery | One change of intent that had to touch many unrelated places — a sign the concept is scattered. |
| Divergent Change | One module edited for several unrelated reasons in the same diff — a sign it has more than one job. |
| Speculative Generality | A parameter, hook, abstraction or option no caller uses yet, added "in case". |
| Message Chains | A caller walking a chain of objects (`a.b().c().d()`) to reach what it needs, so it depends on every link. |
| Middle Man | A class or function that only forwards to another and adds nothing of its own. |
| Refused Bequest | A subclass or implementation that inherits behaviour it overrides to do nothing, or throws on. |
