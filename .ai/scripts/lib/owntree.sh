# A write in Jig's own tree (adr-20261104-a-write-goes-in-jigs-own-tree): a change
# committed on a branch of its own, in a tree nobody else uses, and shipped as far
# as `agent.git` allows, so that no person's checkout moves or goes dirty. `jig spec
# item` and `jig knowledge accept|reject|reviewed --revision` are its writers;
# `jig writes` carries a waiting write further and lists what waits.
#
# Sourced by the commands that write or read through it (spec.sh, knowledge.sh,
# writes.sh, housekeeping.sh, status.sh); it only defines functions. A writer calls,
# in this order:
#
#   ot_begin <who> <target> <revision>  the level, the revision, the clone's lock
#   ot_fetch <branch>...                what the branch resolution will compare
#   ot_open <branch> <base>             the branch, and the tree on it: OT_TREE
#   ...validate, in OT_TREE...          a refusal here has written nothing
#   ot_claim                            refuses stale-revision
#   ...change files in OT_TREE...
#   ot_commit <message-file> <path>...  only the paths named
#   ot_ship <title> <body>              push and pull request, as the level allows
#
# and prints ot_answer_json or ot_answer_text. Whatever ends the command, the tree
# goes and the lock is given back (_ot_close).
#
# <target> names what the write is for: `spec:<id>` or `knowledge`. The record of the
# write, `.ai/runtime/writes/<target with : as ->` in the clone's main checkout (see
# ot_records_dir), is what a read answers from, with no network
# (conventions/json-output.md).
# shellcheck shell=bash

OT_TREE=""
OT_LEVEL=""
OT_WHO=""
OT_TARGET=""
OT_EXPECTED=""
OT_BRANCH=""
OT_BASE=""
OT_BASE_REF=""
OT_COMMIT=""
OT_COMMITTED=0
OT_COMMITS=0
OT_PUSHED=0
OT_PR=""
OT_MERGED=0
OT_ENDED=""
OT_SENT=""
OT_NOTE=""

# Referenced from the exit handler, so script-global (conventions/shell.md).
_OT_PROJECT=""
_OT_LOCK_DIR=""
_OT_TREE_MADE=""

# --- where things are ------------------------------------------------------------

# ot_records_dir — the records and the lock, in the clone's main checkout: every
# worktree of a clone writes through one lock and reads one set of records. A clone
# with no such checkout to find keeps them under its git common directory, beside the
# tree they guard (jig_config_odd_common).
ot_records_dir() {
  local common
  if common=$(jig_config_odd_common); then
    printf '%s/jig/writes\n' "$common"
    return 0
  fi
  printf '%s/%s/runtime/writes\n' "$(jig_config_clone_root)" "$JIG_AI_DIR"
}

# _ot_record_file <target> — the record's path, or non-zero for what is no target. `:` is
# not a character a file name may hold on every platform.
_ot_record_file() {
  case "$1" in
    knowledge) ;;
    spec:*) jig_valid_id "${1#spec:}" || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s/%s\n' "$(ot_records_dir)" "${1/:/-}"
}

# _ot_tree_path <project> — `<git-common-dir>/jig/tree`: one function builds it, and
# it is the only path `git worktree remove --force` is ever given here (RULES.md).
# Inside the git directory no test runner, indexer or grep walks it (ADR-0029's reason
# against a nested tree), and it goes with the clone.
_ot_tree_path() {
  local dir
  dir=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  dir=$(cd "$1" && cd "$dir" && pwd -P) || return 1
  printf '%s/jig/tree\n' "$dir"
}

# --- the lock --------------------------------------------------------------------
#
# One per clone: a tree per clone, and one write in it at a time. Never waited for: a
# click retries, and a command that sits behind a stuck one helps nobody. The shape of
# the housekeeping lock, with `jig_verify_busy_holder` saying whether a holder lives.

# Longer than any write: a clone, a commit, a push and a forge call. What keeps a live
# write inside it is _OT_NET_BUDGET: every call that reaches the network under the lock
# goes through jig_net (common.sh), with a deadline set when the lock is taken, so a
# stalled origin or forge costs a write an answer and never makes its holder read as
# gone while it runs. The rest of the ttl is for what is local: the tree, the commit
# and its hooks.
_OT_LOCK_TTL=900
_OT_NET_BUDGET=600

_ot_lock_try() {
  mkdir -p "$1/busy" 2>/dev/null || return 1
  jig_claim_file "$1/busy/run" || return 1
  printf 'checkout: %s\npid: %s\n' "$JIG_PROJECT" "$$" > "$1/busy/run" 2>/dev/null || true
  _OT_LOCK_DIR="$1"
  _JIG_NET_DEADLINE=$(($(date +%s) + _OT_NET_BUDGET))
}

# _ot_lock_shaped <dir> — <dir> is a path of the lock's shape, the one place its
# deletions run.
_ot_lock_shaped() {
  case "$1" in
    */"$JIG_AI_DIR"/runtime/writes/lock | */jig/writes/lock) return 0 ;;
  esac
  return 1
}

# _ot_lock_clear <dir> — the two deletions of this run's own lock: the one file a run
# claims, then `rmdir`, which refuses anything else there. Only at a path of the lock's
# shape.
_ot_lock_clear() {
  _ot_lock_shaped "$1" || return 0
  rm -f "$1/busy/run" 2>/dev/null || true
  rmdir "$1/busy" 2>/dev/null || true
  return 0
}

# _ot_lock_id <file> — which record stands at <file>: `<pid>.<mtime>`, the pid `none`
# when the record names none (a holder stopped between its claim and its first line).
# Non-zero when there is no record.
_ot_lock_id() {
  local mtime line pid=none
  mtime=$(jig_file_mtime "$1") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "pid: "*) pid=${line#pid: } ;;
    esac
  done 2>/dev/null < "$1" || true
  case "$pid" in
    '' | *[!0-9]*) pid=none ;;
  esac
  printf '%s.%s\n' "$pid" "$mtime"
}

# _ot_lock_take_back <dir> — take back the record of a holder that is gone, so that two
# writers who both found it gone cannot both act on it: the second would remove the
# first one's fresh claim. The record is taken back under a claim of its own,
# `busy/clear.<pid>.<mtime>`, created exclusively (jig_claim_file) and named after that
# record, and under it the record goes only while it is still that record and its holder
# is still gone. Nobody removes a record without its claim, and the one that comes after
# it has another pid or mtime, so a late writer with the same claim finds a record that
# is not the one it judged and leaves it. The claim is removed by the call that made it.
# One a writer stopped inside those few lines left is never removed here — that would be
# a check-then-remove again — and the refusal names it for a person. 0: the way is clear
# for a claim of the lock; 1: another is taking it back (_OT_LOCK_BUSY).
_ot_lock_take_back() {
  local dir="$1" run="$1/busy/run" id claim
  _ot_lock_shaped "$dir" || return 0
  id=$(_ot_lock_id "$run") || return 0
  claim="$dir/busy/clear.$id"
  if ! jig_claim_file "$claim"; then
    _OT_LOCK_BUSY="another write is taking back a lock whose holder is gone; try again in a moment, and if this goes on, delete $claim, which one stopped part-way left"
    return 1
  fi
  if [ "$(_ot_lock_id "$run" 2>/dev/null)" = "$id" ] \
    && ! jig_verify_busy_holder "$dir" "$_OT_LOCK_TTL" >/dev/null 2>&1; then
    rm -f "$run" 2>/dev/null || true
  fi
  rm -f "$claim" 2>/dev/null || true
  return 0
}

# _ot_lock_take <who> — claim the lock: 0 taken, 1 another holds it (_OT_LOCK_BUSY says
# why). A holder that is gone is taken back first (_ot_lock_take_back). Not able to make
# the directory dies: a write that nothing holds off is the thing the lock is for.
_OT_LOCK_BUSY=""
_ot_lock_take() {
  local who="$1" dir holder
  _OT_LOCK_BUSY=""
  dir="$(ot_records_dir)/lock"
  if _ot_lock_try "$dir"; then
    return 0
  fi
  # A holder that gave the lock back between the `mkdir -p` and the claim took `busy`
  # with it: once more, then it is the directory that cannot be made.
  if [ ! -d "$dir/busy" ] && _ot_lock_try "$dir"; then
    return 0
  fi
  [ -d "$dir/busy" ] || jig_die "$who: cannot create $dir"
  if holder=$(jig_verify_busy_holder "$dir" "$_OT_LOCK_TTL" 2>/dev/null); then
    _OT_LOCK_BUSY="another write is running in this clone (${holder#* }); try again in a moment"
    return 1
  fi
  _ot_lock_take_back "$dir" || return 1
  if _ot_lock_try "$dir"; then
    return 0
  fi
  _OT_LOCK_BUSY="another write just started in this clone; try again in a moment"
  return 1
}

# _ot_lock_acquire <who> — claim the lock, or refuse write-busy.
_ot_lock_acquire() {
  _ot_lock_take "$1" || jig_fail write-busy "$1: $_OT_LOCK_BUSY"
}

# _ot_lock_mine — this run still holds the lock. A write that outlived the ttl has had it
# cleared under it, and what stands there now is another's.
_ot_lock_mine() {
  local line
  [ -n "$_OT_LOCK_DIR" ] && [ -f "$_OT_LOCK_DIR/busy/run" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "pid: $$" ] || return 0
  done < "$_OT_LOCK_DIR/busy/run"
  return 1
}

# _ot_lock_release — give the record back, if it is still this run's.
_ot_lock_release() {
  local dir="$_OT_LOCK_DIR"
  [ -n "$dir" ] || return 0
  _JIG_NET_DEADLINE=""
  _ot_lock_mine || { _OT_LOCK_DIR=""; return 0; }
  _OT_LOCK_DIR=""
  _ot_lock_clear "$dir"
}

# --- the tree --------------------------------------------------------------------

# _ot_tree_remove <project> <path> — take the tree away through git. `--force` because
# a write that was refused leaves it changed: under the lock only Jig writes there,
# nothing a person wrote is ever in it, and all that was worth keeping is a commit
# (RULES.md). Never `reset --hard` or `clean`: a tree that went wrong goes whole. Git takes
# its registration with it, also when the directory has gone, and only that one: `git
# worktree prune` would drop any worktree whose directory is merely away for the moment.
# On Windows git can drop the registration and leave the directory: what it left,
# once git no longer knows the path, goes the way housekeeping clears a task worktree's
# leftover, links and empty directories only. Anything else stays, and the next write
# names it, refused `tree-in-the-way`.
_ot_tree_remove() {
  git -C "$1" worktree remove --force "$2" >/dev/null 2>&1 || true
  [ -e "$2" ] || return 0
  ! _ot_tree_registered "$2" || return 0
  jig_worktree_leftover "$2" || true
}

# _ot_tree_registered <path> — git may still have our tree registered, its directory gone.
# Git names the entry after the directory, so a look at the names is enough, with no
# process, for the housekeeping run that finds nothing; a person's worktree of a like
# name costs a removal git refuses, because it goes by the path.
_ot_tree_registered() {
  local entry
  for entry in "${1%/jig/tree}/worktrees"/tree*; do
    [ -e "$entry" ] && return 0
  done
  return 1
}

# ot_sweep — remove a tree a killed write left, which would otherwise hold its branch
# against a person's `git switch`. Takes the lock for the moment it looks: a tree under
# a live write is that write's. Silent, and for housekeeping too: nothing depends on it.
ot_sweep() {
  local path
  path=$(_ot_tree_path "$JIG_PROJECT") || return 0
  [ -z "$_OT_LOCK_DIR" ] || { _ot_tree_remove "$JIG_PROJECT" "$path"; return 0; }
  [ -e "$path" ] || _ot_tree_registered "$path" || return 0
  ( _ot_lock_acquire ot-sweep ) >/dev/null 2>&1 || return 0
  _OT_LOCK_DIR="$(ot_records_dir)/lock"
  _ot_tree_remove "$JIG_PROJECT" "$path"
  _ot_lock_release
}

# _ot_close — what every way out of a write owes: the tree, then the lock. Only the tree
# this run made, and only while it holds the lock: without it, what stands at that path
# may be the next writer's, and a leftover is swept anyway.
_ot_close() {
  if [ -n "$_OT_TREE_MADE" ] && _ot_lock_mine; then
    _ot_tree_remove "$_OT_PROJECT" "$_OT_TREE_MADE"
  fi
  _OT_TREE_MADE=""
  _ot_lock_release
}

# --- steps -----------------------------------------------------------------------

# _ot_level <who> — OT_LEVEL <- agent.git, refusing an invalid one. Not `spec_ship_git`:
# its unattended branch reads autopilot.git, and a write here is not an autopilot run.
_ot_level() {
  local value
  value=$(jig_agent_git) || jig_die "$1: invalid agent.git: $value (expected none|commit|push|pr|merge)"
  OT_LEVEL=$value
}

# ot_begin <who> <target> <revision> — the checks that cost nothing and the lock.
# Refused with nothing done: `agent.git` none (git-not-allowed), a revision already
# overtaken (stale-revision), another write running (write-busy). An empty <revision>
# asks for no check of a read the caller made: the write checks against the revision it
# reads itself once its tree stands (ot_open), before it reads what it changes, so that a
# Jig write landing during the fetch and the checkout does not refuse it.
ot_begin() {
  OT_WHO="$1"
  OT_TARGET="$2"
  OT_EXPECTED="$3"
  _OT_PROJECT="$JIG_PROJECT"
  _ot_level "$OT_WHO"
  if [ "$OT_LEVEL" = none ]; then
    jig_fail git-not-allowed "$OT_WHO: agent.git is none in this clone, so Jig commits nothing; set it with \`jig config set --local agent.git commit\` (or higher), or make the change in an agent session"
  fi
  if [ -n "$OT_EXPECTED" ]; then
    [ "$(jig_revision_read)" = "$OT_EXPECTED" ] \
      || jig_fail stale-revision "$OT_WHO: the clone changed since revision $OT_EXPECTED; read again and retry"
  fi
  _OT_HEADS_STATE=""
  _OT_HELD_STATE=""
  # shellcheck disable=SC2016 # evaluated at exit, by design
  jig_on_exit '_ot_close'
  _ot_lock_acquire "$OT_WHO"
  ot_sweep
}

# ot_fetch <branch>... — bring what is compared up to date; a failed fetch says so and
# goes on with the refs this clone has (jig_fetch_branches).
ot_fetch() {
  jig_fetch_branches "$OT_WHO" "$@"
}

# _ot_holder <branch> — the checkout that has <branch> checked out, or nothing. Git
# refuses to add a tree on it too; this is what turns that into a code and a path.
_ot_holder() {
  git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null | B="refs/heads/$1" awk '
    /^worktree / { p = substr($0, 10) }
    /^branch / && substr($0, 8) == ENVIRON["B"] { if (!f) print p; f = 1 }
  '
}

# _ot_origin_heads — what origin says its branches are, asked once per write: _OT_HEADS
# <- `ls-remote --heads` (`<sha><TAB>refs/heads/<name>` lines), _OT_HEADS_STATE <- known,
# none (no origin) or unknown (no answer). A tracking ref is what origin had at the last
# fetch, and one whose branch origin deleted stays until a prune: what origin holds is
# judged by this answer, never by those refs, when there is one. Memoises into globals,
# so it is called as a plain command; ot_begin clears it.
_OT_HEADS=""
_OT_HEADS_STATE=""
_ot_origin_heads() {
  [ -z "$_OT_HEADS_STATE" ] || return 0
  if ! git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1; then
    _OT_HEADS=""
    _OT_HEADS_STATE=none
    return 0
  fi
  jig_git_origin_account "$OT_WHO" read
  if _OT_HEADS=$(jig_net jig_git_origin ls-remote --heads origin 2>/dev/null); then
    _OT_HEADS_STATE=known
  else
    _OT_HEADS=""
    _OT_HEADS_STATE=unknown
  fi
}

# _ot_origin_has <branch> — 0 origin has it, 1 it does not, 2 no origin or no answer.
_ot_origin_has() {
  _ot_origin_heads
  [ "$_OT_HEADS_STATE" = known ] || return 2
  case "$_OT_HEADS"$'\n' in
    *$'\t'"refs/heads/$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# _ot_origin_held — what "origin already holds it" is measured against: _OT_HELD <- the
# commits origin's branches name that are here, as `^<sha>` lines for `rev-list --stdin`
# (an origin of many branches would overflow a command line, Git Bash's first), and
# _OT_HELD_REMOTES <- 1 when origin gave no answer, so its tracking refs, the best this
# clone knows, stand in. One `cat-file` for the lot, once per write.
_OT_HELD=""
_OT_HELD_REMOTES=0
_OT_HELD_STATE=""
_ot_origin_held() {
  local sha type
  [ -z "$_OT_HELD_STATE" ] || return 0
  _OT_HELD_STATE=1
  _OT_HELD=""
  _OT_HELD_REMOTES=0
  _ot_origin_heads
  if [ "$_OT_HEADS_STATE" != known ]; then
    _OT_HELD_REMOTES=1
    return 0
  fi
  [ -n "$_OT_HEADS" ] || return 0
  while read -r sha type _; do
    if [ "$type" = commit ]; then
      _OT_HELD="$_OT_HELD^$sha"$'\n'
    fi
  done < <(printf '%s\n' "$_OT_HEADS" | cut -f1 | git -C "$JIG_PROJECT" cat-file --batch-check 2>/dev/null)
}

# _ot_not_held <commit> <also-held-or-empty> — <commit> has something origin does not
# hold (_ot_origin_held), or git could not say: a rule that keeps a person's commits in
# fails closed.
_ot_not_held() {
  local out also="" remotes=()
  _ot_origin_held
  [ "$_OT_HELD_REMOTES" != 1 ] || remotes=(--not --remotes=origin)
  [ -z "$2" ] || also="^$2"$'\n'
  # A --not before --stdin leaves what stdin names alone (git-rev-list(1)).
  out=$(printf '%s%s' "$_OT_HELD" "$also" \
    | git -C "$JIG_PROJECT" rev-list -1 "$1" ${remotes[@]+"${remotes[@]}"} --stdin 2>/dev/null) || return 0
  [ -n "$out" ]
}

_ot_sha() {
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null || true
}

_ot_ancestor() {
  git -C "$JIG_PROJECT" merge-base --is-ancestor "$1" "$2" 2>/dev/null
}

# ot_touched_equal <tip> <base-ref> — every path the branch changed reads the same on
# the base: a squash merge, which ancestry cannot see.
ot_touched_equal() {
  local mb path paths=()
  mb=$(git -C "$JIG_PROJECT" merge-base "$1" "$2" 2>/dev/null) || return 1
  while IFS= read -r path; do
    [ -z "$path" ] || paths+=("$path")
  done < <(git -C "$JIG_PROJECT" diff --name-only --no-renames "$mb" "$1" 2>/dev/null)
  [ "${#paths[@]}" -gt 0 ] || return 1
  git -C "$JIG_PROJECT" diff --quiet "$2" "$1" -- "${paths[@]}" 2>/dev/null
}

# _ot_spec_named <id> — a spec has this id: its directory is in this checkout, on the
# write's base or on the default branch, or its epic is here or on origin. `spec/x-2` is
# then the branch of spec `x-2`, whose own branch may merely be merged and gone.
_ot_spec_named() {
  local rel="$JIG_AI_DIR/specs/$1" ref sha
  [ ! -d "$JIG_PROJECT/$rel" ] || return 0
  for ref in "$OT_BASE_REF" "$(jig_base_ref "$(cfg git.base_branch main)")"; do
    [ -n "$ref" ] || continue
    sha=$(_ot_sha "$ref")
    if [ -n "$sha" ] && git -C "$JIG_PROJECT" cat-file -e "$sha:$rel" 2>/dev/null; then
      return 0
    fi
  done
  if [ -n "$(_ot_sha "refs/heads/epic/$1")" ] || [ -n "$(_ot_sha "refs/remotes/origin/epic/$1")" ]; then
    return 0
  fi
  _ot_origin_has "epic/$1" || return 1
}

# _ot_free_name <branch> — <branch>-2, -3, …: the first neither here nor on origin, and
# for a spec's branch, not the name of another spec's (_ot_spec_named).
_ot_free_name() {
  local n=2 name
  while :; do
    name="$1-$n"
    if [ -z "$(_ot_sha "refs/heads/$name")" ] && [ -z "$(_ot_sha "refs/remotes/origin/$name")" ]; then
      if ! _ot_origin_has "$name"; then
        case "$name" in
          spec/*) _ot_spec_named "${name#spec/}" || { printf '%s\n' "$name"; return 0; } ;;
          *) printf '%s\n' "$name"; return 0 ;;
        esac
      fi
    fi
    n=$((n + 1))
  done
}

# ot_judge <branch> <base> — what a write finds on <branch>: the one answer a write's
# resolve and `jig writes ship` both act on, so that neither keeps a judgement of its own.
# What the record knows counts whenever the record names <branch>, whatever base it was
# written for: a base changes when an epic opens or finishes, and a pull request closed
# before that is no less closed. Origin is asked through _ot_origin_heads, and the branch
# is fetched when origin has it. Sets:
#
# - _OT_J: `none` (no such branch, here or on origin), `ff` (the base holds its tip),
#   `spent` (its pull request merged without the tip: what is above waits for a new one),
#   `gone` (its commits no longer wait) or `top` (it waits, and a commit goes on top);
# - _OT_J_WHY, for `gone`: `merged`, `closed` (unmerged), `dropped` (origin deleted the
#   branch it held) or `landed` (the base has its work, by ancestry or by content);
# - _OT_J_TIP and _OT_J_LOCAL, and _OT_STALE_REF for a tracking ref origin no longer backs.
#
# Refuses with nothing written: `branch-diverged`; what ot_refuse_what_is_not_jigs refuses;
# and `write-still-waits` for edits that never reached origin above a write that is over
# because it was closed or dropped: sent, they would go out with what was turned down, and
# left behind, nobody would see them wait.
_OT_J=""
_OT_J_WHY=""
_OT_J_TIP=""
_OT_J_LOCAL=""
ot_judge() {
  local branch="$1" base="$2" base_ref default_ref rec_base_ref="" remote_sha="" stale_sha="" sent="" tip state n
  local had_rc=0 was_pushed=0 rec_pr="" rec_merged=0 rec_pushed=0 rec_commit="" rec_ended="" rec_sent=""
  _OT_J=""
  _OT_J_WHY=""
  _OT_J_TIP=""
  _OT_STALE_REF=""
  if [ -n "$OT_R_BRANCH" ] && [ "$OT_R_BRANCH" = "$branch" ]; then
    rec_pr=$OT_R_PR
    rec_merged=$OT_R_MERGED
    rec_pushed=$OT_R_PUSHED
    rec_commit=$OT_R_COMMIT
    rec_ended=$OT_R_ENDED
    rec_sent=$OT_R_SENT
    [ "$OT_R_BASE" = "$base" ] || rec_base_ref=$(jig_base_ref "$OT_R_BASE")
  fi

  _ot_origin_has "$branch" || had_rc=$?
  if [ "$had_rc" -eq 0 ]; then
    jig_fetch_branches "$OT_WHO" "$branch"
  elif [ "$had_rc" -eq 1 ]; then
    stale_sha=$(_ot_sha "refs/remotes/origin/$branch")
    if [ -n "$stale_sha" ]; then
      was_pushed=1
      # What `git fetch --prune` does, at the commit: origin has no such branch, and this
      # ref holds no work of its own.
      _OT_STALE_REF="refs/remotes/origin/$branch"
    fi
    [ "$rec_pushed" != 1 ] || was_pushed=1
  fi

  base_ref=$(jig_base_ref "$base")
  [ -n "$base_ref" ] || jig_die "$OT_WHO: $base exists neither here nor on origin"
  default_ref=$(jig_base_ref "$(cfg git.base_branch main)")

  _OT_J_LOCAL=$(_ot_sha "refs/heads/$branch")
  # A failed push since leaves the record's `pushed` at 0, and a prune took the tracking
  # ref: the record's `sent` still says origin held this branch, when what it held is below
  # the tip and has not landed. A `sent` the base holds is a branch merged and deleted on
  # origin, and what is above it was never dropped.
  if [ "$had_rc" -eq 1 ] && [ "$was_pushed" -eq 0 ] && [ -n "$rec_sent" ] && [ -n "$_OT_J_LOCAL" ] \
    && _ot_ancestor "$rec_sent" "$_OT_J_LOCAL" && ! _ot_ancestor "$rec_sent" "$base_ref" \
    && { [ -z "$default_ref" ] || ! _ot_ancestor "$rec_sent" "$default_ref"; } \
    && { [ -z "$rec_base_ref" ] || ! _ot_ancestor "$rec_sent" "$rec_base_ref"; }; then
    was_pushed=1
  fi
  [ -n "$_OT_STALE_REF" ] || remote_sha=$(_ot_sha "refs/remotes/origin/$branch")
  tip=$_OT_J_LOCAL
  if [ -n "$remote_sha" ]; then
    if [ -z "$_OT_J_LOCAL" ] || _ot_ancestor "$_OT_J_LOCAL" "$remote_sha"; then
      tip=$remote_sha
    elif ! _ot_ancestor "$remote_sha" "$_OT_J_LOCAL"; then
      jig_fail branch-diverged "$OT_WHO: $branch and origin/$branch have diverged; reconcile them, or merge the pull request, then try again"
    fi
  fi

  ot_refuse_what_is_not_jigs "$branch" "$OT_R_BRANCH" "$OT_R_COMMIT" "$base"

  _OT_J_TIP=$tip
  if [ -z "$tip" ]; then
    _OT_J=none
    return 0
  fi
  if _ot_ancestor "$tip" "$base_ref"; then
    _OT_J=ff
    return 0
  fi
  sent=${remote_sha:-$stale_sha}
  if [ "$rec_merged" = 1 ]; then
    _OT_J_WHY=merged
  elif [ -n "$rec_ended" ]; then
    _OT_J_WHY=$rec_ended
  elif { [ -n "$default_ref" ] && _ot_ancestor "$tip" "$default_ref"; } \
    || { [ -n "$rec_base_ref" ] && _ot_ancestor "$tip" "$rec_base_ref"; }; then
    _OT_J_WHY=landed
  elif [ -n "$rec_pr" ]; then
    state=$(jig_pr_state "$rec_pr" 2>/dev/null) || state=unknown
    case "$state" in
      closed) _OT_J_WHY=closed ;;
      merged)
        if ot_tip_was_sent "$tip" "$sent" "$rec_pushed" "$rec_commit"; then
          _OT_J_WHY=merged
        else
          _OT_J=spent
          return 0
        fi ;;
    esac
  fi
  if [ -z "$_OT_J_WHY" ] && { ot_touched_equal "$tip" "$base_ref" \
    || { [ -n "$rec_base_ref" ] && ot_touched_equal "$tip" "$rec_base_ref"; }; }; then
    _OT_J_WHY=landed
  fi
  if [ -z "$_OT_J_WHY" ] && [ "$had_rc" -eq 1 ] && [ "$was_pushed" -eq 1 ]; then
    _OT_J_WHY=dropped
  fi
  if [ -z "$_OT_J_WHY" ]; then
    _OT_J=top
    return 0
  fi
  _OT_J=gone
  case "$_OT_J_WHY" in
    closed | dropped) ;;
    *) return 0 ;;
  esac
  # What origin had of it is what anyone could see; the record's tip, or else its `sent`,
  # answers when the tracking ref has gone. Not knowing, there is nothing to tell apart.
  if [ -z "$sent" ] && [ "$rec_pushed" = 1 ]; then
    sent=$rec_commit
  fi
  [ -n "$sent" ] || sent=$rec_sent
  if [ -z "$sent" ] || [ -z "$_OT_J_LOCAL" ]; then
    return 0
  fi
  n=$(git -C "$JIG_PROJECT" rev-list --count "$sent..$_OT_J_LOCAL" 2>/dev/null) || n=0
  [ "$n" -gt 0 ] || return 0
  if [ "$_OT_J_WHY" = closed ]; then
    state="above edits whose pull request was closed unmerged"
  else
    state="above edits origin no longer has"
  fi
  jig_fail write-still-waits "$OT_WHO: $branch has $n edit(s) that never reached origin, $state; Jig neither sends them out with those nor leaves them where nobody sees them wait. Move them to a branch of your own (git branch -m $branch <name>), then try again"
}

# _ot_resolve <wanted> <base> — which branch this write goes on, and from what:
# OT_BRANCH, _OT_START (the commit a new branch is cut from; empty to stay on the
# branch's tip) and OT_BASE_REF. The branch is the one the record names, whatever base
# it was written for, and <wanted> with no record. By ot_judge's answer (the table in
# the ADR):
#
# - none: cut from the base, and one only on origin from its tip there;
# - ff: it merged by ancestry into the base: fast-forward to the base, same name, and the
#   pull request it had is over;
# - gone: it landed some other way, was closed unmerged, or origin dropped it: its commits
#   are no longer what waits, and it cannot be fast-forwarded. A new name, cut from the
#   base. It stays where it is: nothing is deleted, moved back or forced;
# - spent: its pull request merged without its tip: what is above what merged still
#   waits, on the same name, for a new pull request;
# - top: it still waits, and the commit goes on top.
#
# A write that still waits (spent, top) for another base than this one's is refused,
# write-still-waits: on top, this edit would go out in the pull request into the old base,
# which `jig_ship_pr` finds by the branch alone; on a new name, the record would forget
# the edit that waits.
#
# The base is read through jig_base_ref, origin's when it is known: what a forge will
# compare against, so that commits a person has not pushed to their base are not carried
# out on a branch of Jig's, and so that `commits` counts what the pull request shows.
#
# Nothing moves here. A branch that has to catch up leaves _OT_FF_TO and _OT_FF_FROM,
# and a tracking ref origin no longer backs leaves _OT_STALE_REF: ot_commit moves the one,
# inside the tree that holds the branch, and removes the other, so a refusal before then
# has left every ref where it was, and the next write sees what this one saw.
_OT_START=""
_OT_FF_TO=""
_OT_FF_FROM=""
_OT_STALE_REF=""
_OT_PR_SPENT=0
_ot_resolve() {
  local wanted="$1" base="$2" branch holder pr=""
  OT_BASE="$base"
  _OT_FF_TO=""
  _OT_FF_FROM=""
  _OT_STALE_REF=""
  _OT_PR_SPENT=0
  branch=$wanted
  if ot_record_read "$OT_TARGET"; then
    branch=$OT_R_BRANCH
  fi
  git check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || jig_die "$OT_WHO: git rejects the branch name: $branch"
  holder=$(_ot_holder "$branch")
  if [ -n "$holder" ]; then
    jig_fail branch-checked-out "$OT_WHO: $branch is checked out in $holder, and Jig never moves a checkout; finish the work there, or switch that checkout to another branch, then try again"
  fi

  ot_judge "$branch" "$base"
  OT_BASE_REF=$(jig_base_ref "$base")
  OT_BRANCH=$branch
  _OT_START=""
  case "$_OT_J" in
    none) _OT_START=$(_ot_sha "$OT_BASE_REF") ;;
    ff)
      _ot_plan_move "$(_ot_sha "$OT_BASE_REF")" "$_OT_J_LOCAL"
      _OT_PR_SPENT=1 ;;
    gone)
      OT_BRANCH=$(_ot_free_name "$wanted")
      _OT_START=$(_ot_sha "$OT_BASE_REF") ;;
    *)
      if [ -n "$OT_R_BASE" ] && [ "$OT_R_BASE" != "$base" ]; then
        [ "$_OT_J" != top ] || [ -z "$OT_R_PR" ] || pr=" ($OT_R_PR)"
        jig_fail write-still-waits "$OT_WHO: $branch still waits to go into $OT_R_BASE$pr, and this edit goes into $base; merge or close what waits first (\`jig writes ship $OT_TARGET\` carries it on), then try again"
      fi
      [ "$_OT_J" != spent ] || _OT_PR_SPENT=1
      _ot_plan_move "$_OT_J_TIP" "$_OT_J_LOCAL" ;;
  esac
}

# ot_tip_was_sent <tip> <origin's-ref-sha> <record-pushed> <record-commit> — the tip is in
# what had reached origin, and so in what a pull request of it can have merged. The record
# answers when the tracking ref has gone. Otherwise it is above what merged.
ot_tip_was_sent() {
  if [ -n "$2" ] && _ot_ancestor "$1" "$2"; then
    return 0
  fi
  [ "$3" = 1 ] && [ "$4" = "$1" ]
}

# ot_refuse_what_is_not_jigs <branch> <record-branch> <record-commit> <base> — the rule:
# a write publishes only its own commits. Whatever would leave this machine that Jig did
# not write, and that origin does not already hold, is refused, with nothing written.
# Asked by ot_judge, before anything is decided, for a write and for `jig writes ship`,
# the only two ways out (_ot_ship_steps does the sending for both).
#
# - A local tip the record does not name, with commits origin does not hold, is a
#   person's. Held by a branch origin answers it has (_ot_origin_held: a tracking ref of a
#   branch origin deleted holds nothing), or by the base here, nothing new would leave.
#   The branch's own tracking ref counts too: fresh, origin has it; stale, origin dropped
#   the branch, which ot_judge then takes as gone, and what it held is never sent again.
#   Nor does it from a branch the record does not name whose touched paths read the same
#   on the base: that is a squash merge, judged gone, and never sent. The record names
#   only the tip: a commit that is not Jig's below a tip that is cannot be told, which is
#   why the next clause exists.
# - A base origin does not have: a branch cut from it would carry whatever is on it out to
#   origin, and a pull request into it could not open anyway. At `commit` nothing leaves.
ot_refuse_what_is_not_jigs() {
  local local_sha ref base_ref has_origin=0 rc=0 how own
  local_sha=$(_ot_sha "refs/heads/$1")
  if git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1; then
    has_origin=1
  fi
  if [ -n "$local_sha" ] && { [ "$2" != "$1" ] || [ "$3" != "$local_sha" ]; }; then
    own=$(_ot_sha "refs/remotes/origin/$1")
    if _ot_not_held "$local_sha" "$own"; then
      base_ref=$(jig_base_ref "$4")
      for ref in "$base_ref" "$(jig_base_ref "$(cfg git.base_branch main)")"; do
        if [ -n "$ref" ] && _ot_ancestor "$local_sha" "$ref"; then
          local_sha=""
          break
        fi
      done
      if [ -n "$local_sha" ] && [ "$2" != "$1" ] && [ -n "$base_ref" ] && ot_touched_equal "$local_sha" "$base_ref"; then
        local_sha=""
      fi
      if [ -n "$local_sha" ]; then
        how="push or merge them yourself"
        [ "$has_origin" = 1 ] || how="merge them yourself"
        jig_fail branch-has-other-commits "$OT_WHO: $1 has commits that no write of Jig's made and origin does not have, and Jig does not publish them; $how, or move them to another branch, then try again"
      fi
    fi
  fi
  if [ "$OT_LEVEL" != commit ] && [ "$has_origin" = 1 ]; then
    _ot_origin_has "$4" || rc=$?
    if [ "$rc" -eq 1 ] || { [ "$rc" -eq 2 ] && [ -z "$(_ot_sha "refs/remotes/origin/$4")" ]; }; then
      jig_fail base-not-on-origin "$OT_WHO: $4 is not on origin, so a branch cut from it would carry out whatever is on it and no pull request could open into it; push $4 yourself, then try again"
    fi
  fi
}

# _ot_plan_move <new> <old-or-empty> — the local branch is to be at <new>, the caller
# having established that nothing is lost. With no local branch there is nothing to
# hold: it is cut at the commit, from <new>, like any new one.
_ot_plan_move() {
  if [ -z "$2" ]; then
    _OT_START=$1
  elif [ "$1" != "$2" ]; then
    _OT_FF_TO=$1
    _OT_FF_FROM=$2
  fi
}

# ot_open <wanted-branch> <base> — resolve the branch and add the tree. A branch that does
# not exist yet is not cut here: the tree stands detached at its start until ot_commit,
# so that a refusal in validation leaves no branch for `spec new` to trip over. On a
# branch that exists the tree is on it, and one git says is taken elsewhere is the race
# _ot_holder could not see. One that has to catch up stays where it is until ot_commit,
# while the tree's files and index already show what it will be at: validation reads
# that, and a refusal leaves no ref moved.
_OT_CUT=""
ot_open() {
  local path out rc=0
  _ot_resolve "$1" "$2"
  _OT_CUT=$_OT_START
  path=$(_ot_tree_path "$JIG_PROJECT") || jig_die "$OT_WHO: cannot find the git directory"
  mkdir -p "${path%/*}" || jig_die "$OT_WHO: cannot create ${path%/*}"
  # ot_begin swept under this lock. What stands here now is not this run's to use or to
  # remove: a working tree is another writer's, and anything else is what a write that
  # did not finish left and git will not take, which no retry clears.
  if [ -e "$path" ]; then
    if ! _ot_lock_mine || { [ -f "$path/.git" ] && git -C "$path" rev-parse --git-dir >/dev/null 2>&1; }; then
      jig_fail write-busy "$OT_WHO: another write has the tree at $path; try again in a moment"
    fi
    jig_fail tree-in-the-way "$OT_WHO: $path is what an unfinished write left, and git will not remove it; delete that directory, then try again"
  fi
  if [ -n "$_OT_START" ]; then
    out=$(git -C "$JIG_PROJECT" worktree add -q --detach "$path" "$_OT_START" 2>&1) || rc=$?
  else
    out=$(git -C "$JIG_PROJECT" worktree add -q "$path" "$OT_BRANCH" 2>&1) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"already exists"*)
        jig_fail write-busy "$OT_WHO: another write has the tree at $path; try again in a moment" ;;
    esac
  fi
  # A failing post-checkout hook fails the command and leaves the tree whole.
  if [ "$rc" -ne 0 ] && [ ! -f "$path/.git" ]; then
    case "$out" in
      *"already"*"checked out"* | *"already used by worktree"*)
        jig_fail branch-checked-out "$OT_WHO: $OT_BRANCH was checked out elsewhere just now; try again: $out" ;;
    esac
    jig_die "$OT_WHO: could not add a tree for $OT_BRANCH: $out"
  fi
  _OT_TREE_MADE=$path
  OT_TREE=$(cd -P "$path" && pwd -P) || jig_die "$OT_WHO: cannot resolve $path"
  if [ -n "$_OT_FF_TO" ]; then
    out=$(git -C "$OT_TREE" read-tree -m -u HEAD "$_OT_FF_TO" 2>&1) \
      || jig_die "$OT_WHO: could not bring the tree to $_OT_FF_TO: $out"
  fi
  # No revision was sent: the one the write is checked against is read now, after the
  # fetch and the checkout and before validation reads the tree (ot_begin).
  if [ -z "$OT_EXPECTED" ]; then
    OT_EXPECTED=$(jig_revision_read)
  fi
}

# ot_claim — the revision claim of every write checked against what its caller read,
# or, with no revision sent, what ot_open read (jig_revision_claim,
# conventions/json-output.md). Nothing Jig records has been written before it.
ot_claim() {
  local rc=0
  jig_revision_claim "$OT_EXPECTED" || rc=$?
  case "$rc" in
    0) ;;
    1) jig_fail stale-revision "$OT_WHO: the clone changed since revision $OT_EXPECTED; read again and retry" ;;
    *) jig_die "$OT_WHO: cannot claim the clone revision in $(jig_revision_dir)" ;;
  esac
}

# ot_commit <message-file> <path>... — commit the paths named, in the tree. Hooks run
# (adr-20260921-agent-git-rights-are-a-local-setting), and a tree has none of the
# project's dependencies, so one may fail: commit-refused, with what it said, and a branch
# just cut stays at the base with nothing on it, which the next write takes up. A change
# that changed nothing commits nothing (OT_COMMITTED 0), and cuts nothing.
ot_commit() {
  local msg="$1" out rc=0
  shift
  git -C "$OT_TREE" add -A -- "$@" 2>/dev/null || jig_die "$OT_WHO: could not stage the change in $OT_TREE"
  # The tree holds the branch, so no checkout has it, and git checks the old value.
  if [ -n "$_OT_FF_TO" ]; then
    git -C "$OT_TREE" update-ref HEAD "$_OT_FF_TO" "$_OT_FF_FROM" 2>/dev/null \
      || jig_die "$OT_WHO: could not move $OT_BRANCH to $_OT_FF_TO"
    _OT_FF_TO=""
  fi
  OT_COMMITTED=0
  if ! git -C "$OT_TREE" diff --cached --quiet 2>/dev/null; then
    if [ -n "$_OT_CUT" ]; then
      out=$(git -C "$OT_TREE" switch -q -c "$OT_BRANCH" 2>&1) \
        || jig_die "$OT_WHO: could not cut $OT_BRANCH: $out"
    fi
    out=$(git -C "$OT_TREE" commit -q -F "$msg" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || jig_fail commit-refused "$OT_WHO: git commit was refused on $OT_BRANCH:
$out"
    OT_COMMITTED=1
    if [ -n "$_OT_STALE_REF" ]; then
      git -C "$JIG_PROJECT" update-ref -d "$_OT_STALE_REF" 2>/dev/null || true
      _OT_STALE_REF=""
    fi
  fi
  OT_COMMIT=$(_ot_sha "refs/heads/$OT_BRANCH")
  jig_record_changed
}

# _ot_capture <command...> — run a ship step that may die, in a subshell from the
# project's root (a forge CLI finds its repository by the working directory): _OT_CAP
# <- what it said, without the `jig: error: ` it dies with, and the status returned.
# Through a file, never a pipe (conventions/shell.md).
_OT_CAP=""
_ot_capture() {
  local out rc
  out=$(mktemp "${TMPDIR:-/tmp}/jig-owntree.XXXXXX")
  jig_cleanup_add "$out"
  set +e
  ( set -e; _JIG_JSON_CODES=""; cd "$JIG_PROJECT"; "$@" ) >"$out" 2>&1
  rc=$?
  set -e
  _OT_CAP=$(sed 's/^jig: error: //' "$out")
  rm -f "$out"
  return "$rc"
}

# _ot_on_origin <branch> <commit> — origin's ref, as of the last fetch or push, holds it.
_ot_on_origin() {
  local sent
  sent=$(_ot_sha "refs/remotes/origin/$1")
  [ -n "$sent" ] && [ -n "$2" ] && _ot_ancestor "$2" "$sent"
}

# _ot_pushed_now — OT_PUSHED <- whether origin holds the write's tip. Never carried from
# the record: a commit made since, whose push failed or was not this level's, is not.
_ot_pushed_now() {
  OT_PUSHED=0
  if _ot_on_origin "$OT_BRANCH" "$OT_COMMIT"; then
    OT_PUSHED=1
  fi
}

# _ot_ship_steps <title> <body-file> <message-file> — push, then the pull request, each
# as far as OT_LEVEL allows, leaving OT_PUSHED, OT_PR and OT_NOTE, and _OT_SHIP_AT_PR 1
# only when the steps reached a pull request that holds the tip: what a merge may follow.
# A failure here is an answer and not a refusal: the commit stands and waits, and `jig
# writes ship` carries it on. Asks nothing of the forge unless the level says so.
_OT_SHIP_AT_PR=0
_ot_ship_steps() {
  local title="$1" body="$2" msg="$3" url
  OT_NOTE=""
  _OT_SHIP_AT_PR=0
  _ot_pushed_now
  OT_COMMITS=$(git -C "$JIG_PROJECT" rev-list --count "$OT_BASE_REF..refs/heads/$OT_BRANCH" 2>/dev/null) || OT_COMMITS=0
  [ "$OT_COMMITS" -gt 0 ] || return 0
  if [ "$OT_LEVEL" = commit ]; then
    OT_NOTE="agent.git is commit: pushing $OT_BRANCH is yours"
    return 0
  fi
  if ! git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1; then
    OT_NOTE="this clone has no origin: pushing $OT_BRANCH is yours"
    return 0
  fi
  # Asked in a subshell first, because a die here must be an answer, and again in this
  # shell, where it says what the ship sends for the steps below (common.sh).
  if ! _ot_capture jig_ship_require_commits "$OT_WHO" "$OT_BRANCH" "$OT_BASE"; then
    OT_NOTE=$_OT_CAP
    return 0
  fi
  jig_ship_require_commits "$OT_WHO" "$OT_BRANCH" "$OT_BASE"
  # The same pair for the GitHub account a pull request is opened as: an
  # answer before the push, not a refusal after it (jig_ship_account).
  if ! _ot_capture jig_ship_account "$OT_WHO" "$OT_LEVEL"; then
    OT_NOTE=$_OT_CAP
    return 0
  fi
  jig_ship_account "$OT_WHO" "$OT_LEVEL"
  if ! _ot_capture jig_ship_push "$OT_WHO" "$OT_BRANCH"; then
    OT_NOTE=$_OT_CAP
    return 0
  fi
  OT_PUSHED=1
  if [ "$OT_LEVEL" = push ]; then
    OT_NOTE="agent.git is push: the pull request is yours"
    return 0
  fi
  if ! _ot_capture jig_ship_pr "$OT_WHO" "$OT_BRANCH" "$OT_BASE" "$msg" "$title" "$body"; then
    OT_NOTE=$_OT_CAP
    return 0
  fi
  url=$(printf '%s\n' "$_OT_CAP" | sed -n 's/^pr \([^ ]*\).*$/\1/p' | sed -n '$p')
  if [ -n "$url" ]; then
    OT_PR=$url
    _OT_SHIP_AT_PR=1
  else
    OT_NOTE="no forge available: the pull request is yours"
    return 0
  fi
  if [ "$OT_LEVEL" = merge ]; then
    OT_NOTE="a write does not wait for CI: \`jig writes ship ${OT_TARGET}\` merges it once CI passed"
  fi
}

# ot_ship <title> <body-text> — after a commit: write the record, then carry it on and
# write it again. Recorded first, so that a push that dies leaves a write that can be
# seen waiting, and `jig writes ship` finds it. Nothing to record when the branch
# carries nothing.
ot_ship() {
  local title="$1" text="$2" msg body
  OT_PUSHED=0
  OT_PR=""
  OT_MERGED=0
  OT_ENDED=""
  OT_SENT=""
  if ot_record_read "$OT_TARGET" && [ "$OT_R_BRANCH" = "$OT_BRANCH" ]; then
    OT_SENT=$OT_R_SENT
    if [ "$OT_R_BASE" = "$OT_BASE" ] && [ "$OT_R_MERGED" != 1 ] && [ -z "$OT_R_ENDED" ]; then
      [ "$_OT_PR_SPENT" = 1 ] || OT_PR=$OT_R_PR
    fi
  fi
  _ot_pushed_now
  OT_COMMITS=$(git -C "$JIG_PROJECT" rev-list --count "$OT_BASE_REF..refs/heads/$OT_BRANCH" 2>/dev/null) || OT_COMMITS=0
  [ "$OT_COMMITS" -gt 0 ] || return 0
  ot_record_write "$OT_TARGET"
  msg=$(mktemp "${TMPDIR:-/tmp}/jig-owntree.XXXXXX")
  jig_cleanup_add "$msg"
  body="$msg.body"
  jig_cleanup_add "$body"
  printf '%s\n' "$title" > "$msg"
  printf '%s\n' "$text" > "$body"
  _ot_ship_steps "$title" "$body" "$msg"
  rm -f "$msg" "$body"
  ot_record_write "$OT_TARGET"
}

# --- the record ------------------------------------------------------------------

OT_R_BRANCH=""
OT_R_BASE=""
OT_R_COMMIT=""
OT_R_PUSHED=0
OT_R_PR=""
OT_R_MERGED=0
OT_R_ENDED=""
OT_R_SENT=""

# ot_record_read <target> — the OT_R_* of its record; non-zero with none. Read with the
# shell, one process per nothing: a read asks this once per spec. `ended` is what `jig
# writes ship` learned of a write that is over without a merge — `closed`, `dropped` or
# `landed` — and is absent from a record written before it was asked. `sent` is the last
# tip of the branch origin was seen to hold, kept through a push that failed since: what
# says origin held the branch once its tracking ref was pruned. A record written before it
# was kept has none.
ot_record_read() {
  local file key value
  OT_R_BRANCH="" OT_R_BASE="" OT_R_COMMIT="" OT_R_PUSHED=0 OT_R_PR="" OT_R_MERGED=0 OT_R_ENDED="" OT_R_SENT=""
  file=$(_ot_record_file "$1") || return 1
  [ -f "$file" ] || return 1
  while IFS= read -r key || [ -n "$key" ]; do
    value=${key#*: }
    case "$key" in
      branch:*) OT_R_BRANCH=$value ;;
      base:*) OT_R_BASE=$value ;;
      commit:*) [ "$value" = "$key" ] || OT_R_COMMIT=$value ;;
      pushed:*) OT_R_PUSHED=$value ;;
      pr:*) [ "$value" = "$key" ] || OT_R_PR=$value ;;
      merged:*) OT_R_MERGED=$value ;;
      ended:*) [ "$value" = "$key" ] || OT_R_ENDED=$value ;;
      sent:*) [ "$value" = "$key" ] || OT_R_SENT=$value ;;
    esac
  done < "$file"
  [ -n "$OT_R_BRANCH" ]
}

# ot_record_write <target> — the record from OT_*, moved into place whole, and the
# revision raised: a read answers from it. `sent` is the tip when origin holds it, else
# what origin's ref of the branch holds below it, else OT_SENT, carried by the caller from
# a record of the same branch.
ot_record_write() {
  local file dir tmp ref
  file=$(_ot_record_file "$1") || jig_die "$OT_WHO: not a target: $1"
  if [ "$OT_PUSHED" = 1 ]; then
    OT_SENT=$OT_COMMIT
  else
    ref=$(_ot_sha "refs/remotes/origin/$OT_BRANCH")
    if [ -n "$ref" ] && [ -n "$OT_COMMIT" ] && _ot_ancestor "$ref" "$OT_COMMIT"; then
      OT_SENT=$ref
    fi
  fi
  dir=${file%/*}
  mkdir -p "$dir" || jig_die "$OT_WHO: cannot create $dir"
  # A dotfile, as _jig_checkout_write names its temporary (checkout.sh): ot_targets
  # reads the directory as a glob of record names, and a dot is legal in a spec id,
  # so `spec-<id>.tmp.<pid>` left by a killed write would read as a record, and no
  # name pattern that skipped it could tell it from a spec whose id has `.tmp.` in it.
  tmp="$dir/.tmp.${file##*/}.$$"
  jig_cleanup_add "$tmp"
  {
    printf 'branch: %s\nbase: %s\ncommit: %s\n' "$OT_BRANCH" "$OT_BASE" "$OT_COMMIT"
    printf 'pushed: %s\npr: %s\nmerged: %s\n' "$OT_PUSHED" "$OT_PR" "$OT_MERGED"
    [ -z "$OT_SENT" ] || printf 'sent: %s\n' "$OT_SENT"
    [ -z "$OT_ENDED" ] || printf 'ended: %s\n' "$OT_ENDED"
  } > "$tmp"
  mv "$tmp" "$file"
  jig_record_changed
}

# ot_record_over <target> — say in its record that the write is over (ot_judge's `gone`),
# from the record as read (OT_R_*) and _OT_J_WHY: `merged: 1` for a merge, `ended: <why>`
# otherwise. Under the lock. Reads go on counting the write as waiting until it does.
ot_record_over() {
  OT_BRANCH=$OT_R_BRANCH
  OT_BASE=$OT_R_BASE
  OT_COMMIT=$OT_R_COMMIT
  OT_PUSHED=$OT_R_PUSHED
  OT_PR=$OT_R_PR
  OT_MERGED=$OT_R_MERGED
  OT_ENDED=$OT_R_ENDED
  OT_SENT=$OT_R_SENT
  if [ "$_OT_J_WHY" = merged ]; then
    OT_MERGED=1
  else
    OT_ENDED=$_OT_J_WHY
  fi
  ot_record_write "$1"
}

# ot_targets — the targets that have a record, one per line.
ot_targets() {
  local dir f name
  dir=$(ot_records_dir)
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    case "$name" in
      knowledge) printf 'knowledge\n' ;;
      spec-*) if jig_valid_id "${name#spec-}"; then printf 'spec:%s\n' "${name#spec-}"; fi ;;
    esac
  done
}

# --- what a reader sees ----------------------------------------------------------

OT_W_TIP=""
OT_W_COMMITS=0

# ot_waiting <target> — true while its write has not reached its base, the OT_R_* of
# its record and OT_W_TIP and OT_W_COMMITS set. Local refs and the record, no network:
# so a merge shows as of the last fetch, and an end only `jig writes ship` asked about
# shows once it marked the record. A person's own branch of that name, with no
# record, is not a write that waits.
ot_waiting() {
  local base_ref
  ot_record_read "$1" || return 1
  if [ "$OT_R_MERGED" = 1 ] || [ -n "$OT_R_ENDED" ]; then
    return 1
  fi
  OT_W_TIP=$(_ot_sha "refs/heads/$OT_R_BRANCH")
  [ -n "$OT_W_TIP" ] || OT_W_TIP=$(_ot_sha "refs/remotes/origin/$OT_R_BRANCH")
  [ -n "$OT_W_TIP" ] || return 1
  OT_R_PUSHED=0
  if _ot_on_origin "$OT_R_BRANCH" "$OT_W_TIP"; then
    OT_R_PUSHED=1
  fi
  base_ref=$(jig_base_ref "$OT_R_BASE")
  OT_W_COMMITS=0
  if [ -n "$base_ref" ]; then
    if _ot_ancestor "$OT_W_TIP" "$base_ref" || ot_touched_equal "$OT_W_TIP" "$base_ref"; then
      return 1
    fi
    OT_W_COMMITS=$(git -C "$JIG_PROJECT" rev-list --count "$base_ref..$OT_W_TIP" 2>/dev/null) || OT_W_COMMITS=0
  fi
  return 0
}

# ot_waiting_json <target> — _JSON <- the waiting write's object without its closing
# brace, ready for more fields, or the empty string when none waits.
ot_waiting_json() {
  local rec
  _JSON=""
  ot_waiting "$1" || return 0
  json_quote "$1"; rec="{\"target\":$_JSON"
  json_quote "$OT_R_BRANCH"; rec="$rec,\"branch\":$_JSON"
  json_quote "$OT_R_BASE"; rec="$rec,\"base\":$_JSON"
  json_quote "$OT_W_TIP"; rec="$rec,\"commit\":$_JSON"
  rec="$rec,\"commits\":$OT_W_COMMITS"
  if [ "$OT_R_PUSHED" = 1 ]; then rec="$rec,\"pushed\":true"; else rec="$rec,\"pushed\":false"; fi
  json_str_or_null "$OT_R_PR"; rec="$rec,\"pr\":$_JSON"
  _JSON="$rec,\"merged\":false"
}

# ot_answer_json — _JSON <- what a write answers, the one object all of them share.
ot_answer_json() {
  local rec
  json_quote "$OT_TARGET"; rec="{\"target\":$_JSON"
  json_quote "$OT_BRANCH"; rec="$rec,\"branch\":$_JSON"
  json_quote "$OT_BASE"; rec="$rec,\"base\":$_JSON"
  json_str_or_null "$OT_COMMIT"; rec="$rec,\"commit\":$_JSON"
  rec="$rec,\"commits\":$OT_COMMITS"
  if [ "$OT_PUSHED" = 1 ]; then rec="$rec,\"pushed\":true"; else rec="$rec,\"pushed\":false"; fi
  json_str_or_null "$OT_PR"; rec="$rec,\"pr\":$_JSON"
  if [ "$OT_MERGED" = 1 ]; then rec="$rec,\"merged\":true"; else rec="$rec,\"merged\":false"; fi
  if [ "$OT_COMMITTED" = 1 ]; then rec="$rec,\"committed\":true"; else rec="$rec,\"committed\":false"; fi
  json_quote "$OT_LEVEL"; rec="$rec,\"level\":$_JSON"
  json_str_or_null "$OT_NOTE"; _JSON="$rec,\"note\":$_JSON}"
}

# ot_answer_text — the same for a person, on stdout.
ot_answer_text() {
  printf 'branch: %s (into %s)\n' "$OT_BRANCH" "$OT_BASE"
  printf 'commit: %s\n' "${OT_COMMIT:-none}"
  if [ "$OT_PUSHED" = 1 ]; then printf 'pushed: yes\n'; else printf 'pushed: no\n'; fi
  printf 'pull request: %s\n' "${OT_PR:-none}"
  if [ "$OT_MERGED" = 1 ]; then printf 'merged: yes\n'; else printf 'merged: no\n'; fi
  [ -z "$OT_NOTE" ] || printf 'note: %s\n' "$OT_NOTE"
}
