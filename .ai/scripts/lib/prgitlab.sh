# The GitLab half of `jig pr` (lib/pr.sh, which sources this file): glab and
# the account it answers as, the ndjson reader, a merge request and its diff,
# the read-back of what was posted, the post itself, and a follow-up's read of
# the discussions. A library of its own because the subject crowds out its
# command (.ai/knowledge/ARCHITECTURE.md, "Scripts layout"); everything here is
# called from lib/pr.sh, never from another command.
# shellcheck shell=bash

# --- GitLab ---------------------------------------------------------------------------------
#
# adr-20261110-a-merge-request-review-is-posted-as-discussions. `glab api` has
# no filter of its own, so its answers reach the shell as JSON: always asked
# for with `--output ndjson` (one value a line) and read by _pr_json_lines,
# never by pattern over the raw text.

# The token variables glab takes before any stored account.
_PR_GL_TOKEN_VARS="GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN"

# 1: the next _pr_glab call keeps the environment's token; otherwise every
# token variable is unset and glab answers as the account it keeps for the host.
_PR_GL_ENV=0

# _pr_glab <args>... — `glab api --hostname <_PR_HOST> --output ndjson <args>`,
# in a subshell: the token variables unset (unless _PR_GL_ENV is 1), the host
# variables unset so that --hostname alone names the instance, and glab told
# not to prompt or look for its own updates. Jig never reads, passes or writes
# the token itself; glab's configuration and active account stay as they are.
# API paths are given without a leading `/` (MSYS, as for gh).
_pr_glab() (
  # shellcheck disable=SC2086 # a fixed list of names
  if [ "$_PR_GL_ENV" != 1 ]; then unset $_PR_GL_TOKEN_VARS CI_JOB_TOKEN; fi
  unset GITLAB_HOST GL_HOST GITLAB_URI GITLAB_URL
  GLAB_CHECK_UPDATE=false NO_PROMPT=1
  export GLAB_CHECK_UPDATE NO_PROMPT
  jig_net glab api --hostname "$_PR_HOST" --output ndjson "$@"
)

# _pr_json_lines — ndjson on stdin, one `<path><TAB><value>` line per scalar
# out: <path> is the value's record number (0 for the first line) and its keys
# and array indices joined by `.` (`3.notes.0.author.username`). A string is
# decoded (\uXXXX into UTF-8; \r dropped; \t, \b, \f and other control
# characters a space); each newline in it starts a continuation line, a TAB
# and the next line of the text. A number, true, false or null is printed as it
# stands. A record jig cannot read prints a line `!`, which every reader takes
# for a refusal. Run under the C locale, where awk's strings are bytes.
_pr_json_lines() {
  # shellcheck disable=SC2016 # an awk program
  env LC_ALL=C awk '
    BEGIN {
      r = 0
      for (i = 0; i < 256; i++) chr[i] = sprintf("%c", i)
      for (i = 0; i < 16; i++) { hv[substr("0123456789abcdef", i + 1, 1)] = i; hv[substr("0123456789ABCDEF", i + 1, 1)] = i }
    }
    function hex4(t,   i, v, c) {
      v = 0
      for (i = 1; i <= 4; i++) { c = substr(t, i, 1); if (!(c in hv)) return -1; v = v * 16 + hv[c] }
      return v
    }
    function utf8(cp) {
      if (cp < 128) return chr[cp]
      if (cp < 2048) return chr[192 + int(cp / 64)] chr[128 + cp % 64]
      if (cp < 65536) return chr[224 + int(cp / 4096)] chr[128 + int(cp / 64) % 64] chr[128 + cp % 64]
      return chr[240 + int(cp / 262144)] chr[128 + int(cp / 4096) % 64] chr[128 + int(cp / 64) % 64] chr[128 + cp % 64]
    }
    function ws(   c) {
      while (p <= n) { c = substr(s, p, 1); if (c != " " && c != "\t" && c != "\r" && c != "\n") break; p++ }
    }
    # str(path) — the string at p; printed under <path> when it is not empty,
    # kept whole in sv otherwise (a key).
    function str(path,   a, c, e, cp, lo, cur, pre) {
      p++
      cur = ""; pre = path "\t"; a = p
      while (p <= n) {
        c = substr(s, p, 1)
        if (c != "\"" && c != "\\") { p++; continue }
        cur = cur substr(s, a, p - a)
        if (c == "\"") {
          p++
          if (path != "") printf "%s%s\n", pre, cur
          sv = cur
          return 1
        }
        e = substr(s, p + 1, 1); p += 2
        if (e == "n") {
          if (path != "") { printf "%s%s\n", pre, cur; pre = "\t"; cur = "" } else cur = cur "\n"
        } else if (e == "r") {
        } else if (e == "t" || e == "b" || e == "f") cur = cur " "
        else if (e == "u") {
          cp = hex4(substr(s, p, 4)); p += 4
          if (cp < 0) return 0
          if (cp >= 55296 && cp < 56320 && substr(s, p, 2) == "\\u") {
            lo = hex4(substr(s, p + 2, 4))
            if (lo >= 56320 && lo < 57344) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); p += 6 }
          }
          if (cp == 10) {
            if (path != "") { printf "%s%s\n", pre, cur; pre = "\t"; cur = "" } else cur = cur "\n"
          } else if (cp == 13) {
          } else if (cp < 32) cur = cur " "
          else cur = cur utf8(cp)
        } else if (e == "\"" || e == "\\" || e == "/") cur = cur e
        else return 0
        a = p
      }
      return 0
    }
    function value(path,   c, a) {
      ws()
      c = substr(s, p, 1)
      if (c == "{") return object(path)
      if (c == "[") return array(path)
      if (c == "\"") return str(path)
      a = p
      while (p <= n) { c = substr(s, p, 1); if (index(",]} \t\r\n", c)) break; p++ }
      if (p == a) return 0
      c = substr(s, a, p - a)
      if (c !~ /^(true|false|null|-?[0-9][0-9.eE+-]*)$/) return 0
      printf "%s\t%s\n", path, c
      return 1
    }
    function object(path,   k, c) {
      p++; ws()
      if (substr(s, p, 1) == "}") { p++; return 1 }
      while (1) {
        ws()
        if (substr(s, p, 1) != "\"") return 0
        if (!str("")) return 0
        k = sv
        ws()
        if (substr(s, p, 1) != ":") return 0
        p++
        if (!value(path "." k)) return 0
        ws(); c = substr(s, p, 1); p++
        if (c == "}") return 1
        if (c != ",") return 0
      }
    }
    function array(path,   i, c) {
      p++; ws()
      if (substr(s, p, 1) == "]") { p++; return 1 }
      i = 0
      while (1) {
        if (!value(path "." i)) return 0
        i++
        ws(); c = substr(s, p, 1); p++
        if (c == "]") return 1
        if (c != ",") return 0
      }
    }
    {
      s = $0; n = length(s); p = 1
      ws()
      if (p > n) next
      if (!value(r)) { print "!"; next }
      ws()
      if (p <= n) print "!"
      r++
    }
  '
}

# _pr_gl_token_env — the token variables set in this environment, which glab
# takes before the account it keeps for any host.
_pr_gl_token_env() {
  local names="" v
  for v in $_PR_GL_TOKEN_VARS; do
    eval "[ -z \"\${$v:-}\" ]" || names="$names${names:+ }$v"
  done
  printf '%s\n' "$names"
}

# _pr_gl_project_path — the project's full path, URL-encoded as the API takes it.
_pr_gl_project_path() {
  local v
  # shellcheck disable=SC2153 # set by lib/pr.sh
  _jig_replace_all_v v "$_PR_OWNER/$_PR_REPO" / %2F
  printf '%s\n' "$v"
}

# _pr_gl_user — the username the next _pr_glab call answers as; nothing when
# GitLab names none.
_pr_gl_user() {
  local out line tab
  tab=$(printf '\t')
  out=$(_pr_glab user 2>/dev/null | _pr_json_lines) || return 0
  while IFS= read -r line; do
    case "$line" in "0.username$tab"*) printf '%s\n' "${line#*"$tab"}"; return 0 ;; esac
  done <<EOF
$out
EOF
}

# _pr_gl_access <project> — `<access> <id>`: what the next _pr_glab call's
# account may do on <project> (an id or the encoded path) — `comment` as a
# member (Reporter or above, or any membership of a project that is not
# public), `read` when it only sees it (on a public project everybody does),
# `none` when GitLab shows it nothing — and the project's numeric id.
_pr_gl_access() {
  local out line tab id="" vis="" pa=0 ga=0 v lvl
  tab=$(printf '\t')
  out=$(_pr_glab "projects/$1" 2>/dev/null | _pr_json_lines) || out=""
  while IFS= read -r line; do
    v=${line#*"$tab"}
    case "$line" in
      "0.id$tab"*) id="$v" ;;
      "0.visibility$tab"*) vis="$v" ;;
      "0.permissions.project_access.access_level$tab"*) pa="$v" ;;
      "0.permissions.group_access.access_level$tab"*) ga="$v" ;;
    esac
  done <<EOF
$out
EOF
  case "$id" in '' | *[!0-9]*) printf 'none \n'; return 0 ;; esac
  case "$pa" in '' | *[!0-9]*) pa=0 ;; esac
  case "$ga" in '' | *[!0-9]*) ga=0 ;; esac
  lvl=$pa
  [ "$ga" -le "$lvl" ] || lvl=$ga
  if [ "$lvl" -ge 20 ] || { [ "$lvl" -ge 10 ] && [ "$vis" != public ]; }; then
    printf 'comment %s\n' "$id"
  else
    printf 'read %s\n' "$id"
  fi
}

# _pr_gl_propose_login <owner/repo> — the GitLab half of _pr_propose_login:
# sets _PR_ACCOUNTS and _PR_ACTIVE (glab keeps one account a host: the one
# GitLab names for a call without a token variable), _PR_TOKEN_ENV, _PR_LOGIN
# (that account when it may comment as a member, or `ask` with _PR_WHY), the
# project's id in _PR_GL_PID, and in _PR_GL_ENV the token the reads that
# follow use: the environment's when it has one, as glab itself would.
_PR_GL_PID=""
_pr_gl_propose_login() {
  local slug="$1" u acc
  _PR_GL_ENV=0
  u=$(_pr_gl_user)
  _PR_ACCOUNTS="$u" _PR_ACTIVE="$u"
  _PR_TOKEN_ENV=$(_pr_gl_token_env)
  _PR_LOGIN=ask _PR_WHY="" _PR_GL_PID=""
  if [ -n "$_PR_TOKEN_ENV" ]; then
    _PR_GL_ENV=1
    read -r acc _PR_GL_PID <<EOF
$(_pr_gl_access "$(_pr_gl_project_path)")
EOF
    _PR_WHY="$_PR_TOKEN_ENV in the environment overrides glab's account"
    return 0
  fi
  read -r acc _PR_GL_PID <<EOF
$(_pr_gl_access "$(_pr_gl_project_path)")
EOF
  if [ -z "$u" ]; then
    _PR_WHY="glab holds no account for $_PR_HOST"
  elif [ "$acc" = comment ]; then
    _PR_LOGIN="$u"
  else
    _PR_WHY="$u may not comment on $slug as a member"
  fi
}

# _pr_gl_as <who> <login> — the GitLab half of _pr_gh_as: the account glab
# keeps for the host, or the environment's token when that is the one that
# answers as <login> (_PR_GL_ENV); GitLab must name that very login either
# way. What it may do on project _PR_GL_PID goes into _PR_ACC.
_pr_gl_as() {
  local who="$1" login="$2" who_am me
  command -v glab >/dev/null 2>&1 || jig_die "pr $who: the GitLab CLI (glab) is needed"
  me=$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')
  _PR_GL_ENV=0
  who_am=$(_pr_gl_user)
  if [ "$(printf '%s' "$who_am" | tr '[:upper:]' '[:lower:]')" != "$me" ] && [ -n "$(_pr_gl_token_env)" ]; then
    _PR_GL_ENV=1
    who_am=$(_pr_gl_user)
  fi
  if [ "$(printf '%s' "$who_am" | tr '[:upper:]' '[:lower:]')" != "$me" ]; then
    jig_die "pr $who: glab answers for $_PR_HOST as ${who_am:-nobody}; the draft's login, $login, is the one it posts as"
  fi
  read -r _PR_ACC _ <<EOF
$(_pr_gl_access "$_PR_GL_PID")
EOF
  [ "$_PR_ACC" != none ] || jig_die "pr $who: $login cannot reach $_PR_SLUG on $_PR_HOST"
}

# _pr_gl_mr_info — merge request _PR_N of project _PR_GL_PID into _PR_GL_STATE,
# _PR_GL_TARGET, _PR_GL_SHA (its head), _PR_GL_LOCKED, _PR_GL_CHANGES and the
# three shas of its diff: _PR_GL_BASE, _PR_GL_START and _PR_GL_HEADSHA.
_PR_GL_STATE="" _PR_GL_TARGET="" _PR_GL_SHA="" _PR_GL_LOCKED="" _PR_GL_CHANGES=""
_PR_GL_BASE="" _PR_GL_START="" _PR_GL_HEADSHA=""
_pr_gl_mr_info() {
  local out line tab v
  tab=$(printf '\t')
  _PR_GL_STATE="" _PR_GL_TARGET="" _PR_GL_SHA="" _PR_GL_LOCKED="" _PR_GL_CHANGES=""
  _PR_GL_BASE="" _PR_GL_START="" _PR_GL_HEADSHA=""
  out=$(_pr_glab "projects/$_PR_GL_PID/merge_requests/$_PR_N" 2>/dev/null | _pr_json_lines) || return 1
  while IFS= read -r line; do
    v=${line#*"$tab"}
    case "$line" in
      '!') return 1 ;;
      "0.state$tab"*) _PR_GL_STATE="$v" ;;
      "0.target_branch$tab"*) _PR_GL_TARGET="$v" ;;
      "0.sha$tab"*) _PR_GL_SHA="$v" ;;
      "0.discussion_locked$tab"*) _PR_GL_LOCKED="$v" ;;
      "0.changes_count$tab"*) _PR_GL_CHANGES="$v" ;;
      "0.diff_refs.base_sha$tab"*) _PR_GL_BASE="$v" ;;
      "0.diff_refs.start_sha$tab"*) _PR_GL_START="$v" ;;
      "0.diff_refs.head_sha$tab"*) _PR_GL_HEADSHA="$v" ;;
    esac
  done <<EOF
$out
EOF
  [ -n "$_PR_GL_SHA" ]
}

# _pr_gl_read_files — merge request _PR_N's files as GitLab's diff has them,
# into the arrays _pr_read_files fills (_PR_F_NAME, _PR_F_OLD, _PR_F_SHOWN,
# _PR_F_HUNKS) and _PR_F_KINDS: per hunk, a letter per line of it — `c` a
# context line, `a` an added one, `d` a deleted one — each hunk ending in `;`,
# as its header does in _PR_F_HUNKS. From `merge_requests/<n>/diffs`, or
# `/changes` on a GitLab older than 15.7.
_pr_gl_read_files() {
  local out line tab i=-1 rec field v pre="" infield="" diffs=1 ren="" big="" seen=0
  tab=$(printf '\t')
  _PR_F_NAME=() _PR_F_OLD=() _PR_F_SHOWN=() _PR_F_HUNKS=() _PR_F_KINDS=()
  if ! out=$(_pr_glab --paginate "projects/$_PR_GL_PID/merge_requests/$_PR_N/diffs?per_page=100" 2>/dev/null | _pr_json_lines); then
    diffs=0
    out=$(_pr_glab "projects/$_PR_GL_PID/merge_requests/$_PR_N/changes" 2>/dev/null | _pr_json_lines) \
      || jig_die "pr comments: GitLab did not give the diff of merge request $_PR_N"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '!') jig_die "pr comments: GitLab gave a diff of merge request $_PR_N that jig cannot read" ;;
      "$tab"*)
        # A continuation: another line of the string read last.
        case "$infield" in
          diff) _pr_gl_diff_line "$i" "${line#?}" ;;
          new_path | old_path) jig_die "pr comments: merge request $_PR_N has a file whose name holds a newline; jig cannot place comments in it" ;;
        esac
        continue
        ;;
    esac
    if [ "$diffs" = 0 ]; then
      case "$line" in "0.changes."*) line=${line#0.changes.} ;; *) infield=""; continue ;; esac
    fi
    rec=${line%%.*}
    pre=${line#*.}
    field=${pre%%"$tab"*}
    v=${line#*"$tab"}
    case "$rec" in '' | *[!0-9]*) infield=""; continue ;; esac
    if [ "$rec" != "$seen" ] || [ "$i" -lt 0 ]; then
      if [ "$i" -ge 0 ]; then _pr_gl_file_done "$i" "$ren" "$big"; fi
      i=$((i + 1))
      seen="$rec" ren="" big=""
      _PR_F_NAME[i]="" _PR_F_OLD[i]="" _PR_F_SHOWN[i]=0 _PR_F_HUNKS[i]="" _PR_F_KINDS[i]=""
    fi
    infield="$field"
    case "$field" in
      new_path) _PR_F_NAME[i]="$v" ;;
      old_path) _PR_F_OLD[i]="$v" ;;
      renamed_file) ren="$v" ;;
      too_large) big="$v" ;;
      diff) _pr_gl_diff_line "$i" "$v" ;;
    esac
  done <<EOF
$out
EOF
  if [ "$i" -ge 0 ]; then _pr_gl_file_done "$i" "$ren" "$big"; fi
}

# _pr_gl_diff_line <file> <line> — one line of GitLab's `diff` text of file
# <file>: a hunk header (only at the start of a line) opens a hunk; ` `, `+`
# and `-` lines inside one are recorded; `\ No newline…` and the rest are not.
_pr_gl_diff_line() {
  local i="$1" l="$2"
  case "$l" in
    "@@ -"*)
      _pr_hunk "$l" || jig_die "pr comments: GitLab gave a hunk header jig cannot read: $l"
      _PR_F_HUNKS[i]="${_PR_F_HUNKS[i]}$_PR_HUNK;"
      _PR_F_KINDS[i]="${_PR_F_KINDS[i]};"
      ;;
    *)
      [ -n "${_PR_F_KINDS[i]}" ] || return 0
      case "$l" in
        " "*) _PR_F_KINDS[i]="${_PR_F_KINDS[i]%;}c;" ;;
        "+"*) _PR_F_KINDS[i]="${_PR_F_KINDS[i]%;}a;" ;;
        "-"*) _PR_F_KINDS[i]="${_PR_F_KINDS[i]%;}d;" ;;
      esac
      ;;
  esac
}

# _pr_gl_file_done <file> <renamed_file> <too_large> — whether GitLab shows the
# file: a diff with a hunk, or a rename with nothing changed; never a file it
# calls too large. An old path equal to the new one is no rename.
_pr_gl_file_done() {
  local i="$1"
  if [ "${_PR_F_OLD[i]}" = "${_PR_F_NAME[i]}" ]; then _PR_F_OLD[i]=""; fi
  if [ "$3" = true ]; then
    _PR_F_SHOWN[i]=0
  elif [ -n "${_PR_F_HUNKS[i]}" ]; then
    _PR_F_SHOWN[i]=1
  elif [ "$2" = true ]; then
    _PR_F_SHOWN[i]=1
  else
    _PR_F_SHOWN[i]=0
  fi
}

# _pr_gl_lines <R|L> <line> — the line pair of a position on GitLab's diff,
# for the hunk _pr_place found (_PR_PLACED_F, _PR_PLACED_H): into _PR_GL_OLD
# and _PR_GL_NEW, either empty when the line has no number on that side (an
# added line has no old one, a deleted line no new one; a context line has
# both, and GitLab wants both).
_PR_GL_OLD="" _PR_GL_NEW=""
_pr_gl_lines() {
  local side="$1" t="$2" hs ks h k j=0 o nn c len
  _PR_GL_OLD="" _PR_GL_NEW=""
  hs=${_PR_F_HUNKS[_PR_PLACED_F]}
  ks=${_PR_F_KINDS[_PR_PLACED_F]}
  while [ "$j" -lt "$_PR_PLACED_H" ]; do
    hs=${hs#*;}
    ks=${ks#*;}
    j=$((j + 1))
  done
  h=${hs%%;*}
  k=${ks%%;*}
  set -f
  # shellcheck disable=SC2086 # four numbers
  set -- $h
  set +f
  o=$1 nn=$3 j=0 len=${#k}
  while [ "$j" -lt "$len" ]; do
    c=${k:j:1}
    case "$c" in
      c)
        if { [ "$side" = R ] && [ "$nn" = "$t" ]; } || { [ "$side" = L ] && [ "$o" = "$t" ]; }; then
          _PR_GL_OLD=$o _PR_GL_NEW=$nn
          return 0
        fi
        o=$((o + 1)) nn=$((nn + 1))
        ;;
      a)
        if [ "$side" = R ] && [ "$nn" = "$t" ]; then _PR_GL_NEW=$nn; return 0; fi
        nn=$((nn + 1))
        ;;
      d)
        if [ "$side" = L ] && [ "$o" = "$t" ]; then _PR_GL_OLD=$o; return 0; fi
        o=$((o + 1))
        ;;
    esac
    j=$((j + 1))
  done
  return 1
}

# _pr_gl_comments_prepare <who> — the GitLab half of _pr_comments_prepare,
# after the draft and the record are read: the draft's login confirmed, its
# access, the merge request's head and diff checked against the review, and
# GitLab's diff read.
_pr_gl_comments_prepare() {
  local who="$1" acc
  _PR_GL_PID=$(_pr_record_get "$_PR_DIR/record" project_id)
  case "$_PR_GL_PID" in
    '' | *[!0-9]*) jig_die "pr comments $who: the record of merge request $_PR_N names no GitLab project; fetch it again" ;;
  esac
  # shellcheck disable=SC2153 # set by lib/pr.sh
  _pr_gl_as "comments $who" "$_PR_D_LOGIN"
  acc="$_PR_ACC"
  _pr_gl_mr_info || jig_die "pr comments $who: GitLab did not answer for $_PR_URL"
  if [ "$_PR_GL_SHA" != "$_PR_HEAD" ] || [ "$_PR_GL_HEADSHA" != "$_PR_HEAD" ]; then
    jig_die "pr comments $who: merge request $_PR_N moved since it was reviewed (GitLab's head is ${_PR_GL_SHA:-unknown}, its diff's ${_PR_GL_HEADSHA:-unknown}, the reviewed head $_PR_HEAD); fetch it again and review what changed — nothing was posted"
  fi
  if [ "$_PR_GL_LOCKED" = true ] && [ "$acc" != comment ]; then
    jig_die "pr comments $who: the discussion of merge request $_PR_N is locked, and $_PR_D_LOGIN is not a member who may still comment"
  fi
  [ "$_PR_GL_BASE" = "$_PR_MB" ] \
    || jig_die "pr comments $who: GitLab's diff starts at ${_PR_GL_BASE:-an unknown commit}, the review at $_PR_MB; fetch it again — old-side lines would point elsewhere"
  case "$_PR_GL_START" in
    '' | *[!0-9a-f]*) jig_die "pr comments $who: GitLab named no start commit for the diff of $_PR_URL" ;;
  esac
  # `1000+` is GitLab's own ceiling: more files than it lists.
  _PR_CHANGED=${_PR_GL_CHANGES%+}
  case "$_PR_GL_CHANGES" in *+) _PR_CHANGED=$((_PR_CHANGED + 1)) ;; esac
  _pr_gl_read_files
  _pr_unshown "$_PR_MB" "$_PR_HEAD" "$_PR_CHANGED"
}

# _pr_gl_readback — the GitLab half of _pr_readback, from the merge request's
# discussions, each by its first note: the same _PR_LANDED, _PR_LANDED_AT,
# _PR_REVIEW_URL (the summary's note) and _PR_OTHER, and _PR_MISPLACED
# (" <part> …") with _PR_MISPLACED_AT: a part of this version whose note is not
# where it was shown — a comment without its position or on another line, a
# summary with one. A misplaced part is never posted again. _PR_GL_SEEN
# (" <note id> …") holds every note of this version, wherever it sits.
_PR_GL_SEEN=""
_pr_gl_readback() {
  local out line tab me key rec ni f v cur="" infield="" body="" login="" nid="" npath="" nold="" nnew="" haspos=""
  local -a dids
  tab=$(printf '\t')
  me=$(printf '%s' "$_PR_D_LOGIN" | tr '[:upper:]' '[:lower:]')
  _PR_LANDED=" " _PR_REVIEW_URL="" _PR_OTHER="" _PR_MISPLACED=" " _PR_GL_SEEN=" "
  _PR_LANDED_AT=() _PR_MISPLACED_AT=()
  out=$(_pr_glab --paginate "projects/$_PR_GL_PID/merge_requests/$_PR_N/discussions?per_page=100" 2>/dev/null | _pr_json_lines) \
    || jig_die "pr comments: could not read back the discussions of merge request $_PR_N"
  # Each discussion's id first: a reply is counted by the thread it is in.
  while IFS= read -r line; do
    case "$line" in
      '!') jig_die "pr comments: GitLab gave discussions of merge request $_PR_N that jig cannot read" ;;
      *".id$tab"*)
        key=${line%%"$tab"*}
        rec=${key%.id}
        case "$rec" in '' | *[!0-9]*) ;; *) dids[rec]=${line#*"$tab"} ;; esac
        ;;
    esac
  done <<EOF
$out
EOF
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$tab"*)
        if [ "$infield" = body ]; then body="$body$_PR_NL${line#?}"; fi
        continue
        ;;
    esac
    v=${line#*"$tab"}
    key=${line%%"$tab"*}
    rec=${key%%.*}
    f=${key#*.}
    case "$f" in notes.*) ;; *) infield=""; continue ;; esac
    f=${f#notes.}
    ni=${f%%.*}
    f=${f#*.}
    if [ "$rec.$ni" != "$cur" ]; then
      if [ -n "$cur" ]; then _pr_gl_readback_one "$me" "$login" "$body" "$nid" "$haspos" "$npath" "$nold" "$nnew" "${cur#*.}" "${dids[${cur%%.*}]:-}"; fi
      cur="$rec.$ni"
      body="" login="" nid="" npath="" nold="" nnew="" haspos=""
    fi
    infield="$f"
    case "$f" in
      body) body="$v" ;;
      id) nid="$v" ;;
      author.username) login="$v" ;;
      position) haspos="" ;;
      position.*) haspos=1 ;;
    esac
    case "$f" in
      position.new_path) npath="$v" ;;
      position.old_line) nold="$v" ;;
      position.new_line) nnew="$v" ;;
    esac
  done <<EOF
$out
EOF
  if [ -n "$cur" ]; then _pr_gl_readback_one "$me" "$login" "$body" "$nid" "$haspos" "$npath" "$nold" "$nnew" "${cur#*.}" "${dids[${cur%%.*}]:-}"; fi
}

# _pr_gl_readback_one <me> <login> <body> <note id> <has position> <new path>
# <old line> <new line> <note index> <discussion id> — one note, counted as
# _pr_gl_readback says: a discussion's first note for the summary and the
# comments, a later one for a follow-up's replies.
_pr_gl_readback_one() {
  local me="$1" login="$2" body="$3" nid="$4" haspos="$5" npath="$6" nold="$7" nnew="$8" ni="$9" d="${10}" m url want at
  case "$body" in *"jig-pr-review id="*) ;; *) return 0 ;; esac
  [ "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" = "$me" ] || return 0
  m=${body##*jig-pr-review }
  m=${m%%-->*}
  _pr_marker "$m"
  [ "$_PR_M_HEAD" = "$_PR_HEAD" ] || return 0
  url="$_PR_URL#note_$nid"
  if [ "$_PR_M_ID" != "$_PR_H" ]; then
    if [ -z "$_PR_OTHER" ]; then _PR_OTHER="$url"; fi
    return 0
  fi
  _PR_GL_SEEN="$_PR_GL_SEEN$nid "
  case "$_PR_M_PART" in '' | *[!0-9]*) return 0 ;; esac
  [ "$_PR_M_PART" -le "$_PR_NP" ] || return 0
  if [ "$_PR_M_PART" -gt "$_PR_NC" ]; then
    # A reply has landed only as a later note of the thread it was shown for.
    if [ "$ni" != 0 ] && [ "$d" = "${_PR_R_THREAD[_PR_M_PART]}" ]; then
      _PR_LANDED="$_PR_LANDED$_PR_M_PART "
      _PR_LANDED_AT[_PR_M_PART]="thread $d"
    else
      _PR_MISPLACED="$_PR_MISPLACED$_PR_M_PART "
      _PR_MISPLACED_AT[_PR_M_PART]="thread ${d:-none}"
    fi
    return 0
  fi
  [ "$ni" = 0 ] || return 0
  # Where the note sits, on the side it was posted on: a context line has a
  # number on both.
  want=${_PR_C_WANT[_PR_M_PART]:-}
  at="no line"
  if [ -n "$haspos" ]; then
    case "$want" in
      L*) at="L$nold $npath" ;;
      *) at="R$nnew $npath" ;;
    esac
  fi
  if [ "$_PR_M_PART" = 0 ]; then
    if [ -z "$haspos" ]; then
      _PR_LANDED="${_PR_LANDED}0 "
      _PR_REVIEW_URL="$url"
    else
      _PR_MISPLACED="${_PR_MISPLACED}0 "
      _PR_MISPLACED_AT[0]="$at"
    fi
    return 0
  fi
  if [ -n "$haspos" ] && [ "$at" = "$want" ]; then
    _PR_LANDED="$_PR_LANDED$_PR_M_PART "
    _PR_LANDED_AT[_PR_M_PART]="$at"
  else
    _PR_MISPLACED="$_PR_MISPLACED$_PR_M_PART "
    _PR_MISPLACED_AT[_PR_M_PART]="$at"
  fi
}

# _pr_gl_refuse_a_lost_note — a note GitLab took for this version (an id in
# `posted`) that the read-back does not find with its marker was deleted or
# edited since: what is missing may be that very part, so nothing is posted
# again blindly (adr-20261109-a-review-is-posted-as-it-was-shown).
_pr_gl_refuse_a_lost_note() {
  local id ids
  [ -f "$_PR_DIR/posted" ] || return 0
  [ "$(_pr_record_get "$_PR_DIR/posted" hash)" = "$_PR_H" ] || return 0
  ids=" $(_pr_record_get "$_PR_DIR/posted" review) "
  while [ "$ids" != " " ] && [ -n "$ids" ]; do
    ids=${ids# }
    id=${ids%% *}
    ids=${ids#"$id"}
    [ -n "$id" ] || continue
    case "$_PR_GL_SEEN" in
      *" $id "*) ;;
      *) jig_die "pr comments post: GitLab took note $id of this version, but it does not come back with its marker; look at $_PR_URL before posting anything again — nothing was posted" ;;
    esac
  done
}

# _pr_gl_post_part <k> — post part <k> (0 the summary) as a discussion of its
# own (a follow-up's reply as a note of its thread), its JSON written to a file of the state directory and handed to glab
# with --input; the new note's id, or glab's complaint, in _PR_OUT.
_pr_gl_post_part() {
  local k="$1" file="$_PR_DIR/part-$1.json" rc=0 out line tab id="" ep idkey="0.notes.0.id"
  tab=$(printf '\t')
  ep="projects/$_PR_GL_PID/merge_requests/$_PR_N/discussions"
  jig_cleanup_add "$file"
  if [ "$k" = 0 ]; then
    _pr_write "$file" "{$_PR_SUMMARY_FIELDS}"
  else
    _pr_write "$file" "{${_PR_C_FIELDS[k]}}"
  fi
  # A follow-up's reply is a note of the thread it answers.
  if [ "$k" -gt "$_PR_NC" ]; then
    ep="$ep/${_PR_R_THREAD[k]}/notes"
    idkey="0.id"
  fi
  # glab's stderr goes straight into the capture; its stdout through the
  # reader, so that the id is read from the answer and nothing else.
  out=$( (_pr_glab --method POST "$ep" --input "$file" | _pr_json_lines) 2>&1) || rc=$?
  rm -f "$file"
  while IFS= read -r line; do
    case "$line" in "$idkey$tab"*) id=${line#*"$tab"} ;; esac
  done <<EOF
$out
EOF
  case "$id" in '' | *[!0-9]*) id="" ;; esac
  if [ "$rc" = 0 ] && [ -n "$id" ]; then
    _PR_OUT="$id"
    return 0
  fi
  _PR_OUT=$(printf '%s' "$out" | tr '\t\r' '  ')
  return 1
}

# _pr_gl_position_json <old path> <new path> — a GitLab position on the line
# pair _pr_gl_lines found, with the three shas of the merge request's diff.
_pr_gl_position_json() {
  local j o
  json_quote "$1"
  o=$_JSON
  json_quote "$2"
  j="{\"position_type\":\"text\",\"base_sha\":\"$_PR_GL_BASE\",\"start_sha\":\"$_PR_GL_START\",\"head_sha\":\"$_PR_HEAD\",\"old_path\":$o,\"new_path\":$_JSON"
  if [ -n "$_PR_GL_OLD" ]; then j="$j,\"old_line\":$_PR_GL_OLD"; fi
  if [ -n "$_PR_GL_NEW" ]; then j="$j,\"new_line\":$_PR_GL_NEW"; fi
  printf '%s}\n' "$j"
}

# _pr_gl_followup_read <login> — the GitLab half: every note of every
# discussion of merge request _PR_N; a discussion's first note opens a thread
# (or is a summary), the notes after it are replies in it.
_pr_gl_followup_read() {
  local me out line tab key rest rec ni f v cur="" infield="" body="" login="" nid="" at="" npath="" opath="" nnew="" nold="" pos path
  local -a dids
  tab=$(printf '\t')
  me=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  _pr_fu_reset
  out=$(_pr_glab --paginate "projects/$_PR_GL_PID/merge_requests/$_PR_N/discussions?per_page=100" 2>/dev/null | _pr_json_lines) \
    || jig_die "pr followup: could not read the discussions of merge request $_PR_N"
  while IFS= read -r line; do
    case "$line" in
      '!') jig_die "pr followup: GitLab gave discussions of merge request $_PR_N that jig cannot read" ;;
      *".id$tab"*)
        key=${line%%"$tab"*}
        rec=${key%.id}
        case "$rec" in '' | *[!0-9]*) ;; *) dids[rec]=${line#*"$tab"} ;; esac
        ;;
    esac
  done <<EOT
$out
EOT
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$tab"*)
        if [ "$infield" = body ]; then body="$body$_PR_NL${line#?}"; fi
        continue
        ;;
    esac
    key=${line%%"$tab"*}
    v=${line#*"$tab"}
    rec=${key%%.*}
    rest=${key#*.}
    case "$rest" in notes.*) ;; *) infield=""; continue ;; esac
    rest=${rest#notes.}
    ni=${rest%%.*}
    f=${rest#*.}
    if [ "$rec.$ni" != "$cur" ]; then
      if [ -n "$cur" ]; then _pr_gl_followup_note; fi
      cur="$rec.$ni"
      body="" login="" nid="" at="" npath="" opath="" nnew="" nold=""
    fi
    infield="$f"
    case "$f" in
      body) body="$v" ;;
      id) nid="$v" ;;
      author.username) login="$v" ;;
      created_at) at="$v" ;;
      position.new_path) npath="$v" ;;
      position.old_path) opath="$v" ;;
      position.new_line) nnew="$v" ;;
      position.old_line) nold="$v" ;;
    esac
  done <<EOT
$out
EOT
  if [ -n "$cur" ]; then _pr_gl_followup_note; fi
}

# _pr_gl_followup_note — one note _pr_gl_followup_read has gathered (it reads
# that function's locals).
_pr_gl_followup_note() {
  local r=${cur%%.*} i=${cur#*.} marker kind pos="" path=""
  case "$body" in *"jig-pr-review id="*) ;; *) return 0 ;; esac
  marker=${body##*jig-pr-review }
  marker=${marker%%-->*}
  if [ "$i" = 0 ]; then kind=top; else kind=reply; fi
  if [ -n "$nnew" ] && [ "$nnew" != null ]; then
    pos="R$nnew" path="$npath"
  elif [ -n "$nold" ] && [ "$nold" != null ]; then
    pos="L$nold" path="$opath"
  fi
  _pr_fu_add "$me" "$login" "$kind" "${dids[r]:-}" "$marker" "$at" "$pos" "$path" "$_PR_URL#note_$nid" "$body"
}
