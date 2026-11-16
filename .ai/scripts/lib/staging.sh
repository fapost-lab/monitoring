# cmd_staging — the person's side of the staging drift report
# (adr-20261113-staging-work-is-reported-to-its-own-author-until-acknowledged).
# `jig staging ack` records the person's own commits that the report counts —
# on the staging branch, not in the base, held by no live task branch — as
# known, in this clone's .ai/runtime/staging-acked, so that `jig status` names
# only what is new; `--dry-run` lists them and writes nothing; `--expect <n>`
# refuses unless they are <n>, the count the reader was shown.
# shellcheck shell=bash

STAGING_USAGE="usage: jig staging ack [--dry-run] [--expect <n>]"

cmd_staging() {
  local sub="${1:-}" dry="" expect=""
  case "$sub" in
    ack) shift ;;
    -h | --help) printf '%s\n' "$STAGING_USAGE"; return 0 ;;
    "") jig_fail usage "staging: a subcommand is needed; $STAGING_USAGE" ;;
    *) jig_fail usage "staging: unknown subcommand: $sub; $STAGING_USAGE" ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --expect)
        [ $# -ge 2 ] || jig_fail usage "staging ack: --expect needs a count; $STAGING_USAGE"
        case "$2" in '' | *[!0-9]*) jig_fail usage "staging ack: --expect takes a count, not '$2'" ;; esac
        expect=$2; shift 2 ;;
      -h | --help) printf '%s\n' "$STAGING_USAGE"; return 0 ;;
      *) jig_fail usage "staging ack: unexpected argument: $1; $STAGING_USAGE" ;;
    esac
  done
  jig_require_init
  # task.sh: the task states for the rows, and the owner's runtime
  # (_task_borrowed_tasks_root) that jig_staging_ack_file reads.
  # shellcheck source=lib/task.sh
  . "$JIG_LIB/task.sh"
  local staging stale records shown n file
  if ! staging=$(jig_staging_in_use); then
    jig_fail failed "staging ack: this project is not on a sound staging flow (git.flow; jig doctor names what is wrong)"
  fi
  stale=$(jig_staging_stale_after) || stale=""
  records=$(jig_staging_drift "$staging" "$stale" "$(_staging_rows)" "" all)
  shown=$(printf '%s\n' "$records" | awk -F '\t' '$1 == "unowned-commit" { print $2 "\t" $3 "\t" $4 }')
  n=0
  [ -z "$shown" ] || n=$(printf '%s\n' "$shown" | awk 'END { print NR }')
  # What the reader was shown is what is acknowledged: a commit that arrived
  # since (a fetch between the read and the click) refuses the whole ack.
  if [ -n "$expect" ] && [ "$((10#$expect))" -ne "$n" ]; then
    jig_fail failed "staging ack: $n commit(s) of yours on $staging now, not $expect; read jig status again"
  fi
  if [ -z "$shown" ]; then
    printf 'staging: nothing of yours on %s to acknowledge\n' "$staging"
    return 0
  fi
  if [ -n "$dry" ]; then
    printf '%s\n' "$shown" | awk -F '\t' '{ print substr($1, 1, 12) "  " substr($2, 1, 10) "  " $3 }'
    printf 'staging: %s commit(s) of yours on %s would be acknowledged (jig staging ack)\n' "$n" "$staging"
    return 0
  fi
  file=$(jig_staging_ack_file)
  mkdir -p "$(dirname "$file")"
  # By content, so a rebase or cherry-pick on the staging branch keeps the
  # acknowledgement; by sha as well, for a commit with no diff and no patch-id.
  {
    printf '%s\n' "$shown" | cut -f1 | jig_staging_patch_ids
    printf '%s\n' "$shown" | awk -F '\t' '{ print "- " $1 }'
  } >> "$file"
  jig_record_changed
  printf 'staging: %s commit(s) of yours on %s acknowledged; jig status names only new ones\n' "$n" "$staging"
}

# _staging_rows — this checkout's live tasks as jig_staging_drift reads them,
# "<id><TAB><branch><TAB><base><TAB><promote_url>", read through the one reader
# of the state format, with no process per task.
_staging_rows() {
  local dir state id branch base status purl t=$'\t'
  # The glob follows a worktree's link to the owner's tasks, as the reports do.
  dir="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  for state in "$dir"/*/state; do
    [ -f "$state" ] || continue
    id=${state%/state}
    id=${id##*/}
    _task_valid_id "$id" || continue
    task_state_var status "$id" status
    case "$status" in active | ready) ;; *) continue ;; esac
    task_state_var branch "$id" branch
    [ -n "$branch" ] || continue
    jig_task_base_v base "$id"
    task_state_var purl "$id" promote_url
    printf '%s\n' "$id$t$branch$t$base$t$purl"
  done
}
