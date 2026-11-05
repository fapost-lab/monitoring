# Task priority

The queue holds the priority, order and dependencies of a project's tasks, and `jig queue next`
advises from it. A task not in the queue is never advised, however urgent it is; one queued without
a number comes last.
You set the number yourself and say which one you set: a write is one command, outside git, and
one command takes it back.

## The scale

Each number means one thing:

| Priority | When |
|---|---|
| `0` | Something is broken or dangerous: data loss, a destructive operation, an install that fails |
| `1` | A bug a user meets |
| `2` | Not a bug, but it stops a user doing their own work |
| `3` | Friction: the work gets done, with more effort than it should take |
| `4` | An improvement or a new capability |
| `5` | Some day |

## When

- **Filing a task:** right after `jig task new`:

  ```
  .ai/scripts/jig queue set <id> --priority <0-5>
  ```

- **Asked to set priorities, or to order the tasks:** read `jig task list --goals` and `jig queue`,
  give every active task that has no number one, and show the result of `jig queue`. The answer is
  the queue, not a list in the chat. `jig task list` shows no priorities; `jig queue` does.

Two tasks stay out of both: a triage task (`<id>-findings`), since a person decides what it holds and
no autopilot should pick it up, and a release's notes task until every other task of the release has
merged, as `jig-release` says. `not queued: <n>` in `jig queue next` still counts them, so that line
need not reach zero.

## Which number

- **What is confirmed, not the worst that could happen.** A worst case read from a description puts
  everything at `0`, and then the number orders nothing. A report nobody has checked gets the number
  of what it claims, and you say it is unchecked; when analysis finds otherwise, set the number again.
- **A number already there stays.** The queue does not record who set it, and it may be a person's.
  Change it when asked to, or name what you found and ask.
- **A person's word beats the scale.** Product work is `4` and comes after every bug on purpose, but
  `jig queue next` only advises: a task the person names is the task to take.

## Order and waiting

- **Within one number**, the started task goes first, then the place decides:
  `.ai/scripts/jig queue move <id> --before <other>`.
- **A task that waits for another** gets a dependency with its reason, not a lower number:
  `.ai/scripts/jig queue depend <id> --on <other> --reason "<why>"`.

What a project adds to this, such as which roadmap step comes first, is in its own `AGENTS.md`.
