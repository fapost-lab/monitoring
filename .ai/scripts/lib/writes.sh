# cmd_writes — the writes made in Jig's own tree (lib/owntree.sh;
# adr-20261104-a-write-goes-in-jigs-own-tree): `list` says what waits and where,
# `ship` carries one further than the write itself did — a push that failed, the
# pull request after `agent.git` was raised, and at `merge` the merge, which a write
# never waits for.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153 # the OT_ globals belong to lib/owntree.sh

WRITES_USAGE="usage: jig writes [list] [--json] | jig writes ship <target> [--json]; <target> is spec:<id> or knowledge"

cmd_writes() {
  local arg
  # shellcheck source=lib/owntree.sh
  . "$JIG_LIB/owntree.sh"
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      _WRITES_AS_JSON=1
      json_run _writes_main "$@"
      return
    fi
  done
  _writes_main "$@"
}

_WRITES_AS_JSON=""

_writes_main() {
  local arg args=() sub=list
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  if [ "${#args[@]}" -gt 0 ]; then
    sub=${args[0]}
    args=("${args[@]:1}")
  fi
  case "$sub" in
    list) _writes_list ${args[@]+"${args[@]}"} ;;
    ship) _writes_ship ${args[@]+"${args[@]}"} ;;
    help | -h | --help) printf '%s\n' "$WRITES_USAGE" ;;
    *) jig_fail usage "writes: unknown subcommand: $sub; $WRITES_USAGE" ;;
  esac
}

_writes_list() {
  [ $# -eq 0 ] || jig_fail usage "writes list: unexpected argument: $1"
  jig_require_init
  local target out="" sep=""
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    if [ -n "$_WRITES_AS_JSON" ]; then
      ot_waiting_json "$target"
      [ -n "$_JSON" ] || continue
      out="$out$sep$_JSON}"
      sep=,
    elif ot_waiting "$target"; then
      printf '%s  %s -> %s  %s commit(s)  %s\n' "$target" "$OT_R_BRANCH" "$OT_R_BASE" "$OT_W_COMMITS" \
        "${OT_R_PR:-$(_writes_where)}"
    fi
  done < <(ot_targets)
  [ -z "$_WRITES_AS_JSON" ] || printf '{"writes":[%s]}\n' "$out"
}

# _writes_where — where a waiting write stands when it has no pull request.
_writes_where() {
  if [ "$OT_R_PUSHED" = 1 ]; then printf 'pushed, no pull request\n'; else printf 'not pushed\n'; fi
}

# _writes_pr_still_open <target> <record-pushed> — what the record's pull request says about
# carrying this write on, under the lock. Reads have no network, so a read may still show
# what this finds over. Turned down, its edits do not come back; merged with the tip, they
# landed: neither is sent again, and the next edit takes a new name. Merged below the tip,
# what is above it waits for a new pull request.
_writes_pr_still_open() {
  local state
  [ -n "$OT_R_PR" ] || return 0
  state=$(jig_pr_state "$OT_R_PR" 2>/dev/null) || state=unknown
  case "$state" in
    closed) jig_fail not-found "writes ship: the pull request of $1 was closed unmerged, and its edits do not come back; the next edit goes on a new name" ;;
    merged)
      if ot_tip_was_sent "$OT_W_TIP" "$(_ot_sha "refs/remotes/origin/$OT_R_BRANCH")" "$2" "$OT_R_COMMIT"; then
        jig_fail not-found "writes ship: the pull request of $1 merged with these edits, so nothing waits; the next edit goes on a new name"
      fi
      OT_R_PR="" ;;
  esac
}

# _writes_ship <target> — take a waiting write as far as the level now allows. The lock
# is given back before the wait for CI, so edits can go on meanwhile; one that lands
# moves the branch, and the merge, which names the commit, refuses.
_writes_ship() {
  [ $# -eq 1 ] || jig_fail usage "writes ship: give one target; $WRITES_USAGE"
  local target="$1" who="writes ship" sha msg body rec_pushed
  case "$target" in
    knowledge) ;;
    spec:*) jig_valid_id "${target#spec:}" || jig_fail usage "writes ship: not a valid spec id: $target" ;;
    *) jig_fail usage "writes ship: not a target: $target; $WRITES_USAGE" ;;
  esac
  jig_require_init
  ot_begin "$who" "$target" ""
  ot_record_read "$target" || jig_fail not-found "writes ship: nothing of $target waits"
  rec_pushed=$OT_R_PUSHED
  ot_fetch "$OT_R_BASE"
  ot_waiting "$target" || jig_fail not-found "writes ship: nothing of $target waits"
  ot_refuse_what_is_not_jigs "$OT_R_BRANCH" "$OT_R_BRANCH" "$OT_R_COMMIT" "$OT_R_BASE"
  _writes_pr_still_open "$target" "$rec_pushed"
  OT_BRANCH=$OT_R_BRANCH
  OT_BASE=$OT_R_BASE
  OT_COMMIT=$OT_W_TIP
  OT_COMMITTED=0
  OT_COMMITS=$OT_W_COMMITS
  OT_PUSHED=$OT_R_PUSHED
  OT_PR=$OT_R_PR
  OT_MERGED=0
  OT_BASE_REF=$(jig_base_ref "$OT_BASE")
  msg=$(mktemp "${TMPDIR:-/tmp}/jig-writes.XXXXXX")
  jig_cleanup_add "$msg"
  body="$msg.body"
  jig_cleanup_add "$body"
  printf 'Edits made through Jig: %s\n' "$target" > "$msg"
  printf 'Committed by Jig on a branch of its own; each commit is one edit.\n' > "$body"
  _ot_ship_steps "$(cat "$msg")" "$body" "$msg"
  ot_record_write "$target"
  if [ "$OT_LEVEL" = merge ] && [ -n "$OT_PR" ]; then
    _ot_lock_release
    sha=$(_ot_sha "refs/heads/$OT_BRANCH")
    _ot_capture jig_ship_merge "$who" "$OT_PR" "$sha" any || true
    case "$_OT_CAP" in
      *"not merged:"*) OT_NOTE=${_OT_CAP#*not merged: } ;;
      *merged*) OT_MERGED=1; OT_NOTE="" ;;
      *) OT_NOTE=$_OT_CAP ;;
    esac
    # The lock was given back for the wait, so an edit may have landed meanwhile: its
    # record stands, and its commit waits. Only a branch still at what merged is done.
    if [ "$OT_MERGED" = 1 ] && [ "$(_ot_sha "refs/heads/$OT_BRANCH")" = "$sha" ]; then
      ot_record_write "$target"
    fi
  fi
  if [ -n "$_WRITES_AS_JSON" ]; then
    ot_answer_json
    printf '{"write":%s}\n' "$_JSON"
  else
    printf 'writes ship: %s\n' "$target"
    ot_answer_text
  fi
}
