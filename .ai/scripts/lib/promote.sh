# shellcheck shell=bash
# "Prepare for prod": a task tested on the staging branch reaches a pull
# request into the base branch (adr-20261111-prepare-for-prod-opens-the-promotion-from-git-alone).
# Sourced by task.sh for `jig task promote` alone,
# so that every other task command pays for none of it.
#
# It runs from git and the forge alone: a CI runner has the repository and a
# forge token, never a workspace, a queue or `agent.git`. What a workspace
# adds where there is one — the link in `promote_url`, the dependency warning,
# the person's `agent.git` — is never required.
#
# Every refusal comes before the first step that leaves the machine
# (adr-20260925-a-ship-refuses-before-it-sends): the only things sent are a
# push of merges of the base the person or agent already made on the task
# branch, the pull request, and with git.promote_merge: auto its auto-merge
# switched on, or off for a release and a major release made a draft. One
# exception sends on a refusal and only takes a merge away: when origin's
# branch is not the tested one (branch-diverged, carries-staging,
# not-on-staging, behind-staging), auto-merge on the open promotion is
# switched off first (_promote_refuse_untested;
# adr-20261112-a-promotion-merges-itself-only-where-ci-gates-it).

# _promote_refuse <code> <message> — refuse this task's promotion: nothing was
# pushed and no pull request opened. It exits, as the functions of common.sh
# and task.sh the steps call do; a run over several tasks runs each in a
# subshell of its own (_promote_task), so a refusal ends that task alone.
_promote_refuse() {
  jig_fail "$@"
}

# _promote_refuse_untested <code> <message> <branch> <base> — refuse as
# _promote_refuse does, when origin's <branch> is not the commit that was
# tested: an open promotion into <base> with auto-merge on would merge that
# untested work on green CI, so it is switched off first and the refusal says
# so. The one step a refusal sends, and it only takes a merge away.
_promote_refuse_untested() {
  local code="$1" msg="$2" branch="$3" base="$4" url
  _PROMOTE_SWITCHED_OFF=""
  url=$(_promote_open_url "$branch" "$base")
  [ -z "$url" ] || _promote_auto_off "$url" "$branch is not the commit that was tested"
  [ -z "$_PROMOTE_SWITCHED_OFF" ] || msg="$msg
Auto-merge on $_PROMOTE_SWITCHED_OFF was switched off: it would have merged this into $base on green CI."
  _promote_refuse "$code" "$msg"
}

# _promote_needs_person <message> — a promotion only a person (or their
# agent) can finish: said on stderr, exit 3 from the command, as `task ship`
# hands over at `agent.git: none`.
_promote_needs_person() {
  printf '%s\n' "$1" >&2
  return 3
}

# _promote_fetch <who> <name>... — refresh origin/<name> for each branch, and
# refuse when one cannot be fetched: unlike jig_fetch_branches, which only
# warns, a promotion judged on a stale origin/<task-branch> would open its
# pull request on the real branch, which may hold a fix nobody tested.
# Through jig_git_origin, which sets GIT_TERMINAL_PROMPT=0 and GIT_SSH_COMMAND
# (conventions/shell.md).
_promote_fetch() {
  local who="$1" name out
  shift
  git -C "$JIG_PROJECT" remote get-url origin >/dev/null 2>&1 \
    || _promote_refuse failed "$who: this clone has no origin, so nothing can be judged against what was tested"
  # As the clone's account (jig_git_origin), named here, in this shell.
  jig_git_origin_account "$who" read
  for name in "$@"; do
    # In the C locale: git translates "couldn't find remote ref", and a
    # missing branch must not read as a failed fetch under another language.
    if ! out=$(LC_ALL=C
         export LC_ALL
         jig_net jig_git_origin fetch --quiet origin \
         "+refs/heads/$name:refs/remotes/origin/$name" 2>&1); then
      # Origin answered, and has no such branch: nothing there was tested.
      case "$out" in
        *"couldn't find remote ref"*)
          _promote_refuse not-found "$who: origin has no branch $name; what was not pushed was not tested" ;;
      esac
      _promote_refuse failed "$who: could not fetch $name from origin, so it cannot be judged as origin has it now. Nothing was pushed and no pull request opened; fix the fetch and run again.
$out"
    fi
  done
  return 0
}

# _promote_branch_of <id> — the task's branch: `branch` from its state where
# this checkout has one, else the name git.branch_template gives the id —
# what a CI runner, which has no workspace, has to go by.
_promote_branch_of() {
  local id="$1" branch template
  task_state_var branch "$id" branch
  if [ -z "$branch" ]; then
    template=$(cfg git.branch_template "task/{id}")
    case "$template" in
      *'{id}'*) branch=${template%%'{id}'*}$id${template#*'{id}'} ;;
      *) branch="task/$id" ;;
    esac
  fi
  printf '%s\n' "$branch"
}

# _promote_pr_rows <head> <base> <state> — "<url><TAB><title>" of the pull
# requests from <head> into <base> the forge reports in <state> (`open` or
# `all`), newest first; nothing without a forge or when it cannot answer.
_promote_pr_rows() {
  local head="$1" base="$2" state="$3" kind out
  kind=$(jig_forge_kind 2>/dev/null) || return 0
  case "$kind" in
    github)
      jig_net jig_gh pr list --head "$head" --base "$base" --state "$state" --json url,title \
        --jq '.[] | .url + "\t" + .title' 2>/dev/null || true ;;
    gitlab)
      if [ "$state" = all ]; then
        out=$(jig_net glab mr list --source-branch "$head" --target-branch "$base" --all --output json 2>/dev/null) || out=""
      else
        out=$(jig_net glab mr list --source-branch "$head" --target-branch "$base" --output json 2>/dev/null) || out=""
      fi
      printf '%s' "$out" | jig_glab_fields web_url title || true ;;
  esac
  return 0
}

# _promote_open_url <head> <base> — the open pull request from <head> into
# <base>, or nothing.
_promote_open_url() {
  local rows url
  rows=$(_promote_pr_rows "$1" "$2" open)
  url=${rows%%$'\t'*}
  url=${url%%$'\n'*}
  case "$url" in https://*) printf '%s\n' "$url" ;; esac
  return 0
}

# _promote_flow <who> — the project's flow, which must be staging, into
# _PROMOTE_FLOW, _PROMOTE_BASE and _PROMOTE_STAGING; refused otherwise.
_promote_flow() {
  local who="$1" problems
  problems=$(jig_git_flow_problems)
  [ -z "$problems" ] || _promote_refuse failed "$who: the project's git flow cannot be read:
$problems
Fix it in .ai/config.yaml (jig doctor names the same) and run again."
  _PROMOTE_FLOW=$(jig_git_flow) || _PROMOTE_FLOW=""
  _PROMOTE_BASE=$(cfg git.base_branch main)
  [ "$_PROMOTE_FLOW" = staging ] \
    || _promote_refuse failed "$who: the git flow is ${_PROMOTE_FLOW:-direct}, not staging; a task reaches $_PROMOTE_BASE by jig task ship"
  _PROMOTE_STAGING=$(jig_staging_branch)
}

# _promote_full_history <who> — refuse a shallow clone, where what a commit
# contains cannot be told.
_promote_full_history() {
  if [ "$(git -C "$JIG_PROJECT" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    _promote_refuse shallow-clone "$1: this clone is shallow, so what the tested commit contains cannot be told. Fetch the full history (actions/checkout fetch-depth: 0; GitLab GIT_DEPTH: 0) and run again."
  fi
  return 0
}

# _promote_tested_commit <who> <commit-arg> <base> <staging> — after the
# fetch, the tested commit into _PROMOTE_CSHA (<commit-arg>, which must be on
# origin/<staging>, else that branch's tip) and the base's commit into
# _PROMOTE_BASE_SHA; refused when either cannot be had.
_promote_tested_commit() {
  local who="$1" commit_arg="$2" base="$3" staging="$4" stip csha base_ref
  stip=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$staging^{commit}" 2>/dev/null) || stip=""
  [ -n "$stip" ] || _promote_refuse failed "$who: origin has no $staging branch, so nothing was tested on it"
  if [ -n "$commit_arg" ]; then
    csha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$commit_arg^{commit}" 2>/dev/null) || csha=""
    [ -n "$csha" ] || _promote_refuse not-found "$who: --commit $commit_arg names no commit here; fetch it and run again"
    git -C "$JIG_PROJECT" merge-base --is-ancestor "$csha" "$stip" 2>/dev/null \
      || _promote_refuse failed "$who: $commit_arg is not a commit of origin/$staging; the tested commit is one the staging branch has"
  else
    csha=$stip
  fi
  base_ref=$(jig_base_ref "$base")
  [ -n "$base_ref" ] || _promote_refuse failed "$who: no branch $base here or on origin; fetch it and run again"
  _PROMOTE_CSHA=$csha
  _PROMOTE_BASE_SHA=$(git -C "$JIG_PROJECT" rev-parse "$base_ref^{commit}")
}

# _promote_one <id> <commit> <title> <body-file> — promote one task: the steps
# numbered below, in order
# (adr-20261111-prepare-for-prod-opens-the-promotion-from-git-alone). Returns
# 0 (the pull request is open, or the task is in the base already) or 3 (a
# person is needed); a refusal exits 1 through _promote_refuse.
_promote_one() {
  local id="$1" commit_arg="$2" title="$3" body_file="$4"
  local who="task promote" t=$'\t' flow base staging dir have_ws=0 branch tbase run level="" runner=0
  _task_valid_id "$id" || _promote_refuse usage "invalid task id: $id"

  # 1. The flow.
  _promote_flow "$who"
  flow=$_PROMOTE_FLOW
  base=$_PROMOTE_BASE
  staging=$_PROMOTE_STAGING

  # 2. The task: its branch, and its base where a workspace records one.
  task_dir_v dir "$id"
  [ ! -f "$dir/state" ] || have_ws=1
  branch=$(_promote_branch_of "$id")
  if [ "$have_ws" = 1 ]; then
    tbase=$(jig_task_base "$id")
    [ "$tbase" = "$base" ] \
      || _promote_refuse failed "$who: $id is cut from $tbase, not $base; the staging flow does not apply to it"
  fi

  # 3. Rights: a runner's pipeline is the team's decision; a checkout's is
  # its person's agent.git. A runner is a process with CI set
  # (jig_on_ci_runner) and no workspace for the task: a real runner has none,
  # while a person's checkout with CI exported by some tool keeps its agent.git
  # wherever it has the task's workspace.
  # Autopilot never promotes, on a runner as in a checkout (decided by the
  # person, 2026-11-11): wherever a workspace says a run is on.
  if [ "$have_ws" = 1 ]; then
    task_state_var run "$id" autopilot
    [ "$run" != on ] \
      || _promote_refuse failed "$who: $id runs on autopilot, which never promotes; stop it, or let the person say prepare for prod"
  fi
  if [ "$have_ws" = 0 ] && jig_on_ci_runner; then
    runner=1
  fi
  if [ "$runner" = 0 ]; then
    level=$(jig_agent_git) || _promote_refuse failed "$who: invalid agent.git: $level (expected none|commit|push|pr|merge)"
    case "$level" in
      pr | merge) ;;
      *)
        _promote_needs_person "$who: agent.git is $level in this clone; opening the pull request into $base is the person's. Nothing was pushed."
        return 3 ;;
    esac
  fi

  # 4. History deep enough to tell what a commit contains.
  _promote_full_history "$who"

  # 5. Fresh refs, refused when one cannot be had, and the flow the base
  # branch names.
  _promote_fetch "$who" "$base" "$staging" "$branch"
  _task_ship_flow_agrees "$base" "$flow" "$staging" "$who"

  # 6. The tested commit.
  local csha base_sha
  _promote_tested_commit "$who" "$commit_arg" "$base" "$staging"
  csha=$_PROMOTE_CSHA
  base_sha=$_PROMOTE_BASE_SHA
  printf '%s: tested commit %s of %s\n' "$who" "$(git -C "$JIG_PROJECT" rev-parse --short "$csha")" "$staging"

  # 7. The tip: what the pull request will carry once pushed.
  local lsha osha tip push=0
  lsha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null) || lsha=""
  osha=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}" 2>/dev/null) || osha=""
  if [ -z "$lsha" ] && [ -z "$osha" ]; then
    _promote_refuse not-found "$who: no branch $branch here or on origin"
  elif [ -z "$lsha" ] || [ "$lsha" = "$osha" ]; then
    tip=$osha
  elif [ -z "$osha" ]; then
    tip=$lsha
    push=1
  elif git -C "$JIG_PROJECT" merge-base --is-ancestor "$lsha" "$osha" 2>/dev/null; then
    tip=$osha
  elif git -C "$JIG_PROJECT" merge-base --is-ancestor "$osha" "$lsha" 2>/dev/null; then
    tip=$lsha
    push=1
  else
    _promote_refuse_untested branch-diverged "$who: $branch here and on origin have diverged; nothing is forced. Bring them together and run again." "$branch" "$base"
  fi
  if git -C "$JIG_PROJECT" merge-base --is-ancestor "$tip" "$base_sha" 2>/dev/null; then
    printf '%s: %s is already in %s; nothing to promote\n' "$who" "$branch" "$base"
    return 0
  fi

  # 8. Against the tested commit: on it, nothing of its own after it, and no
  # staging merged in (_jig_staging_walk, the walk `jig status` reads).
  local walk state="" own="" line kind sha short url open_url=""
  walk=$(_jig_staging_walk "$csha" "$id$t$branch$t$base$t$tip")
  while IFS="$t" read -r kind _ sha; do
    case "$kind" in
      state) state=$sha ;;
      own) own="$own$sha"$'\n' ;;
    esac
  done <<EOF
$walk
EOF
  short=$(git -C "$JIG_PROJECT" rev-parse --short "$csha")
  # The branch is a clean task branch first (jig_staging_branch_problems):
  # cut from the base, with no staging and no other branch merged in but the
  # clean branch of another task, which goes to the base with this one and is
  # said so (decided by the person, 2026-11-11). Asked before the tested
  # commit is, so staging merged in, newer than that commit, is named for
  # what it is rather than listed as the task's own commits.
  local problems_line bad="" carry_warn="" dkind dval dsha dhow
  problems_line=$(jig_staging_branch_problems "$branch" "$tip" "$base" "$staging")
  while IFS="$t" read -r dkind dval dsha; do
    case "$dkind" in
      bad) bad="$bad
  $dval" ;;
      dep)
        # Brought in by a merge, or the branch is cut from that task's.
        if git -C "$JIG_PROJECT" rev-parse --verify --quiet "$dsha^2" >/dev/null 2>&1; then dhow="merged at"; else dhow="cut from it at"; fi
        carry_warn="$carry_warn$id carries $dval ($dhow $(git -C "$JIG_PROJECT" rev-parse --short "$dsha")); it reaches $base with this task"$'\n' ;;
    esac
  done <<EOF
$problems_line
EOF
  if [ -n "$bad" ]; then
    _promote_refuse_untested carries-staging "$who: $branch is not a clean task branch: it carries work that $base does not have and that is not its own:$bad
its pull request would take it to $base. Rebuild the branch from $base with its own commits only (a clean branch of another task may be merged in), ship it to $staging again, and run again after the test." "$branch" "$base"
  fi
  if [ -z "$state" ]; then
    _promote_refuse_untested not-on-staging "$who: $branch is not in the tested commit $short of $staging: none of its own commits is there.
It reaches $base only after it was tested on $staging: land it there (jig task ship) and run again after the test." "$branch" "$base"
  fi
  # On the task's first-parent line every commit but a merge of the base is
  # its own work and must be in the tested commit, a merge of a clean
  # dependency included: content made in that merge was never tested
  # otherwise. _jig_staging_walk does not
  # count such a merge, since its other parent is on the tested commit.
  local fpline fc fpp fbase notin
  notin=$(git -C "$JIG_PROJECT" rev-list "$tip" "^$base_sha" "^$csha" 2>/dev/null) || notin=""
  if [ -n "$notin" ]; then
    while IFS= read -r fpline; do
      [ -n "$fpline" ] || continue
      set -f
      # shellcheck disable=SC2086 # the commit and its parents, hexadecimal
      set -- $fpline
      set +f
      fc=$1
      jig_has_line "$fc" "$notin" || continue
      jig_has_line "$fc" "$own" && continue
      if [ $# -gt 2 ]; then
        fbase=1
        shift 2
        for fpp in "$@"; do
          git -C "$JIG_PROJECT" merge-base --is-ancestor "$fpp" "$base_sha" 2>/dev/null || fbase=0
        done
        [ "$fbase" = 0 ] || continue
      fi
      own="$own$fc"$'\n'
      state=behind
    done < <(git -C "$JIG_PROJECT" rev-list --first-parent --parents "$tip" "^$base_sha" 2>/dev/null)
  fi
  if [ "$state" = behind ]; then
    local list="" note=""
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      note=""
      if [ "$push" = 1 ] && { [ -z "$osha" ] || ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$sha" "$osha" 2>/dev/null; }; then
        note=" (not pushed)"
      fi
      list="$list
  $(git -C "$JIG_PROJECT" log -1 --format='%h %s' "$sha")$note"
    done <<EOF
$own
EOF
    open_url=$(_promote_open_url "$branch" "$base")
    _promote_refuse_untested behind-staging "$who: $branch has commit(s) of its own that the tested commit $short does not have:$list
A fix made after the test must be tested before it reaches $base: ship it to $staging and run again after the test.${open_url:+
The open pull request $open_url already carries them: it must not be merged before they are tested.
Close it first: it comes from this same branch, so jig task ship refuses while it is open, and every push reaches it. Then ship the fix to $staging, and run jig task promote again after the test.}" "$branch" "$base"
  fi

  # 9. A conflict with the base is found here and resolved by whoever merges
  # the base into the task branch: a script resolves no conflict (ADR-0001).
  local conflicts
  jig_merge_conflicts "$base_sha" "$tip" \
    || _promote_refuse failed "$who: could not try the merge of $branch into $base here"
  conflicts=$JIG_MERGE_CONFLICTS
  if [ -n "$conflicts" ]; then
    open_url=$(_promote_open_url "$branch" "$base")
    [ -z "$open_url" ] || printf 'pr %s (already open)\n' "$open_url"
    _promote_needs_person "$who: $branch conflicts with $base in:
$(printf '%s\n' "$conflicts" | sed 's/^/  /')
Nothing was pushed. Merge $base into the task branch and resolve it in the task's checkout
(git switch $branch && git merge origin/$base), commit, and run jig task promote $id again: it pushes the merge and opens the pull request."
    return 3
  fi

  # 10. Dependencies on the staging branch but not in the base, where this
  # checkout has a queue: a warning, never a refusal.
  local warnings="$carry_warn" dep reason dep_id dep_branch rows="" dline dkind did
  if jig_queue_place "$id"; then
    while IFS="$t" read -r dep reason; do
      case "$dep" in task:*) ;; *) continue ;; esac
      dep_id=${dep#task:}
      _task_valid_id "$dep_id" || continue
      dep_branch=$(_promote_branch_of "$dep_id")
      rows="$rows$dep_id$t$dep_branch$t$base$t${reason:-}"$'\n'
    done <<EOF
$_JIG_QUEUE_DEPS
EOF
  fi
  if [ -n "$rows" ]; then
    local states
    states=$(_jig_staging_walk "$csha" "$(printf '%s' "$rows" | awk -F '\t' '{ print $1 "\t" $2 "\t" $3 }')" \
      | awk -F '\t' '$1 == "state" { print $2 }')
    while IFS="$t" read -r did dep_branch _ reason; do
      [ -n "$did" ] || continue
      jig_has_line "$did" "$states" || continue
      dline=$(jig_base_ref "$dep_branch")
      [ -n "$dline" ] || continue
      if ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$dline" "$base_sha" 2>/dev/null; then
        warnings="$warnings$id depends on $did (queue${reason:+: $reason}), which is on $staging but not in $base; promote $did with this task or before it"$'\n'
      fi
    done <<EOF
$rows
EOF
  fi
  if [ -n "$warnings" ]; then
    while IFS= read -r dline; do
      [ -n "$dline" ] || continue
      printf '%s: warning: %s\n' "$who" "$dline"
    done <<EOF
$warnings
EOF
  fi

  # 11. A raised version makes the promotion a release; its merge is a
  # person's (adr-20261026-a-task-that-raises-the-version-is-a-release).
  local raise r_file="" r_old="" r_new="" r_level="" release_line=""
  raise=$(jig_release_raise "$base" "$tip")
  if [ -n "$raise" ]; then
    IFS="$t" read -r r_file r_old r_new r_level <<EOF
$raise
EOF
    printf "%s: this promotion raises the version in %s: %s -> %s; it is a release, and its merge is a person's\n" \
      "$who" "$r_file" "$r_old" "$r_new"
    release_line="Release: this promotion raises the version in $r_file: $r_old -> $r_new"
  fi

  # Who merges (git.promote_merge), decided before the pull request opens: a
  # major release where Jig would otherwise switch auto-merge on opens as a
  # draft for a person, as task ship's does at `merge`
  # (adr-20261026-a-task-that-raises-the-version-is-a-release).
  local pm may=0 draft=0
  pm=$(jig_promote_merge) || pm=human
  if [ "$runner" = 1 ] || [ "$level" = merge ]; then
    may=1
  fi
  if [ "$pm" = auto ] && [ "$may" = 1 ] && [ "$r_level" = major ]; then
    draft=1
    printf '%s: a major release needs a human; the pull request is a draft\n' "$who"
  fi

  # 12. Send: the base merges already made on the task branch, then the pull
  # request into the base branch, found by head and base together.
  jig_ship_sends_no_commit "a promotion commits nothing; it pushes only merges of the base already on the branch"
  if [ "$push" = 1 ]; then
    jig_ship_push "$who" "$branch"
  fi
  local staging_rows staging_url="" staging_title="" body
  staging_rows=$(_promote_pr_rows "$branch" "$staging" all)
  if [ -n "$staging_rows" ]; then
    line=${staging_rows%%$'\n'*}
    staging_url=${line%%"$t"*}
    staging_title=${line#*"$t"}
    [ "$staging_title" != "$line" ] || staging_title=""
  fi
  if [ -z "$title" ]; then
    title=$staging_title
    [ -n "$title" ] || title=$(git -C "$JIG_PROJECT" log -1 --no-merges --format=%s "$tip" "^$base_sha" 2>/dev/null)
    [ -n "$title" ] || title="Promote $branch to $base"
  fi
  body=$(mktemp "${TMPDIR:-/tmp}/jig-promote-body.XXXXXX")
  jig_cleanup_add "$body"
  {
    [ "$draft" = 0 ] || printf 'Needs a human: major release?\n\n'
    if [ -n "$body_file" ]; then
      cat "$body_file"
    else
      printf 'Promotes %s to %s, tested on %s at %s.\n' "$branch" "$base" "$staging" "$short"
      case "$staging_url" in https://*) printf 'Staging pull request: %s\n' "$staging_url" ;; esac
    fi
    if [ -n "$warnings" ]; then
      printf '\nDepends on\n\n'
      printf '%s' "$warnings" | sed 's/^/- /'
    fi
    if [ -n "$release_line" ] && [ -z "$body_file" ]; then
      printf '\n%s\n' "$release_line"
    fi
  } > "$body"
  jig_ship_pr "$who" "$branch" "$base" "$body" "$title" "$body" "$draft" 1
  url=$JIG_SHIP_URL
  case "$url" in
    https://*) ;;
    *)
      _promote_needs_person "$who: no forge available; open the pull request from $branch into $base by hand"
      return 3 ;;
  esac
  if [ "$have_ws" = 1 ]; then
    _task_rewrite_state "$dir" promote_url "$url"
  fi

  # 13. The merge, by git.promote_merge.
  _promote_merge "$who" "$url" "$tip" "$base" "$pm" "$may" "$level" "$draft" \
    "$r_file" "$r_old" "$r_new"
  return 0
}

# --- the merge of the promotion ------------------------------------------------
#
# adr-20261112-a-promotion-merges-itself-only-where-ci-gates-it. With
# `git.promote_merge: auto` Jig does not merge: it switches the forge's
# auto-merge on, and the pull request merges itself, with a merge commit, once
# the base's required checks pass. Only where the base requires checks at
# all — without them the forge merges at once and CI gates nothing (the
# reason adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci
# rejected `--auto`) — and never for a release. Every outcome returns 0: the
# pull request is open, and the last line says who merges it. Nothing here
# dies, so a run over several tasks gets each task's own result.

# _promote_merge <who> <url> <tip> <base> <pm> <may> <level> <draft> <file>
# <old> <new> — decide and print the merge of the promotion at <url>. <may> is
# 1 on a CI runner or at `agent.git: merge`; <file> is non-empty for a
# release, whose version went from <old> to <new>.
_promote_merge() {
  local who="$1" url="$2" tip="$3" base="$4" pm="$5" may="$6" level="$7" draft="$8"
  local r_file="$9" r_old="${10}" r_new="${11}" why kind
  if [ "$pm" != auto ]; then
    printf "%s: the merge is the person's (git.promote_merge: %s)\n" "$who" "$pm"
    return 0
  fi
  _promote_kind_once
  kind=$_PROMOTE_KIND
  if [ -n "$r_file" ]; then
    why="this promotion is a release ($r_file $r_old -> $r_new)"
    _promote_auto_off "$url" "$why"
    [ "$draft" = 0 ] || _promote_make_draft "$url"
    _promote_not_on "$why"
    return 0
  fi
  if [ "$may" != 1 ]; then
    _promote_not_on "agent.git is $level in this clone; switching it on needs merge"
    return 0
  fi
  case "$kind" in
    github) _promote_auto_github "$url" "$tip" "$base" ;;
    gitlab) _promote_auto_gitlab "$url" "$tip" ;;
    *) _promote_not_on "no forge available" ;;
  esac
  return 0
}

# _promote_kind_once — the forge this checkout uses (jig_forge_kind), asked
# once per task into _PROMOTE_KIND, in the caller's shell: every forge step
# below reads it through _promote_kind instead of asking `gh auth status`
# again.
_PROMOTE_KIND=""
# The pull request _promote_auto_off last switched auto-merge off on.
_PROMOTE_SWITCHED_OFF=""
_promote_kind_once() {
  [ -n "$_PROMOTE_KIND" ] || _PROMOTE_KIND=$(jig_forge_kind 2>/dev/null) || _PROMOTE_KIND=none
  [ -n "$_PROMOTE_KIND" ] || _PROMOTE_KIND=none
}

# _promote_kind — print _PROMOTE_KIND (_promote_kind_once runs first).
_promote_kind() {
  printf '%s\n' "${_PROMOTE_KIND:-none}"
}

# _promote_not_on <why> — the last line when auto-merge stays off.
_promote_not_on() {
  printf "auto-merge not switched on: %s; the merge is the person's\n" "$1"
}

# _promote_auto_state <url> — what the forge says of the pull request at
# <url>, into _PROMOTE_PR_STATE (open|merged|closed|unknown), _PROMOTE_PR_DRAFT
# (true|false), _PROMOTE_PR_HEAD (its head commit: GitHub's headRefOid,
# GitLab's diff_refs.head_sha, else its top-level `sha`) and
# _PROMOTE_PR_AUTO (on|off). Called directly, never in `$()`. Anything it
# cannot read leaves `unknown`.
_promote_auto_state() {
  local url="$1" view s d h a json iid flat
  _PROMOTE_PR_STATE=unknown
  _PROMOTE_PR_DRAFT=false
  _PROMOTE_PR_HEAD=""
  _PROMOTE_PR_AUTO=off
  case "$(_promote_kind)" in
    github)
      view=$(jig_net jig_gh pr view "$url" --json state,isDraft,headRefOid,autoMergeRequest \
        --jq '"\(.state) \(.isDraft) \(.headRefOid) \(if .autoMergeRequest then "on" else "off" end)"' 2>/dev/null) \
        || return 0
      read -r s d h a <<EOF
$view
EOF
      case "$s" in
        OPEN) _PROMOTE_PR_STATE=open ;;
        MERGED) _PROMOTE_PR_STATE=merged ;;
        CLOSED) _PROMOTE_PR_STATE=closed ;;
        *) return 0 ;;
      esac
      _PROMOTE_PR_DRAFT=${d:-false}
      _PROMOTE_PR_HEAD=$h
      [ "$a" != on ] || _PROMOTE_PR_AUTO=on
      ;;
    gitlab)
      iid=$(_jig_ship_glab_mr "$url")
      [ -n "$iid" ] || return 0
      json=$(jig_net glab mr view "$iid" --output json 2>/dev/null) || return 0
      s=$(printf '%s' "$json" | jig_glab_fields state)
      case "$s" in
        opened) _PROMOTE_PR_STATE=open ;;
        merged) _PROMOTE_PR_STATE=merged ;;
        closed | locked) _PROMOTE_PR_STATE=closed ;;
        *) return 0 ;;
      esac
      flat=$(printf '%s' "$json" | tr -d ' \n')
      case "$flat" in
        *'"draft":true'* | *'"work_in_progress":true'*) _PROMOTE_PR_DRAFT=true ;;
      esac
      case "$flat" in
        *'"merge_when_pipeline_succeeds":true'* | *'"auto_merge_enabled":true'*) _PROMOTE_PR_AUTO=on ;;
      esac
      # The head: diff_refs.head_sha names it alone; `sha` is taken at its
      # first occurrence, the merge request's own before its pipeline's.
      h=$(printf '%s' "$flat" | jig_glab_fields head_sha)
      [ -n "$h" ] || h=$(printf '%s' "$flat" | jig_glab_fields sha)
      _PROMOTE_PR_HEAD=$h
      ;;
  esac
  return 0
}

# _promote_base_gated_github <base> — yes when <base> requires a status
# check, by a ruleset or by classic branch protection; no when GitHub answered
# and neither does; unknown when it could not be asked.
_promote_base_gated_github() {
  local base="$1" rules classic
  rules=$(jig_net jig_gh api "repos/{owner}/{repo}/rules/branches/$base" \
    --jq '[.[] | select(.type == "required_status_checks")] | length' 2>/dev/null) || rules=""
  # shellcheck disable=SC2016 # $r is jq's, not the shell's
  classic=$(jig_net jig_gh api "repos/{owner}/{repo}/branches/$base" \
    --jq '(.protection.required_status_checks // {}) as $r | if ($r.enforcement_level // "everyone") == "off" then 0 else ((($r.contexts // []) + ($r.checks // [])) | length) end' \
    2>/dev/null) || classic=""
  case "$rules" in '' | *[!0-9]*) rules="" ;; esac
  case "$classic" in '' | *[!0-9]*) classic="" ;; esac
  if [ "${rules:-0}" -gt 0 ] || [ "${classic:-0}" -gt 0 ]; then
    printf 'yes\n'
  elif [ -n "$rules" ] || [ -n "$classic" ]; then
    printf 'no\n'
  else
    printf 'unknown\n'
  fi
}

# _promote_auto_settled <url> <base> — after the forge was asked: merged at
# once (its checks had already passed), on, or not confirmed.
_promote_auto_settled() {
  _promote_auto_state "$1"
  if [ "$_PROMOTE_PR_STATE" = merged ]; then
    printf 'merged %s\n' "$1"
  elif [ "$_PROMOTE_PR_AUTO" = on ]; then
    printf "auto-merge on %s: it merges with a merge commit once %s's required checks pass\n" "$1" "$2"
  else
    _promote_not_on "the forge did not confirm it"
  fi
}

# _promote_auto_known <url> <tip> — the checks every forge shares, on the
# state just read: 0 when auto-merge may be switched on now; 1 when a line was
# printed and nothing is to be done.
_promote_auto_known() {
  local url="$1" tip="$2"
  case "$_PROMOTE_PR_STATE" in
    merged)
      printf 'merged %s\n' "$url"
      return 1 ;;
    open) ;;
    *)
      _promote_not_on "could not read the pull request"
      return 1 ;;
  esac
  if [ "$_PROMOTE_PR_DRAFT" = true ]; then
    _promote_not_on "the pull request is a draft"
    return 1
  fi
  if [ -n "$_PROMOTE_PR_HEAD" ] && [ "$_PROMOTE_PR_HEAD" != "$tip" ]; then
    # Auto-merge already on would merge that other head: switched off.
    [ "$_PROMOTE_PR_AUTO" != on ] \
      || _promote_auto_off "$url" "the pull request is at $_PROMOTE_PR_HEAD, not at the promoted $tip"
    _promote_not_on "the pull request is at $_PROMOTE_PR_HEAD, not at the promoted $tip"
    return 1
  fi
  if [ "$_PROMOTE_PR_AUTO" = on ]; then
    printf 'auto-merge on %s (already on)\n' "$url"
    return 1
  fi
  return 0
}

# _promote_auto_github <url> <tip> <base> — switch auto-merge on through gh,
# with a merge commit and at <tip> (`--match-head-commit`), only where the
# repository allows auto-merge and merge commits and <base> requires a check.
_promote_auto_github() {
  local url="$1" tip="$2" base="$3" allowed am mc gated out
  _promote_auto_state "$url"
  _promote_auto_known "$url" "$tip" || return 0
  allowed=$(jig_net jig_gh repo view --json autoMergeAllowed,mergeCommitAllowed \
    --jq '"\(.autoMergeAllowed) \(.mergeCommitAllowed)"' 2>/dev/null) || allowed=""
  read -r am mc <<EOF
$allowed
EOF
  if [ -z "$allowed" ]; then
    _promote_not_on "could not read the repository's merge settings"
    return 0
  fi
  if [ "$am" != true ]; then
    _promote_not_on "the repository does not allow auto-merge (Settings, General, Allow auto-merge)"
    return 0
  fi
  if [ "$mc" != true ]; then
    _promote_not_on "the repository does not allow merge commits, and a promotion keeps its ancestry only with one"
    return 0
  fi
  gated=$(_promote_base_gated_github "$base")
  case "$gated" in
    yes) ;;
    no)
      _promote_not_on "$base requires no status check, so auto-merge would merge at once and CI would gate nothing"
      return 0 ;;
    *)
      _promote_not_on "could not tell whether $base requires status checks"
      return 0 ;;
  esac
  _jig_ship_outward "task promote"
  if ! out=$(jig_net jig_gh pr merge "$url" --auto --merge --match-head-commit "$tip" 2>&1); then
    _promote_not_on "the forge refused: $(_jig_ship_first_line "$out")"
    return 0
  fi
  _promote_auto_settled "$url" "$base"
}

# _promote_auto_gitlab <url> <tip> — the same through glab: only in a project
# that requires a successful pipeline to merge, merging with a merge commit
# and no squash — `merge`, not semi-linear `rebase_merge`, which merges only a
# branch level with the target and rebases the tested commits to get there;
# `--sha` holds the merge request at <tip>.
_promote_auto_gitlab() {
  local url="$1" tip="$2" iid project mm so out
  _promote_auto_state "$url"
  _promote_auto_known "$url" "$tip" || return 0
  iid=$(_jig_ship_glab_mr "$url")
  project=$(jig_net glab api "projects/:id" 2>/dev/null | tr -d ' \n') || project=""
  if [ -z "$project" ]; then
    _promote_not_on "could not read the project's merge settings"
    return 0
  fi
  case "$project" in
    *'"only_allow_merge_if_pipeline_succeeds":true'*) ;;
    *)
      _promote_not_on "the project does not require a successful pipeline to merge, so auto-merge would merge at once"
      return 0 ;;
  esac
  # A skipped pipeline counts as a success there: nothing would be checked.
  case "$project" in
    *'"allow_merge_on_skipped_pipeline":false'*) ;;
    *)
      _promote_not_on "the project lets a skipped pipeline count as a success, so auto-merge could merge with nothing checked"
      return 0 ;;
  esac
  mm=$(printf '%s' "$project" | sed -n 's/.*"merge_method":"\([^"]*\)".*/\1/p')
  so=$(printf '%s' "$project" | sed -n 's/.*"squash_option":"\([^"]*\)".*/\1/p')
  case "$mm:$so" in
    merge:never | merge:default_off) ;;
    *)
      _promote_not_on "the repository does not allow merge commits, and a promotion keeps its ancestry only with one"
      return 0 ;;
  esac
  _jig_ship_outward "task promote"
  if ! out=$(jig_net glab mr merge "$iid" --auto-merge --sha "$tip" --yes 2>&1); then
    _promote_not_on "the forge refused: $(_jig_ship_first_line "$out")"
    return 0
  fi
  _promote_auto_settled "$url" "the target branch"
}

# _promote_auto_off <url> <why> — switch auto-merge off on the pull request
# at <url> when the forge says it is on, and say so. A failure is a warning:
# the person is told to switch it off by hand.
_promote_auto_off() {
  local url="$1" why="$2" iid out rc=0
  _promote_kind_once
  _promote_auto_state "$url"
  [ "$_PROMOTE_PR_STATE" = open ] && [ "$_PROMOTE_PR_AUTO" = on ] || return 0
  case "$(_promote_kind)" in
    github) out=$(jig_net jig_gh pr merge "$url" --disable-auto 2>&1) || rc=$? ;;
    gitlab)
      iid=$(_jig_ship_glab_mr "$url")
      out=$(jig_net glab api -X POST "projects/:id/merge_requests/$iid/cancel_merge_when_pipeline_succeeds" 2>&1) || rc=$? ;;
    *) return 0 ;;
  esac
  if [ "$rc" -ne 0 ]; then
    jig_warn "task promote: could not switch auto-merge off on $url ($why): $(_jig_ship_first_line "$out"); switch it off by hand"
    return 0
  fi
  _PROMOTE_SWITCHED_OFF=$url
  printf 'auto-merge switched off on %s: %s\n' "$url" "$why"
}

# _promote_make_draft <url> — turn the open pull request at <url> into a
# draft when it is not one: a major release found on a promotion opened before.
_promote_make_draft() {
  local url="$1" iid out rc=0
  _promote_kind_once
  _promote_auto_state "$url"
  [ "$_PROMOTE_PR_STATE" = open ] && [ "$_PROMOTE_PR_DRAFT" != true ] || return 0
  _jig_ship_outward "task promote"
  case "$(_promote_kind)" in
    github) out=$(jig_net jig_gh pr ready "$url" --undo 2>&1) || rc=$? ;;
    gitlab)
      iid=$(_jig_ship_glab_mr "$url")
      out=$(jig_net glab mr update "$iid" --draft 2>&1) || rc=$? ;;
    *) return 0 ;;
  esac
  if [ "$rc" -ne 0 ]; then
    jig_warn "task promote: could not make $url a draft: $(_jig_ship_first_line "$out"); a major release needs a human"
    return 0
  fi
  printf 'task promote: %s is now a draft: a major release needs a human\n' "$url"
}

# _promote_task <id> <commit> <title> <body-file> — the per-task step of a run
# over several tasks: _promote_one in a subshell of its own, so that a
# refusal, which exits, ends this task alone. Returns what the task came to:
# 0 open or in the base already, 1 refused, 3 a person is needed. The explicit
# `exit` runs the subshell's own exit cleanup (jig_cleanup_add), which a
# subshell running off its end may skip in bash 3.2.
_promote_task() {
  local rc=0
  (
    _prc=0
    _promote_one "$@" || _prc=$?
    # The state this subshell wrote (promote_url) reaches the status page
    # here: the parent never sees the subshell's dirty flag.
    jig_status_page_flush
    exit "$_prc"
  ) || rc=$?
  return "$rc"
}

# _promote_branch_ids <who> <tested-commit> <base-sha> — the ids of `--all`
# into _PROMOTE_IDS (called directly, never in `$()`, so that its refusal
# ends the run):
# every branch on origin that git.branch_template names a task branch (the id
# in place of `{id}`, a valid task id; a template with nothing before `{id}`
# is refused), whose tip the tested commit contains and the base does not. One per line, in origin's order. Read from the
# branch names alone, so a CI runner with no workspace has them too.
_promote_branch_ids() {
  local who="$1" csha="$2" base_sha="$3" template pre suf heads sha ref name id own untested raw
  _PROMOTE_IDS=""
  template=$(cfg git.branch_template "task/{id}")
  case "$template" in
    *'{id}'*) pre=${template%%'{id}'*} suf=${template#*'{id}'} ;;
    *) pre="task/" suf="" ;;
  esac
  # As jig_branch_is_jigs: with nothing before {id}, every branch whose name
  # is a valid id would be a task's, the staging branch included.
  [ -n "$pre" ] || _promote_refuse usage "$who: --all cannot tell a task branch by git.branch_template $template, which has nothing before {id}; name the tasks instead"
  heads=$(jig_net jig_git_origin ls-remote --heads origin 2>&1) \
    || _promote_refuse failed "$who: could not list the branches on origin, so --all cannot tell which tasks the tested commit holds.
$heads"
  while IFS=$'\t' read -r sha ref; do
    case "$ref" in refs/heads/*) ;; *) continue ;; esac
    name=${ref#refs/heads/}
    case "$name" in "$pre"*"$suf") ;; *) continue ;; esac
    id=${name#"$pre"}
    id=${id%"$suf"}
    [ -n "$id" ] || continue
    jig_valid_id "$id" || continue
    # A tip this clone does not have is no commit of the tested one.
    git -C "$JIG_PROJECT" cat-file -e "$sha^{commit}" 2>/dev/null || continue
    if git -C "$JIG_PROJECT" merge-base --is-ancestor "$sha" "$base_sha" 2>/dev/null; then
      continue
    fi
    if ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$sha" "$csha" 2>/dev/null; then
      # Tested once, then given commits the test never saw — a fix pushed
      # onto it, perhaps onto an open promotion: said, never promoted, and
      # not a failure of the run, or every untested fix would turn a pipeline
      # red. A branch with nothing in the tested commit stays unmentioned.
      # A merge of the base on the branch's first-parent line — a conflict
      # with the base resolved after the test — is not untested work, as the
      # promotion of one task judges it (_promote_one, step 8): such a branch
      # is promoted, and _promote_one judges the rest.
      # Whether it is mentioned is read from the raw counts, as before: a
      # branch with nothing in the tested commit stays silent, a merge of the
      # base included.
      own=$(git -C "$JIG_PROJECT" rev-list --count "$sha" "^$base_sha" 2>/dev/null) || own=0
      untested=$(_promote_untested_count "$sha" "$base_sha" "$csha") || untested=$own
      if [ "$untested" -gt 0 ]; then
        raw=$(git -C "$JIG_PROJECT" rev-list --count "$sha" "^$base_sha" "^$csha" 2>/dev/null) || raw=$own
        if [ "$raw" -lt "$own" ]; then
          printf '%s: skipped %s: it has commits the tested commit %s does not have; promote it after they are tested\n' \
            "$who" "$id" "$(git -C "$JIG_PROJECT" rev-parse --short "$csha")"
        fi
        continue
      fi
    fi
    _PROMOTE_IDS="$_PROMOTE_IDS$id"$'\n'
  done <<HEADS
$heads
HEADS
  return 0
}

# _promote_untested_count <tip> <base-sha> <tested> — how many commits <tip>
# has that neither the base nor the tested commit has, a merge of the base on
# <tip>'s first-parent line not counted: every parent of it but the first is
# in the base. Non-zero when git cannot list them.
_promote_untested_count() {
  local tip="$1" base_sha="$2" csha="$3" notin fpl n=0 c p fbase
  notin=$(git -C "$JIG_PROJECT" rev-list "$tip" "^$base_sha" "^$csha" 2>/dev/null) || return 1
  fpl=$(git -C "$JIG_PROJECT" rev-list --first-parent --parents "$tip" "^$base_sha" 2>/dev/null) || return 1
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    fbase=0
    while IFS= read -r p; do
      case "$p" in "$c "*" "*) ;; *) continue ;; esac
      set -f
      # shellcheck disable=SC2086 # the commit and its parents, hexadecimal
      set -- $p
      set +f
      shift 2
      fbase=1
      for p in "$@"; do
        git -C "$JIG_PROJECT" merge-base --is-ancestor "$p" "$base_sha" 2>/dev/null || fbase=0
      done
      break
    done <<FPL
$fpl
FPL
    [ "$fbase" = 1 ] || n=$((n + 1))
  done <<NOTIN
$notin
NOTIN
  printf '%s\n' "$n"
}

# _promote_many <commit> <all> <id>... — promote several tasks, or with <all>
# = 1 every task branch the tested commit holds and the base does not
# (adr-20261111-prepare-for-prod-opens-the-promotion-from-git-alone: a run promotes the tasks it names, or all of them only when told). What would refuse every task — the flow, a shallow
# clone, a base or staging branch that cannot be fetched, a tested commit not
# on staging — refuses the run before the first task. The tested commit is
# resolved once, so every task is judged against the same one. Each task then
# runs on its own (_promote_task): a line before it, its own output, a line
# with what it came to, and a summary last. Returns 1 when any task was
# refused, else 3 when any needs a person, else 0; an interrupted task (130,
# 143) ends the run with its code.
_promote_many() {
  local commit="$1" all="$2" who="task promote" ids="" id short rc
  local promoted=0 refused=0 person=0
  shift 2
  _promote_flow "$who"
  _promote_full_history "$who"
  _promote_fetch "$who" "$_PROMOTE_BASE" "$_PROMOTE_STAGING"
  _promote_tested_commit "$who" "$commit" "$_PROMOTE_BASE" "$_PROMOTE_STAGING"
  short=$(git -C "$JIG_PROJECT" rev-parse --short "$_PROMOTE_CSHA")
  if [ "$all" = 1 ]; then
    _promote_branch_ids "$who" "$_PROMOTE_CSHA" "$_PROMOTE_BASE_SHA"
    ids=$_PROMOTE_IDS
    if [ -z "$ids" ]; then
      printf '%s: no task branch on origin is in the tested commit %s of %s and not yet in %s; nothing to promote\n' \
        "$who" "$short" "$_PROMOTE_STAGING" "$_PROMOTE_BASE"
      return 0
    fi
  else
    for id in "$@"; do
      jig_has_line "$id" "$ids" || ids="$ids$id"$'\n'
    done
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s: promoting %s\n' "$who" "$id"
    rc=0
    _promote_task "$id" "$_PROMOTE_CSHA" "" "" || rc=$?
    case "$rc" in
      0)
        promoted=$((promoted + 1))
        printf '%s: %s: promoted\n' "$who" "$id" ;;
      3)
        person=$((person + 1))
        printf '%s: %s: needs a person\n' "$who" "$id" ;;
      130 | 143) return "$rc" ;;
      *)
        refused=$((refused + 1))
        printf '%s: %s: refused\n' "$who" "$id" ;;
    esac
  done <<IDS
$ids
IDS
  printf '%s: %s promoted, %s refused, %s need a person (tested commit %s of %s)\n' \
    "$who" "$promoted" "$refused" "$person" "$short" "$_PROMOTE_STAGING"
  if [ "$refused" -gt 0 ]; then
    return 1
  elif [ "$person" -gt 0 ]; then
    return 3
  fi
  return 0
}
