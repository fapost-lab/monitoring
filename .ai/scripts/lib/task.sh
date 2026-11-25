# cmd_task — task workspace and state (domains/task; schemas/state.md;
# ARCHITECTURE.md, Scripts layout; ADR-0005; ADR-0008).
# Sourced by scripts/jig; defines cmd_task plus the reusable readers
# `task_dir` and `task_state_get` that other libraries (context.sh) source
# this file for. bash 3.2 compatible: no associative arrays, no ${var,,},
# no mapfile.
# shellcheck shell=bash

cmd_task() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    help | -h | --help) _task_usage; return 0 ;;
  esac
  # `jig task <sub> -h|--help` prints that subcommand's usage and does nothing
  # else. Only the first argument counts: it is where every subcommand reads
  # its task id, and a later `--help` is a value (`pause --reason --help`).
  case "${1:-}" in
    -h | --help)
      if _task_usage "$sub"; then return 0; fi
      ;;
  esac
  _TASK_VERB="task $sub"
  case "$sub" in
    new) task_new "$@" ;;
    set) task_set "$@" ;;
    start) task_start "$@" ;;
    bootstrap) task_bootstrap "$@" ;;
    abandon) task_abandon "$@" ;;
    archive) task_archive "$@" ;;
    unarchive) task_unarchive "$@" ;;
    merge) task_merge "$@" ;;
    pause) task_pause "$@" ;;
    resume) task_resume "$@" ;;
    list) task_list "$@" ;;
    show) task_show "$@" ;;
    current) task_current "$@" ;;
    changes) task_changes "$@" ;;
    artifacts) task_artifacts "$@" ;;
    artifact) task_artifact "$@" ;;
    finding) task_finding "$@" ;;
    findings) task_findings "$@" ;;
    receipt) task_receipt "$@" ;;
    ship) task_ship "$@" ;;
    land) task_land "$@" ;;
    promote) task_promote "$@" ;;
    request-review | merge-pr | pr-status)
      # shellcheck source=lib/prdo.sh
      . "$JIG_LIB/prdo.sh"
      case "$sub" in
        request-review) prdo_request_review "$@" ;;
        merge-pr) prdo_merge_pr "$@" ;;
        *) prdo_pr_status "$@" ;;
      esac ;;
    autopilot) task_autopilot "$@" ;;
    gate) task_gate "$@" ;;
    waive) task_waive "$@" ;;
    route) task_route "$@" ;;
    *) jig_die "$(_task_usage)" ;;
  esac
  # One redraw of the status page for however many writes the command made
  # (jig_record_changed, common.sh). A command that stops early redraws on
  # its own way out: jig_die flushes, and so does the one `return 3` below.
  jig_status_page_flush
}

# _task_usage [sub] — the usage line of <sub>, or of `jig task` as a whole
# when <sub> is empty; non-zero, printing nothing, for an unknown <sub>. The
# one source for both `--help` and the usage errors the subcommands die with.
_task_usage() {
  case "${1:-}" in
    '') printf 'usage: jig task new|start|bootstrap|set|abandon|archive|unarchive|merge|pause|resume|list|show|current|changes|artifacts|artifact|finding|findings|receipt|ship|land|promote|request-review|merge-pr|pr-status|autopilot|gate|waive|route ...\n' ;;
    new) printf 'usage: jig task new <id> [--class T0..T4] [--domains a,b] [--from <file> | --goal <text>] [--lean] [--json]\n' ;;
    start) printf 'usage: jig task start <id> [--worktree] [--no-bootstrap] [--share <dir>]... [--out-of-order --reason <text>]\n' ;;
    bootstrap) printf 'usage: jig task bootstrap <id> [--share <dir>]...\n' ;;
    set)
      printf 'usage: jig task set <id> <key> <value>\n'
      printf '       jig task set <id> class <Tn> --reason <text>   (a lower class than the current one)\n'
      printf '       jig task set <id> status consolidated [--revision <n>] [--json]\n'
      ;;
    abandon) printf 'usage: jig task abandon <id> [--reason <text>] [--moved-to <repo>#<task-id>|<repo>#spec/<spec-id>] [--revision <n>] [--json]\n' ;;
    archive) printf 'usage: jig task archive <id> [--revision <n>] [--json]\n' ;;
    unarchive) printf 'usage: jig task unarchive <id> [--revision <n>] [--json]\n' ;;
    merge) printf 'usage: jig task merge <from> --into <to> [--partial]\n' ;;
    pause) printf 'usage: jig task pause <id> [--reason <text>] [--stash] [--revision <n>] [--json]\n       jig task pause <id> --if-requested --stage <name>\n' ;;
    resume) printf 'usage: jig task resume <id> [--revision <n>] [--json]\n' ;;
    list) printf 'usage: jig task list [--all] [--status <status>] [--goals] [--json]\n' ;;
    show) printf 'usage: jig task show <id>\n' ;;
    current) printf 'usage: jig task current\n' ;;
    changes) printf 'usage: jig task changes <id> --base <ref> [--files <list>|-] [--format report|paths]\n' ;;
    artifacts) printf 'usage: jig task artifacts <id> [--provided discovery,design,...] | [--json]\n' ;;
    artifact)
      printf 'usage: jig task artifact write <id> <kind> [--from <file>|-]\n'
      printf '       jig task artifact append <id> <kind> [--from <file>|-]\n'
      printf '       jig task artifact read <id> <kind> [--json]\n'
      printf '       <kind>: task discovery spec alternatives design plan review verification handoff knowledge-map commit-message pr-body\n'
      ;;
    finding)
      printf 'usage: jig task finding add <id> --severity P0|P1|P2|P3 --where <path[:line]|-> --summary <text>\n'
      printf '       jig task finding set <id> <F-id> open|fixed|closed|dismissed [--reason <text>]\n'
      ;;
    findings) printf 'usage: jig task findings <id> [--blocking]\n' ;;
    receipt)
      printf 'usage: jig task receipt <id> --stage review|architecture-review\n'
      printf '       jig task receipt <id> --check\n'
      printf '       jig task receipt <id> --since-review [--format report|paths]\n'
      ;;
    ship) printf 'usage: jig task ship <id> --message-file <file> [--title <t>] [--body-file <file>] [--reviewer <login|name>]... [--draft] [--partial]\n' ;;
    land)
      printf 'usage: jig task land <id> [--without-review]\n'
      printf '       jig task land <id> --by human [--without-review] [--revision <n>] [--json]\n'
      printf '       jig task land <id> --resolved --note-file <file> [--without-review]\n'
      printf '       jig task land <id> --abort\n'
      ;;
    promote) printf 'usage: jig task promote <id> [--commit <sha>] [--title <t>] [--body-file <file>]\n       jig task promote <id> --by human [--commit <sha>] [--title <t>] [--body-file <file>] [--revision <n>] [--json]\n       jig task promote [--commit <sha>] <id> <id>...\n       jig task promote --commit <sha> --all\n' ;;
    request-review) printf 'usage: jig task request-review <id> --reviewer <login|name>... [--by human] [--revision <n>] [--json]\n' ;;
    merge-pr) printf 'usage: jig task merge-pr <id> [--by human] [--revision <n>] [--json]\n' ;;
    pr-status) printf 'usage: jig task pr-status <id> --json\n' ;;
    autopilot)
      printf 'usage: jig task autopilot <id> start [--phase <spec-id>/<n>]\n'
      printf '       jig task autopilot <id> stage <name>\n'
      printf '       jig task autopilot <id> repair --reason <text>\n'
      printf '       jig task autopilot <id> stop --reason <text>\n'
      printf '       jig task autopilot <id> approve --reason <text>\n'
      printf '       jig task autopilot <id> decide --reason <text>\n'
      printf '       jig task autopilot <id> answer --answer <the human'"'"'s answer> [--by human]\n'
      printf '       jig task autopilot <id> resume --answer <the human'"'"'s answer>\n'
      printf '       jig task autopilot <id> resume   (after an answer was recorded)\n'
      printf '       jig task autopilot <id> handover --by human --answer <the person'"'"'s words>\n'
      printf '       jig task autopilot <id> end [--reason <how it ended>]\n'
      printf '       jig task autopilot <id> report\n'
      ;;
    gate)
      printf 'usage: jig task gate <id> approved [--by human|agent] [--revision <n>] [--json]\n'
      printf '       jig task gate <id> answered --answer <the human'"'"'s answer> [--revision <n>] [--json]\n'
      ;;
    waive)
      printf 'usage: jig task waive <id> ready|consolidate|ship <path> --reason <text>\n'
      printf '       jig task waive <id> ready|consolidate|ship <path> --withdraw\n'
      ;;
    route) printf 'usage: jig task route <id>\n' ;;
    *) return 1 ;;
  esac
}

# --- reusable readers (also used by scripts/lib/context.sh) -----------------

# task_dir <id> — absolute path of the task's workspace directory. Pure
# string computation; does not check the workspace exists.
task_dir() {
  local dir
  task_dir_v dir "$1"
  printf '%s\n' "$dir"
}

# task_dir_v <var> <id> — task_dir's path into <var>, in the caller's shell,
# for a reader that builds a task's path once per task of a listing.
task_dir_v() {
  # Every subcommand goes through here, so an id like `..` or `../x` can never
  # resolve to a path outside the tasks directory (RULES.md invariant).
  _task_valid_id "$2" || jig_die "invalid task id: $2"
  printf -v "$1" '%s/%s/workspace/tasks/%s' "$JIG_PROJECT" "$JIG_AI_DIR" "$2"
}

# task_state_get <id> <key> — print the value of <key> from the task's state
# file, or nothing when the task or the key does not exist. Never dies:
# callers that need "unknown task" to be an error check for the state file
# themselves (see task_show, task_set).
#
# The format's one rule — the first `<key>:` line, its value after the colon
# and any blanks — is jig_task_state_var's (common.sh), read with builtins
# and, on a read path, from the snapshot of the file (jig_read_snapshot_begin).
task_state_get() {
  local value
  task_state_var value "$1" "$2"
  [ "$_JIG_TS_FOUND" = 0 ] || printf '%s\n' "$value"
}

# task_state_var <var> <id> <key> — task_state_get's value into <var>, in the
# caller's shell: no command substitution, no process. The form a reader that
# asks several keys of many tasks uses. Dies on an invalid id, as task_dir.
task_state_var() {
  if [ -z "$2" ] || [ "$2" != "$_JIG_TS_CUR" ]; then
    _task_valid_id "$2" || jig_die "invalid task id: $2"
  fi
  jig_task_state_var "$@"
}

# --- validation ---------------------------------------------------------------

_task_valid_id() {
  # The grammar is shared with spec ids (common.sh, jig_valid_id).
  jig_valid_id "$1"
}

_task_valid_class() {
  case "$1" in
    T0 | T1 | T2 | T3 | T4) return 0 ;;
    *) return 1 ;;
  esac
}

_task_valid_status() {
  case "$1" in
    active | ready | consolidated | abandoned | archived) return 0 ;;
    *) return 1 ;;
  esac
}

# The reasons a task is archived (adr-20261027-a-task-nobody-finished-is-
# archived-not-purged): housekeeping's two, after abandoned_ttl and after
# stale_after, and a person's own `jig task archive`.
_task_valid_archived_reason() {
  case "$1" in
    abandoned | stale | manual | absorbed) return 0 ;;
    *) return 1 ;;
  esac
}

_task_valid_bool() {
  case "$1" in
    true | false) return 0 ;;
    *) return 1 ;;
  esac
}

# Comma-separated `^[a-z0-9-]+(,[a-z0-9-]+)*$` (schemas/state.md). Rejects
# empty, leading/trailing/doubled commas explicitly: field-splitting a
# trailing comma does not yield a trailing empty field in bash, so that case
# needs its own check rather than relying on the per-item loop below.
_task_valid_domains() {
  local val="$1" d
  case "$val" in
    '' | ,* | *, | *,,*) return 1 ;;
  esac
  local IFS=','
  for d in $val; do
    case "$d" in
      '' | *[!a-z0-9-]*) return 1 ;;
    esac
  done
  return 0
}

# --- findings ledger validation (design §1-2, findings-ledger) -----------------

_task_valid_severity() {
  case "$1" in P0 | P1 | P2 | P3) return 0 ;; *) return 1 ;; esac
}

_task_valid_finding_status() {
  case "$1" in open | fixed | closed | dismissed) return 0 ;; *) return 1 ;; esac
}

# A ledger field (where, summary, reason) may not contain a tab (the TSV
# delimiter) or a newline (would split the record across two lines).
_task_finding_valid_field() {
  local nl=$'\n' tab
  tab=$(printf '\t')
  case "$1" in
    *"$nl"* | *"$tab"*) return 1 ;;
  esac
  return 0
}

# --- tracker issue (adr-20261010-a-task-carries-its-tracker-issue) -------------
#
# A project whose tasks live in a tracker names a task after its issue
# (`SRD-2455-fix-login`, `123-fix-login`). Jig reads the issue from the id, and
# only by the project's own `task.issue_pattern`: with no pattern nothing is
# read, so `release-0-25-1` can never turn into an issue `release-0`. There is
# no flag to give one by hand — the id is the one place it is written.

# _task_issue_pattern — task.issue_pattern with one pair of surrounding quotes
# removed, or nothing when the project sets none.
_task_issue_pattern() {
  local pattern
  pattern=$(cfg task.issue_pattern "")
  jig_strip_quotes "$pattern"
}

# _task_issue_from_id <id> — the tracker issue at the start of <id>, or
# nothing. The pattern is anchored at the first character, takes awk's longest
# match, and counts only when that match ends at the end of the id or before a
# `-`, `_` or `.`: `SRD-2455x-y` names no issue, `SRD-2455-y` names SRD-2455.
# jig pr fetch reads a head branch by the same rule (_pr_issue_candidates in
# pr.sh); keep the two the same.
# Exit 2, printing nothing, when awk cannot read the pattern.
_task_issue_from_id() {
  local pattern
  pattern=$(_task_issue_pattern)
  [ -n "$pattern" ] || return 0
  JIG_I_ID="$1" JIG_I_PAT="$pattern" awk 'BEGIN {
    id = ENVIRON["JIG_I_ID"]
    if (!match(id, "^(" ENVIRON["JIG_I_PAT"] ")") || RLENGTH < 1) exit 0
    after = substr(id, RLENGTH + 1, 1)
    if (after == "" || after == "-" || after == "_" || after == ".") print substr(id, 1, RLENGTH)
  }' 2>/dev/null || return 2
}

# _task_issue_ref <issue> — how a commit and a pull request title name the
# issue: as it is (`SRD-2455`), or `#123` for an issue of digits only, the form
# GitHub, GitLab and Redmine link.
_task_issue_ref() {
  case "$1" in
    *[!0-9]*) printf '%s\n' "$1" ;;
    *) printf '#%s\n' "$1" ;;
  esac
}

# _task_issue_in_line <line> <ref> — exit 0 when <ref> is a word of <line>:
# no letter, digit or `_` right before or after it. `SRD-24550` does not hold
# SRD-2455, and `#1234` does not hold #123.
_task_issue_in_line() {
  JIG_I_LINE="$1" JIG_I_REF="$2" awk 'BEGIN {
    line = ENVIRON["JIG_I_LINE"]; ref = ENVIRON["JIG_I_REF"]; n = length(ref)
    pos = 0; rest = line; found = 0
    while (!found && n > 0 && (i = index(rest, ref)) > 0) {
      p = pos + i
      before = (p > 1) ? substr(line, p - 1, 1) : ""
      after = substr(line, p + n, 1)
      if (before !~ /[A-Za-z0-9_]/ && after !~ /[A-Za-z0-9_]/) found = 1
      pos = p
      rest = substr(line, p + 1)
    }
    exit found ? 0 : 1
  }'
}

# _task_issue_subject <line> <issue> — <line> naming <issue>: unchanged when it
# already does, or is empty; otherwise `SRD-2455 <line>`, and `<line> (#123)`
# for an issue of digits — a first line that starts with `#` is a comment to
# git under `commit.cleanup=strip`, and the subject would be thrown away.
_task_issue_subject() {
  local line="$1" ref
  ref=$(_task_issue_ref "$2")
  line=${line%$'\r'}
  if [ -z "$line" ] || _task_issue_in_line "$line" "$ref"; then
    printf '%s\n' "$1"
    return 0
  fi
  case "$ref" in
    \#*) printf '%s (%s)\n' "$line" "$ref" ;;
    *) printf '%s %s\n' "$ref" "$line" ;;
  esac
}

# --- branch -------------------------------------------------------------------

# Current branch of the checkout, or "detached" (ADR-0008: a workspace
# belongs to the checkout it was created in).
_task_current_branch() {
  local b
  if b=$(git -C "$JIG_PROJECT" symbolic-ref --short HEAD 2>/dev/null); then
    printf '%s\n' "$b"
  else
    printf 'detached\n'
  fi
}

# --- worktrees (ADR-0029) -------------------------------------------------------

# _task_worktree_root — the directory `task start --worktree` creates task
# worktrees under: `git.worktree_root`, relative to the project root unless it
# is absolute. By default a sibling of the project, `<project>.worktrees`.
#
# Beside the repository rather than inside it: a nested copy of the whole tree
# is found twice by every tool that walks the directory — test runners, type
# checkers, IDE indexers — and jig can teach its own profiles to prune it but
# not the tools of the project that adopted it (ADR-0029).
_task_worktree_root() {
  local root
  root=$(cfg git.worktree_root "")
  [ -n "$root" ] || root="../$(basename "$JIG_PROJECT").worktrees"
  case "$root" in
    /*) printf '%s\n' "$root" ;;
    *) printf '%s/%s\n' "$JIG_PROJECT" "$root" ;;
  esac
}

# _task_worktrees — "<branch><TAB><path>" for every worktree of this
# repository other than this checkout that has a branch checked out and still
# exists on disk. Paths are physical.
#
# This reads git's list of worktrees, never another checkout's .ai/, so it is
# not the cross-worktree lookup ADR-0008 rules out: it says where a branch is
# checked out, which only git knows.
_task_worktrees() {
  local list self path branch t
  list=$(git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null) || return 0
  self=$(cd -P "$JIG_PROJECT" 2>/dev/null && pwd -P) || return 0
  t=$(printf '\t')
  while IFS="$t" read -r path branch; do
    [ -n "$branch" ] || continue
    path=$(cd -P "$path" 2>/dev/null && pwd -P) || continue
    [ "$path" != "$self" ] || continue
    printf '%s\t%s\n' "$branch" "$path"
  done < <(printf '%s\n' "$list" | awk '
    /^worktree / { if (p != "") print p "\t" b; p = substr($0, 10); b = "" }
    /^branch refs\/heads\// { b = substr($0, 19) }
    END { if (p != "") print p "\t" b }
  ')
  return 0
}

# _task_worktree_for <branch> <worktrees> — the path of the worktree that has
# <branch> checked out, from a `_task_worktrees` listing; empty when none.
_task_worktree_for() {
  local path
  _task_worktree_for_v path "$1" "$2"
  [ -z "$path" ] || printf '%s\n' "$path"
}

# _task_worktree_for_v <var> <branch> <worktrees> — the same path into <var>,
# in the caller's shell: the first line whose first tab-separated field is
# <branch> gives its second.
_task_worktree_for_v() {
  local __twf_line __twf_t=$'\t'
  printf -v "$1" '%s' ""
  [ -n "$2" ] || return 0
  while IFS= read -r __twf_line; do
    case "$__twf_line" in
      "$2$__twf_t"*)
        __twf_line=${__twf_line#"$2$__twf_t"}
        printf -v "$1" '%s' "${__twf_line%%"$__twf_t"*}"
        return 0 ;;
    esac
  done <<EOF
$3
EOF
  return 0
}

# _task_worktree_note <path> — how a task started in its own worktree is shown
# by `task list` and `jig status`: where it is, and how many files there wait
# for review. At agent.git none (the default, config.sh) agents do not
# commit, so that count is the whole review queue; at a higher level it is
# whatever `jig task ship` has not carried further yet.
_task_worktree_note() {
  printf 'worktree=%s uncommitted=%s\n' "$1" "$(_task_worktree_uncommitted "$1")"
}

# _task_worktree_uncommitted <path> — how many files in the worktree at <path>
# differ from its HEAD, as `git status --porcelain` counts them: the number
# _task_worktree_note shows and `task list --json` reports.
_task_worktree_uncommitted() {
  local n
  _task_worktree_uncommitted_v n "$1"
  printf '%s\n' "$n"
}

# _task_worktree_uncommitted_v <var> <path> — the same count into <var>: one
# git process, the lines counted in the shell.
_task_worktree_uncommitted_v() {
  local __twu_out __twu_line __twu_n=0
  __twu_out=$(git -C "$2" status --porcelain 2>/dev/null || true)
  while IFS= read -r __twu_line; do
    [ -z "$__twu_line" ] || __twu_n=$((__twu_n + 1))
  done <<EOF
$__twu_out
EOF
  printf -v "$1" '%s' "$__twu_n"
}

# _task_worktree_holds <physical-path> <relative> — zero when <physical-path>
# is <W>/<relative> for this checkout or for any worktree git lists for this
# repository. It is what tells a directory link jig made from one planted by
# anybody else: a link jig makes leads into a checkout of this repository, and
# only git knows which checkouts those are. Paths compare physically, so a
# symlink and an NTFS junction (which bash reads as a link, and `cd -P`
# follows) are judged by where they lead, not by what they are.
_task_worktree_holds() {
  local want="$1" rel="$2" list p
  p=$(cd -P "$JIG_PROJECT" 2>/dev/null && pwd -P) || return 1
  [ "$want" != "$p/$rel" ] || return 0
  list=$(git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r p; do
    case "$p" in
      "worktree "*) p=${p#worktree } ;;
      *) continue ;;
    esac
    p=$(cd -P "$p" 2>/dev/null && pwd -P) || continue
    [ "$want" != "$p/$rel" ] || return 0
  done < <(printf '%s\n' "$list")
  return 1
}

# _task_borrowed_tasks_root — the physical path of `.ai/workspace/tasks` when
# this checkout borrows the whole directory from another worktree of this
# repository. Non-zero for a directory of its own, and for any other link,
# which could point anywhere.
_task_borrowed_tasks_root() {
  local link real
  link="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  [ -L "$link" ] || return 1
  real=$(cd -P "$link" 2>/dev/null && pwd -P) || return 1
  _task_worktree_holds "$real" "$JIG_AI_DIR/workspace/tasks" || return 1
  printf '%s\n' "$real"
}

# _task_link_workspace <owner-task-dir> <tree> <id> — give <tree> the task
# workspaces of the checkout that owns <id>. Non-zero when no link could be
# made; the caller undoes the start.
#
# The whole `tasks/` directory, not the one task (ADR-0029 as amended). A task
# filed from inside the worktree then lands where every other one is, instead
# of in a directory that is gitignored, invisible to the checkout that keeps
# the queue, and deleted without a word when the tree goes; and a task filed
# outside is visible here, so an agent can confirm one exists before filing a
# duplicate. The link is still given at creation, never looked up, so
# ADR-0008's rule stands.
#
# What keeps ownership of the lifecycle where it was is `find`: housekeeping
# walks `find "$tasks_dir" -mindepth 2`, and find does not descend a symlink
# named as its own starting point, so a borrowing checkout finds no task to
# purge or retire. The globs the reporting commands use do follow it, and that
# asymmetry is exactly the split this change wants. It turns on the absence of
# a trailing slash in those two find calls, which is why they carry a comment
# saying so.
#
# The fallback to ADR-0029's single-task link is not a nicety. A path git does
# not ignore reads as untracked, and `git worktree remove` without --force --
# the only way jig removes a task's worktree -- then refuses that worktree for the rest of
# its life. A rule ending in `/` matches only a directory, so a project that
# ignores `.ai/workspace/tasks/` would earn exactly that. Being blind is the
# lesser harm, so git is asked first and the old shape taken when it says no.
_task_link_workspace() {
  local owner="$1" tree="$2" id="$3" tasks rel
  rel="$JIG_AI_DIR/workspace/tasks"
  tasks="$tree/$rel"
  mkdir -p "$tree/$JIG_AI_DIR/workspace" 2>/dev/null || return 1
  if git -C "$tree" check-ignore -q "$rel" 2>/dev/null; then
    rmdir "$tasks" 2>/dev/null || true
    if [ ! -e "$tasks" ] && [ ! -L "$tasks" ]; then
      jig_link_dir "$(dirname "$owner")" "$tasks" && return 0
    fi
  fi
  mkdir -p "$tasks" 2>/dev/null || return 1
  jig_link_dir "$owner" "$tasks/$id"
}

# _task_borrowed_workspace <id> — the physical path of this task's workspace
# when it is reached through the link `task start --worktree` made. Two shapes
# are accepted, because both exist on disk: the whole `tasks/` directory
# borrowed from another worktree of this repository (what a start makes now),
# and a symlink to this same task's workspace inside a directory of this
# checkout's own (what a start made before, and what a project whose gitignore
# cannot carry a directory link still gets). Non-zero for any other link, which
# could point anywhere.
_task_borrowed_workspace() {
  local id="$1" link real root
  # The whole directory borrowed: every task under it is the owner's, and this
  # task's workspace is simply the one named after it -- unless that name is a
  # link itself, which the borrowed directory vouches nothing for and the
  # check below judges like any other.
  if root=$(_task_borrowed_tasks_root) && [ ! -L "$root/$id" ]; then
    [ -d "$root/$id" ] || return 1
    printf '%s\n' "$root/$id"
    return 0
  fi
  link=$(task_dir "$id")
  [ -L "$link" ] || return 1
  real=$(cd -P "$link" 2>/dev/null && pwd -P) || return 1
  _task_worktree_holds "$real" "$JIG_AI_DIR/workspace/tasks/$id" || return 1
  printf '%s\n' "$real"
}

# --- candidates (design §1) -----------------------------------------------------

# Number of non-empty lines in <text>. Avoids `wc -l`'s BSD/GNU leading-space
# quirk; used everywhere a count feeds an `[ -eq ]`/`[ -gt ]` comparison.
_task_count_lines() {
  printf '%s\n' "$1" | sed '/^$/d' | awk 'END { print NR }'
}

# _task_candidates_for_branch <branch> — ids, one per line and sorted, of
# every task whose `branch` equals <branch>, whose `status` is `active` or
# `ready`, and which is not paused (design §1). `consolidated` and
# `abandoned` are excluded on purpose: their work is finished and they stay
# reachable by explicit id, which is what keeps a trunk-based repository from
# becoming permanently ambiguous once finished-but-unmerged workspaces pile
# up on the same branch. A `ready` task parked at the staging branch is not a
# candidate either: it waits for a review or for "prepare for prod", and holds
# no current-task slot until `jig task resume` takes it back
# (adr-20261112-a-task-waiting-at-staging-is-parked-and-resuming-it-is-its-status).
_task_candidates_for_branch() {
  local branch="$1" base dir id br st paused list="" n=0 ready="" flow kept="" k=0 p
  base="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  # Asked by nearly every `jig task` command, of every workspace: the id comes
  # off the path and the state into variables, with no process per task
  # (convention-shell, `<name>_v`).
  for dir in "$base"/*/; do
    [ -f "${dir}state" ] || continue
    id=${dir%/}
    id=${id##*/}
    # A directory that is not a well-formed task id is not ours to read
    # (RULES.md): task_state_var would die on it, and take `task current` with it.
    _task_valid_id "$id" || continue
    task_state_var br "$id" branch
    [ "$br" = "$branch" ] || continue
    task_state_var st "$id" status
    case "$st" in
      active | ready) ;;
      *) continue ;;
    esac
    task_state_var paused "$id" paused
    [ "$paused" = "true" ] && continue
    [ "$st" != ready ] || ready="$ready$id
"
    list="$list${list:+
}$id"
    n=$((n + 1))
  done
  # Parking is asked only of a `ready` candidate in a project on the staging
  # flow: anywhere else this costs no process.
  if [ -n "$ready" ]; then
    cfg_v flow git.flow direct
    if [ "$flow" = staging ]; then
      _task_parked_read "$ready"
      if [ -n "$_TASK_PARKED" ]; then
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          _task_parked_lookup_v p "$id"
          [ -z "$p" ] || continue
          kept="$kept${kept:+
}$id"
          k=$((k + 1))
        done <<EOF
$list
EOF
        list=$kept
        n=$k
      fi
    fi
  fi
  # Nothing to put in order below two; the common answers are none and one.
  case "$n" in
    0) ;;
    1) printf '%s\n' "$list" ;;
    *) printf '%s\n' "$list" | sort ;;
  esac
}

# The single candidate on <branch>, or nothing when there are zero or several
# (an advisory hint for `task start`'s dirty-tree refusal, not a resume
# decision — ambiguity there is fine, it just means the message stays
# generic rather than naming a task it cannot be sure of).
_task_likely_owner() {
  local branch="$1" candidates
  candidates=$(_task_candidates_for_branch "$branch")
  [ "$(_task_count_lines "$candidates")" -eq 1 ] || return 0
  printf '%s\n' "$candidates"
}

# --- task.md template ----------------------------------------------------------

# Write <dest> with {{TASK_ID}} substituted, from <from> when given
# (task_new --from: a path, or "-" for stdin — the user's own document,
# copied as-is), otherwise from templates/task.md. Uses jig_source_root when
# the running copy is a framework source checkout (dev mode, and every test
# run); an installed copy (`.ai/scripts/`) ships no templates/ directory at
# all — jig init only ever places files *sourced from* templates/, never the
# directory itself — so that case falls back to a minimal built-in copy of
# the same template. Written atomically.
#
# The substitution is a single `sed s/{{TASK_ID}}/<id>/g` over the source
# stream: <id> is restricted to `[A-Za-z0-9._-]` (_task_valid_id) so it is
# safe as a sed replacement, and sed passes every byte outside the matched
# placeholder through unchanged — no reformatting, no whole-body rewrite, so
# a --from document with backslashes, `&`, backticks, tabs or non-ASCII
# survives byte-for-byte except at the placeholder itself. A document
# without the placeholder is copied verbatim.
_task_write_task_md() {
  local id="$1" dest="$2" from="${3:-}" goal="${4:-}" source tmpl tmp
  tmp="$dest.tmp.$$"
  jig_cleanup_add "$tmp"
  if [ -n "$from" ]; then
    if [ "$from" = "-" ]; then
      sed "s/{{TASK_ID}}/$id/g" > "$tmp"
    else
      sed "s/{{TASK_ID}}/$id/g" "$from" > "$tmp"
    fi
  else
    source=$(jig_source_root)
    tmpl=""
    [ -n "$source" ] && [ -f "$source/templates/task.md" ] && tmpl="$source/templates/task.md"
    if [ -n "$tmpl" ]; then
      sed "s/{{TASK_ID}}/$id/g" "$tmpl" > "$tmp"
    else
      cat > "$tmp" <<EOF
# $id

## Goal

<!-- One paragraph: what must be true when this task is done. -->

## Scope

<!-- In / out. Affected areas or files if known; \`jig context --files\` uses the diff, not this list. -->

## Notes

<!-- Working notes for this task. Nothing here survives the task unless consolidation moves it to .ai/knowledge/. -->
EOF
    fi
  fi
  if [ -n "$goal" ]; then
    jig_cleanup_add "$tmp.goal"
    _task_md_put_goal "$goal" < "$tmp" > "$tmp.goal"
    mv "$tmp.goal" "$dest"
  else
    mv "$tmp" "$dest"
  fi
  jig_record_changed
}

# _task_md_put_goal <goal> — a filter: the brief on stdin, with <goal> as the
# paragraph under its first `## Goal` heading, in place of the template's
# placeholder comment, or as a new paragraph before what follows the heading;
# a brief with no such heading gets one at its end. The goal reaches awk
# through the environment, so it is printed literally (see _task_rewrite_state).
_task_md_put_goal() {
  JIG_T_GOAL="$1" awk '
    BEGIN { goal = ENVIRON["JIG_T_GOAL"] }
    !done && !in_goal && /^##[[:space:]]+Goal[[:space:]]*$/ { print; in_goal = 1; next }
    in_goal && /^[[:space:]]*$/ { print; next }
    in_goal {
      in_goal = 0; done = 1
      print goal
      if ($0 ~ /^[[:space:]]*<!--.*-->[[:space:]]*$/) next
      print ""
    }
    { print }
    END {
      if (in_goal) { print goal; done = 1 }
      if (!done) { print ""; print "## Goal"; print ""; print goal }
    }
  '
}

# --- state file rewriting -------------------------------------------------------

# Rewrite <dir>/state with <key> set to <value> (replacing an existing line,
# or inserting one before `created_at:` when the key is absent) and
# `updated_at` refreshed to today. Atomic write (ADR-0008): state.tmp.$$
# then mv. awk, not sed, does the substitution: <value> is printed literally
# rather than used as a sed replacement, so it needs no escaping.
#
# Values reach awk through the environment, not `-v`: awk expands escape
# sequences (`\n`, `\t`, ...) in a `-v` value, so a reason spelling a literal
# backslash-n (a Windows path such as `C:\temp`, or `--reason` text with one)
# would be written as an actual newline and split the state file into a
# second, bogus key (task_finding_set below uses the same ENVIRON pattern).
_task_rewrite_state() {
  local dir="$1" key="$2" value="$3" file tmp
  _task_guard_dir "$dir"
  file="$dir/state"
  tmp="$dir/state.tmp.$$"
  _task_state_set_into "$file" "$tmp" "$key" "$value"
  mv "$tmp" "$file"
  jig_task_state_forget
  jig_record_changed
}

# _task_ship_resumed_done <id> <dir> <draft> <staging> — a non-draft `task
# ship` into the staging branch has shipped the fix a person took the task
# back for (`park_resumed_at`), whoever takes the git steps from here: Jig, or
# the person by hand from what the ship told them at `none` and `commit`. The
# record goes, and the task is parked again once git or the forge gives a
# reason (adr-20261112-a-task-waiting-at-staging-is-parked-and-resuming-it-is-its-status).
# <staging> is the staging branch the ship goes into, or empty where the
# ship has not asked yet (`none`, which stops before the flow is read): then
# the task is judged as the parked reader judges it, a task on a sound staging
# flow whose base is the project's.
_task_ship_resumed_done() {
  local id="$1" dir="$2" draft="$3" staging="$4" base
  [ "$draft" -eq 0 ] || return 0
  [ -n "$(task_state_get "$id" park_resumed_at)" ] || return 0
  if [ -z "$staging" ]; then
    staging=$(jig_staging_in_use) || return 0
    jig_task_base_v base "$id"
    [ "$base" = "$(cfg git.base_branch main)" ] || return 0
  fi
  _task_state_drop_key "$dir" park_resumed_at
}

# _task_state_drop_key <dir> <key>... — remove <key>s from the task's state,
# refreshing `updated_at`, atomically; a key that is not there changes nothing
# else.
_task_state_drop_key() {
  local dir="$1" tmp
  shift
  tmp="$dir/state.tmp.$$"
  _task_state_without "$dir" "$tmp" "$@"
  mv "$tmp" "$dir/state"
  jig_task_state_forget
  jig_record_changed
}

# _task_state_set_into <src> <dst> <key> <value> — the state file <src> with
# <key> set to <value> and `updated_at` refreshed, into <dst>; <src> is not
# touched. What _task_rewrite_state builds before it moves the file into
# place, apart so that a write checked against a revision (`task set <id>
# status consolidated --revision`) can build the whole file, claim the
# revision and only then move it. <dst> may be <src>'s successor in a chain
# of keys, never <src> itself.
_task_state_set_into() {
  local src="$1" dst="$2" key="$3" value="$4" today
  jig_cleanup_add "$dst"
  today=$(jig_today)
  JIG_S_KEY="$key" JIG_S_VALUE="$value" JIG_S_TODAY="$today" \
    awk '
    BEGIN { key = ENVIRON["JIG_S_KEY"]; value = ENVIRON["JIG_S_VALUE"]; today = ENVIRON["JIG_S_TODAY"] }
    {
      line = $0
      if (line ~ ("^" key ":")) {
        print key ": " value
        done = 1
      } else if (!done && line ~ /^created_at:/) {
        print key ": " value
        print line
        done = 1
      } else if (line ~ /^updated_at:/) {
        print "updated_at: " today
      } else {
        print line
      }
    }
    END {
      if (!done) print key ": " value
    }
  ' "$src" > "$dst"
}

# Rewrite <dir>/state with the <key> line removed (companion to
# _task_rewrite_state above, same atomic write and `updated_at` refresh).
# A no-op, beyond refreshing `updated_at`, when <key> is already absent.
_task_rewrite_state_remove() {
  local dir="$1" key="$2" tmp="$1/state.tmp.$$"
  _task_state_without "$dir" "$tmp" "$key"
  mv "$tmp" "$dir/state"
  jig_task_state_forget
  jig_record_changed
}

# _task_state_without <dir> <tmp> <key>... — build <dir>/state without the
# lines of every <key>, `updated_at` refreshed, into <tmp>, a file beside it;
# the state itself is not touched. A write that must land several removals as
# one — under one revision claim (`task resume`) — moves <tmp> into place
# itself. Called as a plain command, never inside $(...): the guard dies.
_task_state_without() {
  local dir="$1" tmp="$2"
  shift 2
  _task_guard_dir "$dir"
  _task_state_without_into "$dir/state" "$tmp" "$@"
}

# _task_state_without_into <src> <dst> <key>... — the state file <src> without
# the lines of every <key>, `updated_at` refreshed, into <dst>; <src> is not
# touched. What _task_state_without builds, for a chain of changes that began
# with a key set (`task unarchive`). <dst> is never <src>.
_task_state_without_into() {
  local src="$1" tmp="$2" today
  shift 2
  jig_cleanup_add "$tmp"
  today=$(jig_today)
  awk -v keys="$*" -v today="$today" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) drop[k[i]] = 1 }
    {
      line = $0
      key = line
      sub(/:.*/, "", key)
      if (index(line, ":") && (key in drop)) {
        next
      } else if (line ~ /^updated_at:/) {
        print "updated_at: " today
      } else {
        print line
      }
    }
  ' "$src" > "$tmp"
}

# _task_touch_state <dir> — refresh `updated_at` and mark the status page,
# for a write that changed a workspace without changing a key. Rewriting an
# artifact is such a write: state carries no artifact field, but a task whose
# plan was rewritten today is not a task last touched last week, and a status
# page that still shows the old date says the task is untouched (ADR-0008:
# the page never shows less than the files do). Same atomic write as
# _task_rewrite_state, and a no-op when the state file is gone.
_task_touch_state() {
  local dir="$1" file tmp today
  _task_guard_dir "$dir"
  file="$dir/state"
  [ -f "$file" ] || return 0
  tmp="$dir/state.tmp.$$"
  jig_cleanup_add "$tmp"
  today=$(jig_today)
  awk -v today="$today" '
    /^updated_at:/ { print "updated_at: " today; next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
  jig_task_state_forget
  jig_record_changed
}

# --- pause / resume helpers (design §4, §5) --------------------------------------

# Whole days between <date> (YYYY-MM-DD) and today; 0 when <date> is empty or
# unparsable. Mirrors jig_file_age_days's BSD/GNU `date` portability trick
# (ADR-0002: no GNU-only tools assumed).
_task_days_since() {
  local d="$1" ts now
  [ -n "$d" ] || { printf '0\n'; return; }
  if ts=$(date -j -f '%Y-%m-%d' "$d" +%s 2>/dev/null); then :; else
    ts=$(date -d "$d" +%s 2>/dev/null) || { printf '0\n'; return; }
  fi
  now=$(date +%s)
  printf '%d\n' $(( (now - ts) / 86400 ))
}

# _task_resume_overlap <id> — files this task changed that were also changed
# on the task's base since the merge base (design §5: overlap, not distance).
# Exit 1, printing nothing, when the base or the merge base is missing — the
# resume report omits the section then, and `--json` reports `null`.
#
# _task_resume_overlap <id> [<tree> [<branch>]] — <tree> is the checkout the
# task's branch is checked out in, this one by default; its uncommitted
# changes count as the task's. With <tree> empty the branch is checked out
# nowhere, and only its commits (<branch> against the merge base) count: a
# resume run from another checkout must not read that checkout's HEAD as the
# task's.
_task_resume_overlap() {
  local base ref mb task_files base_files tree="${2-$JIG_PROJECT}" branch="${3:-}" head=HEAD
  base=$(jig_task_base "$1")
  ref=$(jig_base_ref "$base")
  [ -n "$ref" ] || return 1
  [ -n "$tree" ] || head=$branch
  [ -n "$head" ] || return 1
  mb=$(git -C "${tree:-$JIG_PROJECT}" merge-base "$ref" "$head" 2>/dev/null) || return 1
  if [ -n "$tree" ]; then
    task_files=$(_task_touched_in "$tree" "$base")
  else
    task_files=$(git -C "$JIG_PROJECT" diff --name-only "$mb" "$branch" 2>/dev/null)
  fi
  base_files=$(git -C "$JIG_PROJECT" diff --name-only "$mb" "$ref" 2>/dev/null)
  comm -12 \
    <(printf '%s\n' "$task_files" | sed '/^$/d' | sort -u) \
    <(printf '%s\n' "$base_files" | sed '/^$/d' | sort -u)
}

# _task_touched_in <tree> <base> — jig_git_touched_files read in the checkout
# at <tree>: a local JIG_PROJECT, which bash scopes to this call.
_task_touched_in() {
  local JIG_PROJECT="$1"
  jig_git_touched_files --base-branch "$2"
}

# _task_branch_name <id> — the branch this task will live on, from
# `git.branch_template` with {id} substituted. Dies on a name git would
# reject, using git's own rules rather than a hand-rolled regex: the set of
# invalid ref names is long (`..`, a trailing `.lock`, control characters, a
# leading dash) and getting it wrong here means creating a ref nobody can
# delete without plumbing.
_task_branch_name() {
  local id="$1" template name
  template=$(cfg git.branch_template "task/{id}")
  case "$template" in
    *'{id}'*) ;;
    *) jig_die "task start: git.branch_template must contain {id}: $template" ;;
  esac
  name=${template%%'{id}'*}$id${template#*'{id}'}
  git check-ref-format --branch "$name" >/dev/null 2>&1 \
    || jig_die "task start: git rejects the branch name: $name"
  if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1; then
    jig_die "task start: branch already exists: $name (reusing it would attach this task to someone else's work)"
  fi
  printf '%s\n' "$name"
}

# _task_dirty_only_spec_raw <tracked-status-lines> — one candidate spec id
# per input line (empty for a line outside every spec), unsorted. A function
# of its own because bash 3.2 misparses a `case` written inside `$( )` (as
# `_jp_decide_raw`, profile.sh) — the loop has to live outside the
# substitution _task_dirty_only_spec reads it through.
#
# A rename line ("R  old -> new") is read from its new path; a quoted path
# (git quotes one holding a space or a non-ASCII byte) has its surrounding
# quotes stripped.
_task_dirty_only_spec_raw() {
  local lines="$1" prefix path rest line
  prefix="$JIG_AI_DIR/specs/"
  printf '%s\n' "$lines" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Columns 1-2 are the status codes, column 3 a space; the path starts
    # at column 4 (git status --porcelain's fixed format).
    path=${line#???}
    case "$path" in
      *' -> '*) path=${path#*' -> '} ;;
    esac
    case "$path" in
      \"*\") path=${path#\"}; path=${path%\"} ;;
    esac
    case "$path" in
      "$prefix"*)
        rest=${path#"$prefix"}
        printf '%s\n' "${rest%%/*}"
        ;;
      *)
        printf '\n'
        ;;
    esac
  done
}

# _task_dirty_only_spec <tracked-status-lines> — the one spec id every line
# names under `.ai/specs/<id>/`, or nothing when the lines are empty, name
# more than one id, or touch a path outside every spec. Told apart from "some
# other task's tracked work" so the refusal below can name the door that is
# actually open: `jig spec ship`, not `commit them`.
_task_dirty_only_spec() {
  local lines="$1" ids
  ids=$(_task_dirty_only_spec_raw "$lines" | sort -u)
  # More than one distinct value (several specs, or a spec mixed with
  # anything else), or the lone value being empty (nothing under a spec at
  # all): neither names one spec to point at.
  case "$ids" in
    *$'\n'*) return 1 ;;
    '') return 1 ;;
  esac
  jig_valid_id "$ids" || return 1
  [ -d "$JIG_PROJECT/$JIG_AI_DIR/specs/$ids" ] || return 1
  printf '%s\n' "$ids"
}

# _task_refuse_busy_checkout <id> — refuse to move this checkout's HEAD under
# another session (adr-20260924-a-checkout-records-what-is-happening-in-it).
#
# Who occupies this checkout is decided in one place, jig_checkout_occupants
# (checkout.sh), which `jig upgrade` reads too: a fresh record named by a task
# that has been started, is not consolidated or abandoned, and whose branch is
# the one checked out here. The task being started and this session's own id
# are left out. Nothing is deleted. Only the start that takes over this
# checkout asks: `--worktree` leaves it as it was, and a project on one branch
# moves no HEAD.
#
# The way out is named, as the dirty-tree refusal names its own. There is no
# override (ADR-0029 records that the dirty-tree one was overridden every
# time), and no advice to delete a record: what is left is a live session's
# task on HEAD, and the record lapses by itself after checkout.busy_ttl.
_task_refuse_busy_checkout() {
  local id="$1" name age cmd fname="" fage="" fcmd="" rest=0 more=""
  cfg_bool git.branch_per_task true || return 0
  while read -r name age cmd; do
    [ -n "$name" ] || continue
    if [ -z "$fname" ]; then
      fname="$name"
      fage="$age"
      fcmd="$cmd"
    else
      rest=$((rest + 1))
    fi
  done < <(jig_checkout_occupants "$id" "$(_task_parked_ids_here)")
  [ -n "$fname" ] || return 0
  [ "$rest" -eq 0 ] || more=" (and $rest more)"
  jig_die "task start: this checkout is in use: task $fname ran \`jig $fcmd\` $(jig_checkout_ago "$fage") ago$more; start $id in its own worktree: \`jig task start $id --worktree\`, or wait until that work has finished"
}

# Refuse to start a task on a dirty working tree (design §6): untracked files
# never block (build output is not work in progress), only tracked changes do —
# a `git status --porcelain` line that is not `??` (jig_tracked_changes,
# common.sh). There is no override: the changes would ride into the new
# branch and become this task's first commit, which is how four tasks
# recorded someone else's work on 2026-09-11.
#
# The refusal is a fork, not a dead end, when branches are per task: the other
# road is a worktree of its own, which leaves this checkout — and the work in
# it — untouched (ADR-0029). When every tracked change lies under one spec's
# own directory, the door is `jig spec ship`, not a commit or a pause: the
# dirt is a spec `jig-idea` left mid-session, not another task's work
# (idea-leaves-a-tree-task-start-refuses).
_task_refuse_dirty_tree() {
  local branch="$1" id="${2:-}" tracked owner fork="" spec_id
  tracked=$(jig_tracked_changes)
  [ -n "$tracked" ] || return 0

  if [ -n "$id" ] && cfg_bool git.branch_per_task true; then
    fork=", or start it in its own worktree: \`jig task start $id --worktree\`"
  fi
  spec_id=$(_task_dirty_only_spec "$tracked") || spec_id=""
  if [ -n "$spec_id" ]; then
    jig_die "task start: uncommitted changes under $JIG_AI_DIR/specs/$spec_id/; ship it first: \`jig spec ship $spec_id\`$fork"
  fi
  owner=$(_task_likely_owner "$branch")
  if [ -n "$owner" ]; then
    jig_die "task start: uncommitted changes in the working tree, likely from task $owner; run \`jig task pause $owner --stash\` first$fork"
  else
    jig_die "task start: uncommitted changes in the working tree; commit them, or pause the task that owns them with --stash$fork"
  fi
}

# --- subcommands ----------------------------------------------------------------

# task_new <id> [...] — file a task. `--json` anywhere runs the whole command
# as the producer of json_run (conventions/json-output.md), so a program reads
# the filed task, or why it was refused, in the envelope: an id already taken
# is `already-exists`, an invalid one `usage` (schemas/json.md).
task_new() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_new_body 1 "$@"
      return
    fi
  done
  _task_new_body 0 "$@"
}

# _task_new_body <as_json> <id> [...] — the body of `task new`; with <as_json>
# 1 it runs inside json_run and prints the filed task as data, not its path.
_task_new_body() {
  local as_json="$1" arg args=()
  shift
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ $# -ge 1 ] || jig_fail usage "$(_task_usage new)"
  local id="$1"
  shift
  local class="" domains="" from="" depth="" goal="" goal_given=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --lean) depth=lean; shift ;;
      --class) [ $# -ge 2 ] || jig_fail usage "task new: --class requires a value"; class="$2"; shift 2 ;;
      --domains) [ $# -ge 2 ] || jig_fail usage "task new: --domains requires a value"; domains="$2"; shift 2 ;;
      --from) [ $# -ge 2 ] || jig_fail usage "task new: --from requires a value"; from="$2"; shift 2 ;;
      --goal) [ $# -ge 2 ] || jig_fail usage "task new: --goal requires a value"; goal="$2"; goal_given=1; shift 2 ;;
      *) jig_fail usage "task new: unknown argument: $1" ;;
    esac
  done

  _task_valid_id "$id" || jig_fail usage "task new: invalid task id: $id"
  [ -z "$class" ] || _task_valid_class "$class" || jig_fail usage "task new: invalid class: $class"
  [ -z "$domains" ] || _task_valid_domains "$domains" || jig_fail usage "task new: invalid domains: $domains"
  # The goal is the paragraph under `## Goal` that `task list --goals` and
  # `task list --json` read back (jig_goal_check, which `spec item file --new` shares).
  if [ "$goal_given" -eq 1 ]; then
    [ -z "$from" ] || jig_fail usage "task new: --goal and --from both write task.md; give one of them"
    jig_goal_check "task new" "$goal"
    goal=$JIG_GOAL
  fi

  # A task filed in a worktree that keeps a task directory of its own dies with
  # that worktree: the directory is gitignored, the checkout holding the queue
  # never sees it, and `git worktree remove` deletes ignored files without a
  # word. Three statements written by agents at the end of their own work were
  # nearly lost that way in one shift. A worktree from `jig task start
  # --worktree` borrows the owner's directory whole and files the task with
  # every other one, so it never reaches this check; any other worktree is told
  # where the task belongs instead of losing it quietly.
  local clone_root
  if ! _task_borrowed_tasks_root >/dev/null 2>&1; then
    clone_root=$(jig_config_clone_root)
    [ "$clone_root" = "$JIG_PROJECT" ] \
      || jig_die "task new: this worktree keeps a $JIG_AI_DIR/workspace/tasks/ of its own, so a task filed here would be invisible to $clone_root and would go when the worktree goes; file it in $clone_root"
  fi

  local dir
  dir=$(task_dir "$id")
  [ -e "$dir" ] && jig_fail already-exists "task new: task already exists: $id"
  # The tasks directory may not exist yet (`mkdir -p` below makes it), and then
  # it is `.ai/workspace` that has to be this repository's: made through a link
  # there it would be made outside.
  local ws_path="$JIG_PROJECT/$JIG_AI_DIR/workspace" ws_real
  if [ -e "$ws_path/tasks" ] || [ -L "$ws_path/tasks" ]; then
    _task_tasks_root "task new" >/dev/null
  elif [ -e "$ws_path" ] || [ -L "$ws_path" ]; then
    ws_real=$(cd -P "$ws_path" 2>/dev/null && pwd -P) \
      || jig_die "task new: cannot inspect $JIG_AI_DIR/workspace"
    _task_worktree_holds "$ws_real" "$JIG_AI_DIR/workspace" \
      || jig_die "task new: $JIG_AI_DIR/workspace leads to $ws_real, which is no checkout of this repository"
  fi


  # --from is validated here, before the workspace directory exists, so a
  # missing/unreadable/non-regular source (a directory, for instance) never
  # leaves a half-created task behind. "-" means stdin: nothing to check.
  if [ -n "$from" ] && [ "$from" != "-" ]; then
    [ -e "$from" ] || jig_die "task new: --from: no such file: $from"
    [ -f "$from" ] || jig_die "task new: --from: not a regular file: $from"
    [ -r "$from" ] || jig_die "task new: --from: file not readable: $from"
  fi

  # The tracker issue, read from the id by the project's pattern before the
  # workspace exists. A pattern awk cannot read files the task without one: a
  # typo in the project's config is not a reason to refuse the work.
  local issue="" issue_rc=0
  issue=$(_task_issue_from_id "$id") || issue_rc=$?
  [ "$issue_rc" -eq 0 ] \
    || jig_warn "task new: task.issue_pattern is not a pattern awk can read; no issue recorded"

  # No dirty-tree check here: filing touches neither the checkout nor the
  # branch, so there is nothing for uncommitted work to leak into. The check
  # lives in `task start`, and filing a task for later in the middle of other
  # work is the case this split exists for.
  # The directory, made without -p, refuses an id already filed; the claim on
  # it is the state file below, since `mkdir` does not exclude a second maker
  # everywhere (adr-20261023-a-claim-is-an-exclusive-create).
  mkdir -p "$(dirname "$dir")"
  if ! mkdir "$dir" 2>/dev/null; then
    [ -e "$dir" ] && jig_fail already-exists "task new: task already exists: $id"
    jig_die "task new: cannot create $(jig_relpath "$dir" "$JIG_PROJECT")"
  fi

  # `branch` and `base_commit` are written by `task start`, not here. A task
  # filed for later has no branch, and saying so by *omission* is what makes
  # it invisible to `_task_candidates_for_branch`: an absent value matches no
  # branch name, so the task cannot become an ambiguous `task current`
  # candidate. Before this, a filed task claimed whatever branch the checkout
  # happened to be on, and four of them claimed a branch they had nothing to
  # do with in a single day (ADR-0026, as amended).
  local tmp="$dir/state.tmp.$$"
  jig_cleanup_add "$tmp"
  {
    printf 'task_id: %s\n' "$id"
    [ -z "$issue" ] || printf 'issue: %s\n' "$issue"
    [ -z "$class" ] || printf 'class: %s\n' "$class"
    printf 'status: active\n'
    printf 'knowledge_consolidated: false\n'
    # Filed under the route-evidence check (adr-20261004-a-route-stage-is-proven-by-its-record):
    # a task without this key was filed before it and is only warned.
    printf 'route_evidence: required\n'
    [ -z "$domains" ] || printf 'domains: %s\n' "$domains"
    [ -z "$depth" ] || printf 'route_depth: %s\n' "$depth"
    printf 'created_at: %s\n' "$(jig_today)"
    printf 'updated_at: %s\n' "$(jig_today)"
  } > "$tmp"
  # The state file is the claim on the id: the directory alone is not, since
  # `mkdir` does not exclude a second maker everywhere
  # (adr-20261023-a-claim-is-an-exclusive-create). Claimed empty, then
  # replaced whole by the rename, so no reader sees a partial state (ADR-0008).
  if ! jig_claim_file "$dir/state"; then
    rm -f "$tmp"
    jig_fail already-exists "task new: task already exists: $id"
  fi
  mv "$tmp" "$dir/state"
  jig_task_state_forget
  jig_record_changed

  _task_write_task_md "$id" "$dir/task.md" "$from" "$goal"

  if [ "$as_json" = 1 ]; then
    # The filed task as `task list --json` lists it: one producer of a task's
    # facts. A task just filed has no branch, so no worktree to look up, and
    # no housekeeping flag can stand for it yet; nor has the forge cache a
    # pull request of it, but the producer looks it up.
    # shellcheck source=lib/forgecache.sh
    . "$JIG_LIB/forgecache.sh"
    printf '{"task":%s}\n' "$(_task_list_json_task "$id" "" "")"
    return 0
  fi
  jig_relpath "$dir" "$JIG_PROJECT"
  _task_not_queued_hint "$id"
}

# task_start <id> — begin work on a filed task: cut its branch, check it out
# and record where it forked from.
#
# Separate from `resume` on purpose. `resume` means "undo a pause", and a task
# can be *both* unstarted and paused — every task filed on 2026-09-11 was. One
# verb doing either thing depending on hidden state would collapse the two
# absences this design just separated, which is the ambiguity ADR-0012 refused
# for `task current`.
#
# The branch is cut here rather than at `task new` because a fork point
# recorded weeks before work begins is a fact that is false by the time it is
# first needed (ADR-0026, as amended).
task_start() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage start)"
  local id="$1" worktree=0 bootstrap=1 share out_of_order=0 ooo_reason="" reason_given=0
  shift
  _TASK_ADD_SHARES=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) worktree=1; shift ;;
      --no-bootstrap) bootstrap=0; shift ;;
      --out-of-order) out_of_order=1; shift ;;
      --reason)
        [ $# -ge 2 ] || jig_die "task start: --reason needs a text"
        ooo_reason=$2; reason_given=1
        shift 2
        ;;
      --share)
        [ $# -ge 2 ] || jig_die "task start: --share needs a directory"
        share=$(_task_share_arg "task start" "$2") || exit 1
        _TASK_ADD_SHARES="$_TASK_ADD_SHARES$share
"
        shift 2
        ;;
      *) jig_die "task start: unknown argument: $1" ;;
    esac
  done
  [ "$reason_given" = 0 ] || [ "$out_of_order" = 1 ] \
    || jig_die "task start: --reason gives the cause of --out-of-order; it needs --out-of-order"
  if [ "$out_of_order" = 1 ]; then
    case "$ooo_reason" in
      *[![:space:]]*) ;;
      *) jig_die "task start: --out-of-order needs the reason: jig task start $id --out-of-order --reason \"<why>\"" ;;
    esac
  fi
  [ "$bootstrap" = 1 ] || [ "$worktree" = 1 ] \
    || jig_die "task start: --no-bootstrap says what not to carry into a worktree; it needs --worktree"
  [ -z "$_TASK_ADD_SHARES" ] || [ "$worktree" = 1 ] \
    || jig_die "task start: --share gives a worktree a directory of this checkout; it needs --worktree"
  [ -z "$_TASK_ADD_SHARES" ] || [ "$bootstrap" = 1 ] \
    || jig_die "task start: --share is done by the bootstrap that --no-bootstrap skips; drop one of them"
  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task start"

  # A `branch` with no `base_commit` was recorded at filing, before starting
  # was a separate step: it is the branch the checkout happened to be on, not
  # one the task forked. Such a task was never started, and starting it is how
  # its record gets repaired — by the script that owns the key, not by hand
  # (ADR-0008). A task with a fork point is started, and stays refused.
  local existing refusal
  existing=$(task_state_get "$id" branch)
  refusal=$(_task_start_refusal "$id") || exit 1
  if [ -n "$refusal" ]; then
    if [ "$worktree" -eq 1 ]; then
      _task_move_to_worktree "$id" "$dir" "$existing" "$bootstrap"
      return 0
    fi
    jig_die "$refusal"
  fi
  # A brief with no goal: work begun on an empty template asks the questions
  # the person already answered somewhere else. T3/T4 are refused (their gate
  # reads the design that the goal feeds), lower classes are warned. Only a
  # task not yet started is asked; moving a started one into a worktree is not
  # a beginning.
  refusal=$(_task_start_goal_refusal "$id")
  [ -z "$refusal" ] || jig_die "$refusal"
  # The queue's order: a task another one outranks is started only on a reason
  # (adr-20261022). Before anything is created; a task that is not queued has
  # no place in the order.
  local ahead="" ahead_ref ahead_pri
  _task_queue_ahead_v ahead "$id"
  if [ -n "$ahead" ]; then
    ahead_ref=${ahead%%$'\t'*}
    ahead_pri=${ahead#*$'\t'}
    if [ "$ahead_pri" = "-" ]; then ahead_pri="no priority"; else ahead_pri="P$ahead_pri"; fi
    [ "$out_of_order" = 1 ] \
      || jig_die "task start: first in the queue is $ahead_ref ($ahead_pri); to start $id instead: jig task start $id --out-of-order --reason \"<why>\""
  fi
  if ! jig_task_has_goal "$dir/task.md"; then
    # shellcheck disable=SC2016 # the backticks quote a command for the reader
    jig_warn "$(printf 'task start: %s has no goal: `## Goal` in task.md is empty; write it with `jig task artifact write %s task --from <file>`' "$id" "$id")"
  fi
  if [ -n "$existing" ]; then
    jig_info "task start: $id recorded $existing when it was filed, with no fork point; starting it now"
  fi

  # The base the task is cut from and has to land on, recorded beside the
  # fork point so that everything judging the task later reads the same
  # answer (ADR-0039). Checked before anything is created.
  local base
  base=$(_task_start_base "$id") || exit 1

  # A repository with no commit has nothing to fork from: git cannot cut a
  # branch there, and "could not create branch" named the symptom, not the
  # cause.
  git -C "$JIG_PROJECT" rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
    || jig_die "task start: the repository has no commits yet; commit something first (even a README), then start the task"

  if [ "$worktree" -eq 1 ]; then
    _task_start_in_worktree "$id" "$dir" "$base" "$bootstrap"
    _task_record_out_of_order "$id" "$dir" "$out_of_order" "$ahead" "$ooo_reason"
    return 0
  fi

  # Before either path, not only before a branch is cut: with one shared
  # branch the leak is the same — base_commit would name a point the
  # uncommitted work is already on top of.
  _task_refuse_dirty_tree "$(_task_current_branch)" "$id"
  _task_refuse_busy_checkout "$id"

  local branch base_commit
  if cfg_bool git.branch_per_task true; then
    branch=$(_task_branch_name "$id")
    base_commit=$(_task_start_branch "$branch" "$base") \
      || jig_die "task start: could not create branch $branch"
  else
    # A project that works on one branch by choice still gets a start: the
    # task records where it began, which is what housekeeping needs to tell
    # "did nothing" from "landed".
    branch=$(_task_current_branch)
    base_commit=$(git -C "$JIG_PROJECT" rev-parse HEAD 2>/dev/null) \
      || jig_die "task start: cannot resolve HEAD"
  fi

  _task_rewrite_state "$dir" branch "$branch"
  _task_rewrite_state "$dir" base_commit "$base_commit"
  _task_rewrite_state "$dir" base_branch "$base"
  _task_executor_freeze "$id" "$dir"
  _task_base_hint "$id" "$base"
  _task_paused_hint "$id" ""
  _task_record_out_of_order "$id" "$dir" "$out_of_order" "$ahead" "$ooo_reason"
  printf '%s\n' "$branch"
}

# _task_queue_ahead_v <var> <id> — jig_queue_ahead_v (queue.sh, loaded here on
# first use): `task:Y<TAB><priority or ->` of the task the queue puts before
# <id>, or nothing.
_task_queue_ahead_v() {
  declare -F jig_queue_ahead_v >/dev/null 2>&1 || {
    # shellcheck source=lib/queue.sh
    . "$JIG_LIB/queue.sh"
  }
  jig_queue_ahead_v "$1" "$2"
}

# _task_record_out_of_order <id> <dir> <asked 0|1> <ahead> <reason> — after a
# start that was asked to go out of order: the task it went ahead of and the
# reason, into the task's state, where status shows them while the task lives.
# <ahead> is empty when the task was first in the queue anyway: then nothing is
# recorded, and the person is told so.
_task_record_out_of_order() {
  local id="$1" dir="$2" asked="$3" ahead="$4" reason="$5"
  [ "$asked" = 1 ] || return 0
  if [ -z "$ahead" ]; then
    if jig_queue_place "$id"; then
      jig_info "task start: $id is first in the queue; --out-of-order was not needed and nothing was recorded"
    else
      jig_info "task start: $id is not in the queue; --out-of-order was not needed and nothing was recorded"
    fi
    return 0
  fi
  _jig_replace_all_v reason "$reason" $'\t' ' '
  _jig_replace_all_v reason "$reason" $'\r' ' '
  _jig_replace_all_v reason "$reason" $'\n' ' '
  _task_rewrite_state "$dir" out_of_order_over "${ahead%%$'\t'*}"
  _task_rewrite_state "$dir" out_of_order_reason "$reason"
  jig_info "task start: $id was started ahead of ${ahead%%$'\t'*}; the reason is recorded: $reason"
}

# _task_start_refusal <id> — why `jig task start <id>` refuses this task by its
# state, or nothing when it would start it: a task with a fork point is
# started. The one guard the command and the actions table (_task_actions)
# both ask; what a start refuses by the checkout instead — a dirty tree, an
# occupied HEAD, a base that cannot be found — is the command's alone.
_task_start_refusal() {
  local id="$1"
  _task_started "$id" || return 0
  local branch
  task_state_var branch "$id" branch
  # shellcheck disable=SC2016 # the backticks quote a command for the reader
  printf 'task start: already started on %s; to give it a worktree of its own: `jig task start %s --worktree`\n' "$branch" "$id"
}

# _task_started <id> — exit 0 when the task has been started: `task start`
# recorded its branch and the commit it forked from. One test, asked by the
# start's refusal and by the actions table's request-pause row.
_task_started() {
  local branch base_commit
  task_state_var branch "$1" branch
  task_state_var base_commit "$1" base_commit
  [ -n "$branch" ] && [ -n "$base_commit" ]
}

# _task_request_pause_unstarted_refusal <id> — why the actions table does not
# offer `request-pause` for a task nobody started, or nothing. A request is
# honoured where a stage begins, and a task not started enters none, so a
# board that wrote one would show "requested" until someone started the task
# (pause-not-started-directly). The command still takes it — the table
# withholds more than it refuses (adr-20261015-one-table-of-what-a-person-may-do) —
# and the reason sends the person to the direct pause, which the table offers.
_task_request_pause_unstarted_refusal() {
  _task_started "$1" && return 0
  printf 'task %s is not started: no stage will take a pause request; pause it directly: jig task pause %s\n' "$1" "$1"
}

# _task_start_goal_refusal <id> — why `jig task start <id>` refuses a T3/T4
# task whose task.md has no goal (jig_task_has_goal), or nothing. Lower classes,
# and a task with no class, are only warned by the command. Asked by the
# command and by the actions table, after _task_start_refusal.
_task_start_goal_refusal() {
  local id="$1" class dir
  task_state_var class "$id" class
  case "$class" in
    T3 | T4) ;;
    *) return 0 ;;
  esac
  task_dir_v dir "$id"
  jig_task_has_goal "$dir/task.md" && return 0
  # shellcheck disable=SC2016 # the backticks quote a command for the reader
  printf 'task start: %s is %s and has no goal: `## Goal` in task.md is empty; write it first with `jig task artifact write %s task --from <file>`\n' \
    "$id" "$class" "$id"
}

# _task_start_in_worktree <id> <dir> — start the task on its own branch in a
# new worktree, leaving this checkout exactly as it was (ADR-0029).
#
# The workspace does not move. The worktree gets one link to the owner's whole
# `tasks/` directory (_task_link_workspace), so the checkout the task was filed
# in keeps seeing every task — including the ones filed from inside the
# worktree, which a link to this one task alone left stranded — and the
# workspace's lifecycle — housekeeping, trash — stays in one place. The link is
# absolute because git keeps worktree paths absolute too; moving the repository
# breaks both alike, and `git worktree repair` is the answer to that.
#
# No dirty-tree check: nothing uncommitted here can reach a tree cut fresh
# from the base. The command prints the path and stops there: a script cannot
# move the agent session that called it. Getting a session into the worktree —
# switching one there, where the runtime allows it, or opening a new one — is
# the agent's and the human's step, not jig's (ADR-0029 as amended).
_task_start_in_worktree() {
  local id="$1" dir="$2" base="$3" bootstrap="${4:-1}" branch path owner base_commit
  cfg_bool git.branch_per_task true \
    || jig_die "task start: --worktree needs git.branch_per_task: true (one branch cannot be checked out in two worktrees)"
  branch=$(_task_branch_name "$id")
  path="$(_task_worktree_root)/$id"
  if [ -e "$path" ] || [ -L "$path" ]; then
    jig_die "task start: worktree path already exists: $path"
  fi
  owner=$(cd -P "$dir" && pwd -P) || jig_die "task start: cannot resolve the workspace of $id"
  # Before anything is created: without a directory link the worktree could
  # only get a copy of the workspace, and a copy is two tasks from its first
  # write (jig_link_detect).
  jig_link_detect
  [ "$_JIG_LINK_KIND" != none ] \
    || jig_die "task start: --worktree needs a directory link, and neither a symlink nor a junction can be made here; start the task in this checkout instead"

  local start
  start=$(jig_fresh_base_ref "$base" "task start") || exit 1
  base_commit=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$start^{commit}" 2>/dev/null) \
    || jig_die "task start: cannot resolve $start"

  if ! git -C "$JIG_PROJECT" worktree add -q -b "$branch" "$path" "$base_commit" >/dev/null 2>&1; then
    _task_undo_worktree_start "$branch" "$path" "$base_commit"
    jig_die "task start: could not create worktree $path"
  fi
  if ! _task_link_workspace "$owner" "$path" "$id"; then
    _task_undo_worktree_start "$branch" "$path" "$base_commit"
    jig_die "task start: could not link the workspace of $id into $path"
  fi
  path=$(cd -P "$path" && pwd -P) || jig_die "task start: cannot resolve worktree $path"

  _task_rewrite_state "$dir" branch "$branch"
  _task_rewrite_state "$dir" base_commit "$base_commit"
  _task_rewrite_state "$dir" base_branch "$base"
  _task_executor_freeze "$id" "$dir"

  # Only now, with the task started and its workspace linked, is the state git
  # does not track carried over. Last, and never fatal: a tree missing a
  # dependency is not a broken task, and what a failed carry leaves behind --
  # the tree and the branch -- is exactly what `jig task bootstrap` needs to
  # try again (adr-20260924-a-worktree-carries-what-git-does-not).
  if [ "$bootstrap" = 1 ]; then
    _task_carry_into "$JIG_PROJECT" "$path" "task start" "$id"
  fi

  _task_base_hint "$id" "$base"
  _task_paused_hint "$id" " there"
  jig_info "task start: $id is on $branch in its own worktree; open a new agent session in $path"
  printf '%s\n' "$path"
}

# _task_move_to_worktree <id> <dir> <branch> <bootstrap> — give a task that is
# already started a worktree of its own: `jig task start <id> --worktree` on a
# started task. It is the way out of the refusal `task start` gives when this
# checkout is in use, and the move the moved-HEAD notice names.
#
# What it does is the four manual steps: free the branch here, add the worktree
# on it, link the workspace, carry the declared state. Nothing is recorded
# anew: the branch, the fork point and the base are the task's already, and the
# commits made so far ride along with the branch.
#
# Freeing the branch is the move `checkout-is-occupied` warns about, so it is
# made only when it takes nothing from anybody: the tree must have no tracked
# changes (a dirty one is a fork, as for `task start`: commit, or `jig task
# pause <id> --stash`), and HEAD goes to the task's base branch, which git
# refuses when that branch is checked out elsewhere or the switch would
# overwrite a file. Every refusal comes before anything is changed, and a
# failure after the switch puts HEAD back. The branch is never deleted, and
# the way back (a worktree into this checkout) is not offered: `git worktree
# remove` and `git switch` do it.
_task_move_to_worktree() {
  local id="$1" dir="$2" branch="$3" bootstrap="${4:-1}" path owner here other target="" moved=0
  cfg_bool git.branch_per_task true \
    || jig_die "task start: --worktree needs git.branch_per_task: true (one branch cannot be checked out in two worktrees)"
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 \
    || jig_die "task start: $id is started on $branch, which does not exist here; nothing to move"
  # `_task_worktrees` leaves this checkout out, so what it finds is elsewhere.
  other=$(_task_worktree_for "$branch" "$(_task_worktrees)")
  if [ -n "$other" ]; then
    jig_die "task start: $id is already on $branch in its own worktree: $other"
  fi
  here=$(_task_current_branch)
  path="$(_task_worktree_root)/$id"
  if [ -e "$path" ] || [ -L "$path" ]; then
    jig_die "task start: worktree path already exists: $path"
  fi
  owner=$(cd -P "$dir" && pwd -P) || jig_die "task start: cannot resolve the workspace of $id"
  jig_link_detect
  [ "$_JIG_LINK_KIND" != none ] \
    || jig_die "task start: --worktree needs a directory link, and neither a symlink nor a junction can be made here"

  if [ "$here" = "$branch" ]; then
    # This checkout holds the branch: it has to let go first.
    if [ -n "$(jig_tracked_changes)" ]; then
      jig_die "task start: $branch is checked out here with uncommitted changes, and a worktree cannot take them along; commit them, or run \`jig task pause $id --stash\`, then move the task"
    fi
    target=$(task_state_get "$id" base_branch)
    [ -n "$target" ] || target=$(cfg git.base_branch main)
    git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$target" >/dev/null 2>&1 \
      || jig_die "task start: cannot leave $branch here: base branch $target does not exist locally; switch this checkout to another branch, then run this again"
    git -C "$JIG_PROJECT" switch -q "$target" >/dev/null 2>&1 \
      || jig_die "task start: cannot leave $branch here: switching this checkout to $target failed (checked out in another worktree, or it would overwrite a file); switch it to another branch yourself, then run this again"
    moved=1
  fi

  if ! git -C "$JIG_PROJECT" worktree add -q "$path" "$branch" >/dev/null 2>&1; then
    _task_undo_move "$moved" "$branch" "$path"
    jig_die "task start: could not create worktree $path; $id stays on $branch"
  fi
  if ! _task_link_workspace "$owner" "$path" "$id"; then
    _task_undo_move "$moved" "$branch" "$path"
    jig_die "task start: could not link the workspace of $id into $path"
  fi
  path=$(cd -P "$path" && pwd -P) || jig_die "task start: cannot resolve worktree $path"

  if [ "$bootstrap" = 1 ]; then
    _task_carry_into "$JIG_PROJECT" "$path" "task start" "$id"
  fi

  _task_paused_hint "$id" " there"
  if [ "$moved" -eq 1 ]; then
    jig_info "task start: $id moved to its own worktree; this checkout is on $target now"
  fi
  jig_info "task start: $id is on $branch in its own worktree; open a new agent session in $path"
  printf '%s\n' "$path"
}

# _task_undo_move <moved> <branch> <path> — undo a half-made move: remove the
# worktree, and put this checkout back on the branch when it was taken off it.
# Never deletes the branch: it was the task's before the move began.
_task_undo_move() {
  git -C "$JIG_PROJECT" worktree remove "$3" >/dev/null 2>&1 || true
  git -C "$JIG_PROJECT" worktree prune >/dev/null 2>&1 || true
  [ "$1" -eq 1 ] || return 0
  git -C "$JIG_PROJECT" switch -q "$2" >/dev/null 2>&1 \
    || jig_info "task start: could not put this checkout back on $2 (a worktree is still at $3); remove it with \`git worktree remove\`, then \`git switch $2\`"
}

# _task_carry_into <owner-abs> <tree-abs> <verb> <id> — load the bootstrap
# library and carry the declared state into a task worktree. A wrapper so that
# `task start --worktree` and `task bootstrap` load the same two libraries the
# same way, and so that every other task command pays for neither (verify.sh
# sources profiles.sh on the same terms).
#
# The directories asked for with `--share` (_TASK_ADD_SHARES) join the task's
# `share` here, right before the bootstrap that mirrors them, so a start that
# died earlier records none. The project's `worktree.setup` outcome is kept as
# `setup`: a failure stays visible in `jig status` and `jig task route` after
# the warning has scrolled away, until a bootstrap finishes the worktree
# (adr-20261026-a-worktree-is-finished-by-the-projects-command).
_task_carry_into() {
  local id="$4" dir shares one
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"
  # shellcheck source=lib/bootstrap.sh
  . "$JIG_LIB/bootstrap.sh"
  dir=$(task_dir "$id")
  shares=$(task_state_get "$id" share | tr ',' '\n')
  if [ -n "${_TASK_ADD_SHARES:-}" ]; then
    while IFS= read -r one; do
      [ -n "$one" ] || continue
      jig_has_line "$one" "$shares" || shares="$shares${shares:+
}$one"
    done <<EOF
$_TASK_ADD_SHARES
EOF
    _task_rewrite_state "$dir" share "$(printf '%s' "$shares" | tr '\n' ',')"
  fi
  jig_bootstrap_worktree "$1" "$2" "$3" "$id" "$shares"
  # No command ran — the project has none now — so an outcome left from one
  # that had failed describes nothing any more and goes.
  if [ -n "$_JIG_SETUP_OUTCOME" ]; then
    _task_rewrite_state "$dir" setup "$_JIG_SETUP_OUTCOME"
  elif [ -n "$(task_state_get "$id" setup)" ]; then
    _task_rewrite_state_remove "$dir" setup
  fi
}

# _task_share_arg <verb> <dir> — <dir> as a task's `share` keeps it: no
# trailing slash. Refuses what cannot be one entry of a comma-separated state
# value or a directory of this checkout; the bootstrap checks the rest — that
# git ignores it, that it is not `.ai/` — as it does for `worktree.share`.
_task_share_arg() {
  local verb="$1" dir="$2"
  while :; do
    case "$dir" in
      ?*/) dir=${dir%/} ;;
      *) break ;;
    esac
  done
  case "$dir" in
    '' | /* | *,* | *[[:space:]]* | .. | ../* | */../* | */.. | . | ./*)
      printf '%s: --share takes a directory of this checkout, relative and without commas or blanks: %s\n' "$verb" "$2" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$dir"
}

# task_bootstrap <id> — carry the declared state into the task's existing
# worktree again.
#
# It exists because the carry is deliberately the last and least important
# step of `task start --worktree`: when it fails halfway — no disk left, a
# path declared wrong — the worktree and the branch are fine and must not be
# rolled back, but a second `task start` refuses on the path that now exists.
# Without this verb the only repair is by hand, which is the cleanup by manual
# discipline RULES.md rejects (adr-20260924-a-worktree-carries-what-git-does-not).
#
# Idempotent by construction: it carries only what the worktree does not have,
# the same rule `task start` uses, so running it twice changes nothing.
#
# It works from either side. Run in the owning checkout, git says where the
# task's branch is checked out; run inside the task's own worktree, the
# borrowed workspace link says which checkout owns it.
task_bootstrap() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage bootstrap)"
  local id="$1" dir branch tree owner workspace share
  shift
  _TASK_ADD_SHARES=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --share)
        [ $# -ge 2 ] || jig_die "task bootstrap: --share needs a directory"
        share=$(_task_share_arg "task bootstrap" "$2") || exit 1
        _TASK_ADD_SHARES="$_TASK_ADD_SHARES$share
"
        shift 2
        ;;
      *) jig_die "task bootstrap: unknown argument: $1" ;;
    esac
  done

  dir=$(task_dir "$id")
  _task_guard_write "$id" "task bootstrap"
  branch=$(task_state_get "$id" branch)
  [ -n "$branch" ] || jig_die "task bootstrap: $id has not been started yet"

  if workspace=$(_task_borrowed_workspace "$id"); then
    tree=$(cd -P "$JIG_PROJECT" && pwd -P) \
      || jig_die "task bootstrap: cannot resolve this checkout"
    owner=${workspace%"/$JIG_AI_DIR/workspace/tasks/$id"}
  else
    owner=$(cd -P "$JIG_PROJECT" && pwd -P) \
      || jig_die "task bootstrap: cannot resolve this checkout"
    tree=$(_task_worktree_for "$branch" "$(_task_worktrees)")
    [ -n "$tree" ] || jig_die "task bootstrap: $id has no worktree of its own"
  fi
  [ -d "$owner" ] || jig_die "task bootstrap: cannot find the checkout that owns $id"
  [ "$owner" != "$tree" ] || jig_die "task bootstrap: $id is not in a worktree of its own"

  _task_carry_into "$owner" "$tree" "task bootstrap" "$id"
}

# _task_base_hint <id> <base> — a task cut from anything but the project's base
# says where its pull request goes, at the moment nobody has opened it yet.
# A pull request into the default branch would read, to housekeeping, as work
# in the wrong place (wrong-base), long after it could have been prevented.
_task_base_hint() {
  [ "$2" != "$(cfg git.base_branch main)" ] || return 0
  jig_info "task start: $1 is cut from $2; open its pull request into $2"
}

# _task_paused_hint <id> <where> — starting is not resuming (a task can be
# both unstarted and paused), so a paused task stays paused; say how to go on.
_task_paused_hint() {
  [ "$(task_state_get "$1" paused)" = "true" ] || return 0
  jig_info "task start: $1 is paused; run \`jig task resume $1\`$2 to make it current"
}

# _task_start_base <id> — the base a task being started is cut from, after
# refreshing it from origin (ADR-0040).
#
# A task linked to a spec whose roadmap declares an open epic is cut from the
# epic; every other task from `git.base_branch`. Each way a phase could end up
# on `main` without anyone noticing is refused instead of falling back: a spec
# this checkout does not have, an epic branch that exists nowhere, an epic
# already finished. The fetch runs for every task: a stale local `main` cuts a
# stale branch just as surely as a missing epic does.
_task_start_base() {
  local id="$1" default base spec rc=0
  default=$(cfg git.base_branch main)
  base=$default
  jig_task_epic "$(task_dir "$id")/task.md" || rc=$?
  # shellcheck disable=SC2153 # set by jig_task_epic (common.sh)
  spec=$_JIG_TASK_SPEC
  [ "$rc" -ne 2 ] || jig_die "task start: $id links to more than one spec; keep one Spec: line"
  [ "$rc" -ne 3 ] \
    || jig_die "task start: $id links to spec $spec, which this checkout does not have; switch to a branch that has it"
  [ "$rc" -ne 4 ] || jig_die "task start: spec $spec declares more than one epic; keep one Epic: line"
  if [ -n "$_JIG_TASK_EPIC" ]; then
    base=$_JIG_TASK_EPIC
    [ "$_JIG_TASK_EPIC_STATE" = open ] \
      || jig_die "task start: spec $spec marks epic $base finished; drop \"— finished\" from its Epic: line to cut tasks from it, or link the task to another spec"
  fi
  git check-ref-format --branch "$base" >/dev/null 2>&1 \
    || jig_die "task start: git rejects the base branch name: $base"

  if [ "$base" = "$default" ]; then
    jig_fetch_branches "task start" "$default"
    [ -z "$spec" ] || _task_start_note_no_epic "$spec" "$default"
  else
    jig_fetch_branches "task start" "$default" "$base"
    [ -n "$(jig_base_ref "$base")" ] \
      || jig_die "task start: epic $base of spec $spec exists neither here nor on origin; push it, or create it with \`jig spec epic $spec\`"
  fi
  printf '%s\n' "$base"
}

# _task_start_note_no_epic <spec> <default> — a note, never a refusal, when a
# task of a spec with no Epic: line is started while nothing of that spec has
# merged yet: the last moment an epic can still hold the whole feature
# (jig-idea §8 asks the person; this is the deterministic backstop for a spec
# where the question was skipped). "Nothing merged" is read without spec.sh,
# which task.sh never sources (ARCHITECTURE.md): no checked item in the
# roadmap (schemas/spec.md), and no task linked to the spec closed here
# (ADR-0030 closes a task only after its change landed). A task merged but not
# yet closed is missed, and costs one needless note. On stderr: the caller's
# stdout is the base branch.
_task_start_note_no_epic() {
  local spec="$1" default="$2" roadmap state dir link
  roadmap="$JIG_PROJECT/$JIG_AI_DIR/specs/$spec/roadmap.md"
  ! grep -Eq '^[[:space:]]*[-*][[:space:]]+\[[xX]\]' "$roadmap" 2>/dev/null || return 0
  for state in "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"/*/state; do
    [ -f "$state" ] || continue
    [ "$(sed -n 's/^status:[[:space:]]*//p' "$state" | head -n 1)" = consolidated ] || continue
    dir=${state%/state}
    link=$(jig_spec_link "$dir/task.md" 2>/dev/null) || continue
    [ "$link" != "$spec" ] || return 0
  done
  jig_info "task start: spec $spec has no epic; its tasks will merge into $default"
}

# _task_start_branch <name> <base> — create <name> off the freshest <base>,
# check it out here, and print the commit it starts from.
#
# Cut from the commit, not the ref: a branch started from origin/<base> would
# otherwise get origin/<base> as its upstream, and `git status` would report
# the task as "ahead of origin/main" — a branch that is never pushed there.
_task_start_branch() {
  local name="$1" base="$2" start commit
  start=$(jig_fresh_base_ref "$base" "task start") || exit 1
  commit=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$start^{commit}" 2>/dev/null) || return 1
  git -C "$JIG_PROJECT" checkout -q -b "$name" "$commit" >/dev/null 2>&1 || return 1
  printf '%s\n' "$commit"
}

# _task_undo_worktree_start <branch> <path> <commit> — take back what a failed
# `task start --worktree` made, so that running it again can succeed rather
# than hitting "branch already exists" forever. `git worktree add -b` creates
# the branch before the directory, so a failure can leave either behind.
#
# Only what this very call created is removed, and without force. The path
# did not exist before (checked), and a fresh checkout has nothing to lose, so
# `git worktree remove` needs no --force; if it refuses, the worktree stays.
# The branch is deleted with `update-ref -d <ref> <commit>`, which deletes only
# while it still points at the commit it was cut at — a branch anyone has
# committed to since is never touched — and only when no worktree has it
# checked out.
_task_undo_worktree_start() {
  local branch="$1" path="$2" commit="$3"
  git -C "$JIG_PROJECT" worktree remove "$path" >/dev/null 2>&1 || true
  git -C "$JIG_PROJECT" worktree prune >/dev/null 2>&1 || true
  if [ -z "$(_task_worktree_for "$branch" "$(_task_worktrees)")" ]; then
    git -C "$JIG_PROJECT" update-ref -d "refs/heads/$branch" "$commit" >/dev/null 2>&1 || true
  fi
}

# `jig task set <id> status consolidated` — the close — takes `--revision <n>`
# and `--json` as `task resume` does (fapost-lab/jig#365): the write is checked
# against the revision the caller read, and the answer is the closed task as
# `task list --json` lists it, or an error.code. They are the close's alone:
# on any other key they are refused as `usage`, never ignored, since a program
# that sent a revision with a write that does not check it would believe it
# had been protected. `--json` anywhere runs the whole command as the producer
# of json_run (conventions/json-output.md).
task_set() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_set_body 1 "$@"
      return
    fi
  done
  _task_set_body 0 "$@"
}

# _task_set_body <as_json> <id> <key> <value> [--reason <text>] [--revision <n>]
# [--json] — the body of `task set`; with <as_json> 1 it runs inside json_run
# and prints the closed task as data.
_task_set_body() {
  local as_json="$1" arg args=()
  shift
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  [ $# -ge 3 ] || jig_fail usage "$(_task_usage set)"
  jig_require_init
  local id="$1" key="$2" value="$3" dir reason="" has_reason=0 rev="" rev_given=0
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_fail usage "$(_task_usage set)"
        reason="$2"; has_reason=1; shift 2 ;;
      --revision)
        [ $# -ge 2 ] || jig_fail usage "task set: --revision requires a value"
        rev="$2"; rev_given=1; shift 2 ;;
      *) jig_fail usage "task set: unknown argument: $1" ;;
    esac
  done
  if [ "$has_reason" -eq 1 ]; then
    [ "$key" = class ] || jig_fail usage "task set: --reason is only for lowering a class"
    [ -n "$reason" ] || jig_fail usage "task set: --reason must not be empty"
    _task_finding_valid_field "$reason" || jig_fail usage "task set: --reason must be a single line with no tab"
  fi
  local claim=0 refusal
  if [ "$rev_given" -eq 1 ] || [ "$as_json" -eq 1 ]; then
    [ "$key:$value" = status:consolidated ] \
      || jig_fail usage "task set: --revision and --json are only for closing a task: jig task set $id status consolidated"
    [ "$rev_given" -eq 0 ] || [ -n "$rev" ] || jig_fail usage "task set: --revision is empty"
    [ -z "$rev" ] || jig_revision_valid "$rev" || jig_fail usage "task set: --revision is not a revision: $rev"
    claim=1
  fi
  _task_valid_id "$id" || jig_fail usage "invalid task id: $id"
  # The revision this write is checked against: the caller's, or the one read
  # here before the task is, so the state read below is never newer than it.
  local expected=""
  if [ "$claim" -eq 1 ]; then
    if [ -n "$rev" ]; then expected=$rev; else expected=$(jig_revision_read); fi
  fi
  dir=$(task_dir "$id")
  if [ "$claim" -eq 1 ] && [ ! -f "$dir/state" ]; then
    jig_fail not-found "task set: unknown task: $id"
  fi
  _task_guard_write "$id" "task set"

  case "$key" in
    class) _task_valid_class "$value" || jig_die "task set: invalid class: $value" ;;
    status)
      _task_valid_status "$value" || jig_die "task set: invalid status: $value"
      # `archived` has a command of its own, which records when, why and what
      # it was; a status written by hand would leave unarchive nothing to
      # return to, and an archived task changes status only by unarchive.
      [ "$value" != archived ] || jig_die "task set: a task is archived by jig task archive $id"
      refusal=$(_task_archived_refusal "$id")
      [ -z "$refusal" ] || jig_die "task set: $refusal"
      # A spec-linked task is abandoned by its own command, which records why
      # and closes the roadmap item that names it
      # (adr-20261029-an-abandoned-task-says-why-and-its-roadmap-item-follows);
      # writing the status by hand would leave the roadmap saying the work is
      # still here.
      if [ "$value" = abandoned ] \
         && [ "$(task_state_get "$id" status)" != abandoned ] \
         && [ -n "$(_task_spec_id "$id")" ]; then
        jig_die "task set: $id is linked to a spec; abandon it with jig task abandon $id --reason <text>"
      fi
      ;;
    knowledge_consolidated) _task_valid_bool "$value" || jig_die "task set: invalid knowledge_consolidated: $value" ;;
    domains) _task_valid_domains "$value" || jig_die "task set: invalid domains: $value" ;;
    route_depth) _cfg_route_depth "$value" || jig_die "task set: invalid route_depth: $value (full or lean)" ;;
    # The commit of the base a release's notes were checked up to; `task ship`
    # writes it into the commit as a Release-Notes-Through: trailer, and a
    # release is refused while the base has commits after it
    # (adr-20261112-release-notes-name-the-commit-they-describe). Kept as the
    # full sha, so a short one that later grows ambiguous still means the same.
    notes_through)
      local full_sha
      full_sha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$value^{commit}" 2>/dev/null) \
        || jig_die "task set: notes_through is not a commit here: $value; fetch the base and name its commit"
      value=$full_sha ;;
    executor_implement_runtime | executor_review_runtime | executor_implement_model | executor_review_model)
      [ -z "$(task_state_get "$id" branch)" ] \
        || jig_die "task set: executor choice is fixed when $id starts; stop this task and file a new one to change the stage executor"
      if [ "$value" != inherit ]; then
        local config_key problem
        config_key="executor.${key#executor_}"
        problem=$(jig_config_value_problem "$config_key" "$value") \
          || jig_die "task set: invalid $key: $problem"
      fi
      ;;
    task_id | issue | branch | base_commit | base_branch | created_at | updated_at | paused | paused_at | paused_reason | paused_stash | paused_stash_applied \
      | autopilot | autopilot_repairs | autopilot_mode | autopilot_phase | autopilot_handover | autopilot_answered | gate | gate_design | gate_by | pr_url | pr_into | promote_url | park_resumed_at \
      | archived_at | archived_reason | archived_from \
      | abandoned_at | abandoned_reason | moved_to | triage_task | triage_of \
      | absorbed_into | absorbs | partly_in | absorbs_partly \
      | route_evidence | class_lowered_from | class_lowered_reason | out_of_order_over | out_of_order_reason | share | setup \
      | executor_implement_runtime_source | executor_review_runtime_source \
      | executor_implement_model_source | executor_review_model_source)
      jig_die "task set: key is not writable: $key" ;;
    *) jig_die "task set: unknown key: $key" ;;
  esac

  # ADR-0030: a task closes only after the knowledge decision is recorded.
  # Without this order check, `status consolidated` could be written by hand
  # ahead of `knowledge_consolidated`, which is exactly how a task ended up
  # closed with no recorded knowledge decision. Idempotent: re-setting
  # `status consolidated` on an already-consolidated task still succeeds,
  # since its flag is already true by then.
  #
  # And a merge alone never closes a task (AGENTS.md), nor does closing stand
  # in for one: _task_close_refusal asks the forge about the pull request now.
  if [ "$key" = status ] && [ "$value" = consolidated ]; then
    # What the close would adopt in place of a closed `pr_url` is decided here,
    # in this shell, and written nothing: the refusal below judges it, and the
    # one write that closes the task carries it (_task_close_write).
    _task_close_adopt_v "$id"
    refusal=$(_task_close_refusal "$id" forge) || exit 1
    [ -z "$refusal" ] || jig_fail not-closable "$refusal"
  fi
  if [ "$key" = knowledge_consolidated ] && [ "$value" = false ] && [ "$(task_state_get "$id" status)" = consolidated ]; then
    jig_die "task set: knowledge_consolidated cannot be false on a consolidated task: $id"
  fi

  # Completion stops here (design §4): `status ready` is verify's own
  # sign-off, and `knowledge_consolidated true` is consolidation's. A P0/P1
  # finding still open, or fixed but not re-reviewed, refuses both.
  local gate=0
  case "$key:$value" in
    status:ready) gate=1 ;;
    knowledge_consolidated:true) gate=1 ;;
    # A bare triage task's close records its knowledge decision (below), so
    # it passes the same gates as recording it would.
    status:consolidated)
      if _task_is_bare_triage "$id" && [ "$(task_state_get "$id" knowledge_consolidated)" != true ]; then
        gate=1
      fi ;;
  esac
  if [ "$gate" -eq 1 ]; then
    local blocking
    blocking=$(_task_blocking_findings "$id")
    [ -z "$blocking" ] || jig_die "task set: $(_task_gate_blocking_message "$id" "$blocking")"
    # review-receipt (design.md §3): a receipt that no longer matches what was
    # reviewed, or a T4 task with none at all, refuses the same way. Checked
    # after the findings gate, same order as the two ledger checks above.
    local receipt_msg
    receipt_msg=$(_task_receipt_gate_message "$id")
    [ -z "$receipt_msg" ] || jig_die "task set: $receipt_msg"
    # The stages the route requires, each by its record
    # (adr-20261004-a-route-stage-is-proven-by-its-record): `ready` is verify's
    # sign-off, so it asks for what comes before verify; the knowledge
    # decision is consolidation's, so it asks for verify too.
    if [ "$key" = status ]; then
      _task_route_evidence_gate "$id" ready "task set"
    else
      _task_route_evidence_gate "$id" consolidate "task set"
    fi
    # The project's own scripts come last, once every check of Jig's has
    # passed, and before anything is written. A bare triage close records the
    # knowledge decision, so it passes consolidation's hooks.
    if [ "$key:$value" = status:ready ]; then
      _task_gate_hooks "$id" ready "task set"
    else
      _task_gate_hooks "$id" consolidate "task set"
    fi
  fi

  if [ "$key" = class ]; then
    _task_set_class "$id" "$dir" "$value" "$has_reason" "$reason"
    return 0
  fi
  [ "$has_reason" -eq 0 ] || jig_die "task set: --reason is only for lowering a class"

  if [ "$claim" -eq 1 ]; then
    _task_close_write "$id" "$dir" "$expected"
    _task_close_adopt_say "$id" "$as_json"
    _task_queue_prune "$id" "task set"
    if [ "$as_json" -eq 1 ]; then
      printf '{"task":%s}\n' "$(_task_json_one "$id")"
    fi
    return 0
  fi

  local was=""
  [ "$key" != status ] || was=$(task_state_get "$id" status)
  # A close that adopts a merged replacement of the recorded pull request is
  # one file, built whole: the new address, where it went and the status.
  if [ "$key:$value" = status:consolidated ] && [ -n "$_TASK_ADOPT_URL" ]; then
    local atmp="$dir/state.tmp.$$"
    _task_guard_dir "$dir"
    _task_close_build "$id" "$dir" "$atmp"
    mv "$atmp" "$dir/state"
    jig_task_state_forget
    jig_record_changed
    _task_close_adopt_say "$id" "$as_json"
    _task_queue_prune "$id" "task set"
    return 0
  fi
  # A bare triage task closes in one command: it carries no change whose
  # intent could be lost, so its knowledge decision is recorded with the close
  # and `consolidated` still implies `knowledge_consolidated: true` (ADR-0030)
  # for every reader (adr-20261029-a-ship-hands-open-findings-to-one-triage-task).
  if [ "$key:$value" = status:consolidated ] && _task_is_bare_triage "$id" \
     && [ "$(task_state_get "$id" knowledge_consolidated)" != true ]; then
    _task_rewrite_state "$dir" knowledge_consolidated true
  fi
  if [ "$value" = inherit ]; then
    _task_rewrite_state_remove "$dir" "$key"
  else
    _task_rewrite_state "$dir" "$key" "$value"
  fi
  if [ "$was" = abandoned ] && [ "$value" != abandoned ]; then
    _task_abandon_keys_clear "$id" "$dir"
  fi
  if [ "$key" = status ]; then
    case "$value" in
      consolidated | abandoned) _task_queue_prune "$id" "task set" ;;
      *) [ "$was" != abandoned ] || _task_not_queued_hint "$id" ;;
    esac
  fi
}

# _task_not_queued_hint <id> — the reminder `task new` gives, for a task that
# is live and not in the queue: a task taken back from abandoned or archived
# left its place when it finished (adr-20261107-a-finished-task-leaves-the-queue).
_task_not_queued_hint() {
  jig_queue_place "$1" && return 0
  jig_info "not queued: $1 — jig queue set $1 --priority <0-5>; the scale is in the jig-task skill"
}

# _task_claim_or_refuse <who> <expected> [<tmp-file>…] — claim the clone revision above
# <expected> (jig_revision_claim) for a write that built its new state aside, or refuse and
# take that state away: `stale-revision` when the clone changed since <expected>, a plain
# failure when the claim cannot be made at all. It runs in the caller's shell, so the
# refusal ends the command and not a subshell. The one copy of what every state write of
# this file does between building the file and moving it into place.
_task_claim_or_refuse() {
  local who="$1" expected="$2" rc=0
  shift 2
  jig_revision_claim "$expected" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      rm -f "$@"
      jig_fail stale-revision "$who: the clone changed since revision $expected; read again and retry" ;;
    *)
      rm -f "$@"
      jig_die "$who: cannot claim the clone revision in $(jig_revision_dir)" ;;
  esac
}

# _task_close_write <id> <dir> <expected> — the close of a write checked
# against a revision: the new state built whole (the knowledge decision of a
# bare triage task with it, as the unchecked close records it), the revision
# claimed, and only then the file moved into place — one write under one
# claim, as `task resume` lands its own. A claim that does not stand writes
# nothing and refuses with `stale-revision`.
_task_close_write() {
  local id="$1" dir="$2" expected="$3" claimed="${4:-}" tmp
  tmp="$dir/state.tmp.$$"
  _task_guard_dir "$dir"
  _task_close_build "$id" "$dir" "$tmp"
  # <claimed> says the caller holds the claim already (`task merge-pr`, which
  # claims before it merges and closes under that one claim).
  [ -n "$claimed" ] || _task_claim_or_refuse "task set" "$expected" "$tmp"
  mv "$tmp" "$dir/state"
  jig_task_state_forget
  jig_record_changed
}

# _task_close_build <id> <dir> <dst> — the state of the closed task built whole
# into <dst>, nothing moved into place: the knowledge decision of a bare
# triage task, the pull request a close adopted (_task_close_adopt_v) with
# where it went, and `status: consolidated`, as one file for one claim. A task
# that was abandoned loses its abandoned_at, abandoned_reason and moved_to in
# the same file, as the plain close removes them (_task_abandon_keys_clear), so
# no consolidated state carries them; the reminder that clearing prints for a
# task live again is left to that path.
_task_close_build() {
  local id="$1" dir="$2" dst="$3" src="$2/state" n=0 next steps drop=0
  local -a kv=()
  jig_cleanup_add "$dst"
  if _task_is_bare_triage "$id" && [ "$(task_state_get "$id" knowledge_consolidated)" != true ]; then
    kv+=(knowledge_consolidated true)
  fi
  if [ -n "$_TASK_ADOPT_URL" ]; then
    kv+=(pr_url "$_TASK_ADOPT_URL" pr_into "$_TASK_ADOPT_INTO")
  fi
  kv+=(status consolidated)
  [ "$(task_state_get "$id" status)" != abandoned ] || drop=1
  steps=$(( ${#kv[@]} / 2 + drop ))
  local i=0
  while [ "$i" -lt "${#kv[@]}" ]; do
    n=$((n + 1))
    # The last step writes <dst> itself: this function moves nothing into
    # place, its caller does, under its claim.
    if [ "$n" -lt "$steps" ]; then
      next="$dst.step$n"
    else
      next=$dst
    fi
    _task_state_set_into "$src" "$next" "${kv[$i]}" "${kv[$((i + 1))]}"
    [ "$src" = "$dir/state" ] || rm -f "$src"
    src=$next
    i=$((i + 2))
  done
  if [ "$drop" -eq 1 ]; then
    _task_state_without_into "$src" "$dst" abandoned_at abandoned_reason moved_to
    [ "$src" = "$dir/state" ] || rm -f "$src"
  fi
}

# The pull request a close adopts in place of the recorded one, as
# _task_close_adopt_v decided it: its address, the branch it went into and the
# recorded address it replaces. Empty when nothing is adopted.
_TASK_ADOPT_URL=""
_TASK_ADOPT_INTO=""
_TASK_ADOPT_FROM=""

# _task_branch_pr_rows <branch> <open|merged> — one row per pull request of
# the forge from <branch>, newest first: `<target><TAB><url><TAB><merged_at>`
# (merged_at empty when the forge does not say, or for an open one). Returns 1
# with nothing printed when there is no forge or it could not be asked, so a
# caller can tell "none" from "could not say". The one place `task ship` and
# the close ask the forge for the pull requests of a branch.
_task_branch_pr_rows() {
  local branch="$1" state="$2" kind out="" line
  kind=$(jig_forge_kind 2>/dev/null) || return 1
  case "$kind" in
    github)
      jig_gh_resolve || return 1
      out=$(jig_net jig_gh pr list --head "$branch" --state "$state" --json url,baseRefName,mergedAt \
        --jq '.[] | [.baseRefName, .url, .mergedAt] | join("\t")' 2>/dev/null) || return 1 ;;
    gitlab)
      local merged=""
      [ "$state" != merged ] || merged=--merged
      out=$(jig_net glab mr list --source-branch "$branch" ${merged:+"$merged"} --output json 2>/dev/null) || return 1
      # The merge request's own web_url, not its author's, which comes first.
      out=$(printf '%s\n' "$out" | jig_glab_fields target_branch web_url@/merge_requests/ merged_at) || return 1 ;;
    *) return 1 ;;
  esac
  while IFS= read -r line; do
    line=${line%$'\r'}
    [ -z "$line" ] || printf '%s\n' "$line"
  done <<ROWS
$out
ROWS
  return 0
}

# _task_pr_created_v <var> <url> — when the pull request <url> was opened, as
# the forge says it (empty when it cannot).
_task_pr_created_v() {
  local __tpc_kind __tpc_out="" __tpc_iid
  __tpc_kind=$(jig_forge_kind 2>/dev/null) || __tpc_kind=""
  case "$__tpc_kind" in
    github)
      jig_gh_resolve || __tpc_kind=""
      [ -z "$__tpc_kind" ] || __tpc_out=$(jig_net jig_gh pr view "$2" --json createdAt --jq .createdAt 2>/dev/null) || __tpc_out="" ;;
    gitlab)
      __tpc_iid=$(_jig_ship_glab_mr "$2")
      if [ -n "$__tpc_iid" ]; then
        __tpc_out=$(jig_net glab mr view "$__tpc_iid" --output json 2>/dev/null | jig_glab_fields created_at) || __tpc_out=""
      fi ;;
  esac
  __tpc_out=${__tpc_out%$'\r'}
  printf -v "$1" '%s' "$__tpc_out"
}

# _task_close_adopt_v <id> — decide, before the close asks the forge about
# `pr_url`, whether another pull request stands in for it, and write nothing.
# The case: the recorded pull request is `closed` unmerged, and another from
# the task's branch was merged into the base (or the staging branch) after the
# recorded one was opened — a person opened it by hand and closed the one
# `task ship` made. Sets _TASK_ADOPT_URL, _TASK_ADOPT_INTO and
# _TASK_ADOPT_FROM; _task_close_refusal judges the adopted address like any
# recorded one (only `merged` lets a close through) and _task_close_write
# records it with the close. Anything else — not closed, unknown, a forge that
# does not answer, no such pull request, a time that is missing — leaves them
# empty. Runs in the caller's shell, not `$(...)`, so the globals reach the
# refusal and the write.
_task_close_adopt_v() {
  local id="$1" pr branch base staging="" flow kind rows st="" why="" created
  local target url merged_at found_url="" found_into="" t=$'\t'
  _TASK_ADOPT_URL=""
  _TASK_ADOPT_INTO=""
  _TASK_ADOPT_FROM=""
  task_state_var pr "$id" pr_url
  task_state_var branch "$id" branch
  [ -n "$pr" ] && [ -n "$branch" ] || return 0
  kind=$(jig_forge_kind 2>/dev/null) || return 0
  case "$kind" in github | gitlab) ;; *) return 0 ;; esac
  jig_pr_state_v st why "$pr"
  [ "$st" = closed ] || return 0
  # As this clone's account, resolved here in this shell, where the memo
  # survives: _task_branch_pr_rows runs under $(...) and could not keep it.
  [ "$kind" != github ] || jig_gh_resolve || return 0
  rows=$(_task_branch_pr_rows "$branch" merged) || return 0
  _task_pr_created_v created "$pr"
  [ -n "$created" ] || return 0
  jig_task_base_v base "$id"
  cfg_v flow git.flow direct
  if [ "$flow" = staging ]; then
    staging=$(jig_staging_in_use) || staging=""
  fi
  while IFS="$t" read -r target url merged_at; do
    [ -n "$target" ] && [ -n "$url" ] && [ -n "$merged_at" ] || continue
    if [ "$target" = "$base" ] || { [ -n "$staging" ] && [ "$target" = "$staging" ]; }; then
      # Merged after the recorded one was opened (UTC, to the second): one
      # merged before it is an earlier shipment of the branch, not its stand-in.
      [ "${merged_at:0:19}" \> "${created:0:19}" ] || continue
      found_url=$url
      found_into=$target
      break
    fi
  done <<ROWS
$rows
ROWS
  [ -n "$found_url" ] && [ "$found_url" != "$pr" ] || return 0
  _TASK_ADOPT_URL=$found_url
  _TASK_ADOPT_INTO=$found_into
  _TASK_ADOPT_FROM=$pr
  return 0
}

# _task_close_adopt_say <id> <as-json> — the one line that says what the close
# recorded in place of the closed pull request, after it was written (stderr
# under --json, whose stdout is the envelope). Nothing when nothing was adopted.
_task_close_adopt_say() {
  local id="$1" as_json="$2" msg
  [ -n "$_TASK_ADOPT_URL" ] || return 0
  msg="task set: $id: $_TASK_ADOPT_FROM was closed unmerged; $_TASK_ADOPT_URL from the same branch, merged into $_TASK_ADOPT_INTO, is recorded in its place"
  if [ "$as_json" = 1 ]; then printf '%s\n' "$msg" >&2; else printf '%s\n' "$msg"; fi
}

# _task_close_refusal <id> <pr-state> [<base-state>] — why `jig task set <id> status
# consolidated` refuses this task, or nothing when it would close it.
# <pr-state> is `forge` for the command, which asks the forge now
# (jig_pr_state), or the state a reader already holds — the forge cache's, for
# the actions table (_task_actions), which never asks the forge. A cache's
# `merged` cannot be contradicted by the forge, since a merge is final; a cache
# behind the forge can only withhold a close the command would allow.
#
# A closed unmerged `pr_url` is first replaced, by the command, with a pull
# request from the same branch that was merged into the base or the staging
# branch (_task_close_adopt_v).
#
# A merge alone never closes a task (AGENTS.md), and neither does the
# reverse: closing a task never stands in for a merge that has not happened.
# Silent when no pull request was ever opened (pr_url unset — agent.git
# below pr, or the work never left this branch); once one was, `merged` is
# the only answer that lets `consolidated` through, asked of the forge now,
# never assumed from what wrote the request (autopilot-end-closes-unmerged-task).
#
# On the staging flow the pull request `pr_url` names goes into the staging
# branch, and the base is reached only by the promotion, so a merged pull
# request is not the whole answer there: once it passes, the close waits for
# the fact housekeeping's needs-consolidation rests on, that the task's work is
# in the base (_task_close_staging_refusal). <base-state> is the state of a
# pull request from the task's branch into its base that the table's reader
# holds (the forge cache's: the promotion, when it squashed); the command
# passes none and reads the forge cache itself.
#
# The `pr_url` check is forge-only, deliberately (the staging check above
# reads git and the forge cache too): housekeeping's own remote-state tier falls back
# from the forge to git ancestry/patch-id when the forge cannot answer
# (ADR-0005), because a background sweep can afford to keep looking. This
# gate cannot — it must answer now, synchronously, in the same call the
# human or the route is waiting on — so a forge that cannot be reached
# reads as `unknown` and refuses here, even on a run where housekeeping's
# ancestry check would have called the same pull request merged. That is
# the safe side to be wrong on: closing early cannot be taken back for
# free, and the refusal is retried by re-running this same command, not by
# `jig housekeeping`, which never feeds that check.
# When the forge could not be asked, the refusal names why (jig_pr_state_v)
# and says the pull request may already be merged: "unknown" alone reads as a
# verdict on the pull request, when it is only the forge that did not answer.
_task_close_refusal() {
  local id="$1" pr_state="$2" base_state="${3:-}" pr kc st why="" mode=cache
  task_state_var kc "$id" knowledge_consolidated
  # A bare triage task's close records its knowledge decision too (task_set).
  if [ "$kc" != "true" ] && ! _task_is_bare_triage "$id"; then
    printf 'task set: status consolidated requires knowledge_consolidated true; record the knowledge decision first: jig task set %s knowledge_consolidated true\n' "$id"
    return 0
  fi
  task_state_var pr "$id" pr_url
  [ "$pr_state" != forge ] || mode=forge
  # The command's close judges the pull request it would adopt, not the closed
  # one it replaces (_task_close_adopt_v); a reader holding a state never does.
  [ "$mode" != forge ] || [ -z "$_TASK_ADOPT_URL" ] || pr=$_TASK_ADOPT_URL
  if [ -n "$pr" ]; then
    if [ "$mode" = forge ]; then
      jig_pr_state_v pr_state why "$pr"
    fi
    [ -n "$pr_state" ] || pr_state=unknown
    if [ "$pr_state" = unknown ] && [ -n "$why" ]; then
      printf 'task set: status consolidated requires its pull request to be merged: %s is unknown, the forge could not be asked (%s); it may already be merged: run this same command again once the forge answers, and merge it first if it is not\n' "$pr" "$why"
      return 0
    elif [ "$pr_state" != merged ]; then
      printf 'task set: status consolidated requires its pull request to be merged: %s is %s; merge it, then run this again\n' "$pr" "$pr_state"
      return 0
    fi
  fi
  # A task already closed closes again (task_set's idempotence), even one an
  # older Jig closed before its work reached the base.
  task_state_var st "$id" status
  [ "$st" = consolidated ] || _task_close_staging_refusal "$id" "$mode" "$base_state"
  return 0
}

# _task_close_staging_refusal <id> <forge|cache> <base-state> — what
# _task_close_refusal adds on the staging flow: nothing when the task's work is
# in the base, else why its close waits. It applies to a task of the project's
# base, with a branch, that has a pull request, whose own work reached the
# staging branch, or whose branch on origin holds work the base lacks; any
# other task (direct flow, an epic's task, one that never
# reached staging, a bare triage or no-code task) closes as before.
# "In the base" is any of, cheapest first: <base-state> is `merged`; the
# promotion (`promote_url`) is merged; its branch is in the base by git (see
# below for how far each mode asks).
# <forge> asks the forge about the promotion now (jig_pr_state_v) and reads the
# forge cache for the base state; <cache> never asks it, as the table never does.
# Inside a listing the table asks git no question of its own: the base ref and
# which branches are in it were read once (_task_list_staging_read) and each
# row is a lookup in those lists, with the answers the commands below give.
_task_close_staging_refusal() {
  local id="$1" mode="$2" base_state="$3" staging branch base defbase pr promote
  local pstate="" pwhy="" st="" tip baseref="" cache line flag msg pushed="" into="" t=$'\t'
  local listing="" nl=$'\n'
  task_state_var branch "$id" branch
  [ -n "$branch" ] || return 0
  jig_task_base_v base "$id"
  cfg_v defbase git.base_branch main
  [ "$base" = "$defbase" ] || return 0
  if [ "$_TASK_LIST_STAGING_READ" = 1 ] && [ "$mode" = cache ]; then
    listing=1
    staging=$_TASK_LIST_STAGING_BRANCH
    [ -n "$staging" ] || return 0
  else
    cfg_v staging git.flow direct
    [ "$staging" = staging ] || return 0
    staging=$(jig_staging_in_use) || return 0
  fi
  # In scope only with a pull request, or own work on the staging branch.
  task_state_var pr "$id" pr_url
  # A pull request `task ship` recorded as going into the base itself
  # (`pr_into`, a ship at a level below the staging flow's) is the landing:
  # _task_close_refusal already found it merged.
  task_state_var into "$id" pr_into
  [ "$mode" != forge ] || [ -z "$_TASK_ADOPT_INTO" ] || into=$_TASK_ADOPT_INTO
  if [ -n "$pr" ] && [ -n "$into" ] && [ "$into" != "$staging" ]; then
    return 0
  fi
  if [ "$_TASK_LIST_STAGING_ON" = 1 ] && [ "$mode" = cache ]; then
    while IFS="$t" read -r line flag; do
      [ "$line" != "$id" ] || st=$flag
    done <<EOF
$_TASK_LIST_STAGING
EOF
  else
    st=$(jig_staging_states "$staging" "$id$t$branch$t$base")
    st=${st#*"$t"}
  fi
  case "$st" in on | behind) ;; *) st="" ;; esac
  # Or pushed with work of its own the base lacks, waiting for its landing:
  # under `git.staging_land: external` CI lands it with no pull request, and
  # until it has nothing else says it left the branch (decided by the
  # person, 2026-11-14).
  if [ -z "$pr" ] && [ -z "$st" ]; then
    if [ -n "$listing" ]; then
      baseref=$_TASK_LIST_BASE_REF
      [ -n "$baseref" ] || return 0
      # `rev-list base..origin/<branch>` is not empty exactly when the ref
      # exists and is not an ancestor of the base.
      case "$_TASK_LIST_REFS_UNMERGED" in
        *"$nl""refs/remotes/origin/$branch""$nl"*) ;;
        *) return 0 ;;
      esac
    else
      baseref=$(jig_base_ref "$base")
      [ -n "$baseref" ] || return 0
      [ -n "$(git -C "$JIG_PROJECT" rev-list -n 1 "$baseref..refs/remotes/origin/$branch" -- 2>/dev/null)" ] || return 0
    fi
    pushed=1
  fi
  if ! declare -F forgecache_entry_url >/dev/null; then
    # shellcheck source=lib/forgecache.sh
    . "$JIG_LIB/forgecache.sh"
  fi
  if [ "$mode" = forge ]; then
    cache=$(forgecache_read)
    forgecache_entry "$cache" "$branch" "$base"
    base_state=$_FORGECACHE_STATE
  else
    cache=$_TASK_LIST_FORGE_CACHE
  fi
  [ "$base_state" != merged ] || return 0
  task_state_var promote "$id" promote_url
  if [ -n "$promote" ]; then
    if [ "$mode" = forge ]; then
      jig_pr_state_v pstate pwhy "$promote"
    else
      forgecache_entry_url "$cache" "$promote"
      pstate=$_FORGECACHE_STATE
      # A promotion the cache has not heard of is not merged as far as the
      # table knows: the reason names it as open.
      [ -n "$pstate" ] || pstate=open
    fi
    [ "$pstate" != merged ] || return 0
  fi
  # Git last. The command asks every way housekeeping's ancestry tier does
  # (jig_branch_in_base: a merge, a squash, a rebase), whatever the staging
  # state, since a squash or rebase promotion leaves the task's own commits on
  # staging. The table asks only whether the tip is an ancestor, and only of a
  # task with no own work on staging: the squash check walks the base's new
  # commits, too much for every row. It may withhold a close the command
  # allows; the needs-consolidation flag of the last housekeeping run, passed
  # in as <base-state> `merged`, offers it then.
  if [ "$mode" = forge ] || [ -z "$st" ]; then
    tip=refs/heads/$branch
    if [ -n "$listing" ]; then
      baseref=$_TASK_LIST_BASE_REF
      # The tip is the local branch when it exists, else origin's; it is in the
      # base when it is among the branches the base holds.
      case "$_TASK_LIST_REFS_MERGED$_TASK_LIST_REFS_UNMERGED" in
        *"$nl$tip$nl"*) ;;
        *) tip=refs/remotes/origin/$branch ;;
      esac
      if [ -n "$baseref" ]; then
        case "$_TASK_LIST_REFS_MERGED" in
          *"$nl$tip$nl"*) return 0 ;;
        esac
      fi
    else
      git -C "$JIG_PROJECT" rev-parse --verify --quiet "$tip^{commit}" >/dev/null 2>&1 || tip=refs/remotes/origin/$branch
      [ -n "$baseref" ] || baseref=$(jig_base_ref "$base")
      if [ -n "$baseref" ]; then
        if [ "$mode" = forge ]; then
          ! jig_branch_in_base "$tip" "$baseref" || return 0
        elif git -C "$JIG_PROJECT" merge-base --is-ancestor "$tip" "$baseref" 2>/dev/null; then
          return 0
        fi
      fi
    fi
  fi
  msg="prepare for prod, then close it once the promotion merged"
  if [ -n "$promote" ]; then
    case "$pstate" in
      open | closed) msg="its promotion $promote is $pstate; close it once the promotion merged" ;;
      unknown)
        if [ -n "$pwhy" ]; then
          msg="whether its promotion $promote merged is unknown, the forge could not be asked ($pwhy); run this same command again once the forge answers"
        fi ;;
    esac
  fi
  if [ -n "$pushed" ] && [ -z "$promote" ]; then
    printf 'task set: %s is pushed and not in %s yet: once it lands on %s, prepare for prod, then close it once the promotion merged\n' "$id" "$base" "$staging"
    return 0
  fi
  printf 'task set: %s is on %s and not in %s yet: %s\n' "$id" "$staging" "$base" "$msg"
  return 0
}

# _task_run_unattended <id> — exit 0 when the task's own run was started
# unattended and has not ended (`on` or `stopped`). Checked on the recorded
# mode, so unsetting the key halfway through a run changes nothing about it.
_task_run_unattended() {
  local run mode
  task_state_var run "$1" autopilot
  case "$run" in
    on | stopped)
      _task_autopilot_mode_v mode "$1"
      [ "$mode" = unattended ] ;;
    *) return 1 ;;
  esac
}

# _task_nobody_answers <id> — exit 0 when no human answers for <id>: this
# clone sets `autopilot.unattended`, or the task's own run is unattended
# (_task_run_unattended).
_task_nobody_answers() {
  if jig_unattended; then return 0; fi
  _task_run_unattended "$1"
}

# _task_set_class <id> <dir> <class> <has-reason> <reason> — write the class.
# Re-classification is normal (ADR-0009), and lowering is the one direction
# that sheds stages, so it is the one that has to say why: refused without
# `--reason`, and recorded as `class_lowered_from` (the highest class the task
# was lowered from) and `class_lowered_reason`, which `jig task route`,
# `jig status` and the autopilot report show — a lowering is never quieter than
# the gate it may have skipped. Where nobody answers — `autopilot.unattended`
# set in this clone, or the task's unattended run on or stopped — a T3/T4 task
# is not lowered below T3: nobody there can read the reason before the gate is
# gone, and staying in the class is the cautious, reversible choice. Raising the class
# back to where it was lowered from clears the record
# (adr-20261004-a-route-stage-is-proven-by-its-record).
_task_set_class() {
  local id="$1" dir="$2" value="$3" has_reason="$4" reason="$5" old from
  old=$(task_state_get "$id" class)
  if _task_valid_class "$old" && [ "${value#T}" -lt "${old#T}" ]; then
    [ "$has_reason" -eq 1 ] \
      || jig_die "task set: lowering $id from $old to $value sheds stages of its route; say why: jig task set $id class $value --reason <text>"
    case "$old" in
      T3 | T4)
        if [ "${value#T}" -lt 3 ] && _task_nobody_answers "$id"; then
          jig_die "task set: an unattended run does not lower $id from $old below T3: nobody can read the reason before the gate is gone; stay in $old"
        fi ;;
    esac
    from=$(task_state_get "$id" class_lowered_from)
    if ! _task_valid_class "$from" || [ "${old#T}" -gt "${from#T}" ]; then
      from="$old"
    fi
    _task_rewrite_state "$dir" class "$value"
    _task_rewrite_state "$dir" class_lowered_from "$from"
    _task_rewrite_state "$dir" class_lowered_reason "$reason"
    if [ "$(task_state_get "$id" autopilot)" = on ]; then
      _task_autopilot_log "$id" lower "$old to $value: $reason"
    fi
    return 0
  fi
  [ "$has_reason" -eq 0 ] || jig_die "task set: --reason is only for lowering a class; $value is not lower than ${old:-unclassified}"
  _task_rewrite_state "$dir" class "$value"
  from=$(task_state_get "$id" class_lowered_from)
  if _task_valid_class "$from" && [ "${value#T}" -ge "${from#T}" ]; then
    _task_rewrite_state_remove "$dir" class_lowered_from
    _task_rewrite_state_remove "$dir" class_lowered_reason
  fi
}

# _task_archived_refusal <id> — why a task's status cannot be written because
# it is archived, or nothing: an archived task changes status only by
# `unarchive`. The one sentence `task set` and `task abandon` both refuse with,
# each under its own name.
_task_archived_refusal() {
  [ "$(task_state_get "$1" status)" != archived ] \
    || printf 'task %s is archived; run jig task unarchive %s first\n' "$1" "$1"
}

# task_abandon <id> [--reason <text>] [--moved-to <ref>] [--revision <n>]
# [--json] — give a task up, and say why where the next agent reads it
# (adr-20261029-an-abandoned-task-says-why-and-its-roadmap-item-follows). The
# reason, the day and the move's target go into `state`, as one new file under
# one revision claim (checked as `task pause`'s write is); a task linked to a
# spec must give a reason. The target is parsed by jig_task_ref, the one
# grammar of a reference, and never written to: when it is not there yet, the
# command that files it there is printed (`note` in the answer).
#
# The roadmap item that names a linked task is closed by `jig spec drop`, which
# the text form runs through the dispatcher as `spec remove` runs this command:
# task.sh does not source spec.sh. `--json` does not: it never touches a
# checkout or the roadmap, so the item waits, unchecked and visible, for
# `jig spec drop <id> --json`, the table's `drop-item`, which edits it in Jig's
# own tree. `--json` anywhere runs the whole command as the producer of
# json_run (conventions/json-output.md).
task_abandon() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_abandon_body 1 "$@"
      return
    fi
  done
  _task_abandon_body 0 "$@"
}

# _task_abandon_body <as_json> <id> [options] — the body of `task abandon`;
# with <as_json> 1 it runs inside json_run and prints the abandoned task as
# data, and runs no `spec drop`.
_task_abandon_body() {
  local as_json="$1" arg args=()
  shift
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ $# -ge 1 ] || jig_fail usage "$(_task_usage abandon)"
  local id="$1" reason="" has_reason=0 moved="" sid dir out rc=0 rev="" rev_given=0 expected was refusal
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_fail usage "task abandon: --reason requires a value"
        reason="$2"; has_reason=1; shift 2 ;;
      --moved-to)
        [ $# -ge 2 ] || jig_fail usage "task abandon: --moved-to requires a value"
        moved="$2"; shift 2 ;;
      --revision)
        [ $# -ge 2 ] || jig_fail usage "task abandon: --revision requires a value"
        rev="$2"; rev_given=1; shift 2 ;;
      *) jig_fail usage "task abandon: unknown argument: $1 ($(_task_usage abandon))" ;;
    esac
  done
  [ "$rev_given" -eq 0 ] || [ -n "$rev" ] || jig_fail usage "task abandon: --revision is empty"
  [ -z "$rev" ] || jig_revision_valid "$rev" || jig_fail usage "task abandon: --revision is not a revision: $rev"
  _task_valid_id "$id" || jig_fail usage "invalid task id: $id"
  # The revision this write is checked against: the caller's, or the one read
  # here before the task is, so the state read below is never newer than it.
  if [ -n "$rev" ]; then expected=$rev; else expected=$(jig_revision_read); fi
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_fail not-found "task abandon: unknown task: $id"
  if [ "$has_reason" -eq 1 ]; then
    [ -n "$reason" ] || jig_fail usage "task abandon: --reason must not be empty"
    _task_finding_valid_field "$reason" || jig_fail usage "task abandon: --reason must be a single line with no tab"
  fi
  if [ -n "$moved" ]; then
    jig_task_ref "$moved" || jig_fail usage "task abandon: --moved-to $moved: $_JIG_REF_ERROR"
  fi
  sid=$(_task_spec_id "$id")
  if [ -n "$sid" ] && [ "$has_reason" -eq 0 ]; then
    jig_fail usage "task abandon: $id is linked to spec $sid; say why: jig task abandon $id --reason <text> [--moved-to <repo>#<task-id>]"
  fi
  # The refusals of a status write that concern this one (`task set` asks the
  # same); the one for a task linked to a spec is for a status written by
  # hand, and is the reason's check above.
  _task_guard_write "$id" "task abandon"
  refusal=$(_task_archived_refusal "$id")
  [ -z "$refusal" ] || jig_fail wrong-status "task abandon: $refusal"
  was=$(task_state_get "$id" status)

  # The new state, whole, before the claim: a refused claim leaves nothing.
  local tmp="$dir/state.tmp.$$" tmp2="$dir/state.tmp2.$$"
  jig_cleanup_add "$tmp"
  jig_cleanup_add "$tmp2"
  _task_state_set_into "$dir/state" "$tmp" status abandoned
  _task_state_set_into "$tmp" "$tmp2" abandoned_at "$(jig_today)"
  mv "$tmp2" "$tmp"
  if [ "$has_reason" -eq 1 ]; then
    _task_state_set_into "$tmp" "$tmp2" abandoned_reason "$reason"
  else
    _task_state_without_into "$tmp" "$tmp2" abandoned_reason
  fi
  mv "$tmp2" "$tmp"
  if [ -n "$moved" ]; then
    _task_state_set_into "$tmp" "$tmp2" moved_to "$moved"
  else
    _task_state_without_into "$tmp" "$tmp2" moved_to
  fi
  mv "$tmp2" "$tmp"
  _task_claim_or_refuse "task abandon" "$expected" "$tmp"
  mv "$tmp" "$dir/state"
  jig_task_state_forget
  jig_record_changed
  # A task that was live left the queue with its status; a re-abandon has
  # nothing to take out.
  [ "$was" = abandoned ] || _task_queue_prune "$id" "task abandon"

  local note=""
  if [ -n "$moved" ] && ! jig_task_ref_dir; then
    if [ "$_JIG_REF_KIND" = spec ]; then
      note="moved: $moved is not there ($_JIG_REF_ERROR); nothing is written there, so add it to that spec yourself"
    else
      note="moved: $moved is not there ($_JIG_REF_ERROR); file it there yourself: (cd $_JIG_REF_REPO && jig task new $_JIG_REF_ID)"
    fi
  fi

  if [ "$as_json" = 1 ]; then
    local rec spec=""
    case "$sid" in '(more than one)') ;; *) spec=$sid ;; esac
    json_str_or_null "$reason"; rec="{\"reason\":$_JSON"
    json_str_or_null "$moved"; rec="$rec,\"moved_to\":$_JSON"
    json_str_or_null "$note"; rec="$rec,\"note\":$_JSON"
    json_str_or_null "$spec"; rec="$rec,\"spec\":$_JSON}"
    printf '{"task":%s,"abandon":%s}\n' "$(_task_json_one "$id")" "$rec"
    return 0
  fi
  printf 'task abandon: %s abandoned%s\n' "$id" "${moved:+, moved to $moved}"
  [ -z "$note" ] || printf '%s\n' "$note"

  [ -n "$sid" ] || return 0
  rc=0
  out=$(cd "$JIG_PROJECT" && JIG_INTERNAL_REDRAW=1 "$JIG_SELF" spec drop "$id" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  if [ "$rc" -eq 3 ]; then
    # Not here: a phase run's coordinator closes the item after the merge, or
    # a checkout of the base does (the line above names the command).
    return 0
  fi
  [ "$rc" -eq 0 ] \
    || jig_die "task abandon: $id is abandoned, but its roadmap item was not rewritten (above); fix that and run jig spec drop $id"
}

# _task_spec_id <id> — the spec a task's task.md links to, `(more than one)`
# for a task.md linking two — a link all the same, which the refusals that
# read this must see, and `spec drop` names the conflict — or nothing.
_task_spec_id() {
  local spec
  _task_spec_id_v spec "$1"
  [ -z "$spec" ] || printf '%s\n' "$spec"
}

# _task_spec_id_v <var> <id> — the same answer into <var>, in the caller's shell.
_task_spec_id_v() {
  local __tsi_md
  printf -v "$1" '%s' ""
  task_dir_v __tsi_md "$2"
  __tsi_md="$__tsi_md/task.md"
  [ -f "$__tsi_md" ] || return 0
  jig_spec_link_v "$1" "$__tsi_md" || printf -v "$1" '%s' '(more than one)'
}

# _task_abandon_keys_clear <id> <dir> — a task taken back from `abandoned`
# loses the record of why it was abandoned: on a live task it would be a false
# fact. The roadmap item `spec drop` closed is not reopened here; a person
# does that, and is told so.
_task_abandon_keys_clear() {
  local id="$1" dir="$2" had sid
  had=$(task_state_get "$id" abandoned_at)
  _task_rewrite_state_remove "$dir" abandoned_at
  _task_rewrite_state_remove "$dir" abandoned_reason
  _task_rewrite_state_remove "$dir" moved_to
  sid=$(_task_spec_id "$id")
  if [ -n "$had" ] && [ -n "$sid" ]; then
    jig_info "task set: $id is live again; if $JIG_AI_DIR/specs/$sid/roadmap.md closed its item as dropped or moved, reopen that item by hand"
  fi
}

# task_archive <id> [--revision <n>] [--json] — a person's archive of a task
# nobody will finish now
# (adr-20261027-a-task-nobody-finished-is-archived-not-purged). The workspace
# stays where it is, kept without a limit; only the status changes, and the
# branch, worktree and pull request are left alone. Its queue entry goes
# (adr-20261107-a-finished-task-leaves-the-queue).
#
# The write is checked against a revision as `task pause`'s is, and `--json`
# anywhere runs the whole command as the producer of json_run
# (conventions/json-output.md): see _task_archive_move, which `unarchive`
# shares.
task_archive() {
  _task_archive_move archive "$@"
}

# task_unarchive <id> [--revision <n>] [--json] — return an archived task to
# the status it had. The write refreshes `updated_at`, so the next housekeeping
# run does not find it stale and archives it again.
task_unarchive() {
  _task_archive_move unarchive "$@"
}

# _task_archive_move <archive|unarchive> <id> [options] — the wrapper both
# commands share: `--json` among the arguments runs the body in json_run.
_task_archive_move() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_archive_move_body 1 "$@"
      return
    fi
  done
  _task_archive_move_body 0 "$@"
}

# _task_archive_move_body <as_json> <archive|unarchive> <id> [--revision <n>]
# [--json] — the body of both; with <as_json> 1 it prints the task, as `task
# list --json` lists it after the write.
#
# The new state is built whole, the revision claimed and only then the file
# moved into place: one write under one claim, and a stale caller writes
# nothing. What follows the move — the queue entry that goes with an archive
# (`jig queue prune`, the queue's own writer, which raises the revision once
# more when it removed one) and the reminder that an unarchived task is not
# queued — comes after it, as it does after `task set … status consolidated`,
# and says what it says on stderr.
_task_archive_move_body() {
  local as_json="$1" verb="$2" arg args=()
  shift 2
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ $# -ge 1 ] || jig_fail usage "$(_task_usage "$verb")"
  case "$1" in
    -*) jig_fail usage "$(_task_usage "$verb")" ;;
  esac
  local id="$1" rev="" rev_given=0 expected dir tmp from=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --revision)
        [ $# -ge 2 ] || jig_fail usage "task $verb: --revision requires a value"
        rev="$2"; rev_given=1; shift 2 ;;
      *) jig_fail usage "$(_task_usage "$verb")" ;;
    esac
  done
  [ "$rev_given" -eq 0 ] || [ -n "$rev" ] || jig_fail usage "task $verb: --revision is empty"
  [ -z "$rev" ] || jig_revision_valid "$rev" || jig_fail usage "task $verb: --revision is not a revision: $rev"
  _task_valid_id "$id" || jig_fail usage "invalid task id: $id"
  # The revision this write is checked against: the caller's, or the one read
  # here before the task is, so the state read below is never newer than it.
  if [ -n "$rev" ]; then expected=$rev; else expected=$(jig_revision_read); fi
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_fail not-found "task $verb: unknown task: $id"
  tmp="$dir/state.tmp.$$"
  jig_cleanup_add "$tmp"
  if [ "$verb" = archive ]; then
    _task_archive_build "$id" manual "$tmp"
  else
    _task_unarchive_build "$id" "$tmp"
  fi
  _task_claim_or_refuse "task $verb" "$expected" "$tmp"
  [ "$verb" = archive ] || from=$(task_state_get "$id" archived_from)
  mv "$tmp" "$dir/state"
  jig_task_state_forget
  jig_record_changed
  if [ "$verb" = archive ]; then
    _task_queue_prune "$id" "task archive"
  else
    _task_unarchive_hint "$id" "$from"
  fi
  if [ "$as_json" = 1 ]; then
    printf '{"task":%s}\n' "$(_task_json_one "$id")"
  fi
}

# _task_archive <id> <reason> — the one writer of `archived` outside the two
# commands, shared with housekeeping, which archives through it rather than
# writing state itself, and `task merge`. Not checked against a revision:
# housekeeping raises it once, as it ends. It builds the state as the
# commands do (_task_archive_build) and moves it into place.
_task_archive() {
  local id="$1" reason="$2" dir tmp
  dir=$(task_dir "$id")
  tmp="$dir/state.tmp.$$"
  jig_cleanup_add "$tmp"
  _task_archive_build "$id" "$reason" "$tmp"
  mv "$tmp" "$dir/state"
  jig_task_state_forget
  jig_record_changed
  _task_queue_prune "$id" "task archive"
}

# _task_archive_build <id> <reason> <tmp> — the state of <id> archived, whole,
# into <tmp>, and the refusals of the move: an unfinished task is archived,
# a consolidated one is not (its work is already in git, and its workspace is
# purged, not kept: `wrong-status`) and an archived one already is
# (`already-archived`). `archived_from` is what unarchive returns to. Writes
# nothing but <tmp>. Called as a plain command, never inside $(...): it dies.
_task_archive_build() {
  local id="$1" reason="$2" tmp="$3" dir status tmp2
  _task_valid_archived_reason "$reason" || jig_die "task archive: invalid reason: $reason"
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task archive"
  status=$(task_state_get "$id" status)
  case "$status" in
    active | ready | abandoned) ;;
    archived) jig_fail already-archived "task archive: task $id is already archived" ;;
    *) jig_fail wrong-status "task archive: task $id is $status; only an unfinished task is archived" ;;
  esac
  tmp2="$tmp.2"
  jig_cleanup_add "$tmp2"
  _task_state_set_into "$dir/state" "$tmp2" archived_from "$status"
  _task_state_set_into "$tmp2" "$tmp" archived_reason "$reason"
  _task_state_set_into "$tmp" "$tmp2" archived_at "$(jig_today)"
  _task_state_set_into "$tmp2" "$tmp" status archived
  rm -f "$tmp2"
}

# _task_unarchive_build <id> <tmp> — the state of <id> back at the status it had
# before it was archived, into <tmp>; `not-archived` for a task that is not.
# An absorbed task that comes back is its own task again; the receiver keeps
# `absorbs` as the record of the documents it took.
_task_unarchive_build() {
  local id="$1" tmp="$2" dir from tmp2
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task unarchive"
  [ "$(task_state_get "$id" status)" = archived ] || jig_fail not-archived "task unarchive: task $id is not archived"
  from=$(task_state_get "$id" archived_from)
  case "$from" in
    active | ready | abandoned) ;;
    *) from=active ;;
  esac
  tmp2="$tmp.2"
  jig_cleanup_add "$tmp2"
  _task_state_set_into "$dir/state" "$tmp2" status "$from"
  _task_state_without_into "$tmp2" "$tmp" archived_from archived_reason archived_at absorbed_into
  rm -f "$tmp2"
}

# _task_unarchive_hint <id> <from> — back to live work, a task is not queued
# any more: its entry went when it was archived. Back to abandoned, it is still
# finished, and a reminder to queue it would be undone by the next prune.
_task_unarchive_hint() {
  [ "$2" != abandoned ] || return 0
  _task_not_queued_hint "$1"
}

# _task_list_add <list> <id> — <list>, comma-separated, with <id> added once.
_task_list_add() {
  case ",$1," in
    *",$2,"*) printf '%s\n' "$1" ;;
    ,,) printf '%s\n' "$2" ;;
    *) printf '%s,%s\n' "$1" "$2" ;;
  esac
}

# _task_json_ids <list> — a comma-separated list of task ids as a JSON array
# in _JSON, `[]` when empty.
_task_json_ids() {
  local list="$1" out="" one
  local IFS=,
  for one in $list; do
    [ -n "$one" ] || continue
    json_quote "$one"
    out="${out:+$out,}$_JSON"
  done
  _JSON="[$out]"
}

# task_merge <from> --into <to> [--partial] — record that <to> does <from>'s
# work (adr-20261027-an-absorbed-task-is-archived-with-its-receiver). <from>'s
# documents are copied to <to>/absorbed/<from>/ and named in <to>'s task.md.
# Whole: <from> is archived with reason `absorbed` and `absorbed_into`, and its
# queue waits move to <to>. Partial: <from> stays live with `partly_in`. Both
# ends record the link (`absorbs`, `absorbs_partly`). The tracker is never
# called: `task ship` of <to> names the absorbed issues.
task_merge() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage merge)"
  local from="$1" to="" partial=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --into) [ $# -ge 2 ] || jig_die "task merge: --into requires a value"; to="$2"; shift 2 ;;
      --partial) partial=1; shift ;;
      *) jig_die "task merge: unknown argument: $1" ;;
    esac
  done
  [ -n "$to" ] || jig_die "$(_task_usage merge)"
  [ "$from" != "$to" ] || jig_die "task merge: a task cannot absorb itself: $from"

  local from_dir to_dir from_root to_root from_status to_status
  from_dir=$(task_dir "$from")
  to_dir=$(task_dir "$to")
  _task_guard_write "$from" "task merge"
  _task_guard_write "$to" "task merge"
  from_status=$(task_state_get "$from" status)
  to_status=$(task_state_get "$to" status)
  case "$to_status" in
    active | ready) ;;
    *) jig_die "task merge: task $to is $to_status; only a live task absorbs another" ;;
  esac
  case "$from_status" in
    active | ready | abandoned) ;;
    *) jig_die "task merge: task $from is $from_status; only an unfinished task is absorbed" ;;
  esac

  # Everything that can refuse is asked before anything is written. Both
  # roots are the guarded physical ones, and the destination is built from two
  # validated ids only. A copy already there — a merge that stopped midway, or
  # one taken back by unarchive — is refreshed, not refused, so the command
  # can always be run again.
  from_root=$(_task_workspace_root "$from" "task merge") || return 1
  to_root=$(_task_workspace_root "$to" "task merge") || return 1
  local dest="$to_root/absorbed/$from"
  [ ! -L "$to_root/absorbed" ] && [ ! -L "$dest" ] \
    || jig_die "task merge: absorbed/$from in $to is a link; remove it first"

  # The queue next: a wait that would close a cycle refuses there, before
  # anything is copied, written or archived.
  if [ "$partial" -eq 0 ]; then
    # shellcheck source=lib/queue.sh
    . "$JIG_LIB/queue.sh"
    queue_absorb "$from" "$to"
  fi

  # The copy: every document of <from>, with whatever <from> itself absorbed,
  # as regular files only — a link is left behind, never followed or copied
  # as a link that would lead out of the receiver's workspace.
  mkdir -p "$dest" || jig_die "task merge: cannot create absorbed/$from in $to"
  local f rel
  for f in "$from_root"/*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    cp "$f" "$dest/" || jig_die "task merge: cannot copy ${f##*/} into $to"
  done
  if [ -d "$from_root/absorbed" ] && [ ! -L "$from_root/absorbed" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ -d "$from_root/$rel" ]; then
        mkdir -p "$dest/$rel" || jig_die "task merge: cannot create $rel in $to"
      else
        cp "$from_root/$rel" "$dest/$rel" || jig_die "task merge: cannot copy $rel into $to"
      fi
    done < <(cd "$from_root" && find absorbed \( -type d -o -type f \) | LC_ALL=C sort)
  fi

  local goal note how
  goal=$(_task_goal "$from_root/task.md")
  how="whole"
  [ "$partial" -eq 0 ] || how="partly"
  note=$(mktemp "${TMPDIR:-/tmp}/jig-merge.XXXXXX")
  jig_cleanup_add "$note"
  {
    printf '\n## Absorbed: %s (%s)\n\n' "$from" "$how"
    [ -z "$goal" ] || printf '%s\n\n' "$goal"
    printf 'Its documents: absorbed/%s/.\n' "$from"
  } > "$note"
  task_artifact append "$to" task --from "$note" >/dev/null

  if [ "$partial" -eq 1 ]; then
    _task_rewrite_state "$to_dir" absorbs_partly "$(_task_list_add "$(task_state_get "$to" absorbs_partly)" "$from")"
    _task_rewrite_state "$from_dir" partly_in "$(_task_list_add "$(task_state_get "$from" partly_in)" "$to")"
    printf '\n## Partly in %s\n\nPart of this work is done by %s; its task.md says which.\n' "$to" "$to" > "$note"
    task_artifact append "$from" task --from "$note" >/dev/null
    printf 'task merge: %s takes part of %s; %s stays open\n' "$to" "$from" "$from"
    return 0
  fi

  _task_rewrite_state "$to_dir" absorbs "$(_task_list_add "$(task_state_get "$to" absorbs)" "$from")"
  _task_rewrite_state "$from_dir" absorbed_into "$to"
  _task_archive "$from" absorbed
  printf 'task merge: %s absorbed into %s; %s is archived\n' "$from" "$to" "$from"
}

# --- autopilot run (design.md, .ai/workspace/tasks/autopilot-run) --------------
#
# `.ai/workspace/tasks/<id>/autopilot` — gitignored workspace file, TSV, one
# line per event: `<UTC ISO time>\t<event>\t<text>` where event is one of
# start, stage, repair, stop, answer, resume, approve, decide, handover, end and text is a
# single line with no tab (validated the same way as a findings-ledger field,
# _task_finding_valid_field).
#
# State: `autopilot: on|stopped|done` (absent before the first `start`),
# `autopilot_repairs: <n>` (the repair count for the current run, reset to 0
# by `start` and by `resume`), `autopilot_mode: attended|unattended` (read
# from `autopilot.unattended` once, by `start`, so changing the key halfway
# changes nothing about a run), `autopilot_handover: <UTC ISO time>` (a person
# took a stopped run over: `handover`, never cleared, and no `start` after
# it — adr-20261108-a-person-takes-over-a-stopped-run), `autopilot_answered:
# <UTC ISO time>` (a person answered the stop but nothing resumed the run yet:
# `answer` writes it, `resume` and `handover` clear it —
# adr-20261114-a-waiting-run-holds-no-slot). All are script-owned, alongside `paused`
# and the other keys `task set` refuses to write by hand (schemas/state.md).
#
# An unattended run asks nothing
# (adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci): where an
# attended run would stop, the skill takes the safe default and says so with
# `approve` (it approved its own design at a gate) or `decide` (it chose for
# the human), and `report` lists both for the pull request. Only an
# unattended run may record either: in an attended one they are stops.
#
# The repair limit (2 per run, design's gate decision) is enforced here, not
# by the calling skill: a script-side stop is a stop no orchestration prompt
# can talk its way past.

# _task_autopilot_now — UTC ISO-8601 timestamp for one journal line (same
# format housekeeping.sh's log lines use, conventions/shell.md).
_task_autopilot_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _task_autopilot_valid_stage <name> — same grammar as one item of
# _task_valid_domains: `[a-z0-9-]+`, nothing else.
_task_autopilot_valid_stage() {
  case "$1" in
    '' | *[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

# _task_autopilot_repairs <id> — the current run's repair count, "0" when
# the state key is absent or not a plain integer (a task that never
# repaired).
_task_autopilot_repairs() {
  local n
  _task_autopilot_repairs_v n "$1"
  printf '%s\n' "$n"
}

# _task_autopilot_repairs_v <var> <id> — the same count into <var>.
_task_autopilot_repairs_v() {
  local __tar_n
  task_state_var __tar_n "$2" autopilot_repairs
  case "$__tar_n" in '' | *[!0-9]*) __tar_n=0 ;; esac
  printf -v "$1" '%s' "$__tar_n"
}

# _task_autopilot_log <id> <event> <text> — append one line to the run
# journal. Atomic the same way task_finding_add's ledger write is
# (conventions/shell.md): copy the existing journal into a temp file (or
# start an empty one), append the new line, then `mv` it into place. Chosen
# over a bare `>>`, which is already "atomic enough" for a single `printf`
# whose line fits in one write(2) call, because `report` reads this file
# with a plain `read` loop and a torn write — the one failure `>>` does not
# rule out on every filesystem — would misalign every line after it, not
# just the interrupted one; copy-then-`mv` can only ever yield the file
# exactly as it was before the append, or exactly as it is after.
_task_autopilot_log() {
  local id="$1" event="$2" text="$3" dir file tmp
  dir=$(task_dir "$id")
  _task_guard_dir "$dir"
  file="$dir/autopilot"
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  if [ -f "$file" ]; then
    cp "$file" "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\n' "$(_task_autopilot_now)" "$event" "$text" >> "$tmp"
  mv "$tmp" "$file"
  jig_record_changed
}

# _task_autopilot_note <id> — "autopilot=on" or "autopilot=stopped" for
# `jig status`'s task line, "autopilot=answered" for a stopped run a person
# already answered (it waits for a free slot, not for the person), "autopilot=handed-over" for a run a person took
# over (a fact, not a wait: nothing in `jig status` reads it as attention);
# empty for any other `done` or no run at all (same shape as
# _task_worktree_note — the caller prepends its own separating space).
_task_autopilot_note() {
  case "$(task_state_get "$1" autopilot)" in
    on) printf 'autopilot=on\n' ;;
    stopped)
      if [ -n "$(task_state_get "$1" autopilot_answered)" ]; then
        printf 'autopilot=answered\n'
      else
        printf 'autopilot=stopped\n'
      fi ;;
    done) [ -z "$(task_state_get "$1" autopilot_handover)" ] || printf 'autopilot=handed-over\n' ;;
  esac
}

# _task_autopilot_facts <id> — the run as data, for `report` and the status
# page (ARCHITECTURE.md, Scripts layout: a report consumes an unformatted
# producer rather than parsing a formatted one). One line,
# `<state>\t<repairs>\t<stage>\t<stage-at>\t<stop-reason>\t<stop-at>\t<phase>\t<handover-at>\t<answered-at>`,
# every empty field written `-` so a tab-split read cannot collapse it;
# nothing at all for a task that never started a run. The stage is the last
# one the current run reached — since its last `start` or `resume` — and the
# stop is the journal's last, which is the one a `stopped` run is waiting on.
# <phase> is `autopilot_phase` when a coordinator started this run as one task
# of a roadmap phase (adr-20260922-a-phase-run-is-coordinated). <handover-at>
# is `autopilot_handover`: when a person took the stopped run over.
# <answered-at> is `autopilot_answered`: when a person answered the stop and
# nothing has resumed the run since (the ninth field; readers take fields by
# position, so it was appended).
_task_autopilot_facts() {
  local facts
  _task_autopilot_facts_v facts "$1"
  [ -z "$facts" ] || printf '%s\n' "$facts"
}

# _task_autopilot_facts_v <var> <id> — the same line into <var> (without its
# newline), empty for a task that never started a run. The journal is read
# in the shell, its fields split as `awk -F '\t'` splits them: the time, the
# event, and the text up to the next tab.
_task_autopilot_facts_v() {
  local __taf_state __taf_file __taf_line __taf_at __taf_event __taf_text __taf_t=$'\t'
  local __taf_stage="" __taf_stage_at="" __taf_stop="" __taf_stop_at="" __taf_repairs __taf_phase __taf_handover __taf_answered
  printf -v "$1" '%s' ""
  task_state_var __taf_state "$2" autopilot
  [ -n "$__taf_state" ] || return 0
  task_dir_v __taf_file "$2"
  __taf_file="$__taf_file/autopilot"
  if [ -f "$__taf_file" ]; then
    while IFS= read -r __taf_line || [ -n "$__taf_line" ]; do
      __taf_at=${__taf_line%%"$__taf_t"*}
      __taf_event="" __taf_text=""
      case "$__taf_line" in
        *"$__taf_t"*)
          __taf_line=${__taf_line#*"$__taf_t"}
          __taf_event=${__taf_line%%"$__taf_t"*}
          case "$__taf_line" in
            *"$__taf_t"*)
              __taf_line=${__taf_line#*"$__taf_t"}
              __taf_text=${__taf_line%%"$__taf_t"*} ;;
          esac ;;
      esac
      case "$__taf_event" in
        start | resume) __taf_stage="" __taf_stage_at="" ;;
        stage) __taf_stage=$__taf_text __taf_stage_at=$__taf_at ;;
        stop) __taf_stop=$__taf_text __taf_stop_at=$__taf_at ;;
      esac
    done < "$__taf_file"
  fi
  _task_autopilot_repairs_v __taf_repairs "$2"
  task_state_var __taf_phase "$2" autopilot_phase
  task_state_var __taf_handover "$2" autopilot_handover
  task_state_var __taf_answered "$2" autopilot_answered
  printf -v "$1" '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$__taf_state" "$__taf_repairs" \
    "${__taf_stage:--}" "${__taf_stage_at:--}" "${__taf_stop:--}" "${__taf_stop_at:--}" "${__taf_phase:--}" \
    "${__taf_handover:--}" "${__taf_answered:--}"
}

# jig task autopilot <id> start|stage|repair|stop|answer|resume|handover|end|report —
# dispatches to the functions below. The task id comes before the action
# (same order as `task set <id> <key> <value>`), so every action function
# below takes <id> as its first argument.
task_autopilot() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage autopilot)"
  local id="$1"
  shift
  local action="${1:-}"
  [ $# -gt 0 ] && shift
  case "$action" in
    start) _task_autopilot_start "$id" "$@" ;;
    stage) _task_autopilot_stage "$id" "$@" ;;
    repair) _task_autopilot_repair "$id" "$@" ;;
    stop) _task_autopilot_stop "$id" "$@" ;;
    approve) _task_autopilot_unattended_event "$id" approve "$@" ;;
    decide) _task_autopilot_unattended_event "$id" decide "$@" ;;
    answer) _task_autopilot_answer "$id" "$@" ;;
    resume) _task_autopilot_resume "$id" "$@" ;;
    handover) _task_autopilot_handover "$id" "$@" ;;
    end) _task_autopilot_end "$id" "$@" ;;
    report) _task_autopilot_report "$id" "$@" ;;
    *) jig_die "$(_task_usage autopilot)" ;;
  esac
}

# _task_autopilot_valid_phase <value> — exit 0 when <value> is `<spec-id>/<n>`:
# a spec id by jig_valid_id (the grammar task and spec ids share, common.sh)
# and a phase number, one slash between them. Neither is resolved against a
# roadmap: a worktree cut before the wave's tags landed has no roadmap to
# check against, and a wrong id here costs a journal line, not a wrong action.
_task_autopilot_valid_phase() {
  local value="$1" spec num
  case "$value" in
    */*/* | /* | */) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  spec=${value%/*}
  num=${value##*/}
  jig_valid_id "$spec" || return 1
  case "$num" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# start [--phase <spec-id>/<n>]: refused while a run is already `on`; on a
# `stopped` run it points at `resume` rather than silently restarting; after
# `done`, or on a task that never ran one, it starts a fresh run (design §2
# open question 2: `resume`, not `start`, is what resets the count — `start`
# here resets it too, but only because there is no prior count left to
# preserve).
#
# `--phase` marks the run as one task of a phase run: a coordinator started it
# alongside the rest of a roadmap wave, owns the spec and ships the task
# itself (adr-20260922-a-phase-run-is-coordinated). It is recorded as
# `autopilot_phase`, so the two readers that must behave differently see it
# without being told — `jig spec done` refuses in this task's branch, and the
# status page sends the person to the coordinator's session instead of this
# task's.
_task_autopilot_start() {
  local id="$1"
  shift
  local phase=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)
        [ $# -ge 2 ] || jig_die "task autopilot start: --phase requires a value"
        phase="$2"
        shift 2 ;;
      *) jig_die "task autopilot start: unknown argument: $1" ;;
    esac
  done
  if [ -n "$phase" ]; then
    _task_autopilot_valid_phase "$phase" \
      || jig_die "task autopilot start: --phase takes <spec-id>/<n>, the spec and its phase number: $phase"
  fi
  local dir parked
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task autopilot start"
  # A task parked at the staging branch waits for a review or a signal, never
  # for a run (adr-20261112-a-task-waiting-at-staging-is-parked-and-resuming-it-is-its-status).
  _task_parked_of_v parked "$id"
  if [ -n "$parked" ]; then
    _task_autopilot_parked_refusal "task autopilot start" "$id" "$parked"
    return 3
  fi
  # A person took this task's run over: a fresh run would give an unattended
  # clone two repairs nobody granted
  # (adr-20261108-a-person-takes-over-a-stopped-run).
  [ -z "$(task_state_get "$id" autopilot_handover)" ] \
    || jig_die "task autopilot start: $id was handed over to a person; it finishes without autopilot"
  case "$(task_state_get "$id" autopilot)" in
    on) jig_die "task autopilot start: already running: $id" ;;
    stopped)
      if [ "$(_task_autopilot_mode "$id")" = unattended ]; then
        if _task_autopilot_at_limit "$id"; then
          jig_die "task autopilot start: $id exhausted its unattended repair limit; $(_task_autopilot_limit_roads "$id")"
        fi
        jig_die "task autopilot start: $id is stopped; if a human answered, run: jig task autopilot $id resume --answer <text> --by human"
      fi
      jig_die "task autopilot start: $id is stopped; run: jig task autopilot $id resume" ;;
  esac
  local mode=attended
  if jig_unattended; then mode=unattended; fi
  _task_rewrite_state "$dir" autopilot on
  _task_rewrite_state "$dir" autopilot_repairs 0
  _task_rewrite_state "$dir" autopilot_mode "$mode"
  if [ -n "$phase" ]; then
    _task_rewrite_state "$dir" autopilot_phase "$phase"
    _task_autopilot_log "$id" start "$mode phase $phase"
  else
    _task_autopilot_log "$id" start "$mode"
  fi
  if [ "$mode" = unattended ]; then
    printf 'autopilot: on (unattended)\n'
  else
    printf 'autopilot: on\n'
  fi
  [ -z "$phase" ] || printf 'phase: %s\n' "$phase"
  _task_autopilot_depth_line "$id"
  _task_autopilot_git_line "$id"
}

# _task_autopilot_parked_refusal <who> <id> <parked> — the refusal of a run on
# a task parked at the staging branch, on stderr: a run never takes it on
# from there; a person resumes it for a fix. The caller returns 3, after the
# status page is flushed here (a `return 3` ends the command under errexit
# before cmd_task's own flush).
_task_autopilot_parked_refusal() {
  printf 'jig: error: %s: %s is parked (%s): it waits at the staging branch; a person resumes it for a fix with jig task resume %s\n' \
    "$1" "$2" "$(_task_parked_words "$3")" "$2" >&2
  jig_status_page_flush
}

# _task_autopilot_depth_line <id> — `depth: <depth> (<source>)`, the route
# depth (_task_route_depth) as `start` announces it and `report` repeats it.
_task_autopilot_depth_line() {
  local depth source
  IFS=$'\t' read -r depth source <<EOF
$(_task_route_depth "$1")
EOF
  printf 'depth: %s (%s)\n' "$depth" "$source"
}

# _task_autopilot_mode <id> — the mode the current run recorded at `start`:
# `unattended`, or `attended` for anything else, a run started before modes
# existed included.
_task_autopilot_mode() {
  local mode
  _task_autopilot_mode_v mode "$1"
  printf '%s\n' "$mode"
}

# _task_autopilot_mode_v <var> <id> — the same mode into <var>.
_task_autopilot_mode_v() {
  local __tam_mode
  task_state_var __tam_mode "$2" autopilot_mode
  [ "$__tam_mode" = unattended ] || __tam_mode=attended
  printf -v "$1" '%s' "$__tam_mode"
}

# stage <name>: logs which stage the run just reached. Requires an active
# run — a run only ever moves through stages while `on`. It is the boundary
# Jig sees between two stages, so a pause request is honoured here
# (adr-20261019-a-pause-request-is-honoured-at-the-stage-boundary): a paused
# task enters no stage, and a pending request pauses it instead of the stage.
# Both exit 4, the run staying `on`: a pause is not a stop, and `jig task
# resume` ends it.
_task_autopilot_stage() {
  local id="$1"
  shift
  [ $# -ge 1 ] || jig_die "$(_task_usage autopilot)"
  local name="$1"
  shift
  [ $# -eq 0 ] || jig_die "task autopilot stage: unknown argument: $1"
  task_dir "$id" >/dev/null
  _task_guard_write "$id" "task autopilot stage"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot stage: no active autopilot run: $id; run: jig task autopilot $id start"
  _task_autopilot_valid_stage "$name" \
    || jig_die "task autopilot stage: invalid name: $name (expected [a-z0-9-]+)"
  local parked
  _task_parked_of_v parked "$id"
  if [ -n "$parked" ]; then
    _task_autopilot_parked_refusal "task autopilot stage" "$id" "$parked"
    return 3
  fi
  if [ "$(task_state_get "$id" paused)" = true ]; then
    printf 'jig: error: task autopilot stage: %s is paused; resume it with jig task resume %s before entering a stage\n' "$id" "$id" >&2
    return 4
  fi
  if _task_pause_take_request "$id" "task autopilot stage"; then
    _task_honour_pause_request "$id" "$name"
    # `return 4` ends the command under errexit before cmd_task's own flush.
    jig_status_page_flush
    return 4
  fi
  _task_autopilot_log "$id" stage "$name"
  printf 'stage: %s\n' "$name"
}

# _task_honour_pause_request <id> <stage> — the pause a pending request makes at
# a stage boundary, once _task_pause_take_request has taken the request out:
# `task autopilot stage` and `task pause --if-requested` (which `jig context
# resolve --stage` runs) both come here
# (adr-20261019-a-pause-request-is-honoured-at-the-stage-boundary). It sets the
# fields, writes a `pause` journal line for a run that is `on`, and prints the
# `paused:` line. Called in a body, never as a condition: errexit must stop
# it at a failed write, so a pause that was not recorded is never reported.
_task_honour_pause_request() {
  local id="$1" name="$2" dir why
  dir=$(task_dir "$id")
  why="pause requested at $_JIG_PAUSE_AT"
  [ -z "$_JIG_PAUSE_REASON" ] || why="$why: $_JIG_PAUSE_REASON"
  _task_rewrite_state "$dir" paused true
  _task_rewrite_state "$dir" paused_at "$(jig_today)"
  _task_rewrite_state "$dir" paused_reason "$why"
  if [ "$(task_state_get "$id" autopilot)" = "on" ]; then
    _task_autopilot_log "$id" pause "$name not entered: $why"
  fi
  printf 'paused: %s (%s); stage %s not entered\n' "$id" "$why" "$name"
}

# _task_queue_prune <id> <verb> — once a status that finishes a task is
# written (consolidated, abandoned, archived), take the finished tasks out of
# the queue through `jig queue prune`, the queue's one writer
# (adr-20261107-a-finished-task-leaves-the-queue). Best effort: the status
# stands whatever the queue says. A stale revision is another write landing in
# between: read again, up to three times; a queue that kept changing or
# refused is warned about with the command that finishes the job. Nothing is
# asked of a clone with no queue.
_task_queue_prune() {
  local id="$1" verb="$2" tries=0 out
  [ -f "$(jig_queue_file)" ] || return 0
  while :; do
    if out=$(JIG_INTERNAL_REDRAW=1 "$JIG_SELF" queue prune --json 2>/dev/null); then
      case "$out" in
        *"\"ref\":\"task:$id\",\"status\""*) jig_info "$verb: task:$id left the queue" ;;
      esac
      return 0
    fi
    # The code as json.sh's envelope prints it (_task_pause_take_request).
    case "$out" in
      *'"code":"stale-revision"'*) ;;
      *) jig_warn "$verb: $id stays in the queue; take it out with jig queue prune"; return 0 ;;
    esac
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
      jig_warn "$verb: the queue kept changing; $id stays in it — jig queue prune"
      return 0
    fi
  done
}

# _task_pause_take_request <id> <verb> — when the queue holds a pause request
# for <id>, take it out through `jig queue cancel`, the queue's one writer,
# and exit 0 with _JIG_PAUSE_AT and _JIG_PAUSE_REASON (common.sh) naming it;
# exit 1 when there is none, or somebody cancelled it first. The request goes
# before the pause is set: a request that could not be taken out leaves the
# task unpaused and the request standing, never a pause whose request would
# pause it again after `resume`. A stale revision is another write landing in
# between: read again, up to three times.
#
# A cancel that failed for any other reason may still have landed: its write
# came before whatever ended it. So the queue is read again, and a request
# that is gone counts as taken out — with the time and reason read before the
# cancel, as jig_pause_request clears them — and a warning that names the
# child's exit status and words. A request that still stands is refused with
# them: the child's stderr is the only account of why.
_task_pause_take_request() {
  local id="$1" verb="$2" tries=0 out at reason err="" rc why
  while jig_pause_request "$id"; do
    if [ -z "$err" ]; then
      err=$(mktemp "${TMPDIR:-/tmp}/jig-cancel.XXXXXX") || jig_die "$verb: cannot create a temporary file"
      jig_cleanup_add "$err"
    fi
    at=$_JIG_PAUSE_AT
    reason=$_JIG_PAUSE_REASON
    rc=0
    out=$("$JIG_SELF" queue cancel "task:$id" pause --json 2>"$err") || rc=$?
    if [ "$rc" -eq 0 ]; then
      _JIG_PAUSE_AT=$at
      _JIG_PAUSE_REASON=$reason
      return 0
    fi
    # The code as json.sh's envelope prints it, without spaces
    # (tests/json.t.sh pins that layout); there is no jq to parse it with.
    case "$out" in
      *'"code":"not-found"'*) return 1 ;;
      *'"code":"stale-revision"'*) ;;
      *)
        why=$(_task_pause_cancel_words "$err" "$out" "$rc")
        if ! jig_pause_request "$id"; then
          _JIG_PAUSE_AT=$at
          _JIG_PAUSE_REASON=$reason
          jig_warn "$verb: the pause request of $id left the queue, but jig queue cancel failed: $why"
          return 0
        fi
        jig_die "$verb: cannot take the pause request of $id out of the queue: $why" ;;
    esac
    tries=$((tries + 1))
    [ "$tries" -lt 3 ] || jig_die "$verb: the queue kept changing; the pause request of $id stays"
  done
  return 1
}

# _task_pause_put_request_back <id> <reason> — a pause that failed after it
# took the task's pause request out of the queue puts the request back through
# `jig queue request`, the queue's one writer, with the reason it carried; its
# time is the time it went back. A request that cannot be put back is named in
# a warning, so the person can ask again.
_task_pause_put_request_back() {
  local id="$1" reason="$2" args=()
  [ -z "$reason" ] || args=(--reason "$reason")
  if "$JIG_SELF" queue request "task:$id" pause ${args[@]+"${args[@]}"} >/dev/null 2>&1; then
    jig_warn "task pause: the pause request of $id is back in the queue"
  else
    jig_warn "task pause: the pause request of $id could not be put back in the queue; request it again with jig queue request task:$id pause"
  fi
}

# _task_pause_cancel_words <stderr file> <stdout> <exit status> — one line
# saying how a child `jig queue cancel` failed: its exit status and what it
# said on stderr, or, when it said nothing there, the envelope's message.
_task_pause_cancel_words() {
  local text
  text=$(sed 's/^jig: error: //' "$1" 2>/dev/null | tr '\n' ' ' | sed 's/  *$//')
  if [ -z "$text" ]; then
    text=$(printf '%s\n' "$2" | sed -n 's/.*"error":{"code":"[^"]*","message":"\(.*\)"}}$/\1/p')
  fi
  [ -n "$text" ] || text="no message"
  printf 'exit %s: %s\n' "$3" "$text"
}

# repair --reason <text>: one repair attempt, limited to 2 per run (gate
# decision, task.md human gate). Attempts 1 and 2 increment the count and
# keep the run `on`; the 3rd does not count as a repair at all — it is the
# mechanical stop the design calls for, so the skill can never argue its way
# past the limit. Exit 3 on that stop, distinct from the plain `jig_die`
# exit 1 every other refusal here uses, so a caller can tell "you gave bad
# arguments" apart from "the run just stopped".
_task_autopilot_repair() {
  local id="$1"
  shift
  local reason="" has_reason=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task autopilot repair: --reason requires a value"
        reason="$2"; has_reason=1; shift 2 ;;
      *) jig_die "task autopilot repair: unknown argument: $1" ;;
    esac
  done
  [ "$has_reason" -eq 1 ] || jig_die "task autopilot repair: --reason is required"
  [ -n "$reason" ] || jig_die "task autopilot repair: --reason must not be empty"
  _task_finding_valid_field "$reason" \
    || jig_die "task autopilot repair: --reason must be a single line with no tab"

  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task autopilot repair"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot repair: no active autopilot run: $id; run: jig task autopilot $id start"

  local count
  count=$(_task_autopilot_repairs "$id")
  if [ "$count" -lt 2 ]; then
    count=$((count + 1))
    _task_rewrite_state "$dir" autopilot_repairs "$count"
    _task_autopilot_log "$id" repair "$reason"
    printf 'repair %s/2\n' "$count"
    return 0
  fi

  # The 3rd attempt does not increment: the count stays at the limit it
  # already reached, and the run stops instead.
  _task_rewrite_state "$dir" autopilot stopped
  _task_autopilot_log "$id" stop "repair limit reached (2): $reason"
  _task_autopilot_notify "$id" stop "repair limit reached (2): $reason"
  printf 'stop: repair limit reached (2)\n'
  # `return 3` ends the command under errexit before cmd_task's own flush.
  jig_status_page_flush
  return 3
}

# stop --reason <text>: the stop an agent notices for itself (design §3's
# table — the T3/T4 gate, a re-classification, an unowned decision, a
# destructive operation). Requires an active run, same as repair.
_task_autopilot_stop() {
  local id="$1"
  shift
  local reason="" has_reason=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task autopilot stop: --reason requires a value"
        reason="$2"; has_reason=1; shift 2 ;;
      *) jig_die "task autopilot stop: unknown argument: $1" ;;
    esac
  done
  [ "$has_reason" -eq 1 ] || jig_die "task autopilot stop: --reason is required"
  [ -n "$reason" ] || jig_die "task autopilot stop: --reason must not be empty"
  _task_finding_valid_field "$reason" \
    || jig_die "task autopilot stop: --reason must be a single line with no tab"

  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task autopilot stop"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot stop: no active autopilot run: $id; run: jig task autopilot $id start"

  _task_rewrite_state "$dir" autopilot stopped
  _task_autopilot_log "$id" stop "$reason"
  _task_autopilot_notify "$id" stop "$reason"
  printf 'autopilot: stopped\n'
}

# approve|decide --reason <text>: what an unattended run did instead of
# stopping — `approve` for its own design at a gate, `decide` for a choice
# nobody made or a destructive step it left out. Requires an active run whose
# recorded mode is unattended: in an attended run each of these is a stop, and
# a journal line cannot stand in for the human's answer.
_task_autopilot_unattended_event() {
  local id="$1" event="$2"
  shift 2
  local reason="" has_reason=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task autopilot $event: --reason requires a value"
        reason="$2"; has_reason=1; shift 2 ;;
      *) jig_die "task autopilot $event: unknown argument: $1" ;;
    esac
  done
  [ "$has_reason" -eq 1 ] || jig_die "task autopilot $event: --reason is required"
  [ -n "$reason" ] || jig_die "task autopilot $event: --reason must not be empty"
  _task_finding_valid_field "$reason" \
    || jig_die "task autopilot $event: --reason must be a single line with no tab"

  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task autopilot $event"
  [ "$(task_state_get "$id" autopilot)" = "on" ] \
    || jig_die "task autopilot $event: no active autopilot run: $id; run: jig task autopilot $id start"
  [ "$(_task_autopilot_mode "$id")" = unattended ] \
    || jig_die "task autopilot $event: $id's run is attended; stop and ask the human instead: jig task autopilot $id stop --reason <text>"

  _task_autopilot_log "$id" "$event" "$reason"
  _task_autopilot_notify "$id" "$event" "$reason"
  printf '%s: %s\n' "$event" "$reason"
}

# answer --answer <text> [--by human]: a person answers a stop without
# resuming the run, so a stopped run holds no slot until something resumes it
# (adr-20261114-a-waiting-run-holds-no-slot). The run stays `stopped` and its
# repairs untouched; the answer goes to the journal (`human: ` prefixed for an
# unattended run, as `resume` quotes it) and `autopilot_answered` records when.
# Answering again is allowed: a new line, a new time. The same refusals as
# `resume --answer`. The script cannot authenticate the answer.
_task_autopilot_answer() {
  local id="$1"
  shift
  local answer="" has_answer=0 by="" mode refusal
  while [ $# -gt 0 ]; do
    case "$1" in
      --answer)
        [ $# -ge 2 ] || jig_die "task autopilot answer: --answer requires a value"
        answer="$2"; has_answer=1; shift 2 ;;
      --by)
        [ $# -ge 2 ] || jig_die "task autopilot answer: --by requires human"
        [ "$2" = human ] || jig_die "task autopilot answer: --by accepts human only"
        by=human; shift 2 ;;
      *) jig_die "task autopilot answer: unknown argument: $1" ;;
    esac
  done
  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task autopilot answer"
  [ "$(task_state_get "$id" autopilot)" = "stopped" ] \
    || jig_die "task autopilot answer: not stopped: $id"
  [ "$has_answer" -eq 1 ] \
    || jig_die "task autopilot answer: --answer is required: the human's answer to the stop, in their words: jig task autopilot $id answer --answer <text>"
  [ -n "$answer" ] || jig_die "task autopilot answer: --answer must not be empty"
  _task_finding_valid_field "$answer" \
    || jig_die "task autopilot answer: --answer must be a single line with no tab"
  refusal=$(_task_autopilot_resume_refusal "$id" "$by" answer) || exit 1
  [ -z "$refusal" ] || jig_die "$refusal"

  mode=$(_task_autopilot_mode "$id")
  if [ "$mode" = unattended ]; then
    _task_autopilot_log "$id" answer "human: $answer"
  else
    _task_autopilot_log "$id" answer "$answer"
  fi
  _task_rewrite_state "$dir" autopilot_answered "$(_task_autopilot_now)"
  printf 'autopilot: answered; a session with a free slot resumes it with jig task autopilot %s resume (jig queue next lists it under resume first)\n' "$id"
}

# _task_autopilot_last_answer_v <var> <id> — the text of the journal's last
# `answer` line (already `human: ` prefixed for an unattended run), empty when
# there is none.
_task_autopilot_last_answer_v() {
  local __tala_file __tala_line __tala_rest __tala_text="" __tala_t=$'\t'
  task_dir_v __tala_file "$2"
  __tala_file="$__tala_file/autopilot"
  if [ -f "$__tala_file" ]; then
    while IFS= read -r __tala_line || [ -n "$__tala_line" ]; do
      case "$__tala_line" in
        *"$__tala_t"*)
          __tala_rest=${__tala_line#*"$__tala_t"}
          [ "${__tala_rest%%"$__tala_t"*}" = answer ] || continue
          case "$__tala_rest" in
            *"$__tala_t"*)
              __tala_rest=${__tala_rest#*"$__tala_t"}
              __tala_text=${__tala_rest%%"$__tala_t"*} ;;
          esac ;;
      esac
    done < "$__tala_file"
  fi
  printf -v "$1" '%s' "$__tala_text"
}

# resume [--answer <text>] [--by human]: after the human answers a stop.
# Without --answer it takes the answer `answer` recorded (autopilot_answered),
# and an unattended run then needs no --by human: the person's form wrote it.
# An attended run resets its repair count. A stopped unattended run can resume
# only on an explicit human answer while it has fewer than two repairs; its
# count is preserved, so neither a manual stop nor the repair-limit stop can
# buy another repair attempt. The script cannot authenticate the answer. The
# journal quotes the claim where the person can check it. Every resume clears
# autopilot_answered.
_task_autopilot_resume() {
  local id="$1"
  shift
  local answer="" has_answer=0 by="" mode refusal
  while [ $# -gt 0 ]; do
    case "$1" in
      --answer)
        [ $# -ge 2 ] || jig_die "task autopilot resume: --answer requires a value"
        answer="$2"; has_answer=1; shift 2 ;;
      --by)
        [ $# -ge 2 ] || jig_die "task autopilot resume: --by requires human"
        [ "$2" = human ] || jig_die "task autopilot resume: --by accepts human only"
        by=human; shift 2 ;;
      *) jig_die "task autopilot resume: unknown argument: $1" ;;
    esac
  done
  local dir recorded=0
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task autopilot resume"
  [ "$(task_state_get "$id" autopilot)" = "stopped" ] \
    || jig_die "task autopilot resume: not stopped: $id"
  if [ "$has_answer" -eq 0 ] && [ -n "$(task_state_get "$id" autopilot_answered)" ]; then
    recorded=1
    _task_autopilot_last_answer_v answer "$id"
    # The answer is already recorded: the person's form wrote it, so --by human
    # is not asked again; only the repair limit still applies. An attended run
    # keeps its own refusal of --by human.
    local eff_by=human
    [ "$(_task_autopilot_mode "$id")" = unattended ] || eff_by=$by
    refusal=$(_task_autopilot_resume_refusal "$id" "$eff_by") || exit 1
    [ -z "$refusal" ] || jig_die "$refusal"
  else
    [ "$has_answer" -eq 1 ] \
      || jig_die "task autopilot resume: --answer is required: the human's answer to the stop, in their words: jig task autopilot $id resume --answer <text>"
    [ -n "$answer" ] || jig_die "task autopilot resume: --answer must not be empty"
    _task_finding_valid_field "$answer" \
      || jig_die "task autopilot resume: --answer must be a single line with no tab"
    refusal=$(_task_autopilot_resume_refusal "$id" "$by") || exit 1
    [ -z "$refusal" ] || jig_die "$refusal"
  fi

  mode=$(_task_autopilot_mode "$id")
  if [ "$mode" = unattended ]; then
    _task_rewrite_state "$dir" autopilot on
    if [ "$recorded" -eq 1 ]; then
      _task_autopilot_log "$id" resume "$answer"
    else
      _task_autopilot_log "$id" resume "human: $answer"
    fi
  else
    _task_rewrite_state "$dir" autopilot on
    _task_rewrite_state "$dir" autopilot_repairs 0
    _task_autopilot_log "$id" resume "$answer"
  fi
  _task_state_drop_key "$dir" autopilot_answered
  printf 'autopilot: on\n'
}

# _task_autopilot_resume_refusal <id> <by> [<verb>] — why `jig task autopilot
# <id> resume --answer <text>` (or `answer`, when <verb> says so; `resume` by
# default), with `--by human` when <by> is `human`, refuses this task by its
# state, or nothing when it would go through. The command asks it after
# checking the answer itself; the actions table (_task_actions) asks it with
# the `--by` the run's mode needs.
_task_autopilot_resume_refusal() {
  local id="$1" by="$2" verb="${3:-resume}" run mode
  task_state_var run "$id" autopilot
  if [ "$run" != "stopped" ]; then
    printf 'task autopilot %s: not stopped: %s\n' "$verb" "$id"
    return 0
  fi
  _task_autopilot_mode_v mode "$id"
  if [ "$mode" = unattended ]; then
    if [ "$by" != human ]; then
      printf 'task autopilot %s: an unattended run needs an actual human answer and --by human; otherwise ship a draft\n' "$verb"
    elif _task_autopilot_at_limit "$id"; then
      printf 'task autopilot %s: %s exhausted its unattended repair limit; %s\n' "$verb" "$id" "$(_task_autopilot_limit_roads "$id")"
    fi
  elif [ -n "$by" ]; then
    printf 'task autopilot %s: --by human is only for an unattended run\n' "$verb"
  fi
  return 0
}

# _task_autopilot_at_limit <id> — exit 0 when <id>'s run was started
# unattended and has spent both repairs: what nothing resumes, and what ends in
# its draft or a handover. The one predicate start, resume, the gate and the
# status page's stop card ask (ARCHITECTURE.md: a report consumes it).
_task_autopilot_at_limit() {
  local mode repairs
  _task_autopilot_mode_v mode "$1"
  [ "$mode" = unattended ] || return 1
  _task_autopilot_repairs_v repairs "$1"
  [ "$repairs" -ge 2 ]
}

# _task_autopilot_stage_before_gate <stage> — exit 0 when <stage>, the last
# stage a run reached (_task_autopilot_stop_stage_v: empty when it has
# reached none since it started, a resume included), is one before the human
# gate of a T3/T4 route (_task_route: discover, specify, alternatives, design)
# or the gate itself. A run that stops there stopped at the gate; one that
# stops after it (implement, review, verify, ...) stopped about something
# else, even while the gate waits or has changed, and keeps its own card and
# its own answer (adr-20261119-a-gate-takes-an-answer). An allow-list: a stage
# nobody listed reads as past the gate, the safe miss, because the stop card
# still answers the run.
_task_autopilot_stage_before_gate() {
  case "$1" in
    "" | - | discover | specify | alternatives | design | human-gate | gate) return 0 ;;
  esac
  return 1
}

# _task_autopilot_stop_stage_v <var> <id> — the last stage the task's current
# run marked, into <var>; empty when it marked none. Only `start` resets it:
# a resumed run continues from the stage it stopped in, so a run that marked
# implement, stopped, was resumed and stopped again without marking a stage
# stopped after implement, not at the gate. (Field 3 of the facts line is
# not this: `resume` resets it there, for what the run has done since.) Read
# only for a stopped run, by the gate's answer and the status page's card.
# The journal is parsed as _task_autopilot_facts_v parses it.
_task_autopilot_stop_stage_v() {
  local __tass_file __tass_line __tass_event __tass_text __tass_stage="" __tass_t=$'\t'
  task_dir_v __tass_file "$2"
  __tass_file="$__tass_file/autopilot"
  if [ -f "$__tass_file" ]; then
    while IFS= read -r __tass_line || [ -n "$__tass_line" ]; do
      __tass_event="" __tass_text=""
      case "$__tass_line" in
        *"$__tass_t"*)
          __tass_line=${__tass_line#*"$__tass_t"}
          __tass_event=${__tass_line%%"$__tass_t"*}
          case "$__tass_line" in
            *"$__tass_t"*)
              __tass_line=${__tass_line#*"$__tass_t"}
              __tass_text=${__tass_line%%"$__tass_t"*} ;;
          esac ;;
      esac
      case "$__tass_event" in
        start) __tass_stage="" ;;
        stage) __tass_stage=$__tass_text ;;
      esac
    done < "$__tass_file"
  fi
  printf -v "$1" '%s' "$__tass_stage"
}

# _task_autopilot_limit_roads <id> — what is left for a stopped unattended run
# at its repair limit, as the refusals that meet it name it: the draft, or a
# person taking the task over (adr-20261108-a-person-takes-over-a-stopped-run).
_task_autopilot_limit_roads() {
  printf 'ship a draft, or, if a person takes the task on: jig task autopilot %s handover --by human --answer <text>\n' "$1"
}

# handover --by human --answer <text>: a person takes a stopped run over and
# finishes the task without autopilot (adr-20261108-a-person-takes-over-a-stopped-run).
# Either mode, at the repair limit or before it. The run ends (`done`), and
# `autopilot_handover` records when, so `start` never begins a fresh run with
# fresh repairs. Mode and repair count stay as the record of what the run was.
# The script cannot tell a person from an agent: `--by human` is the claim and
# the answer is quoted where the person reads it — the journal, the report in
# the pull request, Telegram.
_task_autopilot_handover() {
  local id="$1"
  shift
  local answer="" has_answer=0 by="" refusal now
  while [ $# -gt 0 ]; do
    case "$1" in
      --answer)
        [ $# -ge 2 ] || jig_die "task autopilot handover: --answer requires a value"
        answer="$2"; has_answer=1; shift 2 ;;
      --by)
        [ $# -ge 2 ] || jig_die "task autopilot handover: --by requires human"
        [ "$2" = human ] || jig_die "task autopilot handover: --by accepts human only"
        by=human; shift 2 ;;
      *) jig_die "task autopilot handover: unknown argument: $1" ;;
    esac
  done
  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task autopilot handover"
  refusal=$(_task_autopilot_handover_refusal "$id") || exit 1
  [ -z "$refusal" ] || jig_die "$refusal"
  [ "$by" = human ] \
    || jig_die "task autopilot handover: --by human is required: only a person takes a run over, never the agent that ran it"
  [ "$has_answer" -eq 1 ] \
    || jig_die "task autopilot handover: --answer is required: the person's words, what they take on and why: jig task autopilot $id handover --by human --answer <text>"
  [ -n "$answer" ] || jig_die "task autopilot handover: --answer must not be empty"
  _task_finding_valid_field "$answer" \
    || jig_die "task autopilot handover: --answer must be a single line with no tab"

  now=$(_task_autopilot_now)
  _task_rewrite_state "$dir" autopilot "done"
  _task_rewrite_state "$dir" autopilot_handover "$now"
  _task_state_drop_key "$dir" autopilot_answered
  _task_autopilot_log "$id" handover "human: $answer"
  _task_autopilot_notify "$id" handover "taken over by a person: $answer"
  printf 'autopilot: handed over; the task goes on without autopilot\n'
}

# _task_autopilot_handover_refusal <id> — why `jig task autopilot <id>
# handover --by human --answer <text>` refuses this task by its state, or
# nothing when it would hand the run over. Shared with the actions table
# (_task_actions).
_task_autopilot_handover_refusal() {
  local id="$1" run
  task_state_var run "$id" autopilot
  case "$run" in
    stopped) ;;
    on) printf 'task autopilot handover: %s is running; ask the agent to stop it first: jig task autopilot %s stop --reason <text>\n' "$id" "$id" ;;
    *) printf 'task autopilot handover: %s has no stopped autopilot run\n' "$id" ;;
  esac
  return 0
}

# end [--reason <text>]: the run reached the end of its route (design §1 step
# 5, after consolidation). Requires an active run. An unattended run ends only
# once the knowledge decision is recorded: `end` then `start` is a fresh run
# with a fresh repair count, and nobody there would have answered for it
# (adr-20261004-a-route-stage-is-proven-by-its-record).
#
# The reason says how the run ended — merged, not merged and why, ready for
# the person's commit — and is the text of the end's Telegram message
# (adr-20261009-autopilot-stops-reach-telegram). Optional: without it the
# journal line stays empty, as before, and the message says only that the run
# ended, never that anything merged.
_task_autopilot_end() {
  local id="$1"
  shift
  local reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task autopilot end: --reason requires a value"
        reason="$2"; shift 2 ;;
      *) jig_die "task autopilot end: unknown argument: $1" ;;
    esac
  done
  _task_finding_valid_field "$reason" \
    || jig_die "task autopilot end: --reason must be a single line with no tab"
  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task autopilot end"
  local run
  run=$(task_state_get "$id" autopilot)
  # A stopped run waits for its person; ending it here would say nothing about
  # who goes on with the work.
  [ "$run" != stopped ] \
    || jig_die "task autopilot end: $id is stopped; if a person takes the task on: jig task autopilot $id handover --by human --answer <text>"
  # A handover already ended the run, and `start` is refused after one: the
  # usual "run: start" hint would point at a dead end.
  [ -z "$(task_state_get "$id" autopilot_handover)" ] \
    || jig_die "task autopilot end: $id's run already ended when a person took it over; there is nothing to end"
  [ "$run" = "on" ] \
    || jig_die "task autopilot end: no active autopilot run: $id; run: jig task autopilot $id start"
  if [ "$(_task_autopilot_mode "$id")" = unattended ] && [ "$(task_state_get "$id" knowledge_consolidated)" != true ]; then
    jig_die "task autopilot end: $id's unattended run ends after consolidation (knowledge_consolidated true); a run whose repairs ran out stays stopped and ships a draft"
  fi

  _task_rewrite_state "$dir" autopilot "done"
  _task_autopilot_log "$id" end "$reason"
  _task_autopilot_notify "$id" end "$reason"
  printf 'autopilot: done\n'
}

# _task_autopilot_notify <id> <event> <text> — the event's Telegram message,
# detached; never fails and prints nothing (notify.sh). Called after the
# journal line, so a message never reports an event that was not recorded.
_task_autopilot_notify() {
  if ! command -v jig_notify_autopilot >/dev/null 2>&1; then
    # shellcheck source=lib/notify.sh
    . "$JIG_LIB/notify.sh" 2>/dev/null || return 0
  fi
  jig_notify_autopilot "$@" || true
}

# report: the journal in readable form, then a final summary line. A task
# that never ran `start` at all — no journal file — is not an error: "no
# autopilot run", exit 0.
_task_autopilot_report() {
  local id="$1"
  shift
  [ $# -eq 0 ] || jig_die "task autopilot report: unknown argument: $1"
  local dir file
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task autopilot report: unknown task: $id"
  file="$dir/autopilot"
  if [ ! -f "$file" ]; then
    printf 'no autopilot run\n'
    return 0
  fi

  local ts event text
  while IFS=$'\t' read -r ts event text; do
    if [ -n "$text" ]; then
      printf '%s %s: %s\n' "$ts" "$event" "$text"
    else
      printf '%s %s\n' "$ts" "$event"
    fi
  done < "$file"

  # What an unattended run chose instead of asking, in blocks the skill
  # copies into the pull request as they are: the human reads them there.
  local block
  block=$(awk -F '\t' '$2 == "decide" { print "- " $3 }' "$file")
  [ -z "$block" ] || printf '\nDecided without you:\n%s\n' "$block"
  block=$(awk -F '\t' '$2 == "approve" { print "- " $3 }' "$file")
  [ -z "$block" ] || printf '\nApproved by the agent, not a human:\n%s\n' "$block"
  # A resume quotes the answer it was given and a lowering its reason, so the
  # person checks both where they read the run: in the pull request.
  block=$(awk -F '\t' '$2 == "resume" && $3 != "" { print "- " $3 }' "$file")
  [ -z "$block" ] || printf '\nResumed on an answer (check it was yours):\n%s\n' "$block"
  block=$(awk -F '\t' '$2 == "handover" { print "- " $3 }' "$file")
  [ -z "$block" ] || printf '\nTaken over by a person (check it was yours):\n%s\n' "$block"
  local from
  from=$(task_state_get "$id" class_lowered_from)
  if [ -n "$from" ]; then
    printf '\nClass lowered:\n- from %s to %s: %s\n' "$from" "$(task_state_get "$id" class)" "$(task_state_get "$id" class_lowered_reason)"
  fi
  # A linked source the task edited waits for a human's review (jig-accept),
  # and without this they would learn of it only after the merge, from
  # `jig status`. Informational: nothing here stops the run or the ship.
  # Read where the task's branch is checked out — this checkout, or the task's
  # own worktree — by a `knowledge changed` process run there: one command
  # library never sources another (ARCHITECTURE.md, Scripts layout).
  local base branch where="$JIG_PROJECT" sources
  base=$(task_state_get "$id" base_commit)
  branch=$(task_state_get "$id" branch)
  if [ -n "$base" ] && [ -n "$branch" ] && [ "$branch" != "$(_task_current_branch)" ]; then
    where=$(_task_worktree_for "$branch" "$(_task_worktrees)")
  fi
  if [ -n "$base" ] && [ -z "$where" ]; then
    # Said, not left out: an absent block would read as "nothing changed".
    printf '\nChanged linked sources: not checked, %s is not checked out in this clone\n' "$branch"
  elif [ -n "$base" ]; then
    sources=$(cd "$where" 2>/dev/null && "$JIG_SELF" knowledge changed --base "$base" --to-review 2>/dev/null) || sources=""
    [ -z "$sources" ] || printf '\n%s\n' "$sources"
  fi

  local facts state repairs mode=""
  facts=$(_task_autopilot_facts "$id")
  state=$(printf '%s\n' "$facts" | cut -f 1)
  repairs=$(printf '%s\n' "$facts" | cut -f 2)
  [ -n "$repairs" ] || repairs=0
  [ "$(_task_autopilot_mode "$id")" != unattended ] || mode=", unattended"
  [ "$(printf '%s\n' "$facts" | cut -f 8)" = "-" ] || state="$state (handed over)"
  _task_autopilot_depth_line "$id"
  printf 'autopilot: %s, repairs: %s/2%s\n' "$state" "$repairs" "$mode"
}

# --- findings ledger (design.md, findings-ledger) ------------------------------
#
# `.ai/workspace/tasks/<id>/findings` — gitignored workspace file, TSV, one
# line per finding:
#   F<n>  P0|P1|P2|P3  open|fixed|closed|dismissed  where  summary  date  reason
# `where` is `path[:line]` or `-`; `summary` is one line; `date` is the date
# of the last change to the line; `reason` (7th column) holds the dismissal
# reason and is empty for every other status. Written atomically
# (conventions/shell.md: tmp.$$ then mv), and every check on the arguments
# runs before the file is touched, so a refused call leaves it byte-identical.
#
# "Blocking" (severity P0/P1, status open or fixed — fixed still blocks until
# a re-review closes it) is computed once, in _task_blocking_findings, so
# `task set`, `task ship` and `jig status` cannot disagree about it
# (ARCHITECTURE.md, Scripts layout: a reporting command consumes a peer's
# answer, never recomputes it).

# _task_finding_next_id <file> — "F<n>", n one more than the highest existing
# F<n> id in <file> ("F1" when <file> is absent). One awk pass rather than a
# shell loop reading ids one at a time, so a malformed id already on disk
# cannot desync a hand-kept counter from what gets printed.
_task_finding_next_id() {
  local file="$1" max
  if [ -f "$file" ]; then
    max=$(awk -F '\t' '{ n = $1; sub(/^F/, "", n); if (n + 0 > max + 0) max = n + 0 } END { print max + 0 }' "$file")
  else
    max=0
  fi
  printf 'F%d\n' "$((max + 1))"
}

# _task_blocking_findings <id> — "<F-id> <severity> <status> <where>", one
# line per P0/P1 finding still open or fixed. Empty, not an error, when the
# task has no ledger file at all — a task with no findings behaves exactly as
# it did before this feature existed.
# Asked by _task_ship_gates_v only when the task has a findings file: keep
# its no-file case in step with that precondition.
_task_blocking_findings() {
  local file
  file="$(task_dir "$1")/findings"
  [ -f "$file" ] || return 0
  awk -F '\t' '
    ($2 == "P0" || $2 == "P1") && ($3 == "open" || $3 == "fixed") { print $1, $2, $3, $4 }
  ' "$file"
}

# _task_open_minor_findings <id> — the ledger lines, as they are, of every P2
# or P3 still `open`: what a review left for later, and what `task ship` hands
# to a triage task. `fixed` is not among them: it waits for a re-review, it was
# not left for later. One reader, for ship, `task findings` and the autopilot's
# `end` message alike. Empty when the task has no ledger.
_task_open_minor_findings() {
  local file
  file="$(task_dir "$1")/findings"
  [ -f "$file" ] || return 0
  awk -F '\t' '($2 == "P2" || $2 == "P3") && $3 == "open"' "$file"
}

# _task_gate_blocking_message <id> <blocking-lines> — the refusal text for a
# gate that found <blocking-lines> (as _task_blocking_findings prints them)
# non-empty: names every blocking finding and how to clear one (design §4).
_task_gate_blocking_message() {
  local id="$1" blocking="$2" n names="" sep="" first_fid="" line
  n=$(_task_count_lines "$blocking")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    names="$names$sep$line"
    sep="; "
    [ -n "$first_fid" ] || first_fid=${line%% *}
  done < <(printf '%s\n' "$blocking")
  if [ "$n" -eq 1 ]; then
    printf '%s blocking finding (%s); fix it and have a re-review close it (jig task finding set %s %s closed), or dismiss it with the human'"'"'s yes (jig task finding set %s %s dismissed --reason <text>)' \
      "$n" "$names" "$id" "$first_fid" "$id" "$first_fid"
  else
    printf '%s blocking findings (%s); fix each and have a re-review close it (jig task finding set %s <F-id> closed), or dismiss it with the human'"'"'s yes (jig task finding set %s <F-id> dismissed --reason <text>)' \
      "$n" "$names" "$id" "$id"
  fi
}

# jig task finding add|set — dispatches to task_finding_add / task_finding_set.
task_finding() {
  jig_require_init
  local action="${1:-}"
  [ $# -gt 0 ] && shift
  case "$action" in
    add) task_finding_add "$@" ;;
    set) task_finding_set "$@" ;;
    *) jig_die "$(_task_usage finding)" ;;
  esac
}

# task_finding_add <id> --severity P0|P1|P2|P3 --where <path[:line]|->
# --summary <text> — append a finding in status `open`, printing its new id
# (F<n>) on stdout.
task_finding_add() {
  [ $# -ge 1 ] || jig_die "$(_task_usage finding)"
  local id="$1"
  shift
  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task finding add"

  local severity="" where="" summary="" has_severity=0 has_where=0 has_summary=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --severity)
        [ $# -ge 2 ] || jig_die "task finding add: --severity requires a value"
        severity="$2"; has_severity=1; shift 2 ;;
      --where)
        [ $# -ge 2 ] || jig_die "task finding add: --where requires a value"
        where="$2"; has_where=1; shift 2 ;;
      --summary)
        [ $# -ge 2 ] || jig_die "task finding add: --summary requires a value"
        summary="$2"; has_summary=1; shift 2 ;;
      *) jig_die "task finding add: unknown argument: $1" ;;
    esac
  done
  [ "$has_severity" -eq 1 ] || jig_die "task finding add: --severity is required"
  [ "$has_where" -eq 1 ] || jig_die "task finding add: --where is required"
  [ "$has_summary" -eq 1 ] || jig_die "task finding add: --summary is required"

  _task_valid_severity "$severity" || jig_die "task finding add: invalid severity: $severity (expected P0|P1|P2|P3)"
  [ -n "$summary" ] || jig_die "task finding add: --summary must not be empty"
  _task_finding_valid_field "$where" || jig_die "task finding add: --where must be a single line with no tab"
  _task_finding_valid_field "$summary" || jig_die "task finding add: --summary must be a single line with no tab"

  local file fid tmp
  file="$dir/findings"
  fid=$(_task_finding_next_id "$file")
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  if [ -f "$file" ]; then
    cp "$file" "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\topen\t%s\t%s\t%s\t\n' "$fid" "$severity" "$where" "$summary" "$(jig_today)" >> "$tmp"
  mv "$tmp" "$file"
  jig_record_changed

  printf '%s\n' "$fid"
}

# task_finding_set <id> <F-id> open|fixed|closed|dismissed [--reason <text>]
# — rewrite one ledger line's status (and, for dismissed, its reason).
# `closed` and `dismissed` are final except for a return to `open`
# (regression, design §2); every other listed transition is allowed.
task_finding_set() {
  [ $# -ge 3 ] || jig_die "$(_task_usage finding)"
  local id="$1" fid="$2" new_status="$3"
  shift 3
  local reason="" has_reason=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task finding set: --reason requires a value"
        reason="$2"; has_reason=1; shift 2 ;;
      *) jig_die "task finding set: unknown argument: $1" ;;
    esac
  done

  local dir file
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task finding set"
  file="$dir/findings"
  [ -f "$file" ] || jig_die "task finding set: no findings recorded for task: $id"

  _task_valid_finding_status "$new_status" \
    || jig_die "task finding set: invalid status: $new_status (expected open|fixed|closed|dismissed)"

  if [ "$new_status" = dismissed ]; then
    if [ "$has_reason" -eq 0 ] || [ -z "$reason" ]; then
      jig_die "task finding set: dismissed requires --reason"
    fi
    _task_finding_valid_field "$reason" || jig_die "task finding set: --reason must be a single line with no tab"
  else
    [ "$has_reason" -eq 0 ] || jig_die "task finding set: --reason is only valid with dismissed"
  fi

  local cur_status
  cur_status=$(JIG_F_ID="$fid" awk -F '\t' '$1 == ENVIRON["JIG_F_ID"] { print $3; found = 1 } END { if (!found) exit 1 }' "$file") \
    || jig_die "task finding set: unknown finding: $fid"

  case "$cur_status" in
    closed | dismissed)
      [ "$new_status" = open ] \
        || jig_die "task finding set: $fid is $cur_status; only \`open\` follows it (regression)"
      ;;
  esac

  local tmp today
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  today=$(jig_today)
  # Values reach awk through the environment, not `-v`: awk expands escape
  # sequences in a `-v` value, so a reason spelling a literal backslash-t
  # would be written as a tab and split the record the check above allowed.
  JIG_F_ID="$fid" JIG_F_STATUS="$new_status" JIG_F_TODAY="$today" JIG_F_REASON="$reason" \
    awk -F '\t' -v OFS='\t' '
      $1 == ENVIRON["JIG_F_ID"] {
        $3 = ENVIRON["JIG_F_STATUS"]; $6 = ENVIRON["JIG_F_TODAY"]; $7 = ENVIRON["JIG_F_REASON"]
      }
      { print }
    ' "$file" > "$tmp"
  mv "$tmp" "$file"
  jig_record_changed
}

# jig task findings <id> [--blocking] — a table of every recorded finding,
# then `blocking: <n>`. --blocking prints only the blocking lines and sets
# the exit code a script or skill can act on directly: 1 when n > 0, 0
# otherwise (mirroring `context guard`). A task with no ledger file at all:
# `no findings`, `blocking: 0`, exit 0.
task_findings() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage findings)"
  local id="$1" blocking_only=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --blocking) blocking_only=1; shift ;;
      *) jig_die "task findings: unknown argument: $1" ;;
    esac
  done

  local dir file blocking bcount
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task findings: unknown task: $id"
  file="$dir/findings"

  blocking=$(_task_blocking_findings "$id")
  bcount=$(_task_count_lines "$blocking")

  if [ "$blocking_only" -eq 1 ]; then
    [ "$bcount" -eq 0 ] || printf '%s\n' "$blocking"
    printf 'blocking: %s\n' "$bcount"
    if [ "$bcount" -eq 0 ]; then
      return 0
    else
      return 1
    fi
  fi

  if [ ! -f "$file" ]; then
    printf 'no findings\n'
  else
    awk -F '\t' '{
      line = $1" "$2" "$3" "$4" "$5" "$6
      if ($7 != "") line = line" reason="$7
      print line
    }' "$file"
  fi
  # Where the open P2/P3 went, once a ship handed them over: the ledger keeps
  # them `open`, since the review's receipt pins it.
  local triage open
  triage=$(task_state_get "$id" triage_task)
  if [ -n "$triage" ]; then
    open=$(_task_open_minor_findings "$id")
    [ -z "$open" ] || printf 'handed to %s: %s open P2/P3\n' "$triage" "$(_task_count_lines "$open")"
  fi
  printf 'blocking: %s\n' "$bcount"
  return 0
}

# --- review receipt (design.md, review-receipt) --------------------------------
#
# `.ai/workspace/tasks/<id>/receipt` — gitignored workspace file, flat
# `key: value`, one review's worth of state (design.md §1): `stage`,
# `reviewed_at`, `tree` (a git tree id — everything `git add -A` would stage
# from the project root, except `.ai/knowledge/` and `.ai/specs/`, which
# consolidation writes after review), `base_commit` and `head` (read by
# people, not compared), `design` (a hash of the approved design document(s))
# and `findings` (a hash of the findings ledger at review time). Written
# atomically (tmp.$$ then mv), like every other workspace file here.
#
# Pins the reviewed tree's *content*, not a commit: review most often runs
# against an uncommitted working tree (agent.git: none), where HEAD is the
# base, not what was reviewed, and a commit made after review (by hand or
# `task ship`) must not by itself make the receipt stale.

# _task_review_dir <id> — the checkout that holds <id>'s working tree: the
# one git lists with the task's branch checked out, this checkout or a task
# worktree (ADR-0029). A task with no branch of its own answers this
# checkout. Non-zero when the branch is checked out nowhere: its working tree
# cannot be read, and fingerprinting whatever this checkout holds instead
# would pin, or check, the wrong change.
_task_review_dir() {
  local branch dir
  branch=$(task_state_get "$1" branch)
  if [ -z "$branch" ] || [ "$branch" = "$(_task_current_branch)" ]; then
    printf '%s\n' "$JIG_PROJECT"
    return 0
  fi
  dir=$(_task_worktree_for "$branch" "$(_task_worktrees)")
  [ -n "$dir" ] || return 1
  printf '%s\n' "$dir"
}

# _task_review_tree <dir> [--all] — the git tree id of everything `git add -A`
# would stage right now in the checkout <dir>, minus `.ai/knowledge/` and
# `.ai/specs/` (with `--all`, minus nothing: the task's own knowledge edits are
# then visible to _task_receipt_context_hash). Computed through a temporary index so the real one is never
# touched: every git call below is pointed at a throwaway `GIT_INDEX_FILE`,
# cleaned up on every return path rather than through an EXIT trap, because
# this function can run many times in one process — once per task with a
# receipt, from `jig status` — and a single process-wide trap variable (the
# convention `task_ship`'s PR body file uses) would only remember the last one.
#
# A repository with no commits yet has no HEAD to read: `read-tree` is
# skipped in that case rather than treated as a failure, and the temporary
# index simply starts empty (a missing GIT_INDEX_FILE reads as one).
_task_review_tree() {
  local dir="$1" all="${2:-}" tmp tree
  tmp=$(mktemp "${TMPDIR:-/tmp}/jig-task-review-tree.XXXXXX") || return 1
  jig_cleanup_add "$tmp"
  rm -f "$tmp"

  if git -C "$dir" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    if ! GIT_INDEX_FILE="$tmp" git -C "$dir" read-tree HEAD 2>/dev/null; then
      rm -f "$tmp"
      return 1
    fi
  fi
  if ! GIT_INDEX_FILE="$tmp" git -C "$dir" add -A 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if [ "$all" != --all ]; then
    GIT_INDEX_FILE="$tmp" git -C "$dir" rm -r -q --cached --ignore-unmatch \
      -- "$JIG_AI_DIR/knowledge" "$JIG_AI_DIR/specs" >/dev/null 2>&1 || true
  fi
  tree=$(GIT_INDEX_FILE="$tmp" git -C "$dir" write-tree 2>/dev/null) || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s\n' "$tree"
}

# _task_review_merge_base <id> <dir> — the commit the task's own change is
# measured from: the merge base of the task's base branch (judged as
# jig_base_ref judges it, origin first) and the HEAD of the checkout <dir>.
# A merge of the base into the task's branch moves the merge base with it, so
# what the base brought in never counts as the task's change. Without a base
# ref the `base_commit` the task recorded at start answers; without that,
# nothing, and the callers fall back to pinning the whole tree.
_task_review_merge_base() {
  local id="$1" dir="$2" ref mb
  ref=$(jig_base_ref "$(jig_task_base "$id")")
  if [ -n "$ref" ] && mb=$(git -C "$dir" merge-base "$ref" HEAD 2>/dev/null); then
    printf '%s\n' "$mb"
    return 0
  fi
  mb=$(task_state_get "$id" base_commit)
  if [ -n "$mb" ] && git -C "$dir" rev-parse --verify --quiet "$mb^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "$mb"
    return 0
  fi
  return 1
}

# _task_review_changed_files <id> <dir> — the repo-relative paths the task's
# own change touches in the checkout <dir> (merge-base aware, untracked files
# included, `.ai/knowledge/` and `.ai/specs/` left out), one per line. Fails
# when there is no merge base to measure from.
_task_review_changed_files() {
  local id="$1" dir="$2" mb tree
  mb=$(_task_review_merge_base "$id" "$dir") || return 1
  tree=$(_task_review_tree "$dir") || return 1
  git -C "$dir" diff-tree -r --no-renames --name-only "$mb" "$tree" \
    -- . ":(exclude)$JIG_AI_DIR/knowledge" ":(exclude)$JIG_AI_DIR/specs" 2>/dev/null \
    | LC_ALL=C sort -u
}

# _task_receipt_diff_hash <id> <dir> — the receipt's `diff` field: the hash of
# the task's own change against its merge base, by content (the raw diff-tree
# listing carries both blob ids of every path). The same change gives the same
# value whatever the base has moved on to; a change to a file the task touches
# gives another. `tree:<id>` — the whole tree, the old pin — when there is no
# merge base: stricter, never softer.
_task_receipt_diff_hash() {
  local id="$1" dir="$2" mb tree
  tree=$(_task_review_tree "$dir") || return 1
  if ! mb=$(_task_review_merge_base "$id" "$dir"); then
    printf 'tree:%s\n' "$tree"
    return 0
  fi
  git -C "$dir" diff-tree -r --no-renames "$mb" "$tree" \
    -- . ":(exclude)$JIG_AI_DIR/knowledge" ":(exclude)$JIG_AI_DIR/specs" 2>/dev/null \
    | git hash-object --stdin
}

# _task_receipt_context_hash <id> <dir> — the receipt's `context` field: the
# knowledge the review was done against, by content. The documents are what
# `jig context` resolves for the files of the task's change, run in the
# checkout <dir> with the task's domains (the global documents included, the
# task's workspace left out). A document the task edited itself counts at the
# content it had at the merge base, as a checkout would hold it — what the
# review read before the task touched it — and one the task added counts not
# at all: consolidation writes knowledge after the review (ADR-0030), and those
# edits are the task's own change, so they must neither stale the receipt nor
# drop a line out of it. The value hashes "<path> <content hash>" lines, so a
# document added, removed or edited by anyone else — a base merged in moves the
# merge base — changes it. Fails when it cannot be computed; "-" when there is
# no merge base to find the task's files from.
_task_receipt_context_hash() {
  local id="$1" dir="$2" lines
  _task_review_merge_base "$id" "$dir" >/dev/null || { printf -- '-\n'; return 0; }
  lines=$(_task_receipt_context_lines "$id" "$dir") || return 1
  if [ -n "$lines" ]; then
    printf '%s\n' "$lines"
  fi | git hash-object --stdin
}

# _task_receipt_context_lines <id> <dir> [--write] — the "<path> <content
# hash>" lines _task_receipt_context_hash hashes, sorted, one per document the
# review relied on; nothing when there is no merge base. The receipt keeps
# them as `context_doc:` lines so `--since-review` can tell which document
# moved (adr-20261029-a-global-knowledge-edit-narrows-a-re-review). With
# `--write` each document's content is also stored as a blob — the same id
# jig_hash gives, `--no-filters` — so the re-review can be shown what changed
# in it; the gates call this without `--write` and write nothing.
_task_receipt_context_lines() {
  local id="$1" dir="$2" write="${3:-}" mb files full own domains matched path hash lines=""
  mb=$(_task_review_merge_base "$id" "$dir") || return 0
  files=$(_task_review_changed_files "$id" "$dir") || return 1
  full=$(_task_review_tree "$dir" --all) || return 1
  own=$(git -C "$dir" diff-tree -r --no-renames --name-only "$mb" "$full" \
    -- "$JIG_AI_DIR/knowledge" 2>/dev/null) || own=""
  domains=$(task_state_get "$id" domains | tr ',' ' ')
  # A process, not a sourced library: one command library never sources
  # another (ARCHITECTURE.md, Scripts layout). `--no-task` keeps the task's
  # workspace out; its domains are passed explicitly. It is a re-entry, not a
  # session, so it carries JIG_INTERNAL_REDRAW and leaves no checkout record in
  # <dir> (checkout.sh, jig_checkout_record): a receipt check — from `task
  # list --json` too — reads about the work there, it does not do it.
  matched=$(printf '%s\n' "$files" | (cd "$dir" && JIG_INTERNAL_REDRAW=1 "$JIG_SELF" context --no-task --files - \
    ${domains:+--domains "$(printf '%s' "$domains" | tr ' ' ',')"} --format paths) 2>/dev/null) || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if jig_has_line "$path" "$own"; then
      git -C "$dir" cat-file -e "$mb:$path" 2>/dev/null || continue
      if [ "$write" = --write ]; then
        hash=$(git -C "$dir" cat-file --filters "$mb:$path" | git -C "$dir" hash-object -w --no-filters --stdin) || return 1
      else
        hash=$(git -C "$dir" cat-file --filters "$mb:$path" | jig_hash_stdin)
      fi
    elif [ -f "$dir/$path" ]; then
      if [ "$write" = --write ]; then
        hash=$(git -C "$dir" hash-object -w --no-filters -- "$path") || return 1
      else
        hash=$(jig_hash "$dir/$path")
      fi
    else
      hash=-
    fi
    lines="$lines$path $hash
"
  done < <(printf '%s\n' "$matched")
  printf '%s' "$lines" | LC_ALL=C sort
}

# _task_receipt_design_hash <id> — the receipt's `design` field: the hash of
# design.md, and for a T4 task also spec.md and alternatives.md when they
# exist, combined by hashing their own "<name> <hash>" lines together so any
# one of the documents changing changes the combined value too. "-" when
# design.md itself is absent — nothing has been approved yet to pin.
_task_receipt_design_hash() {
  local id="$1" dir class lines file
  dir=$(task_dir "$id")
  [ -f "$dir/design.md" ] || { printf -- '-\n'; return 0; }
  lines="design.md $(jig_hash "$dir/design.md")"
  class=$(task_state_get "$id" class)
  if [ "$class" = T4 ]; then
    for file in spec.md alternatives.md; do
      [ -f "$dir/$file" ] || continue
      lines="$lines
$file $(jig_hash "$dir/$file")"
    done
  fi
  printf '%s\n' "$lines" | git hash-object --stdin
}

# _task_receipt_findings_hash <id> — the receipt's `findings` field: the hash
# of the findings ledger file, or "-" when the task has none. Any later edit
# to the ledger — including the author closing their own finding — changes
# this and makes the receipt stale (design.md §3: the ledger tie-in).
_task_receipt_findings_hash() {
  local file
  file="$(task_dir "$1")/findings"
  if [ -f "$file" ]; then
    jig_hash "$file"
  else
    printf -- '-\n'
  fi
}

# _task_receipt_get <id> <key> — the value of <key> from the task's receipt
# file, or nothing when the task has no receipt or the key is absent.
# Companion to task_state_get, same shape, different file.
_task_receipt_get() {
  local id="$1" key="$2" file
  file="$(task_dir "$id")/receipt"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -n 1
}

# _task_receipt_changed <id> — "diff", "context", "design", "findings", any
# combination joined by ", ", or empty, for the parts of an existing receipt
# that no longer match the task's current state; empty (not an error) when the
# task has no receipt at all. `diff` is the task's own change against its base,
# `context` the knowledge the review relied on (ADR
# 20261003-receipt-pins-what-the-review-read); a receipt written before they
# existed has no such keys and is compared by `tree` until it is rewritten.
# One function decides staleness so `--check`, the three completion gates and
# `jig status` cannot disagree about what "stale" means (ARCHITECTURE.md,
# Scripts layout: a reporting command consumes a peer's answer, never
# recomputes it). With a second argument `cheap`, the `context` part is not
# computed — it costs a `jig context` process per task — so the answer says
# only what is certainly changed, never that the knowledge is unchanged.
_task_receipt_changed() {
  local id="$1" mode="${2:-}" file changed="" sep="" cur dir=""
  file="$(task_dir "$id")/receipt"
  [ -f "$file" ] || return 0

  # A checkout that cannot be read — the branch checked out nowhere — counts as
  # changed: the gate must not pass on a change it could not look at.
  dir=$(_task_review_dir "$id") || dir=""
  if [ -z "$(_task_receipt_get "$id" diff)" ]; then
    cur=""
    if [ -n "$dir" ]; then
      cur=$(_task_review_tree "$dir") || cur=""
    fi
    if [ "$cur" != "$(_task_receipt_get "$id" tree)" ]; then
      changed="$changed${sep}tree"
      sep=", "
    fi
  else
    cur=""
    if [ -n "$dir" ]; then
      cur=$(_task_receipt_diff_hash "$id" "$dir") || cur=""
    fi
    if [ "$cur" != "$(_task_receipt_get "$id" diff)" ]; then
      changed="$changed${sep}diff"
      sep=", "
    fi
    if [ "$mode" != cheap ]; then
      cur=""
      if [ -n "$dir" ]; then
        cur=$(_task_receipt_context_hash "$id" "$dir") || cur=""
      fi
      if [ "$cur" != "$(_task_receipt_get "$id" context)" ]; then
        changed="$changed${sep}context"
        sep=", "
      fi
    fi
  fi
  cur=$(_task_receipt_design_hash "$id")
  if [ "$cur" != "$(_task_receipt_get "$id" design)" ]; then
    changed="$changed${sep}design"
    sep=", "
  fi
  cur=$(_task_receipt_findings_hash "$id")
  if [ "$cur" != "$(_task_receipt_get "$id" findings)" ]; then
    changed="$changed${sep}findings"
    sep=", "
  fi
  printf '%s\n' "$changed"
}

# _task_receipt_gloss <changed> — one clause saying what each reason in the
# list _task_receipt_changed returned means, so a person can tell the task's
# own work moving from the knowledge under it moving.
_task_receipt_gloss() {
  local changed="$1" out="" sep="" reason
  for reason in tree diff context design findings; do
    case ", $changed, " in *", $reason, "*) ;; *) continue ;; esac
    case "$reason" in
      tree) out="$out${sep}tree: the working tree" ;;
      diff) out="$out${sep}diff: the task's own change" ;;
      context) out="$out${sep}context: the knowledge the review relied on, not the code" ;;
      design) out="$out${sep}design: the approved design" ;;
      findings) out="$out${sep}findings: the ledger" ;;
    esac
    sep="; "
  done
  printf '%s\n' "$out"
}

# _task_receipt_gate_message <id> — empty when the task's review receipt
# needs no attention; otherwise the refusal text (the caller still prefixes
# it with "<command>: ", same as _task_gate_blocking_message) for a stale
# receipt, or for a T4 task with no receipt at all (design.md §3). Read by
# task_set's two gates and task_ship's recheck — the same three call sites
# _task_blocking_findings has, right after it.
# Asked by _task_ship_gates_v only when the task has a receipt or is T4:
# keep its no-receipt case in step with that precondition.
_task_receipt_gate_message() {
  local id="$1" changed class
  if [ -f "$(task_dir "$id")/receipt" ]; then
    changed=$(_task_receipt_changed "$id")
    [ -n "$changed" ] || return 0
    printf 'review is stale: code changed since review on %s (%s; %s); re-review and run: jig task receipt %s --stage %s' \
      "$(_task_receipt_get "$id" reviewed_at)" "$changed" "$(_task_receipt_gloss "$changed")" "$id" "$(_task_receipt_get "$id" stage)"
    return 0
  fi
  class=$(task_state_get "$id" class)
  if [ "$class" = T4 ]; then
    printf 'T4 needs a review receipt; run the independent review, then: jig task receipt %s --stage review' "$id"
  fi
  return 0
}

# jig task receipt <id> --stage review|architecture-review — write the
# receipt and print it; jig task receipt <id> --check — report whether it
# still matches.
task_receipt() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage receipt)"
  local id="$1"
  shift
  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_die "task receipt: unknown task: $id"

  local stage="" has_stage=0 check=0 since=0 format="" has_format=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --stage)
        [ $# -ge 2 ] || jig_die "task receipt: --stage requires a value"
        stage="$2"; has_stage=1; shift 2 ;;
      --check) check=1; shift ;;
      --since-review) since=1; shift ;;
      --format)
        [ $# -ge 2 ] || jig_die "task receipt: --format requires a value"
        format="$2"; has_format=1; shift 2 ;;
      *) jig_die "task receipt: unknown argument: $1" ;;
    esac
  done
  [ "$check" -eq 0 ] || [ "$has_stage" -eq 0 ] || jig_die "task receipt: --stage and --check are mutually exclusive"
  if [ "$since" -eq 1 ]; then
    if [ "$check" -eq 1 ] || [ "$has_stage" -eq 1 ]; then
      jig_die "task receipt: --since-review takes no --stage or --check"
    fi
    case "${format:-report}" in report | paths) ;; *) jig_die "task receipt: invalid format: $format" ;; esac
    _task_receipt_since_review "$id" "${format:-report}"
    return
  fi
  [ "$has_format" -eq 0 ] || jig_die "task receipt: --format goes with --since-review"

  if [ "$check" -eq 1 ]; then
    task_receipt_check "$id"
    return
  fi

  [ "$has_stage" -eq 1 ] || jig_die "$(_task_usage receipt)"
  case "$stage" in
    review | architecture-review) ;;
    *) jig_die "task receipt: invalid stage: $stage (expected review|architecture-review)" ;;
  esac

  task_receipt_write "$id" "$stage"
}

# task_receipt_write <id> <stage> — write the task's receipt (design.md §1)
# and print it. One receipt per task: a repeated call, most often a
# re-review, replaces it outright — the stage most recently written wins, and
# nothing reads the one it overwrote.
task_receipt_write() {
  local id="$1" stage="$2" dir tree base_commit head diff context design findings file tmp merge_base
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task receipt"
  local review_dir
  review_dir=$(_task_review_dir "$id") \
    || jig_die "task receipt: $(task_state_get "$id" branch) is not checked out in any worktree; review the task where its branch is"
  tree=$(_task_review_tree "$review_dir") || jig_die "task receipt: could not read the working tree"
  diff=$(_task_receipt_diff_hash "$id" "$review_dir") || jig_die "task receipt: could not read the task's change"
  context=$(_task_receipt_context_hash "$id" "$review_dir") || jig_die "task receipt: could not resolve the knowledge for the task's change"
  # Which documents `context` hashed, with their content stored, so a re-review
  # can tell a global document moving from the set under the task's files moving
  # (adr-20261029-a-global-knowledge-edit-narrows-a-re-review). Never compared.
  local context_docs
  context_docs=$(_task_receipt_context_lines "$id" "$review_dir" --write) \
    || jig_die "task receipt: could not resolve the knowledge for the task's change"
  # What `diff` was measured from: read by `task receipt --since-review`, never
  # compared (adr-20261019-a-re-review-reads-what-changed-since-review).
  merge_base=$(_task_review_merge_base "$id" "$review_dir") || merge_base=""
  base_commit=$(task_state_get "$id" base_commit)
  head=$(git -C "$review_dir" rev-parse --verify --quiet HEAD 2>/dev/null) || head=""
  design=$(_task_receipt_design_hash "$id")
  findings=$(_task_receipt_findings_hash "$id")
  # Every stage a receipt of this task was ever written for, so a re-review
  # under another stage does not erase that the first one happened (the route
  # evidence, adr-20261004-a-route-stage-is-proven-by-its-record). A receipt
  # from before the list counts its own `stage:`.
  local stages
  stages=$(_task_receipt_get "$id" stages)
  [ -n "$stages" ] || stages=$(_task_receipt_get "$id" stage)
  stages=$(printf '%s,%s\n' "$stages" "$stage" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)

  file="$dir/receipt"
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  {
    printf 'stage: %s\n' "$stage"
    printf 'stages: %s\n' "$stages"
    printf 'reviewed_at: %s\n' "$(jig_today)"
    printf 'tree: %s\n' "$tree"
    printf 'diff: %s\n' "$diff"
    printf 'context: %s\n' "$context"
    printf 'merge_base: %s\n' "$merge_base"
    printf 'base_commit: %s\n' "$base_commit"
    printf 'head: %s\n' "$head"
    printf 'design: %s\n' "$design"
    printf 'findings: %s\n' "$findings"
    [ -z "$context_docs" ] || printf '%s\n' "$context_docs" | sed 's/^/context_doc: /'
  } > "$tmp"
  mv "$tmp" "$file"
  jig_record_changed
  cat "$file"
}

# task_receipt_check <id> — `receipt: current|stale (...)|none`, exit 1 for
# stale and for a T4 task with none at all (design.md §3), exit 0 otherwise.
# With a second argument `cheap` (what `jig status` asks) the knowledge the
# review read is not resolved: a receipt whose diff, design and findings still
# match answers `not checked (knowledge not resolved)`, never `current`, and
# stale only when something cheap already moved. The gates ask without it.
task_receipt_check() {
  local id="$1" mode="${2:-}" file changed class
  task_dir_v file "$id"
  file="$file/receipt"
  if [ ! -f "$file" ]; then
    task_state_var class "$id" class
    if [ "$class" = T4 ]; then
      printf 'receipt: none (required for T4)\n'
      return 1
    fi
    printf 'receipt: none\n'
    return 0
  fi

  changed=$(_task_receipt_changed "$id" "$mode")
  if [ -z "$changed" ]; then
    if [ "$mode" = cheap ] && [ -n "$(_task_receipt_get "$id" diff)" ]; then
      printf 'receipt: not checked (knowledge not resolved; jig task receipt %s --check)\n' "$id"
      return 0
    fi
    printf 'receipt: current\n'
    return 0
  fi
  printf 'receipt: stale (%s, reviewed %s)\n' "$changed" "$(_task_receipt_get "$id" reviewed_at)"
  return 1
}

# _task_receipt_since_review <id> <report|paths> — what the task's own change
# did since its receipt was written: the interdiff a re-review reads instead of
# the whole change (adr-20261019-a-re-review-reads-what-changed-since-review).
# It narrows the re-review only; no gate reads it, and the receipt still goes
# stale on any change. The reviewed tree is diffed against the current review
# tree, limited to the files of the task's change then (receipt `merge_base`
# to receipt `tree`) and now, so what a merge of the base brought into files
# the task never touched is left out.
#
# Exit 0 with `re-review: narrow (...)` and the interdiff when only the task's
# diff, the ledger or a global knowledge document moved — then the diff of each
# such document follows the interdiff; exit 0 with `re-review: none` when the
# receipt is current; exit 1 with `re-review: full — <why>` when the re-review
# must read everything: no receipt, the design moved, the documents resolved for
# the task's files changed as a set or in one that is not global
# (_task_since_review_knowledge), or what the receipt pinned can no longer be
# read. With `paths` only the interdiff's code files are printed, and the
# verdict of none or full goes to stderr, so the list can be piped into
# `jig context resolve`.
_task_receipt_since_review() {
  local id="$1" format="$2" changed dir old_tree old_mb new_tree old_files new_files paths diffed files="" path
  if [ ! -f "$(task_dir "$id")/receipt" ]; then
    _task_since_review_full "$format" "$id has no review receipt"
    return 1
  fi
  dir=$(_task_review_dir "$id") || {
    _task_since_review_full "$format" "$(task_state_get "$id" branch) is not checked out in any worktree"
    return 1
  }
  changed=$(_task_receipt_changed "$id")
  if [ -z "$changed" ]; then
    if [ "$format" = paths ]; then
      printf 're-review: none — the receipt is current\n' >&2
    else
      printf 're-review: none — the receipt is current\n'
    fi
    return 0
  fi
  case ", $changed, " in
    *", design, "*) _task_since_review_full "$format" "the approved design changed since the review"; return 1 ;;
    *", tree, "*) _task_since_review_full "$format" "the receipt predates the task's own diff; it pins the whole tree"; return 1 ;;
  esac
  _TASK_SR_KNOWLEDGE=""
  case ", $changed, " in
    *", context, "*)
      if ! _task_since_review_knowledge "$id" "$dir"; then
        _task_since_review_full "$format" "$_TASK_SR_WHY"
        return 1
      fi
      ;;
  esac
  old_tree=$(_task_receipt_get "$id" tree)
  old_mb=$(_task_receipt_get "$id" merge_base)
  if [ -z "$old_mb" ]; then
    _task_since_review_full "$format" "the receipt does not record what its diff was measured from"
    return 1
  fi
  if ! git -C "$dir" cat-file -e "$old_tree^{tree}" 2>/dev/null \
    || ! git -C "$dir" cat-file -e "$old_mb^{commit}" 2>/dev/null; then
    _task_since_review_full "$format" "what the review read is no longer in the repository"
    return 1
  fi
  new_tree=$(_task_review_tree "$dir") || { _task_since_review_full "$format" "could not read the working tree"; return 1; }
  old_files=$(git -C "$dir" diff-tree -r --no-renames --name-only "$old_mb" "$old_tree" \
    -- . ":(exclude)$JIG_AI_DIR/knowledge" ":(exclude)$JIG_AI_DIR/specs" 2>/dev/null) \
    || { _task_since_review_full "$format" "could not read the reviewed change"; return 1; }
  new_files=$(_task_review_changed_files "$id" "$dir") \
    || { _task_since_review_full "$format" "could not read the task's change"; return 1; }
  paths=$(printf '%s\n%s\n' "$old_files" "$new_files" | sed '/^$/d' | LC_ALL=C sort -u)
  diffed=$(git -C "$dir" diff-tree -r --no-renames --name-only "$old_tree" "$new_tree" 2>/dev/null) \
    || { _task_since_review_full "$format" "could not compare with the reviewed tree"; return 1; }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    jig_has_line "$path" "$paths" || continue
    files="$files$path
"
  done < <(printf '%s\n' "$diffed")
  if [ "$format" = paths ]; then
    printf '%s' "$files"
    return 0
  fi
  printf 're-review: narrow (%s)\n' "$changed"
  printf 'task: %s\nreviewed: %s (tree %s)\n' "$id" "$(_task_receipt_get "$id" reviewed_at)" "$old_tree"
  printf 'changed since review: %s paths\n' "$(printf '%s' "$files" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ -n "$files" ]; then
    printf '%s' "$files" | tr '\n' '\0' | (cd "$dir" && xargs -0 git --literal-pathspecs diff --no-color --no-ext-diff "$old_tree" "$new_tree" --)
  fi
  [ -n "$_TASK_SR_KNOWLEDGE" ] || return 0
  printf 'knowledge changed since review: %s documents\n' "$(printf '%s' "$_TASK_SR_KNOWLEDGE" | sed '/^$/d' | wc -l | tr -d ' ')"
  local old_hash new_hash
  while IFS=$'\t' read -r path old_hash new_hash; do
    [ -n "$path" ] || continue
    printf 'knowledge: %s\n' "$path"
    git -C "$dir" diff --no-color --no-ext-diff "$old_hash" "$new_hash"
  done < <(printf '%s' "$_TASK_SR_KNOWLEDGE")
}

# _task_since_review_knowledge <id> <dir> — whether a re-review may stay narrow
# although `context` moved (adr-20261029-a-global-knowledge-edit-narrows-a-re-review).
# It may when the same documents resolve for the task's files as at the review
# and only global ones (jig_knowledge_is_global) changed: those resolve for any
# file, so an edit to them is most often another task's consolidation, and the
# re-reviewer is shown it. Sets _TASK_SR_KNOWLEDGE to "<path>\t<old>\t<new>"
# lines, one per changed global document, and returns 0; otherwise sets
# _TASK_SR_WHY to the reason the re-review must be full and returns 1 — a
# document that newly resolves or no longer does, a changed document that
# resolves through the task's paths or domains, a receipt that does not list
# its documents, or content the review read that is no longer stored.
_task_since_review_knowledge() {
  local id="$1" dir="$2" old new old_paths new_paths path hash old_hash moved=""
  _TASK_SR_KNOWLEDGE=""
  _TASK_SR_WHY="the knowledge the review relied on changed"
  old=$(sed -n 's/^context_doc:[[:space:]]*//p' "$(task_dir "$id")/receipt")
  if [ -z "$old" ]; then
    _TASK_SR_WHY="the knowledge the review relied on changed, and the receipt does not list which documents it read"
    return 1
  fi
  new=$(_task_receipt_context_lines "$id" "$dir" --write) || {
    _TASK_SR_WHY="could not resolve the knowledge for the task's change"
    return 1
  }
  old_paths=$(printf '%s\n' "$old" | sed 's/ [^ ]*$//' | LC_ALL=C sort -u)
  new_paths=$(printf '%s\n' "$new" | sed '/^$/d' | sed 's/ [^ ]*$//' | LC_ALL=C sort -u)
  if [ "$old_paths" != "$new_paths" ]; then
    path=$(LC_ALL=C comm -3 <(printf '%s\n' "$old_paths") <(printf '%s\n' "$new_paths") | sed 's/^[[:space:]]*//' | sed -n 1p)
    _TASK_SR_WHY="a document resolves for the task's files that did not at the review, or no longer does: $path"
    return 1
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    hash=${path##* }
    path=${path% *}
    old_hash=$(printf '%s\n' "$old" | awk -v p="$path" '!d { h = $NF; sub(/ [^ ]*$/, ""); if ($0 == p) { print h; d = 1 } }')
    [ "$hash" != "$old_hash" ] || continue
    if ! jig_knowledge_is_global "$JIG_PROJECT/$path"; then
      _TASK_SR_WHY="$path, which resolves for the task's files, changed since the review"
      return 1
    fi
    if [ "$hash" = - ] || [ "$old_hash" = - ] \
      || ! git -C "$dir" cat-file -e "$old_hash^{blob}" 2>/dev/null; then
      _TASK_SR_WHY="what the review read in $path is no longer in the repository"
      return 1
    fi
    moved="$moved$(printf '%s\t%s\t%s' "$path" "$old_hash" "$hash")
"
  done < <(printf '%s\n' "$new")
  [ -n "$moved" ] || return 1
  _TASK_SR_KNOWLEDGE=$moved
  return 0
}

# _task_since_review_full <format> <why> — the `re-review: full` verdict of
# _task_receipt_since_review, on stdout for a report and on stderr for paths.
_task_since_review_full() {
  if [ "$1" = paths ]; then
    printf 're-review: full — %s\n' "$2" >&2
  else
    printf 're-review: full — %s\n' "$2"
  fi
}

# --- route depth (adr-20261002-route-depth-is-a-personal-choice) --------------
#
# How much of its class's route a task runs: `full`, or `lean`, which trims
# only what does not change the risk assessment. A task's own `route_depth`
# (`task new --lean`, `task set <id> route_depth`) wins; without one, the
# person's `route.depth` (local-only, config.sh) answers; without that, `full`.
# Nothing that gates — verify, the findings ledger, the receipt, the human
# gate, ship, consolidation, the route evidence (which reads the class's `full`
# route) — reads the depth, which is what keeps `lean` from ever getting under
# them. The answer is computed here and only here: `jig task
# route`, `jig status` and the autopilot report all ask _task_route_depth.

# _task_route_depth <id> [<setting>] — `<depth>\t<source>`, where <source> is
# `task` (the task's own key) or `route.depth` (the person's setting, or its
# default). <setting> is what _task_route_setting printed, so a caller asking
# for many tasks reads the file once.
_task_route_depth() {
  local id="$1" setting
  if [ $# -ge 2 ]; then
    setting="$2"
  else
    setting=$(_task_route_setting)
  fi
  _task_route_depth_of "$(task_state_get "$id" route_depth)" "$setting"
}

# _task_route_depth_of <own> <setting> — the rule itself, on values already
# read: the task's own `route_depth` wins, the setting answers otherwise. A
# caller holding the state row (`jig status`) asks this rather than repeating
# the rule. An invalid value anywhere reads as `full`: a mistake costs process,
# never a stage.
_task_route_depth_of() {
  local line
  _task_route_depth_of_v line "$1" "$2"
  printf '%s\n' "$line"
}

# _task_route_depth_of_v <var> <own> <setting> — the same line into <var>.
_task_route_depth_of_v() {
  if _cfg_route_depth "$2"; then
    printf -v "$1" '%s\ttask' "$2"
  elif _cfg_route_depth "$3"; then
    printf -v "$1" '%s\troute.depth' "$3"
  else
    printf -v "$1" '%s' $'full\troute.depth'
  fi
}

# _task_route_setting — route.depth (jig_route_depth), `full` when invalid.
_task_route_setting() {
  local value
  if value=$(jig_route_depth); then
    printf '%s\n' "$value"
  else
    printf 'full\n'
  fi
}

# _task_route_stages <class> <depth> — the route's stages, comma-separated.
# The one table of routes the scripts hold; the skills name what it prints.
_task_route_stages() {
  case "$1:$2" in
    T0:*) printf 'implement, verify, consolidate\n' ;;
    T1:*) printf 'analyze, implement, verify, consolidate\n' ;;
    T2:lean) printf 'analyze, implement, review, verify, consolidate\n' ;;
    T2:*) printf 'analyze, plan, implement, review, verify, consolidate\n' ;;
    T3:*) printf 'discover, design, human gate, implement, architecture review, verify, consolidate\n' ;;
    T4:*) printf 'discover, specify, alternatives, design, human gate, implement, independent review, verify, consolidate\n' ;;
  esac
}

# _task_route_lean_note <class> — what `lean` changes for <class>, in one line.
_task_route_lean_note() {
  case "$1" in
    T0) printf 'nothing to trim at T0\n' ;;
    T1) printf 'the analysis is a few lines in task.md, not a document of its own\n' ;;
    T2) printf 'the plan is part of the analysis; one review round: P2/P3 stay open and go to the pull request, and a re-review only closes a fixed P0/P1\n' ;;
    T3 | T4) printf 'the gate, the architecture review and verify are unchanged; one review round: P2/P3 stay open and go to the pull request, and a re-review only closes a fixed P0/P1\n' ;;
  esac
}

# _task_executor_freeze <id> <dir> — snapshot each effective executor field at
# task start, including an empty value. The source marker distinguishes an
# empty frozen choice from a pre-start task that still inherits local config.
# A changed clone-local setting cannot redirect a task already in flight.
_task_executor_freeze() {
  local id="$1" dir="$2" key value source
  for key in implement_runtime review_runtime implement_model review_model; do
    value=$(task_state_get "$id" "executor_$key")
    source=task
    if [ -z "$value" ]; then
      value=$(cfg "executor.$key" "")
      source='local config'
      [ -n "$value" ] || source=default
    fi
    _task_rewrite_state "$dir" "executor_$key" "$value"
    _task_rewrite_state "$dir" "executor_${key}_source" "$source"
  done
}

# _task_route_delegates <id> <class> — `executor:` lines for a chosen runtime and
# `delegate:` lines for a chosen in-runtime subagent model, only for stages
# in <class>'s route. Empty settings print nothing. The model is local-only,
# carried as it is written: Jig never interprets or validates it, and no gate
# reads it — delegation changes who does a stage, never the route or its
# records (adr-20261005-jig-names-the-roles-not-the-models). Review covers
# every review stage of a route — review, independent review, architecture
# review — so a class without one (T0, T1) gets no review line.
# The output carries no paths through Git Bash on Windows; the agent owns
# that boundary when it launches an external CLI.
_task_route_delegates() {
  local id="$1" class="$2" model runtime source
  runtime=$(task_state_get "$id" executor_implement_runtime)
  source=$(task_state_get "$id" executor_implement_runtime_source)
  if [ -z "$source" ]; then
    source=task
  fi
  if [ -z "$runtime" ] && [ "$source" = task ]; then
    runtime=$(cfg executor.implement_runtime "")
    source='local config'
  fi
  if [ -n "$runtime" ]; then
    printf 'executor: implement -> %s (executor.implement_runtime; %s)\n' "$runtime" "$source"
    model=$(task_state_get "$id" executor_implement_model)
    source=$(task_state_get "$id" executor_implement_model_source)
    if [ -z "$source" ]; then source=task; fi
    if [ -z "$model" ] && [ "$source" = task ]; then
      model=$(cfg executor.implement_model "")
      source='local config'
    fi
    if [ -n "$model" ]; then
      printf 'executor model: implement -> %s (executor.implement_model; %s)\n' "$model" "$source"
    fi
  fi
  model=$(cfg claude.implement_model "")
  if [ -n "$model" ]; then
    printf 'delegate: implement -> %s (claude.implement_model)\n' "$model"
  fi
  model=$(cfg codex.implement_model "")
  if [ -n "$model" ]; then
    printf 'delegate: implement -> %s (codex.implement_model)\n' "$model"
  fi
  case "$class" in
    T2 | T3 | T4) ;;
    *) return 0 ;;
  esac
  runtime=$(task_state_get "$id" executor_review_runtime)
  source=$(task_state_get "$id" executor_review_runtime_source)
  if [ -z "$source" ]; then source=task; fi
  if [ -z "$runtime" ] && [ "$source" = task ]; then
    runtime=$(cfg executor.review_runtime "")
    source='local config'
  fi
  if [ -n "$runtime" ]; then
    printf 'executor: review -> %s (executor.review_runtime; %s)\n' "$runtime" "$source"
    model=$(task_state_get "$id" executor_review_model)
    source=$(task_state_get "$id" executor_review_model_source)
    if [ -z "$source" ]; then source=task; fi
    if [ -z "$model" ] && [ "$source" = task ]; then
      model=$(cfg executor.review_model "")
      source='local config'
    fi
    if [ -n "$model" ]; then
      printf 'executor model: review -> %s (executor.review_model; %s)\n' "$model" "$source"
    fi
  fi
  model=$(cfg claude.review_model "")
  if [ -n "$model" ]; then
    printf 'delegate: review -> %s (claude.review_model)\n' "$model"
  fi
  model=$(cfg codex.review_model "")
  if [ -n "$model" ]; then
    printf 'delegate: review -> %s (codex.review_model)\n' "$model"
  fi
  return 0
}

# task_route <id> — the task's class, depth and route, for the skills to name.
task_route() {
  jig_require_init
  [ $# -eq 1 ] || jig_die "$(_task_usage route)"
  local id="$1" class depth source
  [ -f "$(task_dir "$id")/state" ] || jig_die "task route: unknown task: $id"
  class=$(task_state_get "$id" class)
  IFS=$'\t' read -r depth source <<EOF
$(_task_route_depth "$id")
EOF
  printf 'class: %s\n' "${class:--}"
  printf 'depth: %s (%s)\n' "$depth" "$source"
  _task_route_setup_line "$id"
  if ! _task_valid_class "$class"; then
    printf 'route: none until the task is classified (jig task set %s class Tn)\n' "$id"
    return 0
  fi
  printf 'route: %s\n' "$(_task_route_stages "$class" "$depth")"
  if [ "$depth" = lean ]; then
    printf 'lean: %s\n' "$(_task_route_lean_note "$class")"
  fi
  printf 'never trimmed: tests on changed files, CI before a merge, consolidation\n'
  _task_autopilot_git_line "$id"
  _task_route_delegates "$id" "$class"
  local from
  from=$(task_state_get "$id" class_lowered_from)
  if [ -n "$from" ]; then
    printf 'lowered: from %s: %s\n' "$from" "$(task_state_get "$id" class_lowered_reason)"
  fi
}

# _task_route_setup_line <id> — a line when the project's `worktree.setup`
# did not finish the task's worktree; nothing when it did or never ran. Shown
# by `task route` because that is what a coordinator reads after a start
# (adr-20261026-a-worktree-is-finished-by-the-projects-command).
_task_route_setup_line() {
  local setup
  setup=$(task_state_get "$1" setup)
  case "$setup" in
    '' | ok) ;;
    *) printf 'setup: %s — the worktree is not finished; fix worktree.setup and run jig task bootstrap %s\n' "$setup" "$1" ;;
  esac
}

# --- route evidence (adr-20261004-a-route-stage-is-proven-by-its-record) -------
#
# A class decides the process by mechanics, not by prose: the stages of the
# class's route (_task_route_stages, `full`) that leave a record
# must have left it before the completion gates pass. Only records that resist
# ritual count (convention-required-records): the human gate's approval pinned
# to the current design, a receipt the reviewer computed, verify's own
# `status ready`, and the design documents the gate pinned. A stage whose only
# trace is prose the actor writes for itself — discover, analyze, plan — or
# the diff — implement — is not asked for, and neither is the autopilot
# journal, which the actor writes about itself under names of its choosing.
#
# The depth is not read: the records asked for are the class's `full` route's,
# so a person's local `route.depth` can never loosen a gate. Lean trims only
# stages that leave no record (the plan), so a lean run is asked the same
# records; a depth that ever trimmed a recorded stage would be refused here,
# not let through.
#
# A task filed before this check — no `route_evidence: required` in its state,
# which `jig task new` writes — is judged as before: what is missing is
# printed as a warning and the gate passes, so no task in flight is stopped
# halfway through a route it began under other rules.

# _task_receipt_covers <id> <stage> — exit 0 when the task's receipt records a
# review of <stage>: its `stages:` list, or, for a receipt written before the
# list existed, its `stage:`.
_task_receipt_covers() {
  local id="$1" stage="$2" stages
  [ -f "$(task_dir "$id")/receipt" ] || return 1
  stages=$(_task_receipt_get "$id" stages)
  [ -n "$stages" ] || stages=$(_task_receipt_get "$id" stage)
  case ",$stages," in
    *",$stage,"*) return 0 ;;
  esac
  return 1
}

# _task_route_evidence_missing <id> <point> — one line per stage of the task's
# class's full route that leaves a record and has not, each naming the command that writes
# it; nothing when the route is complete. <point> is `ready` (every stage
# before verify) or `consolidate` (verify too: `status ready` is its record).
_task_route_evidence_missing() {
  local id="$1" point="$2" dir class stages stage
  dir=$(task_dir "$id")
  # A triage task as `task ship` filed it has no route, so nothing of one is
  # missing (adr-20261029-a-ship-hands-open-findings-to-one-triage-task).
  if _task_is_bare_triage "$id"; then
    return 0
  fi
  class=$(task_state_get "$id" class)
  if ! _task_valid_class "$class"; then
    printf 'class (not classified, so there is no route: jig task set %s class Tn)\n' "$id"
    return 0
  fi
  stages=$(_task_route_stages "$class" full)
  while IFS= read -r stage; do
    case "$stage" in
      specify)
        [ -s "$dir/spec.md" ] || printf 'specify (no spec.md: jig task artifact write %s spec)\n' "$id" ;;
      alternatives)
        [ -s "$dir/alternatives.md" ] || printf 'alternatives (no alternatives.md: jig task artifact write %s alternatives)\n' "$id" ;;
      design)
        [ -s "$dir/design.md" ] || printf 'design (no design.md: jig task artifact write %s design)\n' "$id" ;;
      'human gate')
        case "$(_task_gate_state "$id")" in
          approved) ;;
          changed) printf 'human gate (the design changed after its approval: take it back to the gate, then jig task gate %s approved)\n' "$id" ;;
          *) printf 'human gate (no approval recorded: jig task gate %s approved)\n' "$id" ;;
        esac ;;
      review | 'independent review')
        _task_receipt_covers "$id" review \
          || printf '%s (no review receipt: jig task receipt %s --stage review)\n' "$stage" "$id" ;;
      'architecture review')
        _task_receipt_covers "$id" architecture-review \
          || printf 'architecture review (no architecture-review receipt: jig task receipt %s --stage architecture-review)\n' "$id" ;;
      verify)
        [ "$point" = consolidate ] || continue
        case "$(task_state_get "$id" status)" in
          ready | consolidated) ;;
          *) printf 'verify (not signed off: jig verify, then jig task set %s status ready)\n' "$id" ;;
        esac ;;
    esac
  done < <(printf '%s\n' "$stages" | tr ',' '\n' | sed 's/^ *//')
}

# _task_is_bare_triage <id> — exit 0 when <id> is a triage task as `task ship`
# filed it: `triage_of` set (script-owned, so an ordinary task cannot claim
# it), no class and never started. It holds decisions, not a change, so it has
# no route to prove and no change whose intent consolidation could lose; it
# closes with `jig task set <id> status consolidated`, which records the
# knowledge decision with it. Classified or started, it is an ordinary task
# again and its route is asked for as for any other
# (adr-20261029-a-ship-hands-open-findings-to-one-triage-task).
_task_is_bare_triage() {
  local of class branch
  task_state_var of "$1" triage_of
  [ -n "$of" ] || return 1
  task_state_var class "$1" class
  ! _task_valid_class "$class" || return 1
  task_state_var branch "$1" branch
  [ -z "$branch" ]
}

# _task_route_evidence_list <id> <point> — what _task_route_evidence_missing
# printed, on one line joined by "; "; nothing when the route is complete.
_task_route_evidence_list() {
  _task_route_evidence_missing "$1" "$2" | awk 'NR > 1 { printf "; " } { printf "%s", $0 } END { if (NR) printf "\n" }'
}

# _task_route_evidence_refusal <id> <point> <command> — the refusal
# _task_route_evidence_gate dies with, or nothing: only a task filed under this
# check is refused, an older one is warned. Read by `task ship`'s guard, which
# the actions table shares (_task_ship_refusal).
# Asked by _task_ship_gates_v only when route_evidence is required: keep
# its no-evidence case in step with that precondition.
_task_route_evidence_refusal() {
  local id="$1" point="$2" cmd="$3" missing
  [ "$(task_state_get "$id" route_evidence)" = required ] || return 0
  missing=$(_task_route_evidence_list "$id" "$point")
  [ -z "$missing" ] \
    || printf '%s: the route of %s (%s) is missing: %s\n' "$cmd" "$id" "$(task_state_get "$id" class)" "$missing"
  return 0
}

# _task_route_evidence_gate <id> <point> <command> — refuse, as <command>, a
# task filed under this check whose route is missing a record; warn, and pass,
# for a task filed before it.
_task_route_evidence_gate() {
  local id="$1" point="$2" cmd="$3" missing
  missing=$(_task_route_evidence_list "$id" "$point")
  [ -n "$missing" ] || return 0
  if [ "$(task_state_get "$id" route_evidence)" = required ]; then
    jig_die "$(_task_route_evidence_refusal "$id" "$point" "$cmd")"
  fi
  jig_warn "$cmd: $id was filed before route evidence was checked, so this passes without: $missing"
}

# --- gate hooks (adr-20261113-a-project-script-can-refuse-a-completion-gate) --
#
# A project names its own scripts at the three completion gates in its
# `.ai/config.yaml`: `hooks.ready` (`task set <id> status ready`),
# `hooks.consolidate` (`task set <id> knowledge_consolidated true`) and
# `hooks.ship` (`task ship`). The exit code decides: 0 passes, and whatever the
# script printed is shown as a warning; anything else refuses the gate with the
# script's name and output. The keys are project keys only — never in
# JIG_CFG_LOCAL_KEYS — so a clone cannot switch a team's hook off.
#
# Only the commands run a hook. The shared refusals (_task_ship_refusal,
# _task_close_refusal) and every reader — the actions table, `jig status` —
# never do: a read must not execute project code.

# _task_gate_hook_paths <gate> — the paths `hooks.<gate>` names, one per line.
# One literal key per gate, so tests/config.t.sh finds each call site.
_task_gate_hook_paths() {
  case "$1" in
    ready) cfg_list_lines hooks.ready ;;
    consolidate) cfg_list_lines hooks.consolidate ;;
    ship) cfg_list_lines hooks.ship ;;
  esac
}

# _task_gate_hook_problem <root> <path> — why the hook <path> cannot be run
# from the tree <root>, or nothing: a path is project-relative and stays in
# the project, and the file is there.
_task_gate_hook_problem() {
  case "$2" in
    /* | [A-Za-z]:*) printf 'is absolute\n'; return 0 ;;
    .. | ../* | */.. | */../*) printf 'leaves the project\n'; return 0 ;;
  esac
  [ -f "$1/$2" ] || printf 'does not exist\n'
  return 0
}

# jig_gate_hook_problems — "<key><TAB><path><TAB><problem>" for each hook path
# the project names that a gate would refuse, judged against this checkout.
# For `jig status`: it checks paths and never runs a hook.
jig_gate_hook_problems() {
  local gate path problem
  for gate in ready consolidate ship; do
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      problem=$(_task_gate_hook_problem "$JIG_PROJECT" "$path")
      [ -z "$problem" ] || printf 'hooks.%s\t%s\t%s\n' "$gate" "$path" "$problem"
    done < <(_task_gate_hook_paths "$gate")
  done
  return 0
}

# _task_gate_hook_tree_v <var> <id> — the tree a hook of <id> runs in, into
# <var>: this checkout when the task's branch is checked out here (or the task
# has no branch), else the worktree that has it checked out, else nothing —
# the task's code is on no disk a hook could read.
_task_gate_hook_tree_v() {
  local __gh_branch __gh_wts
  printf -v "$1" '%s' ""
  __gh_branch=$(task_state_get "$2" branch)
  if [ -z "$__gh_branch" ] || [ "$(_task_current_branch)" = "$__gh_branch" ]; then
    printf -v "$1" '%s' "$JIG_PROJECT"
    return 0
  fi
  __gh_wts=$(_task_worktrees)
  _task_worktree_for_v "$1" "$__gh_branch" "$__gh_wts"
}

# _task_gate_hooks <id> <gate> <command> — run every hook `hooks.<gate>`
# names for task <id>, in the order listed, and die as <command> when any
# refused: each refusal is listed with its output, so one run shows them all.
#
# A hook runs in the task's tree (_task_gate_hook_tree_v), by its path when it
# is executable and as `bash <path>` when not — the fallback ADR-0037 gives
# Jig's own scripts, for a checkout that lost the executable bit. It is told
# JIG_TASK_ID, JIG_TASK_DIR (the task's workspace), JIG_GATE and JIG_BASE (the
# task's base as jig_base_ref resolves it, origin first; the bare branch name
# when neither ref exists). Its stdin is empty and both of its outputs are
# captured together; what Jig shows goes to stderr, since agents read the
# stdout of `task set --json` and `task ship`. It runs on this machine, never
# through `run.exec`, as `worktree.setup` does.
#
# Each hook is bounded by `hooks.timeout`, read once per gate: one that is
# still running at the limit is stopped with its whole process tree
# (jig_run_bounded) and refuses like a failing exit, so a hook that never ends
# cannot hold the gate. The limit is per hook, so a slow one does not spend the
# next one's time and the refusal names the one that hung
# (adr-20261113-a-project-script-can-refuse-a-completion-gate, amendment).
_task_gate_hooks() {
  local id="$1" gate="$2" cmd="$3" paths path tree problem out rc dir base ref refused="" nl=$'\n' before after reason
  local limit secs out_file timed_out=0
  paths=$(_task_gate_hook_paths "$gate")
  [ -n "$paths" ] || return 0
  _task_gate_hook_tree_v tree "$id"
  [ -n "$tree" ] || jig_die "$cmd: hooks.$gate cannot run: $(task_state_get "$id" branch) is not checked out in any tree of this repository; check it out, or run from its worktree"
  dir=$(task_dir "$id")
  base=$(jig_task_base "$id")
  ref=$(jig_base_ref "$base")
  [ -z "$ref" ] || base=$ref
  limit=$(cfg hooks.timeout 5m)
  if ! secs=$(jig_duration_seconds "$limit" 2>/dev/null); then
    jig_warn "$cmd: hooks.timeout $limit is not a duration; using 5m"
    limit=5m
    secs=300
  fi
  out_file=$(mktemp "${TMPDIR:-/tmp}/jig-hook.XXXXXX") || jig_die "$cmd: cannot make a temporary file for a hook's output"
  jig_cleanup_add "$out_file"
  before=$(_task_gate_hook_tree_print "$tree")
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    problem=$(_task_gate_hook_problem "$tree" "$path")
    if [ -n "$problem" ]; then
      # A path that cannot run is a refusal like a failing exit, and is
      # waived the same way: the broken-path hook is the case a waiver is for
      # (adr-20261114-a-person-waives-a-gate-hooks-refusal-for-one-task).
      reason=$(_task_waiver_reason "$id" "$gate" "$path")
      if [ -n "$reason" ]; then
        jig_warn "$cmd: hook $path $problem in $tree, waived for $id: $reason"
      else
        refused="$refused$nl- hook $path $problem in $tree"
      fi
      continue
    fi
    jig_run_bounded rc "$secs" _task_gate_hook_run "$tree" "$path" "$id" "$dir" "$gate" "$base" \
      </dev/null >"$out_file" 2>&1
    out=$(cat "$out_file")
    if [ "$rc" = timeout ]; then
      reason=$(_task_waiver_reason "$id" "$gate" "$path")
      if [ -n "$reason" ]; then
        jig_warn "$cmd: hook $path (hooks.$gate) did not finish in $limit and was stopped, waived for $id: $reason${out:+:$nl$out}"
      else
        timed_out=1
        refused="$refused$nl- hook $path did not finish in $limit and was stopped"
        [ -z "$out" ] || refused="$refused:$nl$out"
      fi
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      # A waived hook has still run, so its output stays in the trace and
      # shows whether it still refuses; only its verdict is set aside.
      reason=$(_task_waiver_reason "$id" "$gate" "$path")
      if [ -n "$reason" ]; then
        jig_warn "$cmd: hook $path (hooks.$gate) exited $rc, waived for $id: $reason${out:+:$nl$out}"
      else
        refused="$refused$nl- hook $path exited $rc"
        [ -z "$out" ] || refused="$refused:$nl$out"
      fi
    elif [ -n "$out" ]; then
      jig_warn "$cmd: hook $path (hooks.$gate) passed with output:$nl$out"
    fi
  done <<EOF
$paths
EOF
  if [ -n "$refused" ] && [ "$timed_out" = 1 ]; then
    refused="$refused
a hook that did not finish ran into hooks.timeout ($limit), which is the hook's limit and not the task's code: fix the hook, or raise hooks.timeout in .ai/config.yaml"
  fi
  [ -z "$refused" ] || jig_die "$cmd: the project's hooks.$gate refused $id:$refused
a person can waive one for this task, with a reason: jig task waive $id $gate <path> --reason <text>"
  # A hook checks; it never writes. A waiver never covers this check: it
  # guards what the review read, not the script's verdict. What it changed that git can see would
  # reach the commit unreviewed — `task ship` stages tracked edits — so the
  # gate refuses and names the change for the person to keep or take back.
  after=$(_task_gate_hook_tree_print "$tree")
  [ "$before" = "$after" ] \
    || jig_die "$cmd: the project's hooks.$gate changed files git can see in $tree; a hook only checks: undo its change or keep it as the task's own (and have it reviewed), then retry"
}

# _task_gate_hook_run <tree> <path> <id> <dir> <gate> <base> — the body of one
# hook's background job (jig_run_bounded): in the task's tree, told what the
# hook is told, exec'd so the hook itself leads the process group the limit
# stops. Runs in its own subshell, so its cd and exports touch nothing of Jig's.
_task_gate_hook_run() {
  cd "$1" || exit 1
  export JIG_TASK_ID="$3" JIG_TASK_DIR="$4" JIG_GATE="$5" JIG_BASE="$6"
  if [ -x "$2" ]; then
    exec "./$2"
  else
    exec bash "./$2"
  fi
}

# _task_gate_hook_tree_print <tree> — one hash of what git sees in <tree>:
# HEAD itself, the status lines (untracked files included) and the diff against
# HEAD. HEAD is in the hash because a hook that commits what it changed leaves
# a clean tree and an empty diff, yet `task ship` would push its unreviewed commit.
_task_gate_hook_tree_print() {
  { git -C "$1" rev-parse HEAD 2>/dev/null; git -C "$1" status --porcelain 2>/dev/null; git -C "$1" diff HEAD --binary 2>/dev/null; } \
    | git hash-object --stdin
}

# --- hook waivers (adr-20261114-a-person-waives-a-gate-hooks-refusal-for-one-task)
#
# `.ai/workspace/tasks/<id>/waivers` — TSV, one line per (gate, hook path):
# `<gate><TAB><path><TAB><date><TAB><reason>`. A waiver sets aside one hook's
# refusal at one gate for this task, and nothing else: not the same hook at
# another gate, not another hook of the gate, not the check that a hook wrote
# no file. Written only by `jig task waive`. The file's text is read through the
# two readers below, but the four TSV columns are split by each consumer itself:
# _task_gate_hooks (through _task_waiver_reason), _status_report (status.sh),
# _task_list_json_task_v and task_ship. A change of the format touches all of them.

# _task_waivers <id> — the waivers file's lines as they are, nothing when the
# task has none.
_task_waivers() {
  local text
  _task_waivers_v text "$1"
  printf '%s' "$text"
}

# _task_waivers_v <var> <id> — the same text into <var>, in the caller's
# shell and without a process, for the readers that ask once per task of a
# listing (the status page, `task list --json`).
_task_waivers_v() {
  local __tw_file __tw_text=""
  task_dir_v __tw_file "$2"
  __tw_file="$__tw_file/waivers"
  if [ -f "$__tw_file" ]; then IFS= read -r -d '' __tw_text < "$__tw_file" || true; fi
  printf -v "$1" '%s' "$__tw_text"
}

# _task_waiver_reason <id> <gate> <path> — the reason of the waiver of the
# hook <path> at <gate>, or nothing; exits 0 either way, so a caller can ask
# inside $(...) under `set -e`. Values reach awk through the environment (see
# task_finding_set).
_task_waiver_reason() {
  local file
  task_dir_v file "$1"
  file="$file/waivers"
  [ -f "$file" ] || return 0
  JIG_W_GATE="$2" JIG_W_PATH="$3" awk -F '\t' '
    $1 == ENVIRON["JIG_W_GATE"] && $2 == ENVIRON["JIG_W_PATH"] { print $4; exit }
  ' "$file"
  return 0
}

# task_waive <id> <ready|consolidate|ship> <path> --reason <text>
# task_waive <id> <ready|consolidate|ship> <path> --withdraw
# — set aside the refusal of one hook of the project's `hooks.<gate>` for this
# task, or take that back. Waiving the same pair again replaces its date and
# reason. Refused while the task's autopilot run is `on`: a hook's refusal is
# a stop of the run, and a person waives it once the run is stopped (a script
# cannot tell a person from an agent, ADR-0020, so it refuses where the move
# is certainly not the agent's).
task_waive() {
  jig_require_init
  [ $# -ge 3 ] || jig_die "$(_task_usage waive)"
  local id="$1" gate="$2" path="$3" reason="" has_reason=0 withdraw=0 dir file tmp today src
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || jig_die "task waive: --reason requires a value"
        reason="$2"; has_reason=1; shift 2 ;;
      --withdraw) withdraw=1; shift ;;
      *) jig_die "task waive: unknown argument: $1" ;;
    esac
  done
  case "$gate" in
    ready | consolidate | ship) ;;
    *) jig_die "task waive: invalid gate: $gate (expected ready|consolidate|ship)" ;;
  esac
  [ -n "$path" ] || jig_die "task waive: the hook path must not be empty"
  _task_finding_valid_field "$path" || jig_die "task waive: the hook path must be a single line with no tab"
  if [ "$withdraw" -eq 1 ]; then
    [ "$has_reason" -eq 0 ] || jig_die "task waive: --reason and --withdraw exclude each other"
  else
    [ "$has_reason" -eq 1 ] || jig_die "task waive: --reason is required"
    [ -n "$reason" ] || jig_die "task waive: --reason must not be empty"
    _task_finding_valid_field "$reason" || jig_die "task waive: --reason must be a single line with no tab"
  fi
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task waive"
  if [ "$(task_state_get "$id" autopilot)" = on ]; then
    jig_die "task waive: $id has an autopilot run on; a hook refusal is a stop of the run: stop it (jig task autopilot $id stop --reason <text>) and a person waives it"
  fi
  file="$dir/waivers"
  if [ "$withdraw" -eq 0 ]; then
    # Only a path the gate names: a typo must not leave a record that waives
    # nothing. A withdrawal skips this, since the hook may have left the config.
    # A case on the list, not `printf | grep -q`: grep -q leaves at the first
    # match, printf's write then fails, and pipefail turns that into a refusal.
    local named
    named=$(_task_gate_hook_paths "$gate")
    case "
$named
" in
      *"
$path
"*) ;;
      *) false ;;
    esac \
      || jig_die "task waive: $path is not named by hooks.$gate in this checkout (it names: $(_task_gate_hook_paths "$gate" | paste -sd ' ' -))"
  else
    [ -n "$(_task_waiver_reason "$id" "$gate" "$path")" ] \
      || jig_die "task waive: $id has no waiver of $path at hooks.$gate"
  fi
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  today=$(jig_today)
  src=$file
  [ -f "$file" ] || src=/dev/null
  # Values reach awk through the environment, not `-v` (task_finding_set).
  JIG_W_GATE="$gate" JIG_W_PATH="$path" JIG_W_DATE="$today" JIG_W_REASON="$reason" JIG_W_WITHDRAW="$withdraw" \
    awk -F '\t' -v OFS='\t' '
      $1 == ENVIRON["JIG_W_GATE"] && $2 == ENVIRON["JIG_W_PATH"] {
        if (ENVIRON["JIG_W_WITHDRAW"] != "1" && !done) {
          print ENVIRON["JIG_W_GATE"], ENVIRON["JIG_W_PATH"], ENVIRON["JIG_W_DATE"], ENVIRON["JIG_W_REASON"]
          done = 1
        }
        next
      }
      { print }
      END {
        if (ENVIRON["JIG_W_WITHDRAW"] != "1" && !done)
          print ENVIRON["JIG_W_GATE"], ENVIRON["JIG_W_PATH"], ENVIRON["JIG_W_DATE"], ENVIRON["JIG_W_REASON"]
      }
    ' "$src" > "$tmp"
  mv "$tmp" "$file"
  jig_record_changed
  if [ "$withdraw" -eq 1 ]; then
    printf 'withdrawn: hooks.%s %s for %s\n' "$gate" "$path" "$id"
  else
    printf 'waived: hooks.%s %s for %s\n' "$gate" "$path" "$id"
  fi
}

# --- the human gate (adr-20260924-the-status-page-keeps-the-readers-place)
#
# A T3/T4 design is approved by a human in conversation, and the jig-task
# skill writes the decision into task.md in prose (ADR-0031). `jig task gate`
# records the same decision as data: `gate: approved` and `gate_design`, the
# hash of the documents approved (_task_receipt_design_hash, the same value a
# review receipt pins). It is a claim, like every record here (ADR-0020): the
# script cannot tell who approved. What it adds is that a design changed after
# its approval becomes visible without anyone rereading task.md.

# task_gate <id> approved [--by human|agent] [--revision <n>] [--json] —
# record the approval of the design as it is now, and who gave it (`gate_by`,
# human by default). Refused for a class without a gate and for a task with no
# design.md, since there is nothing to pin. `--by agent` is the self-approval of
# an unattended run
# (adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci), and is
# refused anywhere else: outside such a run the gate is a human's.
#
# task_gate <id> answered --answer <text> [--revision <n>] [--json] — the
# human's other decision: not an approval but an answer to the design's
# `## Gate questions`. It records `gate: answered` and the hash of the design
# answered, and appends the answer to the task's `gate-answers`; the gate is
# `waiting` again once the design is rewritten (_task_gate_state_v). Always a
# human's: `--by agent` is refused, and an approved design takes no answer.
#
# Either decision, by a human, on a task whose attended run is stopped at the
# gate also answers that stop (_task_gate_answer_the_run), so the run resumes.
# A stop at the gate is a stop before any stage after it
# (_task_autopilot_stage_before_gate): a run that stopped in review keeps its
# own stop, whatever the gate says. The stage is the last one the run marked
# since it started, a resume included.
#
# The three keys are one new state file under one revision claim, checked as
# `task pause`'s write is: against the caller's `--revision`, or the one read
# before the task is. A board's approve button sends the revision of the read
# that showed the design, and `jig task artifact write` raises it, so a design
# rewritten since is never approved unseen. `--json` anywhere runs the whole
# command as the producer of json_run (conventions/json-output.md).
task_gate() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_gate_body 1 "$@"
      return
    fi
  done
  _task_gate_body 0 "$@"
}

# _task_gate_body <as_json> <id> approved|answered [--by human|agent]
# [--answer <text>] [--revision <n>] [--json] — the body of `task gate`; with
# <as_json> 1 it runs inside json_run and prints the decision as data.
_task_gate_body() {
  local as_json="$1" arg args=()
  shift
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ $# -ge 2 ] || jig_fail usage "$(_task_usage gate)"
  local id="$1" decision="$2" by=human by_given=0 answer="" has_answer=0 dir design rev="" rev_given=0 expected
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --by)
        [ $# -ge 2 ] || jig_fail usage "$(_task_usage gate)"
        case "$2" in
          human | agent) by="$2"; by_given=1 ;;
          *) jig_fail usage "task gate: invalid --by: $2 (expected human|agent)" ;;
        esac
        shift 2 ;;
      --answer)
        [ $# -ge 2 ] || jig_fail usage "task gate: --answer requires a value"
        answer="$2"; has_answer=1; shift 2 ;;
      --revision)
        [ $# -ge 2 ] || jig_fail usage "task gate: --revision requires a value"
        rev="$2"; rev_given=1; shift 2 ;;
      --*) jig_fail usage "task gate: unknown argument: $1" ;;
      *) jig_fail usage "$(_task_usage gate)" ;;
    esac
  done
  [ "$rev_given" -eq 0 ] || [ -n "$rev" ] || jig_fail usage "task gate: --revision is empty"
  [ -z "$rev" ] || jig_revision_valid "$rev" || jig_fail usage "task gate: --revision is not a revision: $rev"
  case "$decision" in
    approved)
      [ "$has_answer" -eq 0 ] || jig_fail usage "task gate: --answer is for the answered decision: jig task gate $id answered --answer <text>" ;;
    answered)
      # The agent has no answer to its own questions: an unattended run's
      # recommendation is its approval (--by agent).
      { [ "$by_given" -eq 0 ] || [ "$by" = human ]; } \
        || jig_fail usage "task gate: an answer is a human's: --by agent is refused for answered"
      [ "$has_answer" -eq 1 ] \
        || jig_fail usage "task gate: --answer is required: the human's answer to the design's questions, in their words: jig task gate $id answered --answer <text>"
      [ -n "$answer" ] || jig_fail usage "task gate: --answer must not be empty"
      _task_finding_valid_field "$answer" \
        || jig_fail usage "task gate: --answer must be a single line with no tab" ;;
    *) jig_fail usage "task gate: unknown decision: $decision (expected approved|answered)" ;;
  esac
  _task_valid_id "$id" || jig_fail usage "invalid task id: $id"
  # The revision this write is checked against: the caller's, or the one read
  # here before the task is, so the state read below is never newer than it.
  if [ -n "$rev" ]; then expected=$rev; else expected=$(jig_revision_read); fi
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_fail not-found "task gate: unknown task: $id"
  _task_guard_write "$id" "task gate"
  _task_gate_check "$id" "$by" "$decision"
  if [ -n "$_TASK_GATE_MSG" ]; then
    # A code only where a program can act on it: the run's own answer to give,
    # or a design to write. The agent's self-approval refused outside a run is
    # the clone's setting and stays `failed`.
    if [ -n "$_TASK_GATE_CODE" ]; then
      jig_fail "$_TASK_GATE_CODE" "$_TASK_GATE_MSG"
    fi
    jig_die "$_TASK_GATE_MSG"
  fi
  local before run mode last_stage
  _task_gate_state_v before "$id"
  # An approved design is in work: an answer to it is said in the session, and
  # the agent changes the design (the gate is then `changed`).
  if [ "$decision" = answered ] && [ "$before" = approved ]; then
    jig_die "task gate: $id's design is approved; nothing waits at its gate"
  fi
  design=$(_task_receipt_design_hash "$id")

  # The new state, whole, before the claim: a refused claim leaves nothing.
  local tmp="$dir/state.tmp.$$" tmp2="$dir/state.tmp2.$$"
  jig_cleanup_add "$tmp"
  jig_cleanup_add "$tmp2"
  _task_state_set_into "$dir/state" "$tmp2" gate "$decision"
  _task_state_set_into "$tmp2" "$tmp" gate_design "$design"
  _task_state_set_into "$tmp" "$tmp2" gate_by "$by"
  rm -f "$tmp"
  # The answer's journal line, also whole before the claim, lands with the
  # state under the one revision raise below: a read never sees `answered`
  # without its answer (adr-20261016-the-clone-revision-is-a-claimed-name).
  local jtmp="$dir/gate-answers.tmp.$$"
  if [ "$decision" = answered ]; then
    jig_cleanup_add "$jtmp"
    _task_gate_answer_line_into "$dir" "$jtmp" "$design" "$by" "$answer"
  fi
  _task_claim_or_refuse "task gate" "$expected" "$tmp2"
  [ "$decision" != answered ] || mv "$jtmp" "$dir/gate-answers"
  mv "$tmp2" "$dir/state"
  jig_task_state_forget
  jig_record_changed

  # The stop of an attended run at this gate is answered by the decision.
  task_state_var run "$id" autopilot
  if [ "$run" = stopped ] && [ "$by" = human ]; then
    _task_autopilot_mode_v mode "$id"
    _task_autopilot_stop_stage_v last_stage "$id"
    if _task_autopilot_stage_before_gate "$last_stage"; then
      case "$before:$mode" in
        waiting:attended | changed:attended | answered:attended)
          if [ "$decision" = answered ]; then
            _task_autopilot_log "$id" answer "gate answered: $answer"
          else
            _task_autopilot_log "$id" answer "gate approved"
          fi
          _task_rewrite_state "$dir" autopilot_answered "$(_task_autopilot_now)" ;;
      esac
    fi
  fi

  if [ "$as_json" = 1 ]; then
    local rec
    json_quote "$by"; rec="{\"state\":\"$decision\",\"by\":$_JSON"
    json_quote "$design"; rec="$rec,\"design\":$_JSON"
    if [ "$decision" = answered ]; then
      json_quote "$answer"; rec="$rec,\"answer\":$_JSON"
    fi
    rec="$rec}"
    printf '{"task":%s,"gate":%s}\n' "$(_task_json_one "$id")" "$rec"
    return 0
  fi
  if [ "$decision" = answered ]; then
    printf 'gate: answered\n'
  elif [ "$by" = agent ]; then
    printf 'gate: approved by the agent\n'
  else
    printf 'gate: approved\n'
  fi
}

# _task_gate_answer_line_into <dir> <tmp> <design-hash> <by> <text> — into
# <tmp>, the task's `gate-answers` with one line added,
# `<utc>\t<design-hash>\t<by>\t<text>`: only ever appended, so the last line
# is the latest answer and the file is the history. The caller moves <tmp>
# into place with the decision's state, after the claim, and records the
# change once, so a reader never sees a torn line or an answer the revision
# does not count.
_task_gate_answer_line_into() {
  local dir="$1" tmp="$2"
  _task_guard_dir "$dir"
  if [ -f "$dir/gate-answers" ]; then
    cp "$dir/gate-answers" "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\t%s\n' "$(_task_autopilot_now)" "$3" "$4" "$5" >> "$tmp"
}

# _task_gate_check <id> <by> [<decision>] — why `jig task gate <id> <decision>
# --by <by>` (approved unless said) refuses this task by its state, in
# _TASK_GATE_MSG, empty when it would record the decision; and, in
# _TASK_GATE_CODE, the code a program acts on (schemas/json.md), empty for a
# refusal that has none of its own. The one place the conditions live: `task
# gate` and the actions table both ask it, through _task_gate_refusal for the
# table, for both decisions. Sets variables rather than printing, so the
# command gets the code and the message from one decision, in its own shell.
_TASK_GATE_MSG=""
_TASK_GATE_CODE=""
_task_gate_check() {
  local id="$1" by="$2" decision="${3:-approved}" class run mode design verb=approve
  [ "$decision" != answered ] || verb=answer
  _TASK_GATE_MSG="" _TASK_GATE_CODE=""
  task_state_var run "$id" autopilot
  if [ "$by" = agent ]; then
    _task_autopilot_mode_v mode "$id"
    if [ "$run" != on ] || [ "$mode" != unattended ]; then
      printf -v _TASK_GATE_MSG "task gate: --by agent is an unattended run's self-approval; %s has no unattended autopilot run on, so the gate is the human's" "$id"
      return 0
    fi
  elif _task_run_unattended "$id"; then
    # Inside the task's unattended run, on or stopped, nobody answers, so an
    # approval recorded there is the agent's, and is said to be
    # (adr-20261004-a-route-stage-is-proven-by-its-record). The clone's
    # setting alone does not refuse it: without a run the person working the
    # task is the one approving.
    if [ "$run" = on ]; then
      _TASK_GATE_CODE=autopilot-running
      if [ "$decision" = answered ]; then
        printf -v _TASK_GATE_MSG "task gate: %s's run is unattended, so nobody answers at its gate: the agent approves its own design with the recommendations: jig task gate %s approved --by agent" "$id" "$id"
      else
        printf -v _TASK_GATE_MSG "task gate: %s's run is unattended, so this approval is the agent's: jig task gate %s approved --by agent" "$id" "$id"
      fi
      return 0
    fi
    # Not on, so stopped.
    _TASK_GATE_CODE=autopilot-stopped
    if _task_autopilot_at_limit "$id"; then
      printf -v _TASK_GATE_MSG 'task gate: %s exhausted its unattended repair limit; %s' "$id" "$(_task_autopilot_limit_roads "$id")"
      return 0
    fi
    printf -v _TASK_GATE_MSG 'task gate: %s is stopped; if a human answered, run: jig task autopilot %s resume --answer <text> --by human; then approve with --by agent; or, if a person takes the task on: jig task autopilot %s handover --by human --answer <text>' "$id" "$id" "$id"
    return 0
  fi
  _TASK_GATE_CODE=no-gate
  task_state_var class "$id" class
  case "$class" in
    T3 | T4) ;;
    *)
      printf -v _TASK_GATE_MSG 'task gate: %s is %s; only T3 and T4 tasks have a human gate' "$id" "${class:-unclassified}"
      return 0 ;;
  esac
  _task_design_hash_v design "$id"
  [ "$design" != "-" ] || printf -v _TASK_GATE_MSG 'task gate: %s has no design.md to %s' "$id" "$verb"
}

# _task_gate_refusal <id> <by> [<decision>] — _task_gate_check's message,
# printed: what the actions table (_task_actions) asks for `--by human`, the
# approval or the answer a person gives.
_task_gate_refusal() {
  _task_gate_check "$1" "$2" "${3:-approved}"
  [ -z "$_TASK_GATE_MSG" ] || printf '%s\n' "$_TASK_GATE_MSG"
  return 0
}

# _task_gate_state <id> — where a T3/T4 task stands at its human gate:
# `waiting` (a design.md exists and no approval is recorded), `answered` (a
# human answered its questions and the design has not been rewritten since),
# `changed` (the design moved after the approval), `approved`; nothing for a
# task without a gate or without a design yet. The status page's "needs you"
# reads it.
_task_gate_state() {
  local gate
  _task_gate_state_v gate "$1"
  [ -z "$gate" ] || printf '%s\n' "$gate"
}

# _task_gate_state_v <var> <id> — the same answer into <var>. An answer pins
# the design it answered (`gate_design`, as an approval does): once the design
# is rewritten the gate waits for the human again, as `waiting`, not `changed`
# (nothing was approved).
_task_gate_state_v() {
  local __tgs_v __tgs_design __tgs_gate
  printf -v "$1" '%s' ""
  task_state_var __tgs_v "$2" class
  case "$__tgs_v" in
    T3 | T4) ;;
    *) return 0 ;;
  esac
  _task_design_hash_v __tgs_design "$2"
  [ "$__tgs_design" != "-" ] || return 0
  task_state_var __tgs_gate "$2" gate
  case "$__tgs_gate" in
    approved | answered) ;;
    *)
      printf -v "$1" '%s' waiting
      return 0 ;;
  esac
  task_state_var __tgs_v "$2" gate_design
  if [ "$__tgs_v" = "$__tgs_design" ]; then
    printf -v "$1" '%s' "$__tgs_gate"
  elif [ "$__tgs_gate" = answered ]; then
    printf -v "$1" '%s' waiting
  else
    printf -v "$1" '%s' changed
  fi
}

# _task_gate_questions_v <var> <id> — the questions of the task's design.md
# `## Gate questions` section as a JSON array into <var>: `[]` for a section
# with no question, `null` for a design with no such section (or none at all).
# The section runs from that heading to the next `## ` heading or the end of
# the file; a line in a fenced code block is no heading and no content. In it,
# `### <text>` opens a question, `- <text>` is an option, `Recommended: <text>`
# the agent's recommendation, any other non-empty line a line of context
# (joined with a space). Each is
# `{"question","context"|null,"options":[...],"recommendation"|null}`. It reads
# the shape and never refuses one: the limit of five is a rule the design's
# writer is warned of (_task_gate_questions_warn), not one a reader enforces.
_task_gate_questions_v() {
  local __tgq_file __tgq_text="" __tgq_line __tgq_in=0 __tgq_fence=0 __tgq_open=0 __tgq_found=0
  local __tgq_q="" __tgq_ctx="" __tgq_opts="" __tgq_rec="" __tgq_all="" __tgq_cr=$'\r'
  printf -v "$1" '%s' null
  task_dir_v __tgq_file "$2"
  __tgq_file="$__tgq_file/design.md"
  [ -f "$__tgq_file" ] || return 0
  IFS= read -r -d '' __tgq_text < "$__tgq_file" || true
  case "$__tgq_text" in *"## Gate questions"*) ;; *) return 0 ;; esac
  while IFS= read -r __tgq_line || [ -n "$__tgq_line" ]; do
    __tgq_line=${__tgq_line%"$__tgq_cr"}
    __tgq_line=${__tgq_line#"${__tgq_line%%[![:space:]]*}"}
    __tgq_line=${__tgq_line%"${__tgq_line##*[![:space:]]}"}
    case "$__tgq_line" in
      '```'* | '~~~'*)
        __tgq_fence=$((1 - __tgq_fence))
        continue ;;
    esac
    [ "$__tgq_fence" = 0 ] || continue
    if [ "$__tgq_in" = 0 ]; then
      [ "$__tgq_line" != "## Gate questions" ] || { __tgq_in=1; __tgq_found=1; }
      continue
    fi
    case "$__tgq_line" in
      '## '* | '##')
        break ;;
      '') continue ;;
      '### '*)
        _task_gate_question_flush __tgq_all "$__tgq_open" "$__tgq_q" "$__tgq_ctx" "$__tgq_opts" "$__tgq_rec"
        __tgq_open=1 __tgq_q=${__tgq_line#'### '} __tgq_ctx="" __tgq_opts="" __tgq_rec="" ;;
      '- '*)
        [ "$__tgq_open" = 1 ] || continue
        json_quote "${__tgq_line#'- '}"
        __tgq_opts="${__tgq_opts:+$__tgq_opts,}$_JSON" ;;
      'Recommended: '*)
        [ "$__tgq_open" = 1 ] || continue
        __tgq_rec=${__tgq_line#'Recommended: '} ;;
      *)
        [ "$__tgq_open" = 1 ] || continue
        __tgq_ctx="${__tgq_ctx:+$__tgq_ctx }$__tgq_line" ;;
    esac
  done <<EOF
$__tgq_text
EOF
  [ "$__tgq_found" = 1 ] || return 0
  _task_gate_question_flush __tgq_all "$__tgq_open" "$__tgq_q" "$__tgq_ctx" "$__tgq_opts" "$__tgq_rec"
  printf -v "$1" '[%s]' "$__tgq_all"
}

# _task_gate_question_flush <var> <open> <question> <context> <options>
# <recommendation> — append the question read so far to the comma-joined
# objects in <var>; <options> is the already quoted, comma-joined list. Nothing
# when <open> is not 1 (no question has begun).
_task_gate_question_flush() {
  [ "$2" = 1 ] || return 0
  local __tgf_o __tgf_prev=${!1}
  json_quote "$3"; __tgf_o="{\"question\":$_JSON"
  json_str_or_null "$4"; __tgf_o="$__tgf_o,\"context\":$_JSON"
  __tgf_o="$__tgf_o,\"options\":[$5]"
  json_str_or_null "$6"; __tgf_o="$__tgf_o,\"recommendation\":$_JSON}"
  printf -v "$1" '%s' "${__tgf_prev:+$__tgf_prev,}$__tgf_o"
}

# _task_gate_answer_v <at-var> <design-var> <by-var> <text-var> <id> — the
# task's last gate answer, the last non-empty line of `gate-answers`
# (_task_gate_answer_line_into), split into its four fields. All four are empty
# when there is no answer. The one reader: the JSON producer and `task show`
# both ask it.
_task_gate_answer_v() {
  local __tga_file __tga_line="" __tga_l __tga_t=$'\t'
  local __tga_at="" __tga_design="" __tga_by="" __tga_text=""
  task_dir_v __tga_file "$5"
  __tga_file="$__tga_file/gate-answers"
  if [ -f "$__tga_file" ]; then
    while IFS= read -r __tga_l || [ -n "$__tga_l" ]; do
      [ -z "$__tga_l" ] || __tga_line=$__tga_l
    done < "$__tga_file"
  fi
  if [ -n "$__tga_line" ]; then
    IFS="$__tga_t" read -r __tga_at __tga_design __tga_by __tga_text <<EOF
$__tga_line
EOF
  fi
  printf -v "$1" '%s' "$__tga_at"
  printf -v "$2" '%s' "$__tga_design"
  printf -v "$3" '%s' "$__tga_by"
  printf -v "$4" '%s' "$__tga_text"
}

# _task_gate_answer_json_v <var> <id> — the task's last gate answer
# (_task_gate_answer_v) into <var> as `{"text","at","by","design"}`, `null`
# when there is none.
_task_gate_answer_json_v() {
  local __tgj_at __tgj_design __tgj_by __tgj_text __tgj_o
  _task_gate_answer_v __tgj_at __tgj_design __tgj_by __tgj_text "$2"
  if [ -z "$__tgj_at$__tgj_design$__tgj_by$__tgj_text" ]; then
    printf -v "$1" '%s' null
    return 0
  fi
  json_quote "$__tgj_text"; __tgj_o="{\"text\":$_JSON"
  json_str_or_null "$__tgj_at"; __tgj_o="$__tgj_o,\"at\":$_JSON"
  json_str_or_null "$__tgj_by"; __tgj_o="$__tgj_o,\"by\":$_JSON"
  json_str_or_null "$__tgj_design"; __tgj_o="$__tgj_o,\"design\":$_JSON}"
  printf -v "$1" '%s' "$__tgj_o"
}

# _task_gate_questions_warn <id> — for a T3/T4 task whose design.md was just
# written: a warning on stderr when it has no `## Gate questions` section or
# more than five questions (the jig-task skill's rule). Never fails.
_task_gate_questions_warn() {
  local q n
  # shellcheck source=lib/json.sh
  declare -F json_quote >/dev/null || . "$JIG_LIB/json.sh"
  _task_gate_questions_v q "$1"
  if [ "$q" = null ]; then
    jig_warn "task artifact: $1's design.md has no \`## Gate questions\` section; the human at the gate answers it (0-5 questions, or one line saying there are none)"
    return 0
  fi
  n=$(printf '%s' "$q" | grep -o '{"question":' | grep -c . || true)
  if [ "${n:-0}" -gt 5 ]; then
    jig_warn "task artifact: $1's design.md has $n gate questions; ask at most five, the ones only the human can answer"
  fi
  return 0
}

# _task_design_hash_v <var> <id> — _task_receipt_design_hash into <var>. On a
# read path (a snapshot open, jig_read_snapshot_begin) the hash of a task is
# worked out once: the listing's gate and its actions table both ask it.
_TASK_DESIGN_MEMO=$'\n'
_TASK_DESIGN_MEMO_GEN=""
_task_design_hash_v() {
  local __tdh_rest __tdh_hash __tdh_nl=$'\n' __tdh_t=$'\t'
  if [ "$_TASK_DESIGN_MEMO_GEN" != "$_JIG_TS_GEN" ]; then
    _TASK_DESIGN_MEMO=$'\n'
    _TASK_DESIGN_MEMO_GEN=$_JIG_TS_GEN
  fi
  if [ "$_JIG_TS_ON" = 1 ]; then
    case "$_TASK_DESIGN_MEMO" in
      *"$__tdh_nl$2$__tdh_t"*)
        __tdh_rest=${_TASK_DESIGN_MEMO#*"$__tdh_nl$2$__tdh_t"}
        printf -v "$1" '%s' "${__tdh_rest%%"$__tdh_nl"*}"
        return 0 ;;
    esac
  else
    _TASK_DESIGN_MEMO=$'\n'
  fi
  __tdh_hash=$(_task_receipt_design_hash "$2")
  [ "$_JIG_TS_ON" != 1 ] || _TASK_DESIGN_MEMO="$_TASK_DESIGN_MEMO$2$__tdh_t$__tdh_hash$__tdh_nl"
  printf -v "$1" '%s' "$__tdh_hash"
}

# --- pause / resume ---------------------------------------------------------------

# _task_pause_refusal <id>, _task_resume_refusal <id> — why `jig task pause`
# or `jig task resume` refuses this task by its state, or nothing. Shared with
# the actions table (_task_actions). Resume's other refusal — the checkout is
# not on the task's branch — is the command's: it depends on where it runs.
_task_pause_refusal() {
  local paused
  task_state_var paused "$1" paused
  [ "$paused" != "true" ] || printf 'task pause: already paused: %s\n' "$1"
}
# A task parked at the staging branch is resumed too, for a fix: <parked> is
# its parked reason as the caller read it (_task_parked_lookup_v), empty when
# it is not parked.
_task_resume_refusal() {
  local paused
  task_state_var paused "$1" paused
  [ "$paused" = "true" ] || [ -n "${2:-}" ] || printf 'task resume: not paused or parked: %s\n' "$1"
}

# Pause is a field, not a status (design §3): it is orthogonal to `status`
# and must return the task to wherever `status` left it. --stash is opt-in
# and never the default (an unwanted default that loses work cannot be
# undone; the reverse costs one flag) and records the stash's SHA, not its
# index, because `stash@{0}` shifts as other entries are pushed.
#
# The write is checked against a revision as `task resume`'s is: the caller's
# (`--revision`), or the one read here before the task is. The new state is
# built whole, the revision claimed, and only then are the pending pause
# request taken out (`jig queue cancel`, as a process), the stash made and the
# state moved into place — a stale caller gets a refusal with nothing done.
# `--json` anywhere runs the whole command as the producer of json_run, so a
# board that drops a card on its paused column can pause a task no stage
# will ever honour a request of (pause-not-started-directly).
task_pause() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_pause_body 1 "$@"
      return
    fi
  done
  _task_pause_body 0 "$@"
}

# _task_pause_body <as_json> <id> [options] — the body of `task pause`; with
# <as_json> 1 it runs inside json_run and prints the paused task as data, not
# the report.
_task_pause_body() {
  local as_json="$1" arg args=()
  shift
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ $# -ge 1 ] || jig_fail usage "$(_task_usage pause)"
  case "$1" in
    -*) jig_fail usage "$(_task_usage pause)" ;;
  esac
  local id="$1"
  shift
  local reason="" stash=0 refusal if_requested=0 stage="" has_reason=0 rev="" rev_given=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) [ $# -ge 2 ] || jig_fail usage "task pause: --reason requires a value"; reason="$2"; has_reason=1; shift 2 ;;
      --stash) stash=1; shift ;;
      --if-requested) if_requested=1; shift ;;
      --stage) [ $# -ge 2 ] || jig_fail usage "task pause: --stage requires a value"; stage="$2"; shift 2 ;;
      --revision) [ $# -ge 2 ] || jig_fail usage "task pause: --revision requires a value"; rev="$2"; rev_given=1; shift 2 ;;
      *) jig_fail usage "task pause: unknown argument: $1" ;;
    esac
  done
  [ "$rev_given" -eq 0 ] || [ -n "$rev" ] || jig_fail usage "task pause: --revision is empty"
  [ -z "$rev" ] || jig_revision_valid "$rev" || jig_fail usage "task pause: --revision is not a revision: $rev"
  _task_valid_id "$id" || jig_fail usage "invalid task id: $id"

  # --if-requested: a stage is about to begin, and only a person's pending
  # request may pause the task there. The reason is the request's, and a
  # stash is the person's call, never the agent's; nothing pending, or a task
  # already paused, is nothing to do. Exit 4 when it paused, as `task
  # autopilot stage` does. It is the stage's, never a board's: no revision,
  # no JSON.
  if [ "$if_requested" -eq 1 ]; then
    [ "$has_reason" -eq 0 ] || jig_fail usage "task pause: --if-requested takes the reason from the request; drop --reason"
    [ "$stash" -eq 0 ] || jig_fail usage "task pause: --if-requested does not stash; drop --stash"
    [ "$rev_given" -eq 0 ] || jig_fail usage "task pause: --if-requested takes no --revision"
    [ "$as_json" = 0 ] || jig_fail usage "task pause: --if-requested takes no --json"
    [ -n "$stage" ] || jig_fail usage "task pause: --if-requested requires --stage <name>"
    _task_autopilot_valid_stage "$stage" || jig_fail usage "task pause: invalid stage: $stage (expected [a-z0-9-]+)"
    _task_guard_write "$id" "task pause"
    [ "$(task_state_get "$id" paused)" != "true" ] || return 0
    if _task_pause_take_request "$id" "task pause"; then
      _task_honour_pause_request "$id" "$stage"
      # `return 4` ends the command under errexit before cmd_task's own flush.
      jig_status_page_flush
      return 4
    fi
    return 0
  fi
  [ -z "$stage" ] || jig_fail usage "task pause: --stage needs --if-requested"

  # paused_reason is one flat `key: value` line (schemas/state.md); an
  # embedded newline would corrupt the state file, so it is refused up front
  # rather than silently truncated or split across lines. $'\n', not
  # $(printf '\n'): command substitution strips trailing newlines, which
  # would leave nl empty and turn the pattern below into a bare `*`.
  local nl=$'\n'
  case "$reason" in
    *"$nl"*) jig_fail usage "task pause: --reason must be a single line" ;;
  esac

  # The revision this write is checked against: the caller's, or the one read
  # here before the task is, so the state read below is never newer than it.
  local expected
  if [ -n "$rev" ]; then
    expected=$rev
  else
    expected=$(jig_revision_read)
  fi

  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_fail not-found "task pause: unknown task: $id"
  _task_guard_write "$id" "task pause"
  refusal=$(_task_pause_refusal "$id") || exit 1
  [ -z "$refusal" ] || jig_fail already-paused "$refusal"

  # --stash sets aside *this checkout's* changes and records them as the
  # task's. When the task's branch is checked out somewhere else — its own
  # worktree, most often (ADR-0029) — those changes are not the task's, and
  # its real work would stay where it is while the record said otherwise.
  local state_branch
  if [ "$stash" -eq 1 ]; then
    state_branch=$(task_state_get "$id" branch)
    if [ -n "$state_branch" ] && [ "$state_branch" != "$(_task_current_branch)" ]; then
      jig_fail wrong-checkout "task pause: --stash stashes this checkout, but $id is on $state_branch; run it where $state_branch is checked out"
    fi
  fi

  # The new state, whole, before the claim: a refused claim leaves nothing.
  local tmp="$dir/state.tmp.$$" tmp2="$dir/state.tmp2.$$"
  jig_cleanup_add "$tmp"
  jig_cleanup_add "$tmp2"
  _task_state_set_into "$dir/state" "$tmp2" paused true
  _task_state_set_into "$tmp2" "$tmp" paused_at "$(jig_today)"
  if [ -n "$reason" ]; then
    _task_state_set_into "$tmp" "$tmp2" paused_reason "$reason"
    mv "$tmp2" "$tmp"
  fi
  rm -f "$tmp2"

  _task_claim_or_refuse "task pause" "$expected" "$tmp"

  # A pause made by hand honours a pending request too: it goes with it,
  # before the pause is set (adr-20261019-a-pause-request-is-honoured-at-the-stage-boundary)
  # and before the stash: a cancel that fails must not leave a stash no state
  # records. A stash that fails instead puts the request back, so the person's
  # request outlives a pause that did not happen.
  local took=0 took_at="" took_reason=""
  if _task_pause_take_request "$id" "task pause"; then
    took=1
    took_at=$_JIG_PAUSE_AT
    took_reason=$_JIG_PAUSE_REASON
  fi

  local stash_sha="" stash_line=""
  if [ "$stash" -eq 1 ]; then
    local changed count
    changed=$(git -C "$JIG_PROJECT" status --porcelain 2>/dev/null)
    count=$(_task_count_lines "$changed")
    if [ "$count" -gt 0 ]; then
      if ! git -C "$JIG_PROJECT" stash push -u -m "jig: $id" >/dev/null; then
        rm -f "$tmp"
        [ "$took" -eq 0 ] || _task_pause_put_request_back "$id" "$took_reason"
        jig_die "task pause: git stash push failed"
      fi
      stash_sha=$(git -C "$JIG_PROJECT" rev-parse "stash@{0}")
      stash_line="stashed $count file(s): $stash_sha"
    else
      stash_line="working tree is clean; nothing to stash"
    fi
  fi

  if [ -n "$stash_sha" ]; then
    _task_state_set_into "$tmp" "$tmp2" paused_stash "$stash_sha"
    mv "$tmp2" "$tmp"
  fi
  mv "$tmp" "$dir/state"
  jig_task_state_forget
  jig_record_changed

  if [ "$as_json" = 1 ]; then
    _task_pause_json "$id" "$stash_sha" "$took" "$took_at" "$took_reason"
    return 0
  fi
  [ -z "$stash_line" ] || printf '%s\n' "$stash_line"
  printf 'paused %s\n' "$id"
}

# _task_pause_json <id> <stash-sha> <took> <requested-at> <reason> — the
# `data` of `task pause --json` (schemas/json.md): the task as `task list
# --json` lists it, after the write, the stash the pause made and the pause
# request it took out of the queue with it (<took> 1), or null for either.
_task_pause_json() {
  local id="$1" sha="$2" took="$3" at="$4" why="$5" r task
  json_str_or_null "$sha"; r="{\"stash\":$_JSON"
  if [ "$took" = 1 ]; then
    json_quote "$at"; r="$r,\"request\":{\"requested_at\":$_JSON"
    json_str_or_null "$why"; r="$r,\"reason\":$_JSON}}"
  else
    r="$r,\"request\":null}"
  fi
  task=$(_task_json_one "$id")
  printf '{"task":%s,"pause":%s}\n' "$task" "$r"
}

# resume refuses when the task is not paused, and, when a stash is recorded,
# when this checkout is not on the task's branch (design §4, as ADR-0012's
# amendment of 2026-10-26 narrows it): the stash is applied here, so here must
# be the task's checkout. Without a stash resume writes the task's state and
# touches no checkout, so it runs anywhere — a task in its own worktree is
# resumed from the main checkout. A failed stash apply ends no pause and
# exits non-zero: a conflicted restore must not silently look like a
# successful resume. An apply that merged the stash with conflicts is
# recorded (`paused_stash_applied`), so the resume after the resolution ends
# the pause instead of applying the stash again (ADR-0012, amendment of
# 2026-10-28). `apply`, never `pop` — the stash entry survives as a backup,
# which is why `paused_stash` itself is not cleared here.
#
# The write is checked against the revision the caller read (`--revision`),
# or the one this command reads before it reads the task, as a `jig queue`
# write is (adr-20261019-the-queue-is-one-file-written-against-a-revision):
# the new state is built whole, the revision claimed, the stash applied, and
# only then the state moved into place — one write under one claim. The stash
# comes after the claim: applied first, a stale claim would leave the task
# paused with its stash already in the tree, and a retry would apply it twice.
# `--json` anywhere runs the whole command as the producer of json_run
# (conventions/json-output.md), so every refusal is an envelope with its code.
task_resume() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_resume_body 1 "$@"
      return
    fi
  done
  _task_resume_body 0 "$@"
}

# _task_resume_body <as_json> <id> [--revision <n>] — the body of `task
# resume`; with <as_json> 1 it runs inside json_run and prints the resumed
# task and what the resume found as data, not the report.
_task_resume_body() {
  local as_json="$1" arg args=()
  shift
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ $# -ge 1 ] || jig_fail usage "$(_task_usage resume)"
  case "$1" in
    -*) jig_fail usage "$(_task_usage resume)" ;;
  esac
  local id="$1" rev="" rev_given=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --revision) [ $# -ge 2 ] || jig_fail usage "task resume: --revision requires a value"; rev="$2"; rev_given=1; shift 2 ;;
      *) jig_fail usage "task resume: unknown argument: $1" ;;
    esac
  done
  [ "$rev_given" -eq 0 ] || [ -n "$rev" ] || jig_fail usage "task resume: --revision is empty"
  [ -z "$rev" ] || jig_revision_valid "$rev" || jig_fail usage "task resume: --revision is not a revision: $rev"
  _task_valid_id "$id" || jig_fail usage "invalid task id: $id"

  # The revision this write is checked against: the caller's, or the one read
  # here before the task is, so the state read below is never newer than it.
  local expected
  if [ -n "$rev" ]; then
    expected=$rev
  else
    expected=$(jig_revision_read)
  fi

  local dir refusal parked=""
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_fail not-found "task resume: unknown task: $id"
  _task_guard_write "$id" "task resume"
  # Parked at the staging branch, as this checkout reads it now: no fetch and
  # no forge, the refs and the forge cache as they stand
  # (adr-20261112-a-task-waiting-at-staging-is-parked-and-resuming-it-is-its-status).
  _task_parked_of_v parked "$id"
  refusal=$(_task_resume_refusal "$id" "$parked") || exit 1
  [ -z "$refusal" ] || jig_fail not-paused "$refusal"

  # Parked and not paused: the task goes back to work for a fix. Its status
  # becomes `active`, so it is no longer parked here, and the fix ships only
  # after verify signs it off again. One write, checked against the revision
  # as the pause's end is.
  if [ "$(task_state_get "$id" paused)" != "true" ]; then
    _task_resume_from_park "$as_json" "$id" "$dir" "$expected" "$parked"
    return 0
  fi

  # Where the task's branch is checked out: this checkout, a worktree, or
  # nowhere (empty). A task paused before it was ever started has no branch,
  # and its checkout is this one, as it always was.
  local state_branch tree="$JIG_PROJECT" wt=""
  state_branch=$(task_state_get "$id" branch)
  if [ -n "$state_branch" ] && [ "$(_task_current_branch)" != "$state_branch" ]; then
    wt=$(_task_worktree_for "$state_branch" "$(_task_worktrees)")
    tree=$wt
  fi

  local sha
  sha=$(task_state_get "$id" paused_stash)
  if [ -n "$sha" ] && [ "$tree" != "$JIG_PROJECT" ]; then
    [ -z "$wt" ] || jig_fail wrong-checkout "task resume: $id has a stash to apply, and $state_branch is checked out in $wt; run it there"
    jig_fail wrong-checkout "task resume: $id has a stash to apply; switch to $state_branch first"
  fi

  # A stash that a resume already merged into this tree with conflicts is
  # recorded as `paused_stash_applied`: applying it again would merge it on
  # top of the person's resolution, so the retry only waits for the conflicts
  # to be gone. Unmerged paths refuse before the claim either way — git
  # refuses an apply over an unresolved index, and no write follows.
  local applied="" unmerged
  [ -z "$sha" ] || [ "$(task_state_get "$id" paused_stash_applied)" != "$sha" ] || applied=$sha
  if [ -n "$sha" ]; then
    unmerged=$(_task_unmerged_paths)
    if [ -n "$unmerged" ]; then
      if [ -n "$applied" ]; then
        jig_fail stash-conflict "task resume: the stash $sha is applied, and $(_task_count_lines "$unmerged") file(s) still have conflicts; resolve them and \`git add\` them, then run \`jig task resume $id\` again"
      fi
      jig_fail stash-conflict "task resume: this checkout has unresolved conflicts; resolve them before \`jig task resume $id\` applies its stash"
    fi
  fi

  local days tmp="$dir/state.tmp.$$"
  jig_cleanup_add "$tmp"
  days=$(_task_days_since "$(task_state_get "$id" paused_at)")
  _task_state_without "$dir" "$tmp" paused paused_at paused_reason paused_stash_applied

  _task_claim_or_refuse "task resume" "$expected" "$tmp"

  local stash_line=""
  if [ -n "$applied" ]; then
    stash_line="stash: applied $sha, conflicts resolved (kept; drop with git stash drop $sha)"
  elif [ -n "$sha" ]; then
    local tree_before
    tree_before=$(git -C "$JIG_PROJECT" status --porcelain 2>/dev/null || true)
    if git -C "$JIG_PROJECT" stash apply "$sha" >/dev/null 2>&1; then
      stash_line="stash: applied $sha (kept; drop with git stash drop $sha)"
    elif [ -n "$(_task_unmerged_paths)" ]; then
      # Merged with conflicts: the stash is in the tree now. Recorded, so the
      # retry after the resolution ends the pause instead of applying it again.
      rm -f "$tmp"
      _task_rewrite_state "$dir" paused_stash_applied "$sha"
      jig_fail stash-conflict "task resume: git stash apply of $sha left conflicts; resolve them and \`git add\` them (or commit), then run \`jig task resume $id\` again; it will not apply the stash twice"
    elif [ "$(git -C "$JIG_PROJECT" status --porcelain 2>/dev/null || true)" != "$tree_before" ]; then
      # Stopped part way without conflicts — an untracked file of the stash
      # that now exists in the tree, most often: what it wrote is in the
      # tree, and applying it again would be refused over those changes.
      rm -f "$tmp"
      _task_rewrite_state "$dir" paused_stash_applied "$sha"
      jig_fail stash-conflict "task resume: git stash apply of $sha stopped part way and applied only some of it; restore what is missing (its untracked files are in $sha^3), then run \`jig task resume $id\` again; it will not apply the stash twice"
    else
      jig_fail stash-conflict "task resume: git stash apply failed for $sha and applied nothing; commit or move aside the changes in its way, then run \`jig task resume $id\` again"
    fi
  fi

  mv "$tmp" "$dir/state"
  jig_task_state_forget
  jig_record_changed

  # What the resume found, read in the task's checkout: uncommitted files only
  # where its branch is checked out; overlap from there or, checked out
  # nowhere, from the branch's commits.
  local n="" overlap="" overlap_known=1 k
  [ -z "$tree" ] || n=$(_task_count_lines "$(git -C "$tree" status --porcelain 2>/dev/null)")
  overlap=$(_task_resume_overlap "$id" "$tree" "$state_branch") || overlap_known=0
  k=$(_task_count_lines "$overlap")

  if [ "$as_json" = 1 ]; then
    _task_resume_json "$id" "$days" "$sha" "$n" "$overlap_known" "$overlap"
    return 0
  fi

  printf 'resumed %s (paused %s days)\n' "$id" "$days"
  [ -z "$n" ] || [ "$n" -eq 0 ] || printf 'uncommitted: %s files\n' "$n"
  [ -z "$stash_line" ] || printf '%s\n' "$stash_line"
  if [ "$k" -gt 0 ]; then
    printf 'overlap: %s files you changed also changed on %s\n' "$k" "$(jig_task_base "$id")"
    printf '%s\n' "$overlap" | sed 's/^/  /'
  fi
  # A pause ends where it began (ADR-0012): a task paused while parked is
  # parked again, and a second resume takes it back for a fix.
  [ -z "$parked" ] || printf 'still parked (%s): jig task resume %s again to fix it\n' "$(_task_parked_words "$parked")" "$id"
}

# _task_resume_from_park <as_json> <id> <dir> <expected-revision> <parked> —
# `task resume` of a task parked at the staging branch and not paused: its
# status goes from `ready` to `active` and `park_resumed_at` records that a
# person took it back for a fix, in one write under a claim of
# <expected-revision>. The record holds until the fix ships into the staging
# branch (`task ship` drops it); the reason it waited was never written.
_task_resume_from_park() {
  local as_json="$1" id="$2" dir="$3" expected="$4" parked="$5" tmp tmp2 reason
  tmp="$dir/state.tmp.$$"
  tmp2="$dir/state.tmp2.$$"
  _task_state_set_into "$dir/state" "$tmp" status active
  _task_state_set_into "$tmp" "$tmp2" park_resumed_at "$(_task_autopilot_now)"
  rm -f "$tmp"
  _task_claim_or_refuse "task resume" "$expected" "$tmp2"
  mv "$tmp2" "$dir/state"
  jig_task_state_forget
  jig_record_changed
  reason=${parked%%$'\t'*}
  if [ "$as_json" = 1 ]; then
    local task
    task=$(_task_json_one "$id")
    json_quote "$reason"
    printf '{"task":%s,"resume":{"paused_days":0,"stash":null,"uncommitted":null,"overlap":null,"parked":%s}}\n' "$task" "$_JSON"
    return 0
  fi
  printf 'resumed %s from parked (%s): fix it, jig verify, then jig task ship %s\n' "$id" "$(_task_parked_words "$parked")" "$id"
}

# _task_unmerged_paths — the paths this checkout's index holds unmerged, one
# per line; empty when there are none.
_task_unmerged_paths() {
  git -C "$JIG_PROJECT" diff --name-only --diff-filter=U 2>/dev/null || true
}

# _task_resume_json <id> <days> <stash-sha> <uncommitted> <overlap-known>
# <overlap> — the `data` of `task resume --json` (schemas/json.md): the task
# as `task list --json` lists it, after the write, and what the resume found.
# <uncommitted> is empty when the task's branch is checked out nowhere;
# <overlap-known> 0 when no base or merge base was found.
_task_resume_json() {
  local id="$1" days="$2" sha="$3" n="$4" known="$5" overlap="$6" r f files="" task
  json_int_or_null "$days"; r="{\"paused_days\":$_JSON"
  if [ -n "$sha" ]; then
    json_quote "$sha"; r="$r,\"stash\":{\"sha\":$_JSON,\"applied\":true}"
  else
    r="$r,\"stash\":null"
  fi
  json_int_or_null "$n"; r="$r,\"uncommitted\":$_JSON"
  if [ "$known" = 1 ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      json_quote "$f"; files="${files:+$files,}$_JSON"
    done <<EOF
$overlap
EOF
    r="$r,\"overlap\":[$files]"
  else
    r="$r,\"overlap\":null"
  fi
  # A resume that ends a pause takes no task back from parking.
  r="$r,\"parked\":null}"
  task=$(_task_json_one "$id")
  printf '{"task":%s,"resume":%s}\n' "$task" "$r"
}

# Live work: unfinished, whether or not it is dormant. A paused task is still
# live — it is listed, with its marker. `consolidated` and `abandoned` are done
# and pile up on a long-lived branch, so they are hidden unless asked for. Same
# convention as `jig context`, which hides superseded and deprecated documents
# behind --all.
_task_is_live() {
  case "$1" in
    active | ready) return 0 ;;
    *) return 1 ;;
  esac
}

task_list() {
  local arg
  # `--json` anywhere asks for the same listing as data, in the envelope
  # (lib/json.sh). It is looked for before anything else runs, so that a
  # refusal — an unknown argument, a project without jig — is an envelope too.
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_list "$@"
      return
    fi
  done
  _task_list "$@"
}

_task_list() {
  jig_require_init
  # A read path: every task's state, the queue and the configuration are read
  # once for the whole listing (jig_read_snapshot_begin).
  jig_read_snapshot_begin
  _task_list_run "$@"
  jig_read_snapshot_end
}

_task_list_run() {
  local show_all=0 want_status="" goals=0 json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) show_all=1; shift ;;
      --goals) goals=1; shift ;;
      --json) json=1; shift ;;
      --status)
        [ $# -ge 2 ] || jig_fail usage "task list: --status requires a value"
        _task_valid_status "$2" || jig_fail usage "task list: invalid status: $2"
        want_status="$2"
        shift 2
        ;;
      *) jig_fail usage "task list: unknown argument: $1" ;;
    esac
  done

  _task_list_select "$show_all" "$want_status"
  if [ "$json" -eq 1 ]; then
    _task_list_json
    return 0
  fi

  local base="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  local dir id class status branch base_branch default_base paused issue line lines="" hidden archived worktrees wt parked
  _task_parked_read "$_TASK_LIST_IDS"
  # `hidden` counts the finished tasks alone in the text; the archive has a
  # line of its own.
  hidden=$((_TASK_LIST_HIDDEN - _TASK_LIST_ARCHIVED))
  archived=$_TASK_LIST_ARCHIVED
  worktrees=$(_task_worktrees)
  # The base is shown only where it is not the project's: a listing where
  # every line says base=main says nothing.
  default_base=$(cfg git.base_branch main)
  local archived_at archived_reason goal
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    dir="$base/$id/"
    task_state_var class "$id" class
    task_state_var status "$id" status
    task_state_var branch "$id" branch
    task_state_var paused "$id" paused
    [ -n "$class" ] || class="-"
    line="$id class=$class status=$status"
    task_state_var issue "$id" issue
    [ -z "$issue" ] || line="$line issue=$issue"
    # A task with no branch has not been started. Saying so is the whole
    # point of representing "not started" as an absence: without a marker the
    # listing shows it as indistinguishable from work in progress.
    if [ -n "$branch" ]; then
      line="$line branch=$branch"
      _task_worktree_for_v wt "$branch" "$worktrees"
      [ -z "$wt" ] || line="$line $(_task_worktree_note "$wt")"
    else
      line="$line not-started"
    fi
    task_state_var base_branch "$id" base_branch
    if [ -n "$base_branch" ] && [ "$base_branch" != "$default_base" ]; then
      line="$line base=$base_branch"
    fi
    [ "$paused" = "true" ] && line="$line paused"
    # Waiting at the staging branch, as this checkout reads it.
    _task_parked_lookup_v parked "$id"
    if [ -n "$parked" ]; then
      line="$line parked=${parked%%$'\t'*}"
      [ "${parked#*$'\t'}" != landing ] || line="$line,landing"
    fi
    if [ "$status" = archived ]; then
      task_state_var archived_at "$id" archived_at
      task_state_var archived_reason "$id" archived_reason
      line="$line archived_at=$archived_at archived_reason=$archived_reason"
    fi
    # What `jig task merge` linked, both ends (comma-separated ids, no spaces).
    local link key
    for key in absorbed_into absorbs absorbs_partly partly_in; do
      task_state_var link "$id" "$key"
      [ -z "$link" ] || line="$line $key=$link"
    done
    # The goal rides on the line through the sort, after a unit separator,
    # and is put on a line of its own below it once sorted.
    if [ "$goals" -ne 0 ]; then
      jig_task_goal_v goal "${dir}task.md"
      line="$line"$'\037'"goal: $goal"
    fi
    lines="$lines
$line"
  done <<EOF
$_TASK_LIST_IDS
EOF
  lines=$(printf '%s\n' "$lines" | sed '/^$/d')
  if [ -z "$lines" ]; then
    if [ "$hidden" -gt 0 ]; then
      printf 'no live tasks (%d finished; jig task list --all)\n' "$hidden"
    elif [ "$archived" -eq 0 ]; then
      printf 'no tasks\n'
    else
      printf 'no live tasks\n'
    fi
    [ "$archived" -gt 0 ] && printf 'archived: %d (jig task list --status archived)\n' "$archived"
    return 0
  fi
  printf '%s\n' "$lines" | sort | awk -F '\037' '{ print $1; if (NF > 1) print "  " $2 }'
  [ "$hidden" -gt 0 ] && printf '(%d finished; jig task list --all)\n' "$hidden"
  [ "$archived" -gt 0 ] && printf 'archived: %d (jig task list --status archived)\n' "$archived"
  return 0
}

# _task_list_select <show_all> <want_status> — which tasks `task list` shows,
# in the text and the JSON form alike: _TASK_LIST_IDS gets their ids, one per
# line, _TASK_LIST_HIDDEN how many finished or archived tasks were left out and
# _TASK_LIST_ARCHIVED how many of those were archived. Called as
# a plain command, never through $(...), so both globals reach the caller.
_TASK_LIST_IDS=""
_TASK_LIST_HIDDEN=0
_TASK_LIST_ARCHIVED=0
_task_list_select() {
  local show_all="$1" want_status="$2" dir id status
  _TASK_LIST_IDS=""
  _TASK_LIST_HIDDEN=0
  _TASK_LIST_ARCHIVED=0
  for dir in "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"/*/; do
    [ -f "${dir}state" ] || continue
    id=${dir%/}
    id=${id##*/}
    # Same rule as _task_candidates_for_branch: skip, never die on, a
    # directory whose name is not a task id.
    _task_valid_id "$id" || continue
    task_state_var status "$id" status
    if [ -n "$want_status" ]; then
      [ "$status" = "$want_status" ] || continue
    elif [ "$show_all" -eq 0 ] && ! _task_is_live "$status"; then
      _TASK_LIST_HIDDEN=$((_TASK_LIST_HIDDEN + 1))
      # The archive is a subset of what is hidden, counted on its own so the
      # listing can point at it (adr-20261027-a-task-nobody-finished-is-
      # archived-not-purged).
      [ "$status" != archived ] || _TASK_LIST_ARCHIVED=$((_TASK_LIST_ARCHIVED + 1))
      continue
    fi
    _TASK_LIST_IDS="$_TASK_LIST_IDS$id
"
  done
  return 0
}

# The housekeeping flags `task list --json` reports, in the words the log
# writes them (housekeeping_decide, _hk_report). Each is asked through
# hklog_flagged_ids, so a flag this disk already disproves is dropped exactly
# as the status page drops it.
_TASK_LIST_HK_FLAGS="needs-consolidation wrong-base abandoned? worktree-kept base-unreleased STALE_CANDIDATE"

# The forge cache's lines (forgecache_read), read once by _task_list_json for
# every task it lists.
_TASK_LIST_FORGE_CACHE=""

# A task's staging state, read once per listing (_task_list_staging_read):
# _TASK_LIST_STAGING_ON is 1 in a project on the staging flow, the one kind
# whose objects carry `staging`, and _TASK_LIST_STAGING holds
# "<id><TAB>on|behind" for the tasks whose work reached the staging branch.
_TASK_LIST_STAGING_ON=""
_TASK_LIST_STAGING=""
# The staging branch's name on that flow, read with it: where a task's pull
# request goes (its `pull_request`), asked once per listing.
_TASK_LIST_STAGING_BRANCH=""
# What the close action asks of git, answered once per listing on that flow so
# a row starts no process (_task_close_staging_refusal): the base ref of the
# project's base branch, and the local and origin branches that are, and are
# not, ancestors of it — each list newline-wrapped, one full refname per line.
_TASK_LIST_BASE_REF=""
_TASK_LIST_REFS_MERGED=""
_TASK_LIST_REFS_UNMERGED=""

# _task_list_staging_read <ids> — fill the staging globals above for the tasks
# <ids> names, one per line: their branch and base from the listing's snapshot,
# and the answer from jig_staging_states (common.sh) in one call, plus the base
# ref and the branches in and not in it (two `git for-each-ref`), so the
# processes it starts do not grow with the tasks. A project on any other flow
# reads nothing and its objects keep their shape byte for byte.
_TASK_LIST_STAGING_READ=""
_task_list_staging_read() {
  local ids="$1" staging id branch base defbase rows="" t=$'\t' nl=$'\n'
  _TASK_LIST_STAGING_READ=1
  _TASK_LIST_STAGING_ON=""
  _TASK_LIST_STAGING=""
  _TASK_LIST_STAGING_BRANCH=""
  _TASK_LIST_BASE_REF=""
  _TASK_LIST_REFS_MERGED=""
  _TASK_LIST_REFS_UNMERGED=""
  staging=$(jig_staging_in_use) || return 0
  _TASK_LIST_STAGING_ON=1
  _TASK_LIST_STAGING_BRANCH=$staging
  cfg_v defbase git.base_branch main
  _TASK_LIST_BASE_REF=$(jig_base_ref "$defbase")
  if [ -n "$_TASK_LIST_BASE_REF" ]; then
    _TASK_LIST_REFS_MERGED=$nl$(git -C "$JIG_PROJECT" for-each-ref --format='%(refname)' --merged="$_TASK_LIST_BASE_REF" refs/heads refs/remotes/origin 2>/dev/null)$nl
    _TASK_LIST_REFS_UNMERGED=$nl$(git -C "$JIG_PROJECT" for-each-ref --format='%(refname)' --no-merged="$_TASK_LIST_BASE_REF" refs/heads refs/remotes/origin 2>/dev/null)$nl
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    task_state_var branch "$id" branch
    [ -n "$branch" ] || continue
    jig_task_base_v base "$id"
    rows="$rows$id$t$branch$t$base
"
  done <<EOF
$ids
EOF
  _TASK_LIST_STAGING=$(jig_staging_states "$staging" "$rows")
  _task_parked_read "$ids" "$_TASK_LIST_STAGING"
}

# --- parked at the staging branch
# (adr-20261112-a-task-waiting-at-staging-is-parked-and-resuming-it-is-its-status)
#
# Which tasks wait at the staging branch, as this checkout reads them:
# "<id><TAB>review|signal<TAB>landing|-" lines, filled by _task_parked_read.
# The reason is jig_parked_states' (common.sh), from git and the forge cache
# alone; what is laid over it is what only the owner's checkout knows:
#   - only a `ready` task is parked: every shipped task is `ready` (verify's
#     record);
#   - a task a person took back for a fix (`jig task resume`) is not parked
#     while `park_resumed_at` holds, through its own verify and up to the ship
#     that sends the fix to the staging branch, which drops the record. Only
#     that the person took it back is written; why it waits never is;
#   - `landing` when the reason is `review`, the flow lands by pull request,
#     this person's agent.git is below `merge` (they land it, not Jig) and the
#     review is over: the pull request is approved as housekeeping last read it
#     from the forge (the forge cache's review column), or the project asks for
#     no review (`git.staging_review: none`). Waiting for a reviewer, changes
#     requested, no review and a review nobody has read yet are not a landing:
#     the hint tells a board to offer the landing only when it can succeed.
_TASK_PARKED=""

# The review of each parked `review` task, beside _TASK_PARKED and never in it
# (its lines are read by their three fields): "<id><TAB><review><TAB><waiting>"
# lines, <review> approved|changes|waiting|none or `-` when the cache does not
# say, <waiting> the reviewers still requested, comma-separated, or `-`.
# Filled by _task_parked_read from the forge cache alone; a `signal` task has
# no line. The pull request is the task's own: the one its `pr_url` names while
# the cache has it and it goes into the staging branch, else the newest from
# its branch into the staging branch, as jig_parked_states picks it.
_TASK_PARKED_REVIEW=""

# _task_parked_read <ids> [<staging-states>] — fill _TASK_PARKED for the tasks
# <ids> names, one per line, in one jig_parked_states call: a fixed number of
# processes however many tasks there are. <staging-states> is
# jig_staging_states' answer for them when the caller already asked it. Off a
# sound staging flow nothing is read and _TASK_PARKED stays empty. Called as a
# plain command, never through $(...), so the global reaches the caller.
_task_parked_read() {
  local ids="$1" staging land level default_base id st branch base pr pm rs rows="" t=$'\t'
  local answer pid reason flow cache review waiting sreview found pbranch ppr
  _TASK_PARKED=""
  _TASK_PARKED_REVIEW=""
  [ -n "$ids" ] || return 0
  # The direct flow answers with no process at all.
  cfg_v flow git.flow direct
  [ "$flow" = staging ] || return 0
  staging=$(jig_staging_in_use) || return 0
  default_base=$(cfg git.base_branch main)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    task_state_var st "$id" status
    [ "$st" = ready ] || continue
    task_state_var branch "$id" branch
    [ -n "$branch" ] || continue
    # A task of an epic ships into its epic, never into staging.
    jig_task_base_v base "$id"
    [ "$base" = "$default_base" ] || continue
    task_state_var pr "$id" pr_url
    task_state_var pm "$id" promote_url
    task_state_var rs "$id" park_resumed_at
    rows="$rows$id$t$branch$t$base$t${pr:--}$t${pm:--}$t${rs:--}
"
  done <<EOF
$ids
EOF
  [ -n "$rows" ] || return 0
  # shellcheck source=lib/forgecache.sh
  . "$JIG_LIB/forgecache.sh"
  cfg_v land git.staging_land pr
  cache=$(forgecache_read)
  if [ $# -ge 2 ]; then
    answer=$(jig_parked_states "$staging" "$land" "$rows" "$cache" "$2")
  else
    answer=$(jig_parked_states "$staging" "$land" "$rows" "$cache")
  fi
  [ -n "$answer" ] || return 0
  jig_staging_git_v level || true; level=${level%%"$t"*}
  cfg_v sreview git.staging_review ask
  while IFS="$t" read -r pid reason; do
    [ -n "$pid" ] || continue
    review="-"
    waiting="-"
    if [ "$reason" = review ]; then
      # The review of this task's own pull request, from the cache alone.
      found=""
      task_state_var ppr "$pid" pr_url
      if [ -n "$ppr" ]; then
        forgecache_entry_url "$cache" "$ppr"
        [ "$_FORGECACHE_BASE" != "$staging" ] || found=1
      fi
      if [ -z "$found" ]; then
        task_state_var pbranch "$pid" branch
        forgecache_entry "$cache" "$pbranch" "$staging"
      fi
      review=${_FORGECACHE_REVIEW:--}
      waiting=${_FORGECACHE_WAITING:--}
      _TASK_PARKED_REVIEW="$_TASK_PARKED_REVIEW$pid$t$review$t$waiting
"
    fi
    if [ "$reason" = review ] && [ "$land" = pr ] && [ "$level" != merge ] \
      && { [ "$review" = approved ] || [ "$sreview" = none ]; }; then
      _TASK_PARKED="$_TASK_PARKED$pid$t$reason${t}landing
"
    else
      _TASK_PARKED="$_TASK_PARKED$pid$t$reason$t-
"
    fi
  done <<EOF
$answer
EOF
}

# _task_parked_review_lookup_v <var> <id> — "<review><TAB><waiting>" from
# _TASK_PARKED_REVIEW into <var>, each `-` when the cache does not say; empty
# when the task is not parked for review. In the caller's shell, without a
# process.
_task_parked_review_lookup_v() {
  local __tpr_nl=$'\n' __tpr_t=$'\t' __tpr_all __tpr_rest
  __tpr_all="$__tpr_nl$_TASK_PARKED_REVIEW"
  case "$__tpr_all" in
    *"$__tpr_nl$2$__tpr_t"*)
      __tpr_rest=${__tpr_all#*"$__tpr_nl$2$__tpr_t"}
      printf -v "$1" '%s' "${__tpr_rest%%"$__tpr_nl"*}" ;;
    *) printf -v "$1" '%s' "" ;;
  esac
}

# _task_review_json_v <var> <review> <waiting> — a review as the task's JSON
# carries it, into <var>: {"state":..,"waiting_for":[..]}, or null when the
# review is unknown (empty or `-`: a cache line written before the column
# existed, one `task ship` recorded, a forge that was not asked or could not
# say). The same shape `task pr-status --json` prints as `review`. In the
# caller's shell; <waiting> is comma-separated logins, `-` or empty for none.
_task_review_json_v() {
  local __trj_r="$2" __trj_w="$3"
  case "$__trj_r" in
    approved | changes | waiting | none) ;;
    *) printf -v "$1" '%s' null; return 0 ;;
  esac
  [ "$__trj_w" != "-" ] || __trj_w=""
  _task_json_ids "$__trj_w"
  printf -v "$1" '{"state":"%s","waiting_for":%s}' "$__trj_r" "$_JSON"
}

# _task_parked_lookup_v <var> <id> — "<reason><TAB><hint>" from _TASK_PARKED
# into <var>, the hint `-` for none; empty when the task is not parked. In the
# caller's shell, without a process.
_task_parked_lookup_v() {
  local __tpl_nl=$'\n' __tpl_t=$'\t' __tpl_all __tpl_rest
  __tpl_all="$__tpl_nl$_TASK_PARKED"
  case "$__tpl_all" in
    *"$__tpl_nl$2$__tpl_t"*)
      __tpl_rest=${__tpl_all#*"$__tpl_nl$2$__tpl_t"}
      printf -v "$1" '%s' "${__tpl_rest%%"$__tpl_nl"*}" ;;
    *) printf -v "$1" '%s' "" ;;
  esac
}

# _task_parked_of_v <var> <id> — the same for one task, read now: what
# `task resume`, the autopilot's guards and the checkout's occupancy ask.
_task_parked_of_v() {
  _task_parked_read "$2"
  _task_parked_lookup_v "$1" "$2"
}

# _task_parked_ids_here — the ids of the tasks whose branch is checked out in
# this checkout and that are parked, one per line: what
# jig_checkout_occupants (checkout.sh) is told, so that it neither sources
# this file nor decides parking itself. Nothing off the staging flow.
_task_parked_ids_here() {
  local here dir id br st ids="" flow
  cfg_v flow git.flow direct
  [ "$flow" = staging ] || return 0
  here=$(_task_current_branch)
  [ -n "$here" ] || return 0
  for dir in "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"/*/; do
    [ -f "${dir}state" ] || continue
    id=${dir%/}
    id=${id##*/}
    _task_valid_id "$id" || continue
    task_state_var br "$id" branch
    [ "$br" = "$here" ] || continue
    task_state_var st "$id" status
    [ "$st" = ready ] || continue
    ids="$ids$id
"
  done
  [ -n "$ids" ] || return 0
  _task_parked_read "$ids"
  _task_parked_ids
}

# _task_parked_ids — the ids _TASK_PARKED holds, one per line.
_task_parked_ids() {
  local line t=$'\t'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "${line%%"$t"*}"
  done <<EOF
$_TASK_PARKED
EOF
}

# _task_parked_words <reason><TAB><hint> — how a person reads it: `signal`,
# `review`, or `review, landing`.
_task_parked_words() {
  local reason="${1%%$'\t'*}" hint="${1#*$'\t'}"
  if [ "$hint" = landing ]; then
    printf '%s, landing\n' "$reason"
  else
    printf '%s\n' "$reason"
  fi
}

# _task_list_hk_flagged — "<id><TAB><flag>" for every housekeeping flag that
# still stands, asked once per flag rather than once per task. Needs hklog.sh
# sourced. Pathname expansion is off for the split: `abandoned?` is a glob.
_task_list_hk_flagged() {
  local flag ids fid t
  t=$(printf '\t')
  set -f
  for flag in $_TASK_LIST_HK_FLAGS; do
    ids=$(hklog_flagged_ids "$flag")
    while IFS= read -r fid; do
      [ -n "$fid" ] || continue
      printf '%s%s%s\n' "$fid" "$t" "$flag"
    done <<EOF
$ids
EOF
  done
  set +f
}

# _task_spec_json_v <var> <task.md> — the `spec` of a task's JSON into <var>:
# `{"id","title","phase","epic"}` or `null`. `title` is the first heading of
# the spec's spec.md and `epic` the branch its roadmap.md declares (open or
# finished), each `null` when the spec does not have it in this checkout;
# `phase` the number of the link's `Phase <n>`, `null` when it names none.
_task_spec_json_v() {
  local __tsj_var="$1" __tsj_sid __tsj_phase __tsj_dir __tsj_t __tsj_e __tsj_o
  printf -v "$__tsj_var" '%s' null
  [ -f "$2" ] || return 0
  jig_spec_link_v __tsj_sid "$2" || return 0
  [ -n "$__tsj_sid" ] || return 0
  __tsj_phase=$_JIG_SPEC_PHASE
  __tsj_dir="$JIG_PROJECT/$JIG_AI_DIR/specs/$__tsj_sid"
  jig_spec_title_v __tsj_t "$__tsj_dir/spec.md"
  __tsj_e=""
  jig_spec_epic_v __tsj_e "$__tsj_dir/roadmap.md" || __tsj_e=""
  json_quote "$__tsj_sid"; __tsj_o="{\"id\":$_JSON"
  json_str_or_null "$__tsj_t"; __tsj_o="$__tsj_o,\"title\":$_JSON"
  json_int_or_null "$__tsj_phase"; __tsj_o="$__tsj_o,\"phase\":$_JSON"
  json_str_or_null "${__tsj_e% *}"; __tsj_o="$__tsj_o,\"epic\":$_JSON}"
  printf -v "$__tsj_var" '%s' "$__tsj_o"
}

# _task_json_one <id> — one task as `task list --json` lists it, for a write
# that answers with the task it wrote (`task resume --json`): the same
# producer, with the worktrees, the forge cache and the housekeeping flags
# read as the listing reads them.
_task_json_one() {
  # shellcheck source=lib/hklog.sh
  . "$JIG_LIB/hklog.sh"
  # shellcheck source=lib/forgecache.sh
  . "$JIG_LIB/forgecache.sh"
  _TASK_LIST_FORGE_CACHE=$(forgecache_read)
  _task_list_staging_read "$1"
  _task_list_json_task "$1" "$(_task_worktrees)" "$(_task_list_hk_flagged)"
}

# _task_list_json — the `data` of `task list --json` for the tasks
# _task_list_select chose: one JSON object on stdout, in the shape
# schemas/json.md pins. Every value comes from the producer that already
# answers it for the text listing, the status page or the gates; nothing here
# decides what they do not. Local reads only: no fetch, no forge.
_task_list_json() {
  # shellcheck source=lib/hklog.sh
  . "$JIG_LIB/hklog.sh"
  # shellcheck source=lib/forgecache.sh
  . "$JIG_LIB/forgecache.sh"
  local worktrees flagged run ran_at forge t=$'\t' id rows="" row
  worktrees=$(_task_worktrees)
  # What housekeeping last heard from the forge, read once per listing.
  _TASK_LIST_FORGE_CACHE=$(forgecache_read)
  flagged=$(_task_list_hk_flagged)
  _task_list_staging_read "$_TASK_LIST_IDS"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    _task_list_json_task_v row "$id" "$worktrees" "$flagged"
    rows="$rows$id$t$row
"
  done <<EOF
$_TASK_LIST_IDS
EOF
  printf '{"tasks":['
  # Sorted by id, as the text listing is. A record holds no raw tab or
  # newline (json_quote escapes both), so the id column is the whole key.
  printf '%s' "$rows" | sed '/^$/d' | LC_ALL=C sort -t "$t" -k1,1 | cut -f2- \
    | awk 'NR > 1 { printf "," } { printf "%s", $0 }'
  # `hidden` stays every task left out; `archived` is the part of it that the
  # archive holds.
  printf '],"hidden":%s,"archived":%s,"housekeeping":' "$_TASK_LIST_HIDDEN" "$_TASK_LIST_ARCHIVED"
  run=$(hklog_last_run)
  if [ -z "$run" ]; then
    printf 'null'
  else
    ran_at=${run%%"$t"*}
    forge=${run#*"$t"}
    [ "$forge" != "-" ] || forge=""
    json_quote "$ran_at"
    printf '{"ran_at":%s,' "$_JSON"
    json_str_or_null "$forge"
    printf '"forge":%s}' "$_JSON"
  fi
  printf '}\n'
}

# _task_list_json_task <id> <worktrees> <flagged> — one task as a JSON object
# on one line. <worktrees> is a _task_worktrees listing and <flagged> the
# "<id><TAB><flag>" lines _task_list_json collected; both are read once per
# listing, not once per task.
_task_list_json_task() {
  local row
  _task_list_json_task_v row "$@"
  printf '%s\n' "$row"
}

# _task_list_json_task_v <var> <id> <worktrees> <flagged> — the same object
# into <var>, built in the caller's shell. Every field comes through
# task_state_var, from the snapshot of the task's file the listing holds, and
# every helper answers into a variable: a fixed number of processes per task
# however many fields it has — git for a worktree's count, the hashes of a
# design, one subshell per guard of the actions table.
_task_list_json_task_v() {
  local __tlj_var="$1" id="$2" worktrees="$3" flagged="$4" line o t=$'\t' v
  local class status issue consolidated paused created updated branch base pr_url gate_by
  local wt n gate facts state repairs stage stage_at stop stop_at phase handover_at goal flag flags="" mode atext
  local into defbase found pr_base rvl rvj promote_url pr_url_state="" base_state=""
  task_state_var class "$id" class
  task_state_var status "$id" status
  task_state_var issue "$id" issue
  task_state_var consolidated "$id" knowledge_consolidated
  task_state_var paused "$id" paused
  task_state_var created "$id" created_at
  task_state_var updated "$id" updated_at
  task_state_var branch "$id" branch
  task_state_var pr_url "$id" pr_url
  task_state_var gate_by "$id" gate_by

  json_quote "$id"; o="{\"id\":$_JSON"
  json_str_or_null "$class"; o="$o,\"class\":$_JSON"
  json_str_or_null "$status"; o="$o,\"status\":$_JSON"
  json_str_or_null "$issue"; o="$o,\"issue\":$_JSON"
  task_dir_v v "$id"
  jig_task_goal_v goal "$v/task.md"
  [ "$goal" != "(none)" ] || goal=""
  json_str_or_null "$goal"; o="$o,\"goal\":$_JSON"
  json_bool "$consolidated"; o="$o,\"knowledge_consolidated\":$_JSON"
  json_bool "$paused"; o="$o,\"paused\":$_JSON"
  # A pause asked of the task and not yet honoured, with when it was asked:
  # the card shows its age (common.sh reads the queue file).
  if jig_pause_request "$id"; then
    json_quote "$_JIG_PAUSE_AT"; o="$o,\"pause_request\":{\"requested_at\":$_JSON"
    json_str_or_null "$_JIG_PAUSE_REASON"; o="$o,\"reason\":$_JSON}"
  else
    o="$o,\"pause_request\":null"
  fi
  json_str_or_null "$created"; o="$o,\"created_at\":$_JSON"
  json_str_or_null "$updated"; o="$o,\"updated_at\":$_JSON"
  task_state_var v "$id" archived_at; json_str_or_null "$v"; o="$o,\"archived_at\":$_JSON"
  task_state_var v "$id" archived_reason; json_str_or_null "$v"; o="$o,\"archived_reason\":$_JSON"
  task_state_var v "$id" archived_from; json_str_or_null "$v"; o="$o,\"archived_from\":$_JSON"
  task_state_var v "$id" absorbed_into; json_str_or_null "$v"; o="$o,\"absorbed_into\":$_JSON"
  task_state_var v "$id" absorbs; _task_json_ids "$v"; o="$o,\"absorbs\":$_JSON"
  task_state_var v "$id" absorbs_partly; _task_json_ids "$v"; o="$o,\"absorbs_partly\":$_JSON"
  task_state_var v "$id" partly_in; _task_json_ids "$v"; o="$o,\"partly_in\":$_JSON"
  json_str_or_null "$branch"; o="$o,\"branch\":$_JSON"
  jig_task_base_v base "$id"
  json_quote "$base"; o="$o,\"base_branch\":$_JSON"
  # Whether the task's work is on the staging branch, derived from git by its
  # branch (jig_staging_states): only in a project on the staging flow.
  if [ "$_TASK_LIST_STAGING_ON" = 1 ]; then
    v=""
    while IFS="$t" read -r line flag; do
      [ "$line" != "$id" ] || v=$flag
    done <<EOF
$_TASK_LIST_STAGING
EOF
    json_str_or_null "$v"; o="$o,\"staging\":$_JSON"
    # Parked at the staging branch, as this checkout reads it (_task_parked_read).
    _task_parked_lookup_v v "$id"
    if [ -n "$v" ]; then
      json_quote "${v%%$'\t'*}"; line=$_JSON
      if [ "${v#*$'\t'}" = landing ]; then flag='"landing"'; else flag=null; fi
      # Whom a review waits for, as the forge cache holds it: null for a task
      # parked for a signal, and for a review the cache cannot say.
      rvj=null
      if [ "${v%%$'\t'*}" = review ]; then
        _task_parked_review_lookup_v rvl "$id"
        _task_review_json_v rvj "${rvl%%"$t"*}" "${rvl#*"$t"}"
      fi
      o="$o,\"parked\":{\"reason\":$line,\"hint\":$flag,\"review\":$rvj}"
    else
      o="$o,\"parked\":null"
    fi
  fi

  # The spec the task was filed from, read from its task.md and the spec's own
  # files, offline and with no process (jig_spec_link_v and the readers
  # beside it): null without a link, or with two to different specs.
  task_dir_v v "$id"
  _task_spec_json_v v "$v/task.md"
  o="$o,\"spec\":$v"

  wt=""
  [ -z "$branch" ] || _task_worktree_for_v wt "$branch" "$worktrees"
  if [ -n "$wt" ]; then
    json_quote "$wt"
    _task_worktree_uncommitted_v n "$wt"
    o="$o,\"worktree\":{\"path\":$_JSON,\"uncommitted\":$n}"
  else
    o="$o,\"worktree\":null"
  fi

  _task_gate_state_v gate "$id"
  if [ -n "$gate" ]; then
    json_quote "$gate"; o="$o,\"gate\":{\"state\":$_JSON"
    # Who approved: nobody while it waits; an approval recorded before
    # `gate_by` existed is read as `human` (schemas/state.md).
    case "$gate" in
      waiting | answered) _JSON=null ;;
      *) json_quote "${gate_by:-human}" ;;
    esac
    o="$o,\"by\":$_JSON"
    # The questions of the design as it is now, and the last answer a human
    # gave (the design it answered may be an older one): schemas/json.md.
    _task_gate_questions_v v "$id"
    o="$o,\"questions\":$v"
    _task_gate_answer_json_v v "$id"
    o="$o,\"answer\":$v}"
  else
    o="$o,\"gate\":null"
  fi

  _task_autopilot_facts_v facts "$id"
  if [ -n "$facts" ]; then
    IFS="$t" read -r state repairs stage stage_at stop stop_at phase handover_at answered_at <<EOF
$facts
EOF
    [ "$stage" != "-" ] || stage=""
    [ "$stage_at" != "-" ] || stage_at=""
    [ "$stop" != "-" ] || stop=""
    [ "$stop_at" != "-" ] || stop_at=""
    [ "$phase" != "-" ] || phase=""
    [ "$handover_at" != "-" ] || handover_at=""
    [ "$answered_at" != "-" ] || answered_at=""
    json_quote "$state"; o="$o,\"autopilot\":{\"state\":$_JSON"
    # The mode the gates read: anything but `unattended` is attended.
    _task_autopilot_mode_v mode "$id"
    json_quote "$mode"; o="$o,\"mode\":$_JSON"
    json_int_or_null "$repairs"; o="$o,\"repairs\":$_JSON"
    json_str_or_null "$stage"; o="$o,\"stage\":$_JSON"
    json_str_or_null "$stage_at"; o="$o,\"stage_at\":$_JSON"
    json_str_or_null "$stop"; o="$o,\"stop_reason\":$_JSON"
    json_str_or_null "$stop_at"; o="$o,\"stop_at\":$_JSON"
    json_str_or_null "$phase"; o="$o,\"phase\":$_JSON"
    json_str_or_null "$handover_at"; o="$o,\"handover_at\":$_JSON"
    json_str_or_null "$answered_at"; o="$o,\"answered_at\":$_JSON}"
  else
    o="$o,\"autopilot\":null"
  fi

  # The task's own pull request, with its state, checks and review as
  # housekeeping last heard them from the forge (lib/forgecache.sh). Reading
  # never asks the forge: an old entry says how old it is, a missing one is
  # null. It is the one `task ship` recorded (`pr_url`), found by its address;
  # failing that, or with none recorded (opened by hand), the newest from the
  # task's branch into where its pull request goes: the staging branch on the
  # staging flow for a task of the default base, else the task's base.
  # `base` is where the pull request goes.
  cfg_v defbase git.base_branch main
  into=$base
  if [ "$_TASK_LIST_STAGING_ON" = 1 ] && [ -n "$_TASK_LIST_STAGING_BRANCH" ] && [ "$base" = "$defbase" ]; then
    into=$_TASK_LIST_STAGING_BRANCH
  fi
  # What the actions table is told of the pull request stays what it was: the
  # entry from the task's branch into its base, and only with a recorded
  # `pr_url` (below).
  local pr_state="" pr_ci="" pr_mergeable=""
  if [ -n "$pr_url" ]; then
    forgecache_entry "$_TASK_LIST_FORGE_CACHE" "$branch" "$base"
    pr_state=$_FORGECACHE_STATE
    pr_ci=$_FORGECACHE_CI
    pr_mergeable=$_FORGECACHE_MERGEABLE
  fi
  found=""
  if [ -n "$pr_url" ]; then
    forgecache_entry_url "$_TASK_LIST_FORGE_CACHE" "$pr_url"
    if [ -n "$_FORGECACHE_HEAD" ]; then
      found=1
    else
      forgecache_entry "$_TASK_LIST_FORGE_CACHE" "$branch" "$into"
      # Another pull request of the same branch never lends its state to
      # the one the task recorded; a line without an address may.
      if [ -n "$_FORGECACHE_URL" ] && [ "$_FORGECACHE_URL" != "$pr_url" ]; then
        _forgecache_clear
      fi
      [ -z "$_FORGECACHE_HEAD" ] || found=1
    fi
    v=$pr_url
  else
    forgecache_entry "$_TASK_LIST_FORGE_CACHE" "$branch" "$into"
    [ -z "$_FORGECACHE_HEAD" ] || found=1
    v=$_FORGECACHE_URL
  fi
  # The close reads the state of the pull request `pr_url` names.
  [ -z "$pr_url" ] || pr_url_state=$_FORGECACHE_STATE
  if [ -n "$pr_url" ] || [ -n "$found" ]; then
    pr_base=$into
    [ -z "$found" ] || pr_base=$_FORGECACHE_BASE
    json_str_or_null "$v"; o="$o,\"pull_request\":{\"url\":$_JSON"
    json_str_or_null "$_FORGECACHE_STATE"; o="$o,\"state\":$_JSON"
    json_str_or_null "$_FORGECACHE_CI"; o="$o,\"ci\":$_JSON"
    json_str_or_null "$_FORGECACHE_AT"; o="$o,\"fetched_at\":$_JSON"
    json_quote "$pr_base"; o="$o,\"base\":$_JSON"
    json_str_or_null "$_FORGECACHE_MERGEABLE"; o="$o,\"mergeable\":$_JSON"
    _task_review_json_v rvj "$_FORGECACHE_REVIEW" "$_FORGECACHE_WAITING"
    o="$o,\"review\":$rvj}"
  else
    o="$o,\"pull_request\":null"
  fi

  # The promotion pull request on the staging flow: from the task's branch
  # into the default base, as the cache holds it, else the address `task
  # promote` recorded. A task of an epic has none.
  if [ "$_TASK_LIST_STAGING_ON" = 1 ]; then
    found=""
    task_state_var promote_url "$id" promote_url
    if [ "$base" = "$defbase" ]; then
      forgecache_entry "$_TASK_LIST_FORGE_CACHE" "$branch" "$base"
      [ -z "$_FORGECACHE_HEAD" ] || found=1
    else
      promote_url=""
      forgecache_entry "" "" ""
    fi
    if [ -n "$found" ] || [ -n "$promote_url" ]; then
      v=$_FORGECACHE_URL
      [ -n "$v" ] || v=$promote_url
      json_str_or_null "$v"; o="$o,\"promotion\":{\"url\":$_JSON"
      json_str_or_null "$_FORGECACHE_STATE"; o="$o,\"state\":$_JSON"
      json_str_or_null "$_FORGECACHE_CI"; o="$o,\"ci\":$_JSON"
      json_str_or_null "$_FORGECACHE_MERGEABLE"; o="$o,\"mergeable\":$_JSON"
      json_str_or_null "$_FORGECACHE_AT"; o="$o,\"fetched_at\":$_JSON}"
    else
      o="$o,\"promotion\":null"
    fi
  fi

  # A `jig task ship` of this task waiting for CI right now (jig_shipping_*,
  # common.sh): since when, or null.
  jig_shipping_since_v v "$id"
  if [ -n "$v" ]; then
    json_quote "$v"; o="$o,\"shipping\":{\"since\":$_JSON}"
  else
    o="$o,\"shipping\":null"
  fi

  while IFS="$t" read -r line flag; do
    [ "$line" = "$id" ] || continue
    json_quote "$flag"
    flags="${flags:+$flags,}$_JSON"
  done <<EOF
$flagged
EOF
  o="$o,\"housekeeping_flags\":[$flags]"

  # The hooks a person waived for this task (`task waive`), as the file holds
  # them; `[]` when there are none.
  local w_gate w_path w_date w_reason waivers="" wline wtext
  _task_waivers_v wtext "$id"
  while IFS="$t" read -r w_gate w_path w_date w_reason; do
    [ -n "$w_gate" ] || continue
    json_quote "$w_gate"; wline="{\"gate\":$_JSON"
    json_quote "$w_path"; wline="$wline,\"path\":$_JSON"
    json_quote "$w_date"; wline="$wline,\"date\":$_JSON"
    json_quote "$w_reason"; wline="$wline,\"reason\":$_JSON}"
    waivers="${waivers:+$waivers,}$wline"
  done <<EOF
$wtext
EOF
  o="$o,\"waivers\":[$waivers]"

  # What a person may do next (_task_actions): every row of the table, with
  # the pull request's state as the forge cache holds it, never the forge's.
  local action offered command reason actions=""
  # What the cache says of a pull request from the branch into the task's base
  # (on the staging flow, its promotion): `close` reads it for every task with
  # a branch, as it reads the state of the pull request `pr_url` names.
  if [ -n "$branch" ]; then
    forgecache_entry "$_TASK_LIST_FORGE_CACHE" "$branch" "$base"
    base_state=$_FORGECACHE_STATE
  fi
  # Housekeeping found the work in the base (needs-consolidation, its own
  # forge and git tiers): the close reads that as a merge into the base.
  case ",$flags," in
    *',"needs-consolidation",'*) base_state=merged ;;
  esac
  # The table withholds the close for a closed `pr_url`: a cache can only
  # withhold, never offer more than the command; the command adopts a merged
  # replacement (_task_close_adopt_v).
  _task_actions_v atext "$id" "$pr_state" "$pr_ci" "$pr_mergeable" "$pr_url_state" "$base_state"
  while IFS="$t" read -r action offered command reason; do
    [ -n "$action" ] || continue
    json_quote "$action"; line="{\"id\":$_JSON"
    json_quote "$command"; line="$line,\"command\":$_JSON,\"offered\":$offered"
    json_str_or_null "$reason"; line="$line,\"reason\":$_JSON}"
    actions="${actions:+$actions,}$line"
  done <<EOF
$atext
EOF
  printf -v "$__tlj_var" '%s,"actions":[%s]}' "$o" "$actions"
}

# --- what a person may do next (adr-20261015-one-table-of-what-a-person-may-do)
#
# One table of the moves a person makes on a task, each a Jig command, and
# whether this task's state lets it through. No consumer keeps a copy: `task
# list --json` reports it per task (schemas/json.md). The rule is one-way —
# an action offered is one its command accepts on this task's state — and it
# holds because each row asks the command's own guard (_task_*_refusal), whose
# text is the reason a row is withheld. The table may withhold more than the
# command refuses: a finished task offers nothing but `reopen`, a design
# already approved offers no approval, a merged pull request no ship. What a
# command refuses by the checkout it runs in, by the network or by the value a
# person types is the command's when it runs, never the table's.
#
# The rows, in their order; the ids are a contract. The pause request rows ask
# the guards `jig queue request|cancel` asks (common.sh), which read the queue.
_TASK_ACTIONS="start pause resume request-pause cancel-pause-request approve-gate answer-gate answer-stop handover set-class ship land request-review merge promote pr-status close abandon archive unarchive reopen drop-item"

# _task_actions <id> <pr-state> [<ci> [<mergeable> [<pr-url-state>
# [<base-state>]]]] — one line per row of the table:
# `<action><TAB><true|false><TAB><command><TAB><reason>`, the reason empty
# when the action is offered. <pr-state> is what the reader knows of the
# task's pull request without asking the forge (the forge cache's state, or
# empty); `close` and `ship` read it. The cache's checks and mergeable words
# (<ci>, <mergeable>, optional) are what `merge` is withheld on; <pr-url-state>
# and <base-state> are what `close` reads (_task_actions_v). Local reads only.
_task_actions() {
  local out
  _task_actions_v out "$@"
  printf '%s' "$out"
}

# _task_actions_v <var> <id> <pr-state> [<ci> [<mergeable> [<pr-url-state>
# [<base-state>]]]] — the same lines into <var>, in the caller's shell. <ci>
# and <mergeable> are _task_actions'. <pr-url-state> is the state of
# the pull request `pr_url` names (on the staging flow, the one into the
# staging branch), <base-state> that of a pull request from the task's branch
# into its base (its promotion); each defaults to <pr-state>, which `ship` and
# `land` read. A guard still runs in a subshell of its own, so a guard that
# fails withholds its row rather than ending the listing; it reads the task's
# state from the snapshot it inherits.
_task_actions_v() {
  local __ta_out="" id="$2" pr_state="$3" pr_ci="${4:-}" pr_mergeable="${5:-}" pr_url_state="${6-$3}" base_state="${7-$3}" status action command reason by="" mode spec gate parked ahead
  # The ship gates are asked by two rows of this table; read once (_task_ship_refusal_v).
  _TASK_SHIP_MEMO_ON=1 _TASK_SHIP_MEMO_KEY=""
  _TASK_PR_INTO_FROM_CACHE=1
  if [ -z "$_TASK_PR_CACHE_READ" ]; then
    if ! declare -F forgecache_read >/dev/null; then
      # shellcheck source=lib/forgecache.sh
      . "$JIG_LIB/forgecache.sh"
    fi
    _TASK_PR_CACHE=${_TASK_LIST_FORGE_CACHE:-}
    [ -n "$_TASK_PR_CACHE" ] || _TASK_PR_CACHE=$(forgecache_read)
    _TASK_PR_CACHE_READ=1
  fi
  task_state_var status "$id" status
  for action in $_TASK_ACTIONS; do
    reason=""
    case "$action" in
      start) command="jig task start $id" ;;
      pause) command="jig task pause $id" ;;
      resume) command="jig task resume $id" ;;
      request-pause) command="jig queue request task:$id pause" ;;
      cancel-pause-request) command="jig queue cancel task:$id pause" ;;
      approve-gate) command="jig task gate $id approved" ;;
      answer-gate) command="jig task gate $id answered --answer <text>" ;;
      answer-stop)
        # The `--by human` an unattended run's answer needs, in the command
        # and in the guard alike.
        command="jig task autopilot $id answer --answer <text>"
        _task_autopilot_mode_v mode "$id"
        if [ "$mode" = unattended ]; then
          by=human
          command="$command --by human"
        fi ;;
      handover) command="jig task autopilot $id handover --by human --answer <text>" ;;
      set-class) command="jig task set $id class <Tn>" ;;
      ship) command="jig task ship $id --message-file <file>" ;;
      land) command="jig task land $id --by human" ;;
      request-review) command="jig task request-review $id --reviewer <login> --by human" ;;
      merge) command="jig task merge-pr $id --by human" ;;
      promote) command="jig task promote $id --by human" ;;
      pr-status) command="jig task pr-status $id --json" ;;
      close) command="jig task set $id status consolidated" ;;
      abandon)
        # A spec-linked task is refused without a reason; the placeholder
        # tells a reader of the table to ask for one.
        command="jig task abandon $id"
        _task_spec_id_v spec "$id"
        [ -z "$spec" ] || command="$command --reason <text>" ;;
      archive) command="jig task archive $id" ;;
      unarchive) command="jig task unarchive $id" ;;
      reopen) command="jig task set $id status active" ;;
      drop-item) command="jig spec drop $id --json" ;;
    esac
    case "$status:$action" in
      abandoned:reopen) ;;
      # The roadmap item an abandon left open, which `task abandon --json`
      # never touches (adr-20261029-an-abandoned-task-says-why-and-its-roadmap-item-follows):
      # `spec drop --json` closes it in Jig's own tree, and its own guard
      # answers for every status, an archived task that was abandoned included.
      *:drop-item) _task_actions_ask_v reason "$id" "$action" _task_drop_item_refusal "$id" ;;
      # An abandoned task can be archived and an unfinished one too; a
      # consolidated task is not (its work is in git, its workspace is
      # purged) and an archived one already is
      # (adr-20261027-a-task-nobody-finished-is-archived-not-purged).
      active:archive | ready:archive | abandoned:archive) ;;
      consolidated:archive) reason="task archive: task $id is consolidated; only an unfinished task is archived" ;;
      archived:archive) reason="task archive: task $id is already archived" ;;
      archived:unarchive) ;;
      *:unarchive) reason="task unarchive: task $id is not archived" ;;
      # A request left on a finished task — made during its last stage, or
      # before it was closed — can still be taken back.
      consolidated:cancel-pause-request | abandoned:cancel-pause-request | archived:cancel-pause-request)
        _task_actions_ask_v reason "$id" "$action" jig_pause_cancel_refusal "$id" ;;
      consolidated:* | abandoned:* | archived:*) reason="task $id is $status" ;;
      *:reopen) reason="task $id is $status, not abandoned" ;;
      *:start)
        _task_actions_ask_v reason "$id" "$action" _task_start_refusal "$id"
        [ -n "$reason" ] || _task_actions_ask_v reason "$id" "$action" _task_start_goal_refusal "$id"
        # Offered, but with the way the command takes when the queue puts
        # another task first: `--out-of-order` and a reason, like `abandon`'s.
        if [ -z "$reason" ]; then
          _task_queue_ahead_v ahead "$id"
          [ -z "$ahead" ] || command="$command --out-of-order --reason <text>"
        fi ;;
      *:pause) _task_actions_ask_v reason "$id" "$action" _task_pause_refusal "$id" ;;
      *:resume)
        _task_parked_lookup_v parked "$id"
        _task_actions_ask_v reason "$id" "$action" _task_resume_refusal "$id" "$parked" ;;
      *:request-pause)
        _task_actions_ask_v reason "$id" "$action" jig_pause_request_refusal "$id"
        [ -n "$reason" ] || _task_actions_ask_v reason "$id" "$action" _task_request_pause_unstarted_refusal "$id" ;;
      *:cancel-pause-request) _task_actions_ask_v reason "$id" "$action" jig_pause_cancel_refusal "$id" ;;
      *:approve-gate)
        _task_actions_ask_v reason "$id" "$action" _task_gate_refusal "$id" human
        if [ -z "$reason" ]; then
          _task_gate_state_v gate "$id"
          [ "$gate" != approved ] || reason="task gate: $id's design is approved; nothing waits at its gate"
        fi ;;
      *:answer-gate)
        _task_actions_ask_v reason "$id" "$action" _task_gate_refusal "$id" human answered
        if [ -z "$reason" ]; then
          _task_gate_state_v gate "$id"
          [ "$gate" != approved ] || reason="task gate: $id's design is approved; nothing waits at its gate"
        fi ;;
      *:answer-stop) _task_actions_ask_v reason "$id" "$action" _task_autopilot_resume_refusal "$id" "$by" answer ;;
      *:handover) _task_actions_ask_v reason "$id" "$action" _task_autopilot_handover_refusal "$id" ;;
      *:ship)
        if [ "$pr_state" = merged ]; then
          reason="task ship: $id's pull request is merged"
        else
          # In the command's order: the level, the gates, the branch.
          _task_actions_ask_v reason "$id" "$action" _task_ship_level_refusal "$id"
          # The gates are read in this shell and once per task: the `land` row
          # asks the same ones (_task_ship_refusal_v).
          if [ -z "$reason" ]; then
            _task_ship_refusal_v reason "$id" 0 || _task_actions_withheld_v reason "$id" "$action"
          fi
          [ -n "$reason" ] || _task_actions_ask_v reason "$id" "$action" _task_ship_branch_refusal "$id"
        fi ;;
      *:land) _task_actions_ask_v reason "$id" "$action" _task_land_refusal "$id" "$pr_state" human ;;
      *:request-review) _task_actions_ask_v reason "$id" "$action" _task_request_review_refusal "$id" "$pr_state" ;;
      *:merge)
        _task_actions_ask_v reason "$id" "$action" _task_merge_pr_refusal "$id" "$pr_state"
        # What only the table withholds: the forge cache's word on the checks
        # and on conflicts. The command looks at the forge itself, now.
        if [ -z "$reason" ]; then
          case "$pr_ci" in
            red | pending) reason="task merge-pr: the forge cache says the checks of $id's pull request are $pr_ci; the table withholds the merge until they are green (the command itself looks at the forge now)" ;;
          esac
        fi
        if [ -z "$reason" ] && [ "$pr_mergeable" = conflicting ]; then
          reason="task merge-pr: the forge cache says $id's pull request conflicts with its base; the table withholds the merge (the command itself looks at the forge now)"
        fi ;;
      *:promote) _task_actions_ask_v reason "$id" "$action" _task_promote_refusal "$id" ;;
      *:pr-status) _task_actions_ask_v reason "$id" "$action" _task_pr_status_refusal "$id" ;;
      *:close) _task_actions_ask_v reason "$id" "$action" _task_close_refusal "$id" "${pr_url_state:-unknown}" "$base_state" ;;
    esac
    if [ -n "$reason" ]; then
      __ta_out="$__ta_out$action"$'\t'"false"$'\t'"$command"$'\t'"$reason"$'\n'
    else
      __ta_out="$__ta_out$action"$'\t'"true"$'\t'"$command"$'\t'$'\n'
    fi
  done
  _TASK_SHIP_MEMO_ON="" _TASK_SHIP_MEMO_KEY="" _TASK_PR_INTO_FROM_CACHE=""
  printf -v "$1" '%s' "$__ta_out"
}

# _task_drop_item_refusal <id> — why `jig spec drop <id> --json` would refuse, in
# its own words, or nothing: the command's own guard (ot_spec_drop_refusal,
# owntree.sh) asked of local refs only, no fetch and no network
# (conventions/json-output.md). It may find less than the command, which asks
# origin as it writes, never more. owntree.sh is sourced on first use.
_task_drop_item_refusal() {
  # shellcheck source=lib/owntree.sh
  declare -F ot_spec_drop_refusal >/dev/null || . "$JIG_LIB/owntree.sh"
  ot_spec_drop_refusal "$1" all
  [ -z "$OT_SD_MSG" ] || printf '%s\n' "$OT_SD_MSG"
  return 0
}

# _task_actions_guard <id> <action> <guard> [args] — what <guard> prints, or,
# when it could not decide, a reason that withholds <action>: a guard that
# fails never reads as "nothing refuses".
_task_actions_guard() {
  local out
  _task_actions_guard_v out "$@"
  printf '%s\n' "$out"
}

# _task_actions_guard_v <var> <id> <action> <guard> [args] — the same answer
# into <var>: one subshell, the guard's own. For a guard that may fail or die
# part way (a guard that reads files or git, or runs a program of its own).
_task_actions_guard_v() {
  local __tag_var="$1" __tag_id="$2" __tag_action="$3" __tag_out
  shift 3
  if __tag_out=$("$@"); then
    printf -v "$__tag_var" '%s' "$__tag_out"
  else
    _task_actions_withheld_v "$__tag_var" "$__tag_id" "$__tag_action"
  fi
}

# _task_actions_withheld_v <var> <id> <action> — into <var>, the reason that
# withholds <action> when its guard could not decide. The one place the words
# are spelled.
_task_actions_withheld_v() {
  printf -v "$1" 'jig could not check whether %s may %s now' "$2" "$3"
}

# _task_actions_ask_v <var> <id> <action> <guard> [args] — the same answer as
# _task_actions_guard_v, from a guard run in this shell with its output in a
# file: no process per row. Only for a guard that reads state and never dies —
# every row but the ship gates, which the `ship` and `land` rows read in this
# shell through _task_ship_refusal_v. A non-zero exit still withholds the row.
_TASK_ASK_FILE=""
_TASK_ASK_LEVEL=""
_task_actions_ask_v() {
  local __taa_var="$1" __taa_id="$2" __taa_action="$3" __taa_out="" __taa_rc=0 __taa_nl=$'\n'
  shift 3
  if [ -z "$_TASK_ASK_FILE" ] || [ "$_TASK_ASK_LEVEL" != "${BASH_SUBSHELL:-0}" ]; then
    _TASK_ASK_FILE=$(mktemp "${TMPDIR:-/tmp}/jig-guard.XXXXXX") || {
      _task_actions_guard_v "$__taa_var" "$__taa_id" "$__taa_action" "$@"
      return 0
    }
    _TASK_ASK_LEVEL=${BASH_SUBSHELL:-0}
    jig_cleanup_add "$_TASK_ASK_FILE"
  fi
  "$@" > "$_TASK_ASK_FILE" || __taa_rc=$?
  if [ "$__taa_rc" -ne 0 ]; then
    _task_actions_withheld_v "$__taa_var" "$__taa_id" "$__taa_action"
    return 0
  fi
  IFS= read -r -d '' __taa_out < "$_TASK_ASK_FILE" || true
  # What `$(...)` would have kept: every trailing newline dropped.
  while :; do
    case "$__taa_out" in
      *"$__taa_nl") __taa_out=${__taa_out%"$__taa_nl"} ;;
      *) break ;;
    esac
  done
  printf -v "$__taa_var" '%s' "$__taa_out"
}

# _task_goal <task.md> — the first paragraph under the `## Goal` heading of a
# task's brief, joined into one line, or `(none)` when the brief has no such
# heading or nothing under it. What `jig task list --goals` shows a person
# choosing which tasks go into a release; a missing goal is a gap in the
# brief, said as one, not a field to add. HTML comments (`<!-- ... -->`, on one
# line or across several) are not the goal: the template's guidance sits under
# the heading of every brief filed without one, so it is dropped before a word
# is kept, and a line that held only a comment does not end the paragraph.
_task_goal() {
  local goal
  jig_task_goal_v goal "$1"
  printf '%s\n' "$goal"
}

task_show() {
  jig_require_init
  [ $# -eq 1 ] || jig_die "$(_task_usage show)"
  local file
  file="$(task_dir "$1")/state"
  [ -f "$file" ] || jig_die "task show: unknown task: $1"
  cat "$file"
  # Two derived lines after the state, never keys of it: where the gate stands
  # now (`gate_state`, _task_gate_state_v — the `gate` key stays `answered`
  # after the design is rewritten, when the state is `waiting` again) and the
  # last answer given at it. A session picking the task up acts on an answer
  # only while `gate_state` is `answered` (the jig-task skill); the history is
  # the `gate-answers` file, whose last line _task_gate_answer_v reads, as the
  # JSON producer does.
  # shellcheck disable=SC2034 # the design and author fields are not shown here
  local gstate ga_at ga_design ga_by ga_text
  _task_gate_state_v gstate "$1"
  [ -z "$gstate" ] || printf 'gate_state: %s\n' "$gstate"
  _task_gate_answer_v ga_at ga_design ga_by ga_text "$1"
  [ -z "$ga_at" ] || printf 'gate_answer: %s %s\n' "$ga_at" "$ga_text"
}

# The task for this checkout's current branch (design §2). Deterministic,
# never a ranking: exactly one candidate (design §1: branch matches, status
# `active` or `ready`, not paused) prints its id on stdout and exits 0; zero
# candidates is a normal, silent outcome (exit 1, a warning on stderr) so
# `jig context` can treat "no current task" as ordinary rather than fatal;
# several candidates is refused outright (exit 2, one line per candidate on
# stderr, nothing on stdout) rather than picked by any tie-break — silently
# guessing wrong here is exactly the bug this replaced.
task_current() {
  jig_require_init
  local branch candidates count
  branch=$(_task_current_branch)
  candidates=$(_task_candidates_for_branch "$branch")
  count=$(_task_count_lines "$candidates")

  if [ "$count" -eq 0 ]; then
    jig_warn "no current task for branch: $branch"
    return 1
  fi

  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$candidates"
    return 0
  fi

  local cid cst cupd
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    cst=$(task_state_get "$cid" status)
    cupd=$(task_state_get "$cid" updated_at)
    printf '%s  %s  updated_at=%s\n' "$cid" "$cst" "$cupd" >&2
  done < <(printf '%s\n' "$candidates")
  return 2
}

# Read-only review inventory; the task ID establishes context, not hunk ownership.
task_changes() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage changes)"
  local id="$1" base="" head format=report files="" has_files=0 row path layer rows selected="" candidates kept t
  shift
  [ -f "$(task_dir "$id")/state" ] || jig_die "task changes: unknown task: $id"
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || jig_die "task changes: --base requires a value"; base="$2"; shift 2 ;;
      --files)
        [ $# -ge 2 ] || jig_die "task changes: --files requires a value"
        [ "$has_files" -eq 0 ] || jig_die "task changes: duplicate --files"
        has_files=1
        if [ "$2" = - ]; then files=$(cat); else
          case "$2" in *'
'*) jig_die "task changes: use stdin for a multiline scope" ;; esac
          files=$(printf '%s' "$2" | tr ',' '\n')
        fi
        shift 2 ;;
      --format) [ $# -ge 2 ] || jig_die "task changes: --format requires a value"; format="$2"; shift 2 ;;
      *) jig_die "task changes: unknown argument: $1" ;;
    esac
  done
  case "$format" in report | paths) ;; *) jig_die "task changes: invalid format: $format" ;; esac
  [ -n "$base" ] || jig_die "task changes: --base is required; establish the task baseline first"
  base=$(jig_review_commit "$base") || return 1
  head=$(jig_review_commit HEAD) || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    jig_check_review_path "$path"
  done < <(printf '%s\n' "$files")
  rows=$(jig_git_change_rows "$base" "$head") || return 1
  t=$(printf '\t')
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    path=${row%%"$t"*}
    if [ "$has_files" -eq 1 ] && ! jig_has_line "$path" "$files"; then continue; fi
    selected="$selected$row
"
  done < <(printf '%s\n' "$rows")
  if [ "$format" = paths ]; then
    printf '%s' "$selected" | cut -f1 | LC_ALL=C sort -u
  else
    candidates=$(printf '%s\n' "$rows" | sed '/^$/d' | cut -f1 | sort -u | wc -l | tr -d ' ')
    kept=$(printf '%s' "$selected" | cut -f1 | sort -u | wc -l | tr -d ' ')
    printf 'task: %s\nbase: %s\nhead: %s\nselected: %s paths; excluded: %s candidate paths\n' "$id" "$base" "$head" "$kept" "$((candidates - kept))"
    while IFS="$t" read -r path layer; do
      [ -n "$path" ] || continue
      printf '%-10s %s\n' "$layer" "$path"
    done < <(printf '%s' "$selected")
    printf 'inventory only; task ownership and review remain unassessed\n'
  fi
}

# _task_workspace_root <id> <command> — the physical directory holding this
# task's artifacts and `state`, with the one path check every command that
# reads or writes an artifact must pass (RULES.md: the check lives at a single
# function, not once per caller).
#
# A link anywhere on the way is judged by where it leads, never by its shape.
# `-L` asks about the last component only, and comparing the task's directory
# with the tasks directory proves nothing when both resolve through the same
# link above them: a planted `.ai/workspace/tasks` (or `.ai/workspace`) passed
# that comparison wherever it pointed, outside the repository included. So
# the tasks directory itself must physically be the one of a checkout of this
# repository -- this one, or the owner a `task start --worktree` link (a
# symlink, or a junction on Windows) leads to, or the owner a coordinator's
# workspace link leads to (ADR-0029 as amended). Inside it, a task directory
# that is a link must lead to this task's workspace in some worktree of this
# repository (the single-task link `task start` still makes where the whole
# directory cannot be linked); any other must be exactly the entry named after
# the task. <command> names the caller in the refusals, so the message still
# says which verb refused.
_task_workspace_root() {
  local id="$1" cmd="$2" root tasks_root real
  root=$(task_dir "$id") || return 1
  [ -f "$root/state" ] || jig_fail not-found "$cmd: unknown task: $id"
  tasks_root=$(_task_tasks_root "$cmd")
  if [ -L "$root" ]; then
    real=$(cd -P "$root" 2>/dev/null && pwd -P) || real=""
    if [ -z "$real" ] || ! _task_worktree_holds "$real" "$JIG_AI_DIR/workspace/tasks/$id"; then
      jig_die "$cmd: linked task workspace is unsupported unless it is this task's workspace in another worktree"
    fi
    printf '%s\n' "$real"
    return 0
  fi
  real=$(cd -P "$root" && pwd -P) || jig_die "$cmd: cannot inspect workspace"
  [ "$real" = "$tasks_root/$id" ] || jig_die "$cmd: workspace outside task root"
  printf '%s\n' "$real"
}

# _task_tasks_root <command> — the physical path of `.ai/workspace/tasks`, once
# it is known to be the tasks directory of a checkout of this repository
# (see above); dies naming <command> otherwise. The half of the check that
# does not need a task, so `task new` can make it before a task exists.
_task_tasks_root() {
  local cmd="$1" tasks_root
  tasks_root=$(cd -P "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks" 2>/dev/null && pwd -P) \
    || jig_die "$cmd: cannot inspect $JIG_AI_DIR/workspace/tasks"
  _task_worktree_holds "$tasks_root" "$JIG_AI_DIR/workspace/tasks" \
    || jig_die "$cmd: $JIG_AI_DIR/workspace/tasks leads to $tasks_root, which is no checkout of this repository"
  printf '%s\n' "$tasks_root"
}

# _task_guard_write <id> <command> — the check every writer of a task's
# workspace (`state`, the journal, findings, the receipt, artifacts) passes
# before it writes anything, including a side effect that comes first (a stash,
# a commit). Dies, naming <command>, unless the workspace is this checkout's
# own, a worktree's, or the owner's a start linked; unknown task included.
# Called as a plain command, never inside $(...), so the refusal ends the
# process rather than a subshell.
_task_guard_write() {
  _task_workspace_root "$1" "$2" >/dev/null
}

# _task_guard_dir <dir> — the same check for a low-level writer that is handed
# a workspace directory (task_dir's answer, or the physical root of one). The
# verb is the running `jig task` subcommand, set by cmd_task.
_task_guard_dir() {
  _task_workspace_root "${1##*/}" "${_TASK_VERB:-task}" >/dev/null
}

_task_artifact_kind() {
  case "$1" in discovery | spec | alternatives | design | plan | review | verification | handoff) return 0 ;; *) return 1 ;; esac
}

# _task_artifact_locate <root> <kind> — where <kind>.md of the workspace
# <root> really is, and whether it may be read. Sets, in the caller's shell
# (called as a plain command, never inside $(...)):
#   _TASK_ART_PATH    the physical path, links resolved; empty when unresolved
#   _TASK_ART_STATE   present | empty | missing | unavailable
#   _TASK_ART_REASON  why, in the words `task artifacts` prints in parentheses
# The one check every reader of an artifact passes: the text report, the JSON
# list and `task artifact read`. Links are resolved without readlink -f, and a
# path that leaves the workspace is never read.
_task_artifact_locate() {
  local root="$1" kind="$2" path target parent hops=0
  _TASK_ART_PATH="" _TASK_ART_STATE=unavailable _TASK_ART_REASON=""
  path="$root/$kind.md"
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 40 ]; then _TASK_ART_REASON="symlink loop"; return 0; fi
    target=$(readlink "$path") || { _TASK_ART_REASON="unreadable link"; return 0; }
    case "$target" in /*) path="$target" ;; *) path="$(dirname "$path")/$target" ;; esac
  done
  parent=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P) || { _TASK_ART_REASON="missing parent"; return 0; }
  path="$parent/$(basename "$path")"
  case "$path" in "$root"/*) ;; *) _TASK_ART_REASON="outside workspace"; return 0 ;; esac
  _TASK_ART_PATH=$path
  if [ ! -e "$path" ]; then _TASK_ART_STATE=missing; _TASK_ART_REASON="missing or not a regular file"
  elif [ ! -f "$path" ]; then _TASK_ART_REASON="missing or not a regular file"
  elif [ ! -r "$path" ]; then _TASK_ART_REASON="unreadable"
  elif [ ! -s "$path" ]; then _TASK_ART_STATE=empty; _TASK_ART_REASON="empty"
  else _TASK_ART_STATE=present; fi
}

# _task_artifact_fact <root> <kind> <provided> — the text report's word for
# one artifact: `present`, `unavailable (<reason>)`, or the provided claim.
_task_artifact_fact() {
  local root="$1" kind="$2" provided="$3"
  if jig_has_line "$kind" "$provided"; then
    printf 'provided-claim (caller must substantiate)\n'; return 0
  fi
  _task_artifact_locate "$root" "$kind"
  if [ "$_TASK_ART_STATE" = present ]; then printf 'present\n'
  else printf 'unavailable (%s)\n' "$_TASK_ART_REASON"; fi
}

# stage|documentary inputs|unassessed semantic prerequisites, for <class> at
# <depth> (_task_route_depth; `full` when absent). This is not a router: the
# stages are _task_route_stages', and lean changes only what T1 and T2 read —
# the analysis lives in task.md at T1, and the plan inside the analysis at T2
# (adr-20261002-route-depth-is-a-personal-choice).
_task_artifact_route() {
  case "$1:${2:-full}" in
    T1:lean) printf '%s\n' 'analyze|task|task intent' 'implement|task|analysis sufficiency' 'verify|task|implementation' 'consolidate|task|implementation and verification outcome' ;;
    T2:lean) printf '%s\n' 'analyze|task|task intent' 'implement|task discovery|analysis and plan sufficiency' 'review|task discovery|implementation' 'verify|task discovery|implementation and review outcome' 'consolidate|task discovery|implementation, review and verification outcomes' ;;
    T0:*) printf '%s\n' 'implement|task|task intent' 'verify|task|implementation' 'consolidate|task|implementation and verification outcome' ;;
    T1:*) printf '%s\n' 'analyze|task|task intent' 'implement|task discovery|analysis sufficiency' 'verify|task|implementation' 'consolidate|task|implementation and verification outcome' ;;
    T2:*) printf '%s\n' 'analyze|task|task intent' 'plan|task discovery|analysis sufficiency' 'implement|task plan|plan sufficiency' 'review|task plan|implementation' 'verify|task plan|implementation and review outcome' 'consolidate|task plan|implementation, review and verification outcomes' ;;
    T3:*) printf '%s\n' 'discover|task|task intent' 'design|task discovery|discovery sufficiency' 'human-gate|task design|human design decision' 'implement|task design|human design approval' 'architecture-review|task design|implementation' 'verify|task design|implementation and architecture review outcome' 'consolidate|task verification|implementation, review and verification outcomes' ;;
    T4:*) printf '%s\n' 'discover|task|task intent' 'specify|task discovery|discovery sufficiency' 'alternatives|task spec|specification sufficiency' 'design|task spec alternatives|alternatives evaluated' 'human-gate|task spec design|human design decision' 'implement|task spec design|human design approval' 'review|task spec design|implementation and independent reviewer' 'verify|task spec design|implementation and independent review outcome' 'consolidate|task verification|implementation, review and verification outcomes' ;;
  esac
}

# task_artifacts <id> [--provided ...] [--json] — `--json` anywhere runs the
# JSON list instead (_task_artifacts_json), as the producer of json_run
# (conventions/json-output.md).
task_artifacts() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_artifacts_json "$@"
      return
    fi
  done
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage artifacts)"
  local id="$1" root class provided="" seen=0 kinds kind fact stage inputs semantic availability facts="" t depth
  shift
  root=$(_task_workspace_root "$id" "task artifacts") || return 1
  class=$(task_state_get "$id" class)
  _task_valid_class "$class" || jig_die "task artifacts: invalid or missing class: $class"
  while [ $# -gt 0 ]; do
    case "$1" in
      --provided)
        [ $# -ge 2 ] || jig_die "task artifacts: --provided requires a value"
        [ "$seen" -eq 0 ] || jig_die "task artifacts: duplicate --provided"
        seen=1
        case "$2" in '' | ,* | *, | *,,* | *[!a-z,]*) jig_die "task artifacts: malformed --provided: $2" ;; esac
        provided=$(printf '%s' "$2" | tr ',' '\n')
        kinds=""
        while IFS= read -r kind; do
          _task_artifact_kind "$kind" || jig_die "task artifacts: unknown provided kind: $kind"
          case " $kinds " in *" $kind "*) jig_die "task artifacts: duplicate provided kind: $kind" ;; esac
          kinds="$kinds $kind"
        done < <(printf '%s\n' "$provided")
        shift 2 ;;
      *) jig_die "task artifacts: unknown argument: $1" ;;
    esac
  done
  t=$(printf '\t')
  depth=$(_task_route_depth "$id" | cut -f 1)
  printf 'task: %s; class: %s; depth: %s\nartifacts (optional unless consumed by a route stage):\n' "$id" "$class" "$depth"
  for kind in task discovery spec alternatives design plan review verification handoff; do
    fact=$(_task_artifact_fact "$root" "$kind" "$provided")
    facts="$facts$kind$t$fact
"
    printf '  %-14s %s\n' "$kind" "$fact"
  done
  while IFS='|' read -r stage inputs semantic; do
    availability="inputs-available"
    for kind in $inputs; do
      fact=$(printf '%s' "$facts" | awk -F "$t" -v k="$kind" '$1 == k {print $2}')
      case "$fact" in unavailable*) availability="needs-input" ;; esac
    done
    printf '%s: %s; inputs: %s\n  unassessed: %s\n' "$stage" "$availability" "$inputs" "$semantic"
  done < <(_task_artifact_route "$class" "$depth")
  printf 'Presence and provided claims do not prove approval, quality or completion; state unchanged.\n'
}

# _task_artifact_stat — _TASK_ART_PATH's mtime as UTC into _TASK_ART_AT and
# its size in bytes into _TASK_ART_BYTES; each empty when it cannot be read.
_task_artifact_stat() {
  local mtime
  _TASK_ART_AT="" _TASK_ART_BYTES=""
  if mtime=$(jig_file_mtime "$_TASK_ART_PATH"); then
    _TASK_ART_AT=$(jig_utc_from_epoch "$mtime") || _TASK_ART_AT=""
  fi
  _TASK_ART_BYTES=$(wc -c < "$_TASK_ART_PATH" 2>/dev/null | tr -d ' ') || _TASK_ART_BYTES=""
}

# _task_artifacts_json <id> [--json] — the producer of `task artifacts --json`
# (schemas/json.md): every kind `task artifact` writes, in its order, each with
# its state, the reason when it is unavailable, and for a file that is there its
# mtime and size. A listing, not a route report: it asks nothing of the class,
# and `--provided` (a claim from a conversation) has no place in it.
_task_artifacts_json() {
  local arg args=()
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ $# -ge 1 ] || jig_fail usage "$(_task_usage artifacts)"
  case "$1" in -*) jig_fail usage "$(_task_usage artifacts)" ;; esac
  local id="$1" root kind out sep="" reason at bytes
  shift
  [ $# -eq 0 ] || case "$1" in
    --provided) jig_fail usage "task artifacts: --provided cannot be combined with --json" ;;
    *) jig_fail usage "task artifacts: unknown argument: $1" ;;
  esac
  _task_valid_id "$id" || jig_fail usage "task artifacts: invalid task id: $id"
  root=$(_task_workspace_root "$id" "task artifacts") || return 1
  json_quote "$id"
  out="{\"task\":$_JSON,\"artifacts\":["
  for kind in $_TASK_ARTIFACT_KINDS; do
    _task_artifact_locate "$root" "$kind"
    reason=null at=null bytes=null
    case "$_TASK_ART_STATE" in
      present | empty)
        _task_artifact_stat
        json_str_or_null "$_TASK_ART_AT"; at=$_JSON
        json_int_or_null "$_TASK_ART_BYTES"; bytes=$_JSON
        ;;
      unavailable) json_quote "$_TASK_ART_REASON"; reason=$_JSON ;;
    esac
    out="$out$sep{\"kind\":\"$kind\",\"state\":\"$_TASK_ART_STATE\",\"reason\":$reason,\"updated_at\":$at,\"bytes\":$bytes}"
    sep=,
  done
  printf '%s]}\n' "$out"
}

# _task_artifact_read <as_json> <id> <kind> — one artifact, read from where the
# task's workspace really is (_task_workspace_root, ADR-0029): its bytes as
# they are, or with <as_json> 1 an object holding them as a string beside its
# mtime and size (schemas/json.md). Nothing is written. An empty artifact
# reads as empty; a missing one is `not-found`; one the check refuses (a link
# out of the workspace, not a regular file, unreadable) is `failed`.
_task_artifact_read() {
  local as_json="$1" id="$2" kind="$3" root content
  _task_valid_id "$id" || jig_fail usage "task artifact: invalid task id: $id"
  _task_artifact_writable_kind "$kind" \
    || jig_fail usage "task artifact: unknown kind: $kind (one of: $_TASK_ARTIFACT_KINDS)"
  root=$(_task_workspace_root "$id" "task artifact") || return 1
  _task_artifact_locate "$root" "$kind"
  case "$_TASK_ART_STATE" in
    present | empty) ;;
    missing) jig_fail not-found "task artifact: $id has no $kind" ;;
    *) jig_die "task artifact: $kind of $id is unavailable ($_TASK_ART_REASON)" ;;
  esac
  if [ "$as_json" != 1 ]; then
    cat "$_TASK_ART_PATH"
    return 0
  fi
  _task_artifact_stat
  # The sentinel keeps the trailing newlines $(...) would strip.
  content=$(cat "$_TASK_ART_PATH" && printf x) || jig_die "task artifact: cannot read $kind of $id"
  content=${content%x}
  local out
  json_quote "$id"; out="{\"task\":$_JSON,\"kind\":\"$kind\","
  json_str_or_null "$_TASK_ART_AT"; out="$out\"updated_at\":$_JSON,"
  json_int_or_null "$_TASK_ART_BYTES"; out="$out\"bytes\":$_JSON,"
  # A whole document: json_quote over all of it is quadratic on bash 3.2.
  json_quote_text "$content"
  printf '%s"content":%s}\n' "$out" "$_JSON"
}

# _task_artifact_read_json <args...> — the producer json_run runs for
# `task artifact … --json`: `--json` goes with `read` only.
_task_artifact_read_json() {
  local arg args=()
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ "${1:-}" = read ] || jig_fail usage "task artifact: --json goes with read only"
  shift
  [ $# -eq 2 ] || jig_fail usage "$(_task_usage artifact)"
  case "$1$2" in -*) jig_fail usage "$(_task_usage artifact)" ;; esac
  _task_artifact_read 1 "$1" "$2"
}

# --- artifact writes (ADR-0029: a worktree never writes through the link) ----

# The kinds `task artifact` will write. Wider than _task_artifact_kind above,
# which serves `--provided` and has no use for the rest:
#   - `task`: where jig-analyze puts its analysis and where an unattended run
#     records the gate it approved, so it is the most edited document of all;
#   - `knowledge-map`, `commit-message`, `pr-body`: documents the skills have
#     always written into the workspace (jig-map, jig-consolidate and a phase
#     run's task agents). Without a kind they could only be written around
#     jig, which is the one thing the skills forbid; a rule that cannot be
#     kept is broken. They are inputs to nothing `task artifacts` reports.
# The two predicates stay separate on purpose — widening the `--provided`
# vocabulary would let a caller claim an input that is never an input.
_TASK_ARTIFACT_KINDS="task discovery spec alternatives design plan review verification handoff knowledge-map commit-message pr-body"
_task_artifact_writable_kind() {
  case "$1" in '' | *[!a-z-]*) return 1 ;; esac
  case " $_TASK_ARTIFACT_KINDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# task_artifact write|append <id> <kind> [--from <file>|-]
#
# Writes one of a task's artifacts, so that nothing but jig needs to know
# where a task's workspace physically is. That is the point of the verb: in a
# task worktree the workspace is reached through a link (ADR-0029), an agent's
# editing tools refuse a path that resolves outside their sandbox, and the
# workaround — writing the link with plain shell — is a rule against the
# tool's own default, which is the class of rule agents break.
#
# Four things a shell redirection does not do:
#   1. resolves the workspace through _task_workspace_root, accepting exactly
#      the borrowed link and no other;
#   2. writes atomically (tmp + mv), so an interrupted write leaves the old
#      document whole rather than half a new one;
#   3. takes a closed vocabulary of kinds, so a misspelt name cannot become a
#      file `task artifacts` will never look at;
#   4. refreshes `updated_at` and redraws the status page, so a rewritten plan
#      does not leave the task looking untouched from outside.
#
# Content comes from the caller: `--from <file>`, or stdin with `--from -` or
# with no --from at all. In a worktree that file is inside the worktree, which
# is inside the sandbox, so the agent writes it with its ordinary tools and
# hands jig the path.
#
# No {{TASK_ID}} substitution happens here, unlike `task new --from`: that one
# seeds a template, this one stores a document its author already finished,
# where a `{{TASK_ID}}` is text and not a placeholder. The duplication between
# the two is one `mv`, and deliberate.
task_artifact() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_artifact_read_json "$@"
      return
    fi
  done
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage artifact)"
  local mode="$1"
  shift
  case "$mode" in
    write | append) ;;
    read)
      [ $# -eq 2 ] || jig_die "$(_task_usage artifact)"
      case "$1$2" in -*) jig_die "$(_task_usage artifact)" ;; esac
      _task_artifact_read 0 "$1" "$2"
      return
      ;;
    *) jig_die "$(_task_usage artifact)" ;;
  esac
  [ $# -ge 2 ] || jig_die "$(_task_usage artifact)"
  local id="$1" kind="$2" from="" seen=0
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        [ $# -ge 2 ] || jig_die "task artifact: --from requires a value"
        [ "$seen" -eq 0 ] || jig_die "task artifact: duplicate --from"
        seen=1
        from="$2"
        shift 2 ;;
      *) jig_die "task artifact: unknown argument: $1" ;;
    esac
  done
  _task_artifact_writable_kind "$kind" \
    || jig_die "task artifact: unknown kind: $kind (one of: $_TASK_ARTIFACT_KINDS)"

  # Validated before the workspace is touched, so an unreadable source never
  # gets as far as the temporary file (task_new --from does the same).
  if [ -n "$from" ] && [ "$from" != "-" ]; then
    [ -e "$from" ] || jig_die "task artifact: --from: no such file: $from"
    [ -f "$from" ] || jig_die "task artifact: --from: not a regular file: $from"
    [ -r "$from" ] || jig_die "task artifact: --from: file not readable: $from"
  fi

  local root dest tmp
  root=$(_task_workspace_root "$id" "task artifact") || return 1
  dest="$root/$kind.md"
  tmp="$dest.tmp.$$"
  jig_cleanup_add "$tmp"
  # A link is refused rather than resolved. `mv` would replace it and `append`
  # would read through it, out of the workspace and back in — and
  # `task artifacts` already treats an artifact that leaves the workspace as
  # unavailable. Whoever put the link there gets to say what happens to it.
  if [ -L "$dest" ]; then
    jig_die "task artifact: $kind.md is a link; remove it first if this document should live in the workspace"
  fi

  # The new content is captured first, whole, and only then is anything in the
  # workspace touched. An empty capture is refused rather than written: a
  # `write` fed the output of a command that failed would otherwise blank the
  # document, and blanking a plan is the one destructive act this verb can
  # perform. `task artifacts` would report the result as `unavailable
  # (empty)` — true, and too late.
  if [ -z "$from" ] || [ "$from" = "-" ]; then
    cat > "$tmp"
  else
    cat "$from" > "$tmp"
  fi
  if [ ! -s "$tmp" ]; then
    # The one path this command removes: the temporary file it created itself,
    # this run, inside the workspace directory _task_workspace_root validated
    # (RULES.md wants the path validated to be inside `.ai/` and shaped like a
    # workspace entry before a script deletes it; this one is both).
    rm -f "$tmp"
    jig_die "task artifact: refusing to write an empty $kind: nothing on the input"
  fi

  if [ "$mode" = "append" ] && [ -s "$dest" ]; then
    local joined="$dest.join.$$"
    # A document that does not end in a newline would otherwise run into the
    # one appended after it, silently joining a heading to the line above.
    {
      cat "$dest"
      if [ -n "$(tail -c 1 "$dest")" ]; then printf '\n'; fi
      cat "$tmp"
    } > "$joined"
    mv "$joined" "$tmp"
  fi

  mv "$tmp" "$dest"
  _task_touch_state "$root"
  # A design at a human gate says what it asks (the jig-task skill): a warning,
  # not a refusal, for the one that does not.
  case "$kind:$mode" in
    design:write)
      case "$(task_state_get "$id" class)" in
        T3 | T4) _task_gate_questions_warn "$id" ;;
      esac ;;
  esac
  # An absolute path when the workspace is borrowed: it is in another
  # worktree, and a relative one would be read against the wrong root
  # (ADR-0029: paths in reports are absolute).
  jig_relpath "$dest" "$JIG_PROJECT"
}

# --- ship (agent git rights: design.md, .ai/specs/autopilot/) ----------------
#
# The git steps themselves are shared with `jig spec ship` (jig_ship_*,
# common.sh); the task's own gates stay here.

# task_ship <id> --message-file <file> [--title <t>] [--body-file <file>] [--draft]
#
# Carries a task's own change as far as `agent.git` (config.sh) allows:
# commit, push, open a pull request, and at `merge` merge it once its checks
# passed (jig_ship_merge, common.sh;
# adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci). `--draft`
# opens the pull request as a draft, which is never merged: an unattended run
# whose repairs ran out ends in one. Every step it is not allowed to take, and
# a merge that did not happen, ends in a plain status line, not an error:
# "none" is the one outcome a caller must tell apart from every other exit,
# which is why it alone is exit 3.
# _task_ship_unverified_notice — say, at the moment the change leaves the
# machine, that nothing verifies this project.
#
# The person hears it here rather than only in a `jig verify` ten minutes
# earlier, because here is where it has consequences. It is deliberately not a
# refusal: when no profile covers the project there is nothing to install and
# nothing to wait for, so refusing would stop work over a state nobody can
# resolve. A stack profile whose tools are missing is the other case entirely
# — there `jig verify` refuses, because something could have been checked and
# was not (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass).
#
# Nothing here may fail the ship: every path that cannot answer gives up.
_task_ship_unverified_notice() {
  local installed p pdir covered=0 names
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh" 2>/dev/null || return 0
  installed=$(profiles_installed_dir 2>/dev/null) || return 0
  [ -n "$installed" ] || return 0
  # The stack, so a base counts; one that does not resolve reads as the list.
  profiles_stack_v names 2>/dev/null || names=$(profiles_active 2>/dev/null) || names=""
  for p in $names; do
    pdir=$(profiles_dir "$installed" "$p" 2>/dev/null) || continue
    [ -d "$pdir" ] || continue
    if ! profiles_is_fallback "$pdir"; then
      covered=1
      break
    fi
  done
  [ "$covered" = 0 ] || return 0
  printf 'task ship: no profile covers this project, so nothing verifies it; this ships unverified\n'
  return 0
}

# _task_ship_git <id> — `<level><TAB><key>`: the git level `task ship` uses
# for <id>, and the key it came from. A task whose autopilot run is `on`, or
# `stopped` in an unattended run (whose repairs ran out: it ships its draft
# from there), ships at the run's level, jig_autopilot_git, when `autopilot.git`
# is set: the run's explicit level, one for everything it ships. Otherwise a
# task whose pull request goes into the staging branch (_task_ships_to_staging)
# ships at `agent.git_staging` when this clone sets it (the lower of it and
# `agent.git` for a pull request of an older Jig whose base was not recorded,
# which may go into the base branch), and every other ship —
# a run without `autopilot.git`, a run a person took over (`handover`, which
# ends it), anything into the base branch or an epic — at `agent.git`. An
# attended run that stopped is waiting for its person, who may well finish the
# task by hand: that ship is theirs, at their level. Read when it ships, not
# recorded at `start`: a person who lowers either key halfway through a run is
# obeyed at once. Exit 1 when the level is invalid, like jig_agent_git; an
# invalid `agent.git_staging` is named and never falls back to `agent.git`
# (adr-20261114-landing-on-staging-has-its-own-git-level).
_task_ship_git() {
  local line rc=0
  _task_ship_git_v line "$1" || rc=$?
  printf '%s\n' "$line"
  return "$rc"
}

# _task_ship_git_v <var> <id> [base] — the same `<level><TAB><key>` into <var>,
# with the same exit status, in the caller's shell. With `base` the pull
# request is known to go into the base branch (`jig task merge-pr`): the
# staging step is skipped.
_task_ship_git_v() {
  local __tsg_run __tsg_mode __tsg_value __tsg_auto=""
  task_state_var __tsg_run "$2" autopilot
  case "$__tsg_run" in
    on)
      __tsg_auto=1
      ;;
    stopped)
      _task_autopilot_mode_v __tsg_mode "$2"
      [ "$__tsg_mode" != unattended ] || __tsg_auto=1
      ;;
  esac
  if [ -n "$__tsg_auto" ]; then
    cfg_v __tsg_value autopilot.git ""
    if [ -n "$__tsg_value" ]; then
      jig_autopilot_git_v "$1"
      return
    fi
  fi
  cfg_v __tsg_value agent.git_staging ""
  if [ -n "$__tsg_value" ] && [ "${3:-}" != base ]; then
    local __tsg_into=0
    _task_ships_to_staging "$2" || __tsg_into=$?
    case "$__tsg_into" in
      0)
        printf -v "$1" '%s\tagent.git_staging' "$__tsg_value"
        _cfg_agent_git_level "$__tsg_value"
        return ;;
      2)
        # A pull request of an older Jig, whose base nobody recorded: it may
        # go into the base branch, so the lower of the two levels answers.
        local __tsg_git __tsg_rank_s __tsg_rank_g
        cfg_v __tsg_git agent.git none
        _cfg_agent_git_level "$__tsg_value" || {
          printf -v "$1" '%s\tagent.git_staging' "$__tsg_value"
          return 1
        }
        _cfg_agent_git_level "$__tsg_git" || {
          printf -v "$1" '%s\tagent.git' "$__tsg_git"
          return 1
        }
        _task_git_level_rank_v __tsg_rank_s "$__tsg_value"
        _task_git_level_rank_v __tsg_rank_g "$__tsg_git"
        if [ "$__tsg_rank_g" -lt "$__tsg_rank_s" ]; then
          printf -v "$1" '%s\tagent.git' "$__tsg_git"
        else
          printf -v "$1" '%s\tagent.git_staging' "$__tsg_value"
        fi
        return 0 ;;
    esac
  fi
  cfg_v __tsg_value agent.git none
  printf -v "$1" '%s\tagent.git' "$__tsg_value"
  _cfg_agent_git_level "$__tsg_value"
}

# _task_git_level_rank_v <var> <level> — 0..4 for none|commit|push|pr|merge
# into <var>, in the caller's shell: the resolver is asked per task of a listing.
_task_git_level_rank_v() {
  local __tgr=4
  case "$2" in
    none) __tgr=0 ;;
    commit) __tgr=1 ;;
    push) __tgr=2 ;;
    pr) __tgr=3 ;;
  esac
  printf -v "$1" '%s' "$__tgr"
}

# _task_ships_to_staging <id> — exit 0 when <id>'s pull request goes into the
# staging branch as far as local reads can tell: the project is on a sound
# staging flow and the task is cut from the base branch. Whether the task
# changes the flow itself is not known here before its first ship (task_ship
# re-reads its level when it finds out); after it, the recorded `pr_into` says
# where its pull request went. Exit 2 when it is not known: the task has a
# pull request (`pr_url`) a ship of an older Jig opened, which recorded no
# `pr_into` — it may go into the base branch. Exit 1 when it does not. No
# process per task in a listing (_task_staging_sound_v).
_task_ships_to_staging() {
  local __tst_flow __tst_staging __tst_base __tst_base_branch __tst_into __tst_url
  cfg_v __tst_flow git.flow direct
  [ "$__tst_flow" = staging ] || return 1
  _task_staging_sound_v __tst_staging || return 1
  jig_task_base_v __tst_base "$1"
  cfg_v __tst_base_branch git.base_branch main
  [ "$__tst_base" = "$__tst_base_branch" ] || return 1
  # Once a ship opened its pull request, where it went is known: one into the
  # base (a task that changes the flow) answers to agent.git.
  task_state_var __tst_into "$1" pr_into
  if [ -z "$__tst_into" ]; then
    task_state_var __tst_url "$1" pr_url
    [ -z "$__tst_url" ] || return 2
    return 0
  fi
  [ "$__tst_into" = "$__tst_staging" ]
}

# _task_ship_level_refusal <id> — why `jig task ship <id>` refuses at the git
# level it would ship at (_task_ship_git), or nothing: an invalid level, or
# `none`, where the human commits. Shared with the actions table
# (_task_actions); the command exits 3 for `none` and 1 for an invalid level.
_task_ship_level_refusal() {
  local line level key rc=0
  _task_ship_git_v line "$1" || rc=$?
  IFS=$'\t' read -r level key <<EOF
$line
EOF
  if [ "$rc" -ne 0 ]; then
    printf 'task ship: invalid %s: %s (expected none|commit|push|pr|merge)\n' "$key" "$level"
  elif [ "$level" = none ]; then
    printf 'task ship: %s is none in this clone; the human commits\n' "$key"
  fi
  return 0
}

# _task_autopilot_git_line [<id>] — `autopilot git: <level> (<key>)`, the level
# an autopilot run ships at and where it comes from, as `task autopilot start`
# and `task route` print it. An invalid value is named, never guessed. With
# <id> of a task whose pull request goes into the staging branch, a second
# line `autopilot git on <staging>: <level> (<key>)` when agent.git_staging,
# not the line above, answers there: only without `autopilot.git`, which
# answers for everything a run ships (_task_ship_git_v). For a pull request
# whose branch was never recorded (pr_into), the line follows the resolver:
# only when agent.git_staging is the lower level and so answers.
_task_autopilot_git_line() {
  local line level key rc=0 staging value
  line=$(jig_autopilot_git) || rc=$?
  IFS=$'\t' read -r level key <<EOF
$line
EOF
  if [ "$rc" -eq 0 ]; then
    printf 'autopilot git: %s (%s)\n' "$level" "$key"
  else
    printf 'autopilot git: invalid %s %s (expected none|commit|push|pr|merge)\n' "$key" "$level"
  fi
  [ -n "${1:-}" ] || return 0
  [ "$key" != autopilot.git ] || return 0
  cfg_v value agent.git_staging ""
  [ -n "$value" ] || return 0
  local to=0 resolved
  _task_ships_to_staging "$1" || to=$?
  case "$to" in
    0) ;;
    2)
      # A pull request an older Jig opened, its branch not recorded: the
      # resolver answers the lower of the two levels; the second line only
      # when agent.git_staging is the one that answered.
      _task_ship_git_v resolved "$1" || true
      [ "${resolved#*$'\t'}" = agent.git_staging ] || return 0 ;;
    *) return 0 ;;
  esac
  cfg_v staging git.staging_branch ""
  if _cfg_agent_git_level "$value"; then
    printf 'autopilot git on %s: %s (agent.git_staging)\n' "$staging" "$value"
  else
    printf 'autopilot git on %s: invalid agent.git_staging %s (expected none|commit|push|pr|merge)\n' "$staging" "$value"
  fi
}

# _task_ship_refusal <id> <draft> — why `jig task ship <id>` (with `--draft`
# when <draft> is 1) refuses this task by its state, or nothing when its gates
# pass. Shared with the actions table (_task_actions). The git level
# (_task_ship_level_refusal) is asked before it and the branch
# (_task_ship_branch_refusal) after it, by both; what a ship refuses by the
# checkout — another branch checked out, nothing staged — is the command's.
# Non-zero when a check could not be made: a guard that fails refuses.
#
# A draft completes nothing and is never merged (task_ship, and jig_ship_merge
# refuses one on its own): it is how an unattended run whose repairs ran out
# shows where it stopped — usually with the blocking finding still open — so
# the three completion gates are not asked for one.
_task_ship_refusal() {
  local out rc=0
  _task_ship_refusal_v out "$@" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}

# _task_ship_refusal_v <var> <id> <draft> — _task_ship_refusal's answer into
# <var> (without the trailing newline), in the caller's shell, with its exit
# status. A `$(...)` is started only for a gate that reads a file — the
# findings ledger, the receipt, the route's records — so a task that has none
# of them costs a listing no process. Inside one actions table
# (_task_actions_v) the answer is read once per task and the `ship` and `land`
# rows share it (_TASK_SHIP_MEMO_*): they ask the same gates.
_TASK_SHIP_MEMO_ON=""
_TASK_SHIP_MEMO_KEY=""
_TASK_SHIP_MEMO_OUT=""
_TASK_SHIP_MEMO_RC=0
_task_ship_refusal_v() {
  local __tsr_var="$1" __tsr_rc=0 __tsr_out=""
  if [ -n "$_TASK_SHIP_MEMO_ON" ] && [ "$_TASK_SHIP_MEMO_KEY" = "$2:$3" ]; then
    printf -v "$__tsr_var" '%s' "$_TASK_SHIP_MEMO_OUT"
    return "$_TASK_SHIP_MEMO_RC"
  fi
  _task_ship_gates_v __tsr_out "$2" "$3" || __tsr_rc=$?
  if [ -n "$_TASK_SHIP_MEMO_ON" ]; then
    _TASK_SHIP_MEMO_KEY="$2:$3"
    _TASK_SHIP_MEMO_OUT=$__tsr_out
    _TASK_SHIP_MEMO_RC=$__tsr_rc
  fi
  printf -v "$__tsr_var" '%s' "$__tsr_out"
  return "$__tsr_rc"
}

# _task_ship_gates_v <var> <id> <draft> — the gates themselves, _task_ship_refusal_v's.
_task_ship_gates_v() {
  local __tsgt_var="$1" __tsgt_id="$2" __tsgt_draft="$3" __tsgt_kc __tsgt_blocking="" __tsgt_msg="" __tsgt_dir __tsgt_class __tsgt_route
  printf -v "$__tsgt_var" '%s' ""
  if [ "$__tsgt_draft" -eq 0 ]; then
    task_state_var __tsgt_kc "$__tsgt_id" knowledge_consolidated
    if [ "$__tsgt_kc" != "true" ]; then
      printf -v "$__tsgt_var" 'task ship: requires knowledge_consolidated true; record the knowledge decision first: jig task set %s knowledge_consolidated true' "$__tsgt_id"
      return 0
    fi
    task_dir_v __tsgt_dir "$__tsgt_id"
    # Each gate below is asked only when its input exists (the findings file,
    # a receipt or class T4, route_evidence required): that precondition is
    # re-encoded here so that a task with none of them starts no subshell in a
    # listing. It is coupled to the gate's own no-input case, so a change there
    # (a class refused without a receipt, say) is made here too. Each gate's
    # comment names this place.
    # Checked again, independently of knowledge_consolidated above (design §4):
    # a fix landed after consolidation can plant a new finding, and ADR-0030's
    # order check alone would not see it.
    if [ -f "$__tsgt_dir/findings" ]; then
      __tsgt_blocking=$(_task_blocking_findings "$__tsgt_id") || return 1
      if [ -n "$__tsgt_blocking" ]; then
        __tsgt_msg=$(_task_gate_blocking_message "$__tsgt_id" "$__tsgt_blocking") || return 1
        printf -v "$__tsgt_var" 'task ship: %s' "$__tsgt_msg"
        return 0
      fi
    fi
    # Same independent recheck as the findings ledger above, for the same
    # reason: a receipt gone stale after knowledge_consolidated was set true —
    # a later code edit, or a re-review nobody ran — must still refuse here.
    # Without a receipt only a T4 task is refused, and that is its class.
    task_state_var __tsgt_class "$__tsgt_id" class
    if [ -f "$__tsgt_dir/receipt" ] || [ "$__tsgt_class" = T4 ]; then
      __tsgt_msg=$(_task_receipt_gate_message "$__tsgt_id") || return 1
      if [ -n "$__tsgt_msg" ]; then
        printf -v "$__tsgt_var" 'task ship: %s' "$__tsgt_msg"
        return 0
      fi
    fi
    # And the route, for the same reason: the gate's approval goes stale the
    # moment the design changes after it, whenever that happens.
    task_state_var __tsgt_route "$__tsgt_id" route_evidence
    if [ "$__tsgt_route" = required ]; then
      __tsgt_msg=$(_task_route_evidence_refusal "$__tsgt_id" consolidate "task ship") || return 1
      printf -v "$__tsgt_var" '%s' "$__tsgt_msg"
    fi
  fi
  return 0
}

# _task_ship_branch_refusal <id> — why `jig task ship <id>` refuses this task
# for its branch, or nothing: a task not started, or one whose branch is its
# own base, has nothing of its own to ship. Asked after _task_ship_refusal, by
# the command and the actions table alike.
_task_ship_branch_refusal() {
  local id="$1" branch base
  task_state_var branch "$id" branch
  if [ -z "$branch" ]; then
    # shellcheck disable=SC2016 # the backticks quote a command for the reader
    printf 'task ship: %s has not been started (no branch); run `jig task start %s` first\n' "$id" "$id"
    return 0
  fi
  jig_task_base_v base "$id"
  [ "$branch" != "$base" ] \
    || printf "task ship: %s's branch is its own base (%s); nothing task-specific to ship\n" "$id" "$base"
  return 0
}

# _task_ship_flow_v <staging-var> <land-var> <id> <level> <base> — where the
# project's git flow (config.sh, `git.flow`) sends <id>'s pull request: the
# staging branch's name into <staging-var> and `git.staging_land` into
# <land-var>, or both empty when the pull request goes into <base> as it
# always did. Refuses, before anything is committed, a flow whose
# configuration has a problem (jig_git_flow_problems, the lines `jig doctor`
# fails on) and, at `pr` and above, a staging branch that exists neither here
# nor on origin, where the forge would refuse only after the push.
#
# A task that changes the flow itself — turns it on or off, renames the
# staging branch (_task_ship_flow_agrees) — ships into <base> as on the
# direct flow: both variables stay empty, and _TASK_SHIP_OWN_FLOW is 1.
#
# The staging flow applies to a task cut from the base branch only. A task of
# an epic ships into its epic, as before: whether an epic's tasks go through
# the staging branch is not decided yet, and the task epic-in-staging-flow
# holds the question (adr-20261111-in-the-staging-flow-a-task-ships-into-the-staging-branch).
_TASK_SHIP_OWN_FLOW=""
_task_ship_flow_v() {
  local __tsf_id="$3" __tsf_level="$4" __tsf_base="$5" __tsf_problems __tsf_flow __tsf_branch __tsf_land=""
  printf -v "$1" '%s' ""
  printf -v "$2" '%s' ""
  __tsf_problems=$(jig_git_flow_problems)
  if [ -n "$__tsf_problems" ]; then
    jig_die "task ship: the project's git flow cannot be shipped through:
$__tsf_problems
Nothing was committed. Fix it in .ai/config.yaml (jig doctor names the same) and run again."
  fi
  __tsf_flow=$(jig_git_flow) || __tsf_flow=""
  # The base as origin has it now, not as this checkout last fetched it: a
  # teammate's `git.flow: staging` pushed since must be seen. A fetch that
  # fails only warns (jig_fetch_branches), as for `task start` and `upgrade`,
  # and the comparison goes on with the refs this checkout has. The base is
  # fetched only where this ship opens a pull request, so that a commit or a
  # push asks GitHub nothing about accounts for it
  # (adr-20260925-a-ship-refuses-before-it-sends); the comparison itself runs
  # at every level, on the refs this checkout has below `pr`. On the staging
  # flow the ship fetches the staging branch at every level all the same, and
  # strictly (task_ship, the clean-branch rule): there even a commit needs
  # origin.
  case "$__tsf_level" in
    pr | merge) jig_fetch_branches "task ship" "$__tsf_base" ;;
  esac
  __tsf_branch=$(jig_staging_branch)
  _TASK_SHIP_OWN_FLOW=""
  _task_ship_flow_agrees "$__tsf_base" "$__tsf_flow" "$__tsf_branch" "task ship" own
  # A task that changes the flow itself goes into its base, as on the direct
  # flow: neither the flow it leaves nor the one it brings decides its way.
  if [ -n "$_TASK_SHIP_OWN_FLOW" ]; then
    printf 'task ship: %s changes the git flow; its pull request goes into %s, as on the direct flow\n' \
      "$__tsf_id" "$__tsf_base"
    return 0
  fi
  [ "$__tsf_flow" = staging ] || return 0
  if [ "$__tsf_base" != "$(cfg git.base_branch main)" ]; then
    printf 'task ship: %s is cut from %s, not the base branch; the staging flow does not apply to it, so it ships into %s\n' \
      "$__tsf_id" "$__tsf_base" "$__tsf_base"
    return 0
  fi
  __tsf_land=$(jig_staging_land) || __tsf_land=""
  case "$__tsf_level" in
    pr | merge)
      [ "$__tsf_land" != pr ] || jig_fetch_branches "task ship" "$__tsf_branch"
      if [ "$__tsf_land" = pr ] && [ -z "$(jig_base_ref "$__tsf_branch")" ]; then
        jig_die "task ship: the staging branch $__tsf_branch is neither here nor on origin, so there is nothing to open the pull request into.
Nothing was committed. Fetch it, or create it on origin, and run again."
      fi
      ;;
  esac
  printf -v "$1" '%s' "$__tsf_branch"
  printf -v "$2" '%s' "$__tsf_land"
}

# _task_ship_flow_at <ref> <file> — the config committed at <ref> into <file>;
# non-zero when <ref> has none. Then _TSF_FLOW and _TSF_STAGING hold its
# git.flow (`direct` when unset) and its staging branch (empty outside the
# staging flow).
_task_ship_flow_at() {
  _TSF_FLOW="" _TSF_STAGING=""
  jig_git_show_path "$1" "$JIG_AI_DIR/config.yaml" > "$2" 2>/dev/null || return 1
  _cfg_read_v _TSF_FLOW "$2" git.flow || true
  _cfg_read_v _TSF_STAGING "$2" git.staging_branch || true
  _TSF_FLOW=${_TSF_FLOW:-direct}
  [ "$_TSF_FLOW" = staging ] || _TSF_STAGING=""
  return 0
}

# _task_ship_flow_agrees <base> <flow> <staging-branch> [<who>] [own] — refuse,
# before the commit, when the tip of <base> (jig_base_ref: origin's, else the
# local branch) names another flow or staging branch than this checkout does.
# The flow is the team's and lives on the base branch: a task branch cut before
# the team committed `git.flow: staging` — or one that dropped the key —
# would otherwise ship, and at `merge` merge, straight into the base branch.
# The base's config is read with the checkout's own parser (_cfg_read_v), on
# a copy in a temporary file. A base that is unknown here, or that has no
# config, cannot disagree: the checkout decides, as before.
#
# With `own` (task ship, where HEAD is the task branch), a difference the task
# made itself is not refused: when the config at merge-base(HEAD, <base>) is
# the base tip's, the base has not changed the flow since the branch was cut,
# so the difference is the task's own change — the task turning the flow on
# or off, or renaming the staging branch. Then _TASK_SHIP_OWN_FLOW is 1, and
# the caller ships the task into <base> as on the direct flow. Only a base
# that changed the flow after the branch was cut refuses.
_task_ship_flow_agrees() {
  local base="$1" flow="$2" staging="$3" who="${4:-task ship}" own="${5:-}" ref tmp base_flow base_staging mb
  ref=$(jig_base_ref "$base")
  [ -n "$ref" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/jig-ship-flow.XXXXXX")
  jig_cleanup_add "$tmp"
  _task_ship_flow_at "$ref" "$tmp" || return 0
  base_flow=$_TSF_FLOW base_staging=$_TSF_STAGING
  [ "$flow" = staging ] || staging=""
  [ "$base_flow" != "$flow" ] || [ "$base_staging" != "$staging" ] || return 0
  if [ -n "$own" ]; then
    mb=$(git -C "$JIG_PROJECT" merge-base HEAD "$ref" 2>/dev/null) || mb=""
    if [ -n "$mb" ]; then
      tmp=$(mktemp "${TMPDIR:-/tmp}/jig-ship-flow.XXXXXX")
      jig_cleanup_add "$tmp"
      _task_ship_flow_at "$mb" "$tmp" || _TSF_FLOW=direct
      if [ "$_TSF_FLOW" = "$base_flow" ] && [ "$_TSF_STAGING" = "$base_staging" ]; then
        _TASK_SHIP_OWN_FLOW=1
        return 0
      fi
    fi
  fi
  jig_die "$who: the git flow here is not the one $base has:
  here: git.flow: $flow${staging:+, git.staging_branch: $staging}
  $base: git.flow: $base_flow${base_staging:+, git.staging_branch: $base_staging}
Nothing was committed. Merge $base into the task branch first (git merge ${ref#refs/remotes/}), then run again."
}

# _task_ship_foreign_pr <branch> <staging> — refuse when <branch> already has
# an open pull request into another branch than <staging>: jig_ship_pr finds
# an open pull request by its head alone, and would report that one — into
# the base branch, from a ship under `direct` or opened by hand — as the
# staging pull request. Asked only in the staging flow, before the commit;
# with no forge, or a forge that cannot answer (no network, no `gh`/`glab`
# login), there is nothing to tell apart and the ship goes on, to fail where
# it always did, at the pull request.
_task_ship_foreign_pr() {
  local branch="$1" staging="$2" rows="" target url found="" merged_at kind
  kind=$(jig_forge_kind 2>/dev/null) || return 0
  if [ "$kind" = github ]; then
    # As this clone's account, resolved here in this shell: a clone that
    # cannot name one cannot answer, and jig_ship_account refuses it later,
    # before anything is sent.
    jig_gh_resolve || return 0
  fi
  rows=$(_task_branch_pr_rows "$branch" open) || return 0
  while IFS=$'\t' read -r target url merged_at; do
    [ -n "$target" ] || continue
    [ "$target" != "$staging" ] || continue
    found="$found
  $url (into $target)"
  done <<ROWS
$rows
ROWS
  [ -z "$found" ] || jig_die "task ship: $branch already has an open pull request into another branch than $staging:$found
In the staging flow its pull request goes into $staging. Close that pull request, or retarget it to $staging, and run again."
  return 0
}

# task_promote — `jig task promote <id> [--commit <sha>] [--title <t>]
# [--body-file <file>]`: "prepare for prod" for a task tested on the staging
# branch (scripts/lib/promote.sh;
# adr-20261111-prepare-for-prod-opens-the-promotion-from-git-alone). One task
# exits 0 when the pull request is open or the task is in the base already, 1
# on a refusal, 3 when a person is needed. Several ids, or `--all` with
# `--commit` (every task branch the tested commit holds and the base does not),
# promote each task on its own against one tested commit (_promote_many): the
# exit is 1 when any was refused, else 3 when any needs a person, else 0.
#
# `--by human [--revision <n>] [--json]` is a person's promotion
# (adr-20261114-a-persons-pull-request-action-does-not-read-agent-git): the git
# level is not read, and `git.promote_merge: auto` may switch auto-merge on.
# `--json` (anywhere) runs it as the producer of json_run: one task, a person's
# need (exit 3) a coded refusal, and the lines a person reads go to stderr.
task_promote() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_promote_body 1 "$@"
      return
    fi
  done
  _task_promote_body 0 "$@"
}

# _task_promote_body <as_json> [options] <id>... — the body of `task promote`.
_task_promote_body() {
  local as_json="$1" arg args=()
  shift
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  local commit="" title="" body_file="" all=0 rc=0 by="" rev="" rev_given=0
  local -a ids=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --by)
        [ $# -ge 2 ] || jig_fail usage "task promote: --by requires a value"
        [ "$2" = human ] || jig_fail usage "task promote: --by takes human, not $2"
        by=human
        shift 2 ;;
      --revision)
        [ $# -ge 2 ] || jig_fail usage "task promote: --revision requires a value"
        rev="$2"
        rev_given=1
        shift 2 ;;
      --commit)
        [ $# -ge 2 ] || jig_fail usage "task promote: --commit requires a value"
        commit="$2"
        shift 2 ;;
      --title)
        [ $# -ge 2 ] || jig_fail usage "task promote: --title requires a value"
        title="$2"
        shift 2 ;;
      --body-file)
        [ $# -ge 2 ] || jig_fail usage "task promote: --body-file requires a value"
        body_file="$2"
        shift 2 ;;
      --all)
        all=1
        shift ;;
      -*) jig_fail usage "task promote: unknown argument: $1" ;;
      *)
        ids+=("$1")
        shift ;;
    esac
  done
  # The same id twice is one task, so the mode is chosen after duplicates go.
  if [ ${#ids[@]} -gt 1 ]; then
    local -a uniq=()
    local seen="" one
    for one in "${ids[@]}"; do
      jig_has_line "$one" "$seen" && continue
      seen="$seen$one"$'\n'
      uniq+=("$one")
    done
    ids=("${uniq[@]}")
  fi
  if [ "$all" = 1 ]; then
    [ ${#ids[@]} -eq 0 ] || jig_fail usage "task promote: --all names its tasks from the tested commit; give ids or --all, not both"
    # A green build that happened to run is not a decision to ship everything
    # on staging: the commit the pipeline tested says what goes.
    [ -n "$commit" ] || jig_fail usage "task promote: --all needs --commit <sha>, the staging commit that was tested"
  fi
  [ "$all" = 1 ] || [ ${#ids[@]} -ge 1 ] || jig_fail usage "$(_task_usage promote)"
  if [ "$all" = 1 ] || [ ${#ids[@]} -gt 1 ]; then
    if [ -n "$title" ] || [ -n "$body_file" ]; then
      jig_fail usage "task promote: --title and --body-file are for one task; each of several pull requests gets its own"
    fi
  fi
  [ -z "$body_file" ] || [ -f "$body_file" ] || jig_fail usage "task promote: --body-file: no such file: $body_file"
  if [ "$rev_given" -eq 1 ]; then
    [ -n "$rev" ] || jig_fail usage "task promote: --revision is empty"
    jig_revision_valid "$rev" || jig_fail usage "task promote: --revision is not a revision: $rev"
  fi
  if [ "$as_json" -eq 1 ] || [ "$by" = human ]; then
    if [ "$all" = 1 ] || [ ${#ids[@]} -ne 1 ]; then
      jig_fail usage "task promote: a person's promotion and --json take exactly one task id"
    fi
  fi
  if [ "$by" != human ] && [ "$as_json" -eq 0 ] && [ "$rev_given" -eq 1 ]; then
    jig_fail usage "task promote: --revision is for a person's promotion: add --by human"
  fi
  # A person's promotion asks the actions table's own guard (_task_promote_refusal)
  # first: the button is offered only where the flow, the base, the autopilot and
  # the park say so, and the command refuses what the table withholds.
  if [ "$by" = human ] && _task_valid_id "${ids[0]}" && [ -f "$(task_dir "${ids[0]}")/state" ]; then
    local refusal
    _task_parked_read "${ids[0]}"
    refusal=$(_task_promote_refusal "${ids[0]}") || exit 1
    case "$refusal" in
      '') ;;
      *"is not on the staging flow"* | *"is cut from "*) jig_fail wrong-flow "$refusal" ;;
      *"runs on autopilot"*) jig_fail autopilot-running "$refusal" ;;
      *) jig_die "$refusal" ;;
    esac
  fi
  # shellcheck source=lib/promote.sh
  . "$JIG_LIB/promote.sh"
  if [ "$by" = human ]; then _PROMOTE_BY_HUMAN=1; fi
  if [ "$as_json" -eq 1 ]; then
    _PROMOTE_JSON=1
    if [ "$rev_given" -eq 1 ]; then _PROMOTE_EXPECTED=$rev; else _PROMOTE_EXPECTED=$(jig_revision_read); fi
  elif [ "$rev_given" -eq 1 ]; then
    _PROMOTE_EXPECTED=$rev
  fi
  if [ "$all" = 1 ] || [ ${#ids[@]} -gt 1 ]; then
    _promote_many "$commit" "$all" "${ids[@]+"${ids[@]}"}" || rc=$?
  elif [ "$as_json" -eq 1 ]; then
    # The lines a person reads go to stderr: stdout carries the envelope's value.
    _promote_one "${ids[0]}" "$commit" "$title" "$body_file" >&2 || rc=$?
  else
    _promote_one "${ids[0]}" "$commit" "$title" "$body_file" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    jig_status_page_flush
    exit "$rc"
  fi
  [ "$as_json" -eq 1 ] || return 0
  _task_promote_json "${ids[0]}"
}

# _task_promote_json <id> — the `data` of `task promote --json` from what
# _promote_one left: the task as `task list --json` lists it (null when the
# project has no workspace for it, a CI runner's case) and the promotion.
_task_promote_json() {
  local id="$1" task=null pr in_base=false open=false pushed=false line merge=null
  if [ -f "$(task_dir "$id")/state" ]; then
    task=$(_task_json_one "$id")
  fi
  json_str_or_null "$_PROMOTE_URL"; pr=$_JSON
  [ "$_PROMOTE_IN_BASE" != 1 ] || in_base=true
  [ "$_PROMOTE_ALREADY_OPEN" != 1 ] || open=true
  [ "$_PROMOTE_PUSHED" != 1 ] || pushed=true
  if [ -n "$_PROMOTE_MERGE_OUTCOME" ]; then
    json_quote "$_PROMOTE_MERGE_OUTCOME"; merge="{\"outcome\":$_JSON"
    json_str_or_null "$_PROMOTE_MERGE_REASON"; merge="$merge,\"reason\":$_JSON}"
  fi
  json_str_or_null "$_PROMOTE_TESTED"; line="{\"pull_request\":$pr,\"already_open\":$open,\"pushed\":$pushed,\"tested_commit\":$_JSON"
  line="$line,\"in_base\":$in_base,\"merge\":$merge}"
  printf '{"task":%s,"promote":%s}\n' "$task" "$line"
}



# _task_triage_id <id> — the id of the triage task that takes <id>'s open
# P2/P3: `<id>-findings`. Derived, so a repeated ship finds the one it filed.
_task_triage_id() {
  printf '%s-findings\n' "$1"
}

# _task_ship_triage <id> <pr-url> — hand <id>'s open P2/P3
# (_task_open_minor_findings) to one triage task, filed not started and not
# queued, with the findings verbatim, the pull request and the source task
# (adr-20261029-a-ship-hands-open-findings-to-one-triage-task). Links the two
# in state: `triage_task` on <id>, `triage_of` on the triage task. The source
# ledger is left as it is: the review's receipt pins its hash, and the merge
# that follows rechecks the receipt. Idempotent: a triage task already filed
# for <id> is named and left alone, new findings included — its task.md may be
# a person's by now. Never stops the ship: whatever goes wrong is a warning,
# and the findings are still in the pull request's body. Prints nothing when
# there is nothing to hand over.
_task_ship_triage() {
  local id="$1" url="$2" open n tid tdir sdir known md err rc=0
  open=$(_task_open_minor_findings "$id") || open=""
  [ -n "$open" ] || return 0
  n=$(_task_count_lines "$open")
  sdir=$(task_dir "$id")
  tid=$(_task_triage_id "$id")
  if ! _task_valid_id "$tid"; then
    printf 'task ship: warning: %s open finding(s) not handed over: %s is not a valid task id\n' "$n" "$tid"
    return 0
  fi
  tdir=$(task_dir "$tid")

  known=$(task_state_get "$id" triage_task)
  if [ -n "$known" ] && _task_valid_id "$known" && [ -f "$(task_dir "$known")/state" ]; then
    printf 'task ship: %s open finding(s) already handed to %s\n' "$n" "$known"
    return 0
  fi
  if [ -e "$tdir" ]; then
    if [ "$(task_state_get "$tid" triage_of)" = "$id" ]; then
      _task_rewrite_state "$sdir" triage_task "$tid"
      printf 'task ship: %s open finding(s) already handed to %s\n' "$n" "$tid"
    else
      printf 'task ship: warning: %s open finding(s) not handed over: task %s already exists and is not their triage\n' "$n" "$tid"
    fi
    return 0
  fi

  md=$(mktemp "${TMPDIR:-/tmp}/jig-triage-md.XXXXXX")
  jig_cleanup_add "$md"
  err=$(mktemp "${TMPDIR:-/tmp}/jig-triage-err.XXXXXX")
  jig_cleanup_add "$err"
  _task_triage_md "$id" "$url" "$open" > "$md"
  # A process of its own, not task_new in this one: it brings its own checks
  # (a worktree whose workspace would lose the task refuses) and its own
  # cleanup, and its refusal must not end this ship.
  (cd "$JIG_PROJECT" && bash "$JIG_SELF" task new "$tid" --from "$md") >/dev/null 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -f "$tdir/state" ]; then
    printf 'task ship: warning: %s open finding(s) not handed over: %s\n' "$n" \
      "$(sed -n '$s/^jig: error: //;$p' "$err")"
    return 0
  fi
  _task_rewrite_state "$tdir" triage_of "$id"
  _task_rewrite_state "$sdir" triage_task "$tid"
  printf 'task ship: %s open finding(s) handed to task %s\n' "$n" "$tid"
}

# _task_triage_md <id> <pr-url> <findings> — the triage task's task.md, from
# the ledger lines <findings> as _task_open_minor_findings prints them. In
# English, like every brief a script writes: it cannot know its reader.
_task_triage_md() {
  local id="$1" url="$2" open="$3"
  printf '# Triage the open findings of %s\n\n' "$id"
  printf '## Goal\n\n'
  printf 'Decide each open finding of %s with a person: file a task for it, or dismiss it with a reason.\n' "$id"
  # shellcheck disable=SC2016 # the backticks quote a command for the reader
  printf 'Once each is decided, close this task as done: `jig task set %s status consolidated`.\n\n' "$(_task_triage_id "$id")"
  printf '## Source\n\n'
  printf -- '- Task: %s\n' "$id"
  printf -- '- Pull request: %s\n' "$url"
  # shellcheck disable=SC2016 # the backticks quote a command for the reader
  printf -- '- Handed over by `jig task ship %s` on %s\n\n' "$id" "$(jig_today)"
  printf '## Findings\n\n'
  printf '%s\n' "$open" | awk -F '\t' 'NF { print "- " $1 " · " $2 " · " $4 " — " $5 }'
  printf '\n## Notes\n\n'
  printf '<!-- What was decided for each finding: the task filed for it, or why it was dismissed. -->\n'
}

# task_land <id> [--without-review] | --resolved --note-file <file> | --abort —
# land the task's pull request on the staging branch (lib/land.sh,
# adr-20261111-a-task-lands-on-staging-through-its-pull-request). Needs the git
# level `merge`, as merging into a shared branch does; below it the person
# lands it (exit 3). Exit 5: a conflict waits for the agent in the temporary
# tree, and `--resolved` continues. `--abort` sends nothing at any level.
#
# `--by human [--without-review] [--revision <n>] [--json]` is a person's
# landing (adr-20261114-a-persons-pull-request-action-does-not-read-agent-git):
# the git level is not read, nobody-answers does not apply, CI is looked at
# once and not waited for, a conflict is refused (the agent lands that), and
# every refusal is coded. `--json` anywhere runs it as the producer of json_run.
task_land() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _task_land_body 1 "$@"
      return
    fi
  done
  _task_land_body 0 "$@"
}

# _task_land_refusal_code <text> — the failure code of a refusal text
# _task_land_refusal printed, for a person's landing.
_task_land_refusal_code() {
  case "$1" in
    *"is not on the staging flow"* | *"is cut from "* | *"git.staging_land is external"* \
      | *"; landing is for a pull request into the staging branch"*) printf 'wrong-flow\n' ;;
    *"has no pull request"*) printf 'no-pull-request\n' ;;
    *" is closed; "*) printf 'pull-request-closed\n' ;;
    *"runs on autopilot"*) printf 'autopilot-running\n' ;;
    *"jig task ship of "*) printf 'ship-running\n' ;;
    *) printf 'not-ready\n' ;;
  esac
}

# _task_land_body <as_json> <id> [options] — the body of `task land`; with
# <as_json> 1 it runs inside json_run and prints the landing as data.
_task_land_body() {
  local as_json="$1" arg args=()
  shift
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ $# -ge 1 ] || jig_fail usage "$(_task_usage land)"
  local id="$1"
  shift
  local without=0 resolved=0 abort=0 note="" by="" rev="" rev_given=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --without-review) without=1; shift ;;
      --resolved) resolved=1; shift ;;
      --abort) abort=1; shift ;;
      --note-file)
        [ $# -ge 2 ] || jig_fail usage "task land: --note-file requires a value"
        note="$2"
        shift 2 ;;
      --by)
        [ $# -ge 2 ] || jig_fail usage "task land: --by requires a value"
        [ "$2" = human ] || jig_fail usage "task land: --by takes human, not $2"
        by=human
        shift 2 ;;
      --revision)
        [ $# -ge 2 ] || jig_fail usage "task land: --revision requires a value"
        rev="$2"
        rev_given=1
        shift 2 ;;
      *) jig_fail usage "task land: unknown argument: $1" ;;
    esac
  done
  if [ "$rev_given" -eq 1 ]; then
    [ -n "$rev" ] || jig_fail usage "task land: --revision is empty"
    jig_revision_valid "$rev" || jig_fail usage "task land: --revision is not a revision: $rev"
  fi
  if [ "$by" = human ]; then
    { [ "$resolved" -eq 0 ] && [ -z "$note" ]; } \
      || jig_fail usage "task land: --by human does not resolve a conflict: --resolved and --note-file are the agent's"
    [ "$abort" -eq 0 ] || [ "$as_json" -eq 0 ] || jig_fail usage "task land: --abort has no JSON form"
  else
    { [ "$as_json" -eq 0 ] && [ "$rev_given" -eq 0 ]; } \
      || jig_fail usage "task land: --json and --revision are for a person's landing: add --by human"
  fi
  # The revision this landing is checked against: the caller's, or the one read
  # here before the task is. A text landing without --revision does not check.
  local expected=""
  if [ "$by" = human ]; then
    if [ "$rev_given" -eq 1 ]; then
      expected=$rev
    elif [ "$as_json" -eq 1 ]; then
      expected=$(jig_revision_read)
    fi
  fi
  _task_valid_id "$id" || jig_fail usage "invalid task id: $id"
  [ -f "$(task_dir "$id")/state" ] || jig_fail not-found "task land: unknown task: $id"
  _task_guard_write "$id" "task land"
  if [ "$abort" -eq 1 ]; then
    [ "$resolved" -eq 0 ] && [ "$without" -eq 0 ] && [ -z "$note" ] \
      || jig_die "$(_task_usage land)"
  fi
  [ -z "$note" ] || [ "$resolved" -eq 1 ] || jig_die "task land: --note-file goes with --resolved"
  [ -z "$note" ] || [ -f "$note" ] || jig_die "task land: --note-file: no such file: $note"
  # shellcheck source=lib/land.sh
  . "$JIG_LIB/land.sh"
  if [ "$abort" -eq 1 ]; then
    land_abort "task land" "$id"
    return 0
  fi
  # What the actions table asks, in its order and words (_task_land_refusal);
  # below `merge` it is the person's to land, exit 3 as for a ship at `none`.
  local refusal pr
  if [ "$by" = human ]; then
    refusal=$(_task_land_refusal "$id" "" human) || exit 1
    [ -z "$refusal" ] || jig_fail "$(_task_land_refusal_code "$refusal")" "$refusal"
    _task_land_human "$as_json" "$id" "$without" "$expected"
    return 0
  fi
  refusal=$(_task_land_refusal "$id" "") || exit 1
  case "$refusal" in
    '') ;;
    "task land: landing "*" needs agent.git"*": merge "*)
      pr=$(task_state_get "$id" pr_url)
      printf '%s; %s stays open, the person lands it\n' "$refusal" "${pr:-its pull request}" >&2
      jig_status_page_flush
      exit 3 ;;
    *) jig_die "$refusal" ;;
  esac
  land_task "task land" "$id" "$without" "$resolved" "$note"
  if [ "$_LAND_RC" -ne 0 ]; then
    jig_status_page_flush
    exit "$_LAND_RC"
  fi
}

# _task_land_human <as_json> <id> <without-review> <expected-revision> — a
# person's landing, after the table's guard passed: land_task as the person's
# (_LAND_BY_HUMAN), CI looked at once, its lines kept to be said as the
# landing's own words, and anything but a landing a coded refusal.
_task_land_human() {
  local as_json="$1" id="$2" without="$3" expected="$4" out line why pr staging wr task
  _LAND_BY_HUMAN=1
  _LAND_EXPECTED=$expected
  # shellcheck disable=SC2034 # read by jig_ship_merge and jig_pr_mergeable (common.sh)
  JIG_SHIP_CI_TIMEOUT=0
  out=$(mktemp "${TMPDIR:-/tmp}/jig-land-out.XXXXXX")
  jig_cleanup_add "$out"
  land_task "task land" "$id" "$without" 0 "" > "$out"
  if [ -z "$_LAND_OUTCOME" ]; then
    why=""
    while IFS= read -r line; do
      case "$line" in "not landed: "*) why=${line#not landed: }; break ;; esac
    done < "$out"
    [ -n "$why" ] || why=$(sed -n '1p' "$out")
    [ -n "$_LAND_CODE" ] || jig_die "task land: $id was not landed: ${why:-no reason given}"
    jig_fail "$_LAND_CODE" "task land: ${why:-$id was not landed}"
  fi
  # The landing happened: its own lines, and the revision the write raised.
  if [ "$as_json" -eq 1 ]; then cat "$out" >&2; else cat "$out"; fi
  jig_record_changed
  [ "$as_json" -eq 1 ] || return 0
  pr=$(task_state_get "$id" pr_url)
  staging=$(jig_staging_in_use) || staging=""
  case "$_LAND_WITHOUT" in
    '') wr=null ;;
    "at the person's word") wr='"person"' ;;
    *) json_quote "$_LAND_WITHOUT"; wr=$_JSON ;;
  esac
  task=$(_task_json_one "$id")
  json_quote "$_LAND_OUTCOME"; line="{\"outcome\":$_JSON"
  json_str_or_null "$pr"; line="$line,\"pull_request\":$_JSON"
  json_str_or_null "$staging"; line="$line,\"staging\":$_JSON,\"without_review\":$wr}"
  printf '{"task":%s,"land":%s}\n' "$task" "$line"
}

# _task_staging_sound_v <var> — the staging branch's name into <var> when the
# project is on a sound staging flow, else status 1. In a listing the answer is
# the one the listing already read (_task_list_staging_read), so a guard asked
# of every task starts no process per task.
_task_staging_sound_v() {
  if [ "$_TASK_LIST_STAGING_READ" = 1 ]; then
    [ "$_TASK_LIST_STAGING_ON" = 1 ] || return 1
    cfg_v "$1" git.staging_branch ""
    return 0
  fi
  local __tss
  __tss=$(jig_staging_in_use) || return 1
  printf -v "$1" '%s' "$__tss"
}

# _task_promote_refusal <id> — why the `promote` row of the actions table is
# withheld, or nothing: the project is on a sound staging flow, the task is cut
# from its base, it waits at the staging branch for the test (parked `signal`)
# and no autopilot run is on. Local reads only. The command refuses more than
# the parked reason on its own (a runner promotes a branch with no workspace),
# so a row offered is always accepted, never the reverse.
_task_promote_refusal() {
  local id="$1" flow base base_branch parked run staging
  cfg_v base_branch git.base_branch main
  cfg_v flow git.flow direct
  if [ "$flow" != staging ] || ! _task_staging_sound_v staging; then
    printf 'task promote: %s is not on the staging flow; a task in this project reaches %s with jig task ship\n' "$id" "$base_branch"
    return 0
  fi
  jig_task_base_v base "$id"
  if [ "$base" != "$base_branch" ]; then
    printf 'task promote: %s is cut from %s, not %s; the staging flow does not apply to it\n' "$id" "$base" "$base_branch"
    return 0
  fi
  task_state_var run "$id" autopilot
  if [ "$run" = on ]; then
    printf 'task promote: %s runs on autopilot, which never promotes; stop it first\n' "$id"
    return 0
  fi
  _task_parked_lookup_v parked "$id"
  if [ "${parked%%$'\t'*}" != signal ]; then
    printf 'task promote: %s is not waiting at the staging branch for a test signal\n' "$id"
    return 0
  fi
  return 0
}

# Set by _task_actions_v while it asks the guards of the actions table: a
# pull request an older Jig opened (pr_url, no pr_into) is then placed by the
# base column of the forge cache's line for its address. The commands do not
# read the cache: for them the forge is the last word.
_TASK_PR_INTO_FROM_CACHE=""
# The forge cache, read once per process by _task_actions_v in its own shell
# (the guards run in subshells, which would each read it again): a listing's
# own copy when it has one.
_TASK_PR_CACHE=""
_TASK_PR_CACHE_READ=""

# _task_pr_into_v <var> <id> — into <var>: the branch <id>'s pull request goes
# into, from `pr_into` where a ship recorded it; else, for the table only, from
# the base column of the cache's line for `pr_url`; else nothing (the cache has
# no line, or the task has no pull request). Local reads only.
_task_pr_into_v() {
  local __tpi_into __tpi_url
  task_state_var __tpi_into "$2" pr_into
  if [ -z "$__tpi_into" ] && [ -n "$_TASK_PR_INTO_FROM_CACHE" ]; then
    task_state_var __tpi_url "$2" pr_url
    if [ -n "$__tpi_url" ]; then
      # forgecache.sh is sourced by _task_actions_v, which sets the flag.
      forgecache_entry_url "$_TASK_PR_CACHE" "$__tpi_url"
      __tpi_into=$_FORGECACHE_BASE
    fi
  fi
  printf -v "$1" '%s' "$__tpi_into"
}

# _task_other_branch_text_v <var> <who> <id> <pr> <into> <staging> <base-branch>
# — into <var>, the refusal for a pull request that goes into <into>, not the
# staging branch; into the base branch it names its path, `jig task merge-pr`.
# The one text `task land` says in the actions table and in the command: the
# failure code is read off these words (_task_land_refusal_code), so a copy that
# drifts is a refusal with the wrong code. No `$(...)`: a listing asks it per
# task.
_task_other_branch_text_v() {
  local __tob_text="$2: $4 goes into $5, not $6; landing is for a pull request into the staging branch"
  [ "$5" != "$7" ] || __tob_text="$__tob_text; merge it: jig task merge-pr $3 --by human"
  printf -v "$1" '%s' "$__tob_text"
}

# _task_landed_not_merged_text_v <var> <who> <id> <staging> — into <var>, the
# refusal of `merge-pr` for a pull request into the staging branch, in the table
# and in the command alike (_task_prdo_refusal_code reads its code off these
# words).
_task_landed_not_merged_text_v() {
  printf -v "$1" '%s: the pull request of %s goes into %s, which is landed, not merged; land it: jig task land %s --by human' "$2" "$3" "$4" "$3"
}

# _task_land_refusal <id> <pr-state> [human] — why `jig task land <id>` refuses
# this task by its state, or nothing: the `land` row of the actions table. Local
# reads only — the flow, the base, the git level, the pull request as the
# reader knows it (<pr-state>, the forge cache's), and the ship gates; what
# the forge, the network and the clean-branch walk answer is the command's.
# With <human> (`--by human`) the git level is not read, and a run of the
# task's autopilot, or a `jig task ship` waiting for CI, refuses: the agent is
# on it.
_task_land_refusal() {
  local id="$1" pr_state="$2" by="${3:-}" flow staging base base_branch line level key rc=0 pr refusal land
  # The flow and the level first, read without a process: the table asks this
  # of every task of a listing (task list --json starts none per task).
  cfg_v flow git.flow direct
  if [ "$flow" != staging ]; then
    printf 'task land: %s is not on the staging flow; a task in this project lands with jig task ship\n' "$id"
    return 0
  fi
  cfg_v staging git.staging_branch ""
  if [ "$by" != human ]; then
    _task_ship_git_v line "$id" || rc=$?
    level=${line%%$'\t'*}
    key=${line#*$'\t'}
    if [ "$rc" -ne 0 ]; then
      printf 'task land: invalid %s: %s (expected none|commit|push|pr|merge)\n' "$key" "$level"
      return 0
    fi
    if [ "$level" != merge ]; then
      # The key named is the one that is the staging level's, else agent.git
      # as ever: under autopilot.git the level in the brackets says who answered.
      local need=agent.git
      [ "$key" != agent.git_staging ] || need=agent.git_staging
      printf 'task land: landing %s on %s needs %s: merge (git level %s (%s))\n' "$id" "${staging:-the staging branch}" "$need" "$level" "$key"
      return 0
    fi
  fi
  if ! _task_staging_sound_v staging; then
    printf 'task land: %s is not on the staging flow; a task in this project lands with jig task ship\n' "$id"
    return 0
  fi
  jig_task_base_v base "$id"
  cfg_v base_branch git.base_branch main
  if [ "$base" != "$base_branch" ]; then
    printf 'task land: %s is cut from %s, not %s; the staging flow does not apply to it\n' "$id" "$base" "$base_branch"
    return 0
  fi
  cfg_v land git.staging_land pr
  if [ "$land" = external ]; then
    printf 'task land: git.staging_land is external, so CI lands %s on %s; Jig merges nothing there\n' "$id" "$staging"
    return 0
  fi
  task_state_var pr "$id" pr_url
  if [ -z "$pr" ]; then
    printf 'task land: %s has no pull request into %s; run jig task ship %s first\n' "$id" "$staging" "$id"
    return 0
  fi
  # The command's own refusal (land_task), asked here too: a pull request a
  # ship opened into another branch is not landed, so the row is not offered.
  local into
  _task_pr_into_v into "$id"
  if [ -n "$into" ] && [ "$into" != "$staging" ]; then
    _task_other_branch_text_v refusal "task land" "$id" "$pr" "$into" "$staging" "$base_branch"
    printf '%s\n' "$refusal"
    return 0
  fi
  case "$pr_state" in
    merged) printf 'task land: %s is already on %s (%s merged)\n' "$id" "$staging" "$pr"; return 0 ;;
    closed) printf 'task land: %s is closed; ship %s again to open a new pull request into %s\n' "$pr" "$id" "$staging"; return 0 ;;
  esac
  if [ "$by" = human ]; then
    _task_pr_busy_refusal_v refusal "task land" "$id" "lands"
    if [ -n "$refusal" ]; then
      printf '%s\n' "$refusal"
      return 0
    fi
  fi
  _task_ship_refusal_v refusal "$id" 0 || return 1
  [ -z "$refusal" ] || printf 'task land: %s\n' "${refusal#task ship: }"
  return 0
}

# _task_ship_still_on <id> <why> — after a `not merged` outcome of `task ship`:
# when the task's autopilot run is on, say it stays on and name the two ways
# on (ship again, or end it). Nothing when the run is not on. An empty <why>
# leaves the reason for the person to fill in.
_task_ship_still_on() {
  local run why="${2:-<why>}"
  task_state_var run "$1" autopilot
  [ "$run" = on ] || return 0
  printf 'autopilot: the run of %s is still on: ship again once it can merge, or end it: jig task autopilot %s end --reason "not merged: %s"\n' "$1" "$1" "$why"
}

# _task_pr_busy_refusal <who> <id> <what> — why the agent being on <id> refuses
# a person's action on its pull request, or nothing: its autopilot run is on,
# or (<what> `merges`) a `jig task ship` is waiting for CI and merges it itself.
# Local reads only.
_task_pr_busy_refusal() {
  local out
  _task_pr_busy_refusal_v out "$@"
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}

# _task_pr_busy_refusal_v <var> <who> <id> <what> — the same answer into
# <var>, in the caller's shell: no process per task in a listing.
_task_pr_busy_refusal_v() {
  local __tpb_var="$1" who="$2" id="$3" what="$4" run since
  printf -v "$__tpb_var" '%s' ""
  task_state_var run "$id" autopilot
  if [ "$run" = on ]; then
    local jdir line="" last="" ev="" at="" rest="" tab
    tab=$(printf '\t')
    task_dir_v jdir "$id"
    if [ -f "$jdir/autopilot" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] || last=$line
      done < "$jdir/autopilot"
    fi
    if [ -n "$last" ]; then
      at=${last%%"$tab"*}
      rest=${last#*"$tab"}
      ev=${rest%%"$tab"*}
    fi
    # The text keeps `runs on autopilot`: the --json classifiers match it.
    printf -v "$__tpb_var" '%s: %s runs on autopilot; the agent is on it, wait for it to stop' "$who" "$id"
    if [ -n "$ev" ] && [ "$ev" != "$last" ]; then
      printf -v "$__tpb_var" '%s; its last event: %s at %s' "${!__tpb_var}" "$ev" "$at"
    fi
    printf -v "$__tpb_var" '%s; if no agent is on it any more: jig task autopilot %s stop --reason <why>' "${!__tpb_var}" "$id"
    return 0
  fi
  [ -n "$what" ] || return 0
  jig_shipping_since_v since "$id"
  if [ -n "$since" ]; then
    printf -v "$__tpb_var" '%s: a jig task ship of %s has been waiting for CI since %s and %s the pull request itself' "$who" "$id" "$since" "$what"
  fi
  return 0
}

# _task_pr_state_refusal_v <var> <who> <id> <pr> <pr-state> — into <var>: why a
# pull request the forge cache calls merged or closed takes no action, or nothing.
_task_pr_state_refusal_v() {
  local __tpsr=""
  case "$5" in
    merged) __tpsr="$2: the pull request of $3 is merged ($4)" ;;
    closed) __tpsr="$2: the pull request of $3 is closed ($4); ship $3 again to open a new one" ;;
  esac
  printf -v "$1" '%s' "$__tpsr"
}

# _task_request_review_refusal <id> <pr-state> — why `jig task request-review
# <id>` refuses this task by its state, or nothing: the `request-review` row of
# the actions table. The task has a pull request the forge cache does not call
# merged or closed, and no autopilot run is on. Local reads only; the live state
# of the pull request, who the names are and what the forge allows are the
# command's.
_task_request_review_refusal() {
  local id="$1" pr_state="$2" pr why
  task_state_var pr "$id" pr_url
  if [ -z "$pr" ]; then
    printf 'task request-review: %s has no pull request; run jig task ship %s first\n' "$id" "$id"
    return 0
  fi
  _task_pr_state_refusal_v why "task request-review" "$id" "$pr" "$pr_state"
  if [ -n "$why" ]; then
    printf '%s\n' "$why"
    return 0
  fi
  _task_pr_busy_refusal "task request-review" "$id" ""
  return 0
}

# _task_merge_pr_refusal <id> <pr-state> — why `jig task merge-pr <id>` refuses
# this task by its state, or nothing: the `merge` row of the actions table. The
# task is alive, its pull request goes into its own base (never the staging
# branch: that one is landed), exists, is not merged or closed as the reader
# knows it (<pr-state>, the forge cache's), no autopilot run is on and no
# `jig task ship` waits for CI. Local reads only.
_task_merge_pr_refusal() {
  local id="$1" pr_state="$2" flow staging base base_branch pr status why
  task_state_var status "$id" status
  case "$status" in
    abandoned | archived)
      printf 'task merge-pr: task %s is %s\n' "$id" "$status"
      return 0 ;;
  esac
  cfg_v flow git.flow direct
  if [ "$flow" = staging ] && _task_staging_sound_v staging; then
    jig_task_base_v base "$id"
    cfg_v base_branch git.base_branch main
    if [ "$base" = "$base_branch" ]; then
      # A pull request a ship opened into another branch (the base, for a task
      # that changes the flow) is merged, not landed: this guard has nothing
      # to say about it. Nor about one an older Jig opened without recording
      # where (pr_url, no pr_into) and the cache does not place: the command
      # asks the forge and refuses one into the staging branch. The cache's
      # base column places it for the table (_task_pr_into_v).
      local into opened
      _task_pr_into_v into "$id"
      task_state_var opened "$id" pr_url
      if [ "$into" = "$staging" ] || { [ -z "$into" ] && [ -z "$opened" ]; }; then
        _task_landed_not_merged_text_v why "task merge-pr" "$id" "$staging"
        printf '%s\n' "$why"
        return 0
      fi
    fi
  fi
  task_state_var pr "$id" pr_url
  if [ -z "$pr" ]; then
    printf 'task merge-pr: %s has no pull request; run jig task ship %s first\n' "$id" "$id"
    return 0
  fi
  _task_pr_state_refusal_v why "task merge-pr" "$id" "$pr" "$pr_state"
  if [ -n "$why" ]; then
    printf '%s\n' "$why"
    return 0
  fi
  _task_pr_busy_refusal "task merge-pr" "$id" merges
  return 0
}

# _task_pr_status_refusal <id> — why `jig task pr-status <id>` has nothing to
# read, or nothing: the task has a pull request.
_task_pr_status_refusal() {
  local pr
  task_state_var pr "$1" pr_url
  [ -n "$pr" ] || printf 'task pr-status: %s has no pull request; run jig task ship %s first\n' "$1" "$1"
  return 0
}

# _task_prdo_refusal_code <text> — the failure code of a refusal text one of the
# guards above printed, for a person's `request-review` or `merge-pr`.
_task_prdo_refusal_code() {
  case "$1" in
    *"has no pull request"*) printf 'no-pull-request\n' ;;
    *"pull request of "*" is closed ("* | *"pull request of "*" is merged ("*) printf 'pull-request-closed\n' ;;
    *"runs on autopilot"*) printf 'autopilot-running\n' ;;
    *"jig task ship of "*) printf 'ship-running\n' ;;
    *"goes into "*) printf 'wrong-flow\n' ;;
    *) printf 'failed\n' ;;
  esac
}

# The body file task_ship writes for a major release's draft; script-global
# because the exit cleanup that removes it runs after the function returned
# (conventions/shell.md).
_TASK_SHIP_BODY_TMP=""

# _task_ship_notes_last_check — JIG_SHIP_LAST_CHECK for a release: whether its
# notes still reach the tip of the base it merges into (_TASK_SHIP_NOTES_BASE).
_TASK_SHIP_NOTES_BASE=""
# The head the notes are read at: empty for the checkout's HEAD (a ship), a pull
# request's head for `task merge-pr`, which runs wherever the person is.
_TASK_SHIP_NOTES_HEAD=""
_task_ship_notes_last_check() {
  jig_release_notes_refusal "${_TASK_SHIP_NOTES_WHO:-task ship}" "$_TASK_SHIP_NOTES_BASE" "${_TASK_SHIP_NOTES_HEAD:-HEAD}"
}
_TASK_SHIP_NOTES_WHO=""

# _task_ship_reviewers_unused <why> — say that the reviewers named were asked
# for nothing: no pull request is opened by this ship.
_task_ship_reviewers_unused() {
  printf 'task ship: --reviewer: nobody was asked for a review: %s\n' "$1"
}

# _task_ship_reviewers <staging> <land> <level> — task_ship's reviewer_args
# resolved to logins (lib/reviewers.sh), comma-separated, into
# _TASK_SHIP_REVIEWERS; empty, and said, where this ship opens no pull request.
# The account the pull request is opened as is its author, whom the forge does
# not let review it: left out, and said. Reads task_ship's reviewer_args
# (bash scoping). Called in task_ship's shell, after
# jig_ship_account named that account.
_TASK_SHIP_REVIEWERS=""
_task_ship_reviewers() {
  local staging="$1" land="$2" level="$3" self="" login arg seen=" "
  _TASK_SHIP_REVIEWERS=""
  if [ -n "$staging" ] && [ "$land" = external ]; then
    _task_ship_reviewers_unused "git.staging_land is external, so no pull request is opened"
    return 0
  fi
  if [ "$level" != pr ] && [ "$level" != merge ]; then
    _task_ship_reviewers_unused "this ship opens no pull request at this level"
    return 0
  fi
  case "$(jig_forge_kind 2>/dev/null || true)" in
    github | gitlab) ;;
    *)
      _task_ship_reviewers_unused "no forge available, so the pull request is the human's"
      return 0 ;;
  esac
  # shellcheck source=lib/reviewers.sh
  . "$JIG_LIB/reviewers.sh"
  jig_reviewers_self self \
    || jig_die "task ship: --reviewer: the forge could not say which account opens the pull request: $_RV_WHY
Nothing was sent; the commit is on this machine, and running this again goes on from it."
  for arg in "${reviewer_args[@]}"; do
    jig_reviewers_resolve "task ship" login "$arg" "$self"
    if [ "$login" = "$self" ]; then
      printf 'task ship: --reviewer %s: %s opens the pull request, and its author is not asked to review it\n' "$arg" "$login"
      continue
    fi
    case "$seen" in *" $login "*) continue ;; esac
    seen="$seen$login "
    [ "$arg" = "$login" ] || [ "$arg" = "@$login" ] || printf 'task ship: --reviewer %s: %s\n' "$arg" "$login"
    _TASK_SHIP_REVIEWERS="${_TASK_SHIP_REVIEWERS:+$_TASK_SHIP_REVIEWERS,}$login"
  done
}

task_ship() {
  jig_require_init
  [ $# -ge 1 ] || jig_die "$(_task_usage ship)"
  local id="$1"
  shift
  local message_file="" title="" body_file="" has_message=0 draft=0 partial=0
  local reviewer_args=() reviewers=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reviewer)
        [ $# -ge 2 ] || jig_die "task ship: --reviewer requires a value"
        reviewer_args+=("$2")
        shift 2 ;;
      --draft)
        draft=1
        shift ;;
      --partial)
        partial=1
        shift ;;
      --message-file)
        [ $# -ge 2 ] || jig_die "task ship: --message-file requires a value"
        has_message=1
        message_file="$2"
        shift 2 ;;
      --title)
        [ $# -ge 2 ] || jig_die "task ship: --title requires a value"
        title="$2"
        shift 2 ;;
      --body-file)
        [ $# -ge 2 ] || jig_die "task ship: --body-file requires a value"
        body_file="$2"
        shift 2 ;;
      *) jig_die "task ship: unknown argument: $1" ;;
    esac
  done
  [ "$has_message" -eq 1 ] || jig_die "task ship: --message-file is required"
  [ -f "$message_file" ] || jig_die "task ship: --message-file: no such file: $message_file"
  [ -z "$body_file" ] || [ -f "$body_file" ] || jig_die "task ship: --body-file: no such file: $body_file"
  # The files as given, before any copy below replaces them: wherever they
  # sit, they are the ship's inputs and never part of the change it stages.
  local inputs_msg="$message_file" inputs_body="$body_file"

  local dir
  dir=$(task_dir "$id")
  _task_guard_write "$id" "task ship"

  # Level first, before anything else changes: an invalid value must refuse
  # exactly like every other check here, not read as "none" by accident.
  local level key line rc=0 refusal
  line=$(_task_ship_git "$id") || rc=$?
  IFS=$'\t' read -r level key <<EOF
$line
EOF
  refusal=$(_task_ship_level_refusal "$id") || exit 1
  [ "$rc" -eq 0 ] || jig_die "$refusal"

  if [ "$level" = none ]; then
    # The fix is handed to the person to commit and push: shipped, as far as
    # parking goes (_task_ship_resumed_done) — once the completion gates pass,
    # as every other level asks them before it ships: a task with an open
    # blocking finding or no receipt is not a fix ready to hand over, and
    # dropping the record would read it as parked again.
    local none_refusal
    none_refusal=$(_task_ship_refusal "$id" "$draft") || exit 1
    if [ -z "$none_refusal" ]; then
      [ "$draft" -eq 1 ] || _task_gate_hooks "$id" ship "task ship"
      _task_ship_resumed_done "$id" "$dir" "$draft" ""
    fi
    # To stderr and exit 3, not `jig_die` (exit 1): a skill reads 3 as "hand
    # this over to the human", not as a command that failed.
    printf '%s\n' "$refusal" >&2
    exit 3
  fi

  # The completion gates and the branch, as the actions table asks them; a
  # draft skips the gates (_task_ship_refusal).
  local blocking="" receipt_msg="" refusal
  refusal=$(_task_ship_refusal "$id" "$draft") || exit 1
  [ -z "$refusal" ] || jig_die "$refusal"
  # A task filed before route evidence was checked passes with a warning.
  [ "$draft" -eq 1 ] || _task_route_evidence_gate "$id" consolidate "task ship"

  local branch base cur
  refusal=$(_task_ship_branch_refusal "$id") || exit 1
  [ -z "$refusal" ] || jig_die "$refusal"
  branch=$(task_state_get "$id" branch)
  base=$(jig_task_base "$id")
  cur=$(_task_current_branch)
  [ "$cur" = "$branch" ] || jig_die "task ship: current branch is $cur, but $id is on $branch; switch branches first"
  # The project's ship hooks, after Jig's own gates and the branch, and before
  # anything is committed or sent (adr-20260925-a-ship-refuses-before-it-sends).
  # A draft skips them as it skips the gates; the recheck before a merge does
  # not run them again, since they passed in this same call.
  [ "$draft" -eq 1 ] || _task_gate_hooks "$id" ship "task ship"

  # The project's git flow, asked before anything changes: where the pull
  # request goes is decided here, never after the commit or the push.
  local staging="" land=""
  _task_ship_flow_v staging land "$id" "$level" "$base"
  # The level above was read as the staging branch's (agent.git_staging) before
  # the flow was known. A task that changes the flow itself goes into its base
  # as on the direct flow, and the base answers to agent.git: read again, before
  # anything is committed (adr-20261114-landing-on-staging-has-its-own-git-level).
  if [ -z "$staging" ] && [ "$key" = agent.git_staging ]; then
    local own_level
    cfg_v own_level agent.git none
    key=agent.git
    level=$own_level
    if ! _cfg_agent_git_level "$level"; then
      jig_die "task ship: invalid agent.git: $level (expected none|commit|push|pr|merge)"
    fi
    if [ "$level" = none ]; then
      local own_none
      own_none=$(_task_ship_refusal "$id" "$draft") || exit 1
      [ -n "$own_none" ] || _task_ship_resumed_done "$id" "$dir" "$draft" ""
      printf 'task ship: agent.git is none in this clone; the human commits\n' >&2
      exit 3
    fi
    # The flow was asked at the staging level; at agent.git's it may fetch the
    # base it skipped, so ask it again before the flow's answer is trusted.
    _task_ship_flow_v staging land "$id" "$level" "$base"
    [ -z "$staging" ] || jig_die "task ship: the git flow $base has on origin changed between two reads; nothing was committed. Run again."
  fi
  # An open pull request into another branch is refused here, before the
  # commit, not where the pull request is opened: by then the push would
  # already have added this commit to it (adr-20260925-a-ship-refuses-before-it-sends).
  if [ -n "$staging" ] && [ "$land" = pr ]; then
    case "$level" in pr | merge) _task_ship_foreign_pr "$branch" "$staging" ;; esac
  fi
  # The clean-branch rule, at every level and before the commit: a branch that
  # carries the staging branch goes neither into a pull request nor to origin
  # (adr-20261111-a-task-lands-on-staging-through-its-pull-request).
  # The staging branch as origin has it now, at every level and whoever lands:
  # without it the rule cannot be judged, and a ship that cannot judge refuses.
  # So on the staging flow even a ship at `commit` needs origin: offline it
  # refuses, with nothing committed, where the direct flow commits
  # (adr-20261111-in-the-staging-flow-a-task-ships-into-the-staging-branch).
  if [ -n "$staging" ]; then
    local failed
    jig_git_origin_account "task ship" read
    if ! failed=$(jig_fetch_fresh "$staging"); then
      jig_die "task ship: could not fetch $failed from origin; whether $branch carries $staging cannot be told without it.
Nothing was committed. Fetch it (or create it on origin) and run again."
    fi
    # shellcheck source=lib/land.sh
    . "$JIG_LIB/land.sh"
    land_clean_branch_refusal "task ship" "$id" HEAD "$base" "$staging"
  fi

  # The tracker issue into the commit's first line and the pull request's
  # title, where trackers' VCS integrations look for it — written to a copy,
  # so the task's own commit-message artifact stays as its author wrote it.
  local issue subject named msg_tmp
  issue=$(task_state_get "$id" issue)
  if [ -n "$issue" ]; then
    subject=$(head -n 1 "$message_file")
    named=$(_task_issue_subject "$subject" "$issue")
    if [ "$named" != "$subject" ]; then
      msg_tmp=$(mktemp "${TMPDIR:-/tmp}/jig-ship-msg.XXXXXX")
      jig_cleanup_add "$msg_tmp"
      { printf '%s\n' "$named"; tail -n +2 "$message_file"; } > "$msg_tmp"
      message_file="$msg_tmp"
      printf "task ship: issue %s added to the message's first line\n" "$issue"
    fi
    [ -z "$title" ] || title=$(_task_issue_subject "$title" "$issue")
  fi

  # The issues of the tasks this one absorbed (`jig task merge`), named once at
  # the end of the commit and of the pull request's body: the tracker links
  # them from there, as it links the task's own. Jig never calls the tracker.
  local absorbed_refs="" one one_issue
  for one in $(printf '%s,%s' "$(task_state_get "$id" absorbs)" "$(task_state_get "$id" absorbs_partly)" | tr ',' ' '); do
    one_issue=$(task_state_get "$one" issue 2>/dev/null) || one_issue=""
    [ -n "$one_issue" ] || continue
    absorbed_refs="${absorbed_refs:+$absorbed_refs, }$(_task_issue_ref "$one_issue")"
  done
  if [ -n "$absorbed_refs" ] && ! grep -q '^Absorbs: ' "$message_file"; then
    msg_tmp=$(mktemp "${TMPDIR:-/tmp}/jig-ship-msg.XXXXXX")
    jig_cleanup_add "$msg_tmp"
    { cat "$message_file"; printf '\nAbsorbs: %s\n' "$absorbed_refs"; } > "$msg_tmp"
    message_file="$msg_tmp"
    if [ -n "$body_file" ] && ! grep -q '^Absorbs: ' "$body_file"; then
      local body_tmp
      body_tmp=$(mktemp "${TMPDIR:-/tmp}/jig-ship-body.XXXXXX")
      jig_cleanup_add "$body_tmp"
      { cat "$body_file"; printf '\nAbsorbs: %s\n' "$absorbed_refs"; } > "$body_tmp"
      body_file="$body_tmp"
    fi
    printf 'task ship: absorbed issues named: %s\n' "$absorbed_refs"
  fi

  # The hooks a person waived for this task, named in the commit and in the
  # pull request's body, so a reviewer reads a set-aside refusal where the
  # change is read and not only on the status page
  # (adr-20261114-a-person-waives-a-gate-hooks-refusal-for-one-task). Where no
  # --body-file is given the body is the message's tail, so it gets the block
  # from the message.
  local waivers waiver_block="" w_gate w_path w_date w_reason w_count=0
  waivers=$(_task_waivers "$id")
  if [ -n "$waivers" ]; then
    while IFS=$'\t' read -r w_gate w_path w_date w_reason; do
      [ -n "$w_gate" ] || continue
      waiver_block="$waiver_block- hooks.$w_gate $w_path: $w_reason"$'\n'
      w_count=$((w_count + 1))
    done <<EOF
$waivers
EOF
  fi
  if [ "$w_count" -gt 0 ]; then
    if ! grep -q '^Hook waivers:' "$message_file"; then
      msg_tmp=$(mktemp "${TMPDIR:-/tmp}/jig-ship-msg.XXXXXX")
      jig_cleanup_add "$msg_tmp"
      { cat "$message_file"; printf '\nHook waivers:\n%s' "$waiver_block"; } > "$msg_tmp"
      message_file="$msg_tmp"
    fi
    if [ -n "$body_file" ] && ! grep -q '^Hook waivers:' "$body_file"; then
      local waiver_body_tmp
      waiver_body_tmp=$(mktemp "${TMPDIR:-/tmp}/jig-ship-body.XXXXXX")
      jig_cleanup_add "$waiver_body_tmp"
      { cat "$body_file"; printf '\nHook waivers:\n%s' "$waiver_block"; } > "$waiver_body_tmp"
      body_file="$waiver_body_tmp"
    fi
    printf 'task ship: hook waivers named: %s\n' "$w_count"
  fi

  # The commit a release's notes were checked up to, recorded by the notes
  # task (`task set <id> notes_through`), goes into the commit as a trailer:
  # git is where `task ship`, `spec ship` and CI all read it from, whichever
  # task wrote the notes (adr-20261112-release-notes-name-the-commit-they-describe).
  local notes_through
  notes_through=$(task_state_get "$id" notes_through)
  if [ -n "$notes_through" ] && ! grep -q "^Release-Notes-Through: $notes_through\$" "$message_file"; then
    msg_tmp=$(mktemp "${TMPDIR:-/tmp}/jig-ship-msg.XXXXXX")
    jig_cleanup_add "$msg_tmp"
    { cat "$message_file"; printf '\nRelease-Notes-Through: %s\n' "$notes_through"; } > "$msg_tmp"
    message_file="$msg_tmp"
    printf 'task ship: release notes describe the base through %s\n' "$(git -C "$JIG_PROJECT" rev-parse --short "$notes_through" 2>/dev/null || printf '%s' "$notes_through")"
  fi

  _task_ship_unverified_notice
  # Which key decided how far this goes: with autopilot.git and agent.git
  # apart, "stopped at push" alone would not say whose setting stopped it.
  printf 'task ship: git level %s (%s)\n' "$level" "$key"

  jig_ship_stage_tracked "task ship" "$inputs_msg" "$inputs_body"
  jig_ship_check_staged "task ship"
  # At `merge` nobody reads the pull request before it lands, so an index that
  # leaves part of the change behind has to be declared, not only warned about
  # (adr-20261029-task-ship-stages-tracked-changes-and-refuses-new-files). A
  # draft is never merged, and below `merge` a person takes the next step.
  if [ "$level" = merge ] && [ "$draft" -eq 0 ] && [ "$partial" -eq 0 ]; then
    local left_out
    left_out=$(jig_ship_left_out "$message_file" "$inputs_msg" "$inputs_body")
    [ -z "$left_out" ] || jig_die "task ship: this commit would merge without these changes:
$left_out
Nothing was committed. Stage what belongs to the task (git add -u, git add <path>) and run again; if the rest is not this task's, run again with --partial."
  fi
  jig_ship_commit "task ship" "$message_file" "$inputs_msg" "$inputs_body"
  # Notes brought up to a base that moved by commits no user notices change no
  # file; the newer notes_through still has to reach git, or the release would
  # stay refused. Then the commit is empty but for its message.
  if [ -n "$notes_through" ]; then
    local notes_from="refs/remotes/origin/$base"
    git -C "$JIG_PROJECT" rev-parse --verify --quiet "$notes_from" >/dev/null 2>&1 || notes_from=$base
    if [ "$(jig_release_notes_through "$notes_from")" != "$notes_through" ]; then
      git -C "$JIG_PROJECT" commit --allow-empty -F "$message_file" >/dev/null \
        || jig_die "task ship: git commit failed"
      printf 'committed %s: no change but the release notes reaching %s\n' \
        "$(git -C "$JIG_PROJECT" rev-parse --short HEAD)" "$(git -C "$JIG_PROJECT" rev-parse --short "$notes_through")"
    fi
  fi

  # Before the first step that leaves this machine (common.sh, "what a ship
  # may send out"). Asked here rather than just before the push: "this branch
  # carries no work" is the same answer at every level, and at `commit` the
  # human is the one who pushes next — telling them now is what stops the
  # empty branch one step later.
  jig_ship_require_commits "task ship" "$branch" "$base"

  if [ "$level" = commit ]; then
    _task_ship_resumed_done "$id" "$dir" "$draft" "$staging"
    [ "${#reviewer_args[@]}" -eq 0 ] || _task_ship_reviewers_unused "this ship opens no pull request at this level"
    printf "stopped at commit: push is the human's\n"
    return 0
  fi

  # Under `external` CI lands whatever reaches origin, so a pushed draft would
  # be merged into the staging branch: a draft is kept on this machine.
  if [ "$draft" -eq 1 ] && [ -n "$staging" ] && [ "$land" = external ]; then
    printf 'stopped at commit: a draft is not pushed, since git.staging_land is external and CI lands whatever is pushed to %s; push it once it is finished\n' "$branch"
    return 0
  fi

  # A change that raises the version into the default branch is a release,
  # whoever planned it: its merge follows `release.merge` as an epic's final
  # pull request does (spec_ship_final), and a `major` one opens as a draft
  # for a person (adr-20261026-a-task-that-raises-the-version-is-a-release).
  # An epic is not the default branch: there the release is the epic's own.
  # Nor is the staging branch: what reaches the default branch from there is
  # the promotion's pull request, a later step.
  local raise="" r_file r_old r_new r_level release_hold="" pr_draft="$draft" notes_gap
  if [ -z "$staging" ] && [ "$base" = "$(cfg git.base_branch main)" ]; then
    raise=$(jig_release_raise "$base")
  fi
  # Before anything is sent, a release's notes must describe every commit it
  # carries into the base: one merged after they were written would reach the
  # tag undescribed. Below `pr` a person opens the pull request, and this
  # repository's CI asks the same question there.
  if [ -n "$raise" ] && [ "$level" != push ]; then
    notes_gap=$(jig_release_notes_refusal "task ship" "$base")
    [ -z "$notes_gap" ] || jig_die "task ship: not sent: this change raises the version, and $notes_gap
The commit stays on $branch here; nothing was pushed."
  fi

  # The account is the pull request's: under `external` none is opened, and
  # the forge is asked nothing.
  if [ -z "$staging" ] || [ "$land" != external ]; then
    jig_ship_account "task ship" "$level"
  fi
  # The reviewers named, resolved to logins before the push: a name that fits
  # nobody, or several people, is refused with nothing sent, and the commit
  # stays here for the run that names them better.
  if [ "${#reviewer_args[@]}" -gt 0 ]; then
    _task_ship_reviewers "$staging" "$land" "$level"
    reviewers=$_TASK_SHIP_REVIEWERS
  fi
  jig_ship_push "task ship" "$branch"
  _task_ship_resumed_done "$id" "$dir" "$draft" "$staging"

  if [ -n "$staging" ] && [ "$land" = external ]; then
    printf 'stopped at push: git.staging_land is external, so CI lands %s on %s; no pull request opened\n' "$branch" "$staging"
    # No pull request will ever list the open P2/P3 here, and no person opens
    # one later, at any level: they go to their triage task now, as at the
    # other ends (adr-20261029-a-ship-hands-open-findings-to-one-triage-task).
    # A draft's findings stay its own.
    if [ "$draft" -eq 0 ] && [ -n "$(_task_open_minor_findings "$id")" ]; then
      printf 'task ship: no pull request lists the open findings, so they go to their triage task\n'
      _task_ship_triage "$id" "none: git.staging_land is external, so CI lands $branch on $staging"
    fi
    return 0
  fi

  if [ "$level" = push ]; then
    printf "stopped at push: the pull request is the human's\n"
    return 0
  fi

  if [ -n "$raise" ]; then
    IFS=$'\t' read -r r_file r_old r_new r_level <<EOF
$raise
EOF
    printf 'task ship: this change raises the version in %s: %s -> %s\n' "$r_file" "$r_old" "$r_new"
    if [ "$level" = merge ] && [ "$draft" -eq 0 ]; then
      if ! _task_nobody_answers "$id"; then
        release_hold="this change raises the version; outside an unattended run a release's merge is the human's"
      elif [ "$(jig_release_merge)" != agent ]; then
        release_hold="release.merge is human in this clone; the release's merge is the person's"
      elif [ "$r_level" = major ]; then
        release_hold="a major release needs a human; the pull request is a draft"
        pr_draft=1
        _TASK_SHIP_BODY_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-task-body.XXXXXX")
        jig_cleanup_add "$_TASK_SHIP_BODY_TMP"
        {
          printf 'Needs a human: major release?\n\n'
          if [ -n "$body_file" ]; then cat "$body_file"; else tail -n +2 "$message_file"; fi
        } > "$_TASK_SHIP_BODY_TMP"
        body_file="$_TASK_SHIP_BODY_TMP"
      fi
    fi
  fi

  local pr_base="$base"
  if [ -n "$staging" ]; then
    pr_base="$staging"
    printf 'task ship: git flow staging: the pull request goes into %s, not %s\n' "$staging" "$base"
  fi
  jig_ship_pr "task ship" "$branch" "$pr_base" "$message_file" "$title" "$body_file" "$pr_draft" 0 "$reviewers"
  # The pull request's address, kept so the status page can link it the
  # moment it exists. A fact about what ship did, not a merge state: whether
  # it was merged is still derived by housekeeping every run (ADR-0005).
  case "$JIG_SHIP_URL" in
    https://*)
      _task_rewrite_state "$dir" pr_url "$JIG_SHIP_URL"
      # Where it goes, kept beside it: the staging level answers only for a
      # pull request into the staging branch (_task_ships_to_staging), and a
      # task that changes the flow opens its own into the base.
      _task_rewrite_state "$dir" pr_into "$pr_base"
      # The open P2/P3 go to one triage task once a pull request exists to
      # link, before the merge and before the autopilot's `end` names it
      # (adr-20261029-a-ship-hands-open-findings-to-one-triage-task). A draft
      # is not a finished task: its findings are still its own.
      if [ "$draft" -eq 0 ]; then
        _task_ship_triage "$id" "$JIG_SHIP_URL"
      fi
      ;;
  esac

  # Landing on the staging branch: at `merge` the pull request just opened
  # lands as `jig task land` lands it — the approval by git.staging_review,
  # the merge on the forge, the direct merge when it conflicts — and its exit
  # code is the ship's: 3 a person decides, 5 a conflict waits for the agent
  # (adr-20261111-a-task-lands-on-staging-through-its-pull-request).
  if [ -n "$staging" ]; then
    if [ "$level" = merge ] && [ "$draft" -eq 1 ]; then
      printf 'not merged: a draft pull request is never merged\n'
    elif [ "$level" = merge ] && [ -n "$JIG_SHIP_URL" ]; then
      jig_shipping_begin "$id"
      land_task "task ship" "$id" 0 0 ""
      jig_shipping_end "$id"
      if [ "$_LAND_RC" -ne 0 ]; then
        jig_status_page_flush
        exit "$_LAND_RC"
      fi
    elif [ "$level" = merge ]; then
      printf "%s is not on %s yet: with no pull request to land, landing is the human's\n" "$branch" "$staging"
    else
      printf "%s is not on %s yet: landing the pull request is the human's\n" "$branch" "$staging"
    fi
    return 0
  fi

  [ "$level" = merge ] || return 0
  if [ "$draft" -eq 1 ]; then
    printf 'not merged: a draft pull request is never merged\n'
    _task_ship_still_on "$id" "a draft pull request is never merged"
    return 0
  fi
  if [ -n "$release_hold" ]; then
    printf 'not merged: %s\n' "$release_hold"
    _task_ship_still_on "$id" "$release_hold"
    return 0
  fi
  # The task's own gates once more, right before the merge: the merge is the
  # last moment either can still stop the change.
  blocking=$(_task_blocking_findings "$id")
  if [ -n "$blocking" ]; then
    printf 'not merged: %s blocking finding(s) in the ledger\n' "$(_task_count_lines "$blocking")"
    _task_ship_still_on "$id" "blocking finding(s) in the ledger"
    return 0
  fi
  receipt_msg=$(_task_receipt_gate_message "$id")
  if [ -n "$receipt_msg" ]; then
    printf 'not merged: %s\n' "$receipt_msg"
    _task_ship_still_on "$id" "$receipt_msg"
    return 0
  fi
  local missing
  if [ "$(task_state_get "$id" route_evidence)" = required ]; then
    missing=$(_task_route_evidence_list "$id" consolidate)
    if [ -n "$missing" ]; then
      printf 'not merged: the route of %s is missing: %s\n' "$id" "$missing"
      _task_ship_still_on "$id" "the route is missing: $missing"
      return 0
    fi
  fi
  # The base may move while the pull request waits for CI: a release's notes
  # are checked again after CI is green, right before the merge command.
  if [ -n "$raise" ]; then
    _TASK_SHIP_NOTES_BASE=$base
    # shellcheck disable=SC2034 # read by jig_ship_merge (common.sh)
    JIG_SHIP_LAST_CHECK=_task_ship_notes_last_check
  fi
  local sha
  sha=$(git -C "$JIG_PROJECT" rev-parse HEAD)
  jig_shipping_begin "$id"
  jig_ship_merge "task ship" "$JIG_SHIP_URL" "$sha" any
  jig_shipping_end "$id"
  [ "$JIG_SHIP_MERGED" = 1 ] || _task_ship_still_on "$id" ""
  # Merged here, so this checkout goes back to the base and the branch goes;
  # from the task's own worktree it stays for housekeeping
  # (adr-20261007-a-merged-branch-leaves-with-its-work).
  jig_ship_leave "task ship" "$branch" "$base" "$sha"
}
