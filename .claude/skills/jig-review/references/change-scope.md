# Establish and inspect the whole task change

Record a justified base commit and task scope in plan.md or review.md (`jig task artifact write|append <id> plan|review --from <file>`). Before implementation,
record starting HEAD and pre-existing changes. For historical work inspect task records and
Git history; ask only if ownership cannot be established. Main alone is not a task baseline.

Use `jig task changes <id> --base <ref>` to discover all candidate layers. Narrow with
`--files <a,b|->` only after accounting for unexpected paths. Keep the selected `--format
paths` output in a shell variable and feed that exact list to context resolve/guard.
An empty list is not evidence that all requirements were implemented.

Inspect standard Git patches with the reported resolved base/HEAD and literal paths:
`git --literal-pathspecs diff --no-ext-diff --no-textconv <base> <head> -- <paths...>`,
`git --literal-pathspecs diff --no-ext-diff --no-textconv --cached <head> -- <paths...>`,
and `git --literal-pathspecs diff --no-ext-diff --no-textconv -- <paths...>`.
Read untracked nonignored files directly. Pass paths as individually quoted arguments;
do not word-split a file list, and do not run a pathless diff for explicitly empty scope.
Inspect both sides of renames/deletions. Binary, submodule and unmerged changes need
appropriate inspection and disclosed limitations; a file inventory does not verify them.

An allowlist isolates paths, not hunks owned by different tasks in one file. Identify
owned hunks against starting evidence, or report an unresolved boundary and withhold a
complete-review claim. Refresh scope if the checkout changes during review. Surrounding
code can be read for context without silently claiming it belongs to the task.

Review all acceptance criteria before code quality; at T4 each one needs evidence
([T4 is reviewed further](../SKILL.md)). A review needs actual findings from a fresh reader;
an asynchronous completion notification without the report is not a clean review.
