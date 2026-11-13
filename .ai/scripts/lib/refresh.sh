# cmd_refresh — bring this clone up to origin, for a person or a program that shows
# the project (adr-20261112-refresh-brings-the-clone-up-to-origin): fetch origin, then
# fast-forward the base branch to origin's, without moving the person's checkout and
# never over their changes. A base that cannot move is an answer, not a failure: it
# says why, and the command exits 0. Reads stay offline; this is the one command a
# program runs to make what they show current.
# shellcheck shell=bash

REFRESH_USAGE="usage: jig refresh [--json]"

_REFRESH_AS_JSON=""
_REFRESH_FETCH=""
_REFRESH_FETCH_MSG=""
_REFRESH_BASE=""
_REFRESH_OUTCOME=""
_REFRESH_FROM=""
_REFRESH_TO=""
_REFRESH_MSG=""
_REFRESH_WHERE=""

cmd_refresh() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      _REFRESH_AS_JSON=1
      json_run _refresh_main "$@"
      return
    fi
  done
  _refresh_main "$@"
}

_refresh_main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --json) ;;
      -h | --help) printf '%s\n' "$REFRESH_USAGE"; return 0 ;;
      *) jig_fail usage "refresh: unexpected argument: $arg; $REFRESH_USAGE" ;;
    esac
  done
  jig_require_init
  _REFRESH_BASE=$(cfg git.base_branch main)
  local refs_before
  refs_before=$(_refresh_refs)
  _refresh_fetch
  _refresh_base
  _refresh_writes
  # A refresh that changed what the clone knows of origin, or moved the base, changed what
  # reads report (origin.behind, landed knowledge, a write's `pushed`): raise the revision
  # once, after the moves landed. A fetch that brought nothing new raises nothing; only
  # origin.fetched_at moved, a time (adr-20261112-refresh-brings-the-clone-up-to-origin).
  # A closed write raised it already (ot_record_write). jig_revision_bump, not
  # jig_record_changed: the page is redrawn right below.
  [ "$(_refresh_refs)" = "$refs_before" ] || jig_revision_bump
  # What the status page shows moved with the base (base-behind-origin, landed knowledge).
  jig_status_page_touch >/dev/null 2>&1 || true
  if [ -n "$_REFRESH_AS_JSON" ]; then
    _refresh_json
  else
    _refresh_text
  fi
}

# _refresh_refs — what refresh can move, one ref per line: every origin/ ref the fetch
# writes and the base; nothing when git cannot list them.
_refresh_refs() {
  git -C "$JIG_PROJECT" for-each-ref --format='%(refname) %(objectname)' \
    refs/remotes/origin "refs/heads/$_REFRESH_BASE" 2>/dev/null || true
}

# _refresh_fetch — fetch origin as housekeeping does (_hk_fetch): the clone's own
# account, no prompt, `--no-prune` so a squash-merged branch keeps the origin/ ref its
# deletion is checked against. Bounded, since a program waits on the answer.
_refresh_fetch() {
  local err
  if ! git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1; then
    _REFRESH_FETCH=skipped
    _REFRESH_FETCH_MSG="this clone has no origin"
    return 0
  fi
  jig_git_origin_account refresh read
  _JIG_NET_DEADLINE=$(( $(date +%s) + _JIG_NET_CALL ))
  if err=$(jig_net jig_git_origin fetch --quiet --no-prune origin 2>&1 >/dev/null); then
    _REFRESH_FETCH="done"
  else
    _REFRESH_FETCH=failed
    _REFRESH_FETCH_MSG=$(printf '%s\n' "$err" | sed '/^[[:space:]]*$/d' | tail -n 3)
    [ -n "$_REFRESH_FETCH_MSG" ] || _REFRESH_FETCH_MSG="git fetch failed"
  fi
  _JIG_NET_DEADLINE=""
}

# _refresh_checked_out_at <branch> — the worktree <branch> is checked out in, or nothing.
# A list git could not give is answered `?`: the base may be checked out, and stays.
_refresh_checked_out_at() {
  local list
  list=$(git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null) || { printf '?\n'; return 0; }
  printf '%s\n' "$list" | awk -v want="branch refs/heads/$1" '
    /^worktree / { wt = substr($0, 10) }
    $0 == want { print wt; exit }'
}

# _refresh_base — fast-forward the base to origin's, the only move it ever makes:
# `merge --ff-only` where it is checked out here (git itself refuses to touch changes a
# fast-forward would overwrite), `git branch -f` where it is checked out nowhere — git
# refuses that for a branch any worktree has checked out, or is rebasing or bisecting;
# elsewhere, ahead, diverged or missing, nothing moves.
_refresh_base() {
  local base="$_REFRESH_BASE" local_sha origin_sha here out
  origin_sha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$base^{commit}" 2>/dev/null) || origin_sha=""
  local_sha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$base^{commit}" 2>/dev/null) || local_sha=""
  _REFRESH_FROM=$local_sha
  _REFRESH_TO=$local_sha
  if [ -z "$origin_sha" ] || [ -z "$local_sha" ]; then
    _REFRESH_OUTCOME=missing
    if [ -z "$origin_sha" ]; then
      _REFRESH_MSG="origin/$base is not known here"
    else
      _REFRESH_MSG="there is no branch $base here"
    fi
    return 0
  fi
  if [ "$local_sha" = "$origin_sha" ]; then
    _REFRESH_OUTCOME=up-to-date
    return 0
  fi
  if ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$local_sha" "$origin_sha" 2>/dev/null; then
    _REFRESH_OUTCOME=diverged
    _REFRESH_MSG="$base here has commits origin/$base does not have, so it cannot be fast-forwarded"
    return 0
  fi
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet HEAD 2>/dev/null) || here=""
  if [ "$here" = "refs/heads/$base" ]; then
    # merge.autoStash off: refresh never stashes (a person's config may say otherwise).
    if out=$(git -C "$JIG_PROJECT" -c merge.autoStash=false merge --ff-only -q "$origin_sha" 2>&1); then
      _REFRESH_OUTCOME=fast-forwarded
      _REFRESH_TO=$origin_sha
    else
      _REFRESH_OUTCOME=blocked-by-changes
      _REFRESH_MSG=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d')
      [ -n "$_REFRESH_MSG" ] || _REFRESH_MSG="git refused to fast-forward $base over the changes in this checkout"
    fi
    return 0
  fi
  _REFRESH_WHERE=$(_refresh_checked_out_at "$base")
  if [ "$_REFRESH_WHERE" = "?" ]; then
    _REFRESH_WHERE=""
    _REFRESH_OUTCOME=checked-out-elsewhere
    _REFRESH_MSG="git could not list this clone's worktrees, so $base may be checked out in one; nothing was changed"
    return 0
  fi
  if [ -n "$_REFRESH_WHERE" ]; then
    _REFRESH_OUTCOME=checked-out-elsewhere
    _REFRESH_MSG="$base is checked out in $_REFRESH_WHERE; it moves there, with \`jig refresh\` run in it"
    return 0
  fi
  if [ "$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$base^{commit}" 2>/dev/null)" != "$local_sha" ]; then
    _REFRESH_OUTCOME=diverged
    _REFRESH_MSG="$base moved while it was being fast-forwarded; nothing was changed"
  elif out=$(git -C "$JIG_PROJECT" branch -f "$base" "$origin_sha" 2>&1); then
    _REFRESH_OUTCOME=fast-forwarded
    _REFRESH_TO=$origin_sha
  else
    _REFRESH_OUTCOME=checked-out-elsewhere
    _REFRESH_MSG=$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d')
    [ -n "$_REFRESH_MSG" ] || _REFRESH_MSG="git refused to move $base"
  fi
}

# _refresh_writes — close the writes in Jig's own tree that are over, as `jig writes
# ship` would find them (ot_judge's `gone`): a squash merge the base changed again since
# reads as waiting to the offline ot_waiting for ever. Only after a fetch that reached
# origin: judged on an old view, a write still open could read as over. Each one under
# the writes' lock, judged in a subshell, so that what ot_judge refuses — a diverged
# branch, edits that never reached origin — leaves its record as it was and is
# `jig writes ship`'s to say; a lock another write holds leaves it for the next refresh.
# _REFRESH_WRITES <- `<target>\t<branch>\t<why>` per write it closed.
_REFRESH_WRITES=""
_refresh_writes() {
  local target line
  [ "$_REFRESH_FETCH" = "done" ] || return 0
  # shellcheck source=lib/owntree.sh
  . "$JIG_LIB/owntree.sh"
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    ot_waiting "$target" || continue
    _ot_lock_take refresh || continue
    line=$(_refresh_write_judge "$target" 2>/dev/null) || line=""
    _ot_lock_release
    [ -z "$line" ] || _REFRESH_WRITES="$_REFRESH_WRITES$line"$'\n'
  done < <(ot_targets)
}

# _refresh_write_judge <target> — in a subshell, under the lock: judge the write again
# from its record and, when it is over, mark the record and print what was closed.
_refresh_write_judge() {
  local target="$1" rec_pushed
  # shellcheck disable=SC2034 # read by lib/owntree.sh
  OT_WHO=refresh
  # shellcheck disable=SC2034
  OT_TARGET=$target
  # shellcheck disable=SC2034
  _OT_PROJECT=$JIG_PROJECT
  # shellcheck disable=SC2034
  _OT_HEADS_STATE=""
  # shellcheck disable=SC2034
  _OT_HELD_STATE=""
  ot_record_read "$target" || return 1
  rec_pushed=$OT_R_PUSHED
  ot_waiting "$target" || return 1
  # ot_waiting read `pushed` from the refs; ot_judge wants what the record says.
  OT_R_PUSHED=$rec_pushed
  ot_judge "$OT_R_BRANCH" "$OT_R_BASE"
  [ "$_OT_J" = gone ] || return 1
  ot_record_over "$target"
  printf '%s\t%s\t%s\n' "$target" "$OT_R_BRANCH" "$_OT_J_WHY"
}

_refresh_text() {
  case "$_REFRESH_FETCH" in
    done) printf 'fetch: done\n' ;;
    *) printf 'fetch: %s (%s)\n' "$_REFRESH_FETCH" "$_REFRESH_FETCH_MSG" ;;
  esac
  case "$_REFRESH_OUTCOME" in
    fast-forwarded) printf '%s: fast-forwarded %s..%s\n' "$_REFRESH_BASE" "${_REFRESH_FROM:0:12}" "${_REFRESH_TO:0:12}" ;;
    up-to-date) printf '%s: up to date with origin/%s\n' "$_REFRESH_BASE" "$_REFRESH_BASE" ;;
    *) printf '%s: %s — %s\n' "$_REFRESH_BASE" "$_REFRESH_OUTCOME" "$(printf '%s' "$_REFRESH_MSG" | tr '\n' ' ' | sed 's/ *$//')" ;;
  esac
  local target branch why
  while IFS=$'\t' read -r target branch why; do
    [ -n "$target" ] || continue
    printf 'writes: closed %s on %s (%s)\n' "$target" "$branch" "$why"
  done <<EOF
$_REFRESH_WRITES
EOF
}

_refresh_json() {
  local rec fetched_at
  fetched_at=$(jig_origin_fetched_at) || fetched_at=""
  json_quote "$_REFRESH_FETCH"; rec="{\"fetch\":{\"outcome\":$_JSON"
  json_str_or_null "$_REFRESH_FETCH_MSG"; rec="$rec,\"message\":$_JSON"
  json_str_or_null "$fetched_at"; rec="$rec,\"fetched_at\":$_JSON}"
  json_quote "$_REFRESH_BASE"; rec="$rec,\"base\":{\"name\":$_JSON"
  json_quote "$_REFRESH_OUTCOME"; rec="$rec,\"outcome\":$_JSON"
  json_str_or_null "$_REFRESH_FROM"; rec="$rec,\"from\":$_JSON"
  json_str_or_null "$_REFRESH_TO"; rec="$rec,\"to\":$_JSON"
  json_str_or_null "$_REFRESH_WHERE"; rec="$rec,\"checked_out_in\":$_JSON"
  json_str_or_null "$_REFRESH_MSG"; rec="$rec,\"message\":$_JSON}"
  local target branch why sep=""
  rec="$rec,\"writes\":["
  while IFS=$'\t' read -r target branch why; do
    [ -n "$target" ] || continue
    json_quote "$target"; rec="$rec$sep{\"target\":$_JSON"
    json_quote "$branch"; rec="$rec,\"branch\":$_JSON"
    json_quote "$why"; rec="$rec,\"reason\":$_JSON}"
    sep=","
  done <<EOF
$_REFRESH_WRITES
EOF
  rec="$rec]}"
  printf '%s\n' "$rec"
}
