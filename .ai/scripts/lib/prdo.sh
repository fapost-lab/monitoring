# A person's actions on a task's pull request, as commands with a JSON answer
# (adr-20261114-a-persons-pull-request-action-does-not-read-agent-git): ask the
# forge for reviewers (`jig task request-review`), merge the pull request
# (`jig task merge-pr`, the direct flow's counterpart of `jig task land`) and
# read where it stands (`jig task pr-status`).
#
# Sourced by task.sh, and by land.sh for _prdo_view, the forge's word on where
# a pull request goes when no ship recorded it (ARCHITECTURE.md, Scripts
# layout: a subject large enough to crowd out its commands); it only defines
# functions, and calls task.sh's readers and the `jig_*` steps of common.sh. The guards the actions
# table asks (_task_request_review_refusal, _task_merge_pr_refusal,
# _task_pr_status_refusal) stay in task.sh: a listing asks them without this
# file. Each entry reads `--json` anywhere and runs as the producer of json_run.
#
# A write takes the clone's revision (jig_revision_claim) after every local and
# forge check and before the first thing it sends, so a `stale-revision` means
# nothing was sent. `--by human` marks a person's action: the git level, which
# limits the agent, is not read.
# shellcheck shell=bash

# --- reading the forge ---------------------------------------------------------

# Why the last forge call failed: its first line.
_PRDO_WHY=""

# Whether the command runs as JSON: its own words then go to stderr, so stdout
# carries the envelope's value alone.
_PRDO_JSON=0

# _prdo_say <line> — a line a person reads: stdout, or stderr under --json.
_prdo_say() {
  if [ "$_PRDO_JSON" -eq 1 ]; then
    printf '%s\n' "$1" >&2
  else
    printf '%s\n' "$1"
  fi
}

# _prdo_run <out-var> <command>... — run a forge call; its stdout into <out-var>,
# or return 1 with the first line of its error in _PRDO_WHY.
_prdo_run() {
  local __pr_var="$1" __pr_out __pr_err __pr_rc=0
  shift
  __pr_err=$(mktemp "${TMPDIR:-/tmp}/jig-prdo.XXXXXX") || { _PRDO_WHY="no temporary file"; return 1; }
  jig_cleanup_add "$__pr_err"
  __pr_out=$("$@" 2>"$__pr_err") || __pr_rc=$?
  if [ "$__pr_rc" -ne 0 ]; then
    _PRDO_WHY=$(_jig_ship_first_line "$(cat "$__pr_err")")
    [ -n "$_PRDO_WHY" ] || _PRDO_WHY="$1 exited $__pr_rc with no message"
    rm -f "$__pr_err"
    return 1
  fi
  rm -f "$__pr_err"
  printf -v "$__pr_var" '%s' "$(printf '%s' "$__pr_out" | tr -d '\r')"
}

# _prdo_json_fields <keys> <json> — the top-level <keys> (comma-separated) of
# the JSON object <json>, one line of tab-separated values; of each object of
# a JSON array, one line each. A value that is absent, null or empty reads `-`
# (a tab is whitespace to `read`, so an empty field would be lost); a nested
# object or array reads `-`. Walks the text with its strings skipped, so a key
# of a nested object never answers for a top-level one. Written with awk
# (ADR-0002: no jq).
_prdo_json_fields() {
  printf '%s' "$2" | awk -v keys="$1" '
    function strend(k,   d) {
      k++
      while (k <= N) {
        d = substr(S, k, 1)
        if (d == "\\") { k += 2; continue }
        if (d == "\"") return k
        k++
      }
      return N
    }
    function unq(a, b,   v) {
      v = substr(S, a + 1, b - a - 1)
      gsub(/\\"/, "\"", v); gsub(/\\\//, "/", v); gsub(/\\\\/, "\\", v)
      return v
    }
    function field(a, b, key,   i, c, depth, j, k, v, m) {
      depth = 0; i = a
      while (i <= b) {
        c = substr(S, i, 1)
        if (c == "\"") {
          j = strend(i)
          if (depth == 1) {
            k = j + 1
            while (k <= b && substr(S, k, 1) ~ /[ \t\r\n]/) k++
            if (substr(S, k, 1) == ":" && unq(i, j) == key) {
              k++
              while (k <= b && substr(S, k, 1) ~ /[ \t\r\n]/) k++
              v = substr(S, k, 1)
              if (v == "\"") return unq(k, strend(k))
              if (v == "{" || v == "[") return ""
              m = k
              while (m <= b && substr(S, m, 1) !~ /[],} \t\r\n]/) m++
              v = substr(S, k, m - k)
              return (v == "null" ? "" : v)
            }
          }
          i = j + 1
          continue
        }
        if (c == "{" || c == "[") depth++
        else if (c == "}" || c == "]") depth--
        i++
      }
      return ""
    }
    function emit(a, b,   j, line, v) {
      line = ""
      for (j = 1; j <= nk; j++) {
        v = field(a, b, K[j])
        if (v == "") v = "-"
        line = line (j > 1 ? "\t" : "") v
      }
      print line
    }
    { S = S $0 "\n" }
    END {
      N = length(S); nk = split(keys, K, ",")
      i = 1
      while (i <= N && substr(S, i, 1) ~ /[ \t\r\n]/) i++
      if (substr(S, i, 1) == "{") { emit(i, N); exit }
      if (substr(S, i, 1) != "[") exit
      depth = 0; start = 0
      while (i <= N) {
        c = substr(S, i, 1)
        if (c == "\"") { i = strend(i) + 1; continue }
        if (c == "{") { if (depth == 1) start = i; depth++ }
        else if (c == "[") depth++
        else if (c == "}") { depth--; if (depth == 1 && start) { emit(start, i); start = 0 } }
        else if (c == "]") depth--
        i++
      }
    }'
}

# What _prdo_view leaves: the pull request as the forge says it now.
_PRDO_STATE=""      # open|merged|closed
_PRDO_DRAFT=""      # true|false
_PRDO_BASE=""
_PRDO_HEAD=""
_PRDO_MERGEABLE=""  # clean|conflict|unknown
_PRDO_MSTATE=""     # the forge's own word for the merge state, as it says it
_PRDO_PIPELINE=""   # GitLab: the head pipeline's id

# _prdo_view <kind> <url> — read the pull request at <url> once into the
# _PRDO_* variables above, or return 1 with why in _PRDO_WHY. GitHub: one
# `pr view`; GitLab: one `mr view`.
_prdo_view() {
  local kind="$1" url="$2" out iid state draft wip base head ms conflicts
  _PRDO_STATE="" _PRDO_DRAFT="" _PRDO_BASE="" _PRDO_HEAD="" _PRDO_MERGEABLE="" _PRDO_MSTATE="" _PRDO_PIPELINE=""
  case "$kind" in
    github)
      _prdo_run out jig_net jig_gh pr view "$url" \
        --json state,isDraft,baseRefName,headRefOid,mergeable,mergeStateStatus \
        --jq '"\(.state)|\(.isDraft)|\(.baseRefName)|\(.headRefOid)|\(.mergeable)|\(.mergeStateStatus)"' || return 1
      out=${out%%$'\n'*}
      IFS='|' read -r state draft base head ms conflicts <<EOF
$out
EOF
      _PRDO_STATE=$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')
      case "$_PRDO_STATE" in
        open | merged | closed) ;;
        *) _PRDO_WHY="gh answered '${state:-nothing}', which is no pull request state"; return 1 ;;
      esac
      _PRDO_DRAFT=$draft
      _PRDO_BASE=$base
      _PRDO_HEAD=$head
      case "$ms" in
        MERGEABLE) _PRDO_MERGEABLE=clean ;;
        CONFLICTING) _PRDO_MERGEABLE=conflict ;;
        *) _PRDO_MERGEABLE=unknown ;;
      esac
      _PRDO_MSTATE=$(printf '%s' "$conflicts" | tr '[:upper:]' '[:lower:]')
      ;;
    gitlab)
      iid=$(_jig_ship_glab_mr "$url")
      if [ -z "$iid" ]; then _PRDO_WHY="no merge request number in $url"; return 1; fi
      _prdo_run out jig_net glab mr view "$iid" --output json || return 1
      IFS=$'\t' read -r state draft wip base head ms conflicts <<EOF
$(_prdo_json_fields state,draft,work_in_progress,target_branch,sha,detailed_merge_status,has_conflicts "$out")
EOF
      case "$state" in
        opened | open) _PRDO_STATE=open ;;
        merged) _PRDO_STATE=merged ;;
        closed | locked) _PRDO_STATE=closed ;;
        *) _PRDO_WHY="glab answered '${state:--}', which is no merge request state"; return 1 ;;
      esac
      _PRDO_DRAFT=false
      if [ "$draft" = true ] || [ "$wip" = true ]; then _PRDO_DRAFT=true; fi
      [ "$base" != - ] || base=""
      [ "$head" != - ] || head=""
      _PRDO_BASE=$base
      _PRDO_HEAD=$head
      [ "$ms" != - ] || ms=""
      _PRDO_MSTATE=$ms
      case "$conflicts:$ms" in
        true:* | *:conflict) _PRDO_MERGEABLE=conflict ;;
        *:checking | *:unchecked | *:preparing | *:approvals_syncing) _PRDO_MERGEABLE=unknown ;;
        false:*) _PRDO_MERGEABLE=clean ;;
        *) _PRDO_MERGEABLE=unknown ;;
      esac
      _PRDO_PIPELINE=$(printf '%s' "$out" | tr '\n' ' ' \
        | sed -n 's/.*"head_pipeline":[[:space:]]*{[[:space:]]*"id":[[:space:]]*\([0-9][0-9]*\).*/\1/p')
      ;;
  esac
  return 0
}

# _prdo_forge <who> — the forge this clone uses into _PRDO_KIND, after naming
# the GitHub account (jig_gh_resolve), or a `forge-unavailable` refusal saying
# why there is none.
_PRDO_KIND=""
_prdo_forge() {
  _PRDO_KIND=$(jig_forge_kind) || exit 1
  case "$_PRDO_KIND" in
    github) jig_gh_resolve || jig_fail forge-unavailable "$1: $_JIG_GH_WHY" ;;
    gitlab) ;;
    *) jig_fail forge-unavailable "$1: the forge cannot be asked: $(_jig_pr_state_no_forge)" ;;
  esac
}

# _prdo_revision_valid <who> <revision> — validate --revision.
_prdo_revision_valid() {
  [ -n "$2" ] || jig_fail usage "$1: --revision is empty"
  jig_revision_valid "$2" || jig_fail usage "$1: --revision is not a revision: $2"
}

# _prdo_claim <who> <expected> — claim the revision the action was asked
# against, right before the first thing goes to the forge: a stale one stops
# here with nothing sent.
_prdo_claim() {
  local rc=0
  jig_revision_claim "$2" || rc=$?
  case "$rc" in
    0) ;;
    1) jig_fail stale-revision "$1: the clone changed since revision $2; read again and retry" ;;
    *) jig_die "$1: cannot claim the clone revision in $(jig_revision_dir)" ;;
  esac
}

# _prdo_git_level <who> <id> <by> <scope> <levels...> — without `--by human`,
# the agent's git level must be one of <levels>; a person's action reads none.
# <scope> `task`: the level of the task's own ship (_task_ship_git_v, which
# answers agent.git_staging for a task whose pull request goes into the staging
# branch); `base`: a pull request into the base branch, which agent.git governs.
_prdo_git_level() {
  local who="$1" id="$2" by="$3" scope="$4" line level key rc=0 want
  shift 4
  [ "$by" != human ] || return 0
  _task_ship_git_v line "$id" "$scope" || rc=$?
  level=${line%%$'\t'*}
  key=${line#*$'\t'}
  if [ "$rc" -ne 0 ]; then
    jig_fail git-level "$who: invalid $key: $level (expected none|commit|push|pr|merge)"
  fi
  for want in "$@"; do
    [ "$level" != "$want" ] || return 0
  done
  jig_fail git-level "$who: this needs $key: $1${2:+ or $2} (git level $level ($key)); the person does it, not the agent"
}

# --- jig task request-review ---------------------------------------------------

prdo_request_review() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _prdo_request_review_body 1 "$@"
      return
    fi
  done
  _prdo_request_review_body 0 "$@"
}

# _prdo_request_review_body <as_json> <id> [options] — ask the forge to add the
# named people as reviewers of the task's open pull request (adds; never takes
# one off), leaving out its author, the clone's own account.
_prdo_request_review_body() {
  local as_json="$1" arg args=()
  shift
  _PRDO_JSON=$as_json
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ $# -ge 1 ] || jig_fail usage "$(_task_usage request-review)"
  local id="$1" by="" rev="" rev_given=0 who="task request-review"
  shift
  local -a names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --reviewer)
        [ $# -ge 2 ] || jig_fail usage "$who: --reviewer requires a value"
        names+=("$2")
        shift 2 ;;
      --by)
        [ $# -ge 2 ] || jig_fail usage "$who: --by requires a value"
        [ "$2" = human ] || jig_fail usage "$who: --by takes human, not $2"
        by=human
        shift 2 ;;
      --revision)
        [ $# -ge 2 ] || jig_fail usage "$who: --revision requires a value"
        rev="$2"
        rev_given=1
        shift 2 ;;
      *) jig_fail usage "$who: unknown argument: $1 ($(_task_usage request-review))" ;;
    esac
  done
  [ "${#names[@]}" -gt 0 ] || jig_fail usage "$who: --reviewer is required: $(_task_usage request-review)"
  [ "$rev_given" -eq 0 ] || _prdo_revision_valid "$who" "$rev"
  local expected=$rev
  [ -n "$expected" ] || expected=$(jig_revision_read)
  _task_valid_id "$id" || jig_fail usage "invalid task id: $id"
  [ -f "$(task_dir "$id")/state" ] || jig_fail not-found "$who: unknown task: $id"
  _task_guard_write "$id" "$who"
  _prdo_git_level "$who" "$id" "$by" task pr merge

  # The table's own guard, in its words.
  local refusal url state why
  refusal=$(_task_request_review_refusal "$id" "") || exit 1
  [ -z "$refusal" ] || jig_fail "$(_task_prdo_refusal_code "$refusal")" "$refusal"
  url=$(task_state_get "$id" pr_url)

  # The live state of the pull request: reviewers are asked of an open one.
  _prdo_forge "$who"
  jig_pr_state_v state why "$url"
  case "$state" in
    open) ;;
    merged | closed) jig_fail pull-request-closed "$who: the pull request of $id is $state ($url); nobody is asked to review it" ;;
    *) jig_fail forge-unavailable "$who: the forge could not say whether $url is open: ${why:-no answer}" ;;
  esac

  # The names, as `task ship --reviewer` resolves them.
  # shellcheck source=lib/reviewers.sh
  . "$JIG_LIB/reviewers.sh"
  local self="" login seen=" " left_out=0 requested="" n
  jig_reviewers_self self \
    || jig_fail forge-unavailable "$who: the forge could not say which account asks for the review: $_RV_WHY"
  for arg in "${names[@]}"; do
    jig_reviewers_resolve "$who" login "$arg" "$self"
    if [ "$login" = "$self" ]; then
      jig_info "$who: --reviewer $arg: $login opens the pull request, and its author is not asked to review it"
      left_out=1
      continue
    fi
    case "$seen" in *" $login "*) continue ;; esac
    seen="$seen$login "
    [ "$arg" = "$login" ] || [ "$arg" = "@$login" ] || jig_info "$who: --reviewer $arg: $login"
    requested="${requested:+$requested,}$login"
  done
  [ -n "$requested" ] \
    || jig_fail usage "$who: nobody is left to ask: every --reviewer is $self, the author of the pull request"

  _prdo_claim "$who" "$expected"
  local out iid args_gl=() r rc=0
  if [ "$_PRDO_KIND" = github ]; then
    _prdo_run out jig_net jig_gh pr edit "$url" --add-reviewer "$requested" || rc=1
  else
    iid=$(_jig_ship_glab_mr "$url")
    [ -n "$iid" ] || jig_fail forge-unavailable "$who: no merge request number in $url"
    # `+` adds to the list; without it glab replaces it.
    for r in $(printf '%s' "$requested" | tr ',' ' '); do args_gl+=(--reviewer "+$r"); done
    _prdo_run out jig_net glab mr update "$iid" "${args_gl[@]}" || rc=1
  fi
  [ "$rc" -eq 0 ] || jig_fail forge-refused "$who: the forge refused: $_PRDO_WHY"
  for r in $(printf '%s' "$requested" | tr ',' ' '); do
    _prdo_say "requested review of $url from $r"
  done
  [ "$as_json" -eq 1 ] || return 0

  local task list="" lo=false
  task=$(_task_json_one "$id")
  for r in $(printf '%s' "$requested" | tr ',' ' '); do
    json_quote "$r"
    list="${list:+$list,}$_JSON"
  done
  [ "$left_out" -eq 0 ] || lo=true
  json_quote "$url"
  n="{\"pull_request\":$_JSON,\"requested\":[$list],\"author_left_out\":$lo}"
  printf '{"task":%s,"review_request":%s}\n' "$task" "$n"
}

# --- jig task merge-pr ---------------------------------------------------------

prdo_merge_pr() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _prdo_merge_pr_body 1 "$@"
      return
    fi
  done
  _prdo_merge_pr_body 0 "$@"
}

# _prdo_merge_pr_body <as_json> <id> [options] — merge the task's pull request
# into its base on the forge as a person, then close the task when its
# knowledge decision is recorded. Never leaves the branch, never touches the
# checkout, never overrides the forge.
_prdo_merge_pr_body() {
  local as_json="$1" arg args=()
  shift
  _PRDO_JSON=$as_json
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  [ $# -ge 1 ] || jig_fail usage "$(_task_usage merge-pr)"
  local id="$1" by="" rev="" rev_given=0 who="task merge-pr"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --by)
        [ $# -ge 2 ] || jig_fail usage "$who: --by requires a value"
        [ "$2" = human ] || jig_fail usage "$who: --by takes human, not $2"
        by=human
        shift 2 ;;
      --revision)
        [ $# -ge 2 ] || jig_fail usage "$who: --revision requires a value"
        rev="$2"
        rev_given=1
        shift 2 ;;
      *) jig_fail usage "$who: unknown argument: $1 ($(_task_usage merge-pr))" ;;
    esac
  done
  [ "$rev_given" -eq 0 ] || _prdo_revision_valid "$who" "$rev"
  local expected=$rev
  [ -n "$expected" ] || expected=$(jig_revision_read)
  _task_valid_id "$id" || jig_fail usage "invalid task id: $id"
  local dir
  dir=$(task_dir "$id")
  [ -f "$dir/state" ] || jig_fail not-found "$who: unknown task: $id"
  _task_guard_write "$id" "$who"
  _prdo_git_level "$who" "$id" "$by" base merge

  # 1. Locally: the table's own guard, in its words.
  local refusal url why
  refusal=$(_task_merge_pr_refusal "$id" "") || exit 1
  [ -z "$refusal" ] || jig_fail "$(_task_prdo_refusal_code "$refusal")" "$refusal"
  url=$(task_state_get "$id" pr_url)

  # 2. The forge, one look at each thing, so a refusal names its reason.
  _prdo_forge "$who"
  _prdo_view "$_PRDO_KIND" "$url" \
    || jig_fail forge-unavailable "$who: the forge could not be asked about $url: $_PRDO_WHY"
  local outcome=merged
  case "$_PRDO_STATE" in
    merged) outcome=already-merged ;;
    closed) jig_fail pull-request-closed "$who: the pull request of $id is closed ($url); ship $id again to open a new one" ;;
  esac
  # The local guard trusts `pr_into`; the forge is the last word: a pull request
  # into the staging branch is landed, not merged.
  local staging_now
  if [ "$(cfg git.flow direct)" = staging ] && _task_staging_sound_v staging_now \
    && [ "$_PRDO_BASE" = "$staging_now" ]; then
    _task_landed_not_merged_text_v why "$who" "$id" "$staging_now"
    jig_fail wrong-flow "$why"
  fi
  local sha=$_PRDO_HEAD
  if [ "$outcome" = merged ]; then
    _prdo_merge_checks "$who" "$id" "$url" "$sha"
    # 3. The revision, right before the forge is written.
    _prdo_claim "$who" "$expected"
    _prdo_merge_send "$who" "$id" "$url" "$sha"
  else
    _prdo_say "$url is already merged"
  fi

  # 5. The close, under the claim the merge was made under; a task already
  # closed has nothing to write.
  local closed=false blocked=null status close_why
  status=$(task_state_get "$id" status)
  if [ "$status" = consolidated ]; then
    closed=true
  else
    # A pull request into the task's own base puts its work there now: say so,
    # as the forge cache would (<base-state> `merged`), so the staging flow's
    # wait for the base does not refuse a close this merge just made true.
    local own_base into_base=""
    jig_task_base_v own_base "$id"
    if [ -n "$_PRDO_BASE" ] && [ "$_PRDO_BASE" = "$own_base" ]; then
      into_base=merged
    fi
    close_why=$(_task_close_refusal "$id" merged "$into_base") || exit 1
    if [ -n "$close_why" ]; then
      _prdo_say "$id stays open: $close_why"
      # The code by the refusal's opening words, never by a copy of its
      # condition; a test pins each, so a reworded guard fails a test.
      case "$close_why" in
        "task set: status consolidated requires knowledge_consolidated true"*)
          blocked='"knowledge-not-recorded"' ;;
        "task set: $id is on "*" and not in "*" yet: "*)
          blocked='"not-in-base"' ;;
        *) jig_die "$who: merged, but no close_blocked code for this refusal: $close_why" ;;
      esac
    else
      if [ "$outcome" = already-merged ]; then
        _prdo_claim "$who" "$expected"
      fi
      _task_close_write "$id" "$dir" "$expected" claimed
      _task_queue_prune "$id" "$who"
      closed=true
      _prdo_say "closed $id"
    fi
  fi
  [ "$as_json" -eq 1 ] || return 0

  local task pq oq
  task=$(_task_json_one "$id")
  json_quote "$url"; pq=$_JSON
  json_quote "$outcome"; oq=$_JSON
  printf '{"task":%s,"merge":{"pull_request":%s,"outcome":%s,"closed":%s,"close_blocked":%s}}\n' \
    "$task" "$pq" "$oq" "$closed" "$blocked"
}

# _prdo_merge_checks <who> <id> <url> <sha> — step 2 of merge-pr: what the forge
# says now (the view in _PRDO_*) and one look at review and checks, each a
# refusal with its own code, nothing sent.
_prdo_merge_checks() {
  local who="$1" id="$2" url="$3" sha="$4" astate apending why state iid
  if [ "$_PRDO_DRAFT" != false ]; then
    jig_fail draft "$who: $url is a draft; a draft is never merged"
  fi
  case "$_PRDO_MERGEABLE" in
    conflict) jig_fail conflict "$who: $url conflicts with ${_PRDO_BASE:-its base}; resolve the conflict, then merge" ;;
    unknown) jig_fail mergeable-unknown "$who: the forge could not say whether $url merges cleanly into ${_PRDO_BASE:-its base}; try again in a moment" ;;
  esac
  jig_pr_approval_v astate apending "$url"
  case "$astate" in
    changes) jig_fail not-approved "$who: $url is not approved: changes requested" ;;
    waiting)
      if [ -n "$apending" ]; then
        _jig_list_words_v why "$apending"
        why="waiting for $why"
      else
        why="waiting for more approvals"
      fi
      jig_fail not-approved "$who: $url is not approved: $why" ;;
    unknown) jig_fail forge-unavailable "$who: the forge could not say whether $url is approved" ;;
  esac
  # CI, one look (a timeout of 0 is no wait).
  if [ "$_PRDO_KIND" = github ]; then
    state=$(_jig_ship_ci_wait 0 _jig_ship_checks_github "$url")
  else
    iid=$(_jig_ship_glab_mr "$url")
    state=$(_jig_ship_ci_wait 0 _jig_ship_checks_gitlab "$iid" "$sha")
  fi
  case "$state" in
    green) ;;
    red) jig_fail ci-red "$who: a check of $url failed" ;;
    none) jig_fail ci-none "$who: no check ran on $url, so CI checked nothing" ;;
    *) jig_fail ci-pending "$who: the checks of $url have not finished" ;;
  esac
  # A release's notes must still describe the base's tip. The head is the
  # pull request's, since this runs wherever the person is, not on the branch.
  local base_branch raise
  cfg_v base_branch git.base_branch main
  if [ "$_PRDO_BASE" = "$base_branch" ]; then
    # The head must be here to tell whether the merge raises the version: a
    # head this clone lacks is fetched from origin's branch, and one still
    # missing refuses rather than merging a release unchecked.
    if ! git -C "$JIG_PROJECT" cat-file -e "$sha^{commit}" 2>/dev/null; then
      local head_branch
      task_state_var head_branch "$id" branch
      [ -z "$head_branch" ] || jig_fetch_fresh "$head_branch" >/dev/null || true
    fi
    if git -C "$JIG_PROJECT" cat-file -e "$sha^{commit}" 2>/dev/null; then
      raise=$(jig_release_raise "$base_branch" "$sha")
      if [ -n "$raise" ]; then
        _TASK_SHIP_NOTES_BASE=$base_branch
        _TASK_SHIP_NOTES_HEAD=$sha
        _TASK_SHIP_NOTES_WHO=$who
        why=$(_task_ship_notes_last_check)
        [ -z "$why" ] || jig_fail notes-stale "$who: $url raises the version, and $why"
        # shellcheck disable=SC2034 # read by jig_ship_merge (common.sh)
        JIG_SHIP_LAST_CHECK=_task_ship_notes_last_check
      fi
    else
      jig_fail forge-unavailable "$who: the head $sha of $url is not on origin's branch here, so whether it raises the version cannot be checked; nothing was merged. Run jig refresh and try again"
    fi
  fi
}

# _prdo_merge_send <who> <id> <url> <sha> — step 4: the forge merges the pull
# request at <sha>, as `task ship` merges it (any method the repository
# allows), looking at CI once. Its refusal, with the code it came with, is
# the command's. Nothing here moves the checkout or deletes a branch.
_prdo_merge_send() {
  local who="$1" id="$2" url="$3" sha="$4" out line why=""
  # shellcheck disable=SC2034 # read by jig_ship_merge (common.sh)
  JIG_SHIP_CI_TIMEOUT=0
  jig_ship_sends_no_commit "merging a pull request that was shipped"
  out=$(mktemp "${TMPDIR:-/tmp}/jig-merge-pr.XXXXXX")
  jig_cleanup_add "$out"
  jig_ship_merge "$who" "$url" "$sha" any > "$out"
  if [ "$JIG_SHIP_MERGED" != 1 ]; then
    while IFS= read -r line; do
      case "$line" in "not merged: "*) why=${line#not merged: }; break ;; esac
    done < "$out"
    [ -n "$why" ] || why=$(sed -n '1p' "$out")
    jig_fail "${JIG_SHIP_NOT_MERGED_CODE:-forge-refused}" "$who: $url was not merged: ${why:-no reason given}"
  fi
  _prdo_say "merged $url"
}

# --- jig task pr-status --------------------------------------------------------

prdo_pr_status() {
  local arg has=0
  for arg in "$@"; do
    [ "$arg" != --json ] || has=1
  done
  [ "$has" -eq 1 ] || jig_fail usage "task pr-status: it answers as data only: $(_task_usage pr-status)"
  # shellcheck source=lib/json.sh
  . "$JIG_LIB/json.sh"
  json_run _prdo_pr_status_body "$@"
}

# _prdo_ts <value> — a forge timestamp as UTC `YYYY-MM-DDTHH:MM:SSZ`, or
# nothing: fractions of a second dropped, the zero time GitHub reports for a
# check that has not finished, or anything that is not UTC, read as none.
_prdo_ts() {
  local v=$1
  case "$v" in *.*Z) v="${v%%.*}Z" ;; esac
  case "$v" in
    0001-*) return 0 ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) printf '%s\n' "$v" ;;
  esac
}

# _prdo_checks <kind> <url> <pipeline-id> — one line per check of the pull
# request, `<name>\t<bucket>\t<url>\t<started>\t<completed>` (`-` for what is
# not there), into _PRDO_CHECKS: GitHub's checks, GitLab's jobs of the head
# pipeline. A forge that cannot say has none: an unreadable check is no check.
_PRDO_CHECKS=""
_prdo_checks() {
  local kind="$1" url="$2" pipe="$3" out="" jobs line name status link started finished bucket
  _PRDO_CHECKS=""
  if [ "$kind" = github ]; then
    # gh exits 8 while a check is pending: its output stands all the same.
    # shellcheck disable=SC2016 # a jq definition, not the shell's
    out=$(jig_net jig_gh pr checks "$url" --json name,bucket,link,startedAt,completedAt \
      --jq 'def d: if . == null or . == "" then "-" else . end; .[] | [(.name|d),(.bucket|d),(.link|d),(.startedAt|d),(.completedAt|d)] | @tsv' 2>/dev/null) || true
    _PRDO_CHECKS=$(printf '%s' "$out" | tr -d '\r')
    return 0
  fi
  [ -n "$pipe" ] || return 0
  jobs=$(jig_net glab api "projects/:id/pipelines/$pipe/jobs?per_page=100" 2>/dev/null) || return 0
  while IFS=$'\t' read -r name status link started finished; do
    [ -n "$name" ] || continue
    case "$status" in
      success) bucket=pass ;;
      failed) bucket=fail ;;
      canceled | canceling) bucket=cancel ;;
      skipped | manual) bucket=skipping ;;
      *) bucket=pending ;;
    esac
    _PRDO_CHECKS="${_PRDO_CHECKS:+$_PRDO_CHECKS$'\n'}$name"$'\t'"$bucket"$'\t'"$link"$'\t'"$started"$'\t'"$finished"
  done <<EOF
$(_prdo_json_fields name,status,web_url,started_at,finished_at "$jobs")
EOF
}

# _prdo_protection <kind> <url> <base> — the rules of the base branch as the
# forge reports them, into _PRDO_REQ_APPROVALS (a number or empty) and
# _PRDO_REQ_CHECKS (comma-separated names, `-` when the rules ask for none or
# the forge would not say); both empty when it would not say.
_PRDO_REQ_APPROVALS=""
_PRDO_REQ_CHECKS=""
_PRDO_REQ_KNOWN=0
_prdo_protection() {
  local kind="$1" url="$2" base="$3" out iid enc
  _PRDO_REQ_APPROVALS="" _PRDO_REQ_CHECKS="" _PRDO_REQ_KNOWN=0
  if [ "$kind" = github ]; then
    enc=$(printf '%s' "$base" | sed 's|/|%2F|g')
    # shellcheck disable=SC2016 # a jq definition, not the shell's
    out=$(jig_net jig_gh api "repos/{owner}/{repo}/rules/branches/$enc" \
      --jq '"\([.[] | select(.type == "pull_request") | .parameters.required_approving_review_count] | max // 0)|\([.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context] | unique | join(","))"' 2>/dev/null) || return 0
    out=$(printf '%s' "${out%%$'\n'*}" | tr -d '\r')
    _PRDO_REQ_APPROVALS=${out%%|*}
    _PRDO_REQ_CHECKS=${out#*|}
    _PRDO_REQ_KNOWN=1
    return 0
  fi
  iid=$(_jig_ship_glab_mr "$url")
  [ -n "$iid" ] || return 0
  out=$(jig_net glab api "projects/:id/merge_requests/$iid/approvals" 2>/dev/null | tr -d ' \n\r') || return 0
  _PRDO_REQ_APPROVALS=$(printf '%s' "$out" | sed -n 's/.*"approvals_required":\([0-9][0-9]*\).*/\1/p')
  [ -n "$_PRDO_REQ_APPROVALS" ] && _PRDO_REQ_KNOWN=1
  return 0
}

# _prdo_pr_status_body <task id> --json — where the task's pull request stands
# on the forge now. Writes nothing.
_prdo_pr_status_body() {
  local arg args=()
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  set -- ${args[@]+"${args[@]}"}
  jig_require_init
  local who="task pr-status"
  [ $# -eq 1 ] || jig_fail usage "$(_task_usage pr-status)"
  local id="$1" refusal url
  _task_valid_id "$id" || jig_fail usage "invalid task id: $id"
  [ -f "$(task_dir "$id")/state" ] || jig_fail not-found "$who: unknown task: $id"
  refusal=$(_task_pr_status_refusal "$id") || exit 1
  [ -z "$refusal" ] || jig_fail no-pull-request "$refusal"
  url=$(task_state_get "$id" pr_url)

  _PRDO_JSON=1
  _prdo_forge "$who"
  _prdo_view "$_PRDO_KIND" "$url" \
    || jig_fail forge-unavailable "$who: the forge could not be asked about $url: $_PRDO_WHY"

  # The checks, each with its time.
  _prdo_checks "$_PRDO_KIND" "$url" "$_PRDO_PIPELINE"
  local now line name bucket link started completed st s_ep e_ep dur list="" passes=0 reds=0 waits=0 checks_state
  now=$(date -u +%s)
  while IFS=$'\t' read -r name bucket link started completed; do
    [ -n "$name" ] || continue
    [ "$started" != - ] || started=""
    [ "$completed" != - ] || completed=""
    [ "$link" != - ] || link=""
    started=$(_prdo_ts "$started")
    completed=$(_prdo_ts "$completed")
    case "$bucket" in
      pass) st=pass; passes=$((passes + 1)) ;;
      fail) st=fail; reds=$((reds + 1)) ;;
      cancel) st=cancel; reds=$((reds + 1)) ;;
      skipping) st=skipped ;;
      *) st=pending; waits=$((waits + 1)) ;;
    esac
    dur=null
    if [ -n "$started" ]; then
      s_ep=$(jig_utc_epoch "$started")
      e_ep=""
      if [ -n "$completed" ]; then
        e_ep=$(jig_utc_epoch "$completed")
      elif [ "$st" = pending ]; then
        e_ep=$now
      fi
      if [ -n "$s_ep" ] && [ -n "$e_ep" ]; then
        dur=$((e_ep - s_ep))
        [ "$dur" -ge 0 ] || dur=0
      fi
    fi
    json_quote "$name"; line="{\"name\":$_JSON"
    json_quote "$st"; line="$line,\"state\":$_JSON"
    json_str_or_null "$link"; line="$line,\"url\":$_JSON"
    json_str_or_null "$started"; line="$line,\"started_at\":$_JSON"
    json_str_or_null "$completed"; line="$line,\"completed_at\":$_JSON,\"duration_s\":$dur}"
    list="${list:+$list,}$line"
  done <<EOF
$_PRDO_CHECKS
EOF
  if [ "$reds" -gt 0 ]; then checks_state=red
  elif [ "$waits" -gt 0 ]; then checks_state=pending
  elif [ "$passes" -gt 0 ]; then checks_state=green
  else checks_state=none
  fi

  # The review, as `task land` reads it.
  local astate apending
  jig_pr_approval_v astate apending "$url"
  local waiting=""
  for name in $(printf '%s' "$apending" | tr ',' ' '); do
    json_quote "$name"
    waiting="${waiting:+$waiting,}$_JSON"
  done

  # What the base branch asks for.
  _prdo_protection "$_PRDO_KIND" "$url" "$_PRDO_BASE"
  local req_a=null req_c=null
  if [ "$_PRDO_REQ_KNOWN" -eq 1 ]; then
    json_int_or_null "$_PRDO_REQ_APPROVALS"; req_a=$_JSON
    if [ "$_PRDO_KIND" = github ]; then
      req_c=""
      for name in $(printf '%s' "$_PRDO_REQ_CHECKS" | tr ',' ' '); do
        json_quote "$name"
        req_c="${req_c:+$req_c,}$_JSON"
      done
      req_c="[$req_c]"
    fi
  fi

  # What holds the merge back now, in the vocabulary of merge-pr and land.
  local blockers=""
  if [ "$_PRDO_STATE" = open ]; then
    [ "$_PRDO_DRAFT" != true ] || blockers="${blockers:+$blockers,}\"draft\""
    case "$_PRDO_MERGEABLE" in
      conflict) blockers="${blockers:+$blockers,}\"conflict\"" ;;
      unknown) blockers="${blockers:+$blockers,}\"mergeable-unknown\"" ;;
    esac
    case "$checks_state" in
      red) blockers="${blockers:+$blockers,}\"ci-red\"" ;;
      pending) blockers="${blockers:+$blockers,}\"ci-pending\"" ;;
      none) blockers="${blockers:+$blockers,}\"ci-none\"" ;;
    esac
    case "$astate" in
      changes | waiting) blockers="${blockers:+$blockers,}\"not-approved\"" ;;
    esac
  fi

  local o
  json_quote "$id"; o="{\"task_id\":$_JSON"
  json_quote "$url"; o="$o,\"pull_request\":{\"url\":$_JSON"
  json_quote "$_PRDO_STATE"; o="$o,\"state\":$_JSON"
  o="$o,\"draft\":$_PRDO_DRAFT"
  json_str_or_null "$_PRDO_BASE"; o="$o,\"base\":$_JSON"
  json_str_or_null "$_PRDO_HEAD"; o="$o,\"head\":$_JSON"
  json_quote "$_PRDO_MERGEABLE"; o="$o,\"mergeable\":$_JSON"
  json_quote "$checks_state"; o="$o,\"checks\":{\"state\":$_JSON,\"list\":[$list]}"
  json_quote "$astate"; o="$o,\"review\":{\"state\":$_JSON,\"waiting_for\":[$waiting]}"
  json_str_or_null "$_PRDO_MSTATE"; o="$o,\"protection\":{\"merge_state\":$_JSON"
  o="$o,\"required_approvals\":$req_a,\"required_checks\":$req_c}"
  o="$o,\"blockers\":[$blockers]}}"
  printf '%s\n' "$o"
}
