# cmd_pr — somebody else's pull request, read in the person's own clone
# (adr-20261109-a-pull-request-is-read-in-a-detached-tree-of-the-clone; the
# `jig-pr-review` skill): `fetch` takes its head and base into refs of Jig's
# own and a detached worktree beside the repository, `followup` reads an
# earlier review of it back from the forge (its open threads and the head it
# reviewed), `draft` checks and keeps
# the review as it will be shown (skills/jig-pr-review/references/draft.md), `list` says what is
# fetched, and `cleanup` takes all of it back.
#
# Nothing from the pull request's head is ever run: every git call here goes
# through _pr_git, which points `core.hooksPath` at nothing — a relative hooks
# path (`.githooks`, `.husky`) would otherwise run the head's own hook on the
# checkout of the worktree. The forge is the one the URL names, never
# jig_forge_kind's: that answers for `origin`, and the pull request may live
# on another host.
# shellcheck shell=bash

PR_USAGE="usage: jig pr fetch <url> | jig pr followup <n|url> [--login <login>] | jig pr draft <n|url> [--from <file>] | jig pr comments check <n|url> | jig pr comments post <n|url> --shown <hash> | jig pr list | jig pr cleanup <n|url>"

cmd_pr() {
  local sub="${1:-}"
  if [ $# -gt 0 ]; then shift; fi
  jig_require_repo
  _pr_refuse_inside_a_review_tree
  case "$sub" in
    fetch) _pr_fetch "$@" ;;
    followup) _pr_followup "$@" ;;
    draft) _pr_draft "$@" ;;
    comments) _pr_comments "$@" ;;
    list) _pr_list "$@" ;;
    cleanup) _pr_cleanup "$@" ;;
    help | -h | --help) printf '%s\n' "$PR_USAGE" ;;
    '') jig_fail usage "pr: a subcommand is required; $PR_USAGE" ;;
    *) jig_fail usage "pr: unknown subcommand: $sub; $PR_USAGE" ;;
  esac
}

# --- git, with nothing of the head's run ------------------------------------------

# _pr_git <dir> <args>... — git in <dir> with hooks pointed at /dev/null (a file,
# so no hook can exist under it), submodules not followed and LFS objects not
# downloaded. No MSYS2_ARG_CONV_EXCL here: under Git Bash it would hand <dir>
# to git as an MSYS path (`/c/Users/...`) that git cannot change into. The
# refspecs passed here need none either: MSYS reads an argument as a path list
# only where a `:` is followed by `/`, `.` or `:`, and in `refs/a:refs/b` it is
# followed by `r`.
_pr_git() {
  local dir="$1"
  shift
  GIT_LFS_SKIP_SMUDGE=1 \
    git -C "$dir" -c core.hooksPath=/dev/null -c submodule.recurse=false "$@"
}

# _pr_refuse_inside_a_review_tree — jig pr runs in the person's own checkout,
# never in a review tree: there the head's hooks path, `.ai/config.yaml` and
# `.ai/scripts` are the author's. A checkout named `.pr-<n>` that is not the
# clone's main checkout is taken for one.
_pr_refuse_inside_a_review_tree() {
  local clone
  case "$(basename "$JIG_PROJECT")" in
    .pr-[0-9]*) ;;
    *) return 0 ;;
  esac
  clone=$(jig_config_clone_root)
  if [ "$clone" != "$JIG_PROJECT" ]; then
    jig_die "pr: $JIG_PROJECT is a pull request's review tree; run jig pr in your own checkout ($clone)"
  fi
}

# --- names --------------------------------------------------------------------------

# _pr_parse_url <url> — sets _PR_FORGE (github or gitlab), _PR_FORGE_NAME,
# _PR_HOST, _PR_OWNER, _PR_REPO, _PR_N and _PR_URL (the canonical form) from
# https://<host>/<owner>/<repo>/pull/<n> or a GitLab merge request,
# https://<host>/<group>[/<subgroup>…]/<project>/-/merge_requests/<iid>, with any
# trailing path (`/files`, `/diffs`), query or fragment dropped. For GitLab
# _PR_OWNER is the whole namespace, so "$_PR_OWNER/$_PR_REPO" is the project's
# full path. Exit 1 for anything else.
_PR_FORGE="" _PR_FORGE_NAME="" _PR_HOST="" _PR_OWNER="" _PR_REPO="" _PR_N="" _PR_URL=""
_pr_parse_url() {
  local rest host path owner repo kind n
  case "$1" in
    https://*) rest=${1#https://} ;;
    http://*) rest=${1#http://} ;;
    *) return 1 ;;
  esac
  rest=${rest%%#*}
  rest=${rest%%\?*}
  host=${rest%%/*}
  [ "$host" != "$rest" ] || return 1
  case "$host" in '' | *[!A-Za-z0-9.:-]*) return 1 ;; esac
  path=${rest#*/}
  case "$path" in
    */-/merge_requests/*)
      _pr_parse_gitlab "$host" "$path"
      return
      ;;
  esac
  owner=${path%%/*}
  path=${path#*/}
  repo=${path%%/*}
  path=${path#*/}
  kind=${path%%/*}
  path=${path#*/}
  n=${path%%/*}
  [ "$kind" = pull ] || return 1
  _pr_valid_slug_part "$owner" || return 1
  _pr_valid_slug_part "$repo" || return 1
  _pr_valid_number "$n" || return 1
  _PR_FORGE=github _PR_FORGE_NAME=GitHub
  _PR_HOST=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  _PR_OWNER="$owner"
  _PR_REPO="$repo"
  _PR_N="$n"
  _PR_URL="https://$_PR_HOST/$owner/$repo/pull/$n"
}

# _pr_parse_gitlab <host> <path after the host> — the GitLab half of
# _pr_parse_url: a project path of two or more segments, each in GitLab's
# characters and never `.` or `..`, then `/-/merge_requests/<iid>`.
_pr_parse_gitlab() {
  local host="$1" proj rest n seg
  proj=${2%%/-/merge_requests/*}
  rest=${2#*/-/merge_requests/}
  n=${rest%%/*}
  _pr_valid_number "$n" || return 1
  case "$proj" in */*) ;; *) return 1 ;; esac
  rest="$proj/"
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    rest=${rest#*/}
    _pr_valid_slug_part "$seg" || return 1
  done
  _PR_FORGE=gitlab _PR_FORGE_NAME=GitLab
  _PR_HOST=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  _PR_OWNER=${proj%/*}
  _PR_REPO=${proj##*/}
  _PR_N="$n"
  _PR_URL="https://$_PR_HOST/$proj/-/merge_requests/$n"
}

# An owner, repository or GitLab path segment: [A-Za-z0-9._-], and never `.`
# or `..`.
_pr_valid_slug_part() {
  case "$1" in
    '' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# A pull request number becomes part of a path and a ref name: digits only, no
# leading zero, at most nine of them.
_pr_valid_number() {
  case "$1" in
    '' | 0* | *[!0-9]* | ??????????*) return 1 ;;
    *) return 0 ;;
  esac
}

# _pr_resolve <who> <n|url> — sets _PR_N from a number or a pull request URL.
# A URL must be the one recorded for that number, when one is.
_pr_resolve() {
  local who="$1" arg="$2" rc=0 rec recorded
  if _pr_valid_number "$arg"; then
    _PR_N="$arg"
    return 0
  fi
  _pr_parse_url "$arg" || rc=$?
  [ "$rc" = 0 ] || jig_fail usage "pr $who: not a pull request number or URL: $arg"
  rec="$(_pr_state_dir "$_PR_N")/record"
  if [ -f "$rec" ]; then
    recorded=$(_pr_record_get "$rec" url)
    [ "$recorded" = "$_PR_URL" ] \
      || jig_die "pr $who: pull request $_PR_N of this clone is $recorded, not $_PR_URL"
  fi
}

# --- where things live ----------------------------------------------------------------

# The clone's git directory, physical: worktrees share it.
_pr_common_dir() {
  local d
  d=$(_pr_git "$JIG_PROJECT" rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd "$JIG_PROJECT" && cd "$d" && pwd -P)
}

# _pr_state_dir <n> — where pull request <n>'s record and draft are kept: the
# clone's own .ai/workspace/pr/<n>/ when Jig is installed there and git ignores
# that path; otherwise <git-common-dir>/jig/pr/<n>/, inside the clone but out
# of its working tree, so nothing is left in somebody else's tree. <n> is
# checked here, the one function that builds the path.
_pr_state_dir() {
  local n="$1" clone common
  _pr_valid_number "$n" || jig_die "pr: not a pull request number: $n"
  clone=$(jig_config_clone_root)
  if [ -f "$clone/$JIG_AI_DIR/config.yaml" ] \
     && _pr_git "$clone" check-ignore -q "$JIG_AI_DIR/workspace/pr/$n/record" 2>/dev/null; then
    printf '%s/%s/workspace/pr/%s\n' "$clone" "$JIG_AI_DIR" "$n"
  else
    common=$(_pr_common_dir) || common=""
    [ -n "$common" ] || jig_die "pr: cannot find this clone's git directory"
    printf '%s/jig/pr/%s\n' "$common" "$n"
  fi
}

# _pr_worktree_path <n> — <git.worktree_root>/.pr-<n>, beside the repository.
# The setting means what it means for `task start --worktree`
# (_task_worktree_root, task.sh), but a relative root is joined to the clone's
# main checkout rather than to the checkout jig runs in, so that every checkout
# of the clone finds the same tree; the leading dot keeps the name out
# of jig_valid_id's grammar, so no task's worktree can ever be made there.
_pr_worktree_path() {
  local n="$1" clone root
  _pr_valid_number "$n" || jig_die "pr: not a pull request number: $n"
  clone=$(jig_config_clone_root)
  root=$(cfg git.worktree_root "")
  [ -n "$root" ] || root="../$(basename "$clone").worktrees"
  case "$root" in
    /*) printf '%s/.pr-%s\n' "$root" "$n" ;;
    *) printf '%s/%s/.pr-%s\n' "$clone" "$root" "$n" ;;
  esac
}

# _pr_physical <path> — <path> with every link resolved, or nothing when it
# does not exist.
_pr_physical() {
  (cd -P "$1" 2>/dev/null && pwd -P) || true
}

# _pr_worktree_kind <path> — what git says stands at <path>: `detached`,
# `locked` (a detached worktree somebody locked), `branch` (a worktree with a
# branch checked out: never ours), or `none`. Compared physically, so git's
# spelling of the path (C:/… under Git Bash) does not matter.
_pr_worktree_kind() {
  local want p="" line kind="" locked=0 found=0
  want=$(_pr_physical "$1")
  [ -n "$want" ] || { printf 'none\n'; return 0; }
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        if [ "$found" = 1 ]; then break; fi
        p=$(_pr_physical "${line#worktree }")
        if [ "$p" = "$want" ]; then found=1; fi
        ;;
      detached) if [ "$found" = 1 ]; then kind=detached; fi ;;
      "branch "*) if [ "$found" = 1 ]; then kind=branch; fi ;;
      locked | "locked "*) if [ "$found" = 1 ]; then locked=1; fi ;;
    esac
  done < <(_pr_git "$JIG_PROJECT" worktree list --porcelain 2>/dev/null)
  if [ "$found" != 1 ]; then
    printf 'none\n'
  elif [ "$kind" = detached ] && [ "$locked" = 1 ]; then
    printf 'locked\n'
  else
    printf '%s\n' "${kind:-branch}"
  fi
}

# --- the record -------------------------------------------------------------------------

# _pr_record_get <file> <key> — the value of the first `<key>: ` line.
_pr_record_get() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$2: "*) printf '%s\n' "${line#"$2: "}"; return 0 ;;
    esac
  done < "$1"
  return 0
}

# _pr_write <file> <content> — atomically, through a temporary beside it.
_pr_write() {
  local tmp="$1.tmp.$$"
  jig_cleanup_add "$tmp"
  printf '%s' "$2" > "$tmp"
  mv -f "$tmp" "$1"
}

# --- the remote and the forge ------------------------------------------------------------

# _pr_remote_names <remote-url> <host> <owner/repo> — exit 0 when <remote-url>
# reaches <owner/repo> on <host>: https, ssh:// or scp form, `.git` or not,
# owner and repository without regard to case, and an SSH alias resolved to the
# host it stands for (_jig_ssh_alias_hostname, common.sh).
_pr_remote_names() {
  local url="$1" host="$2" slug="$3" h path alias
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
  path=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
  [ "$path" = "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" ] || return 1
  h=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')
  if [ "$h" = "${host%%:*}" ]; then return 0; fi
  alias=$(_jig_ssh_alias_hostname "$url")
  if [ -n "$alias" ] && [ "$(printf '%s' "$alias" | tr '[:upper:]' '[:lower:]')" = "${host%%:*}" ]; then
    return 0
  fi
  return 1
}

# _pr_remote_for <host> <owner/repo> — the name of the first remote of this
# clone that reaches the pull request's repository, as configured (the raw
# `remote.<name>.url`, before any insteadOf).
_pr_remote_for() {
  local name url
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    url=$(_pr_git "$JIG_PROJECT" config --get "remote.$name.url" 2>/dev/null) || continue
    if _pr_remote_names "$url" "$1" "$2"; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(_pr_git "$JIG_PROJECT" remote 2>/dev/null)
  return 1
}

# --- accounts and tokens ------------------------------------------------------------------

# What _pr_propose_login found, and the token the next _pr_gh call uses.
_PR_TOKEN="" _PR_ACCOUNTS="" _PR_ACTIVE="" _PR_TOKEN_ENV="" _PR_LOGIN="" _PR_WHY=""

# _pr_gh <args>... — `gh api --hostname <_PR_HOST> <args>`. With _PR_TOKEN set,
# that token is the one gh uses, for this call only: in a subshell every token
# variable is unset and the host's own (GH_TOKEN for github.com and *.ghe.com,
# GH_ENTERPRISE_TOKEN for a GitHub Enterprise Server) set to it. A token is never an
# argument, where ps would show it, and never written down; the active account
# and gh's configuration stay as they are. API paths are given without a
# leading `/` and no filter holds one: gh is a native program under Git Bash,
# and MSYS would take either for a path to convert.
_pr_gh() {
  (
    if [ -n "$_PR_TOKEN" ]; then
      unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
      # shellcheck disable=SC2030 # set in the subshell on purpose: for this call only
      if jig_gh_dotcom_kind "$_PR_HOST"; then
        GH_TOKEN="$_PR_TOKEN"
        export GH_TOKEN
      else
        # shellcheck disable=SC2030 # as above
        GH_ENTERPRISE_TOKEN="$_PR_TOKEN"
        export GH_ENTERPRISE_TOKEN
      fi
    fi
    jig_net gh api --hostname "$_PR_HOST" "$@"
  )
}

# _pr_stored_token <login> — the token gh keeps for <login> on _PR_HOST
# (jig_gh_stored_token, common.sh).
_pr_stored_token() { jig_gh_stored_token "$_PR_HOST" "$1"; }

# _pr_env_token — the token gh would take from the environment for _PR_HOST.
# shellcheck disable=SC2031 # the environment's own, never _pr_gh's
_pr_env_token() {
  if jig_gh_dotcom_kind "$_PR_HOST"; then
    printf '%s\n' "${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  else
    printf '%s\n' "${GH_ENTERPRISE_TOKEN:-${GITHUB_ENTERPRISE_TOKEN:-}}"
  fi
}

# _pr_access <owner/repo> — what the account of _PR_TOKEN may do there:
# `comment` as a member (push, triage, maintain or admin, or read on a private
# repository), `read` when it only reads (on a public repository every account
# does), `none` when GitHub shows it nothing.
_pr_access() {
  local out priv pull push triage maintain admin
  out=$(_pr_gh "repos/$1" \
    --jq '[.private, .permissions.pull, .permissions.push, .permissions.triage, .permissions.maintain, .permissions.admin] | map(tostring) | join(" ")' \
    2>/dev/null) || out=""
  out=$(printf '%s' "$out" | tr -d '\r')
  read -r priv pull push triage maintain admin <<EOF
$out
EOF
  if [ "$push" = true ] || [ "$triage" = true ] || [ "$maintain" = true ] || [ "$admin" = true ]; then
    printf 'comment\n'
  elif [ "$pull" = true ] && [ "$priv" = true ]; then
    printf 'comment\n'
  elif [ "$pull" = true ]; then
    printf 'read\n'
  else
    printf 'none\n'
  fi
}

# _pr_propose_login <owner/repo> — sets _PR_ACCOUNTS, _PR_ACTIVE, _PR_TOKEN_ENV,
# and the login to propose: _PR_LOGIN is the one account that may comment as a
# member, or `ask` with _PR_WHY saying why not (none, several, a token in the
# environment, a gh that gives no token per account). Leaves in _PR_TOKEN the
# first account that can read the repository, for the reads that follow; none
# leaves gh to its own choice.
_pr_propose_login() {
  local slug="$1" a t acc commenters="" reader="" n=0 tokens=0 tab
  tab=$(printf '\t')
  IFS="$tab" read -r _PR_ACCOUNTS _PR_ACTIVE <<EOF
$(jig_gh_accounts "$_PR_HOST")
EOF
  _PR_TOKEN_ENV=$(jig_gh_token_env "$_PR_HOST")
  _PR_LOGIN=ask _PR_WHY="" _PR_TOKEN=""
  if [ -n "$_PR_TOKEN_ENV" ]; then
    _PR_WHY="$_PR_TOKEN_ENV in the environment overrides every gh account"
    return 0
  fi
  if [ -z "$_PR_ACCOUNTS" ]; then
    _PR_WHY="gh holds no account for $_PR_HOST"
    return 0
  fi
  set -f
  for a in $_PR_ACCOUNTS; do
    t=$(_pr_stored_token "$a") || continue
    tokens=$((tokens + 1))
    _PR_TOKEN="$t"
    acc=$(_pr_access "$slug")
    case "$acc" in
      comment)
        commenters="$commenters${commenters:+ }$a"
        n=$((n + 1))
        if [ -z "$reader" ]; then reader="$t"; fi
        ;;
      read) if [ -z "$reader" ]; then reader="$t"; fi ;;
    esac
  done
  set +f
  _PR_TOKEN="$reader"
  if [ "$tokens" = 0 ]; then
    _PR_WHY="gh gives no token per account (gh auth token --user needs gh 2.40 or later); accounts: $_PR_ACCOUNTS"
  elif [ "$n" = 1 ]; then
    _PR_LOGIN="$commenters"
  elif [ "$n" = 0 ]; then
    _PR_WHY="no account may comment on $slug as a member; accounts: $_PR_ACCOUNTS"
  else
    _PR_WHY="several accounts may comment: $commenters; active: ${_PR_ACTIVE:-none}"
  fi
}

# _pr_pull_info <owner/repo> — `<base ref>\t<head sha>\t<state>\t<base sha>\t<locked>\t<changed files>`
# of pull request _PR_N, read with _PR_TOKEN.
_pr_pull_info() {
  local out
  out=$(_pr_gh "repos/$1/pulls/$_PR_N" \
    --jq '[.base.ref, .head.sha, .state, .base.sha, (.locked | tostring), (.changed_files | tostring)] | @tsv' \
    2>/dev/null) || return 1
  printf '%s\n' "$out" | tr -d '\r'
}

# _pr_gh_as <who> <login> — the token gh keeps for <login> on _PR_HOST (or the
# environment's, when gh keeps none for it) into _PR_TOKEN, confirmed by GitHub
# naming that very login, and what it may do on _PR_SLUG into _PR_ACC; dies
# when either does not hold.
_PR_ACC=""
_pr_gh_as() {
  local who="$1" login="$2" who_am
  command -v gh >/dev/null 2>&1 || jig_die "pr $who: the GitHub CLI (gh) is needed"
  _PR_TOKEN=$(_pr_stored_token "$login") || _PR_TOKEN=$(_pr_env_token)
  [ -n "$_PR_TOKEN" ] \
    || jig_die "pr $who: gh gives no token for $login on $_PR_HOST (gh auth login --hostname $_PR_HOST; gh auth token --user needs gh 2.40 or later)"
  who_am=$(_pr_gh user --jq .login 2>/dev/null | tr -d '\r') || who_am=""
  if [ "$(printf '%s' "$who_am" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" ]; then
    jig_die "pr $who: the token for $login answers as ${who_am:-nobody}; the draft's login is the one it posts as"
  fi
  _PR_ACC=$(_pr_access "$_PR_SLUG")
  [ "$_PR_ACC" != none ] || jig_die "pr $who: $login cannot reach $_PR_SLUG on $_PR_HOST"
}

# --- GitLab ---------------------------------------------------------------------------------
#
# The GitLab half — glab, its account, the merge request, its diff, the
# read-back and the post — lives in lib/prgitlab.sh.
# shellcheck source=lib/prgitlab.sh
. "$JIG_LIB/prgitlab.sh"

# _pr_gh_refuse_a_lost_reply — the GitHub half of _pr_gl_refuse_a_lost_note
# for a follow-up's replies: a reply GitHub took for this version (an id under
# `replies:` of `posted`) that the read-back does not find with its marker is
# never posted again blindly.
_PR_GH_SEEN=""
_pr_gh_refuse_a_lost_reply() {
  local id
  [ -f "$_PR_DIR/posted" ] || return 0
  [ "$(_pr_record_get "$_PR_DIR/posted" hash)" = "$_PR_H" ] || return 0
  for id in $(_pr_record_get "$_PR_DIR/posted" replies); do
    case "$_PR_GH_SEEN" in
      *" $id "*) ;;
      *) jig_die "pr comments post: GitHub took reply $id of this version, but it does not come back with its marker; look at $_PR_URL before posting anything again — nothing was posted" ;;
    esac
  done
}

# --- fetch --------------------------------------------------------------------------------

# _pr_keep_pr_base <sha> <remote> — make GitHub's base commit of the pull
# request available here: nothing to do when the clone holds it (the base
# branch's history usually does), else fetched by its id into
# refs/jig/pr/<n>/pr-base, which pins it until cleanup. Dies when neither
# works: without it the review's diff would not be GitHub's.
_pr_keep_pr_base() {
  local sha="$1" remote="$2" ref="refs/jig/pr/$_PR_N/pr-base" opts got
  _pr_git "$JIG_PROJECT" cat-file -e "$sha^{commit}" 2>/dev/null && return 0
  opts=$(_pr_fetch_opts)
  # shellcheck disable=SC2086 # opts is a list of fixed flags
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(jig_git_batch_ssh)" \
    jig_net _pr_git "$JIG_PROJECT" fetch -q $opts "$remote" "+$sha:$ref" >/dev/null 2>&1 || true
  got=$(_pr_git "$JIG_PROJECT" rev-parse --verify --quiet "$ref^{commit}") || got=""
  [ "$got" = "$sha" ] \
    || jig_die "pr fetch: GitHub's diff of pull request $_PR_N starts below $sha, which this clone does not hold and $remote did not give; fetch it again in a moment"
}

_pr_fetch() {
  local rc=0 remote info base api_head state slug dir rec wt kind recorded head base_sha mb accounts active tok login why now t
  local head_ref extra="" pr_base="" own_mb=""
  [ $# -eq 1 ] || jig_fail usage "pr fetch: one pull request URL is required; $PR_USAGE"
  _pr_parse_url "$1" || rc=$?
  [ "$rc" = 0 ] \
    || jig_fail usage "pr fetch: not a pull request URL (https://<host>/<owner>/<repo>/pull/<n>, https://<host>/<group>/<project>/-/merge_requests/<n>): $1"
  slug="$_PR_OWNER/$_PR_REPO"
  remote=$(_pr_remote_for "$_PR_HOST" "$slug") \
    || jig_die "pr fetch: no remote of this clone reaches $slug on $_PR_HOST; run it in a local clone of that repository"

  dir=$(_pr_state_dir "$_PR_N")
  rec="$dir/record"
  if [ -f "$rec" ]; then
    recorded=$(_pr_record_get "$rec" url)
    [ "$recorded" = "$_PR_URL" ] \
      || jig_die "pr fetch: pull request $_PR_N of this clone is already $recorded; jig pr cleanup $_PR_N first"
  fi
  wt=$(_pr_worktree_path "$_PR_N")
  kind=$(_pr_worktree_kind "$wt")
  case "$kind" in
    detached) ;;
    none) [ ! -e "$wt" ] || jig_die "pr fetch: $wt is in the way and is not a worktree of this clone; move it" ;;
    *) jig_die "pr fetch: $wt is a worktree jig did not make ($kind); move it" ;;
  esac

  t=$(printf '\t')
  if [ "$_PR_FORGE" = gitlab ]; then
    command -v glab >/dev/null 2>&1 || jig_die "pr fetch: the GitLab CLI (glab) is needed to read $_PR_URL"
    _pr_gl_propose_login "$slug"
    [ -n "$_PR_GL_PID" ] \
      || jig_die "pr fetch: GitLab did not show $slug on $_PR_HOST (glab auth status --hostname $_PR_HOST)"
    _pr_gl_mr_info \
      || jig_die "pr fetch: GitLab did not answer for $_PR_URL (glab auth status --hostname $_PR_HOST)"
    base="$_PR_GL_TARGET" api_head="$_PR_GL_SHA" state="$_PR_GL_STATE"
    head_ref="refs/merge-requests/$_PR_N/head"
  else
    command -v gh >/dev/null 2>&1 || jig_die "pr fetch: the GitHub CLI (gh) is needed to read $_PR_URL"
    _pr_propose_login "$slug"
    info=$(_pr_pull_info "$slug") \
      || jig_die "pr fetch: GitHub did not answer for $_PR_URL (gh auth status --hostname $_PR_HOST)"
    IFS="$t" read -r base api_head state pr_base _ <<EOF
$info
EOF
    case "$pr_base" in
      '' | *[!0-9a-f]*) jig_die "pr fetch: GitHub named no base commit for $_PR_URL" ;;
    esac
    head_ref="refs/pull/$_PR_N/head"
  fi
  git check-ref-format --branch "$base" >/dev/null 2>&1 \
    || jig_die "pr fetch: $_PR_FORGE_NAME named no usable base branch for $_PR_URL: $base"
  case "$api_head" in
    *[!0-9a-f]* | '') jig_die "pr fetch: $_PR_FORGE_NAME named no head commit for $_PR_URL" ;;
  esac

  # Only into refs of Jig's own: the person's branches, remote-tracking refs and
  # FETCH_HEAD stay as they are.
  # --refmap= (empty) keeps git from also moving refs/remotes/<remote>/<base>,
  # which it does for a named remote whose fetch refspec covers the branch.
  local fetch_opts
  fetch_opts=$(_pr_fetch_opts)
  # shellcheck disable=SC2086 # fetch_opts is a list of fixed flags
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(jig_git_batch_ssh)" \
    jig_net _pr_git "$JIG_PROJECT" fetch -q $fetch_opts "$remote" \
      "+$head_ref:refs/jig/pr/$_PR_N/head" \
      "+refs/heads/$base:refs/jig/pr/$_PR_N/base" >/dev/null \
    || jig_die "pr fetch: could not fetch pull request $_PR_N and $base from $remote"

  head=$(_pr_git "$JIG_PROJECT" rev-parse --verify --quiet "refs/jig/pr/$_PR_N/head^{commit}") || head=""
  base_sha=$(_pr_git "$JIG_PROJECT" rev-parse --verify --quiet "refs/jig/pr/$_PR_N/base^{commit}") || base_sha=""
  if [ -z "$head" ] || [ -z "$base_sha" ]; then
    jig_die "pr fetch: the fetch left no head or base for pull request $_PR_N"
  fi
  [ "$head" = "$api_head" ] \
    || jig_die "pr fetch: pull request $_PR_N moved while it was fetched ($_PR_FORGE_NAME says $api_head, the fetch got $head); run it again"
  if [ "$_PR_FORGE" = gitlab ]; then
    # GitLab's diff, which every position is read from, starts at its own
    # base_sha: the review reads from there, not from today's merge base.
    [ "$_PR_GL_HEADSHA" = "$head" ] \
      || jig_die "pr fetch: GitLab's diff of merge request $_PR_N is of ${_PR_GL_HEADSHA:-no commit}, not of its head $head; run it again in a moment"
    mb="$_PR_GL_BASE"
    case "$mb" in
      '' | *[!0-9a-f]*) jig_die "pr fetch: GitLab named no base commit for the diff of $_PR_URL" ;;
    esac
    _pr_git "$JIG_PROJECT" merge-base --is-ancestor "$mb" "$head" 2>/dev/null \
      || jig_die "pr fetch: GitLab's diff starts at $mb, which this clone does not hold below the head; a shallow clone needs git fetch --unshallow $remote"
    extra="project_id: $_PR_GL_PID
"
  else
    # GitHub's diff — "Files changed", and what `comments check` asks the compare
    # API for — starts at the merge base of the pull request's own base commit
    # (.base.sha), not of today's tip of the base branch: a base that merged
    # part of the pull request since (a branch cut from main, into a staging
    # branch main is merged into) moves today's merge base, and GitHub's stays
    # until the author pushes. The review reads from GitHub's, as GitLab's does.
    _pr_keep_pr_base "$pr_base" "$remote"
    mb=$(_pr_git "$JIG_PROJECT" merge-base "$pr_base" "$head" 2>/dev/null) \
      || jig_die "pr fetch: GitHub's base commit $pr_base and the head of pull request $_PR_N share no commit here; a shallow clone needs git fetch --unshallow $remote"
    # What the author changed against today's base: narrower when the base
    # holds part of the pull request already. Shown beside, never positioned on.
    own_mb=$(_pr_git "$JIG_PROJECT" merge-base "$base_sha" "$head" 2>/dev/null) || own_mb=""
    extra="pr_base_sha: $pr_base
"
  fi

  if [ "$kind" = detached ]; then
    _pr_git "$wt" checkout -q --detach "$head" \
      || jig_die "pr fetch: could not move $wt to the new head $head; jig pr cleanup $_PR_N, then fetch again"
  else
    mkdir -p "$(dirname "$wt")"
    _pr_git "$JIG_PROJECT" worktree add -q --detach "$wt" "$head" >/dev/null \
      || jig_die "pr fetch: could not make the worktree $wt"
  fi
  wt=$(_pr_physical "$wt")

  accounts="$_PR_ACCOUNTS" active="$_PR_ACTIVE" tok="$_PR_TOKEN_ENV" login="$_PR_LOGIN" why="$_PR_WHY"

  mkdir -p "$dir"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _pr_write "$rec" "url: $_PR_URL
forge: $_PR_FORGE
host: $_PR_HOST
repo: $slug
${extra}number: $_PR_N
state: $state
remote: $remote
base: $base
base_sha: $base_sha
merge_base: $mb
head: $head
worktree: $wt
accounts: $accounts
active: $active
token_env: $tok
login: $login
fetched_at: $now
"
  printf 'pull request: %s (%s)\n' "$_PR_URL" "${state:-unknown}"
  printf 'remote: %s\n' "$remote"
  printf 'base: %s at %s\n' "$base" "$base_sha"
  printf 'head: %s (the reviewed head)\n' "$head"
  printf 'merge base: %s\n' "$mb"
  printf 'worktree: %s (detached; read it, run nothing in it)\n' "$wt"
  printf 'state: %s\n' "$dir"
  if [ "$login" = ask ]; then
    printf 'login: ask (%s)\n' "$why"
  else
    printf 'login: %s\n' "$login"
  fi
  printf 'diff: git -C %s diff %s %s\n' "$JIG_PROJECT" "$mb" "$head"
  if [ -n "$own_mb" ] && [ "$own_mb" != "$mb" ]; then
    printf "own change: git -C %s diff %s %s   (against today's %s, which holds part of the pull request; comments go on the diff above)\n" \
      "$JIG_PROJECT" "$own_mb" "$head" "$base"
  fi
  printf 'rules: git -C %s show %s:<path>   (the base, never the head)\n' "$JIG_PROJECT" "$base_sha"
  _pr_method_lines
}

# _pr_method_lines — where the review method and the showing rule are, in the
# framework that is running. jig-pr-review is installed per user as well as
# per project (adr-20261112-the-pr-review-skill-is-installed-per-user), so it
# cannot reach them by a relative link; these lines are how it finds them, at
# the version of the mechanics it drives. Nothing when the running jig is not
# a framework checkout (a project's copy: its skills are beside it).
_pr_method_lines() {
  local root
  root=$(cd -P "$JIG_LIB/../.." 2>/dev/null && pwd -P) || return 0
  [ -f "$root/skills/jig-review/SKILL.md" ] || return 0
  printf 'method: %s/skills/jig-review/SKILL.md   (section 2)\n' "$root"
  [ -f "$root/skills/jig-task/references/show-the-document.md" ] || return 0
  printf 'show: %s/skills/jig-task/references/show-the-document.md\n' "$root"
}

# --- draft ------------------------------------------------------------------------------------

# _pr_draft_check <draft> <record> — print the draft with CRs dropped when it
# keeps skills/jig-pr-review/references/draft.md and agrees with the record; die naming the first
# line that does not. A draft with `follows:` is a follow-up: it agrees with
# the `followup` file beside the record, answers each of its threads once, and
# comments only on lines the author added since the head reviewed last.
_pr_draft_check() {
  local file="$1" rec="$2" line no=0 phase=head key val have="" seen_summary=0 blocks=0 body=0 kind pos path side a b sha out=""
  local url head accounts tok mb entry tab fu follows="" fu_follows="" fu_login="" fu_reviewed="" nthreads=0 replied=" " k dlogin=""
  local levels=0 nlevels=0 lvl prefix title=0
  kind=""
  tab=$(printf '\t')
  url=$(_pr_record_get "$rec" url)
  head=$(_pr_record_get "$rec" head)
  mb=$(_pr_record_get "$rec" merge_base)
  accounts=$(_pr_record_get "$rec" accounts)
  tok=$(_pr_record_get "$rec" token_env)
  fu="${rec%/record}/followup"
  if [ -f "$fu" ]; then
    fu_follows=$(_pr_record_get "$fu" follows)
    fu_login=$(_pr_record_get "$fu" login)
    fu_reviewed=$(_pr_record_get "$fu" reviewed)
    if [ "$(_pr_record_get "$fu" head)" != "$head" ]; then fu_follows="" fu_login=""; fi
    nthreads=$(_pr_record_get "$fu" threads)
    case "$nthreads" in '' | *[!0-9]*) nthreads=0 ;; esac
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    no=$((no + 1))
    line=${line%"$(printf '\r')"}
    out="$out$line
"
    if [ "$no" = 1 ]; then
      [ "$line" = "jig-pr-draft: 1" ] || jig_die "pr draft: line 1 must be 'jig-pr-draft: 1'"
      continue
    fi
    if [ "$phase" = head ]; then
      if [ -z "$line" ]; then
        phase=gap
        continue
      fi
      key=${line%%: *}
      val=${line#*: }
      [ "$key" != "$line" ] || jig_die "pr draft: line $no: a header line is '<key>: <value>'"
      case " $have " in *" $key "*) jig_die "pr draft: line $no: $key is given twice" ;; esac
      have="$have $key"
      case "$key" in
        url) [ "$val" = "$url" ] || jig_die "pr draft: line $no: url is $val, but the fetched pull request is $url" ;;
        head) [ "$val" = "$head" ] || jig_die "pr draft: line $no: head is $val, but the reviewed head is $head; review what changed, or fetch again" ;;
        follows)
          [ -n "$fu_follows" ] || jig_die "pr draft: line $no: a follow-up needs jig pr followup of the reviewed head first"
          [ "$val" = "$fu_follows" ] || jig_die "pr draft: line $no: follows is $val, but jig pr followup found $fu_follows; run it again, or follow that head"
          follows="$val"
          ;;
        login)
          [ -n "$val" ] && [ "$val" != ask ] || jig_die "pr draft: line $no: login names no account"
          dlogin="$val"
          case " $accounts " in
            *" $val "*) ;;
            *)
            if [ -z "$tok" ] && [ "$val" != "$fu_login" ]; then
              jig_die "pr draft: line $no: gh holds no account $val for this host (accounts: ${accounts:-none})"
            fi
            ;;
          esac
          ;;
        language) [ -n "$val" ] || jig_die "pr draft: line $no: language is empty" ;;
        *) jig_die "pr draft: line $no: unknown header key: $key" ;;
      esac
      continue
    fi
    case "$line" in
      "=== "*)
        if [ "$blocks" -gt 0 ] && [ "$body" = 0 ]; then
          jig_die "pr draft: line $no: the block before it is empty"
        fi
        if [ "$kind" = levels ] && [ "$nlevels" != 4 ]; then
          jig_die "pr draft: line $no: '=== levels' names P0, P1, P2 and P3, one a line"
        fi
        blocks=$((blocks + 1))
        body=0
        set -f
        # shellcheck disable=SC2086 # split the header words on purpose
        set -- ${line#=== }
        set +f
        kind="${1:-}"
        case "$kind" in
          summary)
            [ $# -eq 1 ] || jig_die "pr draft: line $no: '=== summary' takes nothing after it"
            [ "$seen_summary" = 0 ] || jig_die "pr draft: line $no: a second summary"
            [ "$blocks" = 1 ] || jig_die "pr draft: line $no: the summary comes first"
            seen_summary=1
            ;;
          levels)
            [ $# -eq 1 ] || jig_die "pr draft: line $no: '=== levels' takes nothing after it"
            [ "$seen_summary" = 1 ] && [ "$blocks" = 2 ] || jig_die "pr draft: line $no: '=== levels' comes right after the summary"
            levels=1
            ;;
          reply)
            [ "$seen_summary" = 1 ] || jig_die "pr draft: line $no: the summary comes first"
            [ -n "$follows" ] || jig_die "pr draft: line $no: a reply answers a thread of a follow-up; the header has no follows"
            [ $# -eq 3 ] || jig_die "pr draft: line $no: '=== reply <thread> fixed|open'"
            case "$3" in fixed | open) ;; *) jig_die "pr draft: line $no: a reply is fixed or open: $3" ;; esac
            k="$2"
            if ! _pr_valid_number "$k" || [ "$k" -gt "$nthreads" ]; then
              jig_die "pr draft: line $no: jig pr followup lists no thread $k (threads: $nthreads)"
            fi
            case "$replied" in *" $k "*) jig_die "pr draft: line $no: thread $k is answered twice" ;; esac
            replied="$replied$k "
            ;;
          comment | personal)
            [ "$seen_summary" = 1 ] || jig_die "pr draft: line $no: the summary comes first"
            prefix="=== $kind "
            lvl=""
            case "${2:-}" in
              P[0-3]) lvl="$2" ;;
              P[0-9]*) jig_die "pr draft: line $no: a level is P0, P1, P2 or P3: $2" ;;
            esac
            if [ -n "$lvl" ]; then
              [ "$levels" = 1 ] || jig_die "pr draft: line $no: level $lvl needs a '=== levels' block right after the summary"
              prefix="$prefix$lvl "
              title=1
              shift 2
              set -- "$kind" "$@"
            elif [ "$levels" = 1 ]; then
              jig_die "pr draft: line $no: the draft has '=== levels', so every $kind names its level: '=== $kind P<0-3> <position> <path>'"
            fi
            [ $# -ge 3 ] || jig_die "pr draft: line $no: '=== $kind [P<0-3>] <R|L><line>[-<end>] <path>'"
            pos="$2"
            path=${line#"$prefix$pos "}
            side=${pos%"${pos#?}"}
            a=${pos#?}
            case "$a" in
              *-*) b=${a#*-}; a=${a%%-*} ;;
              *) b="" ;;
            esac
            if [ "$side" != R ] && [ "$side" != L ]; then
              jig_die "pr draft: line $no: a position is R<line> or L<line>, with -<end> for a range: $pos"
            fi
            if ! _pr_valid_number "$a" || { [ -n "$b" ] && ! _pr_valid_number "$b"; }; then
              jig_die "pr draft: line $no: a position is R<line> or L<line>, with -<end> for a range: $pos"
            fi
            if [ -n "$b" ] && [ "$b" -le "$a" ]; then
              jig_die "pr draft: line $no: a range ends after it starts: $pos"
            fi
            case "/$path/" in
              *"/../"* | *"/./"* | //*) jig_die "pr draft: line $no: a path is relative to the repository, without . or ..: $path" ;;
            esac
            if [ "$side" = R ]; then sha="$head"; else sha="$mb"; fi
            entry=$(_pr_git "$JIG_PROJECT" -c core.quotepath=false ls-tree "$sha" -- "$path" 2>/dev/null) || entry=""
            case "$entry" in
              *" blob "*"$tab$path") entry=ok ;;
            esac
            if [ "$entry" != ok ]; then
              if [ "$side" = R ]; then
                jig_die "pr draft: line $no: $path is not a file of the reviewed head"
              else
                jig_die "pr draft: line $no: $path is not a file of the merge base (L is the old side)"
              fi
            fi
            # A follow-up's new findings come only from what the author
            # changed since the head reviewed last.
            if [ "$kind" = comment ] && [ -n "$follows" ] && [ "$fu_reviewed" != unreachable ]; then
              [ "$side" = R ] || jig_die "pr draft: line $no: a follow-up comments only on lines added since $follows (R lines): $pos"
              _pr_in_interdiff "$follows" "$mb" "$head" "$path" "$a" "${b:-$a}" \
                || jig_die "pr draft: line $no: $pos $path is not on a line the author added since $follows; a follow-up comments only on what changed"
            fi
            ;;
          *) jig_die "pr draft: line $no: unknown block: === $kind" ;;
        esac
        ;;
      *)
        if [ "$blocks" = 0 ]; then
          [ -z "$line" ] || jig_die "pr draft: line $no: text before the first '=== ' block"
        elif [ "$title" = 1 ]; then
          # The first line of a comment with a level is its title: jig puts the
          # number before it and lists it in the summary, so it is plain text.
          case "$line" in
            '' | '```'* | '~~~'* | '#'* | '>'* | '---'* | '|'* | '<'* | ' '* | "$tab"*)
              jig_die "pr draft: line $no: a comment with a level starts with a one-line title in plain text"
              ;;
          esac
          title=0
          body=1
        elif [ -n "$line" ]; then
          body=1
          if [ "$kind" = levels ]; then
            case "$line" in
              "P$nlevels "[!\ ]*) nlevels=$((nlevels + 1)) ;;
              *) jig_die "pr draft: line $no: '=== levels' names P0, P1, P2 and P3 in order, one a line: 'P<n> <word>[ — <meaning>]'" ;;
            esac
          fi
        fi
        ;;
    esac
  done < "$file"
  if [ "$kind" = levels ] && [ "$nlevels" != 4 ]; then
    jig_die "pr draft: '=== levels' names P0, P1, P2 and P3, one a line"
  fi
  for key in url head login language; do
    case " $have " in *" $key "*) ;; *) jig_die "pr draft: the header has no $key" ;; esac
  done
  [ "$seen_summary" = 1 ] || jig_die "pr draft: there is no '=== summary' block"
  [ "$body" = 1 ] || jig_die "pr draft: the last block is empty"
  if [ -n "$follows" ]; then
    [ "$dlogin" = "$fu_login" ] \
      || jig_die "pr draft: the follow-up answers threads of $fu_login; the draft's login is $dlogin"
    k=1
    while [ "$k" -le "$nthreads" ]; do
      case "$replied" in *" $k "*) ;; *) jig_die "pr draft: thread $k of jig pr followup has no '=== reply $k fixed|open'" ;; esac
      k=$((k + 1))
    done
  fi
  printf '%s' "$out"
}

_pr_draft() {
  local arg="" from="" dir rec draft content
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        [ $# -ge 2 ] || jig_fail usage "pr draft: --from requires a file"
        from="$2"
        shift 2
        ;;
      -*) jig_fail usage "pr draft: unknown argument: $1; $PR_USAGE" ;;
      *)
        [ -z "$arg" ] || jig_fail usage "pr draft: one pull request at a time; $PR_USAGE"
        arg="$1"
        shift
        ;;
    esac
  done
  [ -n "$arg" ] || jig_fail usage "pr draft: a pull request number or URL is required; $PR_USAGE"
  _pr_resolve draft "$arg"
  dir=$(_pr_state_dir "$_PR_N")
  rec="$dir/record"
  [ -f "$rec" ] || jig_die "pr draft: pull request $_PR_N is not fetched here; jig pr fetch <url>"
  draft="$dir/draft.md"
  if [ -n "$from" ]; then
    [ -f "$from" ] || jig_die "pr draft: no such file: $from"
    content=$(_pr_draft_check "$from" "$rec"; printf x)
    content=${content%x}
    _pr_write "$draft" "$content"
  fi
  [ -f "$draft" ] || jig_die "pr draft: there is no draft for pull request $_PR_N yet; jig pr draft $_PR_N --from <file>"
  printf 'jig: draft: %s\n' "$draft" >&2
  cat "$draft"
}

# --- comments: check and post ---------------------------------------------------------------
#
# adr-20261109-a-review-is-posted-as-it-was-shown. `check` builds, from the kept
# draft and GitHub's own diff, the one review that would be posted — comments
# placed on lines of that diff, the rest moved into the summary, the files the
# diff does not show named there — prints it with its hash and records that
# hash as the version shown. `post` builds it again, refuses unless the hash is
# the one shown and named, and posts it as one review with the event COMMENT,
# each part carrying a hidden marker that the read-back looks for.

_pr_comments() {
  local sub="${1:-}"
  if [ $# -gt 0 ]; then shift; fi
  # shellcheck source=lib/json.sh
  . "$JIG_LIB/json.sh"
  case "$sub" in
    check) _pr_comments_check "$@" ;;
    post) _pr_comments_post "$@" ;;
    '') jig_fail usage "pr comments: check or post is required; $PR_USAGE" ;;
    *) jig_fail usage "pr comments: unknown subcommand: $sub; $PR_USAGE" ;;
  esac
}

# _pr_trim_nl <s> — <s> without its trailing newlines, into _PR_S.
_PR_S=""
_pr_trim_nl() {
  _PR_S="$1"
  while :; do
    case "$_PR_S" in
      *"$_PR_NL") _PR_S=${_PR_S%"$_PR_NL"} ;;
      *) break ;;
    esac
  done
}
_PR_NL='
'

# _pr_read_draft <file> — the kept (already checked) draft into _PR_D_LOGIN,
# _PR_D_FOLLOWS, _PR_D_SUMMARY and the block arrays _PR_D_KIND, _PR_D_POS,
# _PR_D_PATH, _PR_D_LEVEL (P0-P3, or empty) and _PR_D_BODY (for a reply: the
# thread and the verdict; for levels: its four lines).
_PR_D_LOGIN="" _PR_D_SUMMARY="" _PR_D_FOLLOWS=""
_pr_read_draft() {
  local line phase=head n=-1 rest body=""
  _PR_D_LOGIN="" _PR_D_SUMMARY="" _PR_D_FOLLOWS=""
  _PR_D_KIND=() _PR_D_POS=() _PR_D_PATH=() _PR_D_BODY=() _PR_D_LEVEL=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$phase" = head ]; then
      case "$line" in
        "login: "*) _PR_D_LOGIN=${line#login: } ;;
        "follows: "*) _PR_D_FOLLOWS=${line#follows: } ;;
        '') phase=blocks ;;
      esac
      continue
    fi
    case "$line" in
      "=== "*)
        if [ "$n" -ge 0 ]; then
          _pr_trim_nl "$body"
          _PR_D_BODY[n]="$_PR_S"
        fi
        n=$((n + 1))
        body=""
        rest=${line#=== }
        _PR_D_KIND[n]=${rest%% *}
        _PR_D_LEVEL[n]=""
        if [ "${_PR_D_KIND[n]}" = summary ] || [ "${_PR_D_KIND[n]}" = levels ]; then
          _PR_D_POS[n]="" _PR_D_PATH[n]=""
        else
          rest=${rest#* }
          case "${_PR_D_KIND[n]} $rest" in
            "comment P"[0-3]" "* | "personal P"[0-3]" "*)
              _PR_D_LEVEL[n]=${rest%% *}
              rest=${rest#* }
              ;;
          esac
          _PR_D_POS[n]=${rest%% *}
          _PR_D_PATH[n]=${rest#* }
        fi
        ;;
      *) if [ "$n" -ge 0 ]; then body="$body$line$_PR_NL"; fi ;;
    esac
  done < "$1"
  if [ "$n" -ge 0 ]; then
    _pr_trim_nl "$body"
    _PR_D_BODY[n]="$_PR_S"
  fi
  if [ "${_PR_D_KIND[0]:-}" = summary ]; then _PR_D_SUMMARY="${_PR_D_BODY[0]}"; fi
}

# _pr_hunk <header> — `@@ -<a>[,<b>] +<c>[,<d>] @@…` into _PR_HUNK as
# "<a> <b> <c> <d>"; an omitted count is 1, and a count of 0 is a side the hunk
# has no lines on (an added or a deleted file).
_PR_HUNK=""
_pr_hunk() {
  local h="$1" old new os oc ns nc v
  case "$h" in "@@ -"*) ;; *) return 1 ;; esac
  h=${h#@@ -}
  old=${h%% *}
  h=${h#* }
  case "$h" in "+"*) ;; *) return 1 ;; esac
  new=${h%% *}
  new=${new#+}
  os=${old%%,*} oc=1 ns=${new%%,*} nc=1
  case "$old" in *,*) oc=${old#*,} ;; esac
  case "$new" in *,*) nc=${new#*,} ;; esac
  for v in "$os" "$oc" "$ns" "$nc"; do
    case "$v" in '' | *[!0-9]*) return 1 ;; esac
  done
  _PR_HUNK="$os $oc $ns $nc"
}

# _pr_read_files <owner/repo> — the pull request's files as GitHub's diff has
# them, into _PR_F_NAME, _PR_F_OLD (the name before a rename), _PR_F_SHOWN (1
# when GitHub gives the file's patch or the file is only renamed, 0 when it
# gives none: a binary file, which it lists with no changes, or one past its
# size limit) and
# _PR_F_HUNKS ("<a> <b> <c> <d>;" per hunk). Only the hunk headers cross from
# gh: the filter makes lines F (status, changes, patch given), N (name),
# O (previous name) and H (a hunk header), and the parsing is the shell's.
_pr_read_files() {
  local out line i=-1 rest tab
  tab=$(printf '\t')
  _PR_F_NAME=() _PR_F_OLD=() _PR_F_SHOWN=() _PR_F_HUNKS=()
  out=$(_pr_gh --paginate "repos/$1/pulls/$_PR_N/files?per_page=100" --jq '.[] | if ((.filename + (.previous_filename | tostring)) | contains("\n")) then "X" else ("F\t" + .status + "\t" + (.changes | tostring) + "\t" + (if .patch then "1" else "0" end)), ("N\t" + .filename), (if .previous_filename then "O\t" + .previous_filename else empty end), ((.patch | tostring) | split("\n") | .[] | select(startswith("@@ ")) | "H\t" + .) end' \
    2>/dev/null) || jig_die "pr comments: GitHub did not give the files of pull request $_PR_N"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$(printf '\r')"}
    case "$line" in
      X) jig_die "pr comments: pull request $_PR_N has a file whose name holds a newline; jig cannot place comments in it" ;;
      "F$tab"*)
        i=$((i + 1))
        rest=${line#F?}
        _PR_F_SHOWN[i]=1
        case "$rest" in
          "renamed${tab}0$tab"*) ;;
          *"${tab}0") _PR_F_SHOWN[i]=0 ;;
        esac
        _PR_F_NAME[i]="" _PR_F_OLD[i]="" _PR_F_HUNKS[i]=""
        ;;
      "N$tab"*) [ "$i" -lt 0 ] || _PR_F_NAME[i]=${line#N?} ;;
      "O$tab"*) [ "$i" -lt 0 ] || _PR_F_OLD[i]=${line#O?} ;;
      "H$tab"*)
        [ "$i" -ge 0 ] || continue
        _pr_hunk "${line#H?}" || jig_die "pr comments: GitHub gave a hunk header jig cannot read: ${line#H?}"
        _PR_F_HUNKS[i]="${_PR_F_HUNKS[i]}$_PR_HUNK;"
        ;;
    esac
  done <<EOF
$out
EOF
}

# _pr_place <R|L> <start> <end> <path> — exit 0 when lines <start>..<end> of
# <path> lie inside one hunk of the forge's diff on that side, with the path the
# comment is posted under in _PR_PLACED and the file's and the hunk's index in
# _PR_PLACED_F and _PR_PLACED_H (the new name: an `L` comment on a
# renamed file is posted under the name the pull request gives it). An `L` path
# is the merge base's: a renamed file's previous name, or an unrenamed file's.
_PR_PLACED="" _PR_PLACED_F=-1 _PR_PLACED_H=-1
_pr_place() {
  local side="$1" a="$2" b="$3" path="$4" i=0 n=${#_PR_F_NAME[@]} f=-1 hs h s c j=-1
  if [ "$side" = L ]; then
    while [ "$i" -lt "$n" ]; do
      if [ "${_PR_F_OLD[i]}" = "$path" ]; then f=$i; break; fi
      i=$((i + 1))
    done
    i=0
    while [ "$f" -lt 0 ] && [ "$i" -lt "$n" ]; do
      if [ "${_PR_F_NAME[i]}" = "$path" ] && [ -z "${_PR_F_OLD[i]}" ]; then f=$i; fi
      i=$((i + 1))
    done
  else
    while [ "$i" -lt "$n" ]; do
      if [ "${_PR_F_NAME[i]}" = "$path" ]; then f=$i; break; fi
      i=$((i + 1))
    done
  fi
  [ "$f" -ge 0 ] || return 1
  hs=${_PR_F_HUNKS[f]}
  while [ -n "$hs" ]; do
    h=${hs%%;*}
    hs=${hs#*;}
    j=$((j + 1))
    set -f
    # shellcheck disable=SC2086 # four numbers
    set -- $h
    set +f
    if [ "$side" = L ]; then s=$1 c=$2; else s=$3 c=$4; fi
    if [ "$c" -gt 0 ] && [ "$a" -ge "$s" ] && [ "$b" -le $((s + c - 1)) ]; then
      _PR_PLACED=${_PR_F_NAME[f]} _PR_PLACED_F=$f _PR_PLACED_H=$j
      return 0
    fi
  done
  return 1
}

# _pr_unshown <merge base> <head> <changed files> — the files GitHub's diff does
# not show, newline-separated, into _PR_UNSHOWN: those it gives without a patch
# (binary, or past its size limit), and, when it lists fewer files than the
# pull request changes (its own ceiling), the ones the local diff of the same
# commits has and its list does not.
_PR_UNSHOWN=""
_pr_unshown() {
  local mb="$1" head="$2" changed="$3" i=0 n=${#_PR_F_NAME[@]} listed name names
  _PR_UNSHOWN=""
  listed="$_PR_NL"
  while [ "$i" -lt "$n" ]; do
    if [ "${_PR_F_SHOWN[i]}" = 0 ]; then _PR_UNSHOWN="$_PR_UNSHOWN${_PR_F_NAME[i]}$_PR_NL"; fi
    listed="$listed${_PR_F_NAME[i]}$_PR_NL"
    if [ -n "${_PR_F_OLD[i]}" ]; then listed="$listed${_PR_F_OLD[i]}$_PR_NL"; fi
    i=$((i + 1))
  done
  case "$changed" in '' | *[!0-9]*) changed=0 ;; esac
  if [ "$changed" -gt "$n" ]; then
    names=$(_pr_git "$JIG_PROJECT" -c core.quotepath=false diff --no-renames --name-only "$mb" "$head" 2>/dev/null) || names=""
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case "$listed" in *"$_PR_NL$name$_PR_NL"*) continue ;; esac
      _PR_UNSHOWN="$_PR_UNSHOWN$name$_PR_NL"
    done <<EOF
$names
EOF
  fi
}

# _pr_comments_prepare <who> <n|url> — everything a post is built from, each
# checked against the forge as the draft's login: sets _PR_DIR, _PR_SLUG,
# _PR_HEAD and the draft and file arrays; dies on the first thing that does
# not hold. A record without `forge:` is GitHub's (written before GitLab was).
_PR_DIR="" _PR_SLUG="" _PR_HEAD="" _PR_MB="" _PR_CHANGED="" _PR_DRAFT=""
_pr_comments_prepare() {
  local who="$1" arg="$2" rec info tab base api_head state base_sha locked changed acc mb
  _pr_resolve "comments $who" "$arg"
  _PR_DIR=$(_pr_state_dir "$_PR_N")
  rec="$_PR_DIR/record"
  [ -f "$rec" ] || jig_die "pr comments $who: pull request $_PR_N is not fetched here; jig pr fetch <url>"
  _PR_DRAFT="$_PR_DIR/draft.md"
  [ -f "$_PR_DRAFT" ] || jig_die "pr comments $who: there is no draft for pull request $_PR_N; jig pr draft $_PR_N --from <file>"
  # The draft again, against the record as it is now: a fetch since may have
  # moved the reviewed head.
  _pr_draft_check "$_PR_DRAFT" "$rec" >/dev/null
  _pr_read_draft "$_PR_DRAFT"
  _PR_FT_N=0
  _PR_FT_ID=() _PR_FT_DESC=()
  if [ -n "$_PR_D_FOLLOWS" ]; then _pr_fu_load; fi
  _PR_HOST=$(_pr_record_get "$rec" host)
  _PR_URL=$(_pr_record_get "$rec" url)
  _PR_SLUG=$(_pr_record_get "$rec" repo)
  _PR_HEAD=$(_pr_record_get "$rec" head)
  _PR_MB=$(_pr_record_get "$rec" merge_base)
  _PR_FORGE=$(_pr_record_get "$rec" forge)
  if [ "$_PR_FORGE" = gitlab ]; then
    _PR_FORGE_NAME=GitLab
    _pr_gl_comments_prepare "$who"
    return 0
  fi
  _PR_FORGE=github _PR_FORGE_NAME=GitHub
  _pr_gh_as "comments $who" "$_PR_D_LOGIN"
  acc="$_PR_ACC"

  tab=$(printf '\t')
  info=$(_pr_pull_info "$_PR_SLUG") || jig_die "pr comments $who: GitHub did not answer for $_PR_URL"
  IFS="$tab" read -r base api_head state base_sha locked changed <<EOF
$info
EOF
  [ "$api_head" = "$_PR_HEAD" ] \
    || jig_die "pr comments $who: pull request $_PR_N moved since it was reviewed (GitHub's head is ${api_head:-unknown}, the reviewed head $_PR_HEAD); fetch it again and review what changed — nothing was posted"
  if [ "$locked" = true ] && [ "$acc" != comment ]; then
    jig_die "pr comments $who: the conversation of pull request $_PR_N is locked, and $_PR_D_LOGIN is not a member who may still comment"
  fi
  case "$base_sha" in
    '' | *[!0-9a-f]*) jig_die "pr comments $who: GitHub named no base commit for $_PR_URL" ;;
  esac
  mb=$(_pr_gh "repos/$_PR_SLUG/compare/$base_sha...$_PR_HEAD" --jq .merge_base_commit.sha 2>/dev/null | tr -d '\r') || mb=""
  [ "$mb" = "$_PR_MB" ] \
    || jig_die "pr comments $who: GitHub's diff starts at ${mb:-an unknown commit}, the review at the merge base $_PR_MB; fetch it again — old-side lines would point elsewhere"
  _PR_CHANGED="$changed"
  _pr_read_files "$_PR_SLUG"
  _pr_unshown "$_PR_MB" "$_PR_HEAD" "$changed"
}

# _pr_levels — for a draft with `=== levels`, the marks a review carries:
# _PR_L_NUM[i] (the number of the comment at block i: by level, P0 first, then
# in the draft's order; personal blocks get none), _PR_L_MARK[0..3] (each
# level's colour) and _PR_L_INDEX (what follows the draft's summary: the
# legend and, level by level, each comment's number and first line). The words
# are the draft's, in the review's language; jig adds only colours and numbers.
_PR_L_INDEX=""
_PR_L_MARK=("🔴" "🟠" "🟡" "🟢")
_pr_levels() {
  local n=${#_PR_D_KIND[@]} i l num=0 line legend="" word title list have=0
  local -a text
  _PR_L_NUM=() _PR_L_INDEX=""
  i=1
  while [ "$i" -lt "$n" ]; do
    if [ "${_PR_D_KIND[i]}" = levels ]; then
      while IFS= read -r line; do
        case "$line" in P[0-3]" "*) text[${line:1:1}]=${line#P? } have=$((have + 1)) ;; esac
      done <<EOF
${_PR_D_BODY[i]}
EOF
    fi
    i=$((i + 1))
  done
  [ "$have" = 4 ] || return 0
  for l in 0 1 2 3; do
    legend="$legend${legend:+ · }${_PR_L_MARK[l]} ${text[l]}"
  done
  _PR_L_INDEX="$_PR_NL$_PR_NL$legend"
  for l in 0 1 2 3; do
    list=""
    i=1
    while [ "$i" -lt "$n" ]; do
      if [ "${_PR_D_KIND[i]}" = comment ] && [ "${_PR_D_LEVEL[i]}" = "P$l" ]; then
        num=$((num + 1))
        _PR_L_NUM[i]=$num
        title=${_PR_D_BODY[i]%%"$_PR_NL"*}
        list="$list$_PR_NL$num. $title"
      fi
      i=$((i + 1))
    done
    [ -n "$list" ] || continue
    word=${text[l]%% — *}
    _PR_L_INDEX="$_PR_L_INDEX$_PR_NL$_PR_NL**${_PR_L_MARK[l]} $word**$_PR_NL$list"
  done
}

# _pr_comments_build — from what _pr_comments_prepare read, the review to
# post: _PR_SHOWN (the text shown, markers included), _PR_H (its hash, taken
# over the same text without the markers, which are made from it), _PR_PAYLOAD
# (the JSON of the one review), _PR_SUMMARY_FIELDS and _PR_C_FIELDS[k],
# _PR_C_DESC[k] for k = 1.. (each part's JSON fields and its position), and
# _PR_C_LABEL[k] (how it is named in a read-back). Comments are parts
# 1.._PR_NC; a follow-up's replies follow them, up to _PR_NP, each with the
# thread it answers in _PR_R_THREAD[k] and its verdict in _PR_R_VERDICT[k].
_PR_SHOWN="" _PR_H="" _PR_PAYLOAD="" _PR_SUMMARY_FIELDS="" _PR_MOVED=0 _PR_PERSONAL=0 _PR_NC=0 _PR_NP=0
_pr_comments_build() {
  local i=1 n=${#_PR_D_KIND[@]} pos side a b path body moved="" k=0 sbody line unshown="" canon marker head replies="" r t v
  local -a cbody cside cline cstart cpath cpos
  _PR_C_FIELDS=() _PR_C_DESC=() _PR_C_WANT=() _PR_C_LABEL=() _PR_R_THREAD=() _PR_R_VERDICT=()
  _PR_MOVED=0 _PR_PERSONAL=0
  head="$_PR_HEAD"
  _pr_levels
  while [ "$i" -lt "$n" ]; do
    if [ "${_PR_D_KIND[i]}" = levels ]; then
      i=$((i + 1))
      continue
    fi
    if [ "${_PR_D_KIND[i]}" = personal ]; then
      _PR_PERSONAL=$((_PR_PERSONAL + 1))
      i=$((i + 1))
      continue
    fi
    if [ "${_PR_D_KIND[i]}" = reply ]; then
      replies="$replies $i"
      i=$((i + 1))
      continue
    fi
    pos=${_PR_D_POS[i]}
    path=${_PR_D_PATH[i]}
    body=${_PR_D_BODY[i]}
    if [ -n "${_PR_L_NUM[i]:-}" ]; then
      body="${_PR_L_MARK[${_PR_D_LEVEL[i]#P}]} **${_PR_L_NUM[i]}.** $body"
    fi
    side=${pos%"${pos#?}"}
    a=${pos#?}
    b="$a"
    case "$a" in *-*) b=${a#*-} a=${a%%-*} ;; esac
    if _pr_place "$side" "$a" "$b" "$path"; then
      k=$((k + 1))
      cpath[k]="$_PR_PLACED"
      cbody[k]="$body"
      cline[k]="$b"
      cstart[k]=""
      if [ "$b" != "$a" ]; then cstart[k]="$a"; fi
      if [ "$side" = L ]; then cside[k]=LEFT; else cside[k]=RIGHT; fi
      _PR_C_DESC[k]="$pos $_PR_PLACED"
      _PR_C_LABEL[k]="comment $pos $_PR_PLACED"
      if [ "$_PR_FORGE" = gitlab ]; then
        # GitLab takes a range only with a line code (a SHA-1 of the path),
        # which jig does not compute: a range is posted at its last line, and
        # the text shown says so.
        if [ "$b" != "$a" ]; then
          _PR_C_DESC[k]="$pos $_PR_PLACED, at $side$b"
          _PR_C_LABEL[k]="comment ${_PR_C_DESC[k]}"
        fi
        _PR_C_WANT[k]="$side$b $_PR_PLACED"
        _pr_gl_lines "$side" "$b" \
          || jig_die "pr comments: line $b of $path is in GitLab's hunk but not in its lines"
        cpos[k]=$(_pr_gl_position_json "${_PR_F_OLD[_PR_PLACED_F]:-$_PR_PLACED}" "$_PR_PLACED")
      fi
    else
      _PR_MOVED=$((_PR_MOVED + 1))
      moved="$moved$_PR_NL**$pos \`$path\`**$_PR_NL$_PR_NL$body$_PR_NL"
    fi
    i=$((i + 1))
  done
  _PR_NC=$k
  # A follow-up's replies, each to the thread jig pr followup listed under
  # its number: the thread's id is part of the text shown, and so of the hash.
  for r in $replies; do
    t=${_PR_D_POS[r]}
    v=${_PR_D_PATH[r]}
    [ -n "${_PR_FT_ID[t]:-}" ] || jig_die "pr comments: jig pr followup lists no thread $t; run it again and write the draft again"
    k=$((k + 1))
    cbody[k]="${_PR_D_BODY[r]}"
    _PR_R_THREAD[k]="${_PR_FT_ID[t]}"
    _PR_R_VERDICT[k]="$v"
    _PR_C_DESC[k]="$t $v ${_PR_FT_DESC[t]}, thread ${_PR_FT_ID[t]}"
    _PR_C_LABEL[k]="reply ${_PR_C_DESC[k]}"
  done
  _PR_NP=$k

  sbody="$_PR_D_SUMMARY$_PR_L_INDEX"
  if [ -n "$moved" ]; then
    _pr_trim_nl "$moved"
    sbody="$sbody$_PR_NL$_PR_NL---$_PR_NL$_PR_S"
  fi
  if [ -n "$_PR_UNSHOWN" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      unshown="$unshown${unshown:+, }\`$line\`"
    done <<EOF
$_PR_UNSHOWN
EOF
    sbody="$sbody$_PR_NL${_PR_NL}Not in $_PR_FORGE_NAME's diff, so not commented on: $unshown."
  fi

  # The hash is taken over the text without markers; the markers carry it.
  canon=$(_pr_comments_render "$sbody" "" cbody; printf x)
  canon=${canon%x}
  _PR_H=$(printf '%s' "$canon" | _pr_git "$JIG_PROJECT" hash-object --stdin) \
    || jig_die "pr comments: could not hash the review"
  marker="<!-- jig-pr-review id=$_PR_H head=$head"
  sbody="$sbody$_PR_NL$_PR_NL$marker part=0 -->"
  i=1
  while [ "$i" -le "$k" ]; do
    if [ "$i" -gt "$_PR_NC" ]; then
      cbody[i]="${cbody[i]}$_PR_NL$_PR_NL$marker part=$i verdict=${_PR_R_VERDICT[i]} -->"
    else
      cbody[i]="${cbody[i]}$_PR_NL$_PR_NL$marker part=$i -->"
    fi
    i=$((i + 1))
  done
  _PR_SHOWN=$(_pr_comments_render "$sbody" "$_PR_H" cbody; printf x)
  _PR_SHOWN=${_PR_SHOWN%x}

  json_quote "$sbody"
  _PR_SUMMARY_FIELDS="\"body\":$_JSON"
  if [ "$_PR_FORGE" = gitlab ]; then
    # One discussion a part; payload.json is the list of them, for reading.
    _PR_PAYLOAD="[{$_PR_SUMMARY_FIELDS}"
    i=1
    while [ "$i" -le "$_PR_NC" ]; do
      json_quote "${cbody[i]}"
      _PR_C_FIELDS[i]="\"body\":$_JSON,\"position\":${cpos[i]}"
      _PR_PAYLOAD="$_PR_PAYLOAD,{${_PR_C_FIELDS[i]}}"
      i=$((i + 1))
    done
    _PR_PAYLOAD="$_PR_PAYLOAD]"
    _pr_reply_fields cbody
    return 0
  fi
  _pr_reply_fields cbody
  k=$_PR_NC
  i=1
  while [ "$i" -le "$k" ]; do
    json_quote "${cpath[i]}"
    _PR_C_FIELDS[i]="\"path\":$_JSON"
    json_quote "${cbody[i]}"
    _PR_C_FIELDS[i]="${_PR_C_FIELDS[i]},\"body\":$_JSON,\"line\":${cline[i]},\"side\":\"${cside[i]}\""
    if [ -n "${cstart[i]}" ]; then
      _PR_C_FIELDS[i]="${_PR_C_FIELDS[i]},\"start_line\":${cstart[i]},\"start_side\":\"${cside[i]}\""
    fi
    i=$((i + 1))
  done
  json_quote "$head"
  _PR_PAYLOAD="{\"commit_id\":$_JSON,\"event\":\"COMMENT\",$_PR_SUMMARY_FIELDS"
  if [ "$k" -gt 0 ]; then
    _PR_PAYLOAD="$_PR_PAYLOAD,\"comments\":["
    i=1
    while [ "$i" -le "$k" ]; do
      if [ "$i" -gt 1 ]; then _PR_PAYLOAD="$_PR_PAYLOAD,"; fi
      _PR_PAYLOAD="$_PR_PAYLOAD{${_PR_C_FIELDS[i]}}"
      i=$((i + 1))
    done
    _PR_PAYLOAD="$_PR_PAYLOAD]"
  fi
  _PR_PAYLOAD="$_PR_PAYLOAD}"
}

# _pr_reply_fields <bodies array name> — each reply's JSON fields (its body
# alone: the thread is in the endpoint) into _PR_C_FIELDS.
_pr_reply_fields() {
  local i=$((_PR_NC + 1)) ref
  while [ "$i" -le "$_PR_NP" ]; do
    ref="$1[$i]"
    json_quote "${!ref}"
    _PR_C_FIELDS[i]="\"body\":$_JSON"
    i=$((i + 1))
  done
}

# _pr_comments_render <summary> <hash or empty> <bodies array name> — the text
# a person is shown: the header, the summary, and each comment under the
# position it is posted at (the draft's notation, the path as posted). On
# GitLab the header names the diff's base and start too: a position carries
# them, so a diff GitLab made again is a new version to show.
_pr_comments_render() {
  local sbody="$1" i=1 ref
  if [ "$_PR_FORGE" = gitlab ]; then
    printf 'jig-pr-post: 1\nurl: %s\nhead: %s\nbase: %s\nstart: %s\n' "$_PR_URL" "$_PR_HEAD" "$_PR_GL_BASE" "$_PR_GL_START"
  else
    printf 'jig-pr-post: 1\nurl: %s\nhead: %s\n' "$_PR_URL" "$_PR_HEAD"
  fi
  if [ -n "$_PR_D_FOLLOWS" ]; then printf 'follows: %s\n' "$_PR_D_FOLLOWS"; fi
  if [ "$_PR_FORGE" = gitlab ]; then
    printf 'login: %s\nevent: discussions\n\n' "$_PR_D_LOGIN"
  else
    printf 'login: %s\nevent: COMMENT\n\n' "$_PR_D_LOGIN"
  fi
  printf '=== summary\n%s\n' "$sbody"
  while [ "$i" -le "$_PR_NP" ]; do
    ref="$3[$i]"
    if [ "$i" -gt "$_PR_NC" ]; then
      printf '=== reply %s\n%s\n' "${_PR_C_DESC[i]}" "${!ref}"
    else
      printf '=== comment %s\n%s\n' "${_PR_C_DESC[i]}" "${!ref}"
    fi
    i=$((i + 1))
  done
}

_pr_comments_check() {
  local arg="" now
  while [ $# -gt 0 ]; do
    case "$1" in
      -*) jig_fail usage "pr comments check: unknown argument: $1; $PR_USAGE" ;;
      *)
        [ -z "$arg" ] || jig_fail usage "pr comments check: one pull request at a time; $PR_USAGE"
        arg="$1"
        shift
        ;;
    esac
  done
  [ -n "$arg" ] || jig_fail usage "pr comments check: a pull request number or URL is required; $PR_USAGE"
  _pr_comments_prepare check "$arg"
  _pr_comments_build
  _pr_write "$_PR_DIR/payload.json" "$_PR_PAYLOAD"
  _pr_write "$_PR_DIR/shown.md" "$_PR_SHOWN"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _pr_write "$_PR_DIR/shown" "hash: $_PR_H
shown_at: $now
"
  printf 'jig: to post: %s\n' "$_PR_DIR/shown.md" >&2
  if [ "$_PR_MOVED" -gt 0 ]; then
    printf 'jig: moved into the summary: %s comment(s) outside %s'"'"'s diff\n' "$_PR_MOVED" "$_PR_FORGE_NAME" >&2
  fi
  if [ "$_PR_PERSONAL" -gt 0 ]; then
    printf 'jig: left out: %s personal block(s), never posted\n' "$_PR_PERSONAL" >&2
  fi
  printf '%s' "$_PR_SHOWN"
  printf 'hash: %s\n' "$_PR_H"
}

# _pr_readback — what of this review is on the pull request already, by the
# draft's login: _PR_LANDED (" <part> …", 0 the summary), _PR_LANDED_AT[k]
# (where comment k sits now), _PR_REVIEW_URL (the summary's review), and
# _PR_OTHER (a review or comment of the same head by the same login from
# another version: a half-done one may have left comments and no review). Markers by anybody else are not ours to count.
_PR_LANDED="" _PR_REVIEW_URL="" _PR_OTHER="" _PR_MISPLACED=""
_pr_readback() {
  local out line tab login marker url rest w lline lside lstart lirt lpath me
  if [ "$_PR_FORGE" = gitlab ]; then
    _pr_gl_readback
    return 0
  fi
  _PR_MISPLACED=" "
  tab=$(printf '\t')
  me=$(printf '%s' "$_PR_D_LOGIN" | tr '[:upper:]' '[:lower:]')
  _PR_LANDED=" " _PR_REVIEW_URL="" _PR_OTHER="" _PR_GH_SEEN=" "
  _PR_LANDED_AT=() _PR_MISPLACED_AT=()
  out=$(_pr_gh --paginate "repos/$_PR_SLUG/pulls/$_PR_N/reviews?per_page=100" \
    --jq '.[] | select(.body | tostring | contains("<!-- jig-pr-review ")) | (.id | tostring) + "\t" + .user.login + "\t" + (.body | split("<!-- jig-pr-review ")[1] | split(" -->")[0]) + "\t" + .html_url' \
    2>/dev/null) || jig_die "pr comments: could not read back the reviews of pull request $_PR_N"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$(printf '\r')"}
    [ -n "$line" ] || continue
    rest=${line#*"$tab"}
    login=${rest%%"$tab"*}
    rest=${rest#*"$tab"}
    marker=${rest%%"$tab"*}
    url=${rest#*"$tab"}
    [ "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" = "$me" ] || continue
    _pr_marker "$marker"
    [ "$_PR_M_HEAD" = "$_PR_HEAD" ] || continue
    if [ "$_PR_M_ID" = "$_PR_H" ]; then
      if [ "$_PR_M_PART" = 0 ]; then
        _PR_LANDED="${_PR_LANDED}0 "
        _PR_REVIEW_URL="$url"
      fi
    elif [ -z "$_PR_OTHER" ]; then
      _PR_OTHER="$url"
    fi
  done <<EOF
$out
EOF
  out=$(_pr_gh --paginate "repos/$_PR_SLUG/pulls/$_PR_N/comments?per_page=100" \
    --jq '.[] | select(.body | tostring | contains("<!-- jig-pr-review ")) | (.id | tostring) + "\t" + .user.login + "\t" + (.body | split("<!-- jig-pr-review ")[1] | split(" -->")[0]) + "\t" + (.line | tostring) + "\t" + (.side | tostring) + "\t" + (.start_line | tostring) + "\t" + (.in_reply_to_id | tostring) + "\t" + .html_url + "\t" + .path' \
    2>/dev/null) || jig_die "pr comments: could not read back the comments of pull request $_PR_N"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$(printf '\r')"}
    [ -n "$line" ] || continue
    rest=${line#*"$tab"}
    login=${rest%%"$tab"*}
    rest=${rest#*"$tab"}
    marker=${rest%%"$tab"*}
    rest=${rest#*"$tab"}
    lline=${rest%%"$tab"*}
    rest=${rest#*"$tab"}
    lside=${rest%%"$tab"*}
    rest=${rest#*"$tab"}
    lstart=${rest%%"$tab"*}
    rest=${rest#*"$tab"}
    lirt=${rest%%"$tab"*}
    rest=${rest#*"$tab"}
    url=${rest%%"$tab"*}
    lpath=${rest#*"$tab"}
    [ "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" = "$me" ] || continue
    _pr_marker "$marker"
    [ "$_PR_M_HEAD" = "$_PR_HEAD" ] || continue
    if [ "$_PR_M_ID" != "$_PR_H" ]; then
      if [ -z "$_PR_OTHER" ]; then _PR_OTHER="$url"; fi
      continue
    fi
    _PR_GH_SEEN="$_PR_GH_SEEN${line%%"$tab"*} "
    case "$_PR_M_PART" in '' | 0 | *[!0-9]*) continue ;; esac
    [ "$_PR_M_PART" -le "$_PR_NP" ] || continue
    if [ "$_PR_M_PART" -gt "$_PR_NC" ]; then
      # A reply has landed only in the thread it was shown for.
      if [ "$lirt" = "${_PR_R_THREAD[_PR_M_PART]}" ]; then
        _PR_LANDED="$_PR_LANDED$_PR_M_PART "
        _PR_LANDED_AT[_PR_M_PART]="thread $lirt"
      else
        _PR_MISPLACED="$_PR_MISPLACED$_PR_M_PART "
        _PR_MISPLACED_AT[_PR_M_PART]="thread $lirt"
      fi
      continue
    fi
    _PR_LANDED="$_PR_LANDED$_PR_M_PART "
    w="$lline"
    if [ "$lstart" != null ] && [ -n "$lstart" ]; then w="$lstart-$lline"; fi
    _PR_LANDED_AT[_PR_M_PART]="$lside $w $lpath"
  done <<EOF
$out
EOF
}

# _pr_marker <id=… head=… part=… [verdict=…]> — into _PR_M_ID, _PR_M_HEAD,
# _PR_M_PART and _PR_M_VERDICT (a reply's: fixed or open).
_PR_M_ID="" _PR_M_HEAD="" _PR_M_PART="" _PR_M_VERDICT=""
_pr_marker() {
  local w
  _PR_M_ID="" _PR_M_HEAD="" _PR_M_PART="" _PR_M_VERDICT=""
  set -f
  # shellcheck disable=SC2086 # the marker's words
  set -- $1
  set +f
  for w in "$@"; do
    case "$w" in
      id=*) _PR_M_ID=${w#id=} ;;
      head=*) _PR_M_HEAD=${w#head=} ;;
      part=*) _PR_M_PART=${w#part=} ;;
      verdict=*) _PR_M_VERDICT=${w#verdict=} ;;
    esac
  done
}

# _pr_misplaced_list — the parts _PR_MISPLACED holds, with where each is.
_pr_misplaced_list() {
  local k=0 out=""
  while [ "$k" -le "$_PR_NP" ]; do
    case "$_PR_MISPLACED" in
      *" $k "*)
        if [ "$k" = 0 ]; then
          out="$out${out:+; }summary at ${_PR_MISPLACED_AT[0]}"
        else
          out="$out${out:+; }${_PR_C_LABEL[k]} at ${_PR_MISPLACED_AT[k]}"
        fi
        ;;
    esac
    k=$((k + 1))
  done
  printf '%s\n' "$out"
}

# _pr_count_landed [<last part>] — how many of the review's parts, up to
# <last part> (all of them by default), _PR_LANDED holds.
_pr_count_landed() {
  local n=0 k=0
  while [ "$k" -le "${1:-$_PR_NP}" ]; do
    case "$_PR_LANDED" in *" $k "*) n=$((n + 1)) ;; esac
    k=$((k + 1))
  done
  printf '%s\n' "$n"
}

# _pr_post_file <name> <json> <endpoint> — POST <json>, written to a file of
# the state directory and handed to gh with --input (never spliced into an
# argument), to <endpoint>; the new object's id, or gh's complaint, in
# _PR_OUT. Called in this shell, never in $(...), so that the file is
# registered for removal on an interrupt; it goes after the call.
_PR_OUT=""
_pr_post_file() {
  local file="$_PR_DIR/$1" rc=0
  jig_cleanup_add "$file"
  _pr_write "$file" "$2"
  _PR_OUT=$(_pr_gh --method POST "$3" --input "$file" --jq .id 2>&1) || rc=$?
  _PR_OUT=$(printf '%s' "$_PR_OUT" | tr -d '\r')
  rm -f "$file"
  return "$rc"
}

# _pr_gh_posted <review id> <reply ids> — `posted` for this version on
# GitHub: the review GitHub took and the replies it took since, each recorded
# as soon as it is given.
_pr_gh_posted() {
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _pr_write "$_PR_DIR/posted" "hash: $_PR_H
review: $1
replies: $2
login: $_PR_D_LOGIN
posted_at: $now
"
}

# _pr_gh_post_replies — a follow-up's replies GitHub does not hold yet, each
# into its thread (`pulls/<n>/comments/<id>/replies`), one call each; the
# first refusal stops the rest, into `err` of _pr_comments_post, as on GitLab.
_pr_gh_post_replies() {
  local k=$((_PR_NC + 1)) rid="" rids=""
  if [ -f "$_PR_DIR/posted" ] && [ "$(_pr_record_get "$_PR_DIR/posted" hash)" = "$_PR_H" ]; then
    rid=$(_pr_record_get "$_PR_DIR/posted" review)
    rids=$(_pr_record_get "$_PR_DIR/posted" replies)
  fi
  while [ "$k" -le "$_PR_NP" ]; do
    case "$_PR_LANDED" in
      *" $k "*) ;;
      *)
        if ! _pr_post_file "part-$k.json" "{${_PR_C_FIELDS[k]}}" \
          "repos/$_PR_SLUG/pulls/$_PR_N/comments/${_PR_R_THREAD[k]}/replies"; then
          err="$err$_PR_OUT$_PR_NL"
          return 0
        fi
        rids="$rids${rids:+ }$_PR_OUT"
        _pr_gh_posted "$rid" "$rids"
        ;;
    esac
    k=$((k + 1))
  done
}

_pr_comments_post() {
  local arg="" shown="" recorded total landed k out rc=0 now prev posted_id="" missing=0 err="" ids="" misplaced=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --shown)
        [ $# -ge 2 ] || jig_fail usage "pr comments post: --shown requires the hash check printed"
        shown="$2"
        shift 2
        ;;
      -*) jig_fail usage "pr comments post: unknown argument: $1; $PR_USAGE" ;;
      *)
        [ -z "$arg" ] || jig_fail usage "pr comments post: one pull request at a time; $PR_USAGE"
        arg="$1"
        shift
        ;;
    esac
  done
  [ -n "$arg" ] || jig_fail usage "pr comments post: a pull request number or URL is required; $PR_USAGE"
  [ -n "$shown" ] || jig_fail usage "pr comments post: --shown <hash> is required: the hash of the version the person said yes to"
  _pr_resolve "comments post" "$arg"
  recorded=""
  prev="$(_pr_state_dir "$_PR_N")/shown"
  if [ -f "$prev" ]; then recorded=$(_pr_record_get "$prev" hash); fi
  [ -n "$recorded" ] || jig_die "pr comments post: nothing was shown for pull request $_PR_N; jig pr comments check $_PR_N, and show what it prints"
  [ "$shown" = "$recorded" ] \
    || jig_die "pr comments post: $shown is not the version shown last ($recorded); show the latest jig pr comments check and ask again"

  _pr_comments_prepare post "$arg"
  _pr_comments_build
  [ "$_PR_H" = "$shown" ] \
    || jig_die "pr comments post: what would be posted now ($_PR_H) is not what was shown ($shown); run jig pr comments check $_PR_N and show it again — nothing was posted"

  _pr_readback
  total=$((_PR_NP + 1))
  landed=$(_pr_count_landed)
  if [ "$_PR_MISPLACED" != " " ]; then
    jig_die "pr comments post: a part of this version is on $_PR_URL, but not where it was shown ($(_pr_misplaced_list)); decide there what stays — nothing was posted"
  fi
  if [ "$_PR_FORGE" = gitlab ]; then
    _pr_gl_refuse_a_lost_note
  else
    _pr_gh_refuse_a_lost_reply
  fi
  if [ "$landed" = 0 ] && [ -n "$_PR_OTHER" ]; then
    jig_die "pr comments post: $_PR_D_LOGIN already posted another version of a review of this head: $_PR_OTHER; decide there what stays — nothing was posted"
  fi
  if [ "$landed" = 0 ] && [ -f "$_PR_DIR/posted" ] && [ "$(_pr_record_get "$_PR_DIR/posted" hash)" = "$_PR_H" ]; then
    jig_die "pr comments post: this version was posted as review $(_pr_record_get "$_PR_DIR/posted" review), but $_PR_FORGE_NAME shows none of its markers; look at $_PR_URL before posting anything again"
  fi

  if [ "$landed" = "$total" ]; then
    printf 'already posted: nothing is missing\n'
  elif [ "$_PR_FORGE" = gitlab ]; then
    # One discussion a call, the summary first; the first refusal stops the
    # rest (a rate limit refuses them too), and a run again posts only what is
    # missing. Each id goes into `posted` as soon as GitLab gives it, after
    # those an earlier run of this version recorded.
    if [ -f "$_PR_DIR/posted" ] && [ "$(_pr_record_get "$_PR_DIR/posted" hash)" = "$_PR_H" ]; then
      ids=$(_pr_record_get "$_PR_DIR/posted" review)
    fi
    k=0
    while [ "$k" -le "$_PR_NP" ]; do
      case "$_PR_LANDED" in
        *" $k "*) ;;
        *)
          if ! _pr_gl_post_part "$k"; then
            err="$_PR_OUT"
            break
          fi
          if [ -z "$posted_id" ]; then posted_id="$_PR_OUT"; fi
          ids="$ids${ids:+ }$_PR_OUT"
          now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          _pr_write "$_PR_DIR/posted" "hash: $_PR_H
review: $ids
login: $_PR_D_LOGIN
posted_at: $now
"
          ;;
      esac
      k=$((k + 1))
    done
  elif [ "$(_pr_count_landed "$_PR_NC")" = 0 ]; then
    _pr_post_file post.json "$_PR_PAYLOAD" "repos/$_PR_SLUG/pulls/$_PR_N/reviews" || rc=$?
    out="$_PR_OUT"
    if [ "$rc" = 0 ]; then
      posted_id="$out"
      _pr_gh_posted "$posted_id" ""
      _pr_gh_post_replies
    else
      err="$out"
    fi
  else
    # Some parts landed and the answer was lost: post only the rest, each
    # alone — the summary as a review without comments, a comment by itself.
    json_quote "$_PR_HEAD"
    case "$_PR_LANDED" in
      *" 0 "*) ;;
      *)
        _pr_post_file part-0.json "{\"commit_id\":$_JSON,\"event\":\"COMMENT\",$_PR_SUMMARY_FIELDS}" \
          "repos/$_PR_SLUG/pulls/$_PR_N/reviews" || err="$err$_PR_OUT$_PR_NL"
        ;;
    esac
    k=1
    while [ "$k" -le "$_PR_NC" ]; do
      case "$_PR_LANDED" in
        *" $k "*) ;;
        *)
          _pr_post_file "part-$k.json" "{\"commit_id\":$_JSON,${_PR_C_FIELDS[k]}}" \
            "repos/$_PR_SLUG/pulls/$_PR_N/comments" || err="$err$_PR_OUT$_PR_NL"
          ;;
      esac
      k=$((k + 1))
    done
    if [ -z "$err" ]; then _pr_gh_post_replies; fi
  fi

  _pr_readback
  printf 'posted as: %s\n' "$_PR_D_LOGIN"
  printf 'review: %s\n' "${_PR_REVIEW_URL:-${posted_id:-not found}}"
  case "$_PR_LANDED" in
    *" 0 "*) printf 'landed: summary\n' ;;
    *) printf 'missing: summary\n'; missing=$((missing + 1)) ;;
  esac
  k=1
  while [ "$k" -le "$_PR_NP" ]; do
    case "$_PR_LANDED" in
      *" $k "*) printf 'landed: %s at %s\n' "${_PR_C_LABEL[k]}" "${_PR_LANDED_AT[k]}" ;;
      *)
        printf 'missing: %s\n' "${_PR_C_LABEL[k]}"
        missing=$((missing + 1))
        ;;
    esac
    k=$((k + 1))
  done
  case "$_PR_MISPLACED" in
    " ") ;;
    *)
      k=0
      while [ "$k" -le "$_PR_NP" ]; do
        case "$_PR_MISPLACED" in
          *" $k "*)
            if [ "$k" = 0 ]; then
              printf 'misplaced: summary at %s\n' "${_PR_MISPLACED_AT[0]}"
            else
              printf 'misplaced: %s at %s\n' "${_PR_C_LABEL[k]}" "${_PR_MISPLACED_AT[k]}"
            fi
            misplaced=$((misplaced + 1))
            ;;
        esac
        k=$((k + 1))
      done
      ;;
  esac
  if [ -n "$err" ]; then
    jig_warn "pr comments post: $_PR_FORGE_NAME answered: $(printf '%s' "$err" | tr '\n' ' ')"
  fi
  if [ "$misplaced" -gt 0 ]; then
    jig_die "pr comments post: $misplaced part(s) landed where they were not shown; do not post again — look at $_PR_URL"
  fi
  if [ "$missing" = "$total" ] && [ -n "$posted_id" ]; then
    jig_die "pr comments post: $_PR_FORGE_NAME took review $posted_id, but none of its markers came back; do not post again — look at $_PR_URL"
  fi
  if [ "$missing" = "$total" ]; then
    jig_die "pr comments post: nothing landed on $_PR_URL"
  fi
  if [ "$missing" -gt 0 ]; then
    jig_die "pr comments post: half-done: $((total - missing)) of $total parts landed; run jig pr comments post $_PR_N --shown $_PR_H again to post only what is missing"
  fi
}

# --- followup: an earlier review, read back from the forge -----------------------------------
#
# adr-20261110-a-follow-up-answers-its-own-threads. What jig posted carries a
# marker with the head it reviewed, so the forge itself says what was
# reviewed: `followup` reads the login's markers back, takes the head of the
# latest of them as the one to follow, makes sure that commit is in the clone
# (or says it is gone), and lists the threads still to answer — every
# top-level comment of an earlier head that no reply of the login has called
# fixed. Nothing the author wrote is printed: their replies are data, read on
# the forge.

# _pr_valid_sha <s> — a full commit id, 40 (or, in a SHA-256 repository, 64)
# lowercase hex digits. A marker's head comes from the forge and reaches git
# as an argument: nothing else passes.
_pr_valid_sha() {
  case "$1" in '' | *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" = 40 ] || [ "${#1}" = 64 ]
}

# _pr_valid_thread <id> — a thread's id as it goes into an API path: GitHub's
# comment ids are digits, GitLab's discussion ids hex.
_pr_valid_thread() {
  case "$1" in '' | *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# _pr_added_ranges <from> <to> <path> — the lines git's diff of <from>..<to>
# adds to <path> on the <to> side, as "<first> <last>;" each. Every option that
# shapes the hunks is pinned, so the person's diff.* settings change nothing:
# with diff.interHunkContext two hunks merge and the unchanged lines between
# them would count as added.
_pr_added_ranges() {
  local out line a c d
  out=$(_pr_git "$JIG_PROJECT" diff --no-ext-diff --no-textconv --no-color --no-renames --diff-algorithm=myers --indent-heuristic --inter-hunk-context=0 -U0 "$1" "$2" -- "$3" 2>/dev/null) || out=""
  a=""
  while IFS= read -r line; do
    case "$line" in "@@ -"*) ;; *) continue ;; esac
    _pr_hunk "$line" || continue
    # shellcheck disable=SC2086 # four numbers
    set -- $_PR_HUNK
    c=$3 d=$4
    if [ "$d" -gt 0 ]; then a="$a$c $((c + d - 1));"; fi
  done <<EOT
$out
EOT
  printf '%s\n' "$a"
}

# _pr_in_interdiff <follows> <merge base> <head> <path> <start> <end> — exit 0
# when lines <start>..<end> of <path> at <head> take in a line added both since
# <follows> and since <merge base>: a line the author changed after the last
# review, not one a rebase brought in from the base.
_pr_in_interdiff() {
  local r1 r2 x y s1 e1 s2 e2 lo hi
  r1=$(_pr_added_ranges "$1" "$3" "$4")
  r2=$(_pr_added_ranges "$2" "$3" "$4")
  x="$r1"
  while [ -n "$x" ]; do
    s1=${x%%;*}
    x=${x#*;}
    e1=${s1#* } s1=${s1% *}
    y="$r2"
    while [ -n "$y" ]; do
      s2=${y%%;*}
      y=${y#*;}
      e2=${s2#* } s2=${s2% *}
      lo=$5 hi=$6
      [ "$s1" -le "$lo" ] || lo=$s1
      [ "$s2" -le "$lo" ] || lo=$s2
      [ "$e1" -ge "$hi" ] || hi=$e1
      [ "$e2" -ge "$hi" ] || hi=$e2
      if [ "$lo" -le "$hi" ]; then return 0; fi
    done
  done
  return 1
}

# The markers of the login, one item each: _PR_I_KIND (top: a comment that
# opens a thread; reply: a note in one; summary), _PR_I_ID (the thread's id
# for a top, the parent's for a reply), _PR_I_HEAD, _PR_I_PART, _PR_I_VERDICT,
# _PR_I_AT (when it was made, ISO 8601), _PR_I_POS, _PR_I_PATH, _PR_I_URL and
# _PR_I_BODY (without its marker line).
_PR_NI=0
_pr_fu_reset() {
  _PR_NI=0
  _PR_I_KIND=() _PR_I_ID=() _PR_I_HEAD=() _PR_I_PART=() _PR_I_VERDICT=() _PR_I_AT=()
  _PR_I_POS=() _PR_I_PATH=() _PR_I_URL=() _PR_I_BODY=()
}

# _pr_fu_add <me> <login> <kind> <id> <marker> <at> <pos> <path> <url> <body> —
# one item, kept when it is the login's and its marker names a head and a part.
_pr_fu_add() {
  local me="$1" kind="$3" body="" line i
  [ "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" = "$me" ] || return 0
  _pr_marker "$5"
  _pr_valid_sha "$_PR_M_HEAD" || return 0
  case "$_PR_M_PART" in '' | *[!0-9]*) return 0 ;; esac
  if [ "$kind" = top ] && [ "$_PR_M_PART" = 0 ]; then kind=summary; fi
  if [ "$kind" != summary ]; then _pr_valid_thread "$4" || return 0; fi
  while IFS= read -r line; do
    case "$line" in *"jig-pr-review id="*) continue ;; esac
    body="$body$line$_PR_NL"
  done <<EOT
${10}
EOT
  _pr_trim_nl "$body"
  i=$_PR_NI
  _PR_I_KIND[i]="$kind" _PR_I_ID[i]="$4" _PR_I_HEAD[i]="$_PR_M_HEAD" _PR_I_PART[i]="$_PR_M_PART"
  _PR_I_VERDICT[i]="$_PR_M_VERDICT" _PR_I_AT[i]="$6" _PR_I_POS[i]="$7" _PR_I_PATH[i]="$8"
  _PR_I_URL[i]="$9" _PR_I_BODY[i]="$_PR_S"
  _PR_NI=$((i + 1))
}

# _pr_gh_followup_read <login> — the login's markers on pull request _PR_N:
# its reviews (the summary) and its review comments, each with the lines of its
# body (`B`), through gh's filter.
_pr_gh_followup_read() {
  local me out line tab kind="" id="" login="" marker="" at="" pos="" path="" url="" body="" rest irt oline side ostart
  tab=$(printf '\t')
  me=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  _pr_fu_reset
  out=$(_pr_gh --paginate "repos/$_PR_SLUG/pulls/$_PR_N/reviews?per_page=100" \
    --jq '.[] | select(.body | tostring | contains("<!-- jig-pr-review ")) | ("S\t" + (.id | tostring) + "\t" + .user.login + "\t" + (.body | split("<!-- jig-pr-review ")[1] | split(" -->")[0]) + "\t" + (.submitted_at | tostring) + "\t" + .html_url), (.body | split("\n") | .[] | "B\t" + .)' \
    2>/dev/null) || jig_die "pr followup: could not read the reviews of pull request $_PR_N"
  out="$out$_PR_NL"$(_pr_gh --paginate "repos/$_PR_SLUG/pulls/$_PR_N/comments?per_page=100" \
    --jq '.[] | select(.body | tostring | contains("<!-- jig-pr-review ")) | ("C\t" + (.id | tostring) + "\t" + .user.login + "\t" + (.body | split("<!-- jig-pr-review ")[1] | split(" -->")[0]) + "\t" + (.created_at | tostring) + "\t" + (.in_reply_to_id | tostring) + "\t" + (.original_line | tostring) + "\t" + (.side | tostring) + "\t" + (.original_start_line | tostring) + "\t" + .html_url + "\t" + (.path | tostring | gsub("\n"; " "))), (.body | split("\n") | .[] | "B\t" + .)' \
    2>/dev/null) || jig_die "pr followup: could not read the comments of pull request $_PR_N"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"$(printf '\r')"}
    case "$line" in
      "B$tab"*) body="$body${line#B?}$_PR_NL"; continue ;;
      "S$tab"* | "C$tab"*) ;;
      *) continue ;;
    esac
    if [ -n "$kind" ]; then _pr_fu_add "$me" "$login" "$kind" "$id" "$marker" "$at" "$pos" "$path" "$url" "$body"; fi
    body=""
    rest=${line#?"$tab"}
    id=${rest%%"$tab"*}; rest=${rest#*"$tab"}
    login=${rest%%"$tab"*}; rest=${rest#*"$tab"}
    marker=${rest%%"$tab"*}; rest=${rest#*"$tab"}
    at=${rest%%"$tab"*}; rest=${rest#*"$tab"}
    pos="" path=""
    case "$line" in
      S*)
        kind=top url="$rest"
        ;;
      C*)
        irt=${rest%%"$tab"*}; rest=${rest#*"$tab"}
        oline=${rest%%"$tab"*}; rest=${rest#*"$tab"}
        side=${rest%%"$tab"*}; rest=${rest#*"$tab"}
        ostart=${rest%%"$tab"*}; rest=${rest#*"$tab"}
        url=${rest%%"$tab"*}
        path=${rest#*"$tab"}
        if [ "$side" = LEFT ]; then pos=L; else pos=R; fi
        if [ -n "$ostart" ] && [ "$ostart" != null ] && [ "$ostart" != "$oline" ]; then pos="$pos$ostart-$oline"; else pos="$pos$oline"; fi
        if [ -n "$irt" ] && [ "$irt" != null ]; then kind=reply id="$irt"; else kind=top; fi
        ;;
    esac
  done <<EOT
$out
EOT
  if [ -n "$kind" ]; then _pr_fu_add "$me" "$login" "$kind" "$id" "$marker" "$at" "$pos" "$path" "$url" "$body"; fi
  # A review's summary is a `top` of part 0, which _pr_fu_add calls summary;
  # a review is no thread.
  return 0
}

# _pr_fu_pick — from the items, the head to follow (_PR_FU_HEAD: that of the
# latest item of a head other than the one fetched now), the summary posted
# with it (_PR_FU_SUMMARY), and the threads to answer, in the order the forge
# gave them: _PR_T_ID[k], _PR_T_DESC[k] ("<pos> <path>"), _PR_T_URL[k],
# _PR_T_BODY[k] for k = 1.._PR_NT. A thread is closed by a reply of the login
# whose verdict was fixed, on an earlier head; what the current head's own
# post holds never closes one, so a half-done follow-up lists the same threads
# again. _PR_FU_CLOSED counts the closed ones.
_PR_FU_HEAD="" _PR_FU_SUMMARY="" _PR_NT=0 _PR_FU_CLOSED=0
_pr_fu_pick() {
  local i=0 j last="" closed
  _PR_FU_HEAD="" _PR_FU_SUMMARY="" _PR_NT=0 _PR_FU_CLOSED=0
  _PR_T_ID=() _PR_T_DESC=() _PR_T_URL=() _PR_T_BODY=()
  while [ "$i" -lt "$_PR_NI" ]; do
    if [ "${_PR_I_HEAD[i]}" != "$_PR_HEAD" ] && { [ -z "$last" ] || [[ "${_PR_I_AT[i]}" > "$last" ]] || [ "${_PR_I_AT[i]}" = "$last" ]; }; then
      last="${_PR_I_AT[i]}"
      _PR_FU_HEAD="${_PR_I_HEAD[i]}"
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$_PR_NI" ]; do
    if [ "${_PR_I_KIND[i]}" = summary ] && [ "${_PR_I_HEAD[i]}" = "$_PR_FU_HEAD" ]; then
      _PR_FU_SUMMARY="${_PR_I_BODY[i]}"
    fi
    if [ "${_PR_I_KIND[i]}" = top ] && [ "${_PR_I_HEAD[i]}" != "$_PR_HEAD" ]; then
      closed=0
      j=0
      while [ "$j" -lt "$_PR_NI" ]; do
        if [ "${_PR_I_KIND[j]}" = reply ] && [ "${_PR_I_ID[j]}" = "${_PR_I_ID[i]}" ] \
           && [ "${_PR_I_HEAD[j]}" != "$_PR_HEAD" ] && [ "${_PR_I_VERDICT[j]}" = fixed ]; then
          closed=1
        fi
        j=$((j + 1))
      done
      if [ "$closed" = 1 ]; then
        _PR_FU_CLOSED=$((_PR_FU_CLOSED + 1))
      else
        _PR_NT=$((_PR_NT + 1))
        _PR_T_ID[_PR_NT]="${_PR_I_ID[i]}"
        _PR_T_DESC[_PR_NT]="${_PR_I_POS[i]:-?} ${_PR_I_PATH[i]}"
        _PR_T_URL[_PR_NT]="${_PR_I_URL[i]}"
        _PR_T_BODY[_PR_NT]="${_PR_I_BODY[i]}"
      fi
    fi
    i=$((i + 1))
  done
}

# _pr_fetch_opts — the flags every fetch of jig pr passes: no tags, no
# submodules, no refmap (so no remote-tracking ref moves) and, where git has
# it, no FETCH_HEAD.
_pr_fetch_opts() {
  local opts="--no-tags --no-recurse-submodules --refmap=" help
  # `fetch -h` exits 129, so its text is caught, not piped.
  help=$(git fetch -h 2>&1) || true
  case "$help" in
    *write-fetch-head*) opts="$opts --no-write-fetch-head" ;;
  esac
  printf '%s\n' "$opts"
}

# _pr_fu_keep <sha> <remote> — pin the head reviewed last at
# refs/jig/pr/<n>/reviewed: from this clone when it still holds the commit,
# else fetched from <remote> by its id (after a force-push the forge may still
# serve it). Into _PR_FU_HOW: `here`, `fetched` or `unreachable`. Nothing is
# deleted here: a ref an earlier follow-up left is cleanup's to take back.
_PR_FU_HOW=""
_pr_fu_keep() {
  local sha="$1" remote="$2" ref="refs/jig/pr/$_PR_N/reviewed" got opts
  _PR_FU_HOW=unreachable
  if _pr_git "$JIG_PROJECT" cat-file -e "$sha^{commit}" 2>/dev/null; then
    _PR_FU_HOW=here
  else
    opts=$(_pr_fetch_opts)
    # shellcheck disable=SC2086 # opts is a list of fixed flags
    if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$(jig_git_batch_ssh)" \
      jig_net _pr_git "$JIG_PROJECT" fetch -q $opts "$remote" "+$sha:$ref" >/dev/null 2>&1; then
      _PR_FU_HOW=fetched
    fi
  fi
  if [ "$_PR_FU_HOW" != unreachable ]; then
    _pr_git "$JIG_PROJECT" update-ref "$ref" "$sha" || jig_die "pr followup: could not keep $sha at $ref"
    got=$(_pr_git "$JIG_PROJECT" rev-parse --verify --quiet "$ref^{commit}") || got=""
    [ "$got" = "$sha" ] || _PR_FU_HOW=unreachable
  fi
}

_pr_followup() {
  local arg="" login="" rec remote base_sha pr_base old_mb="" k threads="" fu now reviewed
  while [ $# -gt 0 ]; do
    case "$1" in
      --login)
        [ $# -ge 2 ] || jig_fail usage "pr followup: --login requires the account that reviewed it"
        login="$2"
        shift 2
        ;;
      -*) jig_fail usage "pr followup: unknown argument: $1; $PR_USAGE" ;;
      *)
        [ -z "$arg" ] || jig_fail usage "pr followup: one pull request at a time; $PR_USAGE"
        arg="$1"
        shift
        ;;
    esac
  done
  [ -n "$arg" ] || jig_fail usage "pr followup: a pull request number or URL is required; $PR_USAGE"
  _pr_resolve followup "$arg"
  _PR_DIR=$(_pr_state_dir "$_PR_N")
  rec="$_PR_DIR/record"
  [ -f "$rec" ] || jig_die "pr followup: pull request $_PR_N is not fetched here; jig pr fetch <url> first, to read its new head"
  _PR_HOST=$(_pr_record_get "$rec" host)
  _PR_URL=$(_pr_record_get "$rec" url)
  _PR_SLUG=$(_pr_record_get "$rec" repo)
  _PR_HEAD=$(_pr_record_get "$rec" head)
  _PR_MB=$(_pr_record_get "$rec" merge_base)
  _PR_FORGE=$(_pr_record_get "$rec" forge)
  remote=$(_pr_record_get "$rec" remote)
  base_sha=$(_pr_record_get "$rec" base_sha)
  # The merge base the fetch read from is GitHub's, below the pull request's
  # own base commit; the earlier head's is measured from the same commit, or a
  # base that moved alone would read as a rebase. A record from before the
  # field measured both from the base branch's tip.
  pr_base=$(_pr_record_get "$rec" pr_base_sha)
  [ -n "$pr_base" ] || pr_base=$base_sha
  [ -n "$login" ] || login=$(_pr_record_get "$rec" login)
  if [ -z "$login" ] || [ "$login" = ask ]; then
    jig_die "pr followup: the fetch could not tell which account to read the earlier review of; name it: jig pr followup $_PR_N --login <login>"
  fi
  case "$login" in *[!A-Za-z0-9._-]*) jig_die "pr followup: not a login: $login" ;; esac

  if [ "$_PR_FORGE" = gitlab ]; then
    _PR_FORGE_NAME=GitLab
    _PR_GL_PID=$(_pr_record_get "$rec" project_id)
    case "$_PR_GL_PID" in
      '' | *[!0-9]*) jig_die "pr followup: the record of merge request $_PR_N names no GitLab project; fetch it again" ;;
    esac
    _pr_gl_as followup "$login"
    _pr_gl_followup_read "$login"
  else
    _PR_FORGE=github _PR_FORGE_NAME=GitHub
    _pr_gh_as followup "$login"
    _pr_gh_followup_read "$login"
  fi
  _pr_fu_pick
  [ -n "$_PR_FU_HEAD" ] \
    || jig_die "pr followup: $login has posted no review of an earlier head of $_PR_URL; review it as a first review"

  _pr_fu_keep "$_PR_FU_HEAD" "$remote"
  if [ "$_PR_FU_HOW" = unreachable ]; then
    reviewed=unreachable
  else
    reviewed=available
    old_mb=$(_pr_git "$JIG_PROJECT" merge-base "$pr_base" "$_PR_FU_HEAD" 2>/dev/null) || old_mb=""
  fi

  k=1
  while [ "$k" -le "$_PR_NT" ]; do
    threads="${threads}thread: $k ${_PR_T_ID[k]} ${_PR_T_DESC[k]}$_PR_NL"
    k=$((k + 1))
  done
  fu="$_PR_DIR/followup"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _pr_write "$fu" "login: $login
head: $_PR_HEAD
follows: $_PR_FU_HEAD
reviewed: $reviewed
old_merge_base: $old_mb
threads: $_PR_NT
${threads}read_at: $now
"
  printf 'pull request: %s\n' "$_PR_URL"
  printf 'login: %s\n' "$login"
  printf 'head: %s (the head to review now)\n' "$_PR_HEAD"
  printf 'follows: %s (the head %s reviewed last)\n' "$_PR_FU_HEAD" "$login"
  case "$_PR_FU_HOW" in
    here) printf 'reviewed: in this clone, kept at refs/jig/pr/%s/reviewed\n' "$_PR_N" ;;
    fetched) printf 'reviewed: fetched from %s, kept at refs/jig/pr/%s/reviewed\n' "$remote" "$_PR_N" ;;
    *) printf 'reviewed: unreachable — neither this clone nor %s has %s (a force-push made it unreachable); judge each thread against the new head, and take new findings from the whole diff\n' "$remote" "$_PR_FU_HEAD" ;;
  esac
  if [ "$reviewed" = available ]; then
    printf 'interdiff: git -C %s diff %s %s\n' "$JIG_PROJECT" "$_PR_FU_HEAD" "$_PR_HEAD"
    if [ -n "$old_mb" ] && [ "$old_mb" != "$_PR_MB" ]; then
      printf 'range-diff: git -C %s range-diff %s..%s %s..%s   (the base moved: a rebase)\n' "$JIG_PROJECT" "$old_mb" "$_PR_FU_HEAD" "$_PR_MB" "$_PR_HEAD"
    fi
  else
    printf 'diff: git -C %s diff %s %s\n' "$JIG_PROJECT" "$_PR_MB" "$_PR_HEAD"
  fi
  printf 'state: %s\n' "$fu"
  _pr_method_lines
  printf 'threads: %s to answer' "$_PR_NT"
  if [ "$_PR_FU_CLOSED" -gt 0 ]; then printf ' (%s answered fixed before)' "$_PR_FU_CLOSED"; fi
  printf '\n'
  k=1
  while [ "$k" -le "$_PR_NT" ]; do
    printf '=== thread %s %s\n%s\n%s\n' "$k" "${_PR_T_DESC[k]}" "${_PR_T_URL[k]}" "${_PR_T_BODY[k]}"
    k=$((k + 1))
  done
  if [ -n "$_PR_FU_SUMMARY" ]; then
    printf '=== earlier summary\n%s\n' "$_PR_FU_SUMMARY"
  fi
}

# _pr_fu_load — the threads of the kept `followup` into _PR_FT_ID[k] and
# _PR_FT_DESC[k], k = 1.._PR_FT_N, for a draft that follows up.
_PR_FT_N=0
_pr_fu_load() {
  local line rest k id
  _PR_FT_N=0
  _PR_FT_ID=() _PR_FT_DESC=()
  [ -f "$_PR_DIR/followup" ] || jig_die "pr comments: the draft follows up, but there is no jig pr followup for pull request $_PR_N"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "thread: "*) ;; *) continue ;; esac
    rest=${line#thread: }
    k=${rest%% *}
    rest=${rest#* }
    id=${rest%% *}
    _pr_valid_number "$k" || continue
    _pr_valid_thread "$id" || jig_die "pr comments: the followup of pull request $_PR_N names a thread jig cannot use: $id"
    _PR_FT_ID[k]="$id"
    _PR_FT_DESC[k]=${rest#* }
    [ "$k" -le "$_PR_FT_N" ] || _PR_FT_N=$k
  done < "$_PR_DIR/followup"
}

# --- list ---------------------------------------------------------------------------------------

_pr_list() {
  local root d n rec any=0 clone common has
  [ $# -eq 0 ] || jig_fail usage "pr list: unknown argument: $1; $PR_USAGE"
  clone=$(jig_config_clone_root)
  common=$(_pr_common_dir) || common=""
  for root in "$clone/$JIG_AI_DIR/workspace/pr" "${common:+$common/jig/pr}"; do
    if [ -z "$root" ] || [ ! -d "$root" ]; then continue; fi
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      n=$(basename "$d")
      _pr_valid_number "$n" || continue
      rec="$d/record"
      [ -f "$rec" ] || continue
      any=1
      has=no
      if [ -f "$d/draft.md" ]; then has=yes; fi
      printf '%s %s head=%s worktree=%s draft=%s\n' "$n" "$(_pr_record_get "$rec" url)" \
        "$(_pr_record_get "$rec" head)" "$(_pr_record_get "$rec" worktree)" "$has"
    done
  done
  [ "$any" = 1 ] || printf 'no pull requests fetched in this clone\n'
}

# --- cleanup ------------------------------------------------------------------------------------

# Takes back what fetch made for one pull request, and nothing else:
# - the worktree, only by `git worktree remove` without --force, only at the
#   path _pr_worktree_path builds from a checked number, and only when git lists
#   it there detached and unlocked; git refuses one with changes, and then
#   nothing else goes either. What git leaves behind (Windows) is cleared by
#   jig_worktree_leftover: links and empty directories only.
# - the refs refs/jig/pr/<n>/head, /base, /pr-base (GitHub's base commit, when
#   the fetch had to bring it) and /reviewed (a follow-up's), each
#   by `update-ref -d` at the commit it holds when read.
# - the record, the draft and the rest jig writes there, by name, then `rmdir` of their directory, which
#   refuses anything else in it.
_pr_cleanup() {
  local n wt kind dir r sha did=0
  [ $# -eq 1 ] || jig_fail usage "pr cleanup: one pull request number or URL is required; $PR_USAGE"
  _pr_resolve cleanup "$1"
  n="$_PR_N"
  wt=$(_pr_worktree_path "$n")
  kind=$(_pr_worktree_kind "$wt")
  case "$kind" in
    detached)
      if ! _pr_git "$JIG_PROJECT" worktree remove "$wt"; then
        jig_die "pr cleanup: git kept the worktree $wt (above); commit nothing there — discard what changed in it, then run cleanup again"
      fi
      if [ -e "$wt" ] && ! jig_worktree_leftover "$wt"; then
        jig_warn "pr cleanup: $wt still holds files git did not remove; delete them yourself"
      fi
      printf 'removed worktree %s\n' "$wt"
      did=1
      ;;
    none)
      if [ -e "$wt" ]; then
        jig_warn "pr cleanup: $wt is not a worktree of this clone; left as it is"
      fi
      ;;
    locked) jig_die "pr cleanup: the worktree $wt is locked; git worktree unlock it first, then run cleanup again" ;;
    *) jig_die "pr cleanup: $wt has a branch checked out; it is not a pull request jig fetched, so it stays" ;;
  esac
  for r in head base pr-base reviewed; do
    sha=$(_pr_git "$JIG_PROJECT" rev-parse --verify --quiet "refs/jig/pr/$n/$r") || continue
    _pr_git "$JIG_PROJECT" update-ref -d "refs/jig/pr/$n/$r" "$sha" \
      || jig_die "pr cleanup: could not delete refs/jig/pr/$n/$r"
    printf 'deleted ref refs/jig/pr/%s/%s\n' "$n" "$r"
    did=1
  done
  dir=$(_pr_state_dir "$n")
  if [ -d "$dir" ]; then
    rm -f "$dir/record" "$dir/draft.md" "$dir/payload.json" "$dir/shown.md" "$dir/shown" "$dir/posted" "$dir/post.json" "$dir/followup"
    for r in "$dir"/part-*.json; do
      r=${r##*/part-}
      r=${r%.json}
      if _pr_valid_number "$r" || [ "$r" = 0 ]; then rm -f "$dir/part-$r.json"; fi
    done
    if rmdir "$dir" 2>/dev/null; then
      printf 'removed %s\n' "$dir"
      did=1
    else
      jig_warn "pr cleanup: $dir holds files jig did not write; left as it is"
    fi
  fi
  [ "$did" = 1 ] || printf 'nothing to clean up for pull request %s\n' "$n"
}
