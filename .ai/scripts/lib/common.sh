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

# jig_version_newer <a> <b> — true when release version <a> (`X.Y.Z`) is
# strictly newer than <b>, comparing each field as a number: 0.10.0 is newer
# than 0.9.0. False for equal versions and for anything that is not three
# numeric fields, so an unparsable version never reads as an upgrade.
jig_version_newer() {
  local a1 a2 a3 b1 b2 b3
  jig_release_version "v$1" >/dev/null || return 1
  jig_release_version "v$2" >/dev/null || return 1
  IFS=. read -r a1 a2 a3 <<EOF
$1
EOF
  IFS=. read -r b1 b2 b3 <<EOF
$2
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
# for `task`, `housekeeping`, `context` and `knowledge`, which must never
# disagree about what a task is judged against (ADR-0039). The state file is
# the task domain's; reading it here is allowed, writing it is not. An id that
# is not a task id gets the configured base, never a path built from it.
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

# _jig_release_fork <base> — the point HEAD forked from <base>: the later of
# its merge-bases with origin/<base> and the local <base>, so a stale
# remote-tracking ref does not take a raise merged in from a fresher local
# base for the task's own. Nothing when neither answers.
_jig_release_fork() {
  local ref fork="" f
  for ref in "refs/remotes/origin/$1" "refs/heads/$1"; do
    git -C "$JIG_PROJECT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue
    f=$(git -C "$JIG_PROJECT" merge-base "$ref" HEAD 2>/dev/null) || continue
    [ -n "$f" ] || continue
    if [ -z "$fork" ] || git -C "$JIG_PROJECT" merge-base --is-ancestor "$fork" "$f" 2>/dev/null; then
      fork="$f"
    fi
  done
  printf '%s\n' "$fork"
}

# jig_release_raise <base> — whether HEAD raises the version the project
# declares, against the point it forked from the branch <base>
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
  local fork f new old o n level
  fork=$(_jig_release_fork "$1")
  [ -n "$fork" ] || return 0
  for f in $JIG_VERSION_FILES; do
    new=$(jig_git_show_path HEAD "$f" 2>/dev/null | _jig_version_in "$f")
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
# none is added here; a caller cannot be made to wait no longer than N
# seconds without one.
jig_git_batch_ssh() {
  printf '%s -o BatchMode=yes\n' "${GIT_SSH_COMMAND:-ssh}"
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
# GIT_TERMINAL_PROMPT=0 and GIT_SSH_COMMAND (jig_git_batch_ssh): a command
# that only wanted fresh refs must not stop and wait for a password.
jig_fetch_branches() {
  local who="$1" name
  shift
  git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1 || return 0
  for name in "$@"; do
    [ -n "$name" ] || continue
    if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(jig_git_batch_ssh)" \
         git -C "$JIG_PROJECT" fetch --quiet origin \
         "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1; then
      jig_warn "$who: could not fetch $name from origin; using the refs this checkout has"
    fi
  done
  return 0
}

# --- forge -------------------------------------------------------------------

# jig_forge_kind — which forge CLI this checkout should use: cfg `forge`
# (auto|github|gitlab|none, default auto) resolved against the origin URL
# when auto, then confirmed actually usable here — the CLI on PATH and
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
    case "$origin" in
      *github.com*) want="github" ;;
      *gitlab.com*|*gitlab.*) want="gitlab" ;;
      *) printf 'none\n'; return 0 ;;
    esac
  fi

  case "$want" in
    github)
      if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        printf 'github\n'
      else
        printf 'none\n'
      fi
      ;;
    gitlab)
      if command -v glab >/dev/null 2>&1 && glab auth status >/dev/null 2>&1; then
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
# (adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci).

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
A new file is never staged for you: stage the ones that belong to the change (git add <path>), ignore or remove the rest, and run again."
  fi
  git -C "$JIG_PROJECT" add -u -- . \
    ":(exclude)$JIG_AI_DIR/workspace" ":(exclude)$JIG_AI_DIR/runtime" \
    || jig_die "$who: git add -u failed"
  staged=$(jig_ship_staged)
  [ -z "$staged" ] || printf '%s: nothing was staged; staged the tracked changes:\n%s\n' "$who" "$staged"
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
    unstaged=$( { git -C "$JIG_PROJECT" diff --name-only 2>/dev/null
                  jig_ship_untracked "$message_file" "$@"; } | sed '/^$/d')
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
# is the answer. GIT_TERMINAL_PROMPT=0 and GIT_SSH_COMMAND (jig_git_batch_ssh):
# shipping is not a place to sit waiting for a credential prompt either.
jig_ship_push() {
  local who="$1" branch="$2" out
  _jig_ship_outward "$who"
  if ! out=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(jig_git_batch_ssh)" \
             git -C "$JIG_PROJECT" push -u origin "$branch" 2>&1); then
    jig_die "$who: git push failed:
$out"
  fi
  printf 'pushed %s\n' "$branch"
}

# jig_ship_pr <who> <head> <base> <message-file> [<title>] [<body-file>] [<draft>]
# — open a pull request from <head> into <base> through whichever forge this
# checkout uses (jig_forge_kind), or report the one already open from <head>
# rather than opening a second. The title defaults to the message's first
# line, the body to the rest of it; <draft> 1 opens it as a draft. With no
# usable forge it says the pull request is the human's and returns 0. Leaves
# the URL in JIG_SHIP_URL, so it is called directly, never in `$()`.
# shellcheck disable=SC2034 # JIG_SHIP_URL is read by the caller
jig_ship_pr() {
  local who="$1" head="$2" base="$3" message_file="$4" title="${5:-}" body_file="${6:-}" draft="${7:-0}" kind
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
    github) _jig_ship_pr_github "$who" "$head" "$base" "$title" "$body_file" "$draft" ;;
    gitlab) _jig_ship_pr_gitlab "$who" "$head" "$base" "$title" "$body_file" "$draft" ;;
  esac
}

# _jig_ship_pr_github <who> <head> <base> <title> <body-file> <draft>
# shellcheck disable=SC2034 # JIG_SHIP_URL is read by the caller
_jig_ship_pr_github() {
  local who="$1" head="$2" base="$3" title="$4" body_file="$5" draft="$6" url out
  local extra=""
  [ "$draft" != 1 ] || extra="--draft"
  url=$(gh pr list --head "$head" --state open --json url --jq '.[0].url' 2>/dev/null || printf '')
  case "$url" in '' | null) url="" ;; esac
  if [ -n "$url" ]; then
    JIG_SHIP_URL="$url"
    printf 'pr %s (already open)\n' "$url"
    return 0
  fi
  # shellcheck disable=SC2086 # $extra is one flag or nothing
  out=$(gh pr create --base "$base" --head "$head" --title "$title" --body-file "$body_file" $extra 2>&1) \
    || jig_die "$who: gh pr create failed:
$out"
  url=$(printf '%s\n' "$out" | tail -n 1)
  JIG_SHIP_URL="$url"
  printf 'pr %s\n' "$url"
}

# _jig_ship_pr_gitlab <who> <head> <base> <title> <body-file> <draft> — the
# same through `glab`, whose JSON is read by jig_glab_fields, the reader
# housekeeping uses.
# shellcheck disable=SC2034 # JIG_SHIP_URL is read by the caller
_jig_ship_pr_gitlab() {
  local who="$1" head="$2" base="$3" title="$4" body_file="$5" draft="$6" out url desc
  local extra=""
  [ "$draft" != 1 ] || extra="--draft"
  out=$(glab mr list --source-branch "$head" --output json 2>/dev/null || printf '')
  url=$(printf '%s' "$out" | jig_glab_fields web_url | head -n 1)
  if [ -n "$url" ]; then
    JIG_SHIP_URL="$url"
    printf 'pr %s (already open)\n' "$url"
    return 0
  fi
  desc=$(cat "$body_file")
  # shellcheck disable=SC2086 # $extra is one flag or nothing
  out=$(glab mr create --target-branch "$base" --source-branch "$head" --title "$title" --description "$desc" $extra 2>&1) \
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

# jig_ship_merge <who> <url> <sha> <any|merge-commit> — merge the pull request
# at <url>, only as the commit <sha> that was shipped. Prints `merged <url>` or
# `not merged: <reason>` and returns 0 either way; dies (exit 1) only on an
# invalid agent.ci_timeout. The conditions, in order:
#   1. a forge this checkout can use, and a pull request to merge;
#   2. not a draft, and its head is <sha>;
#   3. a merge method the repository allows: `any` takes a merge commit, else
#      squash, else rebase; `merge-commit` takes a merge commit or nothing (an
#      epic: squash and rebase break the ancestry its tasks are judged by,
#      ADR-0040);
#   4. at least one check, and every check passed, within agent.ci_timeout
#      minutes — none, a red one or the timeout leaves it open;
#   5. the forge merges it at <sha> (GitHub `--match-head-commit`, GitLab
#      `--sha`) and agrees to: a refusal — branch protection, a required
#      review — leaves it open.
# Never `--admin`, never `--auto`: nothing here overrides the forge or asks it
# to merge later, when nobody is watching the conditions. Leaves the answer in
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
    github) _jig_ship_merge_github "$url" "$sha" "$policy" "$timeout" ;;
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
  out=$(gh pr checks "$1" --json bucket --jq '.[].bucket' 2>/dev/null) || true
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
  if ! view=$(gh pr view "$url" --json isDraft,headRefOid --jq '"\(.isDraft) \(.headRefOid)"' 2>/dev/null); then
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
  allowed=$(gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed \
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
      printf 'not merged: the repository does not allow merge commits, and an epic merges only with one\n'
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
  if ! out=$(gh pr merge "$url" --match-head-commit "$sha" "--$method" 2>&1); then
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
# `merge-commit` needs a merge commit and a squash that is off by default.
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
    merge-commit:merge:never | merge-commit:merge:default_off \
      | merge-commit:rebase_merge:never | merge-commit:rebase_merge:default_off) ;;
    merge-commit:?*:?*)
      printf 'not merged: the project does not merge with a merge commit, and an epic merges only with one\n'
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
  local url="$1" kind
  [ -n "$url" ] || { printf 'unknown\n'; return 0; }
  kind=$(jig_forge_kind) || exit 1
  case "$kind" in
    github) _jig_pr_state_github "$url" ;;
    gitlab) _jig_pr_state_gitlab "$url" ;;
    *) printf 'unknown\n' ;;
  esac
}

_jig_pr_state_github() {
  local state
  state=$(gh pr view "$1" --json state --jq .state 2>/dev/null) || { printf 'unknown\n'; return 0; }
  case "$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')" in
    merged) printf 'merged\n' ;;
    open) printf 'open\n' ;;
    closed) printf 'closed\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

_jig_pr_state_gitlab() {
  local iid json state
  iid=$(_jig_ship_glab_mr "$1")
  [ -n "$iid" ] || { printf 'unknown\n'; return 0; }
  json=$(glab mr view "$iid" --output json 2>/dev/null) || { printf 'unknown\n'; return 0; }
  state=$(printf '%s' "$json" | tr -d ' \n' | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
  case "$state" in
    merged) printf 'merged\n' ;;
    opened) printf 'open\n' ;;
    closed) printf 'closed\n' ;;
    *) printf 'unknown\n' ;;
  esac
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
  jig_branch_is_jigs "$b" || return 0
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
  out=$(jig_branches_leave_origin "$who" "$b" "$sha")
  case "$out" in
    *": deleted branch $b on origin")
      printf '%s\n' "$out"
      return 0
      ;;
  esac
  if out=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(jig_git_batch_ssh)" \
       git -C "$JIG_PROJECT" ls-remote --heads origin "refs/heads/$b" 2>/dev/null) && [ -z "$out" ]; then
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
  out=$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(jig_git_batch_ssh)" \
    git -C "$JIG_PROJECT" push --porcelain "${leases[@]}" origin "${refs[@]/#/:refs/heads/}" 2>/dev/null || true)
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
  jig_branch_is_jigs "$b" || return 0
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
  local rel
  rel=$(jig_relpath "$1" "$JIG_PROJECT")
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
  fm_get "$1" source
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
  local src
  src=$(jig_knowledge_source "$1")
  if [ -z "$src" ]; then
    jig_relpath "$1" "$JIG_PROJECT"
    return 0
  fi
  printf '%s\n' "$src"
  case "$src" in
    /* | ../* | */../* | *.. ) return 3 ;;
  esac
  if [ ! -f "$JIG_PROJECT/$src" ] || [ -L "$JIG_PROJECT/$src" ]; then
    return 3
  fi
  local root dir
  root=$(cd -P "$JIG_PROJECT" 2>/dev/null && pwd -P) || return 3
  dir=$(cd -P "$(dirname "$JIG_PROJECT/$src")" 2>/dev/null && pwd -P) || return 3
  case "$dir/" in
    "$root/"*) return 0 ;;
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
  pattern=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/?/\\?/g; s/\[/\\[/g; s/\]/\\]/g')
  pattern=$(printf '%s' "$pattern" | sed 's#[*][*]/#*#g; s#[*][*]#*#g')
  case "$pattern" in
    */) printf '%s*' "$pattern" ;;
    *) printf '%s' "$pattern" ;;
  esac
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
  pattern=$(jig_glob_pattern "$glob")
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
# the same one, ADR-0008 as amended 2026-09-25). Raising it claims the next
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

# jig_revision_dir — where the counter lives; fails outside a project.
jig_revision_dir() {
  local root
  [ -n "${JIG_PROJECT:-}" ] || return 1
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
  awk -v from="$1" -v to="$2" '
    BEGIN {
      n1 = split(from, a, "/")
      n2 = split(to, b, "/")
      i = 1
      while (i <= n1 && i <= n2 && a[i] == b[i]) i++
      up = ""
      for (j = i; j <= n1; j++) if (a[j] != "") up = up "../"
      down = ""
      for (j = i; j <= n2; j++) if (b[j] != "") down = down b[j] "/"
      result = up down
      sub(/\/$/, "", result)
      if (result == "") result = "."
      print result
    }
  '
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
  local base="${2%/}/" file="$1"
  case "$file" in
    "$base"*) printf '%s\n' "${file#"$base"}" ;;
    *) printf '%s\n' "$file" ;;
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
    d|'') printf '%d\n' $((n * 86400)) ;;
    h) printf '%d\n' $((n * 3600)) ;;
    m) printf '%d\n' $((n * 60)) ;;
    s) printf '%d\n' "$n" ;;
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
  LC_ALL=C sort -u "$JIG_CHANGE_TMP/rows"
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

