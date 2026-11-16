# Who may be asked to review a pull request this clone opens, read from the
# forge and never kept in a setting (adr-20261113-reviewers-are-read-from-the-forge):
# the people who reviewed the last pull requests into a branch, most frequent
# first, and, when nobody did, everyone the repository may ask. A name a person
# gives resolves to one login among those, or is refused. Only people: a team
# is satisfied by one member's review, which is not what a person who named
# reviewers asked for.
#
# Shared by `jig pr reviewers` (lib/pr.sh), which lists the candidates, and
# `jig task ship --reviewer` (lib/task.sh), which resolves names before the
# pull request is opened: one command library never sources another
# (.ai/knowledge/ARCHITECTURE.md, "Scripts layout"). The forge is this clone's
# (jig_forge_kind), and GitHub is asked as this clone's account (jig_gh): the
# caller resolves it first, in its own shell.
# shellcheck shell=bash

# How many of the last merged pull requests into the branch the history reads.
REVIEWERS_HISTORY=30

# Set by jig_reviewers_candidates: `history` or `assignable`, the account the
# forge is asked as, and one `<login>\t<name>\t<reviews>` line per candidate
# (<reviews> empty under `assignable`).
_RV_SOURCE=""
_RV_SELF=""
_RV_LINES=""

# Set by the readers below when the forge could not answer: its first line.
_RV_WHY=""

# _rv_urlencode <s> — every byte of <s> as %XX: a query value for GitLab's API
# whatever its script (a Cyrillic surname), without a locale-dependent loop.
_rv_urlencode() {
  printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g'
}

# _rv_run <out-var> <command>... — run a forge call; its stdout into <out-var>,
# or return 1 with its first error line in _RV_WHY.
_rv_run() {
  local __rv_var="$1" __rv_out __rv_err __rv_rc=0
  shift
  __rv_err=$(mktemp "${TMPDIR:-/tmp}/jig-reviewers.XXXXXX") || { _RV_WHY="no temporary file"; return 1; }
  jig_cleanup_add "$__rv_err"
  __rv_out=$("$@" 2>"$__rv_err") || __rv_rc=$?
  if [ "$__rv_rc" -ne 0 ]; then
    _RV_WHY=$(awk 'NF && !w { w = $0 } END { print w }' "$__rv_err")
    [ -n "$_RV_WHY" ] || _RV_WHY="$1 exited $__rv_rc with no message"
    rm -f "$__rv_err"
    return 1
  fi
  rm -f "$__rv_err"
  printf -v "$__rv_var" '%s' "$(printf '%s' "$__rv_out" | tr -d '\r')"
}

# _rv_kind — github or gitlab into _RV_KIND, or return 1 with why in _RV_WHY.
# Called directly, never in `$(...)`, or the why is lost with the subshell.
_RV_KIND=""
_rv_kind() {
  _RV_KIND=$(jig_forge_kind) || exit 1
  case "$_RV_KIND" in
    github | gitlab) ;;
    *)
      _RV_WHY=$(_jig_pr_state_no_forge)
      return 1 ;;
  esac
}

# jig_reviewers_self <out-var> — the login this clone asks the forge as: the
# author of the pull request a ship opens, never asked to review it.
jig_reviewers_self() {
  local __rs_kind __rs_out
  _rv_kind || return 1
  __rs_kind=$_RV_KIND
  if [ "$__rs_kind" = github ]; then
    _rv_run __rs_out jig_net jig_gh api user --jq .login || return 1
  else
    _rv_run __rs_out jig_net glab api user || return 1
    __rs_out=$(printf '%s' "$__rs_out" | tr -d ' \n' | sed -n 's/^[^}]*"username":"\([^"]*\)".*/\1/p')
  fi
  __rs_out=${__rs_out%%$'\n'*}
  [ -n "$__rs_out" ] || { _RV_WHY="the forge named no account"; return 1; }
  printf -v "$1" '%s' "$__rs_out"
}

# The GraphQL query for the people a GitHub repository may ask: users only.
# shellcheck disable=SC2016 # GraphQL variables, not the shell's
_RV_GH_ASSIGNABLE='query($owner:String!,$name:String!,$endCursor:String){repository(owner:$owner,name:$name){assignableUsers(first:100,after:$endCursor){nodes{login name} pageInfo{hasNextPage endCursor}}}}'

# jig_reviewers_assignable <out-var> — `<login>\t<name>` per person the
# repository may ask to review: GitHub's assignable users; GitLab's active
# project members, bots left out. All of them, page by page: a name is matched
# here (jig_reviewers_resolve), never sent to the forge, since free text on
# gh's command line does not survive Git Bash (conventions/shell.md).
jig_reviewers_assignable() {
  local __ra_kind __ra_out __ra_path
  _rv_kind || return 1
  __ra_kind=$_RV_KIND
  if [ "$__ra_kind" = github ]; then
    _rv_run __ra_out jig_net jig_gh api graphql --paginate -f query="$_RV_GH_ASSIGNABLE" \
      -F owner='{owner}' -F name='{repo}' \
      --jq '.data.repository.assignableUsers.nodes[] | "\(.login)\t\(if .name then .name else "" end)"' || return 1
  else
    __ra_path="projects/:id/members/all?per_page=100"
    _rv_run __ra_out jig_net glab api --paginate --output ndjson "$__ra_path" || return 1
    # One member a line; its own fields come before the nested `created_by`.
    __ra_out=$(printf '%s\n' "$__ra_out" | awk '
      function field(key,   k) {
        k = "\"" key "\":\""
        if (!match($0, k "[^\"]*\"")) return ""
        return substr($0, RSTART + length(k), RLENGTH - length(k) - 1)
      }
      /"bot":true/ { next }
      {
        u = field("username")
        if (u == "" || u ~ /^(project|group)_[0-9]+_bot/) next
        s = field("state")
        if (s != "" && s != "active") next
        print u "\t" field("name")
      }')
  fi
  printf -v "$1" '%s' "$__ra_out"
}

# jig_reviewers_history <out-var> <base> — `<count>\t<login>` per person who
# reviewed one of the last REVIEWERS_HISTORY merged pull requests into <base>,
# most frequent first; each counted once per pull request, its author never.
# GitHub: the reviews submitted. GitLab: the reviewers the merge request names.
jig_reviewers_history() {
  local __rh_kind __rh_out __rh_base="$2"
  _rv_kind || return 1
  __rh_kind=$_RV_KIND
  if [ "$__rh_kind" = github ]; then
    # shellcheck disable=SC2016 # a jq variable, not the shell's
    _rv_run __rh_out jig_net jig_gh pr list --base "$__rh_base" --state merged --limit "$REVIEWERS_HISTORY" \
      --json author,reviews \
      --jq '.[] | .author.login as $a | [.reviews[]?.author.login | select(. != null and . != $a)] | unique | .[]' || return 1
  else
    _rv_run __rh_out jig_net glab api --output ndjson \
      "projects/:id/merge_requests?state=merged&per_page=$REVIEWERS_HISTORY&target_branch=$(_rv_urlencode "$__rh_base")" || return 1
    __rh_out=$(while IFS= read -r __rh_line; do
      [ -n "$__rh_line" ] || continue
      __rh_author=$(printf '%s' "$__rh_line" | sed -n 's/.*"author":{[^}]*"username":"\([^"]*\)".*/\1/p')
      for __rh_r in $(_jig_pr_usernames "$__rh_line" reviewers); do
        [ "$__rh_r" = "$__rh_author" ] || printf '%s\n' "$__rh_r"
      done | sort -u
    done < <(printf '%s\n' "$__rh_out" | tr -d ' '))
  fi
  __rh_out=$(printf '%s\n' "$__rh_out" | awk 'NF' | sort | uniq -c \
    | awk '{ printf "%s\t%s\n", $1, $2 }' | sort -t "$(printf '\t')" -k1,1nr -k2,2)
  printf -v "$1" '%s' "$__rh_out"
}

# jig_reviewers_candidates <base> — the people to offer as reviewers of a pull
# request into <base>, into _RV_SOURCE, _RV_SELF and _RV_LINES: who reviewed
# the last merged ones (`history`), when anybody did that the repository may
# still ask, else everyone it may ask (`assignable`). Never this clone's own
# account, which opens the pull request, nor a bot. Returns 1 with why in
# _RV_WHY when the forge cannot be asked.
jig_reviewers_candidates() {
  local base="$1" assignable history
  _RV_SOURCE="" _RV_LINES="" _RV_SELF=""
  jig_reviewers_self _RV_SELF || return 1
  jig_reviewers_assignable assignable || return 1
  jig_reviewers_history history "$base" || return 1
  # The assignable list, which grows with the repository, goes in on stdin: one
  # environment string is capped (128 KiB on Linux, 32767 characters on
  # Windows), and an awk that cannot start answers with nothing. The history is
  # at most REVIEWERS_HISTORY pull requests of reviewers, so it stays in the
  # environment, as shell.md has free text go.
  _RV_LINES=$(printf '%s\n' "$assignable" | RV_HISTORY="$history" awk -v self="$_RV_SELF" '
    BEGIN { FS = "\t" }
    $0 == "" { next }
    $1 == self { next }
    { name[$1] = $2; order[++n] = $1 }
    END {
      nh = split(ENVIRON["RV_HISTORY"], h, "\n")
      for (i = 1; i <= nh; i++) {
        if (h[i] == "") continue
        split(h[i], f, "\t")
        if (!(f[2] in name) || f[2] ~ /\[bot\]$/) continue
        printf "%s\t%s\t%s\n", f[2], name[f[2]], f[1]; found = 1
      }
      if (found) exit
      for (i = 1; i <= n; i++) printf "%s\t%s\t\n", order[i], name[order[i]]
    }') || { _RV_WHY="awk could not read the list of people the repository may ask"; return 1; }
  case "$_RV_LINES" in
    *"	"*[0-9]) _RV_SOURCE=history ;;
    *) _RV_SOURCE=assignable ;;
  esac
}

# jig_reviewers_resolve <who> <out-var> <value> [<self>] — the login <value>
# names: a login itself (`@` allowed in front), or a part of a login or a
# person's name that fits exactly one person the repository may ask (any case,
# as far as the local awk folds it). <self>, the account that opens the pull
# request, answers to its exact login only: a part of its name is not a
# second person to choose from, since it is never asked. Dies naming the
# matches when several fit, and when none does or <value> names a team (code
# `reviewer-unknown`; `forge-unavailable` when the forge could not be asked).
jig_reviewers_resolve() {
  local __rr_who="$1" __rr_q="${3#@}" __rr_self="${4:-}" __rr_all __rr_hits __rr_login __rr_n
  case "$__rr_q" in
    '') jig_fail reviewer-unknown "$__rr_who: --reviewer needs a login or a name" ;;
    */*) jig_fail reviewer-unknown "$__rr_who: --reviewer $__rr_q: a team is not asked for a review, only people: name each of them" ;;
  esac
  jig_reviewers_assignable __rr_all \
    || jig_fail forge-unavailable "$__rr_who: --reviewer $__rr_q: the forge could not be asked who it may be: $_RV_WHY"
  # An exact login first (`=` lines), else every login or name holding it
  # (`~` lines). The list goes in on stdin (see jig_reviewers_candidates for
  # why); the value and the author's login stay in the environment.
  __rr_hits=$(printf '%s\n' "$__rr_all" | RV_Q="$__rr_q" RV_SELF="$__rr_self" awk '
    BEGIN { FS = "\t"; q = tolower(ENVIRON["RV_Q"]); self = ENVIRON["RV_SELF"] }
    $0 == "" { next }
    {
      if (tolower($1) == q) exact = $1
      else if ($1 != self && (index(tolower($1), q) || index(tolower($2), q))) some = some "~" $1 "\t" $2 "\n"
    }
    END {
      if (exact != "") print "=" exact
      else printf "%s", some
    }') || jig_fail forge-unavailable "$__rr_who: --reviewer $__rr_q: awk could not read the list of people the repository may ask"
  case "$__rr_hits" in
    =*) __rr_login=${__rr_hits#=} ;;
    '') jig_fail reviewer-unknown "$__rr_who: --reviewer $__rr_q: nobody this repository may ask for a review matches it; give the login" ;;
    *)
      __rr_n=$(printf '%s\n' "$__rr_hits" | grep -c '^~' || true)
      if [ "$__rr_n" -gt 1 ]; then
        jig_fail reviewer-unknown "$__rr_who: --reviewer $__rr_q matches several people: $(printf '%s\n' "$__rr_hits" \
          | awk -F '\t' '/^~/ { l = substr($1, 2); printf "%s%s%s", (n++ ? ", " : ""), l, ($2 != "" ? " (" $2 ")" : "") }'); name one of them by login"
      fi
      __rr_login=${__rr_hits#\~}
      __rr_login=${__rr_login%%$'\t'*} ;;
  esac
  case "$__rr_login" in
    *[!A-Za-z0-9._-]*) jig_fail forge-unavailable "$__rr_who: --reviewer $__rr_q: the forge answered '$__rr_login', which is no login" ;;
  esac
  printf -v "$2" '%s' "$__rr_login"
}
