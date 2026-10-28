---
name: jig-setup
description: Ask a person, one question at a time in plain words, how far their agent may go on its own — git rights, autopilot without questions, releases, CI wait, cleanup, Telegram messages — and write their answers to their personal `.ai/config.local.yaml` after a yes. Use after `jig init`, or when the user says "set up Jig for me", "configure my settings", "change my personal settings", "let the agent merge".
---

# jig-setup — personal settings, asked for in plain words

The person may not know `.ai/config.local.yaml` exists. You ask; `jig config set --local`
checks and writes (ADR-0001). The file is theirs alone: it changes what **their** agent does
in **this** clone, never a colleague's. Never write `.ai/config.yaml` — the team's file, edited
by hand.

## Speak in blocks

Say each message in the form Jig's reports and its installer use
(adr-20261005-the-installer-speaks-one-form-in-two-shells), in a code block so the columns
survive: a level word padded to six columns, then the first line; every further line indented
six columns. `ask` is a question, with the options and your recommendation on the lines under
it; `ok` is what is now set; `warn` is what needs the person (an `ignored:` key, a file git does
not ignore); `fail` is a refusal. One question per message stays the rule. For example:

```
ask   When the agent finishes a task, how far should it take the change?
      none    leave the change for you to commit (default)
      pr      commit, push and open the pull request
      I recommend pr: gh is installed and signed in.
```

`jig config set --dry-run` output is shown verbatim, as below, never re-laid-out: it is the file.

## 1. Start from what is set

```
.ai/scripts/jig config show --local
```

Say in one line what is already set, or that nothing is. Any `ignored:` line is a key no
reader answers from — a misspelling, or a setting from a Jig that had it: name those, say they
do nothing, and offer to remove them. On a yes:

```
.ai/scripts/jig config unset <key> [<key>...] --local
```

Then ask the questions below, **one per message**, in the person's words — no key names unless
they ask. Each question says what the choice changes, offers the options, and names your
recommendation with its reason. A person who says "keep the default" or "skip" moves on:
nothing is written for that question. One who wants a setting they already have taken out of
their own file is answered by `config unset` too — say that the key then answers from
`.ai/config.yaml` if the team set it there, and from the default otherwise.

## 2. The questions

1. **Git** (`agent.git`). "When the agent finishes a task, how far should it take the change?"
   `none` — it leaves the change for you to commit (default); `commit`; `push`; `pr` — it
   commits, pushes and opens the pull request, and you review and merge there; `merge` — see
   below. Recommend `pr` when `gh` or `glab` is installed and signed in, else `commit`.
2. **Merging** — only if they want more than `pr`. Before asking, explain: with `merge` the
   agent also merges its own pull request once CI ran and every check passed, never past
   branch protection or a required review, never a draft; the change then goes wherever the
   main branch goes — a deploy included. Set `merge` only on an explicit yes to that.
3. **Autopilot's git** (`autopilot.git`). "When the agent runs a task on autopilot, should it
   take the change as far as that too?" Default: the same — say so, and write nothing. Offer a
   different level for runs only: the usual case is `pr` for their own work and `merge` for
   autopilot, which merges what autopilot builds and leaves the rest to them. `merge` here needs
   the same explanation and the same explicit yes as question 2.
4. **Asking** (`autopilot.unattended`). Before asking, explain: on autopilot the agent stops to
   ask at a design approval, an unmade decision, a destructive step or a problem it could not
   fix; with `true` it asks nothing — it approves its own design, picks the most reversible
   option, never destroys anything, opens a draft when fixing fails, and writes every such
   choice into the pull request. Recommend `false` for a developer who can answer those
   questions, `true` only for someone who cannot and would rather have the change delivered.
   Set `true` only on an explicit yes.
5. **Releases** (`release.merge`) — only with `true` to question 4 and `merge` at either level.
   Before asking, explain: an epic's final pull request is the release — every task of a spec
   reaching the main branch at once; with `agent` (default) the run merges it once CI passed, a
   `major` always left as a draft; with `human` it opens it and leaves that merge to them. A task
   whose change raises the project's version is a release too and follows the same answer; other
   task pull requests are not affected. "Should the agent merge a release by itself, or leave that
   one to you?" Recommend `human` to someone whose main branch deploys or who wants to choose
   when a release goes out.
6. **CI wait** (`agent.ci_timeout`) — only with `merge` at either level. "How many minutes should it wait for
   the checks before leaving the pull request open for you?" Default 30.
7. **At once** (`autopilot.parallel`). "When a whole roadmap phase runs, how many of its tasks
   may agents work on at the same time?" Each one gets its own folder and its own agent, so
   more means more of the machine and more to read when they finish. Default 2, at most 16.
   Recommend 2, or 1 for someone who wants to watch every change.
8. **Process** (`route.depth`). "How much process should your tasks get?" `full` — each risk
   class's whole route (default); `lean` — a shorter analysis, the plan folded into it, one
   review round where the class allows it. Say what never changes: tests on changed files, CI
   before a merge, the design approval and architecture review of risky work. Recommend `full`;
   `lean` for someone who would rather trade a little review depth for time and tokens. One
   task can always differ.
9. **Cleanup** (`housekeeping.*`, `git.delete_merged_branches`) — one question, offer to skip:
   how long an abandoned task stays in the lists before it goes to the archive
   (`housekeeping.abandoned_ttl`, 14d), how long the trash of closed tasks is kept
   (`housekeeping.trash_ttl`, 7d), when an untouched task is moved to the archive
   (`housekeeping.stale_after`, 60d; the archive keeps it, nothing is deleted), how often cleanup runs (`housekeeping.cadence`, whole
   days, 1d), whether it may `git fetch` (`housekeeping.fetch`, true), and whether a branch Jig
   made is deleted once its work has landed (`git.delete_merged_branches`, true — `false` keeps
   every branch). Recommend the defaults.
10. **Worktrees** (`git.worktree_root`) — only if they run several agents at once and want the
    task folders somewhere other than `../<project>.worktrees`.
11. **Where the checks run** (`run.exec`). First run `.ai/scripts/jig verify --explain` and read
    its `verify: checks run in …` or `verify: refused: …` line: it names what Jig detected, or
    the signs of a container it could not place. Ask: "Where do this project's tests run — here,
    or in a container?" With a detection that is right, nothing needs writing (`auto` keeps
    finding it); say so. Otherwise offer `host`, or the command prefix that reaches the
    container — work it out from the project (`docker compose exec -T -w <dir> <service>`,
    `docker exec -i -w <dir> <container>`) and show it; never ask the person to type one. A PHP on
    this machine that is not first on `PATH` and was not detected (Herd's is) goes to `run.path`,
    the folder that holds it.
12. **Helpers** (`claude.implement_model`, `claude.review_model`, `codex.implement_model`,
    `codex.review_model`) — ask only about the runtime this session uses. Explain that the
    agent can hand implementation and review to a helper on a chosen model; Jig still checks
    findings, the review receipt and verification. One review setting covers every review,
    including architecture review. Ask: "Should helpers do the coding and reviews, and on which
    model?" Options: no helpers (default), one model for both, or a different model for each.
    Write the name exactly as the person gives it: Jig does not validate vendor model names. In
    Codex, if a chosen helper cannot start, the stage stops and reports why. Recommend no
    helpers to someone unsure why they would want them. Never set the other runtime's keys
    from this session.

13. **The other runtime** (`executor.implement_runtime`, `executor.review_runtime`,
    `executor.implement_model`, `executor.review_model`) — only when the other runtime's CLI
    (`claude` or `codex`) is installed here (`command -v`). Explain that a stage can run in that
    CLI instead of this session: the agent starts it in the task worktree with limited tools, a
    review in a fresh process, and then checks the diff, findings and receipt itself; a CLI that
    is missing, refuses or is interrupted stops the stage. It spends that runtime's account.
    Ask: "Should coding or reviews run in <other runtime>, and on which model?" Options: neither
    (default — nothing written), coding, reviews, or both; a model only if they name one, written
    as given. Write the runtime as `claude` or `codex`, never this session's own (that is
    question 12). Recommend reviews only to someone who wants a second vendor's eyes on the work.

14. **Telegram** (`notify.telegram.token`, `notify.telegram.chat_id`). "Should Jig message your
    Telegram when an autopilot run stops, ends or chooses for you?" On a yes, explain where the
    two values come from: a bot made with @BotFather (`/newbot`) gives the token; they send that
    bot any message, and their chat id is `chat` → `id` on
    `https://api.telegram.org/bot<token>/getUpdates`. **Never ask for the token in chat** — the
    transcript keeps it. Ask them to run `.ai/scripts/jig notify setup` in their own terminal (it asks for the token without showing it, writes both, sends a test).
    When they say it is done, run `.ai/scripts/jig notify test` here and show its output: your
    session is where autopilot's messages are sent from. A failure that names the network means
    this session's sandbox keeps the agent off `api.telegram.org`, and autopilot's messages will
    not arrive either until it is allowed. Not part of the dry run below.

    When §1 showed both values already set, ask instead whether the messages should keep
    coming (`notify.autopilot`): `false` pauses every autopilot message — a stop, an end, an
    unattended run's choices — and keeps the bot and chat for later; `true` (default) needs
    nothing written.

15. **Messages from ordinary sessions** (`notify.interactive`), only after a yes to 14 or with
    both values already set. "Should it also message you when an ordinary session waits for
    your permission or answer?" Default no: it is for walking away from the screen. Say that in
    the desktop app and the IDE a permission prompt messages them after about six seconds even
    while they are there. On a yes, the value goes into the dry run, and the hook goes into
    their own `.claude/settings.local.json`: show the lines `.ai/scripts/jig doctor` prints for
    `notify hook (claude)` and the file as it would be, and write it only after their yes — Jig
    itself never edits that file. Codex has no such hook; say so instead.

Two timings are left out of the questions: how long a record of work in a checkout counts as a
live session (`checkout.busy_ttl`, 12h) and how long a running `jig verify` holds the clone
(`verify.busy_ttl`, 30m). Set one only when the person brings it up — a test suite that runs
longer than half an hour is the usual reason to raise `verify.busy_ttl`.

Ask about no other key. If `jig config set` refuses a key as not local, this version of Jig
does not have it: drop the question.

## 3. Show the whole file, then write

Put every answer into one dry run — it prints exactly the file that would be written:

```
.ai/scripts/jig config set <key> <value> [<key> <value>...] --local --dry-run
```

Show that output whole, verbatim, and after it, labelled as yours, one line per setting in plain
words. Ask for a yes. A change of mind goes back to its question and to a new dry run. After the
yes, run the same command without `--dry-run`. A refusal names the key and why; fix the answer
with the person, never by editing the file yourself.

If it warns that the file is not ignored by git, say so and offer `jig init`, which adds the
line to `.gitignore`. End with `.ai/scripts/jig status`: its `config.local:` lines are what
took effect.
