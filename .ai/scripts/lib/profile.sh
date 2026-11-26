# Library for profile verify.sh scripts (adr-20260918-profiles-narrow-per-check-with-project-tools; domains/verify).
#
# A profile sources it relative to its own file:
#
#   . "$(dirname "$0")/../../scripts/lib/profile.sh"
#
# which resolves to scripts/lib/ in the framework source and to
# .ai/scripts/lib/ in a project, in copy and link mode alike: profiles and
# scripts sit at the same depth in both layouts. No capability is needed —
# the library is installed with every jig.
#
# The functions below are a distributed interface. A profile a user edited
# is kept by `upgrade` (keep-modified) and meets whatever library the
# upgrade installed, so a function here is never renamed or given a new
# meaning; a new behaviour is a new function.
#
# Contract recap (ARCHITECTURE.md, profile contract): a profile runs from the
# repository root, prints one line per check — `<profile>: <check>:
# pass|fail|skip|incomplete (<note>)` — and exits 0 pass, 1 fail, 2 when no
# check ran, 3 when a check did not finish
# (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass).
# Scope (ADR-0013): JIG_VERIFY_SCOPE=changed and JIG_VERIFY_FILES name the
# changed paths. Map (ADR-0041): JIG_VERIFY_MAPPED carries `jig verify`'s
# decision per path, `?` where the project's map had no line.
# bash 3.2 compatible.
# shellcheck shell=bash

JP_PROFILE=""
JP_STATUS=0
JP_RAN=0
JP_SCOPED=0
JP_INCOMPLETE=0

# jp_plan <check> <state> <reason> — one line of the optional explain
# protocol. Keep it separate from jp_run/jp_skip: installed user profiles
# depend on their existing meanings and exit codes.
jp_plan() {
  local check="$1" state="$2" reason="$3"
  if [ "$JP_SCOPED" = 1 ] && [ ! -s "$JIG_VERIFY_FILES" ]; then
    state=skip
    reason="scope: changed, no changed files"
  fi
  case "$state" in
    full|filtered|skip|conditional) ;;
    *) return 1 ;;
  esac
  reason=${reason//$'\n'/, }
  printf 'PLAN %s: %s: %s (%s)\n' "$JP_PROFILE" "$check" "$state" "$reason"
}

# jp_plan_selection <check> <selection> <label> [reason] — a common shape for
# checks whose narrowed filters come from jp_decide. Callers handle missing
# filters and tool-specific uncertainty before using this helper.
#
# [reason] is why the full set runs, for the ALL case only, and a profile
# builds it from the path jp_decide_cause names. Optional on purpose: a
# profile that passes nothing keeps the wording it had, so this argument
# cannot change an installed user profile's plan.
jp_plan_selection() {
  local check="$1" selection="$2" label="$3" reason="${4:-}" listed
  if ! jp_scoped; then
    jp_plan "$check" full "full scope"
  elif [ -z "$selection" ]; then
    jp_plan "$check" skip "no changed file maps to this check"
  elif [ "$selection" = ALL ]; then
    jp_plan "$check" full "${reason:-changed paths require the full set}"
  else
    listed=$(printf '%s\n' "$selection" | paste -sd, -)
    jp_plan "$check" filtered "$label: $listed"
  fi
}

# jp_begin <profile> — start a profile run: name it and read the scope.
jp_begin() {
  JP_PROFILE="$1"
  JP_STATUS=0
  JP_RAN=0
  JP_SCOPED=0
  JP_INCOMPLETE=0
  if [ "${JIG_VERIFY_SCOPE:-}" = changed ] && [ -n "${JIG_VERIFY_FILES:-}" ] \
     && [ -f "${JIG_VERIFY_FILES:-}" ]; then
    JP_SCOPED=1
  fi
  return 0
}

# jp_scoped — exit 0 when this run is narrowed to changed files.
jp_scoped() { [ "$JP_SCOPED" = 1 ]; }

# _jp_dropped_by_v <var> <role> — the layer that dropped <role>, from the
# `<role><TAB>drop<TAB><layer>` row of JIG_VERIFY_CHECKS, into <var>; empty when
# no row says so.
_jp_dropped_by_v() {
  local __jd_r __jd_f __jd_v
  printf -v "$1" '%s' ""
  [ -n "${JIG_VERIFY_CHECKS:-}" ] && [ -f "$JIG_VERIFY_CHECKS" ] || return 0
  while IFS=$'\t' read -r __jd_r __jd_f __jd_v || [ -n "$__jd_r" ]; do
    if [ "$__jd_r" = "$2" ] && [ "$__jd_f" = drop ]; then
      printf -v "$1" '%s' "$__jd_v"
      return 0
    fi
  done < "$JIG_VERIFY_CHECKS"
  return 0
}

# jp_covered <check> <label> — exit 0 when another profile in this run took
# over this profile's check named <check> (a role such as `tests`, never a
# tool), after printing the check's skip line — or its PLAN line under
# `--explain` — under <label>, the name the check's other lines use. Exit 1
# otherwise, and the caller runs the check as before.
#
# The profile names its own check and nothing else: which profile covers it
# is `jig verify`'s decision, made from the covering profile's
# `covers: [<profile>:<check>]` and this profile's `checks: [<check>]`, and
# handed down as JIG_VERIFY_COVERED (`<check>=<profile>` words). Without it
# nothing is covered, so a check never stands down on a guess. The reason
# starts `scope:`: the check's tools are fine and the work is another
# profile's, so a run where everything else narrowed away is not read as a
# gap in coverage (adr-20261107-a-profile-covers-a-check-of-another).
#
# A second reason stands the check down the same way: a layer above this
# profile dropped it (`checks.<check>.drop: true` in the layer's profile.yaml),
# which `jig verify` hands down as a `<check><TAB>drop<TAB><layer>` row of
# JIG_VERIFY_CHECKS. The skip then reads `scope: dropped by <layer>, <profile>:
# <check>` — the work is nobody's in this run, a decision of the project, not a
# gap to fix (adr-20261118-a-layer-overrides-its-bases-checks-by-role). A cover
# wins when both hold. Signature and return codes are as they were.
jp_covered() {
  local check="$1" label="$2" word by="" reason IFS=$' \t\n' dropper=""
  set -f
  for word in ${JIG_VERIFY_COVERED:-}; do
    case "$word" in
      "$check="?*) by=${word#*=}; break ;;
    esac
  done
  set +f
  if [ -n "$by" ]; then
    reason="scope: covered by $by, $JP_PROFILE:$check"
  else
    _jp_dropped_by_v dropper "$check"
    [ -n "$dropper" ] || return 1
    reason="scope: dropped by $dropper, $JP_PROFILE:$check"
  fi
  if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
    jp_plan "$label" skip "$reason"
  else
    jp_skip "$label" "$reason"
  fi
  return 0
}

# jp_check_cmd <role> <label> full|narrowed <default-cmd>... [-- <selection>...]
# — the command line of check <role> in JP_CMD, from the check table of the
# profile's profile.yaml (`checks.<role>.command|full|narrowed`,
# schemas/profile.md): the table's `command` words, or <default-cmd> when the
# table has none (the profile chooses its tool on the fly: phpunit or pest, a
# wrapper or mvn), then the mode's argument words. In `narrowed` mode the one
# `{selection}` word of the arguments becomes the <selection> words after `--`,
# one argument each, so an item with a blank in it stays one argument. `full`
# is also the mode of a narrowed run that falls back to the full set. An
# absent `full` is no arguments; `[]` is no words. Words are split on blanks
# and never globbed. Use it as
#
#   jp_check_cmd tests "$label" narrowed "$test_bin" -- "$@" || continue
#   jp_run "$label" "$note" "${JP_CMD[@]}"
#
# A role a layer dropped (a `<role> drop <layer>` row, see jp_covered) is not
# run: it prints the skip `scope: dropped by <layer>, <profile>:<role>` — a PLAN
# skip under `--explain` — and returns 1, so a verify.sh that never called
# jp_covered still runs nothing the project removed.
#
# Returns 1, after printing the check's fail line under <label> — or a PLAN
# skip line under `--explain`, which is no verdict — when the table cannot
# answer: `jig verify` hands it down as JIG_VERIFY_CHECKS, a file of
# `<role> <field> <value>` rows, and the role is not in it, or `narrowed` mode
# finds no `narrowed` field. A fail, not a skip: a skip beside another check
# that passed leaves the profile `pass` with this check unrun. It means a
# profile.yaml kept by `upgrade` beside a newer verify.sh; the profile does not
# fall back to a command of its own, because a silently different command is
# the worse answer (adr-20261117-a-profile-declares-its-checks-in-a-table).
# Called as a command, never inside `$( )`: it sets JP_CMD, which is never
# empty after a return 0.
# shellcheck disable=SC2034  # JP_CMD is read by the profile that sourced this
jp_check_cmd() {
  local role="$1" label="$2" mode="$3" r f v w reason=""
  local known=0 have_cmd=0 have_full=0 have_narrowed=0 cmd_v="" full_v="" narrowed_v="" dropper=""
  local -a cmdw=() argw=() sel=() defw=()
  shift 3
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    defw+=("$1")
    shift
  done
  [ "$#" -eq 0 ] || shift
  sel=("$@")
  case "$mode" in
    full|narrowed) ;;
    *) printf 'jp_check_cmd: mode must be full or narrowed, not %s\n' "$mode" >&2; return 2 ;;
  esac
  _jp_dropped_by_v dropper "$role"
  if [ -n "$dropper" ]; then
    reason="scope: dropped by $dropper, $JP_PROFILE:$role"
    if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
      jp_plan "$label" skip "$reason"
    else
      jp_skip "$label" "$reason"
    fi
    return 1
  fi
  if [ -n "${JIG_VERIFY_CHECKS:-}" ] && [ -f "$JIG_VERIFY_CHECKS" ]; then
    while IFS=$'\t' read -r r f v || [ -n "$r" ]; do
      [ "$r" = "$role" ] || continue
      known=1
      case "$f" in
        command) [ "$have_cmd" = 1 ] || { have_cmd=1; cmd_v=$v; } ;;
        full) [ "$have_full" = 1 ] || { have_full=1; full_v=$v; } ;;
        narrowed) [ "$have_narrowed" = 1 ] || { have_narrowed=1; narrowed_v=$v; } ;;
      esac
    done < "$JIG_VERIFY_CHECKS"
  fi
  if [ "$known" = 0 ]; then
    reason="profile.yaml names no check '$role'; carry your edits onto the stock profile's new profile.yaml"
  elif [ "$mode" = narrowed ] && [ "$have_narrowed" = 0 ]; then
    reason="profile.yaml has no checks.$role.narrowed; carry your edits onto the stock profile's new profile.yaml"
  fi
  if [ -n "$reason" ]; then
    if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
      jp_plan "$label" skip "$reason"
    else
      jp_fail "$label" "$reason"
    fi
    return 1
  fi
  # `read -a` splits on the IFS blanks and never globs; `[]` is no words.
  if [ "$have_cmd" = 1 ] && [ "$cmd_v" != "[]" ]; then
    IFS=$' \t' read -r -a cmdw <<EOF
$cmd_v
EOF
  else
    cmdw=(${defw[@]+"${defw[@]}"})
  fi
  if [ "$mode" = narrowed ]; then
    v=$narrowed_v
  elif [ "$have_full" = 1 ]; then
    v=$full_v
  else
    v="[]"
  fi
  if [ "$v" != "[]" ]; then
    IFS=$' \t' read -r -a argw <<EOF
$v
EOF
  fi
  JP_CMD=(${cmdw[@]+"${cmdw[@]}"})
  for w in ${argw[@]+"${argw[@]}"}; do
    if [ "$mode" = narrowed ] && [ "$w" = "{selection}" ]; then
      JP_CMD+=(${sel[@]+"${sel[@]}"})
    else
      JP_CMD+=("$w")
    fi
  done
  if [ "${#JP_CMD[@]}" -eq 0 ]; then
    if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
      jp_plan "$label" skip "profile.yaml gives no command for '$role'; carry your edits onto the stock profile's new profile.yaml"
    else
      jp_fail "$label" "profile.yaml gives no command for '$role'; carry your edits onto the stock profile's new profile.yaml"
    fi
    return 1
  fi
  return 0
}

# jp_has_line <line> <text> — exit 0 when <line> is a whole line of <text>,
# compared as a string: common.sh's jig_has_line for profiles, which source
# this file alone. A `case`, never `printf | grep -q`: bash writes a pipe line
# by line, and under pipefail the SIGPIPE a reader that quit early leaves
# printf with turns a match into a failure (conventions/shell.md).
jp_has_line() {
  case $'\n'"$2"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# jp_changed [<ext>...] — changed paths that still exist, one per line; with
# extensions (`py`, `ts`), only those. Empty outside a scoped run.
jp_changed() {
  local f ext
  jp_scoped || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if [ $# -eq 0 ]; then
      printf '%s\n' "$f"
      continue
    fi
    for ext in "$@"; do
      case "$f" in
        *."$ext") printf '%s\n' "$f"; break ;;
      esac
    done
  done < "$JIG_VERIFY_FILES"
  return 0
}

# jp_changed_any <glob>... — exit 0 when a changed path, deleted ones
# included, matches one of the globs (`*` crosses `/`). For the files whose
# change sends a check to its full set: a manifest, a lock file, a config.
jp_changed_any() {
  local f g
  jp_scoped || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for g in "$@"; do
      # shellcheck disable=SC2254
      case "$f" in
        $g) return 0 ;;
      esac
    done
  done < "$JIG_VERIFY_FILES"
  return 1
}

# _jp_decide_raw <builtin-fn> — jp_decide's answers before deduplication.
# A function of its own because bash 3.2 misparses a `case` written inside
# `$( )`.
_jp_decide_raw() {
  # A decision's filters are space-separated whatever IFS the caller left.
  local fn="$1" f decision tok IFS=$' \t\n'
  if [ -n "${JIG_VERIFY_MAPPED:-}" ] && [ -f "${JIG_VERIFY_MAPPED:-}" ]; then
    while IFS="$(printf '\t')" read -r f decision; do
      [ -n "$f" ] || continue
      case "$decision" in
        '?') "$fn" "$f" ;;
        -) ;;
        *)
          # A decision comes from a hand-edited file: a token must never
          # expand against the project's files.
          set -f
          for tok in $decision; do printf '%s\n' "$tok"; done
          set +f
          ;;
      esac
    done < "$JIG_VERIFY_MAPPED"
  else
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      "$fn" "$f"
    done < "$JIG_VERIFY_FILES"
  fi
  return 0
}

# jp_decide <builtin-fn> — the tests a narrowed run needs, one per line:
# filters, or the single token ALL. For each changed path the project map
# decides (`-` nothing, `ALL`, filters); where it has no line (`?`), or there
# is no map, <builtin-fn> <path> answers with the same vocabulary — nothing,
# ALL, or filters. Sorted and deduplicated; ALL wins over everything.
jp_decide() {
  local out
  jp_scoped || return 0
  out=$(_jp_decide_raw "$1")
  if jp_has_line ALL "$out"; then
    printf 'ALL\n'
  else
    printf '%s\n' "$out" | sed '/^$/d' | LC_ALL=C sort -u
  fi
  return 0
}

# _jp_cause_raw <builtin-fn> — the changed paths <builtin-fn> answers ALL for,
# in the order they were read. A function of its own for the same bash 3.2
# reason as _jp_decide_raw.
_jp_cause_raw() {
  local fn="$1" f decision IFS=$' \t\n'
  if [ -n "${JIG_VERIFY_MAPPED:-}" ] && [ -f "${JIG_VERIFY_MAPPED:-}" ]; then
    while IFS="$(printf '\t')" read -r f decision; do
      [ -n "$f" ] || continue
      case "$decision" in
        '?')
          # An `if`, not `a && b`: under set -e a non-matching path as the
          # loop body's last command would end the loop and truncate the answer.
          if jp_has_line ALL "$("$fn" "$f")"; then printf '%s\n' "$f"; fi
          ;;
      esac
    done < "$JIG_VERIFY_MAPPED"
  else
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if jp_has_line ALL "$("$fn" "$f")"; then printf '%s\n' "$f"; fi
    done < "$JIG_VERIFY_FILES"
  fi
  return 0
}

# jp_decide_cause <builtin-fn> — the first changed path whose own rule makes
# jp_decide answer ALL, so a profile can say which file widened the run
# instead of only that something did. "changed paths require the full set"
# named nothing, and a person reading it could not tell their package.json
# from their orphan class.
#
# Empty when nothing forces ALL, and empty as well when the project's own
# .ai/verify/<profile>.map is what said ALL: that line is one its author
# wrote, and attributing it to a rule of the profile's would be a wrong
# explanation rather than a missing one.
jp_decide_cause() {
  local out
  jp_scoped || return 0
  # Not `| head -1`: the writer is a bash function, and a reader that stops
  # before the end of its input leaves it with SIGPIPE, which pipefail reads
  # as a failure (conventions/shell.md). Take the first line from the string.
  out=$(_jp_cause_raw "$1" | sed '/^$/d')
  [ -n "$out" ] || return 0
  printf '%s\n' "${out%%$'\n'*}"
  return 0
}

# --- the full set under `verify.full_run: ci` ---------------------------------
#
# A project that declares `verify.full_run: ci` has said CI runs every check on
# each pull request, and its owner wants the full set run there and nowhere else
# unasked (adr-0041, amendment 2026-10-08). So a narrowed run never starts a
# check's full set: what it can name it runs, the full set it leaves to CI and
# says so on the check's line. `jig verify --full` (and a non-empty CI) runs the
# profile unnarrowed, where none of this applies. The skip line's reason starts
# with `scope:`, so `jig verify` counts it as narrowing, never as a missing tool.
# New functions rather than new meanings for jp_decide or jp_run: a profile a
# user edited keeps running the full set, as it was written to.

JP_SELECTION=""
JP_SELECTION_NOTE=""

# jp_ci_runs_full — exit 0 when this run is narrowed and the project declared
# `verify.full_run: ci`: the full set belongs to CI.
jp_ci_runs_full() {
  jp_scoped && [ "${JIG_VERIFY_FULL_RUN:-}" = ci ]
}

# jp_select <builtin-fn> — jp_decide's answer in JP_SELECTION, with what the
# narrowed run must say about it in JP_SELECTION_NOTE. Under `ci` an ALL beside
# filters is dropped: the filters run here, the full set is left to CI, and
# JP_SELECTION_NOTE is ", full set left to CI" for the check's line. ALL alone
# stays ALL, for the caller to hand to jp_full_left_to_ci. Called as a command,
# never inside `$( )`: it sets globals.
# shellcheck disable=SC2034  # JP_SELECTION is read by the profile that sourced this
jp_select() {
  local raw rest
  JP_SELECTION=""
  JP_SELECTION_NOTE=""
  jp_scoped || return 0
  raw=$(_jp_decide_raw "$1")
  if ! jp_has_line ALL "$raw"; then
    JP_SELECTION=$(printf '%s\n' "$raw" | sed '/^$/d' | LC_ALL=C sort -u)
    return 0
  fi
  JP_SELECTION=ALL
  jp_ci_runs_full || return 0
  rest=$(printf '%s\n' "$raw" | sed -e '/^ALL$/d' -e '/^$/d' | LC_ALL=C sort -u)
  if [ -n "$rest" ]; then
    JP_SELECTION="$rest"
    JP_SELECTION_NOTE=", full set left to CI"
  fi
  return 0
}

# jp_full_left_to_ci <check> <why> — at a point where a narrowed run would start
# <check>'s full set because of <why>: under `ci`, print the check's skip line
# and exit 0, so the caller runs nothing; otherwise exit 1 and the caller runs
# the full set as before. Use as `jp_full_left_to_ci "$c" "$why" || jp_run …`.
jp_full_left_to_ci() {
  jp_ci_runs_full || return 1
  printf '%s: %s: skip (scope: %s, full set left to CI)\n' "$JP_PROFILE" "$1" "$2"
  return 0
}

# jp_plan_full <check> <reason> — the explain line for a check whose narrowed
# run needs the full set: `full` as jp_plan always said, `skip` under `ci`.
jp_plan_full() {
  if jp_ci_runs_full; then
    jp_plan "$1" skip "scope: $2, full set left to CI"
  else
    jp_plan "$1" full "$2"
  fi
}

# jp_plan_select <check> <selection> <label> [reason] — jp_plan_selection for a
# selection jp_select made: an ALL goes through jp_plan_full, and filters that
# stand in for a dropped ALL say the full set is left to CI.
jp_plan_select() {
  local check="$1" selection="$2" label="$3" reason="${4:-}" listed
  if jp_scoped && [ "$selection" = ALL ]; then
    jp_plan_full "$check" "${reason:-changed paths require the full set}"
  elif jp_scoped && [ -n "$selection" ] && [ -n "$JP_SELECTION_NOTE" ]; then
    listed=$(printf '%s\n' "$selection" | paste -sd, -)
    jp_plan "$check" filtered "$label: $listed$JP_SELECTION_NOTE"
  else
    jp_plan_selection "$@"
  fi
}

# jp_path_matches <path> <glob-list> — exit 0 when <path> matches one of the
# space-separated globs in <glob-list> (`*` crosses `/`). The list is split
# with pathname expansion off: `for g in $list` would otherwise expand
# `config/*` against the files on disk, so a deleted or nested file would
# stop matching the pattern meant to send its change to the full set.
jp_path_matches() {
  # The list is space-separated whatever IFS the calling profile left set.
  local f="$1" g IFS=$' \t\n'
  set -f
  for g in $2; do
    # shellcheck disable=SC2254
    case "$f" in
      $g) set +f; return 0 ;;
    esac
  done
  set +f
  return 1
}

# jp_is_doc <path> — exit 0 for documentation and jig's own state: prose
# (`*.md`, `*.mdx`, `*.rst`, `docs/`) and anything under `.ai/`. No stack's
# check reads them, so a built-in rule answers "nothing" for them rather than
# running a check for a change it cannot see.
jp_is_doc() {
  case "$1" in
    *.md|*.mdx|*.rst|docs/*|.ai/*) return 0 ;;
  esac
  return 1
}

# jp_first_missing <path>... — print the first argument that is not an
# existing file or directory; exit 1 when all exist. A filter that names
# nothing selects no test, and a narrowing that selects nothing is not a pass
# (ADR-0041): the caller runs the full set instead.
jp_first_missing() {
  local p
  for p in "$@"; do
    if [ ! -e "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# jp_files — every file of the project, one per line. Inside git the list
# comes from git (tracked and untracked, not ignored), so a virtualenv,
# node_modules or a nested worktree is never walked; outside git, a find
# that prunes the usual dependency directories.
jp_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -co --exclude-standard 2>/dev/null \
      | while IFS= read -r f; do
          [ -f "$f" ] && printf '%s\n' "$f"
        done
    return 0
  fi
  find . \( -name .git -o -name node_modules -o -name vendor -o -name .venv \
            -o -name venv -o -name target -o -name build -o -name .dart_tool \) -prune \
    -o -type f -print 2>/dev/null | sed 's#^\./##'
  return 0
}

# jp_exec <cmd...> — run a command where the project runs. `jig verify`
# hands a profile that declares `scope: [..., environment]` the command prefix
# that reaches the project's environment as JIG_RUN_EXEC (`docker compose exec
# -T -w /app app`), and the command runs through it; with no prefix it runs as
# is, on this machine. A profile that does not declare the capability never
# receives one, so for it this is exactly "$@"
# (adr-20261001-checks-run-where-the-project-runs). The prefix is plain words,
# split on blanks and never globbed. Stdin is closed under a prefix: `docker
# compose exec` would otherwise read the input of the loop a profile calls it
# from. With JIG_VERIFY_RUN_TOKEN set (only `jig verify` sets it, only beside a
# prefix) the command runs as `env JIG_VERIFY_RUN=<token> <cmd>`: every process
# of its tree carries the token, which is how `jig verify` finds and ends what a
# stopped run left in the container
# (adr-20261125-verify-ends-the-processes-it-started).
jp_exec() {
  local -a pre
  if [ -z "${JIG_RUN_EXEC:-}" ]; then
    "$@"
    return
  fi
  read -r -a pre <<EOF
$JIG_RUN_EXEC
EOF
  if [ -n "${JIG_VERIFY_RUN_TOKEN:-}" ]; then
    "${pre[@]}" env "JIG_VERIFY_RUN=$JIG_VERIFY_RUN_TOKEN" "$@" </dev/null
  else
    "${pre[@]}" "$@" </dev/null
  fi
}

# jp_have <cmd> — exit 0 when <cmd> can be run where the project runs: the
# environment's own `command -v` under a prefix, this shell's otherwise. A
# profile that probes with `command -v` asks the host, which under a container
# environment is the wrong machine.
jp_have() {
  if [ -z "${JIG_RUN_EXEC:-}" ]; then
    command -v "$1" >/dev/null 2>&1
    return
  fi
  # shellcheck disable=SC2016  # $1 is the inner shell's argument, by design
  jp_exec sh -c 'command -v "$1" >/dev/null 2>&1' sh "$1" >/dev/null 2>&1
}

# jp_version <cmd...> — the first non-empty line of a tool's version answer
# (Gradle's banner starts with a blank line), or `unknown`. Never fails the
# profile: a tool that cannot answer --version must not abort the check it
# only annotates (domains/verify RULES).
jp_version() {
  local v
  v=$(jp_exec "$@" 2>/dev/null | sed '/^[[:space:]]*$/d' | sed -n '1p') || v=""
  [ -n "$v" ] || v="unknown"
  printf '%s\n' "$v"
}

# jp_run <check> <note> <cmd...> — run a check and print its line. <note> is
# what the verdict must carry (the tool version, the scope); empty for none.
# A check killed by a signal is reported apart from one that failed. bash
# returns 128+N for a child that died on signal N, so `Killed: 9` arrives here
# as 137 and `Terminated: 15` as 143 — and until now both read as "the tests
# failed". They are not the same answer: a run that died produced no verdict,
# and reading one out of it cost hours three times in one night, none of them
# with a cause in the code
# (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass). Every
# stack profile runs its checks through here, so this one place answers for
# all of them.
jp_run() {
  local check="$1" note="$2" suffix="" rc=0
  shift 2
  [ -z "$note" ] || suffix=" ($note)"
  JP_RAN=1
  jp_exec "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s: %s: pass%s\n' "$JP_PROFILE" "$check" "$suffix"
  elif [ "$rc" -ge 128 ]; then
    jp_incomplete "$check" "killed by signal $((rc - 128))${note:+, $note}"
  else
    printf '%s: %s: fail%s\n' "$JP_PROFILE" "$check" "$suffix"
    JP_STATUS=1
  fi
}

# jp_pass / jp_fail <check> <note> — record a verdict a profile computed
# itself (a runner exit code that needs translating, e.g. pytest's 5).
jp_pass() {
  JP_RAN=1
  printf '%s: %s: pass%s\n' "$JP_PROFILE" "$1" "${2:+ ($2)}"
}
jp_fail() {
  JP_RAN=1
  JP_STATUS=1
  printf '%s: %s: fail%s\n' "$JP_PROFILE" "$1" "${2:+ ($2)}"
}

# jp_incomplete <check> <reason> — a check that started and did not finish.
# Neither a pass nor a fail: it means run it again. For a profile that reads a
# runner's own answer rather than an exit code jp_run saw.
jp_incomplete() {
  JP_RAN=1
  JP_INCOMPLETE=1
  printf '%s: %s: incomplete%s\n' "$JP_PROFILE" "$1" "${2:+ ($2)}"
}

# jp_skip <check> <reason> — a check that did not run, and why.
jp_skip() {
  printf '%s: %s: skip (%s)\n' "$JP_PROFILE" "$1" "$2"
}

# jp_end — exit as the contract says: 3 when a check did not finish, 2 when no
# check ran, else 0 or 1.
#
# Incomplete comes first because a run something was killed in is not evidence:
# the failures beside it cannot be trusted either, and the honest instruction is
# to run it again.
jp_end() {
  if [ "$JP_INCOMPLETE" = 1 ]; then
    exit 3
  fi
  if [ "$JP_RAN" = 0 ]; then
    exit 2
  fi
  exit "$JP_STATUS"
}
