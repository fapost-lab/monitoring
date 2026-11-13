# Shared helpers for every jig command. Sourced by scripts/jig.
# bash 3.2 compatible: no associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

JIG_AI_DIR=".ai"
export JIG_AI_DIR

# --- output --------------------------------------------------------------

jig_log()  { [ -n "${JIG_QUIET:-}" ] || printf '%s\n' "$*"; }
jig_info() { [ -n "${JIG_QUIET:-}" ] || printf 'jig: %s\n' "$*" >&2; }
jig_warn() { printf 'jig: warning: %s\n' "$*" >&2; }
jig_die()  { _jig_die_as failed "$@"; }

# jig_fail <code> <message...> — jig_die, naming the stable failure code a
# program reads from a `--json` refusal's `error.code` (schemas/json.md, "Failure
# codes"). The person reads the same `jig: error: <message>` either way; a
# refusal that names no code is `failed`.
jig_fail() {
  local code="$1"
  shift
  _jig_die_as "$code" "$@"
}

# Inside a `--json` producer (json_run sets _JIG_JSON_CODES there, never
# exported) the code goes on the line just before the message, behind a unit
# separator: the two travel and vanish together — a `2>/dev/null` swallows
# both — so json_run always pairs the message it reports with its own code,
# and strips the marker before stderr reaches a person.
_jig_die_as() {
  [ -z "${_JIG_JSON_CODES:-}" ] || printf '\037jig: code: %s\n' "$1" >&2
  shift
  printf 'jig: error: %s\n' "$*" >&2
  # A command that changed a task and then failed still redraws the status
  # page, so the page never shows less than the files do.
  jig_status_page_flush
  exit 1
}

# --- cleanup that outlives the function that asked for it ---------------------
#
# One accumulating EXIT/INT/TERM mechanism for the whole process. A `trap` is one
# slot: libraries sourced into one process that each set their own replace one
# another, and a library that sets none leaves its temporary files behind when
# the command is interrupted. Everything that must go when the command ends goes
# through here instead:
#
#   jig_cleanup_add [-d] <path>   remove <path> (a directory with -d) at exit
#   jig_on_exit '<command>'       run <command> (single-quoted, evaluated at exit)
#
# Both may be called any number of times, from any library, in any order; actions
# run first, in the order given, then the paths. Registering a path that is gone
# by then (the `mv` already published it) is harmless, and registering the same
# path twice is a no-op, so a loop that rewrites one file does not grow the list.
# SIGINT and SIGTERM exit with 130 and 143, which runs the EXIT handler: the
# command ends there instead of carrying on after its cleanup.
#
# Call it from the main shell, not from `$(...)`: a subshell that registers starts
# a list of its own (BASH_SUBSHELL differs from the one that built the parent's)
# and never removes what its parent registered. It does not promise more: bash 3.2
# skips the EXIT trap of a `$(...)` that simply runs off its end, so a temporary
# made there is cleaned only by an `exit` or a signal. SIGKILL cannot be trapped;
# what it leaves is the price of a signal nothing can catch.
_JIG_EXIT_ACTIONS=""
_JIG_EXIT_FILES=""
_JIG_EXIT_DIRS=""
_JIG_EXIT_LEVEL=""

# _jig_exit_arm — own the traps for the current shell level, once.
_jig_exit_arm() {
  local level="${BASH_SUBSHELL:-0}"
  [ "$_JIG_EXIT_LEVEL" != "$level" ] || return 0
  _JIG_EXIT_ACTIONS=""
  _JIG_EXIT_FILES=""
  _JIG_EXIT_DIRS=""
  _JIG_EXIT_LEVEL="$level"
  trap '_jig_exit_run' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

jig_on_exit() {
  _jig_exit_arm
  case "$_JIG_EXIT_ACTIONS" in
    *"
$1
"*) return 0 ;;
  esac
  _JIG_EXIT_ACTIONS="$_JIG_EXIT_ACTIONS
$1
"
}

jig_cleanup_add() {
  local dir=0 p
  if [ "${1:-}" = "-d" ]; then dir=1; shift; fi
  p="${1:-}"
  [ -n "$p" ] || return 0
  _jig_exit_arm
  if [ "$dir" = 1 ]; then
    case "$_JIG_EXIT_DIRS" in *"
$p
"*) return 0 ;; esac
    _JIG_EXIT_DIRS="$_JIG_EXIT_DIRS
$p
"
  else
    case "$_JIG_EXIT_FILES" in *"
$p
"*) return 0 ;; esac
    _JIG_EXIT_FILES="$_JIG_EXIT_FILES
$p
"
  fi
}

# --- a signal that is not left waiting -------------------------------------
#
# A trapped signal runs its handler only when the command the shell is waiting on
# has ended: `exit 143` above waits out a `sleep 100`, a test run, or one long
# expansion in the shell itself (a quadratic string loop took almost 20 hours to
# reach it, and its children outlived the parent). `wait` is the one builtin a
# trapped signal interrupts, so the dispatcher runs the command as a background
# job and waits for it here. On SIGTERM or SIGINT the job and everything under it
# get SIGTERM (their cleanup runs), and SIGKILL after JIG_TERM_GRACE seconds
# (default 5; digits only) to what is still there. The job keeps its standard
# input. A background job ignores SIGINT, so 130 and 143 come from this process,
# not from the job's own traps above. SIGKILL of this process cannot be handled:
# the job is orphaned and goes on, which is the price of a signal nothing catches
# (its lock and busy records name this pid, so they read as stale at once and a
# later run may take them while the orphan still works).

# _jig_descendants <pid> — every process under <pid>, one per line. Always
# succeeds: it runs in the signal handler under `set -e`, and a failure there
# killed the handler with status 1 before it signalled anything, orphaning the
# job. `ps -o` is POSIX, but the `ps` of Git Bash (MSYS, Cygwin) has no `-o`
# and fails; Cygwin and MSYS give every process a `/proc/<pid>/ppid` instead,
# which Linux and macOS do not, so the fallback is read only where `ps` failed.
# _JIG_PROC_ROOT moves that directory for the tests.
_jig_descendants() {
  local rows
  rows=$(ps -A -o pid= -o ppid= 2>/dev/null) || rows=""
  [ -n "$rows" ] || rows=$(_jig_proc_parents)
  printf '%s\n' "$rows" | awk -v root="$1" '
    NF >= 2 { n++; id[n] = $1; par[$1] = $2 }
    END {
      mark[root] = 1; changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= n; i++)
          if (!(id[i] in mark) && (par[id[i]] in mark)) { mark[id[i]] = 1; print id[i]; changed = 1 }
      }
    }' || true
  return 0
}

# _jig_proc_parents — `<pid> <ppid>` per process, from /proc/<pid>/ppid. A
# process that ends during the walk is skipped: `2>/dev/null` comes before the
# input redirection, so the failed open is silent too.
_jig_proc_parents() {
  local d ppid
  for d in "${_JIG_PROC_ROOT:-/proc}"/[0-9]*; do
    [ -f "$d/ppid" ] || continue
    ppid=""
    read -r ppid 2>/dev/null < "$d/ppid" || [ -n "$ppid" ] || continue
    printf '%s %s\n' "${d##*/}" "$ppid"
  done
  return 0
}

_JIG_SUP_PID=""

# _jig_any_alive <pid>... — true while one of them still runs.
_jig_any_alive() {
  local p
  for p in "$@"; do
    if kill -0 "$p" 2>/dev/null; then return 0; fi
  done
  return 1
}

# _jig_supervise_signal <exit code> — end the job and its tree, then exit.
_jig_supervise_signal() {
  local code="$1" tree grace="${JIG_TERM_GRACE:-5}" until
  case "$grace" in ''|*[!0-9]*) grace=5 ;; esac
  # The tree is read once, before anything dies: a child the job leaves behind
  # when it exits on TERM is still in this list for the SIGKILL below.
  # Should the tree be unreadable after all, the job alone still gets the
  # signals and this process still exits with <code>.
  tree="$(_jig_descendants "$_JIG_SUP_PID" || true) $_JIG_SUP_PID"
  # shellcheck disable=SC2086
  kill -TERM $tree 2>/dev/null || true
  # Wait for every process of the tree, not only the job: the job subshell has no
  # TERM trap and dies at once, while a command below it is still running its own
  # exit cleanup; SIGKILL at that moment would take the cleanup with it.
  until=$((SECONDS + grace))
  # shellcheck disable=SC2086
  while _jig_any_alive $tree && [ "$SECONDS" -lt "$until" ]; do
    sleep 0.1
  done
  # shellcheck disable=SC2086
  kill -KILL $tree 2>/dev/null || true
  wait "$_JIG_SUP_PID" 2>/dev/null || true
  exit "$code"
}

# jig_supervise <command> [args] — run it as a job that SIGTERM and SIGINT reach
# at once; its exit status is this one's. Call it once, from the main shell.
jig_supervise() {
  local rc=0
  # The explicit `exit`: bash 3.2 skips the EXIT trap of a background subshell
  # that only runs off its end, and the command's cleanup lives in that trap.
  { "$@"; exit "$?"; } 0<&0 &
  _JIG_SUP_PID=$!
  trap '_jig_supervise_signal 143' TERM
  trap '_jig_supervise_signal 130' INT
  wait "$_JIG_SUP_PID" || rc=$?
  return "$rc"
}

_jig_exit_run() {
  [ "$_JIG_EXIT_LEVEL" = "${BASH_SUBSHELL:-0}" ] || return 0
  local line
  while IFS= read -r line; do
    [ -z "$line" ] || eval "$line" || true
  done <<EOF_ACTIONS
$_JIG_EXIT_ACTIONS
EOF_ACTIONS
  while IFS= read -r line; do
    [ -z "$line" ] || rm -f -- "$line" 2>/dev/null || true
  done <<EOF_FILES
$_JIG_EXIT_FILES
EOF_FILES
  while IFS= read -r line; do
    [ -z "$line" ] || rm -rf -- "$line" 2>/dev/null || true
  done <<EOF_DIRS
$_JIG_EXIT_DIRS
EOF_DIRS
  return 0
}

# --- repository ------------------------------------------------------------

# Remove the environment variables that tell git which repository to work on,
# so every git jig runs acts on the checkout jig is standing in.
#
# `git rev-parse --show-toplevel` asks the environment first, and `git -C
# <dir>` does not override it: with GIT_DIR and GIT_WORK_TREE pointing at
# another repository and the working directory untouched, every record jig
# wrote landed in that other repository and none in this one — measured. The
# layer above this one had the same bug with an inherited JIG_PROJECT
# (adr-20260924-a-checkout-records-what-is-happening-in-it), and a component
# that describes its own surroundings may not learn them from somebody else,
# at either layer.
#
# The list is git(1) "The Git Repository", read rather than recalled, kept to
# the variables that choose *what* git acts on:
#   GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR  the repository and its tree
#   GIT_OBJECT_DIRECTORY, GIT_ALTERNATE_OBJECT_DIRECTORIES  where objects go
#   GIT_INDEX_FILE                          the index add and commit see
#   GIT_NAMESPACE                           which refs exist
#   GIT_CEILING_DIRECTORIES                 how far discovery walks up
#   GIT_DISCOVERY_ACROSS_FILESYSTEM         whether it crosses a mount point
# All of them or none: clearing GIT_DIR while GIT_OBJECT_DIRECTORY stands
# commits into this repository and writes the objects into another one, which
# is worse than either end of the choice.
#
# The line is location, not configuration. GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM,
# GIT_CONFIG_NOSYSTEM and GIT_CONFIG_COUNT/KEY/VALUE can redirect a work tree
# too, through core.worktree, but they are how a person configures git on
# purpose — tests/run.sh isolates a run with GIT_CONFIG_NOSYSTEM — and jig
# reads the configuration of the repository it found. It decides which
# repository it is in; it does not decide how that repository is set up.
#
# Variables that only change a format or a default (GIT_INDEX_VERSION,
# GIT_DEFAULT_HASH, GIT_DEFAULT_REF_FORMAT) and those that change behaviour
# without changing the address are left alone.
jig_clear_git_location_env() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_INDEX_FILE GIT_NAMESPACE \
    GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM
}

# Print the git repository root of the current directory or fail.
#
# The clearing belongs to the callers below, not here: this runs inside
# `$(jig_repo_root)`, a subshell, where an unset would not outlive the one
# command it guards.
jig_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

# Set JIG_PROJECT to the repository root; die when not inside a repository.
#
# The root is made physical in bash's own spelling. Git for Windows prints
# C:/Users/..., while every path bash builds is /c/Users/...; a symlink target
# computed between the two, or a prefix comparison, finds no common part —
# `init --link` produced ../../../../d/a/jig/jig/scripts, dangling, on the
# same drive. git already resolves symlinks on macOS and Linux, so this
# changes nothing there.
#
# Clears the git location variables first, for the callers that reach the
# library without the dispatcher — the test suite sources common.sh and calls
# this directly. The dispatcher has already cleared them by the time a command
# runs, and `unset` twice costs nothing.
jig_require_repo() {
  local top
  jig_clear_git_location_env
  top=$(jig_repo_root) || jig_fail not-a-repository "not inside a git repository"
  JIG_PROJECT=$(cd -P "$top" 2>/dev/null && pwd -P) \
    || jig_die "cannot resolve the repository root: $top"
  export JIG_PROJECT
}

# jig_valid_id <id> — the grammar of a name that becomes a directory under
# .ai/: a task id and a spec id. Both must agree, because a spec's roadmap
# names task ids and a spec id follows task id rules; two copies of the case
# below would be free to drift.
# No leading dot: rules out `.`, `..` and hidden directories, which the `*/`
# walks over workspaces and specs would not see.
# No leading dash: every subcommand reads its id from the first argument, so
# `-x` is a flag in the wrong place, never a name. `jig task new --help` used
# to file a workspace named `--help`.
jig_valid_id() {
  case "$1" in
    '' | .* | -* | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# jig_goal_check <who> <goal> — the goal of a task, which `task new --goal` and
# `spec item file --new --goal` both take. It is the paragraph under `## Goal` that
# `task list --goals` and `task list --json` read back: one line, so that it stays one
# paragraph, and not a heading, so that it stays under `## Goal`. Refuses `usage`;
# leaves the trimmed goal in JIG_GOAL.
JIG_GOAL=""
jig_goal_check() {
  local who="$1" goal="$2"
  case "$goal" in
    *$'\n'* | *$'\r'*) jig_fail usage "$who: --goal is one line: the goal paragraph of task.md" ;;
  esac
  case "$goal" in
    *[![:space:]]*) ;;
    *) jig_fail usage "$who: --goal is empty" ;;
  esac
  # Trimmed: leading blanks would make the paragraph a code block.
  goal=${goal#"${goal%%[![:space:]]*}"}
  goal=${goal%"${goal##*[![:space:]]}"}
  case "$goal" in
    '#'*) jig_fail usage "$who: --goal cannot start with #: it would read as a heading" ;;
  esac
  # shellcheck disable=SC2034 # read by the callers
  JIG_GOAL=$goal
}

# Die unless the project has been initialised with jig init.
# jig_has_line <line> <text> — exit 0 when <line> is a whole line of <text>,
# compared as a string. A `case`, never `printf | grep -qxF`: bash writes a
# pipe line by line, and under pipefail the SIGPIPE a reader that quit early
# leaves printf with turns a match into a failure (conventions/shell.md).
jig_has_line() {
  case $'\n'"$2"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

jig_require_init() {
  jig_require_repo
  [ -f "$JIG_PROJECT/$JIG_AI_DIR/config.yaml" ] \
    || jig_fail not-initialised "project is not initialised; run: jig init"
}

# True when <dir> is a framework source checkout (has skills/ and templates/).
jig_is_source_root() {
  [ -d "$1/skills" ] && [ -d "$1/templates" ] && [ -f "$1/scripts/jig" ]
}

# Best-effort framework source root: the checkout this script runs from, or
# JIG_SOURCE, or empty when running from an installed copy.
jig_source_root() {
  local candidate
  candidate=$(cd "$JIG_LIB/../.." && pwd)
  if jig_is_source_root "$candidate"; then
    printf '%s\n' "$candidate"
  elif [ -n "${JIG_SOURCE:-}" ] && jig_is_source_root "$JIG_SOURCE"; then
    printf '%s\n' "$JIG_SOURCE"
  fi
}

# --- framework versions and the global executable -------------------------
#
# Release tags are the update channel: a release is `v<major>.<minor>.<patch>`,
# digits only, and the newest one is what `install.sh` installs and what
# `jig self-update` moves to. Versions are ordered in shell arithmetic because
# `sort -V` is not available everywhere jig runs (conventions/shell.md).

# jig_release_version <tag> — the `X.Y.Z` of release tag `vX.Y.Z`. Prints
# nothing and fails for anything else: a pre-release suffix, a stray tag, a
# version with more or fewer than three fields.
jig_release_version() {
  local v a b c rest
  case "$1" in
    v*) v="${1#v}" ;;
    *) return 1 ;;
  esac
  case "$v" in
    '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
  esac
  IFS=. read -r a b c rest <<EOF
$v
EOF
  if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ] || [ -n "$rest" ]; then
    return 1
  fi
  printf '%s\n' "$v"
}

# jig_version_newer <a> <b> — true when release version <a> (`X.Y.Z`, or
# `X.Y.Z+<build>`, ordered by its `X.Y.Z`) is
# strictly newer than <b>, comparing each field as a number: 0.10.0 is newer
# than 0.9.0. False for equal versions and for anything that is not three
# numeric fields, so an unparsable version never reads as an upgrade.
jig_version_newer() {
  local a1 a2 a3 b1 b2 b3 a="${1%%+*}" b="${2%%+*}"
  # A `+<build>` part (unreleased code, `X.Y.Z+<sha>`) takes no part in the
  # order, as in semver: it is compared by the release number it was built on
  # (adr-20261106-copy-mode-projects-take-released-code-only).
  jig_release_version "v$a" >/dev/null || return 1
  jig_release_version "v$b" >/dev/null || return 1
  IFS=. read -r a1 a2 a3 <<EOF
$a
EOF
  IFS=. read -r b1 b2 b3 <<EOF
$b
EOF
  # 10#: a field with a leading zero is still decimal, not octal.
  a1=$((10#$a1)); a2=$((10#$a2)); a3=$((10#$a3))
  b1=$((10#$b1)); b2=$((10#$b2)); b3=$((10#$b3))
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
  [ "$a3" -gt "$b3" ]
}

# jig_newest_release — read tag names on stdin, one per line, and print the
# newest release tag (`vX.Y.Z`). Accepts `git tag` names and `git ls-remote
# --tags` lines alike: a `refs/tags/` prefix and the `^{}` of a peeled
# annotated tag are stripped. Fails, printing nothing, when no line is a
# release tag.
jig_newest_release() {
  local line tag v best="" best_v=""
  while IFS= read -r line; do
    tag=${line##*refs/tags/}
    tag=${tag%'^{}'}
    v=$(jig_release_version "$tag") || continue
    if [ -z "$best_v" ] || jig_version_newer "$v" "$best_v"; then
      best="$tag"
      best_v="$v"
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# jig_version_of <executable> — the version a jig executable reports, taken
# only from a single line shaped exactly `jig <version>`. Fails otherwise, so
# a wrapper or an unrelated `jig` on PATH is never mistaken for a version.
jig_version_of() {
  local out
  out=$("$1" version 2>/dev/null) || return 1
  case "$out" in
    *'
'*) return 1 ;;
    'jig '?*) printf '%s\n' "${out#jig }" ;;
    *) return 1 ;;
  esac
}

# jig_declared_version <source> — the version a framework checkout declares in
# scripts/lib/version.sh, read without running anything. Fails unless exactly
# one line is shaped `JIG_VERSION="<version>"` with a value free of quotes and
# spaces. `jig status` uses this rather than jig_version_of: a read-only
# command must not execute whatever PATH selects, and a broken global checkout
# would otherwise hang it, with no portable timeout to bound the wait.
jig_declared_version() {
  local file="$1/scripts/lib/version.sh" found
  [ -f "$file" ] || return 1
  found=$(sed -n 's/^JIG_VERSION="\([^" ]\{1,\}\)"[[:space:]]*$/\1/p' "$file" 2>/dev/null) \
    || return 1
  case "$found" in
    '' | *'
'*) return 1 ;;
  esac
  printf '%s\n' "$found"
}

# --- released and unreleased sources ------------------------------------------
#
# A framework checkout is a released source only when its HEAD carries the
# release tag of the version it declares. Anything else — a branch past the
# tag, a detached commit, a copy without git — is unreleased code, even when it
# declares a released number: `main` keeps the last release's JIG_VERSION until
# the next release raises it. A copy-mode project takes released code only,
# unless asked for unreleased code by name
# (adr-20261106-copy-mode-projects-take-released-code-only).

# _jig_source_git <dir> — true when <dir> is the top of a git checkout of its
# own, not merely inside somebody else's repository (a copy of the framework
# placed inside a project would otherwise answer with the project's tags).
_jig_source_git() {
  local top phys
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  top=$(cd -P "$top" 2>/dev/null && pwd -P) || return 1
  phys=$(cd -P "$1" 2>/dev/null && pwd -P) || return 1
  [ "$top" = "$phys" ]
}

# jig_source_release <dir> — true when framework checkout <dir> stands at the
# release tag of the version it declares (`v<JIG_VERSION>` points at HEAD). A
# branch whose HEAD carries that tag counts: its bytes are the release's.
# Uncommitted changes are not looked at here: this is the cheap question
# `jig status` and `jig --version` ask on every run. Taking files asks
# jig_source_released, which also asks jig_source_clean.
jig_source_release() {
  local declared tags
  declared=$(jig_declared_version "$1") || return 1
  jig_release_version "v$declared" >/dev/null || return 1
  _jig_source_git "$1" || return 1
  # Read whole, then searched: a pipe into an early-quitting reader can die
  # of SIGPIPE under pipefail (conventions/shell.md).
  tags=$(git -C "$1" tag --points-at HEAD 2>/dev/null) || return 1
  jig_has_line "v$declared" "$tags"
}

# jig_source_changes <dir> — the uncommitted changes of checkout <dir>, as
# `git status --porcelain` lists them; fails when git cannot read them.
# --untracked-files=all pins what counts as a change: with
# status.showUntrackedFiles=no in someone's git config, plain --porcelain
# hides untracked files and a dirty checkout would read as clean. Shared with
# self-update, which refuses a checkout with changes for the same reason.
jig_source_changes() {
  git -C "$1" status --porcelain --untracked-files=all 2>/dev/null
}

# jig_source_clean <dir> — true when checkout <dir> has no tracked, staged or
# untracked change. The answer is kept for the process: an upgrade asks it
# for the refusal and again for the version it records, and on Git Bash each
# `git status` is a slow process start.
_JIG_SOURCE_CLEAN_DIR=""
_JIG_SOURCE_CLEAN_RC=""
jig_source_clean() {
  local changes
  if [ -n "$_JIG_SOURCE_CLEAN_DIR" ] && [ "$_JIG_SOURCE_CLEAN_DIR" = "$1" ]; then
    return "$_JIG_SOURCE_CLEAN_RC"
  fi
  _JIG_SOURCE_CLEAN_RC=1
  if changes=$(jig_source_changes "$1") && [ -z "$changes" ]; then
    _JIG_SOURCE_CLEAN_RC=0
  fi
  _JIG_SOURCE_CLEAN_DIR=$1
  return "$_JIG_SOURCE_CLEAN_RC"
}

# jig_source_released <dir> — true when <dir> holds a release's bytes: at its
# release tag (jig_source_release) and with no local change. A checkout at a
# tag with edited or added files is unreleased code under a release's number
# (adr-20261106-copy-mode-projects-take-released-code-only).
jig_source_released() {
  jig_source_release "$1" && jig_source_clean "$1"
}

# jig_source_taken_version <dir> — the version a copy-mode project records
# when it takes files from <dir>: jig_source_version, and `X.Y.Z+<sha>.dirty`
# when the checkout has local changes, at a release tag or past one.
jig_source_taken_version() {
  local v sha
  v=$(jig_source_version "$1") || return 1
  if ! _jig_source_git "$1" || jig_source_clean "$1"; then
    printf '%s\n' "$v"
    return 0
  fi
  case "$v" in
    *+*) printf '%s.dirty\n' "$v" ;;
    *)
      sha=$(git -C "$1" rev-parse --short=7 HEAD 2>/dev/null) || sha=unknown
      printf '%s+%s.dirty\n' "$v" "${sha:-unknown}" ;;
  esac
}

# jig_source_version <dir> — the version of framework checkout <dir> as a
# person should read it: the declared `X.Y.Z` at its release tag, otherwise
# `X.Y.Z+<short sha>`, or `X.Y.Z+unknown` without a git checkout of its own.
jig_source_version() {
  local declared sha
  declared=$(jig_declared_version "$1") || return 1
  if jig_source_release "$1"; then
    printf '%s\n' "$declared"
  elif _jig_source_git "$1" \
       && sha=$(git -C "$1" rev-parse --short=7 HEAD 2>/dev/null) && [ -n "$sha" ]; then
    printf '%s+%s\n' "$declared" "$sha"
  else
    printf '%s+unknown\n' "$declared"
  fi
}

# jig_version_core <version> — <version> without its `+<build>` part: the
# release number an unreleased version was built on.
jig_version_core() {
  printf '%s\n' "${1%%+*}"
}

# jig_source_where <dir> — where an unreleased checkout stands, in words:
# "on branch main at 278958c", "detached at 278958c", "not a git checkout".
jig_source_where() {
  local sha branch
  if ! _jig_source_git "$1"; then
    printf 'not a git checkout\n'
    return 0
  fi
  sha=$(git -C "$1" rev-parse --short=7 HEAD 2>/dev/null) || sha="?"
  if branch=$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null); then
    printf 'on branch %s at %s\n' "$branch" "$sha"
  else
    printf 'detached at %s\n' "$sha"
  fi
}

# jig_require_released_source <command> <source> <unreleased> — refuse, as
# `unreleased-source`, to install a copy-mode project from <source> when it is
# not a release, unless <unreleased> is 1 (`--unreleased`). The message names
# where the checkout stands and the two ways out.
jig_require_released_source() {
  local cmd="$1" source="$2" unreleased="$3" declared back
  [ "$unreleased" != 1 ] || return 0
  if jig_source_release "$source"; then
    jig_source_clean "$source" && return 0
    jig_fail unreleased-source "$cmd: the source is not a release: $source is at its release tag with uncommitted changes ($(jig_source_taken_version "$source" 2>/dev/null || printf '%s' "$(jig_declared_version "$source" 2>/dev/null)")). A copy-mode project takes released code only; see the changes with \`git -C $source status --short\` and commit them elsewhere or stash them (\`git -C $source stash -u\`); or take this code on purpose: jig $cmd --unreleased"
  fi
  declared=$(jig_declared_version "$source" 2>/dev/null) || declared="?"
  if _jig_source_git "$source" \
     && git -C "$source" rev-parse -q --verify "refs/tags/v$declared" >/dev/null 2>&1; then
    back="return it to a release: git -C $source checkout v$declared"
  else
    back="use a released Jig: install.sh without --ref, or check out a release tag (git tag -l 'v*')"
  fi
  jig_fail unreleased-source "$cmd: the source is not a release: $source is $(jig_source_where "$source") ($(jig_source_version "$source" 2>/dev/null || printf '%s' "$declared")). A copy-mode project takes released code only; $back; or take this code on purpose: jig $cmd --unreleased"
}

# jig_global_executable — the physical path of the `jig` the current PATH
# selects, when it is the dispatcher of a framework source checkout. Fails,
# printing nothing, when PATH has no `jig` or it resolves anywhere else.
#
# Symlinks are resolved with the dispatcher's own jig_resolve_path, defined in
# scripts/jig before any library is sourced; it is reused rather than copied
# here, because two resolvers would drift. Directories are then made physical
# (conventions/shell.md), so the path compares equal to JIG_SELF resolved the
# same way — equal means the same checkout, as in link mode.
jig_global_executable() {
  local found path dir
  found=$(command -v jig 2>/dev/null) || return 1
  case "$found" in
    /*) ;;
    *) return 1 ;;
  esac
  path=$(jig_resolve_path "$found") || return 1
  dir=$(cd -P "${path%/*}" 2>/dev/null && pwd -P) || return 1
  path="$dir/${path##*/}"
  case "$path" in
    */scripts/jig) ;;
    *) return 1 ;;
  esac
  jig_is_source_root "${path%/scripts/jig}" || return 1
  printf '%s\n' "$path"
}

# jig_global_source — the global framework: the checkout behind
# jig_global_executable, physical, without the trailing /scripts/jig. Fails,
# printing nothing, when there is none. The one answer to "which Jig is on this
# machine" that `status`, `self-update` and `upgrade` share, and what a
# manifest's `jig.source: global` names on whichever machine reads it
# (adr-20261029-the-manifest-names-the-global-framework-not-its-path).
jig_global_source() {
  local exe
  exe=$(jig_global_executable) || return 1
  printf '%s\n' "${exe%/scripts/jig}"
}

# --- directory links ----------------------------------------------------------

# How this machine links one directory to another: symlink, junction or none.
# Set by jig_link_detect, once per process. Cleared here so that a value in the
# caller's environment is never taken for a measurement.
_JIG_LINK_KIND=""

# jig_link_detect — measure which kind of directory link works here and keep it
# in _JIG_LINK_KIND. Not a `$(...)` helper: the answer must outlive the call.
#
# `ln -s` is never trusted to have made a link. Git Bash on Windows copies by
# default, and a copied task workspace diverges from its first write — two
# `state` files, and housekeeping keeping the worktree forever, because a copy
# is "a workspace of its own" (ADR-0029). Where symlinks are unavailable an
# NTFS junction needs no privilege; bash reads it as a link (`-L`,
# `find -type l`), and `git worktree remove` and `rm -rf` remove the junction
# without touching its target (measured on windows-latest, 2026-09-14).
jig_link_detect() {
  [ -z "$_JIG_LINK_KIND" ] || return 0
  local dir
  _JIG_LINK_KIND=none
  dir=$(mktemp -d "${TMPDIR:-/tmp}/jig-link-probe.XXXXXX") || return 0
  jig_cleanup_add -d "$dir"
  mkdir "$dir/target" || { rm -rf "$dir"; return 0; }
  if ln -s "$dir/target" "$dir/symlink" 2>/dev/null && [ -L "$dir/symlink" ]; then
    _JIG_LINK_KIND=symlink
  elif _jig_junction "$dir/target" "$dir/junction" && [ -L "$dir/junction" ]; then
    _JIG_LINK_KIND=junction
  fi
  rm -rf "$dir"
  return 0
}

# _jig_junction <target-abs> <link-abs> — an NTFS junction made by cmd.exe.
# MSYS rewrites mklink's `/J` into a path unless argument conversion is off,
# and cmd.exe needs both paths in Windows form.
_jig_junction() {
  local target link
  command -v cmd >/dev/null 2>&1 || return 1
  command -v cygpath >/dev/null 2>&1 || return 1
  target=$(cygpath -w "$1") || return 1
  link=$(cygpath -w "$2") || return 1
  MSYS2_ARG_CONV_EXCL='*' cmd /c mklink /J "$link" "$target" >/dev/null 2>&1
}

# jig_link_dir <target-abs> <link-abs> — link <link-abs> to the existing
# directory <target-abs> with the kind jig_link_detect found. Non-zero when no
# kind works, or when what was made does not read as a link.
jig_link_dir() {
  jig_link_detect
  case "$_JIG_LINK_KIND" in
    symlink) ln -s "$1" "$2" 2>/dev/null || return 1 ;;
    junction) _jig_junction "$1" "$2" || return 1 ;;
    *) return 1 ;;
  esac
  [ -L "$2" ]
}

# jig_worktree_leftover <path> — clear what `git worktree remove` leaves behind
# on Windows, once git no longer has the worktree: links, never what they point
# at — `find` does not follow them; `rm -f`, and `rmdir` where that fails — and
# then empty directories, deepest first; `rmdir` cannot
# remove a directory that still holds anything. Non-zero when anything else
# remains, which stays where it is. Measured on windows-latest, 2026-09-14: git
# removed the tracked files of a task worktree and left the directory, with
# `.ai/…` and the junction that borrowed the tasks directory still in it. Never
# `rm -rf`: under Git Bash it can go through a junction into what it borrows.
# Callers: housekeeping, on a task worktree it proved is ours, and the own tree
# (owntree.sh), on the one path `_ot_tree_path` builds.
jig_worktree_leftover() {
  local path="$1" entry
  while IFS= read -r entry; do
    [ -L "$entry" ] || continue
    rm -f "$entry" 2>/dev/null || rmdir "$entry" 2>/dev/null || true
  done < <(find "$path" -type l 2>/dev/null)
  find "$path" -depth -type d -exec rmdir {} \; 2>/dev/null || true
  [ ! -e "$path" ]
}

# How this machine copies a directory fastest: the `cp` flags in
# _JIG_COPY_FLAGS, with a one-word name for reports in _JIG_COPY_KIND. Set by
# jig_copy_detect, once per process. Cleared here so that a value in the
# caller's environment is never taken for a measurement.
_JIG_COPY_FLAGS=""
_JIG_COPY_KIND=""

# jig_copy_detect — measure which copy flags this `cp` understands and keep
# them in _JIG_COPY_FLAGS. Not a `$(...)` helper: the answer must outlive the
# call (mirrors jig_link_detect).
#
# A capability, never a platform (ADR-0037). Two flags ask the filesystem for
# a copy-on-write clone instead of duplicating the bytes: `-c` (clonefile) on
# macOS and the BSDs, `--reflink=auto` on GNU coreutils. Neither can be probed
# by its result — both fall back to a full copy in silence when the filesystem
# cannot clone, which is exactly what makes them safe to pass blindly, and
# what makes "did it clone?" unanswerable. So the probe asks the only question
# that has an answer: does this `cp` accept the flag at all. Git Bash on
# Windows accepts neither and copies honestly.
#
# Measured 2026-09-24 on APFS, a 26,861-file vendor tree: 5.35s and 11MB of
# disk with `-c`, against 12.27s and 210MB without it.
jig_copy_detect() {
  [ -z "$_JIG_COPY_KIND" ] || return 0
  local dir
  _JIG_COPY_FLAGS="-a"
  _JIG_COPY_KIND="copy"
  dir=$(mktemp -d "${TMPDIR:-/tmp}/jig-copy-probe.XXXXXX") || return 0
  jig_cleanup_add -d "$dir"
  if printf 'x\n' > "$dir/probe" 2>/dev/null; then
    if cp -c "$dir/probe" "$dir/clone" >/dev/null 2>&1; then
      _JIG_COPY_FLAGS="-a -c"
      _JIG_COPY_KIND="clone"
    elif cp --reflink=auto "$dir/probe" "$dir/reflink" >/dev/null 2>&1; then
      _JIG_COPY_FLAGS="-a --reflink=auto"
      _JIG_COPY_KIND="clone"
    fi
  fi
  rm -rf "$dir"
  return 0
}

# jig_copy_dir <src-abs> <dst-abs> — copy a file or directory tree with the
# flags jig_copy_detect found, preserving symlinks as symlinks rather than
# following them. Non-zero when the copy failed.
#
# Hard links (`cp -R -l`) were measured and rejected: 11.64s against 12.27s
# for a full copy, and no more disk saved than a clone. A tenth of the time is
# not what a framework takes the risk of an in-place edit reaching the
# neighbouring tree for.
jig_copy_dir() {
  jig_copy_detect
  # Word splitting is the point: the flags are the framework's own, never a
  # caller's data.
  # shellcheck disable=SC2086
  cp $_JIG_COPY_FLAGS "$1" "$2" 2>/dev/null
}

# jig_physical_path <file> — <file> with its directory made physical.
jig_physical_path() {
  local dir
  dir=$(cd -P "${1%/*}" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "${1##*/}"
}

# jig_task_base <task-id> — the branch a task was cut from and has to land on:
# `base_branch` from its state file, or `git.base_branch` when the task never
# recorded one (not started, or started before the field existed). One answer
# for `task`, `housekeeping`, `context`, `knowledge` and `verify`, which must
# never disagree about what a task is judged against (ADR-0039). The state
# file is the task domain's; reading it here is allowed, writing it is not. An
# id that is not a task id gets the configured base, never a path built from it.
jig_task_base() {
  local value
  jig_task_base_v value "${1:-}"
  printf '%s\n' "$value"
}

# jig_task_base_v <var> <task-id> — jig_task_base's answer into <var>, in the
# caller's shell: no process, for a reader that asks it once per task.
jig_task_base_v() {
  local __jtb_value=""
  jig_task_state_var __jtb_value "${2:-}" base_branch
  [ -n "$__jtb_value" ] || cfg_v __jtb_value git.base_branch main
  printf -v "$1" '%s' "$__jtb_value"
}

# --- the task state file, read in the caller's shell --------------------------
#
# One rule reads a task's `state` (schemas/state.md): the first line that
# starts with `<key>:`, its value after the colon with the leading blanks
# dropped. task_state_get (task.sh) is the reader every command asks;
# jig_task_base and _jig_task_state_value read through the same function, so
# the rule is written once, here, below the task library that owns the file.
#
# Builtins only, never a process: a reader ran a command substitution and an
# awk per field, and `task list --json` paid ~28 of each per task.
#
# A snapshot serves the read paths. Between jig_read_snapshot_begin and
# jig_read_snapshot_end (`task list`, `status`), a task's file is read once
# and every later key comes from the shell's own variables — a guard asked in
# a subshell inherits them. Outside it every read goes to the file, so a
# command that writes and then reads never sees an old value; every writer of
# a state file calls jig_task_state_forget as well, so a write inside the
# read path is seen too.
#
# Bash 3.2 has no associative arrays: each task read into the snapshot gets a
# slot number, its values live in `_JIG_TSV_<slot>_<key>` and its key list in
# `_JIG_TSK_<slot>`. Only a key of the form [A-Za-z][A-Za-z0-9_]* becomes a
# variable name; any other line is read by the plain path, never by eval.
_JIG_TS_ON=0
_JIG_TS_GEN=0
_JIG_TS_SLOTS=$'\n'
_JIG_TS_N=0
_JIG_TS_FOUND=0

# jig_read_snapshot_begin / jig_read_snapshot_end — open and close the read
# path's snapshot: task state, the queue's lines and the configuration are
# read once per process in between. Only a command that writes nothing in
# between opens one. A snapshot holds one project: its caches are keyed by task
# id and config key, not by JIG_PROJECT, so nothing on the read path may switch
# JIG_PROJECT while a snapshot is open (as _task_touched_in does for another
# checkout); such a read must run outside it or in a subshell of its own.
jig_read_snapshot_begin() {
  jig_task_state_forget
  _jig_queue_cache_drop
  _cfg_cache_drop
  # A memo kept beside the snapshot (task.sh's design hashes) is valid for
  # one generation: each snapshot opened is a new one.
  _JIG_TS_GEN=$((_JIG_TS_GEN + 1))
  _JIG_TS_ON=1
}
jig_read_snapshot_end() {
  _JIG_TS_ON=0
  jig_task_state_forget
  _jig_queue_cache_drop
  _cfg_cache_drop
}

# jig_task_state_forget — drop every task the snapshot holds. Called by every
# writer of a state file (task.sh), so the next read sees the write.
jig_task_state_forget() {
  local __jts_n=1 __jts_k __jts_keys
  while [ "$__jts_n" -le "$_JIG_TS_N" ]; do
    eval "__jts_keys=\${_JIG_TSK_$__jts_n-}"
    for __jts_k in $__jts_keys; do
      unset "_JIG_TSV_${__jts_n}_$__jts_k"
    done
    unset "_JIG_TSK_$__jts_n"
    __jts_n=$((__jts_n + 1))
  done
  _JIG_TS_SLOTS=$'\n'
  _JIG_TS_N=0
  _JIG_TS_CUR=""
  _JIG_TS_CUR_KEYS=""
  _JIG_TS_SLOT=""
}

# _jig_task_state_trim <var> — <var> without its leading blanks, the part of
# the rule after the colon ([[:space:]], as awk's class).
_jig_task_state_trim() {
  local __jtt_v
  eval "__jtt_v=\$$1"
  printf -v "$1" '%s' "${__jtt_v#"${__jtt_v%%[![:space:]]*}"}"
}

# _jig_task_state_select <id> — make task <id> the snapshot's current one:
# _JIG_TS_CUR, _JIG_TS_SLOT and _JIG_TS_CUR_KEYS, its file read into a new
# slot the first time it is asked for. The first line of a key wins; a
# missing file is a slot with no keys. <id> is a valid id.
_JIG_TS_CUR=""
_JIG_TS_CUR_KEYS=""
_JIG_TS_SLOT=""
_jig_task_state_select() {
  local __jtl_file __jtl_line __jtl_k __jtl_keys=" " __jtl_n __jtl_nl=$'\n' __jtl_t=$'\t'
  case "$_JIG_TS_SLOTS" in
    *"$__jtl_nl$1$__jtl_t"*)
      __jtl_n=${_JIG_TS_SLOTS#*"$__jtl_nl$1$__jtl_t"}
      __jtl_n=${__jtl_n%%"$__jtl_nl"*}
      eval "__jtl_keys=\$_JIG_TSK_$__jtl_n" ;;
    *)
      __jtl_n=$((_JIG_TS_N + 1))
      _JIG_TS_N=$__jtl_n
      __jtl_file="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$1/state"
      if [ -f "$__jtl_file" ]; then
        while IFS= read -r __jtl_line || [ -n "$__jtl_line" ]; do
          case "$__jtl_line" in *:*) ;; *) continue ;; esac
          __jtl_k=${__jtl_line%%:*}
          case "$__jtl_k" in [A-Za-z]*) ;; *) continue ;; esac
          case "$__jtl_k" in *[!A-Za-z0-9_]*) continue ;; esac
          case "$__jtl_keys" in *" $__jtl_k "*) continue ;; esac
          __jtl_line=${__jtl_line#*:}
          printf -v "_JIG_TSV_${__jtl_n}_$__jtl_k" '%s' "${__jtl_line#"${__jtl_line%%[![:space:]]*}"}"
          __jtl_keys="$__jtl_keys$__jtl_k "
        done < "$__jtl_file"
      fi
      printf -v "_JIG_TSK_$__jtl_n" '%s' "$__jtl_keys"
      _JIG_TS_SLOTS="$_JIG_TS_SLOTS$1$__jtl_t$__jtl_n$__jtl_nl" ;;
  esac
  _JIG_TS_CUR=$1
  _JIG_TS_SLOT=$__jtl_n
  _JIG_TS_CUR_KEYS=$__jtl_keys
}

# jig_task_state_var <var> <id> <key> — the value of <key> in task <id>'s
# state file into <var>, empty when the task, the file or the key does not
# exist; _JIG_TS_FOUND is 1 when the key has a line, 0 when it has none. An
# id that is not a task id has no state: no path is built from it. Never
# dies, never starts a process.
jig_task_state_var() {
  local __jtv_file __jtv_line
  _JIG_TS_FOUND=0
  if [ "$_JIG_TS_ON" = 1 ]; then
    if [ -z "$2" ] || [ "$2" != "$_JIG_TS_CUR" ]; then
      jig_valid_id "$2" || { printf -v "$1" '%s' ""; return 0; }
      _jig_task_state_select "$2"
    fi
    case "$_JIG_TS_CUR_KEYS" in
      *" $3 "*)
        # A key in the list is one the select took as a variable name.
        _JIG_TS_FOUND=1
        eval "$1=\$_JIG_TSV_${_JIG_TS_SLOT}_$3"
        return 0 ;;
    esac
    printf -v "$1" '%s' ""
    # A key that could be a variable name and is not in the list has no line;
    # any other is looked for in the file itself, below.
    case "$3" in
      [A-Za-z]*)
        case "$3" in *[!A-Za-z0-9_]*) ;; *) return 0 ;; esac ;;
    esac
  else
    printf -v "$1" '%s' ""
    jig_valid_id "$2" || return 0
  fi
  __jtv_file="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$2/state"
  [ -f "$__jtv_file" ] || return 0
  while IFS= read -r __jtv_line || [ -n "$__jtv_line" ]; do
    case "$__jtv_line" in
      "$3:"*)
        __jtv_line=${__jtv_line#"$3:"}
        _jig_task_state_trim __jtv_line
        _JIG_TS_FOUND=1
        printf -v "$1" '%s' "$__jtv_line"
        return 0 ;;
    esac
  done < "$__jtv_file"
  return 0
}

# jig_base_ref <name> — the ref a base branch is judged by:
# refs/remotes/origin/<name> when it exists, else refs/heads/<name>, else
# nothing. Origin first because landed means landed on the remote: a local
# base can be behind it (a teammate who never fetched the branch) or ahead of
# it (commits nobody pushed), and a bare name lets git pick the local one.
jig_base_ref() {
  local name="${1:-}"
  [ -n "$name" ] || return 0
  if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$name^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "refs/remotes/origin/$name"
  elif git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$name^{commit}" >/dev/null 2>&1; then
    printf '%s\n' "refs/heads/$name"
  fi
  return 0
}

# jig_staging_states <staging-branch> <rows> — "<id><TAB>on|behind" for each
# task of <rows> ("<id><TAB><branch><TAB><base>" lines) whose own work reached
# origin's <staging-branch>; nothing for any other task. Derived from git by
# branch name on every call and stored nowhere (ADR-0005), so a colleague, a CI
# runner and the owner read the same answer from the same refs.
#
# A task's own commits are those its branch reaches and its base does not (the
# base resolved as jig_base_ref does, origin first). A merge commit whose every
# parent but the first is in the base or the staging branch brings those in and
# is not the task's own work, so a task does not read "behind" the moment its
# base is merged into it at promotion (adr-20261111-prepare-for-prod-opens-the-promotion-from-git-alone), and staging merged into a task branch ("Update branch" on a pull request
# into staging) neither makes the task behind nor puts it on staging: staging
# is reached only along the task's own commits. The tip is the
# local branch, else origin's, as housekeeping resolves it: commits the owner
# has not pushed are commits after staging too.
#   on      some own commit is in origin/<staging-branch>, and every own commit
#           not in it is a merge of the base
#   behind  some own commit is in origin/<staging-branch>, and another own
#           commit is not
# Nothing when no own commit is there: the task never reached staging, has no
# branch or no work of its own, or its base or origin's staging branch is not
# here. A squash merge into staging leaves the branch's commits out of it, so
# such a task reads as not on staging (docs/known-issues.mdx).
#
# The processes it starts do not grow with the tasks (conventions/shell.md):
# one for-each-ref, and per distinct base one rev-list of every tip's own
# commits with their parents and one of staging's commits the base lacks; the
# graph is walked in awk (_jig_staging_walk).
jig_staging_states() {
  local staging="$1" rows="$2" stip
  [ -n "$staging" ] && [ -n "$rows" ] || return 0
  stip=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$staging^{commit}" 2>/dev/null) || return 0
  [ -n "$stip" ] || return 0
  _jig_staging_walk "$stip" "$rows" | awk -F '\t' '$1 == "state" { print $2 "\t" $3 }'
}

# jig_parked_states <staging-branch> <staging-land> <rows> <cache> [<states>]
# — "<id><TAB>review|signal" for each task of <rows> that waits at the staging branch: it
# is parked. Nothing for any other task. <rows> are "<id><TAB><branch><TAB>
# <base><TAB><pr-url><TAB><promote-url>[<TAB><park-resumed-at>]" lines, `-`
# for a value the caller does not know or have; a row whose
# <park-resumed-at> is set is a task a person took back for a fix, and is not
# parked whatever git and the forge say; <cache> is the forge cache's lines (forgecache_read), passed in so
# this file needs no forge cache of its own; <states>, when given, is
# jig_staging_states' answer for the same rows, already asked by the caller.
# Derived on every call from git
# (jig_staging_states) and the forge cache, written nowhere
# (adr-20261112-a-task-waiting-at-staging-is-parked-and-resuming-it-is-its-status):
#   1. a pull request from the branch into its base that is open or merged —
#      the newest the cache has, or the one <promote-url> names, which counts
#      as open until the cache has it — ends parking: the task left the
#      staging side of the flow;
#   2. its own work on origin's staging branch (`on`) is `signal`: it waits for
#      "prepare for prod";
#   3. an open pull request into the staging branch is `review`: the one
#      <pr-url> names when it goes there (open until the cache has it, and only
#      when <staging-land> is `pr`), else the newest the cache has;
#   4. anything else — work after staging with no pull request open, nothing
#      on staging — is not parked.
# The links are the owner's (task state); a caller without a workspace passes
# `-` and reads the cache alone. Status, `agent.git` and an autopilot run are
# never asked here: they are the owner's, laid over this answer by the caller.
# One jig_staging_states call and two awk passes, whatever the number of rows.
jig_parked_states() {
  local staging="$1" land="$2" rows="$3" cache="$4" states
  [ -n "$staging" ] && [ -n "$rows" ] || return 0
  if [ $# -ge 5 ]; then
    states=$5
  else
    states=$(jig_staging_states "$staging" "$(printf '%s\n' "$rows" | cut -f1-3)")
  fi
  {
    printf '%s\n' "$rows" | awk -F '\t' 'NF >= 3 && $1 != "" { print "Q\t" $0 }'
    [ -z "$states" ] || printf '%s\n' "$states" | awk '{ print "S\t" $0 }'
    [ -z "$cache" ] || printf '%s\n' "$cache" | awk '{ print "P\t" $0 }'
  } | awk -F '\t' -v st="$staging" -v land="$land" '
    $1 == "S" { on[$2] = ($3 == "on"); next }
    $1 == "P" {
      # <head> <base> <state> <ci> <fetched_at> <head-commit> <url> [<mergeable>],
      # newest first (lib/forgecache.sh); a line may end before <url>.
      key = $2 SUBSEP $3
      if (!(key in first)) first[key] = $4
      if ($8 != "" && $8 != "-" && !($8 in byurl)) { byurl[$8] = $4; urlbase[$8] = $3 }
      next
    }
    $1 == "Q" { n++; id[n] = $2; br[n] = $3; bs[n] = $4; pr[n] = $5; pm[n] = $6; rs[n] = $7; next }
    END {
      for (i = 1; i <= n; i++) {
        if (rs[i] != "" && rs[i] != "-") continue
        s = first[br[i] SUBSEP bs[i]]
        if (s == "open" || s == "merged") continue
        p = pm[i]
        if (p != "" && p != "-") {
          if (!(p in byurl)) continue
          if (byurl[p] == "open" || byurl[p] == "merged") continue
        }
        if (on[id[i]]) { print id[i] "\tsignal"; continue }
        u = pr[i]; s = ""
        if (u != "" && u != "-" && (!(u in byurl) || urlbase[u] == st)) {
          if (u in byurl) s = byurl[u]
          else if (land == "pr") s = "open"
        } else {
          s = first[br[i] SUBSEP st]
        }
        if (s == "open") print id[i] "\treview"
      }
    }'
}

# _jig_staging_walk <staging-sha> <rows> — jig_staging_states' walk, judged
# against the commit <staging-sha> rather than origin's staging branch: what
# "prepare for prod" asks of the tested staging commit
# (adr-20261111-prepare-for-prod-opens-the-promotion-from-git-alone). <rows>
# are "<id><TAB><branch><TAB><base>[<TAB><tip-sha>]" lines; a fourth field
# names the tip to judge instead of the local branch, else origin's. Prints,
# tagged by their first field:
#   state<TAB><id><TAB>on|behind   as jig_staging_states describes it
#   own<TAB><id><TAB><sha>         an own commit of the task <staging-sha> does
#                                  not have (what makes it behind, or what is
#                                  not on staging at all)
#   carry<TAB><id><TAB><sha>       a merge on the task's branch that brings in
#                                  commits of <staging-sha> the base does not
#                                  have: staging merged into the task branch
#   reach<TAB><id><TAB><sha>       a commit of <staging-sha> the walk of the
#                                  task's own work stopped at: where its work
#                                  is on staging (jig_staging_drift dates it)
# `own`, `carry` and `reach` lines are printed whether the task's work reached
# <staging-sha> or not.
_jig_staging_walk() {
  local stip="$1" rows="$2" t=$'\t' resolved line base bsha tips
  local -a bases=()
  [ -n "$stip" ] && [ -n "$rows" ] || return 0
  # Each task's tip and base from one listing of the refs: "T<TAB>id<TAB>tip
  # <TAB>base<TAB>base-sha" lines.
  resolved=$({
    git -C "$JIG_PROJECT" for-each-ref --format='R%09%(refname)%09%(objectname)' \
      refs/heads refs/remotes/origin 2>/dev/null || true
    printf '%s\n' "$rows" | awk -F '\t' 'NF >= 3 && $1 != "" && $2 != "" && $3 != "" { print "Q\t" $0 }'
  } | awk -F '\t' '
    function tip(name) {
      if (("refs/heads/" name) in ref) return ref["refs/heads/" name]
      if (("refs/remotes/origin/" name) in ref) return ref["refs/remotes/origin/" name]
      return ""
    }
    function base(name) {
      if (("refs/remotes/origin/" name) in ref) return ref["refs/remotes/origin/" name]
      if (("refs/heads/" name) in ref) return ref["refs/heads/" name]
      return ""
    }
    $1 == "R" { ref[$2] = $3; next }
    $1 == "Q" { n++; id[n] = $2; br[n] = $3; bs[n] = $4; et[n] = $5; next }
    END {
      for (i = 1; i <= n; i++) {
        tp = (et[i] != "") ? et[i] : tip(br[i]); b = base(bs[i])
        if (tp != "" && b != "") print "T\t" id[i] "\t" tp "\t" bs[i] "\t" b
      }
    }') || return 0
  # The distinct bases, each with its sha.
  while IFS="$t" read -r line _ _ base bsha; do
    [ "$line" = T ] || continue
    case " ${bases[*]-} " in *" $base:$bsha "*) ;; *) bases+=("$base:$bsha") ;; esac
  done <<EOF
$resolved
EOF
  [ ${#bases[@]} -gt 0 ] || return 0
  {
    printf '%s\n' "$resolved"
    for line in "${bases[@]}"; do
      base=${line%:*}
      bsha=${line##*:}
      tips=$(printf '%s\n' "$resolved" | awk -F '\t' -v b="$base" '$1 == "T" && $4 == b { print $3 }')
      # shellcheck disable=SC2086 # one argument per tip, each a hexadecimal sha
      git -C "$JIG_PROJECT" rev-list --parents $tips "^$bsha" 2>/dev/null \
        | awk -v b="$base" '{ print "C\t" b "\t" $0 }' || true
      git -C "$JIG_PROJECT" rev-list "$stip" "^$bsha" 2>/dev/null \
        | awk -v b="$base" '{ print "N\t" b "\t" $0 }' || true
    done
  } | awk -F '\t' '
    $1 == "T" { n++; id[n] = $2; tp[n] = $3; bs[n] = $4; next }
    $1 == "C" {
      k = split($3, a, " ")
      key = $2 SUBSEP a[1]
      own[key] = 1
      np[key] = k - 1
      for (j = 2; j <= k; j++) par[key, j - 1] = a[j]
      next
    }
    $1 == "N" { on[$2 SUBSEP $3] = 1; next }
    END {
      for (i = 1; i <= n; i++) {
        b = bs[i]
        # A tip the base already has: no work of its own to be anywhere.
        if (!((b SUBSEP tp[i]) in own)) continue
        split("", seen)
        sp = 0; stack[++sp] = tp[i]; reached = 0; behind = 0
        while (sp > 0) {
          c = stack[sp--]
          if (c in seen) continue
          seen[c] = 1
          key = b SUBSEP c
          # On staging, and so is everything it reaches.
          if (key in on) { reached = 1; print "reach\t" id[i] "\t" c; continue }
          # Own work unless it is a merge that only brings the base or the
          # staging branch in (GitHub'"'"'s "Update branch" on a pull request into
          # staging). Such a parent is not followed either: staging reached
          # only through it is not the task'"'"'s own work on staging.
          mine = (np[key] <= 1)
          for (j = 2; j <= np[key]; j++) {
            p = b SUBSEP par[key, j]
            if ((p in own) && !(p in on)) mine = 1
          }
          if (mine) { behind = 1; print "own\t" id[i] "\t" c }
          for (j = 1; j <= np[key]; j++) {
            p = par[key, j]
            if (!((b SUBSEP p) in own) || (p in seen)) continue
            if (j > 1 && ((b SUBSEP p) in on)) continue
            stack[++sp] = p
          }
        }
        if (reached) print "state\t" id[i] "\t" (behind ? "behind" : "on")
        # Staging merged into the task branch: a merge on its first-parent
        # line that brings in commits of the staging commit the base lacks,
        # whether or not that merge itself later reached staging.
        c = tp[i]
        while ((b SUBSEP c) in own) {
          key = b SUBSEP c
          for (j = 2; j <= np[key]; j++) {
            p = b SUBSEP par[key, j]
            if ((p in own) && (p in on)) { print "carry\t" id[i] "\t" c; break }
          }
          if (np[key] < 1) break
          c = par[key, 1]
        }
      }
    }'
}

# jig_staging_drift <staging-branch> <stale-after> <rows> <cache> — the staging
# drift report (adr-20261112-the-staging-drift-report-is-read-from-git-by-branch-name), as tagged lines for
# `jig status` and housekeeping to word (jig_staging_drift_lines).
# <stale-after> is `git.staging_stale_after` as jig_staging_stale_after reads
# it, empty when it is not a duration; <rows> this checkout's live tasks,
# "<id><TAB><branch><TAB><base><TAB><promote_url>"; <cache> the forge cache's
# lines (forgecache_read), empty when there is none. Prints, in this order:
#   invalid<TAB><value>
#       git.staging_stale_after is not a duration: no task is named unpromoted.
#   unpromoted<TAB><id><TAB><branch><TAB><base><TAB><days><TAB><here>
#       the task's work is on origin's staging branch (jig_staging_states: on
#       or behind) and has been for <stale-after> or longer, with no promotion:
#       the cache's newest pull request from <branch> into <base> is neither
#       open nor merged (a promotion merged by a squash leaves the task's own
#       commits outside the base, and it waits for no promotion), or, where the
#       cache knows none, this checkout records no promote_url for it. <here>
#       is `here` for a task of this checkout, empty for one known only by its
#       branch (a colleague's, promoted from any checkout or by its owner). The time counted from is that of the commit on
#       staging's first-parent line that last brought the task's work in — its
#       landing merge, or the commit itself when staging was fast-forwarded.
#   conflicting<TAB><id><TAB><branch><TAB><base><TAB><fetched_at><TAB><url>
#       a promotion this checkout opened (promote_url) that the forge cache
#       has open and conflicting with <base>, as of <fetched_at>.
#   unowned<TAB><count><TAB><command>
#       <count> commits, merges left out, are on origin's staging branch and
#       not in the base (git.base_branch, origin first), and no live task
#       branch — here or on origin — holds them; <command> lists exactly
#       those: the count is that command's.
# Read from git by branch name: the tasks are every branch
# `git.branch_template` names, here or on origin, and this checkout's own; a
# branch no workspace knows is judged against git.base_branch. The workspace
# adds a base and promote_url, never more: a report of this checkout's tasks
# alone would read a colleague's work as orphaned. Only what the staging
# branch has and the base does not is counted, so a promoted task whose branch
# was deleted after it landed is nobody's drift (the same ADR).
#
# The processes it starts do not grow with the tasks or the commits
# (conventions/shell.md): one for-each-ref, _jig_staging_walk's, one rev-list
# of staging's own commits with their parents and times, one of those no task
# branch holds, and one `date`.
jig_staging_drift() {
  local staging="$1" stale="$2" rows="$3" cache="$4" t=$'\t'
  local stip dbase base_ref bsha template prefix="" suffix="" kind a b c d e
  local all="" rows3="" stale_s=-1 now walk landing shown shown_cmd
  local -a excl=()
  stip=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$staging^{commit}" 2>/dev/null) || return 0
  [ -n "$stip" ] || return 0
  cfg_v dbase git.base_branch main
  base_ref=$(jig_base_ref "$dbase")
  [ -n "$base_ref" ] || return 0
  bsha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$base_ref^{commit}" 2>/dev/null) || return 0
  if [ -n "$stale" ]; then
    stale_s=$(jig_duration_seconds "$stale")
  else
    printf 'invalid\t%s\n' "$(cfg git.staging_stale_after 14d)"
  fi
  template=$(cfg git.branch_template "task/{id}")
  case "$template" in
    *'{id}'*)
      prefix=${template%%'{id}'*}
      suffix=${template#*'{id}'}
      ;;
  esac
  # The task branches, from one listing of the refs: `X<TAB><ref>` for a
  # branch of this checkout's tasks the template does not name, and
  # `R<TAB><id><TAB><branch><TAB><base><TAB><here|-><TAB><promote_url>` for
  # each task, this checkout's first (the possibly empty field last: read
  # splits on a run of tabs as on one). A template with nothing before `{id}`
  # names no branch by itself (jig_branch_is_jigs): then only this checkout's
  # tasks are known.
  if [ -n "$prefix" ]; then
    excl+=("--branches=$prefix*$suffix" "--remotes=origin/$prefix*$suffix")
  fi
  while IFS="$t" read -r kind a b c d e; do
    case "$kind" in
      X) excl+=("$a") ;;
      R)
        [ "$d" = here ] || d=""
        all="$all$a$t$b$t$c$t$e$t$d
"
        rows3="$rows3$a$t$b$t$c
" ;;
    esac
  done < <(_jig_staging_drift_refs "$rows" "$prefix" "$suffix" "$staging" "$dbase")
  now=$(date +%s)
  walk=$(_jig_staging_walk "$stip" "$rows3")
  landing=$(git -C "$JIG_PROJECT" rev-list --parents --timestamp "$stip" "^$bsha" 2>/dev/null) || landing=""
  {
    printf '%s\n' "$all" | awk -F '\t' 'NF >= 3 && $1 != "" { print "R\t" $0 }'
    printf '%s\n' "$walk" | awk -F '\t' '$1 == "state" || $1 == "reach" { print "W\t" $0 }'
    printf '%s\n' "$landing" | awk '$0 != "" { print "L\t" $0 }'
    printf '%s\n' "$cache" | awk -F '\t' 'NF >= 3 && $1 != "" { print "C\t" $0 }'
  } | awk -F '\t' -v stip="$stip" -v now="$now" -v stale="$stale_s" '
    $1 == "R" { n++; id[n] = $2; br[n] = $3; bs[n] = $4; pu[n] = $5; hr[n] = $6; next }
    $1 == "W" && $2 == "state" { st[$3] = $4; next }
    $1 == "W" && $2 == "reach" { reach[$3] = reach[$3] " " $4; next }
    $1 == "L" {
      k = split($2, f, " ")
      ts[f[2]] = f[1]; np[f[2]] = k - 2
      for (j = 3; j <= k; j++) par[f[2], j - 2] = f[j]
      next
    }
    $1 == "C" {
      key = $2 SUBSEP $3
      if (key in cst) next
      cst[key] = $4; cat[key] = $6; cmg[key] = $9
      next
    }
    END {
      # Staging'"'"'s first-parent line, oldest first: each commit lands itself
      # and whatever of staging its other parents bring in that nothing
      # earlier on the line did.
      m = 0; c = stip
      while (c in ts) { fp[++m] = c; if (np[c] < 1) break; c = par[c, 1] }
      for (k = m; k >= 1; k--) {
        f0 = fp[k]; land[f0] = ts[f0]; sp = 0
        for (j = 2; j <= np[f0]; j++) stack[++sp] = par[f0, j]
        while (sp > 0) {
          c = stack[sp--]
          if (!(c in ts) || (c in land)) continue
          land[c] = ts[f0]
          for (j = 1; j <= np[c]; j++) stack[++sp] = par[c, j]
        }
      }
      for (i = 1; i <= n; i++) {
        key = br[i] SUBSEP bs[i]
        # A merged promotion waits for none: by a squash, its commits stay
        # on staging outside the base until the task is closed.
        if (key in cst) prom = (cst[key] == "open" || cst[key] == "merged"); else prom = (pu[i] != "")
        if (stale >= 0 && (id[i] in st)) {
          last = 0
          k = split(reach[id[i]], r, " ")
          for (j = 1; j <= k; j++) if ((r[j] in land) && land[r[j]] > last) last = land[r[j]]
          if (last > 0 && now - last >= stale && !prom)
            print "unpromoted\t" id[i] "\t" br[i] "\t" bs[i] "\t" int((now - last) / 86400) "\t" hr[i]
        }
      }
      for (i = 1; i <= n; i++) {
        key = br[i] SUBSEP bs[i]
        if (pu[i] != "" && (key in cst) && cst[key] == "open" && cmg[key] == "conflicting")
          print "conflicting\t" id[i] "\t" br[i] "\t" bs[i] "\t" cat[key] "\t" pu[i]
      }
    }'
  # Staging's own commits no live task branch holds: one rev-list, with the
  # same exclusions as the `git log` printed for them, so the two agree — the
  # template's branches by glob (git's `*` crosses `/`, as the template match
  # in _jig_staging_drift_refs does), and this checkout's other branches by ref.
  shown=$(git -C "$JIG_PROJECT" rev-list --count --no-merges "$stip" "^$bsha" --not ${excl[@]+"${excl[@]}"} 2>/dev/null) || shown=0
  if [ "${shown:-0}" -gt 0 ]; then
    case "$base_ref" in
      refs/remotes/*) b=${base_ref#refs/remotes/} ;;
      *) b=${base_ref#refs/heads/} ;;
    esac
    shown_cmd="git log --no-merges origin/$staging ^$b"
    if [ ${#excl[@]} -gt 0 ]; then
      shown_cmd="$shown_cmd --not"
      for a in "${excl[@]}"; do
        case "$a" in
          --*=*) shown_cmd="$shown_cmd ${a%%=*}='${a#*=}'" ;;
          *) shown_cmd="$shown_cmd $a" ;;
        esac
      done
    fi
    printf 'unowned\t%s\t%s\n' "$shown" "$shown_cmd"
  fi
}

# _jig_staging_drift_refs <rows> <prefix> <suffix> <staging> <base> —
# jig_staging_drift's listing of the task branches, from one for-each-ref.
_jig_staging_drift_refs() {
  {
    git -C "$JIG_PROJECT" for-each-ref --format='F%09%(refname)%09%(objectname)' \
      refs/heads refs/remotes/origin 2>/dev/null || true
    printf '%s\n' "$1" | awk -F '\t' 'NF >= 3 && $1 != "" && $2 != "" { print "Q\t" $0 }'
  } | awk -F '\t' -v pre="$2" -v suf="$3" -v st="$4" -v base="$5" '
    $1 == "Q" {
      own[$3] = 1; seen[$2] = 1
      print "R\t" $2 "\t" $3 "\t" ($4 == "" ? base : $4) "\there\t" $5
      next
    }
    $1 == "F" { ref[++n] = $2; sha[n] = $3; next }
    END {
      for (i = 1; i <= n; i++) {
        name = ref[i]
        if (index(name, "refs/heads/") == 1) name = substr(name, 12)
        else if (index(name, "refs/remotes/origin/") == 1) name = substr(name, 21)
        else continue
        if (name == st || name == base || name == "HEAD") continue
        id = ""; tmpl = 0
        if (pre != "" && index(name, pre) == 1 && length(name) > length(pre) + length(suf) \
            && (suf == "" || substr(name, length(name) - length(suf) + 1) == suf)) {
          tmpl = 1
          id = substr(name, length(pre) + 1, length(name) - length(pre) - length(suf))
          if (id !~ /^[A-Za-z0-9_][A-Za-z0-9._-]*$/) id = ""
        }
        # A branch the template does not name is excluded by its ref; the
        # caller excludes those the template names by glob.
        if (!tmpl && (name in own)) print "X\t" ref[i]
        if (id != "" && !(id in seen)) { seen[id] = 1; print "R\t" id "\t" name "\t" base "\t-\t" }
      }
    }'
}

# jig_staging_drift_lines <staging-branch> <records> — jig_staging_drift's
# records in words, one `staging: ` line each: what `jig status` and
# housekeeping print.
jig_staging_drift_lines() {
  local staging="$1" kind a b c d e t=$'\t'
  while IFS="$t" read -r kind a b c d e; do
    case "$kind" in
      invalid)
        printf "staging: git.staging_stale_after: '%s' is not a duration (e.g. 14d); tasks waiting on %s are not named\n" "$a" "$staging" ;;
      unpromoted)
        if [ "$e" = here ]; then
          printf 'staging: %s has waited on %s %s day(s) with no promotion (jig task promote %s)\n' "$a" "$staging" "$d" "$a"
        else
          printf 'staging: %s has waited on %s %s day(s) with no promotion (jig task promote %s, from any checkout, or ask its owner)\n' "$a" "$staging" "$d" "$a"
        fi ;;
      unowned)
        printf 'staging: %s commit(s) on %s that no live task branch holds (%s)\n' "$a" "$staging" "$b" ;;
      conflicting)
        printf 'staging: the promotion of %s conflicts with %s as of %s (run jig task promote %s again)\n' "$a" "$c" "$d" "$a" ;;
    esac
  done <<EOF
$2
EOF
}

# jig_staging_branch_problems <branch> <tip> <base> <staging> [<depth>] [<via>] —
# whether the line of <branch> up to <tip> is a clean task branch in the
# staging flow: cut from <base>, with nothing of <staging> merged into it. A
# task branch reaches the base from its own commits, never through the
# staging branch (adr-20261111-a-task-lands-on-staging-through-its-pull-request;
# decided by the person, 2026-11-11). Prints tagged lines, nothing when the line is clean:
#   bad<TAB><text>          what makes it unclean, in words for a person:
#                           `<branch> is cut from <staging> (<sha>)`, `<branch>
#                           is cut from <name>` (a dependency only), `a merge of
#                           <name> into <branch> (<sha>)`, and for a merged task
#                           branch that is unclean its own lines, then `a merge
#                           of <dep> into <branch> (<sha>), which carries the above`
#   dep<TAB><dep-branch><TAB><merge-sha>
#                           a clean branch of another task merged into the line,
#                           at any depth, or (at <depth> 1 and more) one a merged
#                           dependency was cut from: its commits reach the base
#                           with it. <via> is the merge that brought the
#                           dependency in, named for a branch it was cut from
# The judgement walks the first-parent line of <tip> down to the base
# (origin's, jig_base_ref):
#   - cut from staging: a commit of that line is on the first-parent line of
#     origin/<staging>. Jig lands a task on staging by a merge commit, so a
#     task's own commits are second parents there, never on that line, while
#     a branch cut from staging carries staging's landing merges on its own.
#   - cut from another branch (at <depth> 1 and more, a merged dependency): the
#     line holds the tip of an origin branch that is neither a task branch
#     (git.branch_template), the base nor staging. It misses a branch whose
#     tip moved on after the cut or that origin no longer has.
#   - cut from another task's branch (at every depth, the task's own line
#     included): the line holds the tip of that branch, local or origin's. It
#     is named as a dependency and judged the same way. Like the case above,
#     it misses a branch whose tip moved on after the cut, or that neither
#     this clone nor origin has any more: that task's work then reaches the
#     base under this task's name.
#   - each merge on the line: a parent the base has is the base merged in; a
#     parent on staging's first-parent line is staging merged in; a parent on
#     the first-parent line of another task branch is that task's branch,
#     judged the same way, down to <depth> 5; anything else is named by git
#     name-rev and refused.
# Whether the commits of the line are in a tested commit is not asked here:
# _jig_staging_walk answers that. The processes it starts grow with the
# merges on the line and the refs that contain them, one rev-list per ref,
# never per commit (conventions/shell.md).
jig_staging_branch_problems() {
  local branch="$1" tip="$2" base="$3" staging="$4" depth="${5:-0}" via="${6:-}"
  local t=$'\t' base_ref base_sha s_sha fp sfp="" found line c p short name ref dep dep_name
  local template prefix suffix sub one others=""
  base_ref=$(jig_base_ref "$base")
  [ -n "$base_ref" ] && [ -n "$tip" ] || return 0
  base_sha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$base_ref^{commit}" 2>/dev/null) || return 0
  s_sha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$staging^{commit}" 2>/dev/null) || s_sha=""
  fp=$(git -C "$JIG_PROJECT" rev-list --first-parent --parents "$tip" "^$base_sha" 2>/dev/null) || fp=""
  [ -n "$fp" ] || return 0
  [ -z "$s_sha" ] || sfp=$(git -C "$JIG_PROJECT" rev-list --first-parent "$s_sha" "^$base_sha" 2>/dev/null) || sfp=""
  template=$(cfg git.branch_template "task/{id}")
  case "$template" in *'{id}'*) ;; *) template="task/{id}" ;; esac
  prefix=${template%%'{id}'*}
  suffix=${template#*'{id}'}
  # The tips of origin's other branches, for a dependency cut from one.
  if [ "$depth" -gt 0 ]; then
    while IFS="$t" read -r name one; do
      case "$name" in HEAD | "$base" | "$staging" | "$prefix"*"$suffix") continue ;; esac
      others="${others}R$t$name$t$one"$'\n'
    done < <(git -C "$JIG_PROJECT" for-each-ref --format="%(refname:strip=3)$t%(objectname)" refs/remotes/origin 2>/dev/null)
  fi
  # The tips of other tasks' branches, at every depth: a branch cut from
  # another task's branch, the task's own included, carries that task's work.
  while IFS="$t" read -r name one; do
    case "$name" in
      refs/heads/*) name=${name#refs/heads/} ;;
      refs/remotes/origin/*) name=${name#refs/remotes/origin/} ;;
      *) continue ;;
    esac
    [ "$name" != "$branch" ] || continue
    case "$name" in "$prefix"*"$suffix") ;; *) continue ;; esac
    [ "$one" != "$tip" ] || continue
    others="${others}T$t$name$t$one"$'\n'
  done < <(git -C "$JIG_PROJECT" for-each-ref --format="%(refname)$t%(objectname)" refs/heads refs/remotes/origin 2>/dev/null)
  # Cut from staging, or from another branch: one pass over the line.
  found=$({
    [ -z "$sfp" ] || printf '%s\n' "$sfp" | awk '{ print "S\t" $1 }'
    [ -z "$others" ] || printf '%s' "$others"
    printf '%s\n' "$fp" | awk '{ print "F\t" $1 }'
  } | awk -F '\t' '
    $1 == "S" { s[$2] = 1; next }
    $1 == "R" { r[$3] = $2; next }
    $1 == "T" { if (!($3 in tk)) tk[$3] = $2; next }
    $1 == "F" {
      if (!st && ($2 in s)) { st = 1; print "staging\t" $2 }
      if (($2 in r) && !(r[$2] in seen)) { seen[r[$2]] = 1; print "other\t" r[$2] }
      if (($2 in tk) && !(tk[$2] in seen)) { seen[tk[$2]] = 1; print "task\t" tk[$2] "\t" $2 }
    }')
  while IFS="$t" read -r one c p; do
    case "$one" in
      staging) printf 'bad\t%s is cut from %s (%s)\n' "$branch" "$staging" "$(git -C "$JIG_PROJECT" rev-parse --short "$c")" ;;
      other) printf 'bad\t%s is cut from %s\n' "$branch" "$c" ;;
      task)
        # Cut from another task's branch: that task reaches the base too.
        if [ "$depth" -ge 5 ]; then
          printf 'bad\t%s is cut from %s, whose own line goes deeper than can be judged\n' "$branch" "$c"
          continue
        fi
        sub=$(jig_staging_branch_problems "$c" "$p" "$base" "$staging" $((depth + 1)) "${via:-$p}")
        case $'\n'"$sub" in
          *$'\n'"bad$t"*)
            printf '%s\n' "$sub" | awk -F '\t' '$1 == "bad"'
            printf 'bad\t%s is cut from %s, which carries the above\n' "$branch" "$c"
            ;;
          *)
            [ -z "$sub" ] || printf '%s\n' "$sub"
            printf 'dep\t%s\t%s\n' "$c" "${via:-$p}"
            ;;
        esac
        ;;
    esac
  done <<EOF
$found
EOF
  # Each merge on the line, by what it brought in.
  while IFS= read -r line; do
    set -f
    # shellcheck disable=SC2086 # the commit and its parents, hexadecimal
    set -- $line
    set +f
    [ $# -gt 2 ] || continue
    c=$1
    short=$(git -C "$JIG_PROJECT" rev-parse --short "$c")
    shift 2
    for p in "$@"; do
      if git -C "$JIG_PROJECT" merge-base --is-ancestor "$p" "$base_sha" 2>/dev/null; then continue; fi
      if [ -n "$sfp" ] && jig_has_line "$p" "$sfp"; then
        printf 'bad\ta merge of %s into %s (%s)\n' "$staging" "$branch" "$short"
        continue
      fi
      dep=""
      while IFS= read -r ref; do
        case "$ref" in
          refs/heads/*) dep_name=${ref#refs/heads/} ;;
          refs/remotes/origin/*) dep_name=${ref#refs/remotes/origin/} ;;
          *) continue ;;
        esac
        [ "$dep_name" != "$branch" ] || continue
        case "$dep_name" in "$prefix"*"$suffix") ;; *) continue ;; esac
        one=${dep_name#"$prefix"}
        jig_valid_id "${one%"$suffix"}" || continue
        # Merged as that task's branch: on its own first-parent line, not
        # only reachable through something it merged later.
        jig_has_line "$p" "$(git -C "$JIG_PROJECT" rev-list --first-parent "$ref" "^$base_sha" 2>/dev/null)" || continue
        dep=$dep_name
        break
      done < <(git -C "$JIG_PROJECT" for-each-ref --contains "$p" --format='%(refname)' refs/heads refs/remotes/origin 2>/dev/null)
      if [ -z "$dep" ]; then
        name=$(git -C "$JIG_PROJECT" name-rev --name-only --no-undefined \
          --exclude="refs/heads/$branch" --exclude="refs/remotes/origin/$branch" --exclude='refs/tags/*' "$p" 2>/dev/null) || name=$p
        name=${name#remotes/origin/}
        name=${name%%[~^]*}
        printf 'bad\ta merge of %s into %s (%s)\n' "$name" "$branch" "$short"
        continue
      fi
      if [ "$depth" -ge 5 ]; then
        printf 'bad\ta merge of %s into %s (%s), whose own merges go deeper than can be judged\n' "$dep" "$branch" "$short"
        continue
      fi
      sub=$(jig_staging_branch_problems "$dep" "$p" "$base" "$staging" $((depth + 1)) "$c")
      case $'\n'"$sub" in
        *$'\n'"bad$t"*)
          printf '%s\n' "$sub" | awk -F '\t' '$1 == "bad"'
          printf 'bad\ta merge of %s into %s (%s), which carries the above\n' "$dep" "$branch" "$short"
          ;;
        *)
          [ -z "$sub" ] || printf '%s\n' "$sub"
          printf 'dep\t%s\t%s\n' "$dep" "$c"
          ;;
      esac
    done
  done <<EOF
$fp
EOF
  return 0
}

# jig_branch_carries_staging <tip> <base-ref> <staging-ref> [<merge-head>...] —
# what a task branch at <tip> carries that it may not: the clean-branch rule of
# the staging flow (adr-20261111-a-task-lands-on-staging-through-its-pull-request).
# A task branch is cut from the base and stays clean until it reaches the base:
# only the base and clean task branches may be merged into it. One line per
# commit at fault, "<sha><TAB><merge><TAB><what>":
#   - <merge> `-`, <what> `cut from <staging>`: the branch itself is cut from
#     (or rebased onto) the staging branch; the lines are the commits of its
#     first-parent line that are on the staging branch's own;
#   - otherwise <merge> is the merge on the branch that brought the commit in —
#     `the merge in progress` for the <merge-head>s given, the heads of a merge
#     not committed yet (MERGE_HEAD), judged as the commit that will conclude
#     it — and <what> what was merged: the staging branch's name, a branch's
#     name, a commit, or `<task-branch>, which itself <why>` for a task branch
#     that is not clean (`is cut from <x>`, `carries <what>`, `is nested too
#     deep to judge`).
# Nothing when the branch is clean. Exit 1, printing nothing, when <tip>,
# <base-ref> or <staging-ref> names no commit here: a guard built on it refuses
# then, never reads "clean".
#
# A branch is judged by its first-parent line, from its tip down to the first
# commit the base has:
#   - it is cut from the staging branch when a commit of that line is on the
#     staging branch's own first-parent line: Jig lands only by merge commits,
#     so a task's own commits are second parents there, while a branch cut
#     from or rebased onto staging carries staging's landing merges on its own
#     line;
#   - each further parent of a merge on that line that the base lacks is the
#     staging branch when it is on staging's first-parent line; a task branch
#     when it is on the first-parent line of a `task/*` branch here or on
#     origin (that task's own work, never a branch it merged in), and clean by
#     this same rule — judged at the commit that was merged, not at its branch's tip, and
#     as a dependency, so also not clean when its first-parent line holds the
#     tip of an origin branch that is neither `task/*` nor the base (cut from a
#     feature branch) — and allowed then, even when its commits are on staging
#     already (the person's decision of 2026-11-11); anything else is refused.
# Dependencies are judged four deep; deeper is not clean. The task's own
# commits that landed on staging stay its own, and a merge of the base never
# counts.
#
# What the walk cannot see. A staging branch landed on by fast-forward (an
# external lander's plain `git merge`) puts a task's own commits on staging's
# first-parent line, and the task then reads as cut from staging: whoever lands
# outside Jig lands by merge commits (`--no-ff`). A branch cut from a feature
# branch is caught only for a dependency, and only while that feature branch's
# tip on origin is still on its line: once the feature branch moved on, was
# deleted on origin or was never pushed, the dependency reads clean; the task
# branch itself is never checked for it.
#
# Processes: per branch judged one rev-list of its first-parent line, and per
# merged parent the base lacks a few git calls; never one per commit.
jig_branch_carries_staging() {
  local tip base stage
  tip=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null) || return 1
  base=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null) || return 1
  stage=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$3^{commit}" 2>/dev/null) || return 1
  [ -n "$tip" ] && [ -n "$base" ] && [ -n "$stage" ] || return 1
  _JIG_BCS_STAGING=${3#refs/remotes/origin/}
  _JIG_BCS_STAGING=${_JIG_BCS_STAGING#refs/heads/}
  _JIG_BCS_BASE=${2#refs/remotes/origin/}
  _JIG_BCS_BASE=${_JIG_BCS_BASE#refs/heads/}
  _JIG_BCS_TOP=$tip
  # Staging's own first-parent line, and the tips of origin's branches that
  # are neither task branches nor the base: read once for the whole judgement.
  _JIG_BCS_SFP=$(git -C "$JIG_PROJECT" rev-list --first-parent "$stage" "^$base" 2>/dev/null || true)
  _JIG_BCS_TIPS=$(git -C "$JIG_PROJECT" for-each-ref --format='%(objectname) %(refname)' refs/remotes/origin 2>/dev/null \
    | awk -v b="refs/remotes/origin/$_JIG_BCS_BASE" '$2 != b && $2 != "refs/remotes/origin/HEAD" && index($2, "refs/remotes/origin/task/") != 1' || true)
  shift 3
  _jig_bcs_judge "$tip" "$base" "$stage" 0 "$@"
}

# What jig_branch_carries_staging reads once and its helpers share.
_JIG_BCS_STAGING=""
_JIG_BCS_BASE=""
_JIG_BCS_TOP=""
_JIG_BCS_SFP=""
_JIG_BCS_TIPS=""

# _jig_bcs_judge <commit> <base> <stage> <depth> [<merge-head>...] — the lines
# of jig_branch_carries_staging for the branch at <commit>; depth 0 is the task
# branch, above it a dependency.
_jig_bcs_judge() {
  local c="$1" base="$2" stage="$3" depth="$4" line m first rest p what label cut
  shift 4
  line=$(git -C "$JIG_PROJECT" rev-list --first-parent --parents "$c" "^$base" 2>/dev/null || true)
  # Cut from the staging branch: its line meets staging's own.
  cut=$(printf '%s\n' "$line" | _JIG_BCS_V="$_JIG_BCS_SFP" awk '
    BEGIN { n = split(ENVIRON["_JIG_BCS_V"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") s[a[i]] = 1 }
    NF && ($1 in s) { print $1 }')
  if [ -n "$cut" ]; then
    printf '%s\n' "$cut" | awk -v w="cut from $_JIG_BCS_STAGING" 'NF { print $1 "\t-\t" w }'
    return 0
  fi
  # A dependency cut from another branch of origin's.
  if [ "$depth" -gt 0 ] && [ -n "$_JIG_BCS_TIPS" ]; then
    cut=$(printf '%s\n' "$line" | _JIG_BCS_V="$_JIG_BCS_TIPS" awk '
      BEGIN { n = split(ENVIRON["_JIG_BCS_V"], a, "\n"); for (i = 1; i <= n; i++) { split(a[i], f, " "); if (f[1] != "") t[f[1]] = f[2] } }
      NF && ($1 in t) { r = t[$1]; sub(/^refs\/remotes\/origin\//, "", r); print $1 "\t" r; exit }')
    if [ -n "$cut" ]; then
      printf '%s\t-\tcut from %s\n' "${cut%%$'\t'*}" "${cut#*$'\t'}"
      return 0
    fi
  fi
  [ $# -eq 0 ] || line="MERGE $c $*
$line"
  while read -r m first rest; do
    [ -n "$m" ] && [ -n "$rest" ] || continue
    for p in $rest; do
      ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$p" "$base" 2>/dev/null || continue
      what=$(_jig_bcs_what "$p" "$base" "$stage" "$depth") || continue
      label=$m
      [ "$m" != MERGE ] || label="the merge in progress"
      git -C "$JIG_PROJECT" rev-list "$p" "^$base" "^$first" 2>/dev/null \
        | awk -v m="$label" -v w="$what" '{ print $1 "\t" m "\t" w }' || true
    done
  done <<EOF
$line
EOF
}

# _jig_bcs_what <parent> <base> <stage> <depth> — what the merged parent
# <parent> is, printed; non-zero when it is a clean task branch and allowed.
# Task branches containing the task's own tip, or standing on its first-parent
# line, are the task's own (here and on origin), never a dependency.
_jig_bcs_what() {
  local p="$1" base="$2" stage="$3" depth="$4" ref sha dep="" name sub why
  if printf '%s\n' "$_JIG_BCS_SFP" | grep -Fx -- "$p" >/dev/null; then
    printf '%s\n' "$_JIG_BCS_STAGING"
    return 0
  fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    sha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null) || continue
    ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$_JIG_BCS_TOP" "$sha" 2>/dev/null || continue
    ! git -C "$JIG_PROJECT" rev-list --first-parent "$_JIG_BCS_TOP" "^$base" 2>/dev/null | grep -Fx -- "$sha" >/dev/null || continue
    # That task's own work only: the merged commit on its first-parent line,
    # never a branch it merged in itself (a feature branch is a second parent
    # there, whatever it did since).
    git -C "$JIG_PROJECT" rev-list --first-parent "$sha" "^$base" 2>/dev/null | grep -Fx -- "$p" >/dev/null || continue
    name=${ref#refs/remotes/origin/}
    name=${name#refs/heads/}
    # The one whose tip is the merged commit, else the first that holds it.
    if [ -z "$dep" ] || [ "$sha" = "$p" ]; then dep=$name; fi
  done <<EOF
$(git -C "$JIG_PROJECT" for-each-ref --format='%(refname)' --contains "$p" refs/heads/task refs/remotes/origin/task 2>/dev/null || true)
EOF
  if [ -n "$dep" ]; then
    if [ "$depth" -ge 4 ]; then
      printf '%s, which itself is nested too deep to judge\n' "$dep"
      return 0
    fi
    # Judged at the commit that was merged.
    sub=$(_jig_bcs_judge "$p" "$base" "$stage" $((depth + 1)))
    [ -n "$sub" ] || return 1
    why=$(printf '%s\n' "$sub" | awk -F '\t' 'NF { print $3; exit }')
    case "$why" in
      "cut from "*) printf '%s, which itself is %s\n' "$dep" "$why" ;;
      *", which itself is nested too deep to judge") printf '%s, which itself is nested too deep to judge\n' "$dep" ;;
      *) printf '%s, which itself carries %s\n' "$dep" "$why" ;;
    esac
    return 0
  fi
  if git -C "$JIG_PROJECT" merge-base --is-ancestor "$p" "$stage" 2>/dev/null; then
    printf '%s\n' "$_JIG_BCS_STAGING"
    return 0
  fi
  # Named by a branch at it, else one that holds it and is no task's (a
  # feature branch that moved on), else by the commit.
  name=$(git -C "$JIG_PROJECT" for-each-ref --format='%(refname)' --points-at "$p" refs/heads refs/remotes/origin 2>/dev/null \
    | grep -v -e '^refs/heads/task/' -e '^refs/remotes/origin/task/' | sed -n 1p || true)
  [ -n "$name" ] || name=$(git -C "$JIG_PROJECT" for-each-ref --format='%(refname)' --contains "$p" refs/heads refs/remotes/origin 2>/dev/null \
    | grep -v -e '^refs/heads/task/' -e '^refs/remotes/origin/task/' -e '^refs/remotes/origin/HEAD$' \
      -e "^refs/heads/$_JIG_BCS_BASE\$" -e "^refs/remotes/origin/$_JIG_BCS_BASE\$" \
      -e "^refs/heads/$_JIG_BCS_STAGING\$" -e "^refs/remotes/origin/$_JIG_BCS_STAGING\$" | sed -n 1p || true)
  name=${name#refs/remotes/origin/}
  name=${name#refs/heads/}
  printf '%s\n' "${name:-commit $(git -C "$JIG_PROJECT" rev-parse --short "$p" 2>/dev/null)}"
}

# jig_git_show_path <ref> <path> — the content of <path> as committed at <ref>,
# on stdout; non-zero when <ref> names no commit or <path> is not in it.
# The ref is resolved to a commit SHA first and git is handed `<sha>:<path>`,
# never `<ref>:<path>`: under Git Bash (MSYS) an argument holding both `/`
# and `:` — `epic/idea-x:.ai/specs/...` — is rewritten as a path list before
# git sees it, so a ref with `/` in its name read nothing on Windows.
jig_git_show_path() {
  local sha
  sha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null) || return 1
  [ -n "$sha" ] || return 1
  git -C "$JIG_PROJECT" show "$sha:$2"
}

# The files a project declares its version in, at the repository's root, in
# the order they are asked: Jig's own source first, then the common manifests.
# One list for every reader of "this change raises the version"
# (adr-20261026-a-task-that-raises-the-version-is-a-release).
JIG_VERSION_FILES="scripts/lib/version.sh VERSION package.json composer.json pyproject.toml Cargo.toml"

# _jig_version_in <file> — the version the content on stdin declares, read the
# way <file>'s kind writes it; nothing when it declares none. A TOML file is
# read only in the table that names the package — [project] or [tool.poetry]
# for pyproject.toml, [package] for Cargo.toml — so a dependency's or a tool's
# `version` is never taken for it.
_jig_version_in() {
  case "$1" in
    scripts/lib/version.sh)
      sed -n 's/^JIG_VERSION="\([^"]*\)".*/\1/p' | head -n 1 ;;
    VERSION)
      awk '{ gsub(/^[ \t]+|[ \t\r]+$/, "") } $0 != "" { print; exit }' ;;
    package.json | composer.json)
      sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 ;;
    pyproject.toml) _jig_toml_version '[project] [tool.poetry]' ;;
    Cargo.toml) _jig_toml_version '[package]' ;;
  esac
}

# _jig_toml_version <tables> — the first `version = "…"` (or a literal
# '…' string) on stdin inside one of <tables>, a space-separated list of table
# headers as written without spaces. A header is read up to its first `]`, so
# `[ project ] # note` is `[project]`. Any line opening with `[` starts a
# table, also one inside a multi-line string or array: such a file can hide
# its version, which is a miss, never a false release.
_jig_toml_version() {
  awk -v want=" $1 " -v q="'" '
    /^[ \t]*\[/ { sec = substr($0, 1, index($0, "]")); gsub(/[ \t\r]/, "", sec); next }
    sec != "" && index(want, " " sec " ") && $0 ~ ("^[ \t]*version[ \t]*=[ \t]*[\"" q "]") {
      v = $0
      sub(/^[^=]*=[ \t]*/, "", v)
      c = substr(v, 1, 1)
      v = substr(v, 2)
      i = index(v, c)
      if (i) v = substr(v, 1, i - 1)
      print v
      exit
    }'
}

# _jig_release_fork <base> [<ref>] — the point <ref> (HEAD by default) forked
# from <base>: the later of its merge-bases with origin/<base> and the local
# <base>, so a stale remote-tracking ref does not take a raise merged in from
# a fresher local base for the task's own. Nothing when neither answers.
_jig_release_fork() {
  local ref fork="" f head="${2:-HEAD}"
  for ref in "refs/remotes/origin/$1" "refs/heads/$1"; do
    git -C "$JIG_PROJECT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue
    f=$(git -C "$JIG_PROJECT" merge-base "$ref" "$head" 2>/dev/null) || continue
    [ -n "$f" ] || continue
    if [ -z "$fork" ] || git -C "$JIG_PROJECT" merge-base --is-ancestor "$fork" "$f" 2>/dev/null; then
      fork="$f"
    fi
  done
  printf '%s\n' "$fork"
}

# jig_release_raise <base> [<ref>] — whether <ref> (HEAD by default; a commit
# the promotion of a task names, which a CI runner has not checked out)
# raises the version the project declares, against the point it forked from
# the branch <base>
# (_jig_release_fork: what the forge's pull request compares). Prints
# `<file><TAB><old><TAB><new><TAB><level>` or nothing. The first file of
# JIG_VERSION_FILES whose version went up decides; a file that declared no
# version at the fork point is passed over, and the next one asked. Two `X.Y.Z` versions are compared as
# numbers (jig_version_newer): an equal or lower one raises nothing, a higher
# one is `major` when its first number grew, `minor-or-patch` otherwise. Any
# other change of a version nobody can read as numbers is `major`: it is never
# merged as a lesser release. Anything git cannot answer is "not a release" —
# the ship goes on as it did before.
jig_release_raise() {
  local fork f new old o n level head="${2:-HEAD}"
  fork=$(_jig_release_fork "$1" "$head")
  [ -n "$fork" ] || return 0
  for f in $JIG_VERSION_FILES; do
    new=$(jig_git_show_path "$head" "$f" 2>/dev/null | _jig_version_in "$f")
    [ -n "$new" ] || continue
    old=$(jig_git_show_path "$fork" "$f" 2>/dev/null | _jig_version_in "$f")
    [ -n "$old" ] && [ "$old" != "$new" ] || continue
    o=${old#v}
    n=${new#v}
    level=major
    if jig_release_version "v$o" >/dev/null && jig_release_version "v$n" >/dev/null; then
      jig_version_newer "$n" "$o" || continue
      [ "$((10#${n%%.*}))" -gt "$((10#${o%%.*}))" ] || level=minor-or-patch
    fi
    printf '%s\t%s\t%s\t%s\n' "$f" "$old" "$new" "$level"
    return 0
  done
  return 0
}

# jig_release_notes_through <from> — the commit this branch's release notes say
# they describe: the newest `Release-Notes-Through: <sha>` trailer among the
# commits <from>..HEAD, resolved to a full sha, or as written when it does not
# resolve; nothing when no commit carries one. The newest wins: notes brought up
# to date after the base moved are a later commit with a later trailer
# (adr-20261112-release-notes-name-the-commit-they-describe).
jig_release_notes_through() {
  local v full
  v=$(git -C "$JIG_PROJECT" log --format=%B "$1..HEAD" 2>/dev/null \
    | awk 'found == "" && /^Release-Notes-Through:[[:space:]]*[0-9a-fA-F]+[[:space:]]*$/ {
        sub(/^Release-Notes-Through:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); found = $0
      }
      END { if (found != "") print found }')
  [ -n "$v" ] || return 0
  if full=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$v^{commit}" 2>/dev/null); then
    printf '%s\n' "$full"
  else
    printf '%s\n' "$v"
  fi
}

# jig_release_notes_gap <tip> — why the release notes on HEAD do not describe
# everything up to <tip> (the base's freshest commit), or nothing when they do.
# Reads git only, no network: the callers fetch, each its own way (a ship as
# the clone's account, CI with its checkout's token). The answer is the same
# question everywhere — every commit the release will carry into the base was
# seen by whoever wrote the notes — so `task ship`, `spec ship` and CI's
# changelog check can never disagree about it.
jig_release_notes_gap() {
  local tip="$1" through n list
  through=$(jig_release_notes_through "$tip")
  if [ -z "$through" ]; then
    printf 'none of its commits names the commit its release notes describe; once the notes cover %s, record that commit in a Release-Notes-Through: trailer (jig task set <task> notes_through <sha> adds it to the next ship)\n' \
      "$(git -C "$JIG_PROJECT" rev-parse --short "$tip" 2>/dev/null || printf '%s' "$tip")"
    return 0
  fi
  if ! git -C "$JIG_PROJECT" cat-file -e "$through^{commit}" 2>/dev/null; then
    printf 'Release-Notes-Through names %s, which is not a commit here\n' "$through"
    return 0
  fi
  if ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$through" "$tip" 2>/dev/null; then
    printf 'Release-Notes-Through names %s, which is not on the base (%s)\n' \
      "$(git -C "$JIG_PROJECT" rev-parse --short "$through")" "$tip"
    return 0
  fi
  n=$(git -C "$JIG_PROJECT" rev-list --count "$through..$tip" 2>/dev/null) || n=0
  [ "$n" -gt 0 ] || return 0
  list=$(git -C "$JIG_PROJECT" log --first-parent --format='  %h %s' "$through..$tip" 2>/dev/null | awk 'NR <= 5')
  printf '%s commit(s) reached the base after the commit the release notes describe (%s):\n%s\ndescribe them in the notes, record the new tip of the base as Release-Notes-Through, and run again\n' \
    "$n" "$(git -C "$JIG_PROJECT" rev-parse --short "$through")" "$list"
}

# jig_release_notes_refusal <who> <base> — jig_release_notes_gap against the
# freshest <base>: origin's, fetched now as the clone's account, or the local
# branch where there is no origin. A fetch that fails is itself the refusal:
# a release whose notes cannot be checked against the base does not go out.
jig_release_notes_refusal() {
  local who="$1" base="$2" tip
  if git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1; then
    jig_git_origin_account "$who" read
    if ! jig_net jig_git_origin fetch --quiet origin \
         "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1; then
      printf 'could not fetch %s from origin, so whether the release notes still describe it cannot be told; run again when origin answers\n' "$base"
      return 0
    fi
    tip="refs/remotes/origin/$base"
  else
    tip="refs/heads/$base"
  fi
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "$tip" >/dev/null 2>&1 || return 0
  jig_release_notes_gap "$tip"
}

# jig_fresh_base_ref <name> <who> — the ref to cut from <name>: the fresher of
# refs/heads/<name> and refs/remotes/origin/<name>, or HEAD when neither exists.
#
# Freshest, not nearest: resolving refs/heads/<base> first meant a local base
# that had fallen behind produced a stale branch *and* a stale base_commit,
# silently. That happened on 2026-09-11 — a branch was cut from the previous
# merge and the work done on it was missing a command merged an hour earlier.
# Diverged refs are refused rather than guessed: picking either surprises
# somebody, and the surprise surfaces far from its cause. <who> prefixes the
# messages (`task start`, `spec epic`). Shared because a task and an epic are
# both cut this way, and must never disagree about which commit is fresh.
jig_fresh_base_ref() {
  local base="$1" who="$2" local_ref remote_ref has_local=0 has_remote=0
  local_ref="refs/heads/$base"
  remote_ref="refs/remotes/origin/$base"
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "$local_ref" >/dev/null 2>&1 && has_local=1
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "$remote_ref" >/dev/null 2>&1 && has_remote=1

  if [ "$has_local" = 1 ] && [ "$has_remote" = 1 ]; then
    if git -C "$JIG_PROJECT" merge-base --is-ancestor "$local_ref" "$remote_ref" 2>/dev/null; then
      if ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$remote_ref" "$local_ref" 2>/dev/null; then
        jig_info "$who: local $base is behind origin/$base; branching from origin/$base"
        printf '%s\n' "$remote_ref"
      else
        printf '%s\n' "$local_ref"
      fi
    elif git -C "$JIG_PROJECT" merge-base --is-ancestor "$remote_ref" "$local_ref" 2>/dev/null; then
      printf '%s\n' "$local_ref"
    else
      jig_die "$who: $base and origin/$base have diverged; reconcile them first"
    fi
  elif [ "$has_local" = 1 ]; then
    printf '%s\n' "$local_ref"
  elif [ "$has_remote" = 1 ]; then
    printf '%s\n' "$remote_ref"
  else
    printf 'HEAD\n'
  fi
}

# jig_git_batch_ssh — the value for GIT_SSH_COMMAND that adds `-o
# BatchMode=yes` on top of whatever SSH command the environment already
# names (plain `ssh` when nothing does), so an `ssh://` or `git@` remote
# fails a password/passphrase prompt instead of waiting for it. Paired with
# `GIT_TERMINAL_PROMPT=0`, which does the same for git's own credential
# helper (HTTPS remotes): together they cover every interactive-credential
# path git has, on every network call that must never sit waiting for input
# nobody will type (this task).
#
# Not a timeout. Neither this nor GIT_TERMINAL_PROMPT=0 bounds a call that
# hangs for a different reason — a stalled TCP connection, a slow forge.
# That would need a process-level timeout, and `timeout`/`gtimeout` is not
# guaranteed to exist (ADR-0002: git is the only required dependency), so
# none is added here; a caller that must not wait past a budget runs the
# call through jig_net below.
jig_git_batch_ssh() {
  printf '%s -o BatchMode=yes\n' "${GIT_SSH_COMMAND:-ssh}"
}

# _JIG_NET_DEADLINE — the epoch second after which no call through jig_net may
# still run; empty, the default, bounds nothing. Set by the one caller that
# holds a lock with a ttl while it reaches the network: a write in Jig's own
# tree (lib/owntree.sh), whose live holder would read as gone past that ttl.
# _JIG_NET_CALL caps a single call below the deadline (JIG_NET_CALL in the
# environment overrides it, for tests), so one stalled call does not use up
# what the calls after it are owed.
_JIG_NET_DEADLINE=""
_JIG_NET_CALL=120
case "${JIG_NET_CALL:-}" in
  '' | *[!0-9]*) ;;
  *) _JIG_NET_CALL=$JIG_NET_CALL ;;
esac

# jig_net <program> [args...] — run a program that reaches the network: as is
# while _JIG_NET_DEADLINE is empty, and otherwise killed once it has run
# min(_JIG_NET_CALL, what is left before the deadline) seconds, exit 124, with
# nothing it printed passed on but one line on stderr that names the cut-off,
# so a caller that reports what failed says why. Past the deadline it is not
# started: 124 too. A program, never a shell function: the background job is
# the program itself, so the kill reaches it and not a subshell its child
# outlives. The two exceptions, jig_gh and jig_git_origin, replace themselves
# with their program (exec) when _JIG_GH_IN_NET is set. TERM, not KILL: git takes its own `.lock` files away on TERM. Its
# output comes back through files once it has ended, stderr first and stdout
# last: a caller that reads `2>&1` takes its answer from the last line (the
# URL `gh pr create` prints), and a warning gh writes to stderr first must
# not end up there.
# Bounded by hand for ADR-0002, as jig_ls_remote_tags is (conventions/shell.md).
jig_net() {
  local now left out err pid rc=0 ticks=0 name="$1"
  # jig_gh is gh, and jig_git_origin git, under this clone's account; a reader
  # knows the program.
  case "$name" in
    jig_gh) name=gh ;;
    jig_git_origin) name=git ;;
  esac
  if [ -z "$_JIG_NET_DEADLINE" ]; then
    "$@"
    return
  fi
  now=$(date +%s)
  left=$((_JIG_NET_DEADLINE - now))
  [ "$left" -le "$_JIG_NET_CALL" ] || left=$_JIG_NET_CALL
  if [ "$left" -le 0 ]; then
    printf '%s: not started, no time left for the network under the lock\n' "$name" >&2
    return 124
  fi
  out=$(mktemp "${TMPDIR:-/tmp}/jig-net.XXXXXX") || return 1
  jig_cleanup_add "$out"
  err="$out.err"
  jig_cleanup_add "$err"
  if [ "$1" = jig_gh ] || [ "$1" = jig_git_origin ]; then
    # Both replace themselves with their program (exec) when this is set.
    _JIG_GH_IN_NET=1 "$@" >"$out" 2>"$err" </dev/null &
  else
    "$@" >"$out" 2>"$err" </dev/null &
  fi
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((left * 5)) ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$out" "$err"
      printf '%s: no answer within %ss; cut off\n' "$name" "$left" >&2
      return 124
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid" || rc=$?
  cat "$err" >&2
  cat "$out"
  rm -f "$out" "$err"
  return "$rc"
}

# --- the newest published release -------------------------------------------
#
# Doctor (`jig doctor`) and housekeeping's daily release check both ask the
# same question of a framework checkout's origin — "what is the newest
# release tag?" — and both must never hang or prompt for a credential doing
# it. One implementation, shared here, rather than two that could drift
# (task status-says-a-newer-jig-exists, following on #146
# doctor-says-a-newer-jig-exists, which first wrote this against doctor
# alone).

# _JIG_RELEASE_CHECK_TIMEOUT — seconds a caller budgets `jig_check_newest_release`
# for `git ls-remote` to answer before it is killed. One shared number, so
# doctor and housekeeping never quietly drift apart on how long "too slow"
# is.
_JIG_RELEASE_CHECK_TIMEOUT=5

# jig_ls_remote_tags <root> <seconds> — `git ls-remote --tags origin` at the
# checkout <root>, printed on success. Killed and reported failed (exit 2) if
# it is still running after <seconds> wall-clock seconds; a plain git failure
# (bad or unreachable origin, answered quickly) is exit 1, so the caller can
# tell "no answer in time" from "an answer arrived, and it was no" apart,
# rather than reporting both as the same shrug.
#
# GIT_TERMINAL_PROMPT=0 and GIT_SSH_COMMAND (jig_git_batch_ssh above) keep a
# credential prompt from hanging the call.
#
# Rolled by hand rather than `timeout`/`gtimeout` (not guaranteed to exist,
# ADR-0002): the call runs in the background, this polls `kill -0` five times
# a second, and sends SIGTERM once the budget is spent. A killed call never
# hands back partial tag data — the temp file is discarded either way.
jig_ls_remote_tags() {
  local root="$1" seconds="$2" out pid ticks=0 max_ticks
  max_ticks=$((seconds * 5))
  out=$(mktemp "${TMPDIR:-/tmp}/jig-lsremote.XXXXXX") || return 1
  jig_cleanup_add "$out"
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(jig_git_batch_ssh)" \
    git -C "$root" ls-remote --tags origin >"$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$max_ticks" ]; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out"
      return 2
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  if wait "$pid"; then
    cat "$out"
    rm -f "$out"
    return 0
  fi
  rm -f "$out"
  return 1
}

# jig_check_newest_release <root> [seconds] — the newest release tag
# (`vX.Y.Z`) published at <root>'s origin remote, printed on success
# (<seconds> defaults to _JIG_RELEASE_CHECK_TIMEOUT). Read-only and
# network-bound like jig_ls_remote_tags above, which it calls.
#
# Failure is never folded into one shrug: the exit code says which of four
# distinct things happened, so a caller can report (or not) accordingly
# (ADR-0017, "unknown is not zero"):
#   1 — no origin remote at <root>
#   2 — origin answered, but `git ls-remote` failed (e.g. it does not exist)
#   3 — origin did not answer within <seconds>
#   4 — origin has no release tag
jig_check_newest_release() {
  local root="$1" seconds="${2:-$_JIG_RELEASE_CHECK_TIMEOUT}" out rc best
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 1
  rc=0
  out=$(jig_ls_remote_tags "$root" "$seconds") || rc=$?
  if [ "$rc" -eq 2 ]; then
    return 3
  elif [ "$rc" -ne 0 ]; then
    return 2
  fi
  best=$(printf '%s\n' "$out" | jig_newest_release) || return 4
  printf '%s\n' "$best"
}

# jig_fetch_branches <who> <name>... — refresh origin/<name> for each branch
# from origin, one at a time, so that a branch origin does not have fails
# alone. Does nothing without an origin. A failure is a warning, never fatal:
# the caller goes on with the refs it has, and says what it decided from them.
# Through jig_git_origin, which never waits for a prompt — a command that only
# wanted fresh refs must not stop and wait for a password — and fetches over
# HTTPS as the clone's GitHub account.
jig_fetch_branches() {
  local who="$1" name
  shift
  git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1 || return 0
  jig_git_origin_account "$who" read
  for name in "$@"; do
    [ -n "$name" ] || continue
    if ! jig_net jig_git_origin fetch --quiet origin \
         "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1; then
      jig_warn "$who: could not fetch $name from origin; using the refs this checkout has"
    fi
  done
  return 0
}

# jig_fetch_fresh <name>... — fetch each branch from origin as
# jig_fetch_branches does, but stop at the first that cannot be fetched,
# printing its name and returning 1: for a step that must act on origin's
# branch as it is now, never on the refs this checkout last saw (a merge into
# the staging branch, adr-20261111-a-task-lands-on-staging-through-its-pull-request).
# No origin at all is a failure too. Through jig_git_origin, as the clone's
# account: the caller names it first (jig_git_origin_account), in its own
# shell, since this is called in `$()`.
jig_fetch_fresh() {
  local name
  if ! git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1; then
    printf '%s\n' "${1:-origin}"
    return 1
  fi
  for name in "$@"; do
    [ -n "$name" ] || continue
    if ! jig_net jig_git_origin fetch --quiet origin \
         "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1; then
      printf '%s\n' "$name"
      return 1
    fi
  done
  return 0
}

# jig_on_ci_runner — exit 0 when this process runs on a CI runner: the
# environment variable CI is set and is not `false` or `0`, as GitHub Actions,
# GitLab CI and most others set it. A runner has no `agent.git` (a local-only
# key), so what the team's pipeline runs is decided by the flow, not by a
# person's rights (adr-20261111-prepare-for-prod-opens-the-promotion-from-git-alone).
jig_on_ci_runner() {
  case "${CI:-}" in
    '' | 0 | false | False | FALSE) return 1 ;;
  esac
  return 0
}

# jig_merge_conflicts <into> <from> — the paths a merge of the commit <from>
# into the commit <into> leaves in conflict, one per line, into
# JIG_MERGE_CONFLICTS; empty when it merges cleanly. Called directly, never in
# `$()`: its temporary directory is registered for the exit cleanup, which a
# subshell would lose (conventions/shell.md). Asked in a temporary detached worktree, never in a
# checkout: nothing is committed, the merge is aborted and the worktree
# removed by `git worktree remove` without `--force` (RULES.md), its mktemp
# directory with the exit cleanup. Exit 1 when the question could not be
# asked (the worktree could not be made, or the merge failed for another
# reason than a conflict). Merge conflicts are symmetric, so this also says
# whether <into> merges cleanly into <from>.
# shellcheck disable=SC2034 # JIG_MERGE_CONFLICTS is read by the caller
JIG_MERGE_CONFLICTS=""
jig_merge_conflicts() {
  local into="$1" from="$2" tmp wt out="" rc=0
  JIG_MERGE_CONFLICTS=""
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jig-merge.XXXXXX") || return 1
  jig_cleanup_add -d "$tmp"
  wt="$tmp/tree"
  git -C "$JIG_PROJECT" worktree add -q --detach "$wt" "$into" >/dev/null 2>&1 || return 1
  # Without the person's rerere: a recorded resolution would stage the paths,
  # and the conflict would read as a merge that failed for another reason.
  if ! git -C "$wt" -c user.name=jig -c user.email=jig@localhost -c rerere.enabled=false \
       merge -q --no-commit --no-ff "$from" >/dev/null 2>&1; then
    out=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null) || out=""
    [ -n "$out" ] || rc=1
  fi
  git -C "$wt" merge --abort >/dev/null 2>&1 || true
  git -C "$JIG_PROJECT" worktree remove "$wt" >/dev/null 2>&1 || true
  # shellcheck disable=SC2034 # JIG_MERGE_CONFLICTS is read by the caller
  JIG_MERGE_CONFLICTS=$out
  return "$rc"
}

# --- forge -------------------------------------------------------------------

# _jig_forge_by_name <url-or-host> — github|gitlab|none, read off the name.
_jig_forge_by_name() {
  case "$1" in
    *github.com*) printf 'github\n' ;;
    *gitlab.com*|*gitlab.*) printf 'gitlab\n' ;;
    *) printf 'none\n' ;;
  esac
}

# _jig_ssh_alias_hostname <url> — the host an SSH remote really reaches, as
# `ssh -G` resolves it from the user's ssh config; nothing for a URL that is
# not SSH, or when ssh is missing or answers nothing.
#
# A person with two accounts on one forge reaches it through a `Host` alias
# (`git@github-personal:owner/repo.git`, `HostName github.com`). The origin URL
# then names no forge, git and gh resolve the alias anyway, and `task ship` and
# `spec ship` said "no forge available" on every pull request. `ssh -G` only
# prints the resolved configuration: it opens no connection. ssh is optional
# (ADR-0002): without it the answer stays what the URL says.
_jig_ssh_alias_hostname() {
  local url="$1" host
  case "$url" in
    ssh://*)
      host=${url#ssh://}
      host=${host%%/*}
      host=${host#*@}
      host=${host%%:*}
      ;;
    *://*) return 0 ;;
    *:*)
      # scp form, [user@]host:path. A path with a slash before the first
      # colon is a local path, not a host.
      host=${url%%:*}
      case "$host" in */*) return 0 ;; esac
      host=${host#*@}
      ;;
    *) return 0 ;;
  esac
  [ -n "$host" ] || return 0
  command -v ssh >/dev/null 2>&1 || return 0
  ssh -G "$host" </dev/null 2>/dev/null | sed -n 's/^hostname //p' || true
}

# --- the GitHub account of this clone -----------------------------------------
#
# A person may hold several accounts in `gh`, and `gh` answers as the active
# one, which is a setting of the whole machine: in a clone that belongs to the
# other account every pull-request call failed, and the agent stopped to ask
# for `gh auth switch`. Jig never switches (another session may be working
# under the active account); it names the account of this clone and hands
# that account's own token to each `gh` call, for that call only
# (adr-20261110-a-clone-names-its-github-account). `jig_gh` is the one way a
# script calls `gh` about the project's repository; `jig pr` keeps its own
# choice of account, made per pull request (lib/pr.sh).

# jig_gh_dotcom_kind <host> — exit 0 for a host gh reads GH_TOKEN/GITHUB_TOKEN
# for: github.com and GitHub's tenancy hosts (*.ghe.com); any other host is a
# GitHub Enterprise Server, read from GH_ENTERPRISE_TOKEN/GITHUB_ENTERPRISE_TOKEN.
jig_gh_dotcom_kind() {
  case "$1" in
    github.com | *.ghe.com) return 0 ;;
    *) return 1 ;;
  esac
}

# jig_gh_accounts <host> — "<accounts><TAB><active>": the logins `gh` holds for
# <host> that are signed in, space-separated, and the active one. Read from
# `gh auth status`, whose exit status is ignored: it fails as a whole when one
# account is broken, and the others still count. An older gh that names one
# account (`Logged in to <host> as <login>`) and no active line makes that one
# active.
jig_gh_accounts() {
  local out
  out=$(jig_net gh auth status --hostname "$1" 2>&1) || true
  printf '%s\n' "$out" | awk '
    /Logged in to / && !/Failed/ {
      login = ""
      for (i = 1; i < NF; i++) if ($i == "account" || $i == "as") { login = $(i + 1); break }
      gsub(/[()]/, "", login)
      if (login != "") { n++; names = names (names == "" ? "" : " ") login; last = login }
      next
    }
    /Active account: true/ { if (last != "") active = last }
    END {
      if (active == "" && n == 1) active = last
      printf "%s\t%s\n", names, active
    }'
}

# jig_gh_stored_token <host> <login> — the token gh keeps for <login> on
# <host>, asked with every token variable unset so that gh answers for the
# stored account (`gh auth token --user`, gh 2.40 and later).
jig_gh_stored_token() {
  local t
  # Not through jig_net: this reads gh's own store, not the network, and
  # jig_net keeps a call's output in a file while it waits — a token would
  # lie on disk there.
  t=$(
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
    gh auth token --hostname "$1" --user "$2" 2>/dev/null </dev/null
  ) || return 1
  t=$(printf '%s' "$t" | tr -d '\r\n')
  [ -n "$t" ] || return 1
  printf '%s\n' "$t"
}

# jig_gh_token_env <host> — the token variables set in this environment that
# gh would use for <host> instead of any stored account.
jig_gh_token_env() {
  local names="" v
  if jig_gh_dotcom_kind "$1"; then
    for v in GH_TOKEN GITHUB_TOKEN; do
      eval "[ -z \"\${$v:-}\" ]" || names="$names${names:+ }$v"
    done
  else
    for v in GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
      eval "[ -z \"\${$v:-}\" ]" || names="$names${names:+ }$v"
    done
  fi
  printf '%s\n' "$names"
}

# What jig_gh_resolve found. _JIG_GH_HOW says where the account came from:
# `config` (github.account), `detected` (the one account that may push),
# `only` (the one account gh holds), `env` (a token in the environment) or
# `gh` (gh's own choice: nothing here names an account). _JIG_GH_TOKEN is
# empty for `env` and `gh`, where gh is run as it is.
_JIG_GH_STATE="" _JIG_GH_HOST="" _JIG_GH_SLUG="" _JIG_GH_ORIGIN=""
_JIG_GH_LOGIN="" _JIG_GH_HOW="" _JIG_GH_TOKEN="" _JIG_GH_WHY=""

# _jig_gh_origin — sets _JIG_GH_ORIGIN, _JIG_GH_HOST and _JIG_GH_SLUG
# (`owner/repo`) from the origin URL: https, ssh:// or scp form, `.git` or
# not. A host that does not name GitHub is taken for an SSH alias and resolved
# (_jig_ssh_alias_hostname); `ssh.github.com`, GitHub's SSH endpoint on port
# 443, is github.com. Exit 1 when origin is missing or names no repository.
_jig_gh_origin() {
  local url h path alias
  url=$(git -C "$JIG_PROJECT" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  case "$url" in
    *://*)
      path=${url#*://}
      h=${path%%/*}
      path=${path#*/}
      h=${h#*@}
      h=${h%%:*}
      ;;
    *:*)
      h=${url%%:*}
      case "$h" in */*) return 1 ;; esac
      h=${h#*@}
      path=${url#*:}
      ;;
    *) return 1 ;;
  esac
  path=${path#/}
  path=${path%/}
  path=${path%.git}
  case "$path" in
    */*/* | /* | */ ) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  h=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')
  if [ "$(_jig_forge_by_name "$h")" != github ]; then
    alias=$(_jig_ssh_alias_hostname "$url")
    [ -z "$alias" ] || h=$(printf '%s' "$alias" | tr '[:upper:]' '[:lower:]')
  fi
  [ "$h" != ssh.github.com ] || h=github.com
  [ -n "$h" ] || return 1
  _JIG_GH_ORIGIN="$url" _JIG_GH_HOST="$h" _JIG_GH_SLUG="$path"
}

# jig_gh_memo_file — where a detected account is remembered: one line,
# `<origin url><TAB><login><TAB><how>`. Never a token.
# One per clone, in the main checkout's runtime directory: a task worktree
# asks GitHub as the same account its clone does, and finds it already known.
jig_gh_memo_file() { printf '%s/%s/runtime/gh-account\n' "$(jig_config_clone_root)" "$JIG_AI_DIR"; }

# _jig_gh_memo_write <login> <how>
_jig_gh_memo_write() {
  local f tmp
  f=$(jig_gh_memo_file)
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  tmp="$f.$$"
  if printf '%s\t%s\t%s\n' "$_JIG_GH_ORIGIN" "$1" "$2" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# _jig_gh_may_push <token> — exit 0 when the account of <token> may write to
# the origin repository: push, maintain or admin.
_jig_gh_may_push() {
  local out
  out=$(
    _jig_gh_token_export "$1"
    jig_net gh api --hostname "$_JIG_GH_HOST" "repos/$_JIG_GH_SLUG" \
      --jq '[.permissions.push, .permissions.maintain, .permissions.admin] | map(tostring) | join(" ")' 2>/dev/null
  ) || return 1
  case " $(printf '%s' "$out" | tr -d '\r') " in
    *" true "*) return 0 ;;
    *) return 1 ;;
  esac
}

# _jig_gh_token_export <token> — make <token> the one gh uses for
# _JIG_GH_HOST in this shell: every token variable unset, the host's own set.
# Only ever called in a subshell or in a job gh is about to replace.
# shellcheck disable=SC2030,SC2031 # the change is meant for that shell only
_jig_gh_token_export() {
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
  if jig_gh_dotcom_kind "$_JIG_GH_HOST"; then
    GH_TOKEN="$1"
    export GH_TOKEN
  else
    GH_ENTERPRISE_TOKEN="$1"
    export GH_ENTERPRISE_TOKEN
  fi
}

# jig_gh_resolve — name the account of this clone, once per process. The
# first that answers:
#   1. a token in the environment: gh is run as it is, as CI and a person's
#      own shell set it up;
#   2. `github.account` (local only): that account's stored token, and a
#      refusal when gh holds no such account or gives no token for it — never
#      a quiet fall back to the active one;
#   3. the account remembered for this origin, while gh still gives its token;
#   4. the one account gh holds;
#   5. of several, the only one that may push to the origin repository, or
#      the active one when several may; a refusal when several may and the
#      active one is not among them. None that may push (a fork's upstream, a
#      public repository) leaves gh to its own choice.
# Exit 1 with _JIG_GH_WHY on a refusal; a caller that only reads may go on
# with gh as it is.
jig_gh_resolve() {
  local want accounts="" active="" a t n=0 writers="" first_t="" memo_origin="" memo_login="" memo_how="" tab
  case "$_JIG_GH_STATE" in
    ready) return 0 ;;
    refused) return 1 ;;
  esac
  _JIG_GH_STATE=ready _JIG_GH_LOGIN="" _JIG_GH_HOW=gh _JIG_GH_TOKEN="" _JIG_GH_WHY=""
  _jig_gh_origin || return 0
  if [ -n "$(jig_gh_token_env "$_JIG_GH_HOST")" ]; then
    _JIG_GH_HOW="env"
    return 0
  fi
  want=$(cfg github.account "")
  if [ -n "$want" ]; then
    if t=$(jig_gh_stored_token "$_JIG_GH_HOST" "$want"); then
      _JIG_GH_LOGIN="$want" _JIG_GH_HOW=config _JIG_GH_TOKEN="$t"
      return 0
    fi
    tab=$(printf '\t')
    IFS="$tab" read -r accounts active <<EOF
$(jig_gh_accounts "$_JIG_GH_HOST")
EOF
    _JIG_GH_STATE=refused
    _JIG_GH_WHY="github.account is $want, and gh gives no token for it on $_JIG_GH_HOST (accounts gh holds: ${accounts:-none}; gh auth login --hostname $_JIG_GH_HOST, or jig config set --local github.account <login>; gh auth token --user needs gh 2.40 or later)"
    return 1
  fi
  tab=$(printf '\t')
  if [ -f "$(jig_gh_memo_file)" ]; then
    IFS="$tab" read -r memo_origin memo_login memo_how < "$(jig_gh_memo_file)" || true
    if [ "$memo_origin" = "$_JIG_GH_ORIGIN" ] && [ -n "$memo_login" ] \
       && t=$(jig_gh_stored_token "$_JIG_GH_HOST" "$memo_login"); then
      _JIG_GH_LOGIN="$memo_login" _JIG_GH_HOW="${memo_how:-detected}" _JIG_GH_TOKEN="$t"
      return 0
    fi
  fi
  IFS="$tab" read -r accounts active <<EOF
$(jig_gh_accounts "$_JIG_GH_HOST")
EOF
  [ -n "$accounts" ] || return 0
  set -f
  # shellcheck disable=SC2086 # logins, split on purpose
  set -- $accounts
  set +f
  if [ $# = 1 ]; then
    t=$(jig_gh_stored_token "$_JIG_GH_HOST" "$1") || return 0
    _JIG_GH_LOGIN="$1" _JIG_GH_HOW=only _JIG_GH_TOKEN="$t"
    _jig_gh_memo_write "$1" only
    return 0
  fi
  for a in "$@"; do
    t=$(jig_gh_stored_token "$_JIG_GH_HOST" "$a") || continue
    _jig_gh_may_push "$t" || continue
    n=$((n + 1))
    writers="$writers${writers:+ }$a"
    [ -n "$first_t" ] || first_t="$t"
    if [ "$a" = "$active" ]; then
      _JIG_GH_LOGIN="$a" _JIG_GH_TOKEN="$t"
    fi
  done
  if [ "$n" = 0 ]; then
    return 0
  elif [ "$n" = 1 ]; then
    _JIG_GH_LOGIN="$writers" _JIG_GH_TOKEN="$first_t"
  elif [ -z "$_JIG_GH_LOGIN" ]; then
    _JIG_GH_STATE=refused
    _JIG_GH_WHY="several gh accounts may push to $_JIG_GH_SLUG ($writers) and the active one (${active:-none}) is not among them; name this clone's: jig config set --local github.account <login>"
    return 1
  fi
  _JIG_GH_HOW=detected
  _jig_gh_memo_write "$_JIG_GH_LOGIN" detected
  return 0
}

# jig_gh_require <who> — jig_gh_resolve, or die with why: for a command that
# writes to GitHub and must not do it under an account nobody named. Called in
# the command's own shell, before the first `$(jig_gh ...)`, so that the
# answer is found once and a refusal is not lost in a subshell.
jig_gh_require() {
  jig_gh_resolve || jig_die "$1: $_JIG_GH_WHY"
}

# jig_gh_asked_as — one sentence naming the account a GitHub call of this clone
# went as and where Jig took it from, for the message of a call that failed: a
# refusal such as "must be a collaborator" says nothing of who asked, and a
# token inherited from the environment (a direnv .envrc, a service started from
# one) wins over github.account without a word. Only on that path: the login
# behind a token in the environment, or gh's active one, costs gh a call.
jig_gh_asked_as() {
  local vars var login="" accounts="" active="" tab
  jig_gh_resolve || true
  case "$_JIG_GH_HOW" in
    config) printf 'It asked GitHub as %s (github.account).\n' "$_JIG_GH_LOGIN" ;;
    detected)
      printf 'It asked GitHub as %s (found: the gh account that may push here; jig config set --local github.account <login> names another).\n' "$_JIG_GH_LOGIN" ;;
    only) printf 'It asked GitHub as %s (the only account gh holds).\n' "$_JIG_GH_LOGIN" ;;
    env)
      vars=$(jig_gh_token_env "$_JIG_GH_HOST")
      var=${vars%% *}
      login=$(jig_net jig_gh api --hostname "$_JIG_GH_HOST" user --jq .login 2>/dev/null | tr -d '\r' | head -n 1) || login=""
      case "$login" in '' | -* | *[!A-Za-z0-9-]*) login="the account of that token" ;; esac
      printf 'It asked GitHub as %s: %s is set in the environment Jig runs in, and a token there comes before github.account and the accounts gh holds. Remove %s from that environment (a shell, a direnv .envrc, a service started from one) to ask as this clone'"'"'s account.\n' \
        "$login" "$var" "$var" ;;
    *)
      [ -n "$_JIG_GH_HOST" ] || return 0
      tab=$(printf '\t')
      IFS="$tab" read -r accounts active <<EOF
$(jig_gh_accounts "$_JIG_GH_HOST")
EOF
      if [ -n "$active" ]; then
        printf 'It asked GitHub as %s, gh'"'"'s active account: nothing names this clone'"'"'s (jig config set --local github.account <login>).\n' "$active"
      fi
      ;;
  esac
}

# jig_ship_account <who> <level> — before a ship's push: when this ship will
# open a pull request on GitHub (<level> pr or merge), name the account it is
# opened as, or refuse with nothing sent
# (adr-20260925-a-ship-refuses-before-it-sends). After the commit and the
# "does this branch carry work" answer, not before: a ship that refuses for a
# reason of its own must not have asked the forge anything, and the commit
# stays on this machine, where running the ship again finds it. Lower levels
# ask GitHub nothing and are not held up by its accounts.
jig_ship_account() {
  case "$2" in
    pr | merge) ;;
    *) return 0 ;;
  esac
  [ "$(jig_forge_kind 2>/dev/null)" = github ] || return 0
  jig_gh_resolve || jig_die "$1: $_JIG_GH_WHY
Nothing was sent; the commit is on this machine, and running this again goes on from it."
}

# jig_gh_prepare <who> — the same for a command that only reads: a refusal is
# a warning, and gh is then run as it is.
jig_gh_prepare() {
  jig_gh_resolve || jig_warn "$1: $_JIG_GH_WHY; asking GitHub as gh's active account"
}

# jig_gh <args>... — `gh <args>` as the account of this clone. With a token
# in hand, every token variable is unset in a subshell and the host's own
# (GH_TOKEN for github.com and *.ghe.com, GH_ENTERPRISE_TOKEN for a GitHub
# Enterprise Server) set to it, for this call only: a token is never an
# argument, where ps would show it, and never written down; the active account
# and gh's configuration stay as they are.
jig_gh() {
  jig_gh_resolve || true
  # Under jig_net this function is the background job itself: gh must replace
  # it, not run as its child, or the kill that cuts a silent call off would
  # reach the wrapper and leave gh running — a `gh pr create` reported as cut
  # off that opens the pull request anyway.
  if [ -n "${_JIG_GH_IN_NET:-}" ]; then
    [ -z "$_JIG_GH_TOKEN" ] || _jig_gh_token_export "$_JIG_GH_TOKEN"
    unset _JIG_GH_IN_NET
    exec gh "$@"
  fi
  (
    [ -z "$_JIG_GH_TOKEN" ] || _jig_gh_token_export "$_JIG_GH_TOKEN"
    exec gh "$@"
  )
}

# --- git over HTTPS as the account of this clone -----------------------------
#
# git asks its credential helper — the Keychain, gh's, a credential manager —
# for whatever it holds for the host, which is one account: over HTTPS a push
# or a fetch went as that one, whatever account jig_gh used for the pull
# request. `jig_git_origin` is the one way a script reaches the project's
# origin with git; when the URL is HTTPS to GitHub and an account is named —
# by github.account, among several, or the one gh holds — it resets git's helpers
# for that host for this one call and adds a helper of its own that asks gh's
# store for that account's token when git asks for it
# (adr-20261111-git-over-https-asks-gh-for-the-clones-account). The token is
# never an argument, never in git's environment (its hooks would see it),
# never on disk: only the host and the login are in the helper's text. SSH is
# left to its key, and asks gh nothing.

# _JIG_GIT_CRED — the `-c` options for the current call; _JIG_GIT_WARNED — a
# read already warned that the account could not be named.
_JIG_GIT_CRED=()
_JIG_GIT_WARNED=""

# _jig_git_origin_url <verb> — the URL git uses for <verb> on origin, with
# insteadOf applied: the push URL for a push, the fetch URL otherwise.
_jig_git_origin_url() {
  if [ "$1" = push ]; then
    git -C "$JIG_PROJECT" remote get-url --push origin 2>/dev/null || true
  else
    git -C "$JIG_PROJECT" remote get-url origin 2>/dev/null || true
  fi
}

# _jig_git_https_github <url> — exit 0 when <url> is HTTPS, names GitHub
# (forge github, or auto and a GitHub name) and gh is installed: the only case
# in which Jig chooses git's credentials, and asks gh anything for it.
_jig_git_https_github() {
  # Never plain http: a token is not handed to an unencrypted URL.
  case "$1" in
    https://*) ;;
    *) return 1 ;;
  esac
  case "$(cfg forge auto)" in
    github) ;;
    auto) [ "$(_jig_forge_by_name "$1")" = github ] || return 1 ;;
    *) return 1 ;;
  esac
  command -v gh >/dev/null 2>&1
}

# _jig_git_cred <url> — fill _JIG_GIT_CRED for a call to <url>: empty unless
# it is HTTPS to GitHub, on the host jig_gh_resolve read, and an account was
# named: by github.account (config), among several (detected), or as the one
# gh held (only) — remembered, so a second account signed in later and made
# active must not take the push while the pull request goes as the first.
# With a token in the environment (env) or nothing named (gh), git's own
# helper answers, as it always did.
_jig_git_cred() {
  local url="$1" scheme authority host login helper
  _JIG_GIT_CRED=()
  _jig_git_https_github "$url" || return 0
  jig_gh_resolve || return 0
  case "$_JIG_GH_HOW" in
    config | detected | only) ;;
    *) return 0 ;;
  esac
  scheme=${url%%://*}
  authority=${url#*://}
  authority=${authority%%/*}
  authority=${authority#*@}
  authority=$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]')
  host=${authority%%:*}
  [ "$host" = "$_JIG_GH_HOST" ] || return 0
  login=$_JIG_GH_LOGIN
  # The helper is shell text git runs: nothing but a login's and a host's
  # characters goes into it.
  case "$login" in
    '' | -* | *[!A-Za-z0-9-]*) return 0 ;;
  esac
  case "$authority" in
    '' | *[!a-z0-9.:-]*) return 0 ;;
  esac
  # git runs it with `get`, `store` or `erase`; only `get` answers. Its stdin
  # is git's request, read to the end and ignored.
  #
  # No backslash anywhere in it: Git Bash on Windows turns a `\` in an
  # argument to git.exe into `/`, so a `printf "...\n..."` here reached git as
  # one line, `username=<login>/npassword=<token>/n` — the token became part
  # of the user name, and git printed it in the URL of its error. `echo` ends
  # each line without one; a login holds [A-Za-z0-9-] and a token no leading
  # `-`, so neither reads as an option of echo.
  # shellcheck disable=SC2016 # expanded by the shell git starts, not here
  helper='!f() { cat >/dev/null; test "$1" = get || return 0; t=$(unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; gh auth token --hostname '"$host"' --user '"$login"' 2>/dev/null </dev/null) || return 0; test -n "$t" || return 0; echo username='"$login"'; echo "password=$t"; }; f'
  _JIG_GIT_CRED=(-c "credential.$scheme://$authority.helper=" -c "credential.$scheme://$authority.helper=$helper")
}

# jig_git_origin_account <who> <write|read> [<verb>] — name the account git
# will reach origin as, once, in the command's own shell, before the first
# `$(jig_git_origin ...)`: a subshell would lose the answer and ask again. Over
# SSH, or to a forge that is not GitHub, nothing is asked. A refusal
# (jig_gh_resolve) stops a write with nothing pushed; a read warns once and
# goes on with git's own helper, as it did before.
jig_git_origin_account() {
  local who="$1" mode="$2" url
  url=$(_jig_git_origin_url "${3:-fetch}")
  _jig_git_https_github "$url" || return 0
  jig_gh_resolve && return 0
  if [ "$mode" = write ]; then
    jig_die "$who: $_JIG_GH_WHY
Nothing was pushed; the commit is on this machine, and running this again goes on from it."
  fi
  [ -n "$_JIG_GIT_WARNED" ] && return 0
  _JIG_GIT_WARNED=1
  jig_warn "$who: $_JIG_GH_WHY; reaching origin with git's own credentials"
}

# jig_git_origin <git-args>... — `git -C "$JIG_PROJECT" <git-args>` against
# origin, as the account of this clone over HTTPS (above), never waiting for a
# prompt: GIT_TERMINAL_PROMPT=0 and GIT_SSH_COMMAND (jig_git_batch_ssh) are
# set here, so a caller cannot forget one. The first argument is git's verb;
# `push` reads origin's push URL. Under jig_net git replaces this function,
# so the kill that cuts a silent call off reaches git itself.
jig_git_origin() {
  _jig_git_cred "$(_jig_git_origin_url "$1")"
  if [ -n "${_JIG_GH_IN_NET:-}" ]; then
    GIT_SSH_COMMAND=$(jig_git_batch_ssh)
    GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND GIT_TERMINAL_PROMPT
    # Not into git's hooks: a jig they run is not under this jig_net.
    unset _JIG_GH_IN_NET
    exec git ${_JIG_GIT_CRED[@]+"${_JIG_GIT_CRED[@]}"} -C "$JIG_PROJECT" "$@"
  fi
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(jig_git_batch_ssh)" \
    git ${_JIG_GIT_CRED[@]+"${_JIG_GIT_CRED[@]}"} -C "$JIG_PROJECT" "$@"
}

# jig_forge_kind — which forge CLI this checkout should use: cfg `forge`
# (auto|github|gitlab|none, default auto) resolved against the origin URL
# when auto — or against the host an SSH alias in it resolves to
# (_jig_ssh_alias_hostname) — then confirmed actually usable here — the CLI on PATH and
# authenticated. Prints github|gitlab|none; dies only on an unrecognised
# `forge` value, the one case a caller cannot paper over with "none".
#
# Shared rather than kept in housekeeping.sh: `housekeeping`'s remote-state
# tier and the pull-request step of `task ship` and `spec ship` (jig_ship_pr)
# all have to agree on which forge this checkout uses, and one command library
# never sources another (ARCHITECTURE.md, Scripts layout) — so the decision
# common to them lives here.
jig_forge_kind() {
  local want origin
  want=$(cfg forge auto)
  case "$want" in
    none) printf 'none\n'; return 0 ;;
    auto|github|gitlab) ;;
    *) jig_die "invalid forge: $want (expected auto|github|gitlab|none)" ;;
  esac

  origin=$(git -C "$JIG_PROJECT" remote get-url origin 2>/dev/null || printf '')
  if [ -z "$origin" ]; then
    printf 'none\n'
    return 0
  fi

  if [ "$want" = "auto" ]; then
    want=$(_jig_forge_by_name "$origin")
    if [ "$want" = none ]; then
      want=$(_jig_forge_by_name "$(_jig_ssh_alias_hostname "$origin")")
    fi
    if [ "$want" = none ]; then
      printf 'none\n'
      return 0
    fi
  fi

  case "$want" in
    github)
      if command -v gh >/dev/null 2>&1 && jig_net gh auth status >/dev/null 2>&1; then
        printf 'github\n'
      else
        printf 'none\n'
      fi
      ;;
    gitlab)
      if command -v glab >/dev/null 2>&1 && jig_net glab auth status >/dev/null 2>&1; then
        printf 'gitlab\n'
      else
        printf 'none\n'
      fi
      ;;
  esac
}

# jig_glab_fields <key>... — read `glab ... --output json` on stdin and print
# one tab-separated row of the given string fields per object, skipping an
# object whose first field is empty. `glab` returns a compact single-line
# array, so it is split into one object per line first: a greedy `.*` across
# the whole line would keep only the last merge request. Each field is taken
# at its first occurrence, whatever the key order: nested objects (author,
# assignees) carry a `state` of their own, later on. A key written
# `<key>@<text>` takes the first occurrence whose value contains <text>
# instead: an object's `web_url` comes after its author's. Housekeeping and
# jig_ship_pr both read `glab` through this, so they cannot disagree on it.
jig_glab_fields() {
  sed 's/},[[:space:]]*{/}\
{/g' | awk -v keys="$*" '
    function field(key,   k, need, rest, v) {
      need = ""
      if (index(key, "@")) { need = substr(key, index(key, "@") + 1); key = substr(key, 1, index(key, "@") - 1) }
      k = "\"" key "\":\""
      rest = $0
      while (match(rest, k "[^\"]*\"")) {
        v = substr(rest, RSTART + length(k), RLENGTH - length(k) - 1)
        if (need == "" || index(v, need)) return v
        rest = substr(rest, RSTART + RLENGTH)
      }
      return ""
    }
    BEGIN { n = split(keys, want, " ") }
    {
      row = field(want[1])
      if (row == "") next
      for (i = 2; i <= n; i++) row = row "\t" field(want[i])
      print row
    }'
}

# --- shipping a change ---------------------------------------------------------
#
# The git steps `jig task ship` and `jig spec ship` both take, as far as
# `agent.git` allows (jig_agent_git, config.sh): commit what the agent staged,
# push a branch, open a pull request. Shared here because the two commands must
# never disagree about what may be committed, how a push is made or when a pull
# request is a duplicate, and one command library never sources another
# (ARCHITECTURE.md, Scripts layout). Each caller keeps its own gates — a task's
# knowledge decision and review, a spec's mode — and decides which of these
# steps to take; <who> prefixes every message with the command that was run.
# Nothing here stages, forces a push or skips hooks
# (adr-20260921-agent-git-rights-are-a-local-setting). The one merge, at
# `agent.git: merge`, is jig_ship_merge below, and it merges only a pull
# request whose checks all passed, at the commit that was shipped, through the
# forge's own rules — never --admin, never --auto
# (adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci). The one
# exception is not a ship's: `jig task promote` with git.promote_merge: auto
# switches the forge's auto-merge on where CI gates the base (promote.sh,
# adr-20261112-a-promotion-merges-itself-only-where-ci-gates-it).

# Referenced from the EXIT trap jig_ship_pr sets for the pull request body it
# cuts from a commit message, so it is script-global rather than `local`
# (conventions/shell.md: a trap runs after its function returned). One ship
# runs per dispatch, so this is the only EXIT trap in that process.
_JIG_SHIP_BODY_TMP=""
# The pull request's URL as jig_ship_pr found or opened it; empty when none.
JIG_SHIP_URL=""

# jig_ship_staged — the paths staged in the index, one per line.
jig_ship_staged() {
  git -C "$JIG_PROJECT" diff --cached --name-only 2>/dev/null | sed '/^$/d'
}

# jig_ship_check_staged <who> — refuse, changing nothing, when anything under
# .ai/workspace/ or .ai/runtime/ is staged: those are never committed
# (RULES.md).
jig_ship_check_staged() {
  local who="$1" bad="" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$JIG_AI_DIR/workspace/"* | "$JIG_AI_DIR/runtime/"*) bad="$bad
$p" ;;
    esac
  done <<EOF
$(jig_ship_staged)
EOF
  bad=$(printf '%s\n' "$bad" | sed '/^$/d')
  if [ -n "$bad" ]; then
    jig_die "$who: staged changes under $JIG_AI_DIR/workspace/ or $JIG_AI_DIR/runtime/ are not shippable:
$bad"
  fi
}

# _jig_ship_abs <file> — <file> as an absolute path with symlinks resolved in
# its directory, so a file named through /tmp and through /private/tmp compare
# equal; empty when its directory does not exist.
_jig_ship_abs() {
  local d
  d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 0
  printf '%s/%s\n' "$d" "$(basename "$1")"
}

# jig_ship_untracked [<file>...] — the files git neither tracks nor ignores,
# one per line, leaving out .ai/workspace/, .ai/runtime/ and each <file>
# given: the commit message and the pull request's body are inputs to the
# ship, not part of the change, wherever the caller happened to write them.
jig_ship_untracked() {
  local root p abs f skip
  root=$(cd "$JIG_PROJECT" && pwd -P)
  git -C "$JIG_PROJECT" ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$JIG_AI_DIR/workspace" | "$JIG_AI_DIR/workspace/"* | "$JIG_AI_DIR/runtime" | "$JIG_AI_DIR/runtime/"*) continue ;;
    esac
    abs="$root/$p"
    skip=0
    for f in "$@"; do
      [ -n "$f" ] || continue
      [ "$abs" != "$(_jig_ship_abs "$f")" ] || skip=1
    done
    [ "$skip" -eq 1 ] || printf '%s\n' "$p"
  done
}

# jig_ship_stage_tracked <who> [<file>...] — when nothing is staged, stage the
# change for the caller
# (adr-20261029-task-ship-stages-tracked-changes-and-refuses-new-files).
#
# An empty index at ship time is an agent that forgot `git add`, not a choice
# to ship nothing, and refusing it only sends the agent round to stage and run
# again. So the tracked files' changes are staged here, as `git commit -a`
# would: no new path enters history that way, only new content of files the
# repository already holds. New files are where staging on the agent's behalf
# would cost the most — a secret or a scratch file pushed to the forge is not
# taken back — so any new file that is not ignored refuses, before anything
# is staged, naming each one; the <file>s (message and body) do not count.
# .ai/workspace/ and .ai/runtime/ are never staged (RULES.md). With something
# already staged it does nothing: that index is the caller's choice.
jig_ship_stage_tracked() {
  local who="$1" untracked staged
  shift
  [ -z "$(jig_ship_staged)" ] || return 0
  untracked=$(jig_ship_untracked "$@")
  if [ -n "$untracked" ]; then
    jig_die "$who: nothing is staged, and these files are not tracked by git:
$untracked
A new file is never staged for you: stage the ones that belong to the change (git add <path>), ignore or remove the rest. Once anything is staged, that index is the commit, so stage the changes to tracked files too (git add -u), and run again."
  fi
  git -C "$JIG_PROJECT" add -u -- . \
    ":(exclude)$JIG_AI_DIR/workspace" ":(exclude)$JIG_AI_DIR/runtime" \
    || jig_die "$who: git add -u failed"
  staged=$(jig_ship_staged)
  [ -z "$staged" ] || printf '%s: nothing was staged; staged the tracked changes:\n%s\n' "$who" "$staged"
}

# jig_ship_left_out [<file>...] — what the index would leave in the working
# tree, one path per line: changes to tracked files and new files, but never
# .ai/workspace/, .ai/runtime/ or the <file>s, which are the ship's inputs.
jig_ship_left_out() {
  { git -C "$JIG_PROJECT" diff --name-only -- . \
      ":(exclude)$JIG_AI_DIR/workspace" ":(exclude)$JIG_AI_DIR/runtime" 2>/dev/null
    jig_ship_untracked "$@"; } | sed '/^$/d'
}

# jig_ship_commit <who> <message-file> [<file>...] — commit the index as it
# is: only what is staged, never `-a`; hooks run, never --no-verify. What a
# non-empty index leaves out — tracked changes and new files, but not the
# message or the <file>s — is named in a warning: the commit is what the
# caller staged, and a file left out of it should be visible, not silent.
#
# An empty index used to be an outcome rather than a question: the step
# printed `nothing staged; no commit` and the ship carried on. That is right
# only when there is nothing left to commit — the change was committed by an
# earlier run, and this run pushes it or opens its pull request. When the
# working tree still holds changes to tracked files, the same empty index
# means the opposite: the work is being left behind, and what would be
# shipped is whatever the branch happens to carry already. Nothing about that
# reads as a failure afterwards — at `agent.git: merge` a pull request without
# the change has nothing to make CI red, so it goes green and merges itself.
# So it is a refusal here, before the commit step returns, and not a line in
# the log. Untracked files are warned about here, not refused: a scratch file
# or a build artefact is nobody's shipped change. `task ship` reaches this
# point with an empty index only when jig_ship_stage_tracked found nothing to
# stage and no new file, so the refusal is `spec ship`'s.
jig_ship_commit() {
  local who="$1" message_file="$2" unstaged untracked
  shift 2
  if [ -n "$(jig_ship_staged)" ]; then
    git -C "$JIG_PROJECT" commit -F "$message_file" >/dev/null \
      || jig_die "$who: git commit failed"
    printf 'committed %s\n' "$(git -C "$JIG_PROJECT" rev-parse --short HEAD)"
    unstaged=$(jig_ship_left_out "$message_file" "$@")
    [ -z "$unstaged" ] || jig_warn "$who: these changes are not part of this commit; stage them and ship again if they belong to it:
$unstaged"
    return 0
  fi
  unstaged=$(git -C "$JIG_PROJECT" diff --name-only 2>/dev/null | sed '/^$/d')
  if [ -n "$unstaged" ]; then
    jig_die "$who: nothing is staged, and these tracked files have changes that are not:
$unstaged
Shipping now would carry whatever the branch already holds and leave the change behind. Stage it and run again."
  fi
  untracked=$(jig_ship_untracked "$message_file" "$@")
  [ -z "$untracked" ] || jig_warn "$who: nothing is staged, and these files are not tracked by git:
$untracked"
  printf 'nothing staged; no commit\n'
}

# --- what a ship may send out ------------------------------------------------
#
# Push, the pull request and the merge are the steps that leave this machine,
# and none of them is taken back by noticing afterwards: an empty pull request
# stays in the forge, people and bots see it, somebody closes it by hand, and
# on a public repository it has already happened while the agent is still
# working out what went wrong. An unhelpful message costs a reader a minute;
# an outward step taken too early costs everyone who sees the result.
#
# So the order is an invariant here, not a habit: a ship says what it is
# sending before its first outward step, and every outward step refuses to run
# until it has. Two calls say it, and one of them must:
#
#   jig_ship_require_commits <who> <head> <base> — <head> carries at least one
#       commit <base> does not; otherwise the ship refuses right there, with
#       nothing sent. This is the ordinary case: it is what `task ship` and a
#       spec's declaration and final pull request all send.
#   jig_ship_sends_no_commit <why> — this ship carries no commit on purpose.
#       `spec ship` in `epic` mode pushes an epic branch so that it exists on
#       the forge for its tasks to target, and an epic just cut from the
#       default branch has no commit of its own.
#
# A new outward step inherits the rule by opening with _jig_ship_outward; a
# new call site inherits it by having to say which of the two above it is.
# Observed on 2026-09-24 and again on 2026-09-25: `task ship` printed
# `nothing staged; no commit`, pushed the empty branch anyway and only then
# asked GitHub for a pull request, which is where the run finally stopped —
# by then the forge had already been asked.

# What this ship sends, as a sentence; empty until the ship has said.
_JIG_SHIP_SENDS=""

# _jig_ship_outward <who> — the guard every step that leaves this machine
# opens with. Reaching one without an answer is a mistake in the caller, not
# something a user can cause, so it dies rather than guessing.
_jig_ship_outward() {
  [ -n "$_JIG_SHIP_SENDS" ] \
    || jig_die "$1: internal: a step that leaves this machine was reached before the ship checked what it has to send"
}

# jig_ship_require_commits <who> <head> <base> — refuse, with nothing sent,
# unless <head> has a commit the base does not. The base is read through
# jig_base_ref, so the comparison is the one the forge will make: origin's
# base when it is known here, the local branch otherwise.
jig_ship_require_commits() {
  local who="$1" head="$2" base="$3" base_ref count
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1 \
    || jig_die "$who: $head names no commit in this checkout"
  base_ref=$(jig_base_ref "$base")
  [ -n "$base_ref" ] \
    || jig_die "$who: no branch $base here or on origin, so what $head would add cannot be told; fetch it and run again"
  count=$(git -C "$JIG_PROJECT" rev-list --count "$base_ref..$head" 2>/dev/null) || count=""
  [ -n "$count" ] || jig_die "$who: cannot tell what $head adds to $base_ref"
  if [ "$count" -eq 0 ]; then
    jig_die "$who: nothing to ship: $head has no commit $base_ref does not have.
The index was empty and no earlier run committed, so the branch carries no work.
Nothing has been pushed and no pull request opened: stage the change and run again."
  fi
  _JIG_SHIP_SENDS="$count commit(s) on $head"
}

# jig_ship_sends_no_commit <why> — this ship sends no commit and means to;
# <why> is for the reader of this code, not for the user.
jig_ship_sends_no_commit() {
  _JIG_SHIP_SENDS="no commit: $1"
}

# jig_ship_push <who> <branch> — push <branch> to origin and track it. Never
# --force: a branch origin has moved past is refused by git, and the refusal
# is the answer. Through jig_git_origin: shipping is not a place to sit
# waiting for a credential prompt either, and over HTTPS the push goes as the
# account the pull request is opened as — or, when that account cannot be
# named, nothing is pushed (jig_git_origin_account).
jig_ship_push() {
  local who="$1" branch="$2" out
  _jig_ship_outward "$who"
  jig_git_origin_account "$who" write push
  if ! out=$(jig_net jig_git_origin push -u origin "$branch" 2>&1); then
    jig_die "$who: git push failed:
$out"
  fi
  printf 'pushed %s\n' "$branch"
}

# jig_ship_pr <who> <head> <base> <message-file> [<title>] [<body-file>] [<draft>]
# [<match-base>] — open a pull request from <head> into <base> through
# whichever forge this checkout uses (jig_forge_kind), or report the one
# already open from <head> rather than opening a second. With <match-base> 1
# only one open from <head> into <base> counts: "prepare for prod" must not
# take a task's open pull request into the staging branch for its promotion
# (adr-20261111-prepare-for-prod-opens-the-promotion-from-git-alone). The title defaults to the message's first
# line, the body to the rest of it; <draft> 1 opens it as a draft. With no
# usable forge it says the pull request is the human's and returns 0. Leaves
# the URL in JIG_SHIP_URL, so it is called directly, never in `$()`.
# shellcheck disable=SC2034 # JIG_SHIP_URL is read by the caller
jig_ship_pr() {
  local who="$1" head="$2" base="$3" message_file="$4" title="${5:-}" body_file="${6:-}" draft="${7:-0}" match="${8:-0}" kind
  _jig_ship_outward "$who"
  JIG_SHIP_URL=""
  kind=$(jig_forge_kind) || exit 1
  if [ "$kind" = none ]; then
    printf "no forge available; the pull request is the human's\n"
    return 0
  fi
  [ -n "$title" ] || title=$(head -n 1 "$message_file")
  if [ -z "$body_file" ]; then
    _JIG_SHIP_BODY_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-ship-body.XXXXXX")
    jig_cleanup_add "$_JIG_SHIP_BODY_TMP"
    tail -n +2 "$message_file" > "$_JIG_SHIP_BODY_TMP"
    body_file="$_JIG_SHIP_BODY_TMP"
  fi
  case "$kind" in
    github)
      jig_gh_require "$who"
      _jig_ship_pr_github "$who" "$head" "$base" "$title" "$body_file" "$draft" "$match"
      ;;
    gitlab) _jig_ship_pr_gitlab "$who" "$head" "$base" "$title" "$body_file" "$draft" "$match" ;;
  esac
}

# _jig_ship_pr_github <who> <head> <base> <title> <body-file> <draft> <match-base>
# shellcheck disable=SC2034 # JIG_SHIP_URL is read by the caller
_jig_ship_pr_github() {
  local who="$1" head="$2" base="$3" title="$4" body_file="$5" draft="$6" match="${7:-0}" url out
  local extra="" only=""
  [ "$draft" != 1 ] || extra="--draft"
  [ "$match" != 1 ] || only="--base"
  # shellcheck disable=SC2086 # $only is one flag or nothing, its value follows
  url=$(jig_net jig_gh pr list --head "$head" ${only:+$only "$base"} --state open --json url --jq '.[0].url' 2>/dev/null || printf '')
  case "$url" in '' | null) url="" ;; esac
  if [ -n "$url" ]; then
    JIG_SHIP_URL="$url"
    printf 'pr %s (already open)\n' "$url"
    return 0
  fi
  # shellcheck disable=SC2086 # $extra is one flag or nothing
  out=$(jig_net jig_gh pr create --base "$base" --head "$head" --title "$title" --body-file "$body_file" $extra 2>&1) \
    || jig_die "$who: gh pr create failed:
$out
$(jig_gh_asked_as)"
  url=$(printf '%s\n' "$out" | tail -n 1)
  JIG_SHIP_URL="$url"
  printf 'pr %s\n' "$url"
}

# _jig_ship_pr_gitlab <who> <head> <base> <title> <body-file> <draft>
# <match-base> — the same through `glab`, whose JSON is read by
# jig_glab_fields, the reader housekeeping uses.
# shellcheck disable=SC2034 # JIG_SHIP_URL is read by the caller
_jig_ship_pr_gitlab() {
  local who="$1" head="$2" base="$3" title="$4" body_file="$5" draft="$6" match="${7:-0}" out url desc
  local extra="" only=""
  [ "$draft" != 1 ] || extra="--draft"
  [ "$match" != 1 ] || only="--target-branch"
  out=$(jig_net glab mr list --source-branch "$head" ${only:+$only "$base"} --output json 2>/dev/null || printf '')
  url=$(printf '%s' "$out" | jig_glab_fields web_url | head -n 1)
  if [ -n "$url" ]; then
    JIG_SHIP_URL="$url"
    printf 'pr %s (already open)\n' "$url"
    return 0
  fi
  desc=$(cat "$body_file")
  # shellcheck disable=SC2086 # $extra is one flag or nothing
  out=$(jig_net glab mr create --target-branch "$base" --source-branch "$head" --title "$title" --description "$desc" $extra 2>&1) \
    || jig_die "$who: glab mr create failed:
$out"
  url=$(printf '%s\n' "$out" | grep -oE 'https://[^[:space:]]+' | tail -n 1)
  JIG_SHIP_URL="$url"
  printf 'pr %s\n' "${url:-$out}"
}

# --- merging a shipped pull request ----------------------------------------------
#
# adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci. At
# `agent.git: merge` a ship ends by merging the pull request it opened — only
# when every condition below holds, and otherwise leaving it open with the
# reason. Not merging is an ordinary end, not an error: the forge's branch
# protection and a human review a repository requires are the ceiling a team
# keeps over one contributor's local key, and a red or silent CI is an answer.
# Each caller checks its own gates — a task's findings and receipt, an epic's
# leftovers — right before calling it.

# Set by jig_ship_merge: 1 when it merged, 0 otherwise.
JIG_SHIP_MERGED=0

# The seconds between two looks at a pull request's checks, and how long no
# check at all may mean "not registered yet" rather than "CI checks nothing".
_JIG_CI_POLL=15
_JIG_CI_GRACE=120

# JIG_SHIP_LAST_CHECK — the name of a function the caller wants asked once
# more after CI is green, right before the merge command: what it prints is why
# the merge must not happen now, nothing when it may. Waiting for CI can take
# many minutes, and a fact the caller checked before the wait (a release's
# notes reaching the base's tip) may have stopped being true during it.
JIG_SHIP_LAST_CHECK=""
_jig_ship_last_check() {
  local why
  [ -n "$JIG_SHIP_LAST_CHECK" ] || return 0
  why=$("$JIG_SHIP_LAST_CHECK") || why="the last check before the merge failed"
  [ -n "$why" ] || return 0
  printf 'not merged: %s\n' "$why"
  return 1
}

# jig_ship_merge <who> <url> <sha> <any|merge-commit> — merge the pull request
# at <url>, only as the commit <sha> that was shipped. Prints `merged <url>` or
# `not merged: <reason>` and returns 0 either way; dies (exit 1) only on an
# invalid agent.ci_timeout. The conditions, in order:
#   1. a forge this checkout can use, and a pull request to merge;
#   2. not a draft, and its head is <sha>;
#   3. a merge method the repository allows: `any` takes a merge commit, else
#      squash, else rebase; `merge-commit` takes a merge commit or nothing (an
#      epic, and a task landing on the staging branch: squash and rebase
#      break the ancestry their tasks are judged by, ADR-0040 and
#      adr-20261111-a-task-lands-on-staging-through-its-pull-request);
#   4. at least one check, and every check passed, within agent.ci_timeout
#      minutes — none, a red one or the timeout leaves it open;
#   5. the forge merges it at <sha> (GitHub `--match-head-commit`, GitLab
#      `--sha`) and agrees to: a refusal — branch protection, a required
#      review — leaves it open.
# Never `--admin`, never `--auto`: nothing here overrides the forge or asks it
# to merge later, when nobody is watching the conditions. The one `--auto` is
# the promotion's, only where CI gates the base (promote.sh,
# adr-20261112-a-promotion-merges-itself-only-where-ci-gates-it). Leaves the answer in
# JIG_SHIP_MERGED, so it is called directly, never in `$()`.
jig_ship_merge() {
  local who="$1" url="$2" sha="$3" policy="$4" kind timeout
  _jig_ship_outward "$who"
  JIG_SHIP_MERGED=0
  timeout=$(jig_ci_timeout) || jig_die "$who: invalid agent.ci_timeout: $timeout (expected whole minutes)"
  kind=$(jig_forge_kind) || exit 1
  if [ "$kind" = none ]; then
    printf "not merged: no forge available; the merge is the human's\n"
    return 0
  fi
  if [ -z "$url" ]; then
    printf 'not merged: no pull request to merge\n'
    return 0
  fi
  case "$kind" in
    github)
      jig_gh_require "merge"
      _jig_ship_merge_github "$url" "$sha" "$policy" "$timeout"
      ;;
    gitlab) _jig_ship_merge_gitlab "$url" "$sha" "$policy" "$timeout" ;;
  esac
}

# _jig_ship_ci_wait <timeout-minutes> <reader> <args>... — call <reader>
# <args>... until the checks settle or the timeout passes; the reader prints
# one line, `<passed> <failed> <pending>` (counts). Prints green, red, none
# (nothing was checked) or timeout. No check at all is waited on only for
# _JIG_CI_GRACE seconds — a check registers a little after the push — and a
# timeout of 0 looks once.
_jig_ship_ci_wait() {
  local timeout="$1" reader="$2" start deadline counts passed failed pending now left
  shift 2
  start=$SECONDS
  deadline=$((start + timeout * 60))
  while :; do
    counts=$("$reader" "$@") || counts="0 0 0"
    read -r passed failed pending <<EOF
$counts
EOF
    passed=${passed:-0}
    failed=${failed:-0}
    pending=${pending:-0}
    if [ "$failed" -gt 0 ]; then
      printf 'red\n'
      return 0
    fi
    if [ "$pending" -eq 0 ] && [ "$passed" -gt 0 ]; then
      printf 'green\n'
      return 0
    fi
    now=$SECONDS
    if [ "$pending" -eq 0 ] && [ $((now - start)) -ge "$_JIG_CI_GRACE" ]; then
      printf 'none\n'
      return 0
    fi
    if [ "$now" -ge "$deadline" ]; then
      if [ "$pending" -eq 0 ]; then printf 'none\n'; else printf 'timeout\n'; fi
      return 0
    fi
    left=$((deadline - now))
    [ "$left" -le "$_JIG_CI_POLL" ] || left=$_JIG_CI_POLL
    sleep "$left"
  done
}

# _jig_ship_ci_reason <state> <timeout> — the `not merged:` text for a CI
# state other than green.
_jig_ship_ci_reason() {
  case "$1" in
    red) printf 'a check failed\n' ;;
    none) printf 'CI checked nothing: no check ran on the pull request\n' ;;
    *) printf 'the checks did not finish within %s minutes (agent.ci_timeout)\n' "$2" ;;
  esac
}

# _jig_ship_first_line <text> — the first non-empty line, for a refusal.
_jig_ship_first_line() {
  printf '%s\n' "$1" | awk '!f && /[^[:space:]]/ { print; f = 1 }'
}

# _jig_ship_checks_github <url> — `<passed> <failed> <pending>` for the pull
# request's checks. A skipped check counts as neither; a cancelled one as
# failed. An error reading them reads as no checks, never as passed.
_jig_ship_checks_github() {
  local out
  out=$(jig_gh pr checks "$1" --json bucket --jq '.[].bucket' 2>/dev/null) || true
  printf '%s\n' "$out" | awk '
    $1 == "pass" { p++ }
    $1 == "fail" || $1 == "cancel" { f++ }
    $1 == "pending" { w++ }
    END { printf "%d %d %d\n", p, f, w }'
}

# _jig_ship_merge_github <url> <sha> <policy> <timeout>
# shellcheck disable=SC2034 # JIG_SHIP_MERGED is read by the caller
_jig_ship_merge_github() {
  local url="$1" sha="$2" policy="$3" timeout="$4" view draft="" head="" allowed m="" s="" r="" method state out
  if ! view=$(jig_gh pr view "$url" --json isDraft,headRefOid --jq '"\(.isDraft) \(.headRefOid)"' 2>/dev/null); then
    printf 'not merged: could not read the pull request\n'
    return 0
  fi
  read -r draft head <<EOF
$view
EOF
  if [ "$draft" != false ]; then
    printf 'not merged: the pull request is a draft\n'
    return 0
  fi
  if [ "$head" != "$sha" ]; then
    printf 'not merged: the pull request is at %s, not at the shipped %s\n' "${head:-an unknown commit}" "$sha"
    return 0
  fi
  allowed=$(jig_gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed \
    --jq '"\(.mergeCommitAllowed) \(.squashMergeAllowed) \(.rebaseMergeAllowed)"' 2>/dev/null) || allowed=""
  read -r m s r <<EOF
$allowed
EOF
  method=""
  if [ "$m" = true ]; then
    method=merge
  elif [ "$policy" = any ] && [ "$s" = true ]; then
    method=squash
  elif [ "$policy" = any ] && [ "$r" = true ]; then
    method=rebase
  fi
  if [ -z "$method" ]; then
    if [ "$policy" = merge-commit ] && [ -n "$allowed" ]; then
      printf 'not merged: the repository does not allow merge commits, and this merge keeps its ancestry only with one\n'
    else
      printf 'not merged: could not tell which merge method the repository allows\n'
    fi
    return 0
  fi
  state=$(_jig_ship_ci_wait "$timeout" _jig_ship_checks_github "$url")
  if [ "$state" != green ]; then
    printf 'not merged: %s\n' "$(_jig_ship_ci_reason "$state" "$timeout")"
    return 0
  fi
  _jig_ship_last_check || return 0
  if ! out=$(jig_gh pr merge "$url" --match-head-commit "$sha" "--$method" 2>&1); then
    printf 'not merged: the forge refused: %s\n' "$(_jig_ship_first_line "$out")"
    return 0
  fi
  JIG_SHIP_MERGED=1
  printf 'merged %s\n' "$url"
}

# _jig_ship_glab_mr <url> — the merge request's iid from its web URL, or
# nothing when the URL is not one.
_jig_ship_glab_mr() {
  local iid="${1##*/merge_requests/}"
  iid=${iid%%[/?#]*}
  case "$iid" in '' | *[!0-9]*) return 0 ;; esac
  printf '%s\n' "$iid"
}

# _jig_ship_glab_pipeline <json> — `<status> <sha>` of the merge request's
# head pipeline, or nothing when it has none (`"head_pipeline":null`). Its
# fields are read up to its first nested object; status and sha come first.
_jig_ship_glab_pipeline() {
  local obj status psha
  obj=$(printf '%s' "$1" | tr '\n' ' ' | sed -n 's/.*"head_pipeline":[[:space:]]*{\([^}]*\).*/\1/p')
  [ -n "$obj" ] || return 0
  status=$(printf '%s' "$obj" | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p')
  psha=$(printf '%s' "$obj" | sed -n 's/.*"sha":[[:space:]]*"\([^"]*\)".*/\1/p')
  printf '%s %s\n' "${status:-unknown}" "${psha:--}"
}

# _jig_ship_checks_gitlab <iid> <sha> — `<passed> <failed> <pending>` for the
# merge request's head pipeline, the one check GitLab reports on it: a
# pipeline for another commit is still pending for <sha>; a skipped one
# checked nothing.
_jig_ship_checks_gitlab() {
  local json pipe status="" psha=""
  json=$(glab mr view "$1" --output json 2>/dev/null) || json=""
  pipe=$(_jig_ship_glab_pipeline "$json")
  if [ -z "$pipe" ]; then
    printf '0 0 0\n'
    return 0
  fi
  read -r status psha <<EOF
$pipe
EOF
  if [ "$psha" != "$2" ]; then
    printf '0 0 1\n'
    return 0
  fi
  case "$status" in
    success) printf '1 0 0\n' ;;
    failed | canceled | canceling) printf '0 1 0\n' ;;
    skipped) printf '0 0 0\n' ;;
    *) printf '0 0 1\n' ;;
  esac
}

# _jig_ship_merge_gitlab <url> <sha> <policy> <timeout> — the same through
# `glab`. GitLab sets the method per project (merge_method, squash_option):
# `merge-commit` needs a merge commit and a squash that is off by default, and
# plain `merge`: semi-linear history (`rebase_merge`) merges only a source
# branch level with the target, and its "Rebase" rewrites the commits whose
# ancestry the merge is kept for.
# shellcheck disable=SC2034 # JIG_SHIP_MERGED is read by the caller
_jig_ship_merge_gitlab() {
  local url="$1" sha="$2" policy="$3" timeout="$4" iid json project mm so squash="" state out
  iid=$(_jig_ship_glab_mr "$url")
  if [ -z "$iid" ]; then
    printf 'not merged: could not read the merge request from %s\n' "$url"
    return 0
  fi
  if ! json=$(glab mr view "$iid" --output json 2>/dev/null); then
    printf 'not merged: could not read the merge request\n'
    return 0
  fi
  case "$(printf '%s' "$json" | tr -d ' \n')" in
    *'"draft":true'* | *'"work_in_progress":true'*)
      printf 'not merged: the merge request is a draft\n'
      return 0 ;;
  esac
  project=$(glab api "projects/:id" 2>/dev/null | tr '\n' ' ') || project=""
  mm=$(printf '%s' "$project" | sed -n 's/.*"merge_method":[[:space:]]*"\([^"]*\)".*/\1/p')
  so=$(printf '%s' "$project" | sed -n 's/.*"squash_option":[[:space:]]*"\([^"]*\)".*/\1/p')
  case "$policy:$mm:$so" in
    merge-commit:merge:never | merge-commit:merge:default_off) ;;
    merge-commit:?*:?*)
      printf 'not merged: the project does not merge with a merge commit, and this merge keeps its ancestry only with one\n'
      return 0 ;;
    any:?*:always | any:?*:default_on) squash="--squash" ;;
    any:?*:?*) ;;
    *)
      printf 'not merged: could not tell which merge method the project allows\n'
      return 0 ;;
  esac
  state=$(_jig_ship_ci_wait "$timeout" _jig_ship_checks_gitlab "$iid" "$sha")
  if [ "$state" != green ]; then
    printf 'not merged: %s\n' "$(_jig_ship_ci_reason "$state" "$timeout")"
    return 0
  fi
  _jig_ship_last_check || return 0
  # --auto-merge=false: merge now or not at all, never "once the pipeline
  # succeeds", later, when nobody checks the conditions again.
  # shellcheck disable=SC2086 # $squash is one flag or nothing
  if ! out=$(glab mr merge "$iid" --sha "$sha" --yes --auto-merge=false $squash 2>&1); then
    printf 'not merged: the forge refused: %s\n' "$(_jig_ship_first_line "$out")"
    return 0
  fi
  JIG_SHIP_MERGED=1
  printf 'merged %s\n' "$url"
}

# jig_pr_state <url> — merged|open|closed|unknown for the pull/merge request at
# <url>, read live from whichever forge this checkout uses. `unknown` is the
# safe answer whenever the state cannot be confirmed: no forge configured, the
# read fails, or the forge reports something this checkout does not recognise
# — a caller deciding whether work has landed must never read `unknown` as
# `merged` (autopilot-end-closes-unmerged-task; ADR-0005 keeps merge state out
# of `state` for the same reason: it is asked for, never trusted from disk).
#
# Shared rather than kept in task.sh: `task set status consolidated` and
# housekeeping's remote-state tier both have to ask the same question of the
# same forge, and one command library never sources another (ARCHITECTURE.md,
# Scripts layout).
jig_pr_state() {
  local __jps_state __jps_why
  jig_pr_state_v __jps_state __jps_why "$1"
  printf '%s\n' "$__jps_state"
}

# jig_pr_state_v <state-var> <why-var> <url> — jig_pr_state into <state-var>,
# and into <why-var> why the forge could not be asked when the state is
# `unknown`: the first line of gh's or glab's error (a cut-off call says so
# itself, jig_net), the account gh could not be given, the forge this clone
# has none of, or what the forge answered that is not a state. Empty for any
# other state, and for an empty <url>. Run in the caller's shell, never in
# `$(...)`, or the cause is lost with the subshell; it costs no forge call
# beyond the one jig_pr_state makes.
jig_pr_state_v() {
  local __jpsv_kind __jpsv_s="unknown" __jpsv_w=""
  if [ -n "$3" ]; then
    __jpsv_kind=$(jig_forge_kind) || exit 1
    case "$__jpsv_kind" in
      github)
        jig_gh_prepare "pull request state"
        _jig_pr_state_ask github "$3"
        if [ "$__jpsv_s" = unknown ] && [ "$_JIG_GH_STATE" = refused ] && [ -n "$_JIG_GH_WHY" ]; then
          __jpsv_w="${__jpsv_w:+$__jpsv_w; }gh account: $_JIG_GH_WHY"
        fi
        ;;
      gitlab) _jig_pr_state_ask gitlab "$3" ;;
      *) __jpsv_w=$(_jig_pr_state_no_forge) ;;
    esac
  fi
  printf -v "$1" '%s' "$__jpsv_s"
  printf -v "$2" '%s' "$__jpsv_w"
}

# _jig_pr_state_ask <github|gitlab> <url> — ask the forge; sets the caller's
# __jpsv_s and __jpsv_w (jig_pr_state_v). The error goes to a file of its own,
# so a warning gh prints on a call that succeeds never reaches the answer.
_jig_pr_state_ask() {
  local forge="$1" url="$2" err out rc=0 iid raw cli
  err=$(mktemp "${TMPDIR:-/tmp}/jig-pr-state.XXXXXX") || { __jpsv_w="no temporary file for the forge's answer"; return 0; }
  jig_cleanup_add "$err"
  if [ "$forge" = github ]; then
    cli=gh
    out=$(jig_net jig_gh pr view "$url" --json state --jq .state 2>"$err") || rc=$?
    raw=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')
  else
    cli=glab
    iid=$(_jig_ship_glab_mr "$url")
    if [ -z "$iid" ]; then
      rm -f "$err"
      __jpsv_w="no merge request number in $url"
      return 0
    fi
    out=$(jig_net glab mr view "$iid" --output json 2>"$err") || rc=$?
    raw=$(printf '%s' "$out" | tr -d ' \n' | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
    [ "$raw" != opened ] || raw=open
  fi
  if [ "$rc" -ne 0 ]; then
    __jpsv_w=$(_jig_ship_first_line "$(cat "$err")")
    [ -n "$__jpsv_w" ] || __jpsv_w="$cli exited $rc with no message"
    case "$__jpsv_w" in
      "$cli"*) ;;
      *) __jpsv_w="$cli: $__jpsv_w" ;;
    esac
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  case "$raw" in
    merged | open | closed) __jpsv_s=$raw ;;
    *) __jpsv_w="$cli answered '${raw:-nothing}', which is no pull request state" ;;
  esac
}

# _jig_pr_state_no_forge — why jig_forge_kind answered `none`, worked out here
# without asking the forge: the setting, the origin, or the forge's CLI missing
# from PATH (a program started outside a login shell may not see it) or not
# signed in.
_jig_pr_state_no_forge() {
  local want origin cli
  want=$(cfg forge auto)
  if [ "$want" = none ]; then
    printf 'no forge configured (forge: none)\n'
    return 0
  fi
  origin=$(git -C "$JIG_PROJECT" remote get-url origin 2>/dev/null || printf '')
  if [ -z "$origin" ]; then
    printf 'no forge configured: this clone has no origin remote\n'
    return 0
  fi
  if [ "$want" = auto ]; then
    want=$(_jig_forge_by_name "$origin")
    [ "$want" != none ] || want=$(_jig_forge_by_name "$(_jig_ssh_alias_hostname "$origin")")
  fi
  case "$want" in
    github) cli=gh ;;
    gitlab) cli=glab ;;
    *)
      printf 'no forge configured: origin is on no forge Jig knows; set forge to github or gitlab\n'
      return 0 ;;
  esac
  if ! command -v "$cli" >/dev/null 2>&1; then
    printf '%s is not on PATH\n' "$cli"
  else
    printf '%s is not signed in: %s auth status failed\n' "$cli" "$cli"
  fi
}

# --- what landing on the staging branch asks the forge -------------------------
#
# adr-20261111-a-task-lands-on-staging-through-its-pull-request. Three questions
# about one open pull request, each answered `unknown` (or a failure) whenever
# the forge cannot say: an unknown is never read as approved, as clean, or as
# commented. On GitHub each asks through jig_gh, as this clone's account
# (adr-20261110-a-clone-names-its-github-account); the caller resolves it first,
# in its own shell (land_task: jig_gh_require), since these run in `$()`.

# jig_pr_approval <url> — approved|changes|none|unknown: whether somebody
# approved the pull request. GitHub: `reviewDecision` when branch protection
# asks for reviews; when it does not, the decision is empty even for an
# approved pull request, so the latest review of each reviewer decides —
# changes requested by anyone wins over an approval. GitLab: who approved
# (`approved_by`), never `approved`, which is true with no approval at all
# when the project requires none.
jig_pr_approval() {
  local url="$1" kind out decision reviews iid
  [ -n "$url" ] || { printf 'unknown\n'; return 0; }
  kind=$(jig_forge_kind) || exit 1
  case "$kind" in
    github)
      out=$(jig_net jig_gh pr view "$url" --json reviewDecision,latestReviews \
        --jq '"\(.reviewDecision // "")|\([.latestReviews[]?.state] | join(","))"' 2>/dev/null) \
        || { printf 'unknown\n'; return 0; }
      decision=${out%%|*}
      reviews=${out#*|}
      case "$decision" in
        APPROVED) printf 'approved\n' ;;
        CHANGES_REQUESTED) printf 'changes\n' ;;
        REVIEW_REQUIRED) printf 'none\n' ;;
        '' | null)
          case ",$reviews," in
            *,CHANGES_REQUESTED,*) printf 'changes\n' ;;
            *,APPROVED,*) printf 'approved\n' ;;
            *) printf 'none\n' ;;
          esac ;;
        *) printf 'unknown\n' ;;
      esac ;;
    gitlab)
      iid=$(_jig_ship_glab_mr "$url")
      [ -n "$iid" ] || { printf 'unknown\n'; return 0; }
      out=$(jig_net glab api "projects/:id/merge_requests/$iid/approvals" 2>/dev/null | tr -d ' \n') \
        || { printf 'unknown\n'; return 0; }
      case "$out" in
        *'"approved_by":[]'*) printf 'none\n' ;;
        *'"approved_by":[{'*) printf 'approved\n' ;;
        *) printf 'unknown\n' ;;
      esac ;;
    *) printf 'unknown\n' ;;
  esac
}

# _jig_pr_mergeable_once <kind> <url> — clean|conflict|draft|unknown, one look.
_jig_pr_mergeable_once() {
  local kind="$1" url="$2" out iid draft state
  case "$kind" in
    github)
      out=$(jig_net jig_gh pr view "$url" --json isDraft,mergeable --jq '"\(.isDraft) \(.mergeable)"' 2>/dev/null) \
        || { printf 'unknown\n'; return 0; }
      read -r draft state <<EOF
$out
EOF
      if [ "$draft" = true ]; then printf 'draft\n'; return 0; fi
      case "$state" in
        MERGEABLE) printf 'clean\n' ;;
        CONFLICTING) printf 'conflict\n' ;;
        *) printf 'unknown\n' ;;
      esac ;;
    gitlab)
      iid=$(_jig_ship_glab_mr "$url")
      [ -n "$iid" ] || { printf 'unknown\n'; return 0; }
      out=$(jig_net glab mr view "$iid" --output json 2>/dev/null | tr -d ' \n') \
        || { printf 'unknown\n'; return 0; }
      case "$out" in
        *'"draft":true'* | *'"work_in_progress":true'*) printf 'draft\n'; return 0 ;;
      esac
      state=$(printf '%s' "$out" | sed -n 's/.*"detailed_merge_status":"\([^"]*\)".*/\1/p')
      case "$out:$state" in
        *'"has_conflicts":true'*) printf 'conflict\n' ;;
        *:conflict) printf 'conflict\n' ;;
        *:checking | *:unchecked | *:preparing | *:approvals_syncing) printf 'unknown\n' ;;
        *'"has_conflicts":false'*) printf 'clean\n' ;;
        *) printf 'unknown\n' ;;
      esac ;;
    *) printf 'unknown\n' ;;
  esac
}

# jig_pr_mergeable <url> — clean|conflict|draft|unknown: whether the pull
# request merges into its base without a conflict, as the forge, which would
# merge it, computes it. The forge works it out a little after a push, so an
# unknown is looked at again every _JIG_CI_POLL seconds for up to a minute —
# no longer than agent.ci_timeout allows, and once at a timeout of 0.
jig_pr_mergeable() {
  local url="$1" kind timeout start limit state
  [ -n "$url" ] || { printf 'unknown\n'; return 0; }
  kind=$(jig_forge_kind) || exit 1
  timeout=$(jig_ci_timeout) || timeout=0
  limit=60
  [ $((timeout * 60)) -ge "$limit" ] || limit=$((timeout * 60))
  start=$SECONDS
  while :; do
    state=$(_jig_pr_mergeable_once "$kind" "$url")
    [ "$state" = unknown ] || break
    [ $((SECONDS - start + _JIG_CI_POLL)) -le "$limit" ] || break
    sleep "$_JIG_CI_POLL"
  done
  printf '%s\n' "$state"
}

# jig_pr_comment <url> <body-file> — add a comment to the pull request. Non-zero,
# printing the forge's first line, when it cannot: a comment is said, never
# retried, and what it carries is also in git.
jig_pr_comment() {
  local url="$1" body="$2" kind out iid
  kind=$(jig_forge_kind) || exit 1
  case "$kind" in
    github)
      out=$(jig_net jig_gh pr comment "$url" --body-file "$body" 2>&1) || { _jig_ship_first_line "$out"; return 1; } ;;
    gitlab)
      iid=$(_jig_ship_glab_mr "$url")
      [ -n "$iid" ] || { printf 'not a merge request: %s\n' "$url"; return 1; }
      out=$(jig_net glab mr note "$iid" --message "$(cat "$body")" 2>&1) || { _jig_ship_first_line "$out"; return 1; } ;;
    *) printf 'no forge available\n'; return 1 ;;
  esac
  return 0
}

# --- merged branches ---------------------------------------------------------
#
# A branch whose work has landed leaves with it
# (adr-20261007-a-merged-branch-leaves-with-its-work): right after a merge Jig
# made itself (jig_ship_leave), and in housekeeping once the task it belonged
# to is purged (_hk_branch_sweep). This is the one place a branch is deleted,
# and git does the deleting: `git branch -d` first, so git itself refuses a
# branch whose commits are on neither its upstream nor HEAD; past a refusal
# only a branch whose tip is in the head of a pull request the forge reported
# merged, by a ref update guarded by that tip
# (adr-20261010-a-gone-upstream-defers-to-the-merged-head); and on origin a
# push with a lease at the merged commit, so a branch somebody pushed to after
# the merge stays. RULES.md names this site in its deletion paragraph.

# jig_branch_is_jigs <branch> — exit 0 when <branch> is a name Jig gives its
# own branches: `jig/upgrade-*` (jig upgrade), `finish/<id>` (spec ship's
# finish), `close/<id>` (spec ship's removal of an epic-less spec) or the name
# `git.branch_template` gives a valid task id. A template with no literal text
# before `{id}` names no branch as Jig's: every branch whose name is a valid id
# would match it. Never an epic (`epic/*`, ADR-0040)
# or a spec branch (`spec/*`): those are the bases tasks are judged against,
# and never the project's base branch, whatever it is called.
jig_branch_is_jigs() {
  local b="$1" template prefix suffix mid
  [ -n "$b" ] || return 1
  [ "$b" != "$(cfg git.base_branch main)" ] || return 1
  case "$b" in
    epic/* | spec/*) return 1 ;;
    jig/upgrade-?*) return 0 ;;
    finish/*) jig_valid_id "${b#finish/}"; return ;;
    close/*) jig_valid_id "${b#close/}"; return ;;
  esac
  template=$(cfg git.branch_template "task/{id}")
  case "$template" in
    *'{id}'*) ;;
    *) return 1 ;;
  esac
  prefix=${template%%'{id}'*}
  suffix=${template#*'{id}'}
  [ -n "$prefix" ] || return 1
  case "$b" in
    "$prefix"*"$suffix") ;;
    *) return 1 ;;
  esac
  mid=${b#"$prefix"}
  mid=${mid%"$suffix"}
  jig_valid_id "$mid"
}

# jig_branch_deletable <branch> — exit 0 when <branch> is Jig's to delete once
# its work has landed: a name jig_branch_is_jigs calls Jig's, or, under a
# `git.branch_template` with nothing before `{id}`, a branch a task record says
# Jig made (jig_branch_recorded). Asked by the three sites that delete —
# _hk_branch_sweep, jig_branch_leave, jig_ship_leave — and by nothing else:
# jig_branch_is_jigs keeps its meaning for the readers that want upgrade
# branches only (adr-20261007-a-merged-branch-leaves-with-its-work, amended
# 2026-11-09).
jig_branch_deletable() {
  local template
  jig_branch_is_jigs "$1" && return 0
  # Never the base branch, whatever a record says.
  [ "$1" != "$(cfg git.base_branch main)" ] || return 1
  template=$(cfg git.branch_template "task/{id}")
  case "$template" in
    '{id}'*) ;;
    *) return 1 ;;
  esac
  # Under git.branch_per_task: false Jig cuts no branch: `task start` records
  # the one the person is on, and a task named after it — PROJ-123 started on
  # the person's own PROJ-123 — would pass the name check. No record vouches
  # for a branch there.
  cfg_bool git.branch_per_task true || return 1
  jig_branch_recorded "$1"
}

# The branches task records name as Jig's, one per line, read once per process
# by jig_branch_recorded; _JIG_RECORDED_READ=0 asks for a fresh read, as the
# sweep does after its run moved workspaces to trash.
_JIG_RECORDED_BRANCHES=""
_JIG_RECORDED_READ=0

# jig_branch_recorded <branch> — exit 0 when a task's `state`, in the workspace
# or in trash under any date, records <branch> as the task's branch, and
# <branch> is the name `git.branch_template` gives that record's own id. Only
# `task start` writes `branch:`, and it refuses a branch that already exists,
# so the record names a branch Jig cut — except under `git.branch_per_task:
# false`, where it records the branch the person was on, which is why
# jig_branch_deletable does not ask here in that mode. The name check keeps out
# a record of a branch other than the task's own. A trash directory may carry
# a `-<n>` suffix (jig_trash_dest), so there its name is tried without it too.
# A name that is not a valid id never counts (RULES.md). The state is read
# with awk, not task.sh's reader: common.sh is loaded where task.sh is not.
jig_branch_recorded() {
  local b="$1" template suffix ai where dir branch id tail
  [ -n "$b" ] || return 1
  if [ "$_JIG_RECORDED_READ" != 1 ]; then
    _JIG_RECORDED_BRANCHES=""
    template=$(cfg git.branch_template "task/{id}")
    suffix=""
    case "$template" in
      *'{id}'*) suffix=${template#*'{id}'} ;;
    esac
    ai="$JIG_PROJECT/$JIG_AI_DIR"
    while IFS="$(printf '\t')" read -r where dir branch; do
      [ -n "$dir" ] && [ -n "$branch" ] || continue
      for id in "$dir" "-"; do
        if [ "$id" = "-" ]; then
          # The trash's collision suffix: `<id>-<n>`, digits only.
          [ "$where" = trash ] || continue
          tail=${dir##*-}
          case "$tail" in
            '' | *[!0-9]*) continue ;;
          esac
          [ "$tail" != "$dir" ] || continue
          id=${dir%-*}
        fi
        jig_valid_id "$id" || continue
        if [ "$branch" = "$id$suffix" ]; then
          _JIG_RECORDED_BRANCHES="$_JIG_RECORDED_BRANCHES$branch
"
          break
        fi
      done
    done < <(_jig_state_branches "$ai")
    _JIG_RECORDED_READ=1
  fi
  jig_has_line "$b" "$_JIG_RECORDED_BRANCHES"
}

# _jig_state_branches <ai-dir> — one line per task state that records a
# branch: `<workspace|trash><TAB><directory name><TAB><branch>`. A function of
# its own so the process substitution that reads it holds a single call:
# bash 3.2 re-parses the text of a process substitution when it runs it, and
# trips over a case pattern or a quote in a comment there.
_jig_state_branches() {
  local ai="$1" f where
  for f in "$ai"/workspace/tasks/*/state "$ai"/runtime/trash/*/*/state; do
    [ -f "$f" ] || continue
    case "$f" in
      "$ai"/runtime/trash/*) where=trash ;;
      *) where=workspace ;;
    esac
    awk -v w="$where" -v d="$(basename "$(dirname "$f")")" '
      /^branch:/ { v = $0; sub(/^branch:[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v); print w "\t" d "\t" v; exit }
    ' "$f" 2>/dev/null || true
  done
}

# jig_branch_checked_out <branch> — exit 0 when <branch> is checked out in any
# worktree of this clone, this checkout included; also when git cannot list
# them: an unanswered question keeps the branch.
jig_branch_checked_out() {
  local list
  list=$(git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null) || return 0
  jig_has_line "branch refs/heads/$1" "$list"
}

# jig_branch_leave <who> <branch> <remote-sha> [<merged-head>] — delete
# <branch> here, then on origin, and say so; or keep it and say why.
# <remote-sha> is the head of the pull request the forge reported merged, or
# empty: without one, origin is never touched. <merged-head> is that head again
# for the local branch alone (default: <remote-sha>); housekeeping passes it
# when origin no longer has the branch and <remote-sha> is therefore empty.
# One line per outcome, prefixed with <who>:
#   deleted branch <b> | deleted branch <b> on origin | kept branch <b>: <why>
#
# The order is the safety. The local branch goes first, while origin/<b> — its
# upstream, at the commit that was pushed — still exists: `git branch -d`
# checks a branch against its upstream when it has one, so a squash-merged
# branch passes, and a branch with a commit origin never saw is refused. A
# refusal keeps origin's copy too. Only then origin: `--force-with-lease` at
# <remote-sha> deletes the branch only while it is still at the commit the
# forge merged. When the forge already deleted it (GitHub's "automatically
# delete head branches"), the lease fails; `ls-remote` confirms the branch is
# gone, and only then the stale origin/<b> is dropped — a cache, not work.
#
# When origin/<b> is already gone — somebody else's `fetch --prune` took it
# after the forge deleted the branch — `-d` compares with HEAD and refuses a
# squash-merged branch. Then, and only with <merged-head>, a branch whose tip
# is that head or an ancestor of it goes anyway: every commit on it is in the
# pull request that was merged. `update-ref -d` with the tip as the old value
# deletes it only while it is still there; a tip with a commit past the head
# is kept.
#
# Off with `git.delete_merged_branches: false`. Returns 0 always: keeping a
# branch is an outcome, never a failure of the command that called this.
jig_branch_leave() {
  local who="$1" b="$2" sha="$3" merged="${4-$3}" out tip
  cfg_bool git.delete_merged_branches true || return 0
  jig_branch_deletable "$b" || return 0
  if jig_branch_checked_out "$b"; then
    printf '%s: kept branch %s: it is checked out in a worktree\n' "$who" "$b"
    return 0
  fi
  if git -C "$JIG_PROJECT" show-ref --verify --quiet "refs/heads/$b"; then
    if ! git -C "$JIG_PROJECT" branch -q -d "$b" >/dev/null 2>&1; then
      tip=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$b^{commit}" 2>/dev/null || true)
      case "$merged" in
        *[!0-9a-f]*) merged="" ;;
      esac
      # `-d` refuses a checked-out branch; update-ref would not, so ask again.
      if [ -z "$merged" ] || [ -z "$tip" ] || jig_branch_checked_out "$b" \
         || ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$tip" "$merged" >/dev/null 2>&1 \
         || ! git -C "$JIG_PROJECT" update-ref -d "refs/heads/$b" "$tip" >/dev/null 2>&1; then
        printf '%s: kept branch %s: git does not see all of its commits merged\n' "$who" "$b"
        return 0
      fi
      git -C "$JIG_PROJECT" config --remove-section "branch.$b" >/dev/null 2>&1 || true
    fi
    printf '%s: deleted branch %s\n' "$who" "$b"
  fi
  [ -n "$sha" ] || return 0
  git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1 || return 0
  jig_git_origin_account "$who" read push
  out=$(jig_branches_leave_origin "$who" "$b" "$sha")
  case "$out" in
    *": deleted branch $b on origin")
      printf '%s\n' "$out"
      return 0
      ;;
  esac
  if out=$(jig_git_origin ls-remote --heads origin "refs/heads/$b" 2>/dev/null) && [ -z "$out" ]; then
    git -C "$JIG_PROJECT" branch -q -d -r "origin/$b" >/dev/null 2>&1 || true
    return 0
  fi
  printf '%s: kept branch %s on origin: it is no longer at the merged commit, or origin refused\n' "$who" "$b"
  return 0
}

# jig_branches_leave_origin <who> <branch> <sha> [<branch> <sha> ...] — delete
# each <branch> on origin while it is still at its <sha>, all in one push, and
# say for each: `<who>: deleted branch <b> on origin` or `<who>: kept branch <b>
# on origin: <why>`. The one place Jig deletes a branch on origin; the caller
# has already let the local branch go (jig_branch_leave says why that order).
#
# One push, not one per branch: over HTTPS every network call goes through the
# credential helper, and a helper that asks the person (a Keychain dialog
# GIT_TERMINAL_PROMPT=0 does not stop) asked once per branch (issue #317).
# Without --atomic, so a lease that fails for one branch holds back no other;
# --porcelain reports each ref, `-` deleted and `!` rejected. A ref with no
# line — the push failed as a whole — is kept. Returns 0 always.
jig_branches_leave_origin() {
  local who="$1" out b leases=() refs=()
  shift
  while [ "$#" -ge 2 ]; do
    leases+=("--force-with-lease=refs/heads/$1:$2")
    refs+=("$1")
    shift 2
  done
  [ "${#refs[@]}" -gt 0 ] || return 0
  jig_git_origin_account "$who" read push
  out=$(jig_git_origin push --porcelain "${leases[@]}" origin "${refs[@]/#/:refs/heads/}" 2>/dev/null || true)
  for b in "${refs[@]}"; do
    if printf '%s\n' "$out" | awk -F '\t' -v r=":refs/heads/$b" \
         '$1 == "-" && $2 == r { found = 1 } END { exit !found }'; then
      printf '%s: deleted branch %s on origin\n' "$who" "$b"
    else
      printf '%s: kept branch %s on origin: it is no longer at the merged commit, or origin refused\n' "$who" "$b"
    fi
  done
  return 0
}

# Set by jig_ship_leave: the branch this checkout was moved to, or empty.
# shellcheck disable=SC2034 # read by the callers (upgrade.sh)
JIG_SHIP_BACK_ON=""

# jig_ship_leave <who> <branch> <base> <sha> — after a merge this run made
# (JIG_SHIP_MERGED=1), put this checkout back on <base>, bring <base> up to
# origin's by fast-forward, and let <branch> go (jig_branch_leave) with <sha>,
# the commit the forge merged at (`--match-head-commit`, `--sha`). Where this
# checkout cannot leave the branch — <base> is checked out in another worktree,
# or this checkout is a linked worktree, as it is when a task ships from its
# own — the branch stays, local and remote, for housekeeping to take once the
# task is purged: deleting origin's copy first would leave a squash-merged
# local branch that `-d` refuses.
jig_ship_leave() {
  local who="$1" b="$2" base="$3" sha="$4" cur
  JIG_SHIP_BACK_ON=""
  [ "$JIG_SHIP_MERGED" = 1 ] || return 0
  cfg_bool git.delete_merged_branches true || return 0
  jig_branch_deletable "$b" || return 0
  [ "$b" != "$base" ] || return 0
  cur=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ "$cur" = "$b" ]; then
    # A linked worktree is never moved: housekeeping finds a task's worktree
    # by the branch git lists in it, and one switched to the base would be
    # found by nothing and stay for good. Its branch waits for that cleanup.
    if [ "$(jig_config_clone_root)" != "$JIG_PROJECT" ]; then
      printf '%s: kept branch %s: it is checked out in this worktree; housekeeping deletes both once its task is closed\n' "$who" "$b"
      return 0
    fi
    if ! git -C "$JIG_PROJECT" checkout -q "$base" >/dev/null 2>&1; then
      printf '%s: kept branch %s: this checkout cannot switch to %s; housekeeping deletes it once its task is closed\n' "$who" "$b" "$base"
      return 0
    fi
    # shellcheck disable=SC2034 # read by the callers (upgrade.sh)
    JIG_SHIP_BACK_ON="$base"
    jig_fetch_branches "$who" "$base"
    if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null 2>&1 \
       && ! git -C "$JIG_PROJECT" merge --ff-only -q "refs/remotes/origin/$base" >/dev/null 2>&1; then
      printf '%s: back on %s, which could not be fast-forwarded to origin/%s\n' "$who" "$base" "$base"
    else
      printf '%s: back on %s\n' "$who" "$base"
    fi
  fi
  jig_branch_leave "$who" "$b" "$sha"
}

# --- specification links ------------------------------------------------------

# jig_spec_link <task.md> — the spec id a task links to, or nothing.
#
# A link is a whole line `Spec: .ai/specs/<id>/`, optionally followed by a
# dash and `Phase <n>`. A line whose id breaks the id grammar links to
# nothing. Exits 2 when the file links to two different specs: which roadmap
# to read would be a guess. Here rather than in spec.sh because `task start`
# needs it too, and one command library never sources another.
jig_spec_link() {
  local id rc=0
  jig_spec_link_v id "$1" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -z "$id" ] || printf '%s\n' "$id"
}

# jig_spec_link_v <var> <task.md> — the same id into <var>, read in the
# caller's shell; exit 2 on two different specs, as above, or when the file
# cannot be read.
jig_spec_link_v() {
  local __jsl_line __jsl_id __jsl_found="" __jsl_conflict=0
  local __jsl_re='^Spec: \.ai/specs/([A-Za-z0-9._-]+)/([[:space:]]+(—|-|--)[[:space:]]+Phase[[:space:]]+[0-9]+)?[[:space:]]*$'
  printf -v "$1" '%s' ""
  [ -r "$2" ] && [ -f "$2" ] || return 2
  while IFS= read -r __jsl_line || [ -n "$__jsl_line" ]; do
    case "$__jsl_line" in "Spec: "*) ;; *) continue ;; esac
    [[ $__jsl_line =~ $__jsl_re ]] || continue
    __jsl_id=${BASH_REMATCH[1]}
    case "$__jsl_id" in .* | -*) continue ;; esac
    if [ -z "$__jsl_found" ]; then
      __jsl_found=$__jsl_id
    elif [ "$__jsl_found" != "$__jsl_id" ]; then
      __jsl_conflict=1
    fi
  done < "$2"
  [ "$__jsl_conflict" -eq 0 ] || return 2
  printf -v "$1" '%s' "$__jsl_found"
}

# jig_spec_epic <roadmap.md|-> — "<branch> open" or "<branch> finished" when
# the roadmap declares an epic branch, nothing when it does not (ADR-0040).
#
# The declaration is a whole line `Epic: <branch>`, closed before the epic's
# final pull request as `Epic: <branch> — finished`. Exits 2 when two lines
# disagree, on the branch or on its state: which base a task is cut from
# would be a guess. The branch name is not validated here; a caller that
# builds a ref from it runs `git check-ref-format --branch` first.
jig_spec_epic() {
  awk '
    /^Epic:[[:space:]]+[^[:space:]]+([[:space:]]+(—|-|--)[[:space:]]+finished)?[[:space:]]*$/ {
      line = $0
      sub(/^Epic:[[:space:]]+/, "", line)
      b = line
      sub(/[[:space:]].*$/, "", b)
      st = (line ~ /finished[[:space:]]*$/) ? "finished" : "open"
      v = b " " st
      if (found == "") found = v
      else if (found != v) conflict = 1
    }
    END {
      if (conflict) exit 2
      if (found != "") print found
    }
  ' "$1"
}

# jig_task_epic <task.md> — which epic a task is built on, by its `Spec:` line
# (jig_spec_link) and that spec's `Epic:` line (jig_spec_epic) in this
# checkout's `.ai/specs`: the one answer `task start`, which cuts the task's
# branch from it, and `jig queue`, which puts the task on that epic's level,
# must never disagree on (ARCHITECTURE.md Scripts layout). What each does with
# an answer off the happy path is its own: the codes say which one it is.
#
# Sets _JIG_TASK_SPEC (the spec id, empty without a link), _JIG_TASK_EPIC (the
# branch, empty when the spec declares none) and _JIG_TASK_EPIC_STATE (`none`,
# `open` or `finished`). Returns 0 with an answer — a task.md that does not
# exist links to nothing — 2 when the task links to more than one spec, 3 when
# the spec it links to is not in this checkout, 4 when that spec declares more
# than one epic. Sets variables rather than printing: a caller in `$(...)`
# would lose them.
_JIG_TASK_SPEC=""
_JIG_TASK_EPIC=""
_JIG_TASK_EPIC_STATE=none
jig_task_epic() {
  local spec="" line="" rc=0 roadmap
  _JIG_TASK_SPEC=""
  _JIG_TASK_EPIC=""
  _JIG_TASK_EPIC_STATE=none
  [ -f "$1" ] || return 0
  spec=$(jig_spec_link "$1") || rc=$?
  [ "$rc" -ne 2 ] || return 2
  [ -n "$spec" ] || return 0
  _JIG_TASK_SPEC=$spec
  roadmap="$JIG_PROJECT/$JIG_AI_DIR/specs/$spec/roadmap.md"
  [ -f "$roadmap" ] || return 3
  rc=0
  line=$(jig_spec_epic "$roadmap") || rc=$?
  [ "$rc" -ne 2 ] || return 4
  [ -n "$line" ] || return 0
  _JIG_TASK_EPIC=${line% *}
  _JIG_TASK_EPIC_STATE=${line##* }
  return 0
}

# --- task references and links ------------------------------------------------
#
# A task reference names a task or a spec in a repository next to this one
# (adr-20261029-a-task-reads-a-neighbouring-repository-through-a-link):
#
#   <repo>#<task-id>          a task in <repo>
#   <repo>#spec/<spec-id>     a spec in <repo>
#
# <repo> is a path relative to the clone's main checkout (jig_config_clone_root),
# not to a worktree: a worktree lacks what the main checkout ignores, such as
# `packages/`. `..` is allowed — a neighbour may sit beside the clone, not
# inside it — but not an absolute path, `~`, a drive letter, a backslash,
# whitespace or a second `#`. The ids follow jig_valid_id. This is the one
# grammar every reader of a reference uses: a task's `Linked:` lines today,
# and a moved task's target (`jig task abandon --moved-to`).

_JIG_REF_REPO=""
_JIG_REF_KIND=""
_JIG_REF_ID=""
_JIG_REF_DIR=""
_JIG_REF_ERROR=""

# jig_task_ref <ref> — parse a task reference. Sets _JIG_REF_REPO,
# _JIG_REF_KIND (`task` or `spec`) and _JIG_REF_ID; returns 1 with
# _JIG_REF_ERROR saying what is wrong. Sets variables rather than printing:
# a caller in `$(...)` would lose them.
jig_task_ref() {
  local ref="$1" repo id kind=task
  _JIG_REF_REPO=""
  _JIG_REF_KIND=""
  _JIG_REF_ID=""
  _JIG_REF_DIR=""
  _JIG_REF_ERROR=""
  case "$ref" in
    *'#'*'#'*) _JIG_REF_ERROR="more than one #"; return 1 ;;
    *'#'*) ;;
    *) _JIG_REF_ERROR="no # between the repository and the id"; return 1 ;;
  esac
  repo=${ref%%#*}
  id=${ref#*#}
  case "$repo" in
    '') _JIG_REF_ERROR="no repository path before #"; return 1 ;;
    /* | '~'* | [A-Za-z]:*) _JIG_REF_ERROR="the repository path must be relative to the clone's main checkout"; return 1 ;;
    *[[:space:]\\]*) _JIG_REF_ERROR="the repository path may not hold whitespace or a backslash"; return 1 ;;
  esac
  case "$id" in
    spec/*) kind=spec; id=${id#spec/} ;;
  esac
  jig_valid_id "$id" || { _JIG_REF_ERROR="not a valid $kind id: $id"; return 1; }
  _JIG_REF_REPO=$repo
  _JIG_REF_KIND=$kind
  _JIG_REF_ID=$id
}

# jig_task_ref_dir — after jig_task_ref, find the directory holding the
# referenced task's workspace or spec. Sets _JIG_REF_DIR to its absolute path
# (the repository part canonical, `cd -P`); returns 1 with _JIG_REF_ERROR when
# the repository or the task or spec is not there. Not being there is an
# ordinary answer — another clone, another machine, a workspace that is
# local to the machine that filed the task — never a reason to die. Reads
# only: nothing is ever written to the other repository.
jig_task_ref_dir() {
  local root dir abs
  _JIG_REF_DIR=""
  root=$(jig_config_clone_root)
  dir="$root/$_JIG_REF_REPO"
  if [ ! -d "$dir" ] || ! abs=$(cd -P "$dir" 2>/dev/null && pwd -P); then
    _JIG_REF_ERROR="no repository at $dir"
    return 1
  fi
  if [ "$_JIG_REF_KIND" = spec ]; then
    dir="$abs/$JIG_AI_DIR/specs/$_JIG_REF_ID"
    if [ ! -f "$dir/spec.md" ] && [ ! -f "$dir/roadmap.md" ]; then
      _JIG_REF_ERROR="no spec $_JIG_REF_ID in $abs"
      return 1
    fi
  else
    dir="$abs/$JIG_AI_DIR/workspace/tasks/$_JIG_REF_ID"
    if [ ! -f "$dir/task.md" ]; then
      _JIG_REF_ERROR="no task $_JIG_REF_ID in $abs (a task workspace exists only in the clone that filed it)"
      return 1
    fi
  fi
  _JIG_REF_DIR=$dir
}

# jig_task_links <task.md> — the references a task links to, one per line, as
# written: each whole line `Linked: <ref>`, trimmed. Not validated here — a
# reader says what is wrong with a line rather than skipping it in silence.
jig_task_links() {
  [ -f "$1" ] || return 0
  awk '
    {
      sub(/\r$/, "")
      if ($0 !~ /^Linked:[[:space:]]/) next
      v = $0
      sub(/^Linked:[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v != "") print v
    }
  ' "$1"
}

# jig_tracked_changes — the tracked-and-uncommitted lines of
# `git status --porcelain`, never the untracked ones (`??`): untracked files
# are not work in progress (build output, a spec nobody started yet), only a
# line git already tracks is. Shared by `task start` and `spec new`/`spec
# resume`, which refuse a dirty tree by the same rule and must not drift
# apart on what "dirty" means (design §6, ARCHITECTURE.md Scripts layout).
jig_tracked_changes() {
  git -C "$JIG_PROJECT" status --porcelain 2>/dev/null | grep -v '^??' || true
}

# Files this checkout has touched: the union of the diff against the merge-base
# with the configured base branch, the staged and unstaged diffs, and untracked
# files — all repo-relative (ARCHITECTURE.md, Scripts layout). `-C "$JIG_PROJECT"` matters: `git diff`
# reports paths relative to the repository root regardless of cwd, but
# `git ls-files` reports them relative to cwd unless it is the root, so without
# -C the two halves of the union could disagree on the path of the same file.
# When the base branch does not exist, merge-base fails and only the working
# tree diffs (staged, unstaged, untracked) are used.
#
# `--base-branch <name>` names the base a task was cut from (jig_task_base);
# without it the configured `git.base_branch` is used. Either way the base is
# resolved as jig_base_ref resolves it, origin first.
#
# Lives here rather than in one command's library because `context` and
# `knowledge paths` both need the same answer to "what did this task touch",
# and they must never disagree about it (ARCHITECTURE.md, scripts layout).
jig_git_touched_files() {
  local base=""
  if [ "${1:-}" = "--base-branch" ]; then
    [ "$#" -ge 2 ] || { jig_warn "jig_git_touched_files: --base-branch requires a value"; return 1; }
    base="$2"
    shift 2
  fi
  if [ "$#" -gt 0 ]; then
    local explicit_base explicit_head explicit_rows
    explicit_base=$(jig_review_commit "$1") || return 1
    explicit_head=$(jig_review_commit "${2:-HEAD}") || return 1
    explicit_rows=$(jig_git_change_rows "$explicit_base" "$explicit_head") || return 1
    printf '%s\n' "$explicit_rows" | sed '/^$/d' | cut -f1 | LC_ALL=C sort -u
    return 0
  fi
  local ref mb out=""
  [ -n "$base" ] || base=$(cfg git.base_branch main)
  ref=$(jig_base_ref "$base")
  if [ -n "$ref" ] && mb=$(git -C "$JIG_PROJECT" merge-base "$ref" HEAD 2>/dev/null); then
    out="$out
$(git -C "$JIG_PROJECT" diff --name-only "$mb" 2>/dev/null)"
  fi
  # Staged changes are listed independently: without a merge base they would
  # otherwise vanish from both the unstaged diff and the untracked list.
  out="$out
$(git -C "$JIG_PROJECT" diff --cached --name-only 2>/dev/null)"
  out="$out
$(git -C "$JIG_PROJECT" diff --name-only 2>/dev/null)"
  out="$out
$(git -C "$JIG_PROJECT" ls-files --others --exclude-standard 2>/dev/null)"
  printf '%s\n' "$out" | sed '/^$/d' | sort -u
}

# --- knowledge documents ---------------------------------------------------

# Document types that carry frontmatter and ship a template under
# templates/knowledge/ (schemas/frontmatter.md, ADR-0004). `domain`,
# `glossary` and `rule` are the three files of a domain pack.
JIG_DOC_TYPES="feature adr convention domain glossary rule"
export JIG_DOC_TYPES

# The three documents directly under .ai/knowledge/ that carry no frontmatter
# by design. Takes an absolute path and matches on the repository-relative
# path, never on the basename: a domain pack is `domains/<d>/RULES.md`, and a
# basename test would exempt that file from validation and hide it from every
# consumer of jig_knowledge_docs — silently, which is the worst way to lose a
# document (design.md, "Global documents are recognised by path").
jig_knowledge_is_global() {
  # jig_relpath without its `$(...)`: asked for every document of a walk.
  local rel="${1#"${JIG_PROJECT%/}/"}"
  case "$rel" in
    "$JIG_AI_DIR/knowledge/GLOSSARY.md" | \
      "$JIG_AI_DIR/knowledge/ARCHITECTURE.md" | \
      "$JIG_AI_DIR/knowledge/RULES.md") return 0 ;;
    *) return 1 ;;
  esac
}

# Every knowledge document that can carry frontmatter, absolute paths, sorted.
# Walks .ai/knowledge recursively: applicability lives in frontmatter, not in
# the directory (ADR-0004), so a document counts wherever it sits — including
# under domains/<d>/.
#
# Lives here, with the other shared knowledge helpers, because `context` and
# `knowledge` must never disagree about which files exist: one walking
# recursively while the other read three fixed directories is how a domain
# document ended up validated but never resolved.
jig_knowledge_docs() {
  local dir="$JIG_PROJECT/$JIG_AI_DIR/knowledge" f
  [ -d "$dir" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    jig_knowledge_is_global "$f" && continue
    printf '%s\n' "$f"
  done < <(find "$dir" -type f -name '*.md' | sort)
}

# jig_knowledge_status_resolvable <status> — true when a document may be loaded into
# an agent's context, listed in the catalog, or pulled in as a `requires` target.
#
# An allowlist, deliberately: a denylist of retired values resolves anything it has not
# heard of — a typo'd status, or a lifecycle value added later — as if it were active.
# `proposed` is exactly such a later value, and the guarantee that a proposed document
# cannot reach an agent rests on this being an allowlist. `accepted` is the ADR spelling
# of `active`.
jig_knowledge_status_resolvable() {
  case "$1" in
    active | accepted) return 0 ;;
    *) return 1 ;;
  esac
}

# jig_knowledge_source <doc> — the `source:` a document links, or nothing.
# A document with one is a stub for an existing file (ADR-0036). `knowledge`
# validates stubs and `context` resolves them to their sources, and the two
# must agree on what a stub is — so the question is asked here, once.
# Callers have sourced frontmatter.sh, as both commands do.
jig_knowledge_source() {
  local __jks_src
  jig_knowledge_source_v __jks_src "$1"
  [ -z "$__jks_src" ] || printf '%s\n' "$__jks_src"
}

# jig_knowledge_source_v <var> <doc> — jig_knowledge_source into <var>, without
# a process: `jig status` and `jig context` ask it of every stub. The block is
# read as fm_block reads it, an unclosed frontmatter included, so the answer is
# fm_get's.
jig_knowledge_source_v() {
  local __jksv_block
  fm_block_v __jksv_block "$2"
  fm_get_block_v "$1" "$__jksv_block" source
}

# jig_knowledge_read_path <doc> — the repository-relative path an agent reads
# for <doc>: the source of a stub, the document itself otherwise. Exit 3, with
# the source path still printed, when a stub's source is not a regular file
# inside the repository — a path that could leave it, a symlink, or a file
# reached through a symlinked directory. Checked on every resolution, not only
# at acceptance: a hand-edited stub is not validated before it is resolved, and
# a source can be swapped for a link to `/etc/passwd` after it was accepted
# without touching the stub. Whether git tracks the file with this exact case
# is `knowledge check`'s question, not this one's.
jig_knowledge_read_path() {
  local __jkrp_path __jkrp_rc=0
  jig_knowledge_read_path_v __jkrp_path "$1" || __jkrp_rc=$?
  printf '%s\n' "$__jkrp_path"
  return "$__jkrp_rc"
}

# jig_knowledge_read_path_v <var> <doc> — jig_knowledge_read_path into <var>,
# with the same exit, and no process for a source reached through no symlink:
# `jig status` and `jig context` ask it of every stub, and the guard cost five
# subshells and a `dirname` each. With `..` and an absolute path refused first,
# the source's directory is inside the repository exactly when none of the
# directories on its way is a symlink, which `-L` asks of each without a
# process. Only when one is a symlink — it may still lead back inside — is the
# directory resolved with `cd -P`, as it always was.
jig_knowledge_read_path_v() {
  local __jkr_src __jkr_rest __jkr_dir __jkr_root __jkr_phys
  jig_knowledge_source_v __jkr_src "$2"
  if [ -z "$__jkr_src" ]; then
    jig_relpath_v "$1" "$2" "$JIG_PROJECT"
    return 0
  fi
  printf -v "$1" '%s' "$__jkr_src"
  case "$__jkr_src" in
    /* | ../* | */../* | *.. ) return 3 ;;
  esac
  if [ ! -f "$JIG_PROJECT/$__jkr_src" ] || [ -L "$JIG_PROJECT/$__jkr_src" ]; then
    return 3
  fi
  __jkr_rest=$__jkr_src
  __jkr_dir=""
  while :; do
    case "$__jkr_rest" in
      */*) ;;
      *) return 0 ;;
    esac
    __jkr_dir="$__jkr_dir${__jkr_rest%%/*}/"
    __jkr_rest=${__jkr_rest#*/}
    if [ -L "$JIG_PROJECT/${__jkr_dir%/}" ]; then
      break
    fi
  done
  __jkr_root=$(cd -P "$JIG_PROJECT" 2>/dev/null && pwd -P) || return 3
  __jkr_phys=$(cd -P "$JIG_PROJECT/${__jkr_src%/*}" 2>/dev/null && pwd -P) || return 3
  case "$__jkr_phys/" in
    "$__jkr_root/"*) return 0 ;;
    *) return 3 ;;
  esac
}

# Translate a frontmatter `paths` glob into a pattern with exactly one
# wildcard token, `*` — schemas/frontmatter.md documents only `*` and `**`
# ("any depth"); `?` and `[...]` were never part of this grammar. Escaping
# them to literals first, rather than leaving them as bash `case` wildcards,
# is what makes `jig_path_matches_any` (a `case` test) and
# `jig_glob_matches_repo` (an ERE built from this same pattern) agree on a
# glob containing one: a `case` pattern lets `?`/`[...]` through as glob
# syntax unless escaped, and an early version of the ERE builder escaped them
# to literal characters instead — two matchers disagreeing again on exactly
# the class of glob item 5 existed to stop disagreeing on (review,
# knowledge-costs-one-walk). No document uses either today, so this changes
# nothing observable yet; it fixes the divergence before one does.
#
# `**` (any depth, including zero directories) collapses to a single `*`,
# which matches across `/` the same way (no FNM_PATHNAME) (convention-shell).
# A glob ending in `/` names a directory, and no path a matcher ever tests
# against ends in `/` (a real file never does, and jig_repo_files below lists
# files, not directory entries) — so it gains a trailing `*`, read as "anything
# under here", the same reading `**` already gets for "any depth". The `**`
# collapse runs before that check: testing for a trailing `/` first would turn
# `docs/**/` into `docs/**/*`, a glob that — unlike plain `docs/**` or `docs/`
# — no longer matches a file directly under `docs/` (review,
# knowledge-costs-one-walk) instead of the `docs/*` both of those already
# collapse to.
#
# Used by jig_path_matches_any and jig_glob_matches_repo below, the one
# matcher context.sh and knowledge.sh both call.
jig_glob_pattern() {
  local pattern
  jig_glob_pattern_v pattern "$1"
  printf '%s' "$pattern"
}

# jig_glob_pattern_v <var> <glob> — jig_glob_pattern into <var>, without a
# process: `jig context` asks it for every glob of every document. Literal
# replacements through _jig_replace_all_v, not `${var//a/b}`: what a replacement
# means there differs between bash 3.2 and the bash 5.2 of Linux and Git Bash.
jig_glob_pattern_v() {
  local __jgp_out="$2"
  _jig_replace_all_v __jgp_out "$__jgp_out" "\\" "\\\\"
  _jig_replace_all_v __jgp_out "$__jgp_out" '?' '\?'
  _jig_replace_all_v __jgp_out "$__jgp_out" '[' '\['
  _jig_replace_all_v __jgp_out "$__jgp_out" ']' '\]'
  _jig_replace_all_v __jgp_out "$__jgp_out" '**/' '*'
  _jig_replace_all_v __jgp_out "$__jgp_out" '**' '*'
  case "$__jgp_out" in
    */) __jgp_out="$__jgp_out*" ;;
  esac
  printf -v "$1" '%s' "$__jgp_out"
}

# _jig_replace_all_v <var> <text> <find> <with> — every <find> in <text>, left
# to right and never overlapping, replaced by <with>; all three literal.
_jig_replace_all_v() {
  local __jra_rest="$2" __jra_out=""
  while :; do
    case "$__jra_rest" in
      *"$3"*)
        __jra_out="$__jra_out${__jra_rest%%"$3"*}$4"
        __jra_rest="${__jra_rest#*"$3"}"
        ;;
      *) break ;;
    esac
  done
  printf -v "$1" '%s' "$__jra_out$__jra_rest"
}

# --- glob matching (one matcher, shared by context.sh and knowledge.sh) -------
#
# There used to be two: a bash `case` loop over a file list, and a `find -path`
# call per glob. They disagreed in three ways a review caught — `find` also
# matches a directory *entry* (a glob over an otherwise-empty directory
# "matched" through find and never through case), `find` does not consult
# `.gitignore`, and the shared `**` substitution above never gave either of
# them brace-glob support. Settling on one implementation, over one list built
# by a tool that already understands ignore rules, ends all three: a document's
# `paths` describes code, and code a glob only reaches through an empty
# directory or an ignored file was never really described.

# jig_path_matches_any <glob> <newline-files> — exit 0 when <glob> matches at
# least one line of <files>. In-process (bash `case`, no subprocess per file):
# a here-string, not `< <(printf ...)` — the latter forks a subshell *and* a
# `printf` on every call, which is affordable once per task's touched files
# but is exactly the per-glob subprocess cost this replaces `find` to avoid,
# paid again, when the list is jig_repo_files instead (jig_glob_matches_repo,
# every glob of every document).
jig_path_matches_any() {
  local glob="$1" files="$2" pattern file
  jig_glob_pattern_v pattern "$glob"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # shellcheck disable=SC2254
    case "$file" in
      $pattern) return 0 ;;
    esac
  done <<EOF
$files
EOF
  return 1
}

# jig_repo_files — every path in the working tree a `paths` glob can describe:
# tracked files, plus untracked ones `.gitignore` does not hide (the same rule
# `jig_git_touched_files`'s untracked layer uses). One `git ls-files` per
# process, NUL-separated and memoised — every glob check in the same command
# shares this one walk instead of spawning `find` again.
_JIG_REPO_FILES_LOADED=0
_JIG_REPO_FILES=""
jig_repo_files() {
  if [ "$_JIG_REPO_FILES_LOADED" -eq 0 ]; then
    _JIG_REPO_FILES=$( (
      git -C "$JIG_PROJECT" ls-files -z
      git -C "$JIG_PROJECT" ls-files -z --others --exclude-standard
    ) | tr '\0' '\n' | sed '/^$/d' | LC_ALL=C sort -u)
    _JIG_REPO_FILES_LOADED=1
  fi
  printf '%s\n' "$_JIG_REPO_FILES"
}

# jig_glob_matches_repo <glob> — exit 0 when <glob> matches at least one file
# presently in the repository (jig_repo_files). Replaces a `find -path` call
# per glob — one process that re-walks the whole tree — with one process
# (`awk`) that tests every cached path from the one shared walk: the same
# one-process-per-glob count `find` had, spent against memory instead of
# disk. Goes through jig_glob_pattern first, the same conversion `case`
# matching uses, rather than a second, awk-only translation of the glob: an
# early version built the ERE straight from the raw glob and silently
# stopped agreeing with jig_glob_pattern's `**/` handling — `**/*.sh` and
# `*.sh` are the same case pattern (a bare `*` already matches across `/`),
# but treating `**` and the `/` after it as two separate ERE tokens made the
# slash mandatory, so a root-level `top.sh` stopped matching. One shared
# conversion is worth the second process.
#
# Quits at the first match (`exit` inside the pattern rule) rather than
# reading every path once one is already found. conventions/shell.md warns
# against exactly this shape, `awk '{ ...; exit }'` — but for a *pipeline*,
# where the awk quitting early can SIGPIPE a bash writer still mid-`printf`
# and turn a match into a false failure under `pipefail`. This is a
# here-document, not a pipe: there is no `cmd | awk` for `pipefail` to judge,
# bash has already handed the whole list over before awk runs a line, and an
# early `exit` here answers "found" the moment it is true instead of scanning
# a repository's worth of paths that can no longer change the answer.
#
# Calls jig_repo_files as a plain command first, discarding its output, then
# reads the global it fills directly — never `$(jig_repo_files)`: a command
# substitution runs the function in a subshell, and the memoisation it sets
# would vanish with that subshell instead of surviving to the next glob, which
# is the one thing this function exists to avoid paying for twice.
jig_glob_matches_repo() {
  local pattern
  jig_repo_files >/dev/null
  pattern=$(jig_glob_pattern "$1")
  awk -v g="$pattern" '
    BEGIN {
      pat = "^"
      n = length(g)
      for (i = 1; i <= n; i++) {
        c = substr(g, i, 1)
        # jig_glob_pattern backslash-escapes every `?`, `[`, `]` and literal
        # `\` in the glob before this runs, so the char after one is always
        # meant literally here too — never re-derived as "happens to be an
        # ERE metachar", which is what let `?`/`[...]` slip through as
        # wildcards in the `case` matcher while this builder quietly turned
        # them into literals, the divergence item 5 asked to end (review,
        # knowledge-costs-one-walk).
        if (c == "\\" && i < n) {
          i++
          pat = pat "\\" substr(g, i, 1)
          continue
        }
        if (c == "*") { pat = pat ".*"; continue }
        if (index(".^$+?(){}|[]\\", c) > 0) { pat = pat "\\" c; continue }
        pat = pat c
      }
      pat = pat "$"
    }
    $0 ~ pat { found = 1; exit }
    END { exit !found }
  ' <<EOF
$_JIG_REPO_FILES
EOF
}

# --- misc ------------------------------------------------------------------

jig_today() { date +%Y-%m-%d; }

# jig_trash_dest <name> — where <name> goes in trash today:
# .ai/runtime/trash/<date>/<name>, or <name>-2, -3, … when that is taken. Never
# overwrites and never merges into an existing entry (ADR-0006). Shared by
# housekeeping (a workspace, named by its task id) and `jig spec remove`
# (`spec-<id>`), so two commands putting things in the same trash cannot
# disagree about collisions. Prints the path; creates nothing.
jig_trash_dest() {
  local base dest n
  base="$JIG_PROJECT/$JIG_AI_DIR/runtime/trash/$(jig_today)/$1"
  dest="$base"
  n=2
  while [ -e "$dest" ]; do
    dest="$base-$n"
    n=$((n + 1))
  done
  printf '%s\n' "$dest"
}

# --- the live status page (adr-20260924-the-status-page-keeps-the-readers-place)
#
# The page, .ai/runtime/status.html, is redrawn by the commands that change
# what it shows, synchronously and from the counts the last full `jig status`
# cached, so a redraw costs a fraction of a second. Shared here because task,
# spec and housekeeping all trigger it and none of them may source status.sh:
# the redraw is a process, `jig status --refresh`, the way one domain runs
# another's command (ARCHITECTURE.md, Scripts layout).

_JIG_PAGE_DIRTY=""

# jig_status_page_touch [--full | --refresh] — redraw the clone's status page
# if it exists.
# One page per clone: a command run in a task worktree redraws the page of the
# main checkout, with that checkout's own jig. A page nobody has opened yet
# (`jig status --html` or `--open` writes the first one) is never created
# here. --full recounts everything and refreshes the cached counts
# (`status --html`); --refresh, the default, reads them (`status --refresh`).
# Callers in this file pass the mode explicitly: shellcheck 0.9.0 reports
# SC2120 on a function that reads $1 when every call it can see passes none.
# Always returns 0 and prints nothing: a failed redraw never changes the
# output or the exit code of the command that triggered it.
#
# **This re-entry is not a session, and says so.** `bash "$jig" status
# "$mode"` runs the whole dispatcher again, which would otherwise write this
# checkout's own two records (adr-20260924-a-checkout-records-what-is-happening-in-it)
# for `status --refresh` — overwriting `runtime/checkout`'s `command:` with
# a line nobody ran, and, because `status` is one of the commands a reader
# orients with, consuming the moved-HEAD notice a neighbour is owed. That
# neighbour's next real orienting command must still get it, so the redraw's
# subprocess carries JIG_INTERNAL_REDRAW, scoped to this one call by the
# subshell it runs in, and checkout.sh's recorder and notice both stay silent
# while it is set (jig_checkout_record, jig_checkout_notice).
jig_status_page_touch() {
  local mode="--refresh" root jig
  [ "${1:-}" != --full ] || mode="--html"
  root=$(jig_config_clone_root 2>/dev/null) || return 0
  [ -f "$root/$JIG_AI_DIR/runtime/status.html" ] || return 0
  jig="$root/$JIG_AI_DIR/scripts/jig"
  [ -f "$jig" ] || return 0
  (cd "$root" && JIG_INTERNAL_REDRAW=1 bash "$jig" status "$mode") </dev/null >/dev/null 2>&1 || true
  return 0
}

# jig_status_page_dirty — note that this command changed something the page
# shows. The writers call it themselves, through jig_record_changed below, so
# a new command that writes through them is covered without anyone remembering
# to; jig_status_page_flush then redraws once, however many writes came before.
jig_status_page_dirty() { _JIG_PAGE_DIRTY=1; }

# jig_status_page_flush — redraw the page when this command changed something.
jig_status_page_flush() {
  [ -n "${_JIG_PAGE_DIRTY:-}" ] || return 0
  _JIG_PAGE_DIRTY=""
  jig_status_page_touch --refresh
}

# --- the clone's revision (adr-20261016-the-clone-revision-is-a-claimed-name) ---
#
# One counter per clone, raised by every Jig write — task state, artifacts, the
# autopilot journal, findings, the receipt, specs, knowledge, settings, a
# housekeeping run — and reported as `revision` by every `--json` read (json.sh,
# schemas/json.md). A consumer compares it between reads, and from
# contract-queue on sends it back with a write.
#
# The value is the highest numeric **name** in `.ai/runtime/revision/` of the
# clone's main checkout (jig_config_clone_root: every worktree raises and reads
# the same one, ADR-0008 as amended 2026-09-25; see jig_revision_dir for a clone with
# no main checkout to find). Raising it claims the next
# name, a file created exclusively (jig_claim_file, O_EXCL on POSIX and
# CREATE_NEW on NTFS under Git Bash), so of two writers that both saw <n> exactly
# one creates <n+1> and the other gets EEXIST, reads again and claims <n+2>; a
# claim made stale by a long stall is caught and made again (jig_revision_bump).
# No increment is lost, and there is no lock to go stale, wait for or break. A
# reader only lists names and never opens one. Not `mv <n> <n+1>`: Git Bash
# emulates rename, and two writers both "renamed" the same <n> on Windows CI.
#
# A file edited by hand, or changed by a git command a person ran, raises
# nothing: the accepted risk of the contract-extensions spec.

# jig_revision_dir — where the counter lives; fails outside a project. Where a clone has
# no main checkout to find, under its git common directory (jig_config_odd_common).
jig_revision_dir() {
  local root common
  [ -n "${JIG_PROJECT:-}" ] || return 1
  if common=$(jig_config_odd_common); then
    printf '%s/jig/revision\n' "$common"
    return 0
  fi
  root=$(jig_config_clone_root) || return 1
  [ -n "$root" ] || return 1
  printf '%s/%s/runtime/revision\n' "$root" "$JIG_AI_DIR"
}

# _jig_revision_scan <dir> — _JIG_REV <- the highest numeric name in <dir>, or
# empty when there is none; _JIG_REV_OLD <- the other numeric names, which a
# raise clears away. The shell's own glob, no process. A name is a directory
# (a claim) or a file (the counter of the first, rename-based version, still
# found in clones that ran it): either counts, and the highest wins.
_JIG_REV=""
_JIG_REV_OLD=""
_jig_revision_scan() {
  local f n
  _JIG_REV=""
  _JIG_REV_OLD=""
  for f in "$1"/[0-9]*; do
    n=${f##*/}
    case "$n" in
      '' | *[!0-9]*) continue ;;
    esac
    [ -e "$f" ] || continue
    if [ -z "$_JIG_REV" ]; then
      _JIG_REV=$n
    elif [ "$n" -gt "$_JIG_REV" ]; then
      _JIG_REV_OLD="$_JIG_REV_OLD $_JIG_REV"
      _JIG_REV=$n
    else
      _JIG_REV_OLD="$_JIG_REV_OLD $n"
    fi
  done
}

# jig_claim_file <path> — create <path>, empty, only if nothing is there: exit
# 0 when this process created it and 1 when it already existed (or could not
# be made). A caller that needs content renames a finished file over it, so a
# reader never sees a partial one (ADR-0008).
#
# The claim of every lock and counter in Jig (adr-20261023-a-claim-is-an-exclusive-create).
# It is bash's own noclobber, an open with O_EXCL, so no external tool decides
# it: uutils' `mkdir`, the default on Ubuntu 25.10 and later, returns success to
# both of two processes making one directory (110 of 300 races, measured on
# ubuntu:26.04), which is why `mkdir` is not a claim anywhere here. Git Bash
# maps O_EXCL to CREATE_NEW, which is as exclusive.
jig_claim_file() {
  ( set -C; : > "$1" ) 2>/dev/null
}

# jig_revision_read — print the clone's revision: an integer, `0` when Jig has
# not written anything in this clone yet (no counter).
jig_revision_read() {
  local dir
  dir=$(jig_revision_dir) || { printf '0\n'; return 0; }
  _JIG_REV=""
  [ ! -d "$dir" ] || _jig_revision_scan "$dir"
  printf '%s\n' "${_JIG_REV:-0}"
}

# jig_revision_valid <value> — zero when <value> is a revision a caller may
# send with `--revision`: digits without a leading zero, or `0`. `08` is not
# one, and the shell would read it as octal. Shared by every write checked
# against the caller's revision (`jig queue`, `jig task resume`).
jig_revision_valid() {
  case "$1" in
    0) return 0 ;;
    [1-9]*)
      case "$1" in
        *[!0-9]*) return 1 ;;
      esac
      return 0 ;;
  esac
  return 1
}

# _jig_revision_clear <dir> <below> <names> — remove the names in <names> that
# are below <below>: best effort, at most 16 a time, never a failure. A reader
# takes the highest name, so a leftover is clutter, not a wrong answer. Each
# path is a digits-only name inside the revision directory (RULES.md: validated
# before anything is removed).
_jig_revision_clear() {
  local dir="$1" below="$2" n count=0 dirs="" files=""
  for n in $3; do
    case "$n" in
      '' | *[!0-9]*) continue ;;
    esac
    [ "$n" -lt "$below" ] || continue
    [ "$count" -lt 16 ] || break
    count=$((count + 1))
    if [ -d "$dir/$n" ]; then
      dirs="$dirs $n"
    elif [ -f "$dir/$n" ]; then
      files="$files $n"
    fi
  done
  # shellcheck disable=SC2086 # digits-only names, split on purpose
  if [ -n "$dirs" ]; then (cd "$dir" && rmdir $dirs) 2>/dev/null || true; fi
  # shellcheck disable=SC2086 # digits-only names, split on purpose
  if [ -n "$files" ]; then (cd "$dir" && rm -f $files) 2>/dev/null || true; fi
  return 0
}

# How far below a claim a name must be before a raise clears it. A name is
# cleared only by a claim more than this above it, so a claim that finds the
# highest name that far above itself is a cleared name created again.
_JIG_REV_KEEP=16

# jig_revision_bump — raise the clone's revision by one, after a write landed.
#
# Claim the name above the highest one seen; a claim that loses (EEXIST) reads
# again. A claim can also *succeed stale*: a writer that read <n> (or found the
# directory empty and seeded), stalled, and meanwhile others claimed <n+1> and
# far beyond and cleared it, would create <n+1> again — below the counter,
# counting nothing. Clearing <n+1> took a claim more than _JIG_REV_KEEP above
# it, and the highest name never goes down, so after its claim every claim
# reads again: a highest name more than _JIG_REV_KEEP above its own makes it
# stale, and it is withdrawn and made again. A fresh claim is misjudged only if
# that many raises land between its claim and the next read, microseconds
# apart — and then it counts once too often, never too few.
#
# A first write (or the first after `.ai/runtime` was lost) claims the current
# time in seconds rather than 1, so that a revision a consumer still holds from
# before the loss does not come round again. Never fails the command: the write
# it follows has already landed, so a counter that cannot be raised — the main
# checkout not writable from a sandboxed worktree — is a warning.
jig_revision_bump() {
  local dir tries=0 next seen old
  dir=$(jig_revision_dir) || return 0
  if [ ! -d "$dir" ] && ! mkdir -p "$dir" 2>/dev/null; then
    jig_warn "could not raise the clone revision: cannot create $dir"
    return 0
  fi
  while [ "$tries" -lt 64 ]; do
    tries=$((tries + 1))
    _jig_revision_scan "$dir"
    seen=$_JIG_REV
    old="$_JIG_REV_OLD $_JIG_REV"
    if [ -z "$seen" ]; then
      next=$(date +%s)
    else
      next=$((seen + 1))
    fi
    # The claim: exactly one writer creates <next>; the loser reads again.
    jig_claim_file "$dir/$next" || continue
    _jig_revision_scan "$dir"
    if [ "${_JIG_REV:-$next}" -le "$((next + _JIG_REV_KEEP))" ]; then
      _jig_revision_clear "$dir" "$((next - _JIG_REV_KEEP))" "$old"
      return 0
    fi
    # Stale: <next> had been claimed and cleared before. Withdraw it.
    rm -f "$dir/$next" 2>/dev/null || true
  done
  jig_warn "could not raise the clone revision in $dir; a reader may miss this change"
  return 0
}

# jig_record_changed — a Jig write landed: raise the clone's revision now, and
# redraw the status page once when the command ends (jig_status_page_dirty).
# Every writer of a record calls it right after its write lands, not once at
# the command's end: a write made inside `$(...)`, or by a command that dies
# after it, is still counted. tests/json.t.sh fails on a writer that does not.
jig_record_changed() {
  jig_revision_bump
  jig_status_page_dirty
}

# jig_revision_claim <expected> — claim the revision right above <expected>,
# for a write that must be refused when the clone changed after its caller
# read <expected> (adr-20261019-the-queue-is-one-file-written-against-a-revision).
#
# The claim is jig_revision_bump's claim of <expected+1> made exact. Before it,
# the highest name must be <expected> (for 0, there must be no name at all):
# otherwise the call is stale and claims nothing — a revision from before a
# lost `.ai/runtime`, from the future, or simply old. Of two writers holding
# one revision at most one then creates the name. After it, the claim must be
# the highest name; when a higher one appeared in between — a cleared name
# created again, another writer's raise — it is withdrawn: `rm -f` of the
# digits-only name, a file, this call just created, never anything else. A claim is
# withdrawn only from under a higher name, so the clone's revision never goes
# down. 0 claims the time in seconds, the seed of a first raise, and two
# writers holding 0 claim different seconds; so a claim of 0 must also be the
# only name, and one that finds another claim of 0 below it is stale but
# stays — the highest name, it counts as one more raise.
#
# The claim raises the revision *before* the caller's write lands. The caller
# therefore moves its file into place and then calls jig_record_changed, so
# that a read which took the claimed revision with the old data sees a change
# again. <expected> is validated by the caller: digits, no leading zero.
# Returns 0 claimed, 1 stale, 2 when the counter cannot be created at all.
jig_revision_claim() {
  local expected="$1" dir next
  dir=$(jig_revision_dir) || return 2
  if [ ! -d "$dir" ] && ! mkdir -p "$dir" 2>/dev/null; then
    return 2
  fi
  _jig_revision_scan "$dir"
  if [ "$expected" = 0 ]; then
    [ -z "$_JIG_REV" ] || return 1
    next=$(date +%s)
  else
    [ "$_JIG_REV" = "$expected" ] || return 1
    next=$((expected + 1))
  fi
  jig_claim_file "$dir/$next" || return 1
  _jig_revision_scan "$dir"
  if [ "$_JIG_REV" = "$next" ]; then
    # For 0 the names two writers claim differ (each its own second), so
    # the claim alone excludes nobody: it stands only alone. A name below
    # it is another writer's first raise or claim of 0; this one stays, the
    # highest name: withdrawing it would lower the revision. It counts as one
    # more raise.
    [ "$expected" != 0 ] || [ -z "$_JIG_REV_OLD" ] || return 1
    return 0
  fi
  rm -f "$dir/$next" 2>/dev/null || true
  return 1
}

# --- the queue file, as its readers outside `jig queue` see it ----------------
#
# `jig queue` (lib/queue.sh) is the queue's only writer; `task` reads the pause
# requests in it and acts on them through `"$JIG_SELF" queue cancel`, and
# `status` and `context` show a task's place in it. Where the file is, how its
# items are parsed and when a pause request may be made are the answers they
# must never disagree about, so they live here
# (adr-20261019-a-pause-request-is-honoured-at-the-stage-boundary).

# jig_queue_file — the queue's path in the clone's main checkout
# (jig_config_clone_root), shared by every worktree.
jig_queue_file() {
  local file
  jig_queue_file_v file
  printf '%s\n' "$file"
}

# jig_queue_file_v <var> — jig_queue_file's path into <var>, in the caller's
# shell (jig_config_clone_root_v always answers: the clone's main checkout,
# or JIG_PROJECT itself).
jig_queue_file_v() {
  local __jqf_root
  jig_config_clone_root_v __jqf_root
  printf -v "$1" '%s/%s/runtime/queue' "$__jqf_root" "$JIG_AI_DIR"
}

# _jig_queue_readable <file> — exit 0 when the queue <file> exists and is of
# the format version this jig reads. A file of another version holds nothing
# this jig can read, as the writer refuses to rewrite it.
_JIG_QUEUE_FORMAT=1
_jig_queue_readable() {
  local line=""
  [ -f "$1" ] || return 1
  IFS= read -r line < "$1" || [ -n "$line" ] || return 0
  _jig_queue_line_readable "$line"
}

# _jig_queue_line_readable <first-line> — the version check of
# _jig_queue_readable on the file's first line: a `# jig queue <n>` header
# whose fourth blank-separated word is not this jig's version is unreadable;
# any other first line is read.
_jig_queue_line_readable() {
  local w4 rest
  case "$1" in
    "# jig queue "*) ;;
    *) return 0 ;;
  esac
  # The header's words as awk's split() counts them: blank runs separate.
  read -r _ _ _ w4 rest <<EOF
$1
EOF
  [ "$w4" = "$_JIG_QUEUE_FORMAT" ]
}

# The queue as the read path's snapshot holds it (jig_read_snapshot_begin):
# _JIG_QUEUE_CACHED is 1 once the file was read, _JIG_QUEUE_CACHE its lines
# (empty when there is no file or it is of another version). Outside a
# snapshot every reader reads the file.
_JIG_QUEUE_CACHED=0
_JIG_QUEUE_CACHE=""
_jig_queue_cache_drop() {
  _JIG_QUEUE_CACHED=0
  _JIG_QUEUE_CACHE=""
}

# _jig_queue_lines_v <var> — the queue's lines into <var>, empty when there
# is no queue or it is of another format version; read once per snapshot.
_jig_queue_lines_v() {
  local __jql_file __jql_line __jql_text="" __jql_first=1
  if [ "$_JIG_TS_ON" = 1 ] && [ "$_JIG_QUEUE_CACHED" = 1 ]; then
    printf -v "$1" '%s' "$_JIG_QUEUE_CACHE"
    return 0
  fi
  jig_queue_file_v __jql_file
  if [ -f "$__jql_file" ]; then
    while IFS= read -r __jql_line || [ -n "$__jql_line" ]; do
      if [ "$__jql_first" = 1 ]; then
        __jql_first=0
        _jig_queue_line_readable "$__jql_line" || { __jql_text=""; break; }
      fi
      __jql_text="$__jql_text$__jql_line"$'\n'
    done < "$__jql_file"
  fi
  if [ "$_JIG_TS_ON" = 1 ]; then
    _JIG_QUEUE_CACHE=$__jql_text
    _JIG_QUEUE_CACHED=1
  fi
  printf -v "$1" '%s' "$__jql_text"
}

# jig_queue_items <file|-> [<ref>] — every item of the queue <file> in the
# order of its lines, each followed by its own dependencies in theirs:
# `item <ref> <level> <position> <priority>`, then `dep <on-ref> <reason>`.
# With <ref>, that item alone. Lines of any other kind are left out. This is
# the one parser of the queue's items and dependencies: `jig queue list
# --json` (queue.sh) reads them through it, and so do `jig status` and `jig
# context` (jig_queue_place), since a command library never sources another
# (ARCHITECTURE.md). The format version is the caller's to check.
jig_queue_items() {
  Q_REF="${2:-}" awk -F '\t' '
    $1 == "item" && NF >= 5 && (ENVIRON["Q_REF"] == "" || $2 == ENVIRON["Q_REF"]) {
      i = ++n; line[i] = $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5; r[i] = $2
    }
    $1 == "dep" && NF >= 4 { j = ++dn; dsub[j] = $2; dl[j] = $1 "\t" $3 "\t" $4 }
    END {
      for (i = 1; i <= n; i++) {
        print line[i]
        for (j = 1; j <= dn; j++) if (dsub[j] == r[i]) print dl[j]
      }
    }
  ' "$1"
}

# jig_queue_place <id> — exit 0 when task <id> is an item of the queue, with
# _JIG_QUEUE_LEVEL <- its level (`-` the top, or `epic:<spec>`),
# _JIG_QUEUE_POSITION and _JIG_QUEUE_PRIORITY (`-` for none) as stored,
# _JIG_QUEUE_RANK <- its place on its level counted from 1 (positions compare
# within a level only), _JIG_QUEUE_COUNT <- how many items that level holds,
# and _JIG_QUEUE_DEPS <- what it waits for, one `<on-ref><TAB><reason>` line
# each. Exit 1 when it is not queued, there is no queue, or the queue is of
# another format version. What `jig status` and `jig context` show of a
# task's place (adr-20261019-the-queue-is-one-file-written-against-a-revision).
_JIG_QUEUE_LEVEL=""
_JIG_QUEUE_POSITION=""
_JIG_QUEUE_PRIORITY=""
_JIG_QUEUE_RANK=""
_JIG_QUEUE_COUNT=""
_JIG_QUEUE_DEPS=""
jig_queue_place() {
  local file ref="task:$1" kind f2 f3 f4 f5 mine="" items="" rank
  _JIG_QUEUE_LEVEL="" _JIG_QUEUE_POSITION="" _JIG_QUEUE_PRIORITY=""
  _JIG_QUEUE_RANK="" _JIG_QUEUE_COUNT="" _JIG_QUEUE_DEPS=""
  file=$(jig_queue_file)
  _jig_queue_readable "$file" || return 1
  items=$(jig_queue_items "$file")
  while IFS=$'\t' read -r kind f2 f3 f4 f5; do
    case "$kind" in
      item)
        mine=""
        [ "$f2" = "$ref" ] || continue
        mine=1
        _JIG_QUEUE_LEVEL=$f3 _JIG_QUEUE_POSITION=$f4 _JIG_QUEUE_PRIORITY=$f5 ;;
      dep)
        [ -n "$mine" ] || continue
        _JIG_QUEUE_DEPS="$_JIG_QUEUE_DEPS$f2"$'\t'"$f3"$'\n' ;;
    esac
  done <<EOF
$items
EOF
  [ -n "$_JIG_QUEUE_LEVEL" ] || return 1
  _JIG_QUEUE_DEPS=${_JIG_QUEUE_DEPS%$'\n'}
  rank=$(printf '%s\n' "$items" | Q_LEVEL="$_JIG_QUEUE_LEVEL" Q_POS="$_JIG_QUEUE_POSITION" awk -F '\t' '
    $1 == "item" && $3 == ENVIRON["Q_LEVEL"] { n++; if ($4 + 0 < ENVIRON["Q_POS"] + 0) before++ }
    END { print before + 1, n + 0 }
  ')
  _JIG_QUEUE_RANK=${rank%% *}
  _JIG_QUEUE_COUNT=${rank#* }
  return 0
}

# jig_pause_request <id> — exit 0 when the queue holds a pause request for
# task <id>, with _JIG_PAUSE_AT <- when it was made (UTC) and
# _JIG_PAUSE_REASON <- its reason (empty for none); exit 1 when it holds none
# or there is no queue. The record is `request<TAB>task:<id><TAB>pause<TAB>
# <requested_at><TAB><reason>`; the first one counts, as the writer reads it.
# A file of another format version holds no request this jig can read, as the
# writer refuses to rewrite it: none is reported. This is a second reader of
# the queue's lines beside queue.sh's writer, for the one record `task`,
# `status` and `context` need, because a command library never sources
# another (ARCHITECTURE.md).
_JIG_PAUSE_AT=""
_JIG_PAUSE_REASON=""
jig_pause_request() {
  local lines line rest ref="task:$1" t=$'\t'
  _JIG_PAUSE_AT=""
  _JIG_PAUSE_REASON=""
  _jig_queue_lines_v lines
  # Split field by field as `awk -F '\t'` does: one tab, one separator, so an
  # empty field stays a field and a fifth field ends at the next tab.
  while IFS= read -r line; do
    case "$line" in "request$t$ref${t}pause$t"*) ;; *) continue ;; esac
    rest=${line#"request$t$ref${t}pause$t"}
    _JIG_PAUSE_AT=${rest%%"$t"*}
    case "$rest" in
      *"$t"*) rest=${rest#*"$t"}; _JIG_PAUSE_REASON=${rest%%"$t"*} ;;
    esac
    return 0
  done <<EOF
$lines
EOF
  return 1
}

# jig_utc_epoch <UTC ISO time> — seconds since the epoch, or nothing. BSD date
# first (macOS), GNU date otherwise (Linux, Git Bash).
jig_utc_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || true
}

# jig_utc_ago <UTC ISO time> — how long ago, in words a person reads at a
# glance: "just now", "12 min", "3 h", "2 days"; empty when unparsable.
jig_utc_ago() {
  local past now d
  past=$(jig_utc_epoch "$1")
  [ -n "$past" ] || return 0
  now=$(date -u +%s)
  d=$((now - past))
  if [ "$d" -lt 60 ]; then printf 'just now\n'
  elif [ "$d" -lt 3600 ]; then printf '%d min\n' $((d / 60))
  elif [ "$d" -lt 172800 ]; then printf '%d h\n' $((d / 3600))
  else printf '%d days\n' $((d / 86400))
  fi
}

# _jig_task_state_value <id> <key> — the value of <key> in task <id>'s state
# file, read as `task_state_get` reads it (lib/task.sh owns the file; reading
# a peer's file directly is allowed, ARCHITECTURE.md). The id passes
# jig_valid_id before it becomes a path (RULES.md); an invalid one has no state.
_jig_task_state_value() {
  local value
  jig_task_state_var value "$1" "$2"
  [ "$_JIG_TS_FOUND" = 0 ] || printf '%s\n' "$value"
}

# jig_pause_request_refusal <id> — why `jig queue request task:<id> pause`
# refuses this task, or nothing when it would write the request. The task's
# state is asked first (jig_pause_request_state_refusal): a paused or closed
# task that still holds a request is refused for its state, not for the
# request. The command and the actions table (_task_actions) both ask it.
# <id> is a valid id of a task that exists; the caller checked.
jig_pause_request_refusal() {
  local refusal
  jig_pause_request_state_refusal_v refusal "$1"
  if [ -n "$refusal" ]; then
    printf '%s\n' "$refusal"
    return 0
  fi
  if jig_pause_request "$1"; then
    printf 'queue request: a pause of task:%s is already requested, at %s\n' "$1" "$_JIG_PAUSE_AT"
  fi
  return 0
}

# jig_pause_request_state_refusal <id> — the part of the refusal above that
# comes from the task's own state (paused, consolidated, abandoned, archived), or
# nothing. `jig queue request` refuses it with `failed`, and only a refusal
# past it — a request already pending — with `already-exists`.
jig_pause_request_state_refusal() {
  local refusal
  jig_pause_request_state_refusal_v refusal "$1"
  [ -z "$refusal" ] || printf '%s\n' "$refusal"
}

# jig_pause_request_state_refusal_v <var> <id> — the same refusal into <var>,
# empty for none.
jig_pause_request_state_refusal_v() {
  local __prs_v
  printf -v "$1" '%s' ""
  jig_task_state_var __prs_v "$2" status
  case "$__prs_v" in
    consolidated | abandoned | archived)
      printf -v "$1" 'queue request: task %s is %s' "$2" "$__prs_v"
      return 0 ;;
  esac
  jig_task_state_var __prs_v "$2" paused
  [ "$__prs_v" != true ] || printf -v "$1" 'queue request: task %s is already paused' "$2"
  return 0
}

# jig_pause_cancel_refusal <id> — why `jig queue cancel task:<id> pause`
# refuses, or nothing when there is a request to cancel.
jig_pause_cancel_refusal() {
  jig_pause_request "$1" || printf 'queue cancel: no pause of task:%s is requested\n' "$1"
  return 0
}

# jig_hash_git_dir — the git directory every hash in this project is computed
# against, empty when the project is not in a repository at all. Asked of git
# once per shell that asks, because it costs a git startup and `jig status`
# hashes on every invocation; a caller inside `$(...)` is a subshell and pays
# again, which is why the batching rule below matters more than this cache.
#
# `git hash-object` reads two things from wherever it happens to run, and both
# of them decide whether two hashes of identical bytes come out equal:
#
#   - the object format. In a repository created with --object-format=sha256 a
#     file hashes to 64 hex digits; outside any repository, to 40. `jig
#     upgrade` hashes the project inside it and its staging tree in $TMPDIR
#     outside it, so in a SHA-256 project every framework file compared
#     unequal: the first run replaced all 97 of them and wrote SHA-1 hashes
#     into a SHA-256 manifest, and from the second run on every file read as
#     `keep-modified` and `jig status` reported drift that was never there.
#   - the clean filters. A `filter=` driver or a `text` attribute makes the
#     hash of a path in a repository the hash of its *cleaned* content, which
#     the same bytes outside a repository do not have.
#
# --no-filters answers the second and not the first, so both are needed: one
# hash space for the project, and the bytes on disk as they are.
#
# Sets _JIG_HASH_GIT_DIR rather than printing it (jig_link_detect's pattern):
# a `$(...)` result would be computed in a subshell, where the answer could not
# be kept. An empty GIT_DIR is not "unset" to git but a fatal "the empty string
# is not a valid path", so every caller branches on it instead of exporting it.
jig_hash_git_dir() {
  [ -z "${_JIG_HASH_GIT_DIR_SET:-}" ] || return 0
  _JIG_HASH_GIT_DIR=$(git -C "${JIG_PROJECT:-.}" rev-parse --absolute-git-dir 2>/dev/null) \
    || _JIG_HASH_GIT_DIR=""
  _JIG_HASH_GIT_DIR_SET=1
}

# Content hash used by the manifest (ADR-0003, domains/install). git is mandatory,
# shasum/sha256sum are not portable. Hashed in the project's own hash space and
# without filters, the same way jig_hash_list does it: the two must never
# disagree about the hash of one file, or one writer of the manifest would
# record what the other reads as a modification.
jig_hash() {
  jig_hash_git_dir
  if [ -n "$_JIG_HASH_GIT_DIR" ]; then
    GIT_DIR="$_JIG_HASH_GIT_DIR" git hash-object --no-filters "$1"
  else
    git hash-object --no-filters "$1"
  fi
}

# jig_hash_stdin — jig_hash of the bytes on stdin: the same hash space, no
# filters, so content read out of git hashes as the same file on disk would.
jig_hash_stdin() {
  jig_hash_git_dir
  if [ -n "$_JIG_HASH_GIT_DIR" ]; then
    GIT_DIR="$_JIG_HASH_GIT_DIR" git hash-object --no-filters --stdin
  else
    git hash-object --no-filters --stdin
  fi
}

# jig_copy_tree <src-dir> <dst-dir> — copy every regular file under <src-dir>
# (`find -type f`: symlinks and empty directories are not copied) to the same
# relative path under <dst-dir>, with `cp -p`. Plain overwrite, no conflict
# handling: for scratch trees such as upgrade's stage, not for a project.
#
# One `mkdir -p` and one `cp` per directory rather than per file. The file list
# is sorted so each directory's files arrive together; a directory split
# around a subdirectory only costs an extra `cp`, never a wrong copy. The
# per-file loop — `dirname`, `mkdir` and `cp` for each of 43 framework files —
# was the largest part of what `jig status` still spent once hashing was
# batched.
jig_copy_tree() {
  local src="$1" dst="$2" f dir last="" n=0
  local -a batch
  mkdir -p "$dst"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    f=${f#./}
    case "$f" in
      */*) dir=${f%/*} ;;
      *) dir=. ;;
    esac
    if [ "$dir" != "$last" ] && [ "$n" -gt 0 ]; then
      mkdir -p "$dst/$last"
      cp -p "${batch[@]}" "$dst/$last/"
      n=0
      batch=()
    fi
    last=$dir
    batch[n]="$src/$f"
    n=$((n + 1))
  done < <(cd "$src" && find . -type f | LC_ALL=C sort)
  if [ "$n" -gt 0 ]; then
    mkdir -p "$dst/$last"
    cp -p "${batch[@]}" "$dst/$last/"
  fi
  return 0
}

# jig_hash_list <base> <file> — the blob hash of every path listed in <file>,
# one per line and in the same order, from a single `git hash-object` process
# run in <base>. Nothing for an empty list. Every listed path must exist under
# <base>: git fails the whole batch otherwise, which the caller turns into an
# error rather than a missing hash.
#
# The paths are relative to <base>, never absolute. MSYS converts a path only
# when it is an argument; on stdin Git for Windows gets /tmp/... verbatim and
# cannot open it — `jig upgrade` died on every Windows run with "could not open
# '/tmp/jig-upgrade-stage…'". A relative path is spelled the same everywhere.
#
# Use this, not a loop over jig_hash, whenever there is more than one file.
# Each call is a git startup, and on 65 manifest files the loop took 0.879 s
# where one call took 0.013 s — it was most of what `jig status` cost.
# Pair the output back with its paths by position (`paste`); a path containing
# a newline would desync that, and none of jig's line-based lists can hold one.
#
# <base> is often outside the project — `jig upgrade` hashes its staging tree in
# $TMPDIR — and the hash must come out the same as for the same bytes inside it,
# so the project's git directory travels with the call (jig_hash_git_dir).
jig_hash_list() {
  [ -s "$2" ] || return 0
  jig_hash_git_dir
  if [ -n "$_JIG_HASH_GIT_DIR" ]; then
    (cd "$1" && GIT_DIR="$_JIG_HASH_GIT_DIR" git hash-object --no-filters --stdin-paths) < "$2"
  else
    (cd "$1" && git hash-object --no-filters --stdin-paths) < "$2"
  fi
}

# jig_relpath_from <from> <to> — the relative path from directory <from> to
# path <to> (both absolute, no trailing slash required). Pure string
# computation, no filesystem access, so it also works for symlink targets that
# do not exist yet.
jig_relpath_from() {
  local __rfp_out
  jig_relpath_from_v __rfp_out "$1" "$2"
  printf '%s\n' "$__rfp_out"
}

# jig_relpath_from_v <var> <from> <to> — jig_relpath_from's answer into <var>,
# without a process: asked for every link of a link-mode install, on every
# `jig status` (convention-shell, `<name>_v`). Both paths are walked one
# `/`-separated component at a time: the shared leading ones are dropped, each
# one left of <from> is a `..`, and what is left of <to> follows. An empty
# component (a doubled or trailing `/`) is compared like any other and never
# printed.
jig_relpath_from_v() {
  local __rf_a="$2" __rf_b="$3" __rf_x __rf_up="" __rf_down="" __rf_am=1 __rf_bm=1
  [ -n "$__rf_a" ] || __rf_am=0
  [ -n "$__rf_b" ] || __rf_bm=0
  while [ "$__rf_am" = 1 ] && [ "$__rf_bm" = 1 ] && [ "${__rf_a%%/*}" = "${__rf_b%%/*}" ]; do
    case "$__rf_a" in */*) __rf_a=${__rf_a#*/} ;; *) __rf_am=0 ;; esac
    case "$__rf_b" in */*) __rf_b=${__rf_b#*/} ;; *) __rf_bm=0 ;; esac
  done
  while [ "$__rf_am" = 1 ]; do
    [ -z "${__rf_a%%/*}" ] || __rf_up="$__rf_up../"
    case "$__rf_a" in */*) __rf_a=${__rf_a#*/} ;; *) __rf_am=0 ;; esac
  done
  while [ "$__rf_bm" = 1 ]; do
    __rf_x=${__rf_b%%/*}
    [ -z "$__rf_x" ] || __rf_down="$__rf_down$__rf_x/"
    case "$__rf_b" in */*) __rf_b=${__rf_b#*/} ;; *) __rf_bm=0 ;; esac
  done
  __rf_x="$__rf_up$__rf_down"
  __rf_x=${__rf_x%/}
  [ -n "$__rf_x" ] || __rf_x=.
  printf -v "$1" '%s' "$__rf_x"
}

# jig_share_candidates <root> — the top-level directories of the checkout at
# <root> that `worktree.share` should name and does not, one per line: ignored
# by git, not a repository itself, holding at least one separate repository
# directly inside (a `.git` directory; a `.git` file is a worktree, not a
# package). Composer's path repositories under `packages/` are the case; a
# `vendor/<vendor>/<package>/.git` from --prefer-source is two levels down and
# is not. Read by `jig status` and by a worktree's bootstrap, which say so
# (adr-20261002-a-worktree-shares-a-directory-by-mirroring-it). [extra] is a
# newline list of directories shared besides the key — a task's own `share` —
# which count as declared.
jig_share_candidates() {
  local root="$1" extra="${2:-}" entry dir child declared="" one
  # Declared the way the bootstrap reads them: `packages/` names `packages`.
  while IFS= read -r one; do
    while :; do
      case "$one" in
        ?*/) one=${one%/} ;;
        *) break ;;
      esac
    done
    [ -z "$one" ] || declared="$declared$one
"
  done <<EOF
$(cfg_list_lines worktree.share)
$extra
EOF
  while IFS= read -r entry; do
    dir=${entry%/}
    [ -n "$dir" ] || continue
    case "$dir" in */*) continue ;; esac
    [ "$entry" != "$dir" ] || continue
    [ ! -e "$root/$dir/.git" ] || continue
    ! jig_has_line "$dir" "$declared" || continue
    for child in "$root/$dir"/*/.git "$root/$dir"/.[!.]*/.git; do
      if [ -d "$child" ]; then
        printf '%s\n' "$dir"
        break
      fi
    done
  done <<EOF
$(git -C "$root" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)
EOF
}

# Path of <file> relative to <base>, both absolute. Pure string operation.
jig_relpath() {
  local __rpp_out
  jig_relpath_v __rpp_out "$1" "$2"
  printf '%s\n' "$__rpp_out"
}

# jig_relpath_v <var> <file> <base> — jig_relpath's answer into <var>, without
# a process: for a caller that asks it of every file it places.
jig_relpath_v() {
  local __rp_base="${3%/}/"
  case "$2" in
    "$__rp_base"*) printf -v "$1" '%s' "${2#"$__rp_base"}" ;;
    *) printf -v "$1" '%s' "$2" ;;
  esac
}

# Age of a file in whole days (0 when it does not exist). Uses mtime.
jig_file_age_days() {
  local f="$1" mtime now
  [ -f "$f" ] || { printf '0\n'; return; }
  if mtime=$(stat -f %m "$f" 2>/dev/null); then :; else mtime=$(stat -c %Y "$f"); fi
  now=$(date +%s)
  printf '%d\n' $(( (now - mtime) / 86400 ))
}

# Convert a duration like 7d / 12h / 30m to seconds.
jig_duration_seconds() {
  local d="$1" n unit
  n=${d%[dhms]}; unit=${d#"$n"}
  case "$n" in ''|*[!0-9]*) jig_die "invalid duration: $d" ;; esac
  case "$unit" in
    d|'') printf '%d\n' $((10#$n * 86400)) ;;
    h) printf '%d\n' $((10#$n * 3600)) ;;
    m) printf '%d\n' $((10#$n * 60)) ;;
    s) printf '%d\n' $((10#$n)) ;;
  esac
}

# Fixed route vocabulary shared by context and knowledge metadata validation.
jig_valid_stage() {
  case "$1" in
    analyze | discover | specify | alternatives | design | plan | implement | review | architecture-review | verify | consolidate) return 0 ;;
    *) return 1 ;;
  esac
}

# Literal repository-relative paths for a review inventory (not shell/Git patterns).
jig_check_review_path() {
  case "$1" in
    '' | /* | *"$(printf '\t')"* | *'
'*) jig_die "task changes: unsupported path (absolute, empty, tab or newline): $1" ;;
  esac
  case "/$1/" in
    */../* | */./* | *//*) jig_die "task changes: path must be repository-relative without dot segments: $1" ;;
  esac
}

# jig_review_commit <ref> [message-prefix]
#
# The prefix names the *calling* command in the error. Without it the message
# was hardcoded to "task changes", so a second caller told the user about a
# command they had not run.
jig_review_commit() {
  local who="${2:-task changes}"
  case "$1" in '' | -*) jig_die "$who: invalid base: $1" ;; esac
  git -C "$JIG_PROJECT" rev-parse --verify "$1^{commit}" 2>/dev/null \
    || jig_die "$who: cannot resolve commit: $1"
}

# Strict inventory, path<TAB>layer. NUL Git output is decoded only after checking
# producer exit status; process substitution would hide a failing Git command.
# Buffer all rows so failures cannot be mistaken for a complete partial inventory.
jig_git_change_rows() (
  local base="$1" head="$2" layer path
  JIG_CHANGE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/jig-changes.XXXXXX") || exit 1
  trap 'rm -rf "$JIG_CHANGE_TMP"' EXIT
  : > "$JIG_CHANGE_TMP/rows"
  for layer in committed staged unstaged untracked; do
    case "$layer" in
      committed) git -C "$JIG_PROJECT" diff --no-ext-diff --no-textconv --ignore-submodules=none --no-renames --name-only -z "$base" "$head" -- > "$JIG_CHANGE_TMP/paths" ;;
      staged) git -C "$JIG_PROJECT" diff --no-ext-diff --no-textconv --ignore-submodules=none --no-renames --cached --name-only -z "$head" -- > "$JIG_CHANGE_TMP/paths" ;;
      unstaged) git -C "$JIG_PROJECT" diff --no-ext-diff --no-textconv --ignore-submodules=none --no-renames --name-only -z -- > "$JIG_CHANGE_TMP/paths" ;;
      untracked) git -C "$JIG_PROJECT" ls-files --others --exclude-standard -z > "$JIG_CHANGE_TMP/paths" ;;
    esac || jig_die "task changes: Git inventory failed for $layer"
    while IFS= read -r -d '' path; do
      jig_check_review_path "$path"
      printf '%s\t%s\n' "$path" "$layer" >> "$JIG_CHANGE_TMP/rows"
    done < "$JIG_CHANGE_TMP/paths"
  done
  # Through env, never `LC_ALL=C sort` as a statement: bash would restore its
  # own locale afterwards, which crashes Homebrew's bash on macOS in a forked
  # shell such as this one (conventions/shell.md).
  env LC_ALL=C sort -u "$JIG_CHANGE_TMP/rows"
)

# --- the verify run record, read ---------------------------------------------
#
# `jig verify` holds one record per clone while it runs (verify.sh, "one run per
# clone"). Reading it is shared here because `jig upgrade` asks the same
# question before it replaces the scripts a run in this checkout is executing,
# and one command library never sources another (ARCHITECTURE.md).

# jig_verify_busy_dir — where the record lives, or nothing.
#
# The clone's main checkout, which `jig_config_clone_root` already computes by
# reading git's own files — one answer from every worktree, no `git` process.
# ADR-0038 made reading there a named exception to ADR-0008; this extends it to
# writing, because what is being protected belongs to no checkout: the CPU is
# one per clone, and the eight runs were in eight different worktrees.
jig_verify_busy_dir() {
  local root
  root=$(jig_config_clone_root) || return 1
  [ -n "$root" ] || return 1
  printf '%s/%s/runtime/verify\n' "$root" "$JIG_AI_DIR"
}

# jig_verify_busy_ttl — how long a record still counts, in seconds. `0` is a
# duration the grammar already spells, and it switches the whole mechanism off:
# the escape for someone who genuinely wants parallel local runs, without a new
# flag to learn.
#
# One key with a working default, never one a person must fill. The duration
# grammar is the framework's one (`jig_duration_seconds`), and a mistyped value
# leaves the default standing rather than taking `jig verify` down.
jig_verify_busy_ttl() {
  local raw seconds
  raw=$(cfg verify.busy_ttl "30m")
  seconds=$(jig_duration_seconds "$raw" 2>/dev/null) || seconds=""
  case "$seconds" in
    '' | *[!0-9]*) seconds=1800 ;;
  esac
  printf '%s\n' "$seconds"
}

# _jig_verify_busy_mtime <file> — the file's mtime in seconds, or nothing.
#
# The BSD-then-GNU pair the session hook and the checkout record use, but
# **chosen on the value, never on the exit status** — and that distinction is
# the whole of this comment, because getting it wrong silently disabled the
# lock on every GNU system.
#
# `stat -f '%m' <file>` under GNU coreutils does not simply fail: `-f` means
# --file-system, so `%m` is read as a FILE operand, which errors, and then the
# real file prints a **file-system block on stdout**. The command exits
# non-zero, so `cmd && return 0` falls through to the GNU form and appends the
# real mtime to that block. The caller then holds several lines where it
# expected a number, rejects them, and reads the record's holder as gone: on
# Linux and in Git Bash the record was never once seen as live, and
# `jig verify` never waited for anything. It passed on macOS, where BSD stat
# answers the first form, which is exactly how it reached CI.
#
# `_jig_checkout_mtimes` survives the same idiom only because it reads its
# output line by line and skips what is not numeric. This reads one file, so it
# checks the value it got instead.
_jig_verify_busy_mtime() {
  jig_file_mtime "$1"
}

# jig_file_mtime <file> — the file's mtime in seconds since the epoch, or
# nothing (status 1). The BSD-then-GNU pair, chosen on the value and never on
# the exit status, for the reason _jig_verify_busy_mtime's comment above gives.
jig_file_mtime() {
  local out
  out=$(stat -f '%m' "$1" 2>/dev/null) || out=""
  case "$out" in
    '' | *[!0-9]*) out=$(stat -c '%Y' "$1" 2>/dev/null) || out="" ;;
  esac
  case "$out" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# jig_origin_fetched_at — when this clone last fetched, as UTC `YYYY-MM-DDTHH:MM:SSZ`,
# or non-zero when no fetch shows. Every worktree has a FETCH_HEAD of its own (Jig's
# own trees under the git directory included), so the newest of them answers; an empty
# one is passed over, since a fetch that failed empties it, which also loses the fetch
# it replaced. Any fetch writes it, of any branch or remote, so this says when the clone
# last reached out, not that origin's base was among what came back
# (adr-20261112-refresh-brings-the-clone-up-to-origin). No network.
jig_origin_fetched_at() {
  local d common f m best=""
  d=$(git -C "$JIG_PROJECT" rev-parse --git-common-dir 2>/dev/null) || return 1
  # Resolved by cd, as _ot_tree_path does: Git for Windows prints `C:/...`, which
  # matches no `/*` and would be taken for a relative path.
  common=$(cd "$JIG_PROJECT" 2>/dev/null && cd "$d" 2>/dev/null && pwd -P) || return 1
  for f in "$common/FETCH_HEAD" "$common"/worktrees/*/FETCH_HEAD; do
    [ -s "$f" ] || continue
    m=$(jig_file_mtime "$f") || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best=$m; fi
  done
  [ -n "$best" ] || return 1
  jig_utc_from_epoch "$best"
}

# jig_origin_counts <base> — "<behind> <ahead>": the commits origin/<base> has that
# <base> here does not, and the other way, as of the last fetch; non-zero when either
# branch is missing. No network.
jig_origin_counts() {
  local out
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$1^{commit}" >/dev/null 2>&1 || return 1
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$1^{commit}" >/dev/null 2>&1 || return 1
  out=$(git -C "$JIG_PROJECT" rev-list --left-right --count "refs/remotes/origin/$1...refs/heads/$1" 2>/dev/null) || return 1
  case "$out" in
    *[!0-9[:space:]]* | '') return 1 ;;
  esac
  printf '%s %s\n' "${out%%[[:space:]]*}" "${out##*[[:space:]]}"
}

# jig_utc_from_epoch <seconds> — the time as UTC `YYYY-MM-DDTHH:MM:SSZ`, or
# nothing (status 1). GNU `date -d @<n>` first: GNU's `-r` takes a file, so
# the BSD form tried first would read a file that happens to be named <n>.
jig_utc_from_epoch() {
  local out
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  out=$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
    || out=$(date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || out=""
  case "$out" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf '%s\n' "$out" ;;
    *) return 1 ;;
  esac
}

# _jig_verify_busy_value <file> <key> — the first `<key>: <value>` line, read by the
# shell alone. The CR is stripped explicitly because `read` keeps one where sed
# would not, and this record may be written under Windows.
_jig_verify_busy_value() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      "$key: "*)
        printf '%s\n' "${line#"$key": }"
        return 0
        ;;
    esac
  done < "$file"
  return 1
}

# jig_verify_busy_holder <dir> <ttl> — "<age in seconds> <checkout>" when a live
# run holds the record, nothing when none does.
#
# Two independent tests, and the record is live only when both pass:
#
#   1. `kill -0 <pid>` — a shell builtin, not `ps`, which ADR-0002 rules out
#      and which behaves differently under Git Bash anyway. This is the normal
#      path: a run killed by the sandbox gives the clone back at the next poll,
#      and that is exactly the death this task was written about.
#   2. the record's mtime is within the ttl — the backstop for when (1) is
#      wrong: another user's process reads as dead (EPERM), a recycled pid
#      reads as alive. Both errors are bounded. "Wrongly dead" is today's
#      behaviour; "wrongly alive" waits no longer than the ttl.
#
# A record with no readable pid falls back to the ttl alone, so a torn read can
# only cost a wait, never a wrong start.
jig_verify_busy_holder() {
  local dir="$1" ttl="$2" file mtime now age pid checkout
  file="$dir/busy/run"
  [ -f "$file" ] || return 1
  mtime=$(_jig_verify_busy_mtime "$file") || return 1
  case "$mtime" in
    '' | *[!0-9]*) return 1 ;;
  esac
  now=$(date +%s)
  if [ "$now" -lt "$mtime" ]; then age=0; else age=$((now - mtime)); fi
  [ "$age" -le "$ttl" ] || return 1
  pid=$(_jig_verify_busy_value "$file" pid) || pid=""
  case "$pid" in
    '' | *[!0-9]*) ;;
    "$$") return 1 ;;
    *) kill -0 "$pid" 2>/dev/null || return 1 ;;
  esac
  checkout=$(_jig_verify_busy_value "$file" checkout) || checkout=""
  [ -n "$checkout" ] || checkout="another checkout"
  printf '%s %s\n' "$age" "$checkout"
}

