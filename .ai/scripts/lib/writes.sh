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

# _writes_over <target> — the write is over without anything left to send (ot_judge's
# `gone`): say so in its record, which reads go on counting until it does, then answer
# not-found. Under the lock, from the record as read. Turned down, or dropped by origin,
# its edits do not come back; landed, they need not: the next edit takes a new name.
_writes_over() {
  ot_record_over "$1"
  case "$_OT_J_WHY" in
    closed) jig_fail not-found "writes ship: the pull request of $1 was closed unmerged, and its edits do not come back; the next edit goes on a new name" ;;
    merged) jig_fail not-found "writes ship: the pull request of $1 merged with these edits, so nothing waits; the next edit goes on a new name" ;;
    dropped) jig_fail not-found "writes ship: origin no longer has $OT_BRANCH, which it held, and what it dropped does not come back; the next edit goes on a new name" ;;
    *) jig_fail not-found "writes ship: what $OT_BRANCH holds is already on $OT_BASE, so nothing of $1 waits" ;;
  esac
}

# _writes_mark_merged <target> <sha> — after the merge of <sha>, mark the record merged:
# under the lock again, and from the record as it reads now. The lock was given back for
# the wait, so a write may have gone on meanwhile — on top of the branch, or, the forge
# having merged it already, on a new name that the record now names. Either way that
# record stands and its commit waits: only a record still of this branch, this tip and
# this pull request, with the branch still at what merged, is marked. With the lock held
# by another write the record stays as it is, and says so; it stops showing as waiting
# once the base is fetched with the merge on it.
_writes_mark_merged() {
  local target="$1" sha="$2"
  if ! _ot_lock_take "writes ship"; then
    OT_NOTE="merged; another write held the lock, so the record of $target was left as it was"
    return 0
  fi
  if ot_record_read "$target" && [ "$OT_R_BRANCH" = "$OT_BRANCH" ] && [ "$OT_R_COMMIT" = "$OT_COMMIT" ] \
    && [ "$OT_R_PR" = "$OT_PR" ] && [ "$(_ot_sha "refs/heads/$OT_BRANCH")" = "$sha" ]; then
    OT_BASE=$OT_R_BASE
    OT_PUSHED=$OT_R_PUSHED
    OT_SENT=$OT_R_SENT
    OT_ENDED=$OT_R_ENDED
    OT_MERGED=1
    ot_record_write "$target"
  fi
  _ot_lock_release
}

# _writes_ship <target> — take a waiting write as far as the level now allows. The lock
# is given back before the wait for CI, so edits can go on meanwhile; one that lands
# moves the branch, and the merge, which names the commit, refuses.
_writes_ship() {
  [ $# -eq 1 ] || jig_fail usage "writes ship: give one target; $WRITES_USAGE"
  local target="$1" who="writes ship" sha msg body rec_pushed out
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
  # ot_waiting read `pushed` from the refs; ot_judge wants what the record says.
  OT_R_PUSHED=$rec_pushed
  ot_judge "$OT_R_BRANCH" "$OT_R_BASE"
  case "$_OT_J" in
    gone) _writes_over "$target" ;;
    none | ff) jig_fail not-found "writes ship: nothing of $target waits" ;;
    # Merged below the tip: what is above it waits for a new pull request.
    spent) OT_R_PR="" ;;
  esac
  # The local branch was deleted and origin still holds it: what waits is origin's tip,
  # and the ship steps send a local branch, so it is cut there again, as a write cuts a
  # branch only on origin. Nothing moves: the ref is created only where there is none.
  # An edit the record names that origin's tip does not hold never reached it, and was on
  # the branch deleted: cut at origin's tip, it would go out of sight, so it is refused.
  if [ -z "$_OT_J_LOCAL" ] && [ -n "$_OT_J_TIP" ]; then
    if [ -n "$OT_R_COMMIT" ] && ! _ot_ancestor "$OT_R_COMMIT" "$_OT_J_TIP"; then
      jig_fail write-still-waits "$who: $OT_R_BRANCH was deleted here with $OT_R_COMMIT, which never reached origin; bring it back (git branch $OT_R_BRANCH $OT_R_COMMIT), then try again"
    fi
    out=$(git -C "$JIG_PROJECT" update-ref "refs/heads/$OT_R_BRANCH" "$_OT_J_TIP" "" 2>&1) \
      || jig_die "$who: could not cut $OT_R_BRANCH again at origin's $_OT_J_TIP: $out"
    OT_W_TIP=$_OT_J_TIP
  fi
  OT_BRANCH=$OT_R_BRANCH
  OT_BASE=$OT_R_BASE
  OT_COMMIT=$OT_W_TIP
  OT_COMMITTED=0
  OT_COMMITS=$OT_W_COMMITS
  OT_PUSHED=$OT_R_PUSHED
  OT_PR=$OT_R_PR
  OT_MERGED=0
  OT_ENDED=""
  OT_SENT=$OT_R_SENT
  OT_BASE_REF=$(jig_base_ref "$OT_BASE")
  msg=$(mktemp "${TMPDIR:-/tmp}/jig-writes.XXXXXX")
  jig_cleanup_add "$msg"
  body="$msg.body"
  jig_cleanup_add "$body"
  printf 'Edits made through Jig: %s\n' "$target" > "$msg"
  printf 'Committed by Jig on a branch of its own; each commit is one edit.\n' > "$body"
  _ot_ship_steps "$(cat "$msg")" "$body" "$msg"
  ot_record_write "$target"
  # Only once the steps reached the pull request: one that stopped on the way has said why
  # in the note, and there is nothing of theirs to merge.
  if [ "$OT_LEVEL" = merge ] && [ -n "$OT_PR" ] && [ "$_OT_SHIP_AT_PR" = 1 ]; then
    sha=$(_ot_sha "refs/heads/$OT_BRANCH")
    _ot_lock_release
    _ot_capture jig_ship_merge "$who" "$OT_PR" "$sha" any || true
    case "$_OT_CAP" in
      *"not merged:"*) OT_NOTE=${_OT_CAP#*not merged: } ;;
      *merged*) OT_MERGED=1; OT_NOTE="" ;;
      *) OT_NOTE=$_OT_CAP ;;
    esac
    [ "$OT_MERGED" != 1 ] || _writes_mark_merged "$target" "$sha"
  fi
  if [ -n "$_WRITES_AS_JSON" ]; then
    ot_answer_json
    printf '{"write":%s}\n' "$_JSON"
  else
    printf 'writes ship: %s\n' "$target"
    ot_answer_text
  fi
}
