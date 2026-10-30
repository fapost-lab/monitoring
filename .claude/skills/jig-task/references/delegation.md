# Handing a stage to a helper

Jig names the stages. The person chooses a model in their local settings. `jig task route <id>`
prints the choices for each configured runtime:

```
delegate: implement -> sonnet (claude.implement_model)
delegate: review -> gpt-6.1-sol (codex.review_model)
```

Use only lines whose key names the **current session's runtime**. A Claude Code session reads
`claude.*`; a Codex session reads `codex.*`. Lines for another runtime do not ask this session
to launch it. The `executor:` lines below select another runtime explicitly. `review` covers every review in
the route: T2 review, T4 independent review, and T3/T4 architecture review.

## Choosing another runtime

`executor.implement_runtime` and `executor.review_runtime` are local-only and print
`executor: <stage> -> claude|codex` when set. An unset key keeps the current session's
behavior. When the selected runtime is the current one, keep using this session and its
`claude.*_model` or `codex.*_model` subagent choice. When it is different, hand the stage to
its CLI in the task worktree; `executor.*_model`, if printed, is the optional model for
that **external process**, not a subagent model. An external process must not re-read these
settings and delegate again. If a selected CLI, authentication, model, permissions or
output fails, stop the stage and name the cause. Never silently complete it in this session.

The **agent following this skill** starts the process. Jig scripts never launch an LLM. Verify
the task worktree and run `command -v codex` or `command -v claude` first. Give the external
process a new prompt containing the task id, base, acceptance criteria, approved design and
the files it may inspect. Do not pass secrets or the implementation conversation. Run it
in the task worktree with a bounded tool timeout supplied by the host runtime. Treat a
timeout, interruption, nonzero exit or denied tool as a failed stage, even when it left
files behind. Preserve partial work for inspection; do not mark the stage complete.
On Windows, use Git Bash as Jig does; check the target CLI's presence and that the
worktree path is accepted before the handoff. If the CLI or its sandbox cannot be
verified on that host, stop the selected stage rather than widening permissions.

### External implementation

- Codex: use `codex -a never -c sandbox_workspace_write.exclude_slash_tmp=true
  -c sandbox_workspace_write.exclude_tmpdir_env_var=true exec --cd <worktree>
  --sandbox workspace-write --ephemeral --ignore-user-config --disable multi_agent`, adding `--model <name>` only when the
  external model key is set. Never use `--add-dir` or a sandbox bypass. Its prompt must
  restrict edits to the task's source files and forbid task lifecycle, ship and merge.
- Claude Code: run `claude -p --restricted --strict-mcp-config --permission-mode
  acceptEdits --permission-prompts none --tools Read Edit Write Glob Grep
  --output-format json` from the task worktree, adding `--model <name>` only when set.
  Do not add Bash, Task, network or connected tools. Restricted mode intentionally
  ignores project settings; provide the relevant knowledge in the prompt.

The external implementer is instructed to edit code only. Codex has a shell: the prompt
cannot prevent it from attempting Jig lifecycle commands. Before launch, record HEAD,
the index state, diff, untracked files and the task workspace records; after launch,
compare them and fail the stage on an unexpected lifecycle change. Also check the exit
status and denied tools, then run Jig artifact writes, tests and the rest of
`jig-implement` here. The worktree's `.ai/workspace` may point outside the sandbox,
so do not give the external process write access to it. An external final message is
a report, not proof of implementation. A partial diff or unexpected path stops the
stage for inspection.

### External review

Start a **new process** with no implementation history. Give it the task id, base,
requirements, design, actual diff, applicable knowledge and the review skill. Codex uses
`codex -a never exec --cd <worktree> --sandbox read-only --ephemeral
--ignore-user-config --disable multi_agent`. Claude uses `claude -p --restricted
--strict-mcp-config --permission-mode plan --permission-prompts none
--tools Read Glob Grep --output-format json` from the worktree. Add an external model
only when selected. The reviewer reports findings with severity, path, line and a
reproducible reason; it does not edit code, ledger or receipt. The process cannot run Jig, so
for a re-review the coordinator runs `jig task receipt <id> --since-review` itself and puts its
verdict in the prompt: on `narrow`, the interdiff, any knowledge diff and the `fixed` findings in
place of the actual diff; on `full`, the actual diff as for a first review.

The coordinator checks the process exit and denials, compares its reviewed diff with the
current diff, enters every finding through `jig task finding`, and records the receipt
through `jig task receipt <id> --stage <review|architecture-review>` only after reviewing the
report and files. Check `jig task findings` and receipt freshness before continuing.
If implementation changed after the review, start a new reviewer process and replace the
receipt. An empty or malformed report is failure, not a clean review. The receipt pins
content, not the reviewer's identity.

## With a matching line

Start a new subagent for the entire stage, with the value exactly as printed as its model.
Give it the task id, worktree path, base, stage skill, and approved design or plan. It runs
the skill itself, reads the relevant knowledge, records findings and the review receipt, and
returns a report. The coordinator checks `jig task findings <id>` and the receipt before
continuing. Never treat the subagent's final message alone as stage evidence.

A re-reviewer's brief adds one line: start with `jig task receipt <id> --since-review`.

The implementer and reviewer are different subagents. A reviewer starts with a fresh context
that does not include the implementation conversation. A fix after review goes to the
implementer; a re-review uses a new reviewer.

### In Codex

Request a Codex subagent explicitly with the printed model and a fresh context. Put the task
id, worktree, base, skill and necessary design or plan in its initial brief; do not rely on
inherited conversation. Wait for its result and check Jig's files. Do not silently choose a
replacement model. If subagent tools are disabled, the model is refused, or creation fails,
**stop this stage and report the reason**. The current session must not complete a stage for
which a Codex model was explicitly selected. In particular, it must not sign its own review
as if an independent reviewer ran.

### In Claude Code

Start a subagent with the printed model. If Claude Code refuses the model, say so in one line
and follow the existing Claude fallback: do the stage without that model. Choosing a different
model remains the person's decision.

## Without a matching line

The current session implements as before. Every review stage still goes to a new subagent on
the session's model, briefed without the implementation conversation. Only here, with no review
line at all, may the session review when no subagent can start, and it says so in the pull
request. No setting is required for a normal Jig route.

## T4: another model when there is one

A T4 review runs on a different model or runtime from the implementation when the lines say so.
Take the effective implementer — the `executor: implement` runtime (with its model, if printed),
else the `delegate: implement` model, else the session — and the effective reviewer the same way
from the `review` lines. They differ when their runtimes differ, or when the same runtime names
two different models. The coordinator never picks a model on its own. With no such line, a same-model reviewer in a fresh context does
the review and the pull request says that it ran on the implementation's model. Nothing records
the model elsewhere: the receipt pins content, not who read it.

## What stays with the coordinator

Classification, discovery and design, the human gate, undecided choices, `jig verify` and
the task's sign-off, consolidation and `jig task ship` stay with the coordinator. A helper
changes who does a stage, not the route or its records.
