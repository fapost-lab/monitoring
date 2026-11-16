# The forge cache: what housekeeping last heard from the forge about pull
# requests, kept so that a read never asks the forge itself
# (adr-20261015-a-read-is-one-json-envelope; schemas/json.md). Written by
# `jig housekeeping` from the list it already fetches, which replaces it whole;
# `jig upgrade` adds the one pull request it has just opened (forgecache_record),
# so the upgrade waiting for its merge is known before housekeeping next runs
# (adr-20261029-an-upgrade-pull-request-is-landed-by-jig). Read by
# `jig task list --json` and `jig status`.
#
#   .ai/runtime/forge-cache, one line per pull request, newest first as the
#   forge listed them:
#     <head><TAB><base><TAB><state><TAB><ci><TAB><fetched_at><TAB><head-commit><TAB><url><TAB><mergeable><TAB><review><TAB><waiting_for><TAB><reviewed_at>
#   <state> open|merged|closed; <ci> green|red|pending|none, `-` when it was
#   not asked (a pull request that is not open, a forge that does not list it);
#   <fetched_at> UTC, when the forge said so; <head-commit> and <url> the pull
#   request's head and address, `-` when the forge did not say; <mergeable>
#   conflicting|mergeable for an open pull request the forge judged against
#   its base, `-` otherwise (read by the staging drift report,
#   jig_staging_drift); <review> approved|changes|waiting|none for an open pull
#   request whose review the forge was asked about (jig_pr_approval_v's words,
#   adr-20261113-reviewers-are-read-from-the-forge), `-` otherwise and when it
#   could not say; <waiting_for> who is still requested as a reviewer, logins
#   comma-separated, `-` when nobody or not known; <reviewed_at> UTC, when the
#   review was last asked of the forge, written only for a GitLab merge request
#   (whose review is one call each): housekeeping reuses a review for the same
#   head commit until that time is old, whatever <fetched_at> says. A line written before a column existed ends before it
#   and reads as if each missing one were `-`. Lines starting with `#` are
#   comments.
#
# The file lives in the runtime directory of the checkout that owns the task
# workspaces: a worktree that borrows the owner's `tasks/` (ADR-0029) reads the
# owner's file and never writes it, so one clone has one cache.
#
# Depends on `_task_borrowed_tasks_root` (lib/task.sh): a caller sources task.sh
# first, as for lib/hklog.sh.
# shellcheck shell=bash

# forgecache_file — the cache's path, in the owner's runtime directory when this
# checkout borrows its task workspaces.
forgecache_file() {
  local borrowed
  if borrowed=$(_task_borrowed_tasks_root); then
    printf '%s/runtime/forge-cache\n' "${borrowed%/workspace/tasks}"
    return 0
  fi
  printf '%s/%s/runtime/forge-cache\n' "$JIG_PROJECT" "$JIG_AI_DIR"
}

# forgecache_owned — exit 0 when this checkout keeps the cache it reads: not
# when it borrows the owner's task workspaces, whose housekeeping keeps the
# owner's cache. A writer asks before it asks the forge for anything.
forgecache_owned() {
  ! _task_borrowed_tasks_root >/dev/null
}

# forgecache_write <rows> — replace the cache with <rows>, atomically. Does
# nothing in a checkout that does not own its cache (forgecache_owned). Never
# fails the caller: a cache that could not be written is the old one, whose
# entries still say how old they are.
forgecache_write() {
  local rows="$1" file tmp
  forgecache_owned || return 0
  file=$(forgecache_file)
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  mkdir -p "${file%/*}" 2>/dev/null || return 0
  {
    printf '# jig forge cache: <head> <base> <state> <ci> <fetched_at> <head-commit> <url> <mergeable> <review> <waiting_for> [<reviewed_at>], written by jig housekeeping\n'
    [ -z "$rows" ] || printf '%s\n' "$rows"
  } > "$tmp" 2>/dev/null || return 0
  mv "$tmp" "$file" 2>/dev/null || return 0
  # `task list --json` reports what the cache holds, so a written cache raises
  # the clone's revision (adr-20261016-the-clone-revision-is-a-claimed-name).
  # housekeeping raises it again when its run ends; this one keeps any other
  # writer (forgecache_record) from forgetting.
  jig_record_changed
  return 0
}

# forgecache_record <head> <base> <state> <head-commit> <url> — put one pull
# request a command has just heard of at the top of the cache, in place of any
# line for the same <head> and <base>, every other line kept as it was: the
# newest is first, as the forge lists them. <ci> and <mergeable> are `-`, not
# asked, and so are <review> and <waiting_for>; <fetched_at> is now; <head-commit> or <url> that is empty or does not
# look like one is `-`. The next housekeeping run replaces the whole cache with
# what the forge says. Never fails the caller (forgecache_write).
forgecache_record() {
  local head="$1" base="$2" state="$3" sha="$4" url="$5" t at rest
  [ -n "$head" ] && [ -n "$base" ] || return 0
  case "$state" in open | merged | closed) ;; *) return 0 ;; esac
  case "$sha" in '' | *[!0-9a-f]*) sha="-" ;; esac
  case "$url" in '' | *[[:space:]]*) url="-" ;; esac
  t=$(printf '\t')
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  rest=$(forgecache_read | awk -F '\t' -v h="$head" -v b="$base" '!($1 == h && $2 == b)')
  forgecache_write "$head$t$base$t$state$t-$t$at$t$sha$t$url$t-$t-$t-${rest:+
$rest}"
}

# forgecache_read — the cache's lines, comments left out; nothing when there is
# no cache.
forgecache_read() {
  local file
  file=$(forgecache_file)
  [ -f "$file" ] || return 0
  sed '/^#/d;/^$/d' "$file" 2>/dev/null || true
}

# forgecache_entry <cache> <head> <base> — sets _FORGECACHE_STATE, _FORGECACHE_CI,
# _FORGECACHE_AT, _FORGECACHE_URL, _FORGECACHE_MERGEABLE, _FORGECACHE_REVIEW and
# _FORGECACHE_WAITING from the first line of <cache> (forgecache_read's output)
# for a pull request from <head> into <base>: the newest, as the forge lists
# them and as housekeeping's own remote state takes it. Each is empty when the
# cache does not say, _FORGECACHE_COMMIT (the head commit) too. When a line was
# found _FORGECACHE_HEAD and _FORGECACHE_BASE are set to its branches (empty otherwise), so a caller can tell a line that
# says nothing from no line. In the caller's shell, without a process per lookup.
_FORGECACHE_STATE=""
_FORGECACHE_CI=""
_FORGECACHE_AT=""
_FORGECACHE_URL=""
_FORGECACHE_MERGEABLE=""
_FORGECACHE_REVIEW=""
_FORGECACHE_WAITING=""
_FORGECACHE_REVIEWED_AT=""
_FORGECACHE_HEAD=""
_FORGECACHE_BASE=""
_FORGECACHE_COMMIT=""
_forgecache_clear() {
  _FORGECACHE_STATE=""
  _FORGECACHE_CI=""
  _FORGECACHE_AT=""
  _FORGECACHE_URL=""
  _FORGECACHE_MERGEABLE=""
  _FORGECACHE_REVIEW=""
  _FORGECACHE_WAITING=""
  _FORGECACHE_REVIEWED_AT=""
  _FORGECACHE_HEAD=""
  _FORGECACHE_BASE=""
  _FORGECACHE_COMMIT=""
}

# _forgecache_parse <line> — the columns of one cache line into the globals
# above, head and base included; a `-` is read as empty.
_forgecache_parse() {
  local t=$'\t'
  IFS="$t" read -r _FORGECACHE_HEAD _FORGECACHE_BASE _FORGECACHE_STATE _FORGECACHE_CI _FORGECACHE_AT _FORGECACHE_COMMIT _FORGECACHE_URL _FORGECACHE_MERGEABLE _FORGECACHE_REVIEW _FORGECACHE_WAITING _FORGECACHE_REVIEWED_AT _ <<EOF
$1
EOF
  [ "$_FORGECACHE_CI" != "-" ] || _FORGECACHE_CI=""
  [ "$_FORGECACHE_COMMIT" != "-" ] || _FORGECACHE_COMMIT=""
  [ "$_FORGECACHE_URL" != "-" ] || _FORGECACHE_URL=""
  [ "$_FORGECACHE_MERGEABLE" != "-" ] || _FORGECACHE_MERGEABLE=""
  [ "$_FORGECACHE_REVIEW" != "-" ] || _FORGECACHE_REVIEW=""
  [ "$_FORGECACHE_WAITING" != "-" ] || _FORGECACHE_WAITING=""
  [ "$_FORGECACHE_REVIEWED_AT" != "-" ] || _FORGECACHE_REVIEWED_AT=""
  return 0
}

forgecache_entry() {
  local cache="$1" head="$2" base="$3" t nl rest line
  _forgecache_clear
  [ -n "$cache" ] && [ -n "$head" ] && [ -n "$base" ] || return 0
  t=$'\t'
  nl=$'\n'
  rest=${nl}${cache}
  case "$rest" in
    *"$nl$head$t$base$t"*) ;;
    *) return 0 ;;
  esac
  rest=${rest#*"$nl$head$t$base$t"}
  line=${rest%%"$nl"*}
  _forgecache_parse "$head$t$base$t$line"
  return 0
}

# forgecache_entry_url <cache> <url> — the same globals, from the first line of
# <cache> whose url column is <url>: a pull request found by its address,
# whatever branches it runs between; _FORGECACHE_HEAD and _FORGECACHE_BASE say
# which. Everything is empty when the cache has no such line. In the caller's
# shell, without a process per lookup.
forgecache_entry_url() {
  local cache="$1" url="$2" t nl rest before after
  _forgecache_clear
  if [ -z "$cache" ] || [ -z "$url" ] || [ "$url" = "-" ]; then
    return 0
  fi
  t=$'\t'
  nl=$'\n'
  rest=${nl}${cache}${nl}
  while :; do
    case "$rest" in
      *"$t$url$t"* | *"$t$url$nl"*) ;;
      *) return 0 ;;
    esac
    before=${rest%%"$t$url"*}
    after=${rest#"$before$t$url"}
    case "$after" in
      "$t"* | "$nl"*) break ;;
    esac
    # Only the front of a longer address (.../pull/1 of .../pull/12): go on.
    rest=$after
  done
  _forgecache_parse "${before##*"$nl"}$t$url${after%%"$nl"*}"
  return 0
}

# forgecache_upgrades <cache> <base> — the pull requests of Jig's own upgrade
# branches (`jig/upgrade-*`) into <base>, from <cache> (forgecache_read's
# output), the newest of each branch only, one line each:
#   <head><TAB><state><TAB><fetched_at><TAB><url>
# <url> is `-` when the cache does not know it. `jig status` reads an upgrade
# still waiting for its merge from this.
forgecache_upgrades() {
  [ -n "$1" ] && [ -n "$2" ] || return 0
  printf '%s\n' "$1" | awk -F '\t' -v base="$2" '
    $2 == base && index($1, "jig/upgrade-") == 1 && length($1) > 12 && !($1 in seen) {
      seen[$1] = 1
      u = $7
      if (u == "") u = "-"
      print $1 "\t" $3 "\t" $5 "\t" u
    }'
}
