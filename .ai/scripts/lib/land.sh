# Landing a task on the staging branch
# (adr-20261111-a-task-lands-on-staging-through-its-pull-request): the task's
# pull request into `git.staging_branch`, opened by `jig task ship`, merged on
# the forge when it merges cleanly, and merged directly into the staging branch
# only when it conflicts — in a temporary worktree of that branch fetched fresh
# from origin, never in the person's checkout, the conflict resolved there by
# the agent, the result pushed without force and pushed again from a fresh
# fetch when origin has moved.
#
# Sourced by task.sh alone (ARCHITECTURE.md, Scripts layout: a subject large
# enough to crowd out its command); it only defines functions, and calls
# task.sh's readers and the `jig_*` steps of common.sh. Its one entry is
# land_task, which `jig task land` and `jig task ship` at `merge` both call.
# shellcheck shell=bash

# The exit code land_task leaves for its caller: 0 landed or an ordinary
# "not landed", 3 a person decides, 5 a conflict waits for the agent.
_LAND_RC=0

# How many times one run pushes the staging branch before it gives up on an
# origin that keeps moving.
_LAND_PUSHES=3

# land_tree_path <id> — the temporary worktree a direct merge of <id> is made
# in: `.land-<id>` under git.worktree_root, beside the task worktrees
# (ADR-0029) and outside `.git/`, so the agent edits it with its ordinary
# tools. The leading dot keeps it from ever being a task's worktree: no task
# id starts with one (jig_valid_id). The only path _land_tree_remove is given.
land_tree_path() {
  local root
  jig_valid_id "$1" || jig_die "invalid task id: $1"
  root=$(_task_worktree_root)
  # Physical, as git records a worktree's path: the root's `..` resolved, by
  # its parent while the root itself is not made yet.
  if [ -d "$root" ]; then
    root=$(cd -P "$root" && pwd -P)
  elif [ -d "${root%/*}" ]; then
    root="$(cd -P "${root%/*}" && pwd -P)/${root##*/}"
  fi
  printf '%s/.land-%s\n' "$root" "$1"
}

# _land_tree_registered <path> — git lists a worktree at <path>. Both sides
# compared physically.
_land_tree_registered() {
  local want="$1" p
  [ ! -d "$want" ] || want=$(cd -P "$want" && pwd -P)
  while IFS= read -r p; do
    [ ! -d "$p" ] || p=$(cd -P "$p" && pwd -P)
    [ "$p" = "$want" ] && return 0
  done < <(git -C "$JIG_PROJECT" worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10) }')
  return 1
}

# _land_tree_remove <path> — take the temporary worktree away through git, with
# `--force`: only Jig makes it, under a name no task worktree has, and all it
# holds worth keeping is the resolution, which git's rerere cache and the
# task's land-note keep. What git leaves behind goes as housekeeping's leftover
# does (jig_worktree_leftover: links and empty directories only).
_land_tree_remove() {
  local path="$1"
  case "$path" in */.land-*) ;; *) return 0 ;; esac
  git -C "$JIG_PROJECT" worktree remove --force "$path" >/dev/null 2>&1 || true
  [ -e "$path" ] || return 0
  _land_tree_registered "$path" && return 0
  jig_worktree_leftover "$path" || true
}

# _land_merge_head <tree> — the commit a merge in progress in <tree> brings in,
# or nothing.
_land_merge_head() {
  git -C "$1" rev-parse --verify --quiet MERGE_HEAD 2>/dev/null || true
}

# _land_unmerged <tree> — the paths still in conflict in <tree>, one per line.
_land_unmerged() {
  git -C "$1" diff --name-only --diff-filter=U 2>/dev/null | sort -u || true
}

# _land_git <tree> <args>... — git in the temporary tree with rerere on, so a
# resolution is recorded when it is committed and replayed when the same
# conflict comes back after a fresh fetch. Its cache is the clone's
# (`<git-common-dir>/rr-cache`).
_land_git() {
  local tree="$1"
  shift
  git -C "$tree" -c rerere.enabled=true -c rerere.autoUpdate=true "$@"
}

# _land_note_file <id> / _land_conflicts_file <id> — where the agent's account
# of the resolution and the paths that conflicted are kept between the stop and
# `--resolved`, and across a push retried from a fresh fetch. In the task's
# gitignored workspace.
_land_note_file() { printf '%s/land-note.md\n' "$(task_dir "$1")"; }
_land_conflicts_file() { printf '%s/land-conflicts\n' "$(task_dir "$1")"; }

# _land_forget <id> — the two files above, once the landing ended or was given up.
_land_forget() {
  rm -f "$(_land_note_file "$1")" "$(_land_conflicts_file "$1")" "$(_land_without_file "$1")"
}

# _land_without_file <id> — the person's word to land without review. It is
# for one landing attempt: kept only across the conflict stop (S5) and its
# `--resolved`, so the person is not asked twice, and gone however else the
# attempt ends — landed, not landed, refused after it was read
# (_land_word_end), and with `--abort`.
_land_without_file() { printf '%s/land-without-review\n' "$(task_dir "$1")"; }

# The task whose word _land_word_end forgets, and whether the attempt stopped
# at a conflict, the one end that keeps it.
_LAND_WORD_ID=""
_LAND_KEEP_WORD=0

# _land_word_end — the exit action that forgets the person's word when the
# attempt it was given for ended anywhere but at the conflict stop.
_land_word_end() {
  [ -n "$_LAND_WORD_ID" ] || return 0
  [ "$_LAND_KEEP_WORD" = 1 ] || rm -f "$(_land_without_file "$_LAND_WORD_ID")"
}

# _land_branch <id> — the task's branch as its state records it, which
# git.branch_template named when the task started; `task/<id>` only for a task
# whose state names none.
_land_branch() {
  local b
  b=$(task_state_get "$1" branch)
  printf '%s\n' "${b:-task/$1}"
}

# _land_start_merge <who> <id> <tree> <staging> <sha> — a fresh tree at origin's
# staging branch with <sha> merged in, not committed. Prints nothing.
_land_start_merge() {
  local who="$1" id="$2" tree="$3" staging="$4" sha="$5" out
  _land_tree_remove "$tree"
  [ ! -e "$tree" ] || jig_die "$who: $tree is in the way and git will not remove it; delete that directory, then run again"
  mkdir -p "${tree%/*}" || jig_die "$who: cannot create ${tree%/*}"
  out=$(git -C "$JIG_PROJECT" worktree add -q --detach "$tree" "refs/remotes/origin/$staging" 2>&1) \
    || jig_die "$who: could not make a worktree of $staging at $tree: $out"
  _land_git "$tree" merge --no-ff --no-commit "$sha" >/dev/null 2>&1 || true
  [ -n "$(_land_merge_head "$tree")" ] \
    || jig_die "$who: git did not start the merge of $(_land_branch "$id") into $staging in $tree"
  # A path rerere resolved is staged, but the merge is not committed: what it
  # replayed is part of the recorded conflicts all the same.
  _land_git "$tree" rerere status 2>/dev/null >> "$(_land_conflicts_file "$id")" || true
  _land_unmerged "$tree" >> "$(_land_conflicts_file "$id")"
  local f
  f=$(_land_conflicts_file "$id")
  sort -u "$f" | awk 'NF' > "$f.tmp" && mv "$f.tmp" "$f"
}

# _land_commit <who> <id> <tree> <staging> — commit the merge in progress in
# <tree>, its message naming the paths that conflicted and the resolution.
_land_commit() {
  local who="$1" id="$2" tree="$3" staging="$4" msg out files
  msg=$(mktemp "${TMPDIR:-/tmp}/jig-land-msg.XXXXXX")
  jig_cleanup_add "$msg"
  files=$(cat "$(_land_conflicts_file "$id")" 2>/dev/null || true)
  {
    printf 'Merge %s into %s\n' "$(_land_branch "$id")" "$staging"
    if [ -n "$files" ]; then
      printf '\nConflicts resolved:\n'
      printf '%s\n' "$files" | sed 's/^/  /'
      if [ -s "$(_land_note_file "$id")" ]; then
        printf '\n'
        cat "$(_land_note_file "$id")"
      fi
    fi
  } > "$msg"
  out=$(_land_git "$tree" commit -q -F "$msg" 2>&1) \
    || jig_die "$who: could not commit the merge in $tree: $(_jig_ship_first_line "$out")"
}

# _land_stop_conflict <who> <id> <tree> <staging> <moved> — S5: the conflict is
# the agent's to resolve, in <tree>. Exit code 5.
_land_stop_conflict() {
  local who="$1" id="$2" tree="$3" staging="$4" moved="$5" files
  files=$(_land_unmerged "$tree")
  if [ "$moved" = 1 ]; then
    printf '%s: %s moved while landing; the earlier resolution was replayed, these conflicts are new:\n' "$who" "$staging"
  fi
  printf '%s: %s conflicts with %s; resolve in %s:\n' "$who" "$(_land_branch "$id")" "$staging" "$tree"
  if [ -n "$files" ]; then
    printf '%s\n' "$files" | sed 's/^/  /'
  else
    printf '  (none left: an earlier resolution was replayed; check it)\n'
  fi
  printf 'Resolve every conflict there (any file, the task'"'"'s or not), git add, then: jig task land %s --resolved --note-file <file> (how each conflict was resolved). jig task land %s --abort gives up.\n' "$id" "$id"
  _LAND_RC=5
  _LAND_KEEP_WORD=1
}

# _land_push_kind <output> — stale when origin refused the push because the
# branch moved past what was merged (a fresh fetch answers it), refused for
# any other refusal: branch protection, a hook, rights.
_land_push_kind() {
  case "$1" in
    *"remote rejected"* | *"protected branch"* | *"hook declined"*) printf 'refused\n' ;;
    *"[rejected]"*"fetch first"* | *"[rejected]"*"non-fast-forward"* | *"stale info"*) printf 'stale\n' ;;
    *) printf 'refused\n' ;;
  esac
}

# land_abort <who> <id> — give a landing in progress up: the tree and the
# files kept beside it, nothing sent and origin untouched.
land_abort() {
  local who="$1" id="$2" tree
  tree=$(land_tree_path "$id")
  if [ -e "$tree" ] || _land_tree_registered "$tree"; then
    _land_tree_remove "$tree"
    [ ! -e "$tree" ] || jig_die "$who: $tree is in the way and git will not remove it; delete that directory"
    printf '%s: %s removed; nothing was sent\n' "$who" "$tree"
  else
    printf '%s: no landing in progress for %s\n' "$who" "$id"
  fi
  _land_forget "$id"
}

# _land_approval_gate <who> <id> <pr> <without> — whether the pull request may
# land now by `git.staging_review`. Sets _LAND_RC and returns 1 when it may not
# (S7 or S8 said); 0 when it may.
_land_approval_gate() {
  local who="$1" id="$2" pr="$3" without="$4" review approval why
  review=$(jig_staging_review) || review=ask
  if [ "$review" = none ]; then
    printf '%s: landing %s without an approval: git.staging_review is none\n' "$who" "$pr"
    _LAND_WITHOUT="git.staging_review is none"
    return 0
  fi
  approval=$(jig_pr_approval "$pr")
  [ "$approval" != approved ] || return 0
  case "$approval" in
    changes) why="changes requested" ;;
    none) why="no review" ;;
    *) why="the forge cannot say" ;;
  esac
  if [ "$without" = 1 ]; then
    printf '%s: landing %s without an approval (%s), at the person'"'"'s word (--without-review)\n' "$who" "$pr" "$why"
    _LAND_WITHOUT="at the person's word"
    : > "$(_land_without_file "$id")"
    return 0
  fi
  if [ "$review" = require ]; then
    printf 'not landed: %s is not approved (%s) and git.staging_review is require; %s waits for review\n' "$pr" "$why" "$id"
    _LAND_RC=0
    return 1
  fi
  if _task_nobody_answers "$id"; then
    printf 'not landed: %s is not approved (%s) and an unattended run waits; %s waits for review\n' "$pr" "$why" "$id"
    _LAND_RC=0
    return 1
  fi
  printf '%s: %s is not approved (%s). Ask the person: land without review — jig task land %s --without-review — or wait for review (the pull request stays open)\n' "$who" "$pr" "$why" "$id"
  _LAND_RC=3
  return 1
}

# Set by _land_approval_gate when the pull request lands without an approval:
# why, for the pull request comment.
_LAND_WITHOUT=""

# land_task <who> <id> <without-review> <resolved> <note-file> — land <id>'s
# pull request on the staging branch, or say why not. The git level is the
# caller's to have checked (`merge`). Refuses with jig_die (exit 1) before it
# sends anything; otherwise leaves the exit code in _LAND_RC and returns 0:
# 0 landed or not landed for an ordinary reason (`landed …`, `not landed: …`),
# 3 a person decides, 5 a conflict waits in the temporary tree.
land_task() {
  local who="$1" id="$2" without="$3" resolved="$4" note="$5"
  local staging flow base base_branch land branch pr state failed sha local_tip ahead
  _LAND_RC=0
  _LAND_WITHOUT=""

  # The flow, the branch and the pull request: all local reads.
  if ! staging=$(jig_staging_in_use); then
    flow=$(jig_git_flow) || true
    jig_die "$who: $id is not on the staging flow (git.flow: $flow); a task in this project lands with jig task ship"
  fi
  base=$(jig_task_base "$id")
  base_branch=$(cfg git.base_branch main)
  [ "$base" = "$base_branch" ] \
    || jig_die "$who: $id is cut from $base, not $base_branch; the staging flow does not apply to it"
  land=$(jig_staging_land) || land="pr"
  branch=$(task_state_get "$id" branch)
  [ "$land" != external ] \
    || jig_die "$who: git.staging_land is external, so CI lands ${branch:-task/$id} on $staging; Jig merges nothing there"
  [ -n "$branch" ] || jig_die "$who: $id has not been started (no branch); run jig task start $id first"
  pr=$(task_state_get "$id" pr_url)
  [ -n "$pr" ] || jig_die "$who: $id has no pull request into $staging; run jig task ship $id first"
  if [ "$resolved" = 1 ]; then
    if [ -z "$note" ] || [ ! -s "$note" ] || ! grep -q '[^[:space:]]' "$note"; then
      jig_die "$who: --resolved needs --note-file with how each conflict was resolved; it goes into the merge commit and the pull request"
    fi
  fi
  if [ "$without" = 1 ]; then
    [ "$(jig_staging_review || true)" != require ] \
      || jig_die "$who: --without-review: git.staging_review is require, so $pr waits for an approval"
    ! _task_nobody_answers "$id" \
      || jig_die "$who: --without-review: nobody answers in an unattended run, so $pr waits for review"
  fi

  # The person's word given earlier in this landing, still standing while a
  # conflict is resolved — only where it could be given now: `ask`, and
  # somebody answers.
  if [ "$without" = 0 ] && [ -f "$(_land_without_file "$id")" ] \
    && [ "$(jig_staging_review || true)" = ask ] && ! _task_nobody_answers "$id"; then
    without=1
  fi
  if [ "$without" = 1 ]; then
    _LAND_WORD_ID=$id
    _LAND_KEEP_WORD=0
    jig_on_exit '_land_word_end'
  fi

  # On GitHub, the account this clone writes as, named here in this shell
  # before the first question to the forge: landing comments and merges, and
  # never as an account nobody named (adr-20261110-a-clone-names-its-github-account).
  if [ "$(jig_forge_kind 2>/dev/null || true)" = github ]; then
    jig_gh_require "$who"
  fi

  state=$(jig_pr_state "$pr")
  case "$state" in
    merged)
      printf '%s is already on %s (%s merged)\n' "$id" "$staging" "$pr"
      return 0 ;;
    closed) jig_die "$who: $pr is closed; ship $id again to open a new pull request into $staging" ;;
  esac

  # What leaves this machine from here is a merge, never a commit of the
  # task's: the ship's outward guard (common.sh) is told so.
  [ -n "$_JIG_SHIP_SENDS" ] || jig_ship_sends_no_commit "landing the pull request a ship already sent"

  # The task's own gates, as before any merge.
  local refusal
  refusal=$(_task_ship_refusal "$id" 0) || exit 1
  [ -z "$refusal" ] || jig_die "$who: ${refusal#task ship: }"

  # Origin as it is now: the staging branch, the task's branch and its base.
  jig_git_origin_account "$who" read
  if ! failed=$(jig_fetch_fresh "$staging" "$branch" "$base"); then
    jig_die "$who: could not fetch $failed from origin; a merge into $staging needs it fresh. Nothing was merged; run again"
  fi
  sha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}" 2>/dev/null) \
    || jig_die "$who: origin has no $branch; run jig task ship $id first"
  local_tip=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null || true)
  if [ -n "$local_tip" ] && [ "$local_tip" != "$sha" ]; then
    ahead=$(git -C "$JIG_PROJECT" rev-list --count "$sha..$local_tip" 2>/dev/null || printf '0')
    [ "$ahead" -eq 0 ] \
      || jig_die "$who: $branch has $ahead commit(s) origin does not; only what was shipped lands. Run jig task ship $id first"
  fi

  # The clean-branch rule: nothing of the staging branch the base did not bring.
  land_clean_branch_refusal "$who" "$id" "$sha" "$base" "$staging"

  # Review, by git.staging_review.
  _land_approval_gate "$who" "$id" "$pr" "$without" || return 0

  local tree
  tree=$(land_tree_path "$id")
  if [ "$resolved" = 1 ]; then
    _land_resolved "$who" "$id" "$tree" "$staging" "$sha" "$pr" "$note"
    return 0
  fi
  # A conflict already waiting for the agent is said again, not started over.
  if [ -n "$(_land_merge_head "$tree" 2>/dev/null)" ] && _land_tree_registered "$tree"; then
    _land_stop_conflict "$who" "$id" "$tree" "$staging" 0
    return 0
  fi

  case "$(jig_pr_mergeable "$pr")" in
    draft)
      printf 'not landed: %s is a draft; a draft is never landed\n' "$pr"
      return 0 ;;
    unknown)
      printf 'not landed: the forge could not say whether %s merges cleanly into %s; run jig task land %s again\n' "$pr" "$staging" "$id"
      return 0 ;;
    clean)
      _land_on_forge "$who" "$id" "$pr" "$sha" "$staging"
      return 0 ;;
  esac
  # A conflict: the direct merge.
  : > "$(_land_conflicts_file "$id")"
  _land_start_merge "$who" "$id" "$tree" "$staging" "$sha"
  if [ -n "$(_land_unmerged "$tree")" ] || [ ! -s "$(_land_note_file "$id")" ]; then
    _land_stop_conflict "$who" "$id" "$tree" "$staging" 0
    return 0
  fi
  # Every conflict replayed from a resolution the agent already gave.
  _land_commit "$who" "$id" "$tree" "$staging"
  _land_push "$who" "$id" "$tree" "$staging" "$sha" "$pr"
}

# land_clean_branch_refusal <who> <id> <tip> <base> <staging> — die with R14
# when the task branch at <tip> carries what it may not: anything but the base
# and clean task branches merged into it (jig_branch_carries_staging,
# common.sh); also when that cannot be told. At HEAD, a merge in progress is
# judged as the commit that will conclude it: its MERGE_HEAD heads are passed
# along, so a ship never commits what this would refuse once committed.
# The refs are origin's when this checkout has them (jig_base_ref).
land_clean_branch_refusal() {
  local who="$1" id="$2" tip="$3" base="$4" staging="$5" base_ref staging_ref carried n merge what file h br
  local -a heads=()
  base_ref=$(jig_base_ref "$base")
  staging_ref=$(jig_base_ref "$staging")
  br=$(_land_branch "$id")
  # No staging branch here: the rule cannot be judged, and is never read as
  # met (its callers fetch it first). No base here: nothing can be judged
  # against it, and the ship refuses that itself before it sends anything
  # (jig_ship_require_commits), as land's fetch does.
  [ -n "$staging_ref" ] \
    || jig_die "$who: cannot tell whether $br carries commits of $staging: there is no $staging here or on origin; fetch it and run again"
  [ -n "$base_ref" ] || return 0
  if [ "$tip" = HEAD ]; then
    file=$(git -C "$JIG_PROJECT" rev-parse --git-path MERGE_HEAD 2>/dev/null) || file=""
    case "$file" in '' | /*) ;; *) file="$JIG_PROJECT/$file" ;; esac
    if [ -n "$file" ] && [ -f "$file" ]; then
      while IFS= read -r h; do
        [ -z "$h" ] || heads+=("$h")
      done < "$file"
    fi
  fi
  if ! carried=$(jig_branch_carries_staging "$tip" "$base_ref" "$staging_ref" ${heads[@]+"${heads[@]}"}); then
    jig_die "$who: cannot tell whether $br carries commits of $staging: $tip, ${base_ref:-$base} or $staging_ref names no commit here"
  fi
  [ -n "$carried" ] || return 0
  n=$(printf '%s\n' "$carried" | awk 'NF { n++ } END { print n + 0 }')
  IFS=$'\t' read -r _ merge what <<EOF
$(printf '%s\n' "$carried" | awk 'NF { print; exit }')
EOF
  [ "$merge" != "the merge in progress" ] || merge="the merge in progress, not committed yet"
  if [ "$merge" = - ]; then
    jig_die "$who: $br is $what, not $base: $n commit(s) of its first-parent line are on $staging's own. A task branch stays clean until it reaches $base: only $base and clean task branches may be merged into it. Rebuild it from its own commits on $base and ship again; a conflict with $staging is resolved on $staging when the task lands"
  fi
  jig_die "$who: $br carries $n commit(s) that $base does not have, through a merge of $what into the branch ($merge). A task branch stays clean until it reaches $base: only $base and clean task branches may be merged into it. Rebuild it without that merge (its own commits on $base) and ship again; a conflict with $staging is resolved on $staging when the task lands"
}

# _land_on_forge <who> <id> <pr> <sha> <staging> — the clean case: the forge
# merges the pull request (jig_ship_merge, with a merge commit, since squash and
# rebase break the ancestry "on staging" is read from). Any refusal stays a
# refusal: the direct merge is never the way around red CI or protection.
_land_on_forge() {
  local who="$1" id="$2" pr="$3" sha="$4" staging="$5" out line
  out=$(mktemp "${TMPDIR:-/tmp}/jig-land-merge.XXXXXX")
  jig_cleanup_add "$out"
  jig_ship_merge "$who" "$pr" "$sha" merge-commit > "$out"
  while IFS= read -r line; do
    case "$line" in
      "not merged: "*) printf 'not landed: %s\n' "${line#not merged: }" ;;
      "merged "*) ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$out"
  if [ "$JIG_SHIP_MERGED" = 1 ]; then
    printf 'landed %s on %s (merged on the forge)\n' "$pr" "$staging"
    [ -z "$_LAND_WITHOUT" ] || _land_comment "$who" "$id" "$pr" "$staging" ""
  fi
}

# _land_resolved <who> <id> <tree> <staging> <sha> <pr> <note> — `--resolved`:
# check what the agent left in <tree>, commit it and push.
_land_resolved() {
  local who="$1" id="$2" tree="$3" staging="$4" sha="$5" pr="$6" note="$7" head left markers unstaged
  head=$(_land_merge_head "$tree" 2>/dev/null)
  if [ -z "$head" ] || ! _land_tree_registered "$tree"; then
    jig_die "$who: nothing to resolve: no landing in progress for $id; run jig task land $id"
  fi
  [ "$head" = "$sha" ] \
    || jig_die "$who: $(_land_branch "$id") moved since the merge started ($head -> $sha); run jig task land $id --abort, then land again"
  left=$(_land_unmerged "$tree")
  unstaged=$(git -C "$tree" diff --name-only 2>/dev/null || true)
  if [ -n "$left" ] || [ -n "$unstaged" ]; then
    jig_die "$who: $(printf '%s\n%s\n' "$left" "$unstaged" | awk 'NF' | sort -u | awk 'END { print NR }') path(s) in $tree are still unmerged or not added:
$(printf '%s\n%s\n' "$left" "$unstaged" | awk 'NF' | sort -u | sed 's/^/  /')
Resolve them and git add, then run again"
  fi
  markers=$(git -C "$tree" diff --cached --check 2>/dev/null | grep 'leftover conflict marker' || true)
  [ -z "$markers" ] || jig_die "$who: conflict markers left in $tree:
$(printf '%s\n' "$markers" | sed 's/^/  /')"
  cp "$note" "$(_land_note_file "$id").tmp" && mv "$(_land_note_file "$id").tmp" "$(_land_note_file "$id")"
  _land_commit "$who" "$id" "$tree" "$staging"
  _land_push "$who" "$id" "$tree" "$staging" "$sha" "$pr"
}

# _land_push <who> <id> <tree> <staging> <sha> <pr> — push the merge committed in
# <tree> to origin's staging branch, never forced. Origin moved past it: fetch
# afresh, merge again in a new tree (rerere replays the resolution) and push
# again, _LAND_PUSHES times at most. Any other refusal stops, the tree kept.
_land_push() {
  local who="$1" id="$2" tree="$3" staging="$4" sha="$5" pr="$6" try=1 out kind failed merged head
  # As the clone's account; the merge commit is in the shared object store,
  # so it is pushed from the project by its sha.
  jig_git_origin_account "$who" write
  while :; do
    head=$(git -C "$tree" rev-parse --verify HEAD 2>/dev/null) || head=""
    if [ -n "$head" ] && out=$(jig_net jig_git_origin push origin "$head:refs/heads/$staging" 2>&1); then
      break
    fi
    kind=$(_land_push_kind "$out")
    if [ "$kind" != stale ]; then
      printf 'not landed: origin refused the push to %s: %s. Nothing was forced; %s stays open. The merge with the resolution is in %s: a person pushes it with their own rights or lands the pull request on the forge; jig task land %s --abort removes it\n' \
        "$staging" "$(_jig_ship_first_line "$out")" "$pr" "$tree" "$id"
      _LAND_RC=3
      return 0
    fi
    if [ "$try" -ge "$_LAND_PUSHES" ]; then
      _land_tree_remove "$tree"
      printf 'not landed: %s moved under %s pushes in a row; %s stays open; run jig task land %s again\n' "$staging" "$_LAND_PUSHES" "$pr" "$id"
      _LAND_RC=3
      return 0
    fi
    try=$((try + 1))
    printf '%s: origin has moved %s since the merge; merging again from a fresh fetch (push %s of %s)\n' "$who" "$staging" "$try" "$_LAND_PUSHES"
    if ! failed=$(jig_fetch_fresh "$staging"); then
      jig_die "$who: could not fetch $failed from origin; a merge into $staging needs it fresh. Nothing was merged; run again"
    fi
    _land_start_merge "$who" "$id" "$tree" "$staging" "$sha"
    if [ -n "$(_land_unmerged "$tree")" ]; then
      _land_stop_conflict "$who" "$id" "$tree" "$staging" 1
      return 0
    fi
    _land_commit "$who" "$id" "$tree" "$staging"
  done
  merged=$(git -C "$tree" rev-parse HEAD)
  _land_tree_remove "$tree"
  # Origin's staging branch, as this push left it.
  git -C "$JIG_PROJECT" update-ref "refs/remotes/origin/$staging" "$merged" 2>/dev/null || true
  local files
  files=$(cat "$(_land_conflicts_file "$id")" 2>/dev/null || true)
  printf 'landed %s on %s by a direct merge %s: the pull request conflicted with %s\n' "$pr" "$staging" "$merged" "$staging"
  if [ -n "$files" ]; then
    printf 'conflicts resolved in: %s\n' "$(printf '%s\n' "$files" | paste -sd ' ' -)"
    if [ -s "$(_land_note_file "$id")" ]; then
      printf 'resolution:\n'
      sed 's/^/  /' "$(_land_note_file "$id")"
    fi
  fi
  _land_comment "$who" "$id" "$pr" "$staging" "$merged"
  if [ "$(jig_pr_state "$pr")" = open ]; then
    printf '%s: %s still reads open on the forge though its head is in %s; close it by hand\n' "$who" "$pr" "$staging"
  fi
  _land_forget "$id"
}

# _land_comment <who> <id> <pr> <staging> <merge-sha> — the comment on the pull
# request: the direct merge with what conflicted and how it was resolved (when
# <merge-sha> is given), and a landing without an approval. A failure only
# warns: what it says is in the merge commit too.
_land_comment() {
  local who="$1" id="$2" pr="$3" staging="$4" merged="$5" body files why
  body=$(mktemp "${TMPDIR:-/tmp}/jig-land-comment.XXXXXX")
  jig_cleanup_add "$body"
  {
    if [ -n "$merged" ]; then
      printf 'Landed on %s by a direct merge %s: this pull request conflicted with %s.\n' "$staging" "$merged" "$staging"
      files=$(cat "$(_land_conflicts_file "$id")" 2>/dev/null || true)
      if [ -n "$files" ]; then
        printf 'Conflicts resolved in: %s\n' "$(printf '%s\n' "$files" | paste -sd ' ' -)"
        if [ -s "$(_land_note_file "$id")" ]; then
          printf 'Resolution:\n\n'
          cat "$(_land_note_file "$id")"
        fi
      fi
    else
      printf 'Landed on %s.\n' "$staging"
    fi
    if [ -n "$_LAND_WITHOUT" ]; then
      case "$_LAND_WITHOUT" in
        "at the person's word") why="Landed without an approval, at the person's word." ;;
        *) why="Landed without an approval: $_LAND_WITHOUT." ;;
      esac
      printf '\n%s\n' "$why"
    fi
  } > "$body"
  local err
  if ! err=$(jig_pr_comment "$pr" "$body"); then
    if [ -n "$merged" ]; then
      printf '%s: could not comment on %s: %s; the resolution is in the merge commit %s\n' "$who" "$pr" "$err" "$merged"
    else
      printf '%s: could not comment on %s: %s\n' "$who" "$pr" "$err"
    fi
  fi
}
