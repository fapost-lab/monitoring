# Pressure — how to test an idea without a checklist

Pick what fits the idea. A lens applied to everything produces noise, and a lens announced
by name turns a conversation into a form.

## Lenses

- **Premortem.** It is a year later and this failed. What is the most likely story?
- **Second order.** It works. What does that change next — for users, for the code, for
  the people who maintain it?
- **Naive listener.** Explain it to someone outside the project. Which word did you have to
  stop and define? That word is where the idea is vague.
- **Inversion.** What would guarantee failure? Does the plan do any of it?
- **Cost of waiting.** What happens if this is not done for six months? If nothing, why now?
- **Another participant.** How does it look to the user, the maintainer, the reviewer, the
  person running it at 3 a.m.?

## Assumption form

State each assumption as "this holds only if X", then ask "and if not X?". An assumption
nobody can answer "and if not" for is a decision in disguise; record it as one.

## Other shapes

Offer two or three, each concrete enough to compare:

- another audience — who else has this problem, differently;
- another scale — the smallest version worth having, the largest that still holds;
- another form — a script instead of a service, a convention instead of a tool;
- a twist — invert it, add a hard constraint, remove the most expensive part.

End with your recommendation and why.

## Independent failure hunt — the brief

Give the hunter only this, not the conversation:

> Here is an idea and its leading options: <idea>, <options>. Assume it gets built as
> described. Find the ways it fails in practice. For each: the cause, what breaks, and the
> signal by which someone would notice. Rank by likelihood times cost. Do not propose
> fixes and do not praise the idea.

A hunter that saw the conversation inherits its blind spots; that is why the context is
clean.

## Stuck protocol

When the human cannot choose twice in a row, the options are wrong, not the human. Ask one
open question in their terms — "what would make this feel finished?", "what are you most
worried about?" — then build new options from the answer.
