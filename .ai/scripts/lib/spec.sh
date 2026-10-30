# cmd_spec — specifications under .ai/specs/<id>/ (the jig-idea skill).
# Sourced by scripts/jig; defines cmd_spec.
#
# A specification is a plan, not knowledge: it lives outside .ai/knowledge/,
# carries no status, and everything reported here is derived from its files —
# the first heading of spec.md and the checkboxes of roadmap.md (ADR-0035).
#
# A task links to a spec through one `Spec: .ai/specs/<id>/ — Phase <n>` line in
# its task.md. `new` creates a spec, `done` checks a linked task's roadmap
# items, `drop` closes the items of an abandoned or moved one, `link` writes a filed task's `Spec:` line, `remove` unlinks a spec's open tasks and moves the spec to trash,
# `stop` records a phase run's stop by sending it to the person's Telegram,
# `close` removes a spec whose roadmap is complete, `epic` declares, cuts,
# finishes and reopens a spec's epic branch (ADR-0035, ADR-0040 as amended),
# and `ship` carries a declaration, an epic or an epic's final pull request as
# far as `agent.git` allows (adr-20260922-spec-work-ships-by-the-agent-git-level);
# `list` only reads.
# shellcheck shell=bash

SPEC_USAGE="usage: jig spec new <id> | jig spec resume <id> | jig spec list [--json] | jig spec plan <id> --phase <n> [--format text|tsv] | jig spec stop <id> --phase <n> --reason <text> | jig spec done <task-id> | jig spec drop <task-id> | jig spec link <spec-id> <task-id> | jig spec close <id> [--leftovers-handled] | jig spec remove <id> [--dry-run] [--abandon-unstarted] | jig spec epic <id> [--release patch|minor|major | --finish [--leftovers-handled] | --reopen] | jig spec ship <id> [--message-file <file>] [--title <t>] [--body-file <file>]"

cmd_spec() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    # A command that changes a spec redraws the status page, whose progress
    # by phase it feeds (jig_status_page_touch, common.sh).
    new) spec_new "$@"; jig_status_page_touch ;;
    resume) spec_resume "$@"; jig_status_page_touch ;;
    list) spec_list "$@" ;;
    plan) spec_plan "$@" ;;
    stop) spec_stop "$@" ;;
    done) spec_done "$@"; jig_status_page_touch ;;
    drop) spec_drop "$@"; jig_status_page_touch ;;
    link) spec_link "$@" ;;
    remove) spec_remove "$@"; jig_status_page_touch ;;
    close) spec_close "$@"; jig_status_page_touch ;;
    epic) spec_epic "$@"; jig_status_page_touch ;;
    # Ships through git only; the spec's files are as `epic` left them.
    ship) spec_ship "$@" ;;
    help | -h | --help)
      printf '%s\n' "$SPEC_USAGE" >&2
      return 0
      ;;
    '')
      printf '%s\n' "$SPEC_USAGE" >&2
      exit 1
      ;;
    *) jig_die "spec: unknown subcommand: $sub ($SPEC_USAGE)" ;;
  esac
}

# spec_template <file> — the template to instantiate: the copy installed under
# .ai/templates/spec/ first, the framework checkout as a fallback for a
# project initialised before spec templates were installed (as km_template).
spec_template() {
  local installed src
  installed="$JIG_PROJECT/$JIG_AI_DIR/templates/spec/$1"
  if [ -f "$installed" ]; then
    printf '%s\n' "$installed"
    return 0
  fi
  src=$(jig_source_root)
  if [ -n "$src" ] && [ -f "$src/templates/spec/$1" ]; then
    printf '%s\n' "$src/templates/spec/$1"
    return 0
  fi
  return 1
}

# _spec_cut_own_branch <id> <cmd> — switch to a fresh `spec/<id>`, branched
# from HEAD, refusing a name git rejects or one that already exists (reusing
# it would attach this spec to whatever that branch already holds — the same
# reasoning `_task_branch_name` uses for a task's branch). <cmd> names the
# caller in every message; prints the branch name once switched. The one
# mechanic `spec new`, `spec resume` and `spec ship`'s declaration share,
# so cutting a spec's branch cannot read three different ways
# (idea-leaves-a-tree-task-start-refuses).
_spec_cut_own_branch() {
  local id="$1" cmd="$2" prefix="${3:-spec}" branch
  branch="$prefix/$id"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || jig_die "$cmd: git rejects the branch name: $branch"
  if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    jig_die "$cmd: $branch exists already; switch to it and run again"
  fi
  git -C "$JIG_PROJECT" switch --quiet -c "$branch" >/dev/null 2>&1 \
    || jig_die "$cmd: could not switch to a new branch $branch"
  printf '%s\n' "$branch"
}

# _spec_switch_to_existing_branch <id> <cmd> — switch to `spec/<id>` when it
# already exists, locally or on origin (fetched fresh first); nothing, and
# exit 1, when it exists nowhere. Used by `spec resume`, where a spec's
# branch from an earlier session may already be there, unlike `spec new`
# and `spec ship`'s declaration, which only ever create one.
_spec_switch_to_existing_branch() {
  local id="$1" cmd="$2" branch
  branch="spec/$id"
  if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
    git -C "$JIG_PROJECT" switch --quiet "$branch" >/dev/null 2>&1 \
      || jig_die "$cmd: could not switch to $branch"
    printf '%s\n' "$branch"
    return 0
  fi
  jig_fetch_branches "$cmd" "$branch" 2>/dev/null
  if git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    git -C "$JIG_PROJECT" switch --quiet -c "$branch" --track "origin/$branch" >/dev/null 2>&1 \
      || jig_die "$cmd: could not switch to origin/$branch"
    printf '%s\n' "$branch"
    return 0
  fi
  return 1
}

# _spec_refuse_dirty_tree <cmd> — refuse a dirty tree by the same rule
# `task start` uses (jig_tracked_changes, common.sh): a tracked change would
# ride onto the spec's own branch as part of its first commit. No worktree
# escape here, unlike a task's: a spec has none.
_spec_refuse_dirty_tree() {
  local cmd="$1" tracked
  tracked=$(jig_tracked_changes)
  [ -n "$tracked" ] \
    || return 0
  jig_die "$cmd: uncommitted changes in the working tree; commit or stash them yourself, then run \`$cmd\` again"
}

# _spec_require_default_branch <cmd> <default> — HEAD must be <default> and
# resolved (not detached); a spec starts, or resumes, from there so that its
# own branch is cut at a point every clone agrees on.
_spec_require_default_branch() {
  local cmd="$1" default="$2" here
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$here" ] || jig_die "$cmd: HEAD is detached; switch to $default first"
  [ "$here" = "$default" ] || jig_die "$cmd: switch to $default first; a spec starts, or resumes, from there"
}

# spec_new <id> — create .ai/specs/<id>/ with spec.md and roadmap.md from the
# templates, then switch to a branch of its own (`spec/<id>`): the same
# reasoning that puts a task on its own branch, from the first minute
# (idea-leaves-a-tree-task-start-refuses). The id is validated here, at the
# one place the path is built: a directory with an invalid name would be
# skipped by every listing, so a spec created under one would silently not
# exist.
spec_new() {
  [ $# -ge 1 ] || jig_die "spec new: missing spec id (usage: jig spec new <id>)"
  [ $# -eq 1 ] || jig_die "spec new: unexpected argument: $2"
  local id="$1" root dir spec_tpl roadmap_tpl default branch
  spec_valid_id "$id" \
    || jig_die "spec new: invalid spec id: $id (letters, digits, '.', '_', '-'; no leading dot or dash)"
  jig_require_init
  default=$(cfg git.base_branch main)
  _spec_require_default_branch "spec new" "$default"
  _spec_refuse_dirty_tree "spec new"
  # Both templates are resolved before anything is created, so a missing one
  # leaves no empty directory behind.
  spec_tpl=$(spec_template spec.md) \
    || jig_die "spec new: no template spec.md; run: jig upgrade"
  roadmap_tpl=$(spec_template roadmap.md) \
    || jig_die "spec new: no template roadmap.md; run: jig upgrade"
  root=$(spec_dir)
  dir="$root/$id"
  [ ! -e "$dir" ] || jig_die "spec new: spec already exists: $JIG_AI_DIR/specs/$id"
  mkdir -p "$root" || jig_die "spec new: cannot create $JIG_AI_DIR/specs"
  # A plain mkdir refuses a directory that appeared since the test above; the
  # claim on the id is spec.md below (adr-20261023-a-claim-is-an-exclusive-create).
  mkdir "$dir" 2>/dev/null || jig_die "spec new: spec already exists: $JIG_AI_DIR/specs/$id"
  # Both files are written under temporary names first, so a failed copy
  # leaves nothing half-created and a retry works. The cleanup removes only
  # the files this run named and then `rmdir`s the directory, which refuses
  # anything that is not empty — it cannot delete what someone else put there.
  jig_cleanup_add "$dir/spec.md.tmp.$$"
  jig_cleanup_add "$dir/roadmap.md.tmp.$$"
  if ! cp "$spec_tpl" "$dir/spec.md.tmp.$$" || ! cp "$roadmap_tpl" "$dir/roadmap.md.tmp.$$"; then
    rm -f "$dir/spec.md.tmp.$$" "$dir/roadmap.md.tmp.$$"
    rmdir "$dir" 2>/dev/null || true
    jig_die "spec new: could not copy the templates into $JIG_AI_DIR/specs/$id"
  fi
  # spec.md is the claim on the id: the directory alone is not, since `mkdir`
  # does not exclude a second maker everywhere
  # (adr-20261023-a-claim-is-an-exclusive-create).
  # Claimed empty, then replaced whole by the rename.
  if ! jig_claim_file "$dir/spec.md"; then
    rm -f "$dir/spec.md.tmp.$$" "$dir/roadmap.md.tmp.$$"
    jig_die "spec new: spec already exists: $JIG_AI_DIR/specs/$id"
  fi
  mv "$dir/spec.md.tmp.$$" "$dir/spec.md" || jig_die "spec new: could not write $JIG_AI_DIR/specs/$id/spec.md"
  jig_record_changed
  printf '%s/specs/%s/spec.md\n' "$JIG_AI_DIR" "$id"
  mv "$dir/roadmap.md.tmp.$$" "$dir/roadmap.md" || jig_die "spec new: could not write $JIG_AI_DIR/specs/$id/roadmap.md"
  jig_record_changed
  printf '%s/specs/%s/roadmap.md\n' "$JIG_AI_DIR" "$id"
  branch=$(_spec_cut_own_branch "$id" "spec new") || exit 1
  printf 'switched to %s\n' "$branch"
}

# spec_resume <id> — before a second session edits an existing spec, put it
# back on its own branch: the same dirty-tree refusal `spec new` uses, then a
# switch to `spec/<id>` (created if this is its first resume, reused if an
# earlier one already cut it, fetched from origin if only that has it).
# `jig-idea` calls this before touching an existing spec's files, so the
# roadmap `jig spec new` files tasks into (step 10, jig-idea) is edited on
# the branch too, never straight on the default one
# (idea-leaves-a-tree-task-start-refuses).
#
# A spec with an open epic is edited on the epic instead (jig-idea says so);
# resuming it here would cut a `spec/<id>` nothing ever ships, so it refuses.
spec_resume() {
  [ $# -ge 1 ] || jig_die "spec resume: missing spec id (usage: jig spec resume <id>)"
  [ $# -eq 1 ] || jig_die "spec resume: unexpected argument: $2"
  local id="$1" dir roadmap default here branch line rc=0
  spec_valid_id "$id" || jig_die "spec resume: invalid spec id: $id"
  jig_require_init
  dir="$(spec_dir)/$id"
  [ -d "$dir" ] || jig_die "spec resume: no such spec: $JIG_AI_DIR/specs/$id"
  roadmap="$dir/roadmap.md"
  if [ -f "$roadmap" ]; then
    line=$(jig_spec_epic "$roadmap") || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$line" ] && [ "${line##* }" = open ]; then
      jig_die "spec resume: $JIG_AI_DIR/specs/$id/roadmap.md declares an open epic (${line% *}); edit it there instead — switch to ${line% *} first"
    fi
  fi
  default=$(cfg git.base_branch main)
  branch="spec/$id"
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ "$here" = "$branch" ]; then
    printf 'already on %s\n' "$branch"
    return 0
  fi
  _spec_require_default_branch "spec resume" "$default"
  _spec_refuse_dirty_tree "spec resume"
  branch=$(_spec_switch_to_existing_branch "$id" "spec resume") || branch=""
  if [ -z "$branch" ]; then
    branch=$(_spec_cut_own_branch "$id" "spec resume") || exit 1
  fi
  printf 'switched to %s\n' "$branch"
}

spec_dir() {
  printf '%s/%s/specs\n' "$JIG_PROJECT" "$JIG_AI_DIR"
}

# spec_valid_id <id> — the same grammar as a task id, from the one place both
# read it (common.sh, jig_valid_id).
spec_valid_id() {
  jig_valid_id "$1"
}

# spec_ids — valid spec ids, one per line, in directory order. A directory
# whose name is not a valid id is skipped rather than reported: nothing can
# address it by id.
spec_ids() {
  local root d id
  root=$(spec_dir)
  [ -d "$root" ] || return 0
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    d=${d%/}
    id=${d##*/}
    spec_valid_id "$id" || continue
    printf '%s\n' "$id"
  done
}

spec_count() {
  spec_ids | grep -c . || true
}

# spec_title <spec.md> — the text of the first level-one heading, or empty.
spec_title() {
  sed -n 's/^#[[:space:]]\{1,\}//p' "$1" | head -n 1
}

# spec_progress <roadmap.md> — "roadmap D/T done, F filed, fog G": the sum of
# spec_phase_counts, so the whole and its phases cannot disagree.
spec_progress() {
  spec_phase_counts "$1" | awk -F '\t' '
    { done += $3; total += $4; filed += $5; fog += $6 }
    END { printf "roadmap %d/%d done, %d filed, fog %d\n", done, total, filed, fog }
  '
}

# spec_phase_counts <roadmap.md|-> — the roadmap counted by section, one
# `<phase>\t<title>\t<done>\t<total>\t<filed>\t<fog>` line each. The one place
# the counting rules for roadmap lines live (schemas/spec.md).
#
# An item is a checkbox line. Done is a checked one, or an unchecked one whose
# task is known to have merged (spec_merged_task_ids — the rule `spec plan`
# reads too): in a phase run the coordinator's checkmarks reach the epic's
# remote only with the next pull request, and the work they mark is already
# there. Filed is an unchecked item whose text starts with a backticked task id
# followed by a dash — the id alone is not enough, because an item may just as
# well open with a backticked command name — and whose task has not merged. Fog
# is an unchecked item whose text starts with `fog:`. Wave lines are a numbered
# list, not checkboxes, so they are never counted.
#
# A `## Phase <n> — <title>` heading opens phase <n>, listed even while it has
# no items. Items under any other `##` heading, or before the first one, are
# counted under `-` with that heading as their title (`-` when there is
# none), and listed only when there are some: every item is counted exactly
# once, which is what keeps spec_progress's sum equal to the old total.
#
# With `items` as the second argument (spec_phase_items) each counted item is
# also printed, before the line of its section, as
# `item\t<checked 0|1>\t<done 0|1>\t=<task-id>\t<fog 0|1>\t<text>`, `=` alone for
# no task id — a mark no id can be, since `-` is one the pattern takes: <done> is
# what the item counted as, the task id and the
# fog mark by the same patterns the counts use, read from checked items too,
# and the text as written after the checkbox, its indented continuation lines
# joined with a space. Without it the output is the counts alone.
spec_phase_counts() {
  local items=0 merged
  [ "${2:-}" != items ] || items=1
  merged=" $(spec_merged_task_ids | cut -f1 | tr '\n' ' ') "
  # The set reaches awk through the environment: a `-v` value has its escapes
  # expanded.
  JIG_SP_MERGED="$merged" awk -v items="$items" '
    function reset() { done = 0; total = 0; filed = 0; fog = 0 }
    function flush() {
      if (phase != "-" || total > 0)
        printf "%s\t%s\t%d\t%d\t%d\t%d\n", phase, (title == "" ? "-" : title), done, total, filed, fog
    }
    function emit() {
      if (!pending) return
      gsub(/\t/, " ", itext)
      sub(/[[:space:]]+$/, "", itext)
      printf "item\t%d\t%d\t=%s\t%d\t%s\n", ichecked, idone, itid, ifog, itext
      pending = 0
    }
    BEGIN { phase = "-"; title = ""; reset(); pending = 0; merged = ENVIRON["JIG_SP_MERGED"] }
    /^##[[:space:]]/ {
      emit(); flush(); reset()
      h = $0
      sub(/^##[[:space:]]+/, "", h)
      gsub(/\t/, " ", h)
      if (h ~ /^Phase[[:space:]]+[0-9]+/) {
        sub(/^Phase[[:space:]]+/, "", h)
        phase = h
        sub(/[^0-9].*$/, "", phase)
        sub(/^[0-9]+[[:space:]]*/, "", h)
        sub(/^(—|--|-|:)[[:space:]]*/, "", h)
      } else {
        phase = "-"
      }
      title = h
      next
    }
    /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/ {
      emit()
      total++
      checked = ($0 ~ /\[[xX]\]/) ? 1 : 0
      text = $0
      sub(/^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/, "", text)
      tid = ""; isfog = 0
      # "—" is matched as its UTF-8 bytes, which every awk compares as-is.
      if (text ~ /^`[A-Za-z0-9._-]+`[[:space:]]+(—|-|--)[[:space:]]/) {
        tid = substr(text, 2); sub(/`.*$/, "", tid)
      } else if (text ~ /^fog:/) isfog = 1
      # Ids are compared as strings: index(), never a pattern a `.` in an id
      # would widen.
      isdone = checked || (tid != "" && index(merged, " " tid " ") > 0)
      if (isdone) done++
      else if (tid != "") filed++
      else if (isfog) fog++
      if (items == 1) { pending = 1; ichecked = checked; idone = isdone; itid = tid; ifog = isfog; itext = text }
      next
    }
    pending && /^[[:space:]]+[^[:space:]]/ {
      t = $0
      sub(/^[[:space:]]+/, "", t)
      sub(/[[:space:]]+$/, "", itext)
      itext = itext " " t
      next
    }
    { emit() }
    END { emit(); flush() }
  ' "$1"
}

# spec_phase_items <roadmap.md|-> — spec_phase_counts with every item printed
# before its section's line: the items and their counts from one pass, so the
# two cannot disagree.
spec_phase_items() {
  spec_phase_counts "$1" items
}

# spec_phase_rows — every spec's progress by phase for the status page, one
# `<spec-id>\t<phase>\t<title>\t<done>\t<total>\t<filed>\t<fog>\t<source>` row
# per spec_phase_counts line, unformatted (ARCHITECTURE.md, Scripts layout).
# <source> is empty when the roadmap is this checkout's. A spec with an open
# epic that is not checked out here is read from the epic's ref — progress is
# made there (ADR-0040) — with no fetch, and <source> names the branch and
# whether the ref is the remote's as of the last fetch; with no ref at all it
# has no rows, and spec_list_rows already says `branch missing`.
spec_phase_rows() {
  local root id roadmap loc ref source _SPEC_MERGED_MEMO _SPEC_MERGED
  root=$(spec_dir)
  _spec_merged_memo
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    roadmap="$root/$id/roadmap.md"
    [ -f "$roadmap" ] || continue
    loc=$(spec_roadmap_ref "$id") || continue
    if [ -n "$loc" ]; then
      IFS=$'\t' read -r ref source <<EOF
$loc
EOF
      jig_git_show_path "$ref" "$JIG_AI_DIR/specs/$id/roadmap.md" 2>/dev/null \
        | spec_phase_counts - | _spec_phase_prefix "$id" "$source" || true
      continue
    fi
    spec_phase_counts "$roadmap" | _spec_phase_prefix "$id" ""
  done < <(spec_ids)
}

# spec_roadmap_ref <spec-id> — where the current roadmap of a spec is read.
# Nothing when this checkout's copy is current: no epic, a finished one, or the
# epic is checked out here. "<ref>\t<source>" when an open epic elsewhere holds
# it — progress is made there (ADR-0040) — read with no fetch; <source> names
# the branch and whether the ref is the remote's as of the last fetch. Exit 1
# when that epic has no ref here at all, 2 when git rejects its name — no
# fetch can bring that one. The one place both the status page
# (spec_phase_rows) and `spec plan` decide it, so they cannot disagree.
spec_roadmap_ref() {
  local roadmap line branch here ref
  roadmap="$(spec_dir)/$1/roadmap.md"
  line=$(jig_spec_epic "$roadmap" 2>/dev/null) || line=""
  [ -n "$line" ] || return 0
  [ "${line##* }" != finished ] || return 0
  branch=${line% *}
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$branch" != "$here" ] || return 0
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 2
  ref=$(jig_base_ref "$branch")
  [ -n "$ref" ] || return 1
  case "$ref" in
    refs/remotes/*) printf '%s\t%s as of the last fetch\n' "$ref" "$branch" ;;
    *) printf '%s\t%s\n' "$ref" "$branch" ;;
  esac
}

# _spec_phase_prefix <id> <source> — frame spec_phase_counts lines as rows.
# Values reach awk through the environment: a `-v` value has its escapes
# expanded.
_spec_phase_prefix() {
  JIG_SP_ID="$1" JIG_SP_SOURCE="$2" awk '{ printf "%s\t%s\t%s\n", ENVIRON["JIG_SP_ID"], $0, ENVIRON["JIG_SP_SOURCE"] }'
}

# spec_list — `jig spec list`: one aligned line per spec, from spec_list_rows.
# `--json` anywhere asks for the same specs as data, in the envelope
# (lib/json.sh). It is looked for before anything else runs, so that a refusal
# — an unexpected argument, a checkout outside git — is an envelope too.
spec_list() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _spec_list_json "$@"
      return
    fi
  done
  [ $# -eq 0 ] || jig_fail usage "spec list: unexpected argument: $1"
  jig_require_repo
  local rows
  rows=$(spec_list_rows)
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | awk -F '\t' '
    { id[NR] = $1; t[NR] = $2; s[NR] = $3
      if (length($1) > wi) wi = length($1)
      if (length($2) > wt) wt = length($2) }
    # The width is spliced into the format, not passed as `*`: not every awk
    # on a supported machine takes a dynamic width.
    END { fmt = "%-" wi "s   %-" wt "s   %s\n"
          for (i = 1; i <= NR; i++) printf fmt, id[i], t[i], s[i] }
  '
}

# _spec_list_json [--json] — the producer of `jig spec list --json`
# (schemas/json.md): `{"specs":[...]}`, one object per spec in spec_ids order.
# Every value is read from what already answers it — spec_title, jig_spec_epic,
# spec_roadmap_ref (where the current roadmap is, as the status page reads it),
# spec_phase_items (the counts of spec_phase_counts with their items) and
# spec_release_check. Local refs only: no fetch, no forge.
_spec_list_json() {
  local arg root id dir title missing line branch state here checked_out
  local loc rc ref src content release epic phases progress
  local _SPEC_MERGED_MEMO _SPEC_MERGED
  for arg in "$@"; do
    [ "$arg" = --json ] || jig_fail usage "spec list: unexpected argument: $arg"
  done
  jig_require_repo
  root=$(spec_dir)
  _spec_merged_memo
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  printf '{"specs":['
  local sep=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    dir="$root/$id"
    title="" missing=""
    if [ -f "$dir/spec.md" ]; then
      title=$(spec_title "$dir/spec.md")
    else
      missing='"spec.md"'
    fi
    [ -f "$dir/roadmap.md" ] || missing="${missing:+$missing,}\"roadmap.md\""
    epic=null phases="[]" progress=null release=""
    if [ -f "$dir/roadmap.md" ]; then
      line=$(jig_spec_epic "$dir/roadmap.md" 2>/dev/null) || line=""
      rc=0
      loc=$(spec_roadmap_ref "$id") || rc=$?
      ref="" src="$dir/roadmap.md" content=""
      if [ "$rc" -eq 0 ] && [ -n "$loc" ]; then
        ref=${loc%%$'\t'*}
        src=""
        content=$(jig_git_show_path "$ref" "$JIG_AI_DIR/specs/$id/roadmap.md" 2>/dev/null) || content=""
      fi
      if [ -n "$line" ]; then
        branch=${line% *}
        state=${line##* }
        checked_out=false
        if [ "$state" = open ] && [ "$branch" = "$here" ]; then checked_out=true; fi
        json_quote "$branch"
        epic="{\"branch\":$_JSON,\"state\":\"$state\",\"checked_out\":$checked_out"
        if [ "$rc" -ne 0 ]; then epic="$epic,\"missing\":true"; else epic="$epic,\"missing\":false"; fi
        json_str_or_null "$ref"
        epic="$epic,\"ref\":$_JSON}"
      fi
      if [ -n "$src" ]; then
        release=$(spec_release_check "spec list" "$JIG_AI_DIR/specs/$id/roadmap.md" < "$src" 2>/dev/null) || release=""
      elif [ -n "$content" ]; then
        release=$(spec_release_check "spec list" "$ref" 2>/dev/null <<<"$content") || release=""
      fi
      if [ "$rc" -eq 0 ] && [ -n "$src" ]; then
        _spec_json_phases < <(spec_phase_items "$src")
        phases=$_SPEC_JSON_PHASES progress=$_SPEC_JSON_PROGRESS
      elif [ "$rc" -eq 0 ] && [ -n "$content" ]; then
        _spec_json_phases < <(spec_phase_items - <<<"$content")
        phases=$_SPEC_JSON_PHASES progress=$_SPEC_JSON_PROGRESS
      fi
    fi
    json_quote "$id"
    printf '%s{"id":%s' "$sep" "$_JSON"
    json_str_or_null "$title"
    printf ',"title":%s,"missing_files":[%s]' "$_JSON" "$missing"
    json_str_or_null "$release"
    printf ',"release":%s,"epic":%s' "$_JSON" "$epic"
    printf ',"progress":%s,"phases":%s}' "$progress" "$phases"
    sep=","
  done < <(spec_ids)
  printf ']}\n'
}

# _spec_json_phases — spec_phase_items rows on stdin, as JSON in two globals:
# _SPEC_JSON_PHASES, the array of phases with their items, and
# _SPEC_JSON_PROGRESS, their sum — the sum spec_progress prints, so the spec's
# total and its phases cannot disagree. Globals, not stdout: the caller reads
# both without a subshell per value.
_SPEC_JSON_PHASES="[]"
_SPEC_JSON_PROGRESS=null
_spec_json_phases() {
  local f1 f2 f3 f4 f5 f6 items="" isep="" out="" psep="" num
  local sd=0 st=0 sf=0 sg=0
  while IFS=$'\t' read -r f1 f2 f3 f4 f5 f6; do
    if [ "$f1" = item ]; then
      # f2 checked, f3 done, f4 `=` and the task id, f5 fog, f6 the text (no
      # tab in it).
      json_quote "$f6"
      items="$items$isep{\"text\":$_JSON"
      if [ "$f2" = 1 ]; then items="$items,\"checked\":true"; else items="$items,\"checked\":false"; fi
      if [ "$f3" = 1 ]; then items="$items,\"done\":true"; else items="$items,\"done\":false"; fi
      if [ "$f4" = = ]; then _JSON=null; else json_quote "${f4#=}"; fi
      items="$items,\"task\":$_JSON"
      if [ "$f5" = 1 ]; then items="$items,\"fog\":true}"; else items="$items,\"fog\":false}"; fi
      isep=","
      continue
    fi
    json_int_or_null "$f1"
    num=$_JSON
    # A CRLF roadmap leaves its CR on a heading; the data carries the title.
    f2=${f2%$'\r'}
    if [ "$f2" = - ]; then _JSON=null; else json_quote "$f2"; fi
    out="$out$psep{\"phase\":$num,\"title\":$_JSON,\"done\":$f3,\"total\":$f4,\"filed\":$f5,\"fog\":$f6,\"items\":[$items]}"
    psep=","
    items="" isep=""
    sd=$((sd + f3)) st=$((st + f4)) sf=$((sf + f5)) sg=$((sg + f6))
  done
  _SPEC_JSON_PHASES="[$out]"
  _SPEC_JSON_PROGRESS="{\"done\":$sd,\"total\":$st,\"filed\":$sf,\"fog\":$sg}"
}

# spec_list_rows — what `spec list` answers, one "<id><TAB><title><TAB><state>"
# row per spec, unformatted. `jig spec list` aligns it; `jig status --html`
# renders it (ARCHITECTURE.md, Scripts layout: a reporting command consumes a
# peer's answer, never recomputes it).
spec_list_rows() {
  local root id title state missing _SPEC_MERGED_MEMO _SPEC_MERGED
  root=$(spec_dir)
  _spec_merged_memo
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    title="" missing=""
    if [ -f "$root/$id/spec.md" ]; then
      title=$(spec_title "$root/$id/spec.md")
    else
      missing="spec.md"
    fi
    [ -f "$root/$id/roadmap.md" ] || missing="${missing:+$missing, }roadmap.md"
    if [ -n "$missing" ]; then
      state="incomplete (no $missing)"
    else
      state=$(spec_list_state "$root/$id/roadmap.md")
    fi
    [ -n "$title" ] || title="-"
    # A tab cannot occur in any field: ids exclude it, and a heading is one
    # line whose tabs are folded to spaces here.
    title=$(printf '%s' "$title" | tr '\t' ' ')
    printf '%s\t%s\t%s\n' "$id" "$title" "$state"
  done < <(spec_ids)
}

# spec_list_state <roadmap.md> — what `spec list` says about a spec's progress.
#
# The roadmap of a spec with an open epic is edited only on the epic, so its
# copy anywhere else is stale by design: off the epic the line names where
# progress is instead of showing old checkmarks as current. A finished epic's
# roadmap reaches the default branch with the epic, current again (ADR-0040).
spec_list_state() {
  local roadmap="$1" line branch here
  line=$(jig_spec_epic "$roadmap" 2>/dev/null) || line=""
  if [ -z "$line" ] || [ "${line##* }" = finished ]; then
    spec_progress "$roadmap"
    return 0
  fi
  branch=${line% *}
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [ "$here" = "$branch" ]; then
    printf '%s (on %s)\n' "$(spec_progress "$roadmap")" "$branch"
  elif ! git check-ref-format --branch "$branch" >/dev/null 2>&1 \
       || [ -z "$(jig_base_ref "$branch")" ]; then
    printf '%s — branch missing\n' "$branch"
  else
    printf '%s — progress is on the epic\n' "$branch"
  fi
}

# spec_epic_status — one line per spec with an open epic, for `jig status`:
# where its work is, and how far the epic has fallen behind the default
# branch it is kept current with by merging (ADR-0040). Read-only; the refs
# are whatever this checkout last fetched.
spec_epic_status() {
  local root id line branch default base_ref epic_ref behind
  root=$(spec_dir)
  default=$(cfg git.base_branch main)
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -f "$root/$id/roadmap.md" ] || continue
    line=$(jig_spec_epic "$root/$id/roadmap.md" 2>/dev/null) || continue
    [ -n "$line" ] || continue
    [ "${line##* }" = open ] || continue
    branch=${line% *}
    epic_ref=""
    if git check-ref-format --branch "$branch" >/dev/null 2>&1; then
      epic_ref=$(jig_base_ref "$branch")
    fi
    if [ -z "$epic_ref" ]; then
      printf 'epic: %s on %s, branch missing\n' "$id" "$branch"
      continue
    fi
    base_ref=$(jig_base_ref "$default")
    if [ -z "$base_ref" ]; then
      printf 'epic: %s on %s\n' "$id" "$branch"
      continue
    fi
    behind=$(git -C "$JIG_PROJECT" rev-list --count "$epic_ref..$base_ref" 2>/dev/null) || behind=""
    if [ -n "$behind" ]; then
      printf 'epic: %s on %s, %s commits behind %s\n' "$id" "$branch" "$behind" "$default"
    else
      printf 'epic: %s on %s\n' "$id" "$branch"
    fi
  done < <(spec_ids)
}

# --- phase plan ------------------------------------------------------------------

# spec_plan <id> --phase <n> [--format text|tsv] — which tasks of a roadmap
# phase may start now, for a phase run and the person watching it.
#
# A phase run follows the waves strictly: wave N starts only once every item
# of every earlier wave has merged, whichever phase the item belongs to — the
# waves are one numbered list over the whole roadmap, and `after:` is prose
# nobody parses. Read-only and offline: the roadmap from where
# spec_roadmap_ref says it is current, each filed item's task from its
# workspace `state` (spec_task_state), and whether its work merged only from
# what is already answered — a checked item, a closed task (ADR-0030 closes a
# task only after its change landed), or `remote=merged` in the newest run of
# the housekeeping log. No fetch, no forge call.
#
# `--format tsv` is the machine form a coordinator reads, one row per line:
#   parallel <limit> <building>
#   wave    <n> <merged|open|waiting>
#   item    <wave|-> <task-id|-> <state> <merged> <paused> <autopilot> <next> <title>
#   blocker <wave> <task-id|-> <state> <title>
#   problem <wave|-> <unmatched|ambiguous|repeated> <wave entry>
# The `parallel` row comes first; each `wave` row is followed by its items;
# items of the phase in no wave come after the waves, then the unmerged items
# of earlier waves that hold the phase's first waiting wave, then every problem
# of the waves list.
#
# `parallel` answers how many more tasks of the open wave a coordinator may
# start: <limit> is `autopilot.parallel` and <building> counts the open wave's
# tasks an agent is still building (run `on`, knowledge not consolidated).
# Plan answers "what may start now", and the limit is part of that answer, so
# no reader of it counts slots itself. An `autopilot.parallel` no reader
# understands answers 1 here — the safest count a report can name without
# refusing to report. `jig config set` never writes such a value, so only a
# hand-edited local file can hold one, and `jig status`'s `config.local:`
# line shows it as it stands.
# <state>: not-filed, fog, no-workspace, not-started, active, ready,
# consolidated, abandoned, archived, done (checked, no workspace here). <merged>: roadmap,
# closed, housekeeping or no. <next>: start, running, file, fog, find,
# abandoned, unarchive, wait, unscheduled, done.
spec_plan() {
  local id="" phase="" format=text
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)
        [ $# -ge 2 ] || jig_die "spec plan: --phase requires a value"
        phase="$2"
        shift 2
        ;;
      --format)
        [ $# -ge 2 ] || jig_die "spec plan: --format requires a value"
        format="$2"
        shift 2
        ;;
      -*) jig_die "spec plan: unknown argument: $1" ;;
      *)
        [ -z "$id" ] || jig_die "spec plan: unexpected argument: $1"
        id="$1"
        shift
        ;;
    esac
  done
  [ -n "$id" ] || jig_die "spec plan: missing spec id (usage: jig spec plan <id> --phase <n> [--format text|tsv])"
  spec_valid_id "$id" || jig_die "spec plan: invalid spec id: $id"
  [ -n "$phase" ] || jig_die "spec plan: missing --phase <n>"
  case "$phase" in
    *[!0-9]*) jig_die "spec plan: --phase takes a phase number: $phase" ;;
  esac
  case "$format" in
    text | tsv) ;;
    *) jig_die "spec plan: --format is text or tsv: $format" ;;
  esac
  jig_require_init

  local roadmap rel loc ref="" source text parsed epic
  roadmap="$(spec_dir)/$id/roadmap.md"
  rel="$JIG_AI_DIR/specs/$id/roadmap.md"
  [ -f "$roadmap" ] || jig_die "spec plan: no such spec, or it has no roadmap: $rel"
  local lrc=0
  loc=$(spec_roadmap_ref "$id") || lrc=$?
  if [ "$lrc" -ne 0 ]; then
    epic=$(jig_spec_epic "$roadmap" 2>/dev/null) || epic=""
    [ "$lrc" -ne 2 ] || jig_die "spec plan: git rejects the epic branch name ${epic% *} in $rel"
    jig_die "spec plan: $id is built on ${epic% *}, which this checkout has no branch of; fetch it first"
  fi
  source="$rel"
  if [ -n "$loc" ]; then
    IFS=$'\t' read -r ref source <<LOC
$loc
LOC
    text=$(jig_git_show_path "$ref" "$rel" 2>/dev/null) \
      || jig_die "spec plan: $source has no $rel"
  else
    text=$(cat "$roadmap") || jig_die "spec plan: cannot read $rel"
  fi

  parsed=$(printf '%s\n' "$text" | _spec_plan_parse)
  # No reader here stops before the end of its input: bash writes a pipe line
  # by line, and under pipefail the SIGPIPE a reader that quit early leaves
  # printf with fails the check now and then (conventions/shell.md).
  case $'\n'"$parsed"$'\n' in
    *$'\n'waves$'\n'*) ;;
    *) jig_die "spec plan: $source has no \`## Waves\` list; a phase run starts tasks by wave" ;;
  esac
  local title
  title=$(printf '%s\n' "$parsed" | awk -F '\t' -v p="$phase" '$1 == "phase" && $2 + 0 == p + 0 && !f { print $3; f = 1 }')
  printf '%s\n' "$parsed" | awk -F '\t' -v p="$phase" '$1 == "phase" && $2 + 0 == p + 0 { f = 1 } END { exit !f }' \
    || jig_die "spec plan: $source has no Phase $phase"

  local rows limit
  # A report never refuses over a setting it only quotes: an autopilot.parallel
  # no reader understands answers 1, the safest count. `jig config set`
  # validates before writing, so only a hand-edited local file reaches this.
  limit=$(jig_autopilot_parallel) || limit=1
  rows=$(printf '%s\n' "$parsed" | _spec_plan_enrich \
    | JIG_SP_PHASE="$phase" JIG_SP_PARALLEL="$limit" _spec_plan_decide)
  if [ "$format" = tsv ]; then
    [ -z "$rows" ] || printf '%s\n' "$rows"
    return 0
  fi
  printf '%s\n' "$rows" | JIG_SP_PHASE="$phase" JIG_SP_TITLE="$title" JIG_SP_SOURCE="$source" _spec_plan_text
}

# spec_stop <id> --phase <n> --reason <text> — `jig spec stop`: the coordinator
# of a phase run stops for the person — a wave waiting for an answer, or,
# unattended, a draft or a problem ending the run. A phase run keeps no journal
# (adr-20260922-a-phase-run-is-coordinated), so this command is its record: it
# sends <text> to the person's Telegram when they set it up (jig_notify_phase,
# notify.sh), detached, and prints one line either way. Never fails on the
# message; refuses only its own arguments. The phase is checked in this
# checkout's roadmap, not the epic's ref as `spec plan` may read it: the
# coordinator runs in the epic's checkout, where the two are the same.
spec_stop() {
  local id="" phase="" reason="" has_reason=0 roadmap title="" n found=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)
        [ $# -ge 2 ] || jig_die "spec stop: --phase requires a value"
        phase="$2"
        shift 2
        ;;
      --reason)
        [ $# -ge 2 ] || jig_die "spec stop: --reason requires a value"
        reason="$2"
        has_reason=1
        shift 2
        ;;
      -*) jig_die "spec stop: unknown argument: $1" ;;
      *)
        [ -z "$id" ] || jig_die "spec stop: unexpected argument: $1"
        id="$1"
        shift
        ;;
    esac
  done
  [ -n "$id" ] || jig_die "spec stop: missing spec id (usage: jig spec stop <id> --phase <n> --reason <text>)"
  spec_valid_id "$id" || jig_die "spec stop: invalid spec id: $id"
  [ -n "$phase" ] || jig_die "spec stop: missing --phase <n>"
  case "$phase" in
    *[!0-9]*) jig_die "spec stop: --phase takes a phase number: $phase" ;;
  esac
  phase=$((10#$phase))
  [ "$has_reason" -eq 1 ] || jig_die "spec stop: --reason is required"
  [ -n "$reason" ] || jig_die "spec stop: --reason must not be empty"
  case "$reason" in
    *$'\t'* | *$'\n'* | *$'\r'*) jig_die "spec stop: --reason must be a single line with no tab" ;;
  esac
  jig_require_init
  roadmap="$(spec_dir)/$id/roadmap.md"
  [ -d "$(spec_dir)/$id" ] || jig_die "spec stop: no such spec in this checkout: $JIG_AI_DIR/specs/$id"
  [ -f "$roadmap" ] || jig_die "spec stop: $JIG_AI_DIR/specs/$id has no roadmap.md"
  while IFS=$'\t' read -r n _; do
    case "$n" in
      '' | *[!0-9]*) continue ;;
    esac
    if [ "$((10#$n))" = "$phase" ]; then found=1; fi
  done < <(spec_phase_counts "$roadmap")
  [ "$found" -eq 1 ] || jig_die "spec stop: $JIG_AI_DIR/specs/$id/roadmap.md has no Phase $phase"
  [ ! -f "$(spec_dir)/$id/spec.md" ] || title=$(spec_title "$(spec_dir)/$id/spec.md")
  if ! command -v jig_notify_phase >/dev/null 2>&1; then
    # shellcheck source=lib/notify.sh
    . "$JIG_LIB/notify.sh" 2>/dev/null || true
  fi
  if command -v jig_notify_phase >/dev/null 2>&1; then
    jig_notify_phase "$id" "$phase" "$title" "$reason" || true
  fi
  printf 'spec stop: %s phase %s\n' "$id" "$phase"
}

# _spec_plan_parse — the roadmap on stdin as rows, all phases:
#   phase   <n> <title>
#   waves                         (the `## Waves` heading is there)
#   wave    <n>                   (every numbered wave, in listed order)
#   item    <phase|-> <wave|-> <checked 0|1> <task-id|-> <filed|fog|plain> <title>
#   problem <wave> <unmatched|ambiguous|repeated> <entry>
#
# Items and headings follow spec_phase_counts' grammar; an item's indented
# lines that follow it are part of its text. A wave line is `<n>. ` and its
# entries are separated by `;`. An entry names an item when it equals the
# item's title — its text without the leading `` `task-id` — `` or `fog:`, up
# to the first dash with a space on each side (`—`, `--`, `-`) or ` (after:` —
# ignoring case, backticks and runs of spaces, or when it equals the item's
# task id, backticked or not. An entry that names no item, or more than one,
# is a problem, and so is an item two entries name: that item is placed in no
# wave rather than in a guessed one. `<…>` template placeholders are skipped.
_spec_plan_parse() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function norm(s) { gsub(/`/, "", s); gsub(/[[:space:]]+/, " ", s); return tolower(trim(s)) }
    function clean(s) { gsub(/\t/, " ", s); s = trim(s); return (s == "" ? "-" : s) }
    function end_item(   t, tid, kind) {
      if (!cur) return
      t = itext[cur]; kind = "plain"; tid = ""
      if (t ~ /^`[A-Za-z0-9._-]+`[[:space:]]+(—|--|-)[[:space:]]/) {
        tid = substr(t, 2); sub(/`.*$/, "", tid)
        # The same grammar as jig_valid_id: no leading dot or dash.
        if (tid ~ /^[.-]/) tid = ""
        else { sub(/^`[^`]*`[[:space:]]+(—|--|-)[[:space:]]+/, "", t); kind = "filed" }
      } else if (t ~ /^fog:/) {
        sub(/^fog:[[:space:]]*/, "", t); kind = "fog"
      }
      if (match(t, /[[:space:]]\(after:/)) t = substr(t, 1, RSTART - 1)
      if (match(t, /[[:space:]](—|--|-)[[:space:]]/)) t = substr(t, 1, RSTART - 1)
      iid[cur] = tid; ikind[cur] = kind; ititle[cur] = clean(t); inorm[cur] = norm(t)
      cur = 0
    }
    function end_wave(   parts, m, j, e) {
      if (wn == "") return
      m = split(wtext, parts, ";")
      for (j = 1; j <= m; j++) {
        e = trim(parts[j]); sub(/\.$/, "", e); e = trim(e)
        if (e == "" || e ~ /^</) continue
        ne++; went[ne] = e; ewave[ne] = wn
      }
      wn = ""
    }
    BEGIN { phase = "-"; OFS = "\t" }
    /^##[[:space:]]/ {
      end_item(); end_wave()
      h = $0
      sub(/^##[[:space:]]+/, "", h)
      gsub(/\t/, " ", h)
      inwaves = 0
      if (h ~ /^Phase[[:space:]]+[0-9]+/) {
        sub(/^Phase[[:space:]]+/, "", h)
        phase = h
        sub(/[^0-9].*$/, "", phase)
        phase = phase + 0
        sub(/^[0-9]+[[:space:]]*/, "", h)
        sub(/^(—|--|-|:)[[:space:]]*/, "", h)
        print "phase", phase, clean(h)
      } else {
        phase = "-"
        if (h ~ /^Waves[[:space:]]*$/) { inwaves = 1; print "waves" }
      }
      next
    }
    /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/ {
      end_item(); end_wave()
      t = $0
      sub(/^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/, "", t)
      if (t ~ /^</) next
      n++; cur = n
      iphase[n] = phase; ichecked[n] = ($0 ~ /\[[xX]\]/) ? 1 : 0; itext[n] = t
      next
    }
    inwaves && /^[0-9]+\.[[:space:]]/ {
      end_item(); end_wave()
      wn = $0; sub(/\..*$/, "", wn); wn = wn + 0
      if (!(wn in seenw)) { seenw[wn] = 1; nw++; worder[nw] = wn }
      wtext = $0; sub(/^[0-9]+\.[[:space:]]*/, "", wtext)
      next
    }
    /^[[:space:]]+[^[:space:]]/ {
      if (cur) { itext[cur] = itext[cur] " " trim($0); next }
      if (wn != "") { wtext = wtext " " trim($0); next }
    }
    { end_item(); end_wave() }
    END {
      end_item(); end_wave()
      for (k = 1; k <= nw; k++) print "wave", worder[k]
      for (k = 1; k <= ne; k++) {
        e = went[k]; eid = e; gsub(/`/, "", eid); eid = trim(eid); en = norm(e)
        cnt = 0; hit = 0
        for (i = 1; i <= n; i++) {
          if ((iid[i] != "" && eid == iid[i]) || (inorm[i] != "" && en == inorm[i])) { cnt++; hit = i }
        }
        if (cnt == 0) { print "problem", ewave[k], "unmatched", clean(e); continue }
        if (cnt > 1) { print "problem", ewave[k], "ambiguous", clean(e); continue }
        if (!(hit in first)) { first[hit] = k; continue }
        if (!(hit in rep)) { rep[hit] = 1; print "problem", ewave[first[hit]], "repeated", clean(went[first[hit]]) }
        print "problem", ewave[k], "repeated", clean(e)
      }
      for (i = 1; i <= n; i++) {
        w = ((i in first) && !(i in rep)) ? ewave[first[i]] : "-"
        print "item", iphase[i], w, ichecked[i], (iid[i] == "" ? "-" : iid[i]), ikind[i], ititle[i]
      }
    }
  '
}

# _spec_plan_enrich — the parsed rows on stdin, each `item` row replaced by
#   item <phase> <wave> <task-id|-> <state> <merged> <paused> <autopilot> <building> <title>
# from the task's workspace in this checkout and the housekeeping log; every
# other row passes through. Workspaces are read, never written: `state` is
# `jig task`'s alone.
#
# <building> is 1 when an agent is still building this task — its run is `on`
# and its knowledge is not consolidated yet — and 0 otherwise. That is the
# slot `autopilot.parallel` counts: a task whose work is consolidated and only
# waiting its turn to ship holds none
# (adr-20260922-a-phase-run-is-coordinated). The field is internal to this
# pipeline; _spec_plan_decide folds it into the `parallel` row and prints the
# item row spec_plan documents.
_spec_plan_enrich() {
  local merged_ids line iphase wave checked tid ikind ititle
  local state merged paused autopilot building tdir st
  # " <id>:<why> " pairs from the shared rule; an id holds no colon or space.
  merged_ids=" $(spec_merged_task_ids | tr '\t\n' ': ') "
  while IFS= read -r line; do
    case "$line" in
      item$'\t'*) ;;
      *) printf '%s\n' "$line"; continue ;;
    esac
    IFS=$'\t' read -r _ iphase wave checked tid ikind ititle <<ROW
$line
ROW
    state="" merged=no paused=false autopilot=- building=0
    [ "$checked" != 1 ] || merged=roadmap
    if [ "$ikind" = fog ]; then
      state=fog
    elif [ "$tid" = - ]; then
      state=not-filed
      [ "$checked" != 1 ] || state="done"
    else
      tdir=$(spec_task_dir "$tid") || tdir=""
      if [ -n "$tdir" ] && [ -f "$tdir/state" ]; then
        st=$(spec_task_state "$tdir" status)
        state=${st:-unknown}
        if [ "$st" = active ] \
           && { [ -z "$(spec_task_state "$tdir" branch)" ] || [ -z "$(spec_task_state "$tdir" base_commit)" ]; }; then
          state=not-started
        fi
        if [ "$(spec_task_state "$tdir" paused)" = true ]; then
          paused=true
        fi
        autopilot=$(spec_task_state "$tdir" autopilot)
        [ -n "$autopilot" ] || autopilot=-
        if [ "$autopilot" = on ] && [ "$(spec_task_state "$tdir" knowledge_consolidated)" != true ]; then
          building=1
        fi
      else
        state=no-workspace
        [ "$checked" != 1 ] || state="done"
      fi
      if [ "$merged" = no ]; then
        # Quoted, the id is matched as a string, never as a pattern.
        case "$merged_ids" in
          *" $tid:closed "*) merged=closed ;;
          *" $tid:housekeeping "*) merged=housekeeping ;;
        esac
      fi
    fi
    printf 'item\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$iphase" "$wave" "$tid" "$state" "$merged" "$paused" "$autopilot" "$building" "$ititle"
  done
}

# spec_merged_task_ids — the tasks whose work is known to have merged, one
# `<task-id>\t<closed|housekeeping>` line each: `closed` for a task whose
# workspace `state` says `consolidated` (ADR-0030 closes a task only after its
# change landed), then `housekeeping` for an id the newest housekeeping run
# logged `remote=merged` and that is not closed. The one rule every reader of
# "merged" shares — the roadmap counts (spec_phase_counts) and `spec plan` —
# read offline: no fetch, no forge call. Both sources are local and
# gitignored, so a clone holding neither knows only the roadmap's checkmarks.
#
# Inside a walk over every spec the answer is the one _spec_merged_memo read
# at its start, not read again per spec.
spec_merged_task_ids() {
  if [ "${_SPEC_MERGED_MEMO:-}" = 1 ]; then
    [ -z "$_SPEC_MERGED" ] || printf '%s\n' "$_SPEC_MERGED"
    return 0
  fi
  _spec_merged_task_ids_read
}

# _spec_merged_memo — read spec_merged_task_ids once for a walk over every
# spec. The walk declares `local _SPEC_MERGED_MEMO _SPEC_MERGED` and calls this
# before its loop; bash scopes locals dynamically, so every spec_phase_counts
# under it, subshells included, answers from that one read, and the memo ends
# with the walk -- a later reader in the same process reads again. Asked per
# spec, the read cost 20 specs a pass over every task's state and the whole
# housekeeping log each: 6.8 s where 0.37.0 took 0.76.
_spec_merged_memo() {
  _SPEC_MERGED=$(_spec_merged_task_ids_read)
  _SPEC_MERGED_MEMO=1
}

_spec_merged_task_ids_read() {
  local ws closed=""
  # A roadmap read outside a project (a library sourced on its own) has no
  # tasks to ask.
  [ -n "${JIG_PROJECT:-}" ] && [ -n "${JIG_AI_DIR:-}" ] || return 0
  ws="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  # A glob, not find: in a `--worktree` checkout the tasks directory is a
  # link to the owner's (_task_link_workspace), and find does not descend it.
  set -- "$ws"/*/state
  if [ -f "$1" ]; then
    closed=$(awk '
      FNR == 1 { seen = 0 }
      !seen && /^status:/ {
        seen = 1
        v = $0; sub(/^status:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v)
        if (v == "consolidated") {
          d = FILENAME; sub(/\/state$/, "", d); sub(/^.*\//, "", d)
          print d
        }
      }
    ' "$@" 2>/dev/null) || closed=""
  fi
  {
    [ -z "$closed" ] || printf '%s\n' "$closed" | awk '{ print "c\t" $0 }'
    _spec_plan_hk_merged | awk '{ print "h\t" $0 }'
  } | awk -F '\t' '
    $1 == "c" { if (!($2 in seen)) { seen[$2] = 1; printf "%s\tclosed\n", $2 } ; next }
    $1 == "h" { if (!($2 in seen)) { seen[$2] = 1; printf "%s\thousekeeping\n", $2 } }
  '
}

# _spec_plan_hk_merged — the task ids the newest housekeeping run found merged
# into their base (`remote=merged` on a task line after the last `--- run`
# marker; domains/housekeeping documents the log's line shape), read by the
# log's shared parser. Nothing when housekeeping never ran here.
_spec_plan_hk_merged() {
  command -v hklog_ids >/dev/null 2>&1 || {
    # shellcheck source=lib/hklog.sh
    . "$JIG_LIB/hklog.sh"
  }
  hklog_ids ' remote=merged( |$)'
}

# _spec_plan_decide — the enriched rows on stdin, the phase in JIG_SP_PHASE and
# the slot limit in JIG_SP_PARALLEL; prints the TSV spec_plan documents. A wave
# is merged when every item in it merged and none of its entries is a problem;
# it is open when every wave numbered below it is merged. Only an open wave's
# items may start, and at most one wave is open and not merged at a time — the
# `parallel` row counts the agents building that wave's tasks. It counts them
# whatever phase they belong to: the waves are one list over the whole roadmap,
# and an agent building a neighbouring phase's task holds a slot on the same
# machine.
_spec_plan_decide() {
  awk -F '\t' '
    BEGIN { OFS = "\t"; want = ENVIRON["JIG_SP_PHASE"] + 0; limit = ENVIRON["JIG_SP_PARALLEL"] + 0 }
    $1 == "wave" { w = $2 + 0; if (!(w in known)) { known[w] = 1; nw++; wl[nw] = w }; next }
    $1 == "problem" { np++; pr[np] = $0; if ($2 != "-") bad[$2 + 0] = 1; next }
    $1 == "item" {
      n++; ph[n] = $2; wv[n] = $3; id[n] = $4; st[n] = $5; mg[n] = $6; pa[n] = $7; ap[n] = $8; bd[n] = $9; ti[n] = $10
      if (wv[n] != "-" && mg[n] == "no") unmerged[wv[n] + 0] = 1
      next
    }
    function next_of(i,   w) {
      if (mg[i] != "no") return "done"
      if (wv[i] == "-") return "unscheduled"
      w = wv[i] + 0
      if (!open[w]) return "wait"
      if (st[i] == "fog") return "fog"
      if (st[i] == "not-filed") return "file"
      if (st[i] == "no-workspace") return "find"
      if (st[i] == "not-started") return "start"
      if (st[i] == "abandoned") return "abandoned"
      if (st[i] == "archived") return "unarchive"
      return "running"
    }
    function item_row(i) { print "item", wv[i], id[i], st[i], mg[i], pa[i], ap[i], next_of(i), ti[i] }
    END {
      # Waves in ascending order: a plain insertion sort, the list is short.
      for (a = 2; a <= nw; a++) { v = wl[a]; for (b = a - 1; b >= 1 && wl[b] > v; b--) wl[b + 1] = wl[b]; wl[b + 1] = v }
      prev = 1
      for (a = 1; a <= nw; a++) {
        w = wl[a]
        merged[w] = !(w in unmerged) && !(w in bad)
        open[w] = prev
        if (!merged[w]) prev = 0
      }
      building = 0
      for (a = 1; a <= nw; a++) {
        w = wl[a]
        if (merged[w] || !open[w]) continue
        for (i = 1; i <= n; i++) if (wv[i] != "-" && wv[i] + 0 == w && bd[i] + 0 == 1) building++
      }
      print "parallel", limit, building
      firstwait = ""
      for (a = 1; a <= nw; a++) {
        w = wl[a]; has = 0
        for (i = 1; i <= n; i++) if (ph[i] != "-" && ph[i] + 0 == want && wv[i] != "-" && wv[i] + 0 == w) has = 1
        if (!has) continue
        wstate = merged[w] ? "merged" : (open[w] ? "open" : "waiting")
        if (wstate == "waiting" && firstwait == "") firstwait = w
        print "wave", w, wstate
        for (i = 1; i <= n; i++) if (ph[i] != "-" && ph[i] + 0 == want && wv[i] != "-" && wv[i] + 0 == w) item_row(i)
      }
      for (i = 1; i <= n; i++) if (ph[i] != "-" && ph[i] + 0 == want && wv[i] == "-") item_row(i)
      if (firstwait != "") {
        for (a = 1; a <= nw && wl[a] < firstwait; a++) {
          w = wl[a]
          for (i = 1; i <= n; i++)
            if (wv[i] != "-" && wv[i] + 0 == w && mg[i] == "no") print "blocker", w, id[i], st[i], ti[i]
        }
      }
      for (k = 1; k <= np; k++) print pr[k]
    }
  '
}

# _spec_plan_text — the TSV on stdin for a person: the phase, each wave with
# its items, what earlier waves still hold, the problems, and what may start.
_spec_plan_text() {
  awk -F '\t' '
    function label(s, p, a, m,   l) {
      l = s
      if (s == "not-filed") l = "not filed"
      else if (s == "no-workspace") l = "no workspace here"
      else if (s == "not-started") l = "not started"
      if (m == "housekeeping") l = l ", merged"
      if (p == "true") l = l ", paused"
      if (a != "-") l = l ", autopilot " a
      return l
    }
    function pad(s, w) { while (length(s) < w) s = s " "; return s }
    { row[NR] = $0 }
    $1 == "item" { l = label($4, $6, $7, $5); if (length($3) > wid) wid = length($3); if (length(l) > wl) wl = length(l); if (length($8) > wn) wn = length($8) }
    $1 == "blocker" { l = label($4, "false", "-", "no"); if (length($3) > bid) bid = length($3); if (length(l) > bl) bl = length(l) }
    END {
      t = ENVIRON["JIG_SP_TITLE"]
      printf "Phase %s%s\n", ENVIRON["JIG_SP_PHASE"], (t == "" || t == "-") ? "" : " — " t
      printf "roadmap: %s\n", ENVIRON["JIG_SP_SOURCE"]
      items = 0; loose = 0; blockers = 0; start = ""; file = ""; limit = 0; building = 0
      for (r = 1; r <= NR; r++) {
        split(row[r], f, "\t")
        if (f[1] == "parallel") { limit = f[2] + 0; building = f[3] + 0 }
        else if (f[1] == "wave") printf "wave %s — %s\n", f[2], f[3]
        else if (f[1] == "item") {
          items++
          if (f[2] == "-" && !loose) { print "not in any wave:"; loose = 1 }
          printf "  %s  %s  %s  %s\n", pad(f[3], wid), pad(label(f[4], f[6], f[7], f[5]), wl), pad(f[8], wn), f[9]
          if (f[8] == "start") start = start (start == "" ? "" : ", ") f[3]
          if (f[8] == "file") file = file (file == "" ? "" : "; ") f[9]
        } else if (f[1] == "blocker") {
          if (!blockers) print "waiting on earlier waves:"
          blockers++
          printf "  wave %s  %s  %s  %s\n", f[2], pad(f[3], bid), pad(label(f[4], "false", "-", "no"), bl), f[5]
        } else if (f[1] == "problem") {
          why = (f[3] == "unmatched") ? "names no roadmap item" : (f[3] == "ambiguous") ? "names more than one roadmap item" : "names an item another wave entry names too"
          printf "problem: wave %s entry \"%s\" %s\n", f[2], f[4], why
        }
      }
      if (!items) print "no items in this phase"
      free = limit - building
      if (free < 0) free = 0
      printf "may start now: %s (%d of %d slots free)\n", (start == "" ? "none" : start), free, limit
      if (file != "") printf "to file first: %s\n", file
    }
  '
}

# --- epic branches ---------------------------------------------------------------

# spec_epic <id> [--finish | --reopen] — the epic branch of a spec released
# once, at the end (ADR-0040).
#
# Without a flag: declare the epic with an `Epic: epic/<id>` line when the
# roadmap has none, and stop — the line has to reach the default branch before
# the epic is cut from it, or neither the epic nor a checkout of the default
# branch would know where the spec's tasks go. With the line on the freshest
# default branch, cut `epic/<id>` there, without a checkout; pushing it is the
# human's step. `--finish`, on the epic after the default branch was merged
# into it, closes the line before the final pull request; `--reopen` takes
# that back when review of the final pull request needs a fix.
spec_epic() {
  [ $# -ge 1 ] || jig_die "spec epic: missing spec id (usage: jig spec epic <id> [--release <level> | --finish | --reopen])"
  local id="$1" mode=declare handled=0 release=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --finish) [ "$mode" = declare ] || jig_die "spec epic: --finish and --reopen exclude each other"; mode=finish ;;
      --reopen) [ "$mode" = declare ] || jig_die "spec epic: --finish and --reopen exclude each other"; mode=reopen ;;
      --leftovers-handled) handled=1 ;;
      --release)
        [ $# -ge 2 ] || jig_die "spec epic: --release requires a value (patch|minor|major)"
        release="$2"
        shift ;;
      *) jig_die "spec epic: unexpected argument: $1" ;;
    esac
    shift
  done
  spec_valid_id "$id" || jig_die "spec epic: invalid spec id: $id"
  [ "$handled" -eq 0 ] || [ "$mode" = finish ] || jig_die "spec epic: --leftovers-handled goes with --finish"
  [ -z "$release" ] || [ "$mode" = declare ] || jig_die "spec epic: --release goes with declaring the epic, not with --finish or --reopen"
  [ -z "$release" ] || spec_release_valid "$release" \
    || jig_die "spec epic: invalid release level: $release (expected patch|minor|major)"
  jig_require_init
  if [ "$mode" = reopen ]; then
    spec_epic_reopen "$id"
    return 0
  fi
  local roadmap rel line rc=0
  roadmap="$(spec_dir)/$id/roadmap.md"
  rel="$JIG_AI_DIR/specs/$id/roadmap.md"
  [ -f "$roadmap" ] || jig_die "spec epic: no such spec, or it has no roadmap: $rel"
  line=$(jig_spec_epic "$roadmap") || rc=$?
  [ "$rc" -ne 2 ] || jig_die "spec epic: $rel declares more than one epic; keep one Epic: line"
  spec_release_check "spec epic" "$rel" < "$roadmap" >/dev/null

  case "$mode" in
    declare) spec_epic_declare "$id" "$roadmap" "$rel" "$line" "$release" ;;
    finish) spec_epic_finish "$id" "$roadmap" "$rel" "$line" "$handled" ;;
  esac
}

spec_epic_declare() {
  local id="$1" roadmap="$2" rel="$3" line="$4" release="${5:-}" branch default start commit on_default rc=0
  if [ -z "$line" ]; then
    branch="epic/$id"
    git check-ref-format --branch "$branch" >/dev/null 2>&1 \
      || jig_die "spec epic: git rejects the branch name: $branch"
    spec_epic_write "$roadmap" "declare" "$branch" "$release"
    printf '%s: Epic: %s\n' "$rel" "$branch"
    [ -z "$release" ] || printf '%s: Release: %s\n' "$rel" "$release"
    jig_info "spec epic: $(spec_ship_hint declare "$id" "$branch" "$rel")"
    return 0
  fi
  [ -z "$release" ] || jig_die "spec epic: $rel declares ${line% *} already; the release level is recorded when the epic is declared — edit its Release: line instead"
  branch=${line% *}
  [ "${line##* }" = open ] || jig_die "spec epic: $rel marks epic $branch finished, as an older jig did; a finished epic's spec is removed now — delete the spec, or drop \"— finished\" to reopen it"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 \
    || jig_die "spec epic: git rejects the branch name: $branch"
  if [ -n "$(jig_base_ref "$branch")" ]; then
    printf 'exists: %s\n' "$branch"
    return 0
  fi

  default=$(cfg git.base_branch main)
  jig_fetch_branches "spec epic" "$default"
  # Checked again after the fetch: the epic may have been pushed by somebody
  # else since this checkout last looked.
  jig_fetch_branches "spec epic" "$branch" 2>/dev/null
  if [ -n "$(jig_base_ref "$branch")" ]; then
    printf 'exists: %s\n' "$branch"
    return 0
  fi
  start=$(jig_fresh_base_ref "$default" "spec epic") || exit 1
  [ "$start" != HEAD ] || jig_die "spec epic: $default exists neither here nor on origin"
  commit=$(git -C "$JIG_PROJECT" rev-parse --verify --quiet "$start^{commit}" 2>/dev/null) \
    || jig_die "spec epic: cannot resolve $start"
  on_default=$(jig_git_show_path "$commit" "$rel" 2>/dev/null | jig_spec_epic -) || rc=$?
  if [ "$rc" -ne 0 ] || [ "$on_default" != "$branch open" ]; then
    jig_die "spec epic: the Epic: line of $rel is not on $default yet; merge it into $default first"
  fi
  git -C "$JIG_PROJECT" branch "$branch" "$commit" >/dev/null 2>&1 \
    || jig_die "spec epic: could not create $branch"
  printf 'created: %s at %s\n' "$branch" "$commit"
  jig_info "spec epic: $(spec_ship_hint cut "$id" "$branch" "$rel")"
}

# spec_epic_site <cmd> <epic-branch> <what> — exit 0 when HEAD may carry the
# epic's finish: the epic itself, or a branch other than the default one that
# already contains the epic's tip (a release branch cut from it). The epic is
# protected like the default branch where a repository says so, so its finish
# is never pushed to it: `spec ship` carries it on a branch of its own
# (ADR-0040, amendment of 2026-10-04). Dies naming the two places that work.
spec_epic_site() {
  local cmd="$1" branch="$2" what="$3" here default tip
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$here" != "$branch" ] || return 0
  default=$(cfg git.base_branch main)
  if [ -n "$here" ] && [ "$here" != "$default" ]; then
    for tip in "refs/heads/$branch" "refs/remotes/origin/$branch"; do
      if git -C "$JIG_PROJECT" rev-parse --verify --quiet "$tip^{commit}" >/dev/null 2>&1; then
        if git -C "$JIG_PROJECT" merge-base --is-ancestor "$tip" HEAD 2>/dev/null; then
          return 0
        fi
        break
      fi
    done
  fi
  jig_die "$cmd: $what runs on $branch or on a branch cut from it; switch to one first"
}

spec_epic_finish() {
  local id="$1" roadmap="$2" rel="$3" line="$4" handled="$5" branch default start
  [ -n "$line" ] || jig_die "spec epic: $rel declares no epic"
  branch=${line% *}
  [ "${line##* }" = open ] || jig_die "spec epic: $rel marks epic $branch finished, as an older jig did; drop \"— finished\" from the line, then run --finish again"
  spec_epic_site "spec epic" "$branch" --finish
  default=$(cfg git.base_branch main)
  jig_fetch_branches "spec epic" "$default"
  start=$(jig_fresh_base_ref "$default" "spec epic") || exit 1
  if [ "$start" != HEAD ] \
     && ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$start" HEAD 2>/dev/null; then
    jig_die "spec epic: $branch does not contain the latest $default; merge $default into it first"
  fi
  # The spec leaves with the epic's final pull request: its decisions are in
  # knowledge by now, and what is not is decided by a human first.
  local release
  release=$(spec_release_check "spec epic" "$rel" < "$roadmap") || exit 1
  spec_close_dir "$id" "spec epic" "$handled"
  # The level the version is raised by in this commit, as recorded when the
  # epic was declared; the rule that picks one when none was is the caller's.
  printf 'release: %s\n' "${release:-not recorded}"
  jig_info "spec epic: $(spec_ship_hint finish "$id" "$branch" "$rel")"
}

# spec_epic_reopen <id> — bring back the spec `--finish` removed, on its epic,
# when review of the final pull request needs a fix: fixes are ordinary tasks,
# and a task finds its epic through the spec. Restored from git, never from
# trash, which is local and expires: from HEAD while the removal is not
# committed, else from the commit before the one that deleted the roadmap.
# Files are written with `git show`, so the index is left alone.
spec_epic_reopen() {
  local id="$1" dir rel roadmap src del line rc=0 branch path
  dir="$(spec_dir)/$id"
  rel="$JIG_AI_DIR/specs/$id"
  roadmap="$rel/roadmap.md"
  [ ! -e "$dir" ] || jig_die "spec epic: $rel is here; --reopen restores a spec that --finish removed"
  if git -C "$JIG_PROJECT" cat-file -e "HEAD:$roadmap" 2>/dev/null; then
    src=HEAD
  else
    del=$(git -C "$JIG_PROJECT" log -1 --diff-filter=D --format=%H -- "$roadmap" 2>/dev/null) || del=""
    [ -n "$del" ] || jig_die "spec epic: no removed spec $id in the history of this branch"
    src="$del^"
  fi
  line=$(jig_git_show_path "$src" "$roadmap" 2>/dev/null | jig_spec_epic -) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$line" ]; then
    jig_die "spec epic: the removed $roadmap declares no epic"
  fi
  branch=${line% *}
  spec_epic_site "spec epic" "$branch" --reopen
  # Restored into a directory of its own first and moved into place whole: a
  # failure halfway must not leave a partial spec that the "is here" check
  # would then refuse to restore over. A partial copy goes to trash, not to
  # `rm`: scripts delete nothing outside workspaces and trash (RULES.md). Only
  # paths under the spec's own directory are listed, so none lands elsewhere.
  local tmp sub
  tmp="$dir.restore.$$"
  mkdir "$tmp" || jig_die "spec epic: cannot create $tmp"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    sub=${path#"$rel/"}
    if ! mkdir -p "$tmp/$(dirname "$sub")" \
       || ! jig_git_show_path "$src" "$path" > "$tmp/$sub"; then
      spec_trash_partial "$tmp" "$id"
      jig_die "spec epic: could not restore $path"
    fi
  done < <(git -C "$JIG_PROJECT" ls-tree -r --name-only "$src" -- "$rel/")
  if ! mv "$tmp" "$dir"; then
    spec_trash_partial "$tmp" "$id"
    jig_die "spec epic: could not move the restored spec into $rel"
  fi
  jig_record_changed
  printf 'restored: %s from %s\n' "$rel" "$(git -C "$JIG_PROJECT" rev-parse --short "$src")"
  jig_info "spec epic: fix it with ordinary tasks, then run \`jig spec epic $id --finish\` again"
}

# spec_trash_partial <dir> <id> — move a partial restore out of the way, to
# trash; best effort, the caller dies either way.
spec_trash_partial() {
  local dest
  dest=$(jig_trash_dest "spec-$2-restore")
  if mkdir -p "${dest%/*}" 2>/dev/null; then
    mv "$1" "$dest" 2>/dev/null || true
  fi
}

# --- release level ----------------------------------------------------------------

# spec_release_valid <level> — patch, minor or major.
spec_release_valid() {
  case "$1" in patch | minor | major) return 0 ;; *) return 1 ;; esac
}

# spec_release_check <who> <rel> — read a roadmap on stdin and print the level
# its `Release:` line records, or nothing when it has none. The line says how
# far the epic's final pull request raises the version; it is recorded when
# the epic is declared, while the human still answers (jig-idea §8), so an
# unattended run never has to guess a release a human would have chosen.
# Every line starting with `Release:` counts, so a line with a typo or a
# trailing remark is refused instead of silently read as "not recorded". Dies
# on a value other than patch|minor|major and on two lines that disagree.
spec_release_check() {
  local who="$1" rel="$2" out rc=0
  out=$(awk '
    /^Release:/ {
      v = $0
      sub(/^Release:[[:space:]]*/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v !~ /^(patch|minor|major)$/) { print v; bad = 1; exit }
      if (found == "") found = v
      else if (found != v) conflict = 1
    }
    END {
      if (bad) exit 1
      if (conflict) exit 2
      if (found != "") print found
    }') || rc=$?
  case "$rc" in
    0) [ -z "$out" ] || printf '%s\n' "$out" ;;
    2) jig_die "$who: $rel records more than one release level; keep one Release: line" ;;
    *) jig_die "$who: $rel records an invalid release level: ${out:-(empty)} (expected Release: patch|minor|major)" ;;
  esac
}

# --- shipping spec work (adr-20260922-spec-work-ships-by-the-agent-git-level) -----

# spec_ship_git — `<level><TAB><key>`: the git level `spec ship` uses, and
# the key it came from. In a clone set to `autopilot.unattended: true` it is
# the run's level (jig_autopilot_git): `spec ship` keeps no run of its own,
# and an unattended clone is already what lets its epic finish merge, so a
# person who held their runs to `autopilot.git: pr` is not merged past by an
# `agent.git: merge` meant for their own work. Everywhere else `agent.git`.
# Exit 1 when the level is invalid, like jig_agent_git.
spec_ship_git() {
  local value
  if jig_unattended; then
    jig_autopilot_git
    return
  fi
  if value=$(jig_agent_git); then
    printf '%s\tagent.git\n' "$value"
  else
    printf '%s\tagent.git\n' "$value"
    return 1
  fi
}

# spec_ship_level — spec_ship_git's level for the next-step lines `spec epic`
# prints: an invalid value reads as `none` here, because only `spec ship` may
# refuse it.
spec_ship_level() {
  local line
  if line=$(spec_ship_git 2>/dev/null); then
    printf '%s\n' "${line%%$'\t'*}"
  else
    printf 'none\n'
  fi
}

# spec_ship_hint declare|cut|finish <id> <branch> <rel> — the step after
# `spec epic`, named by whose it is at this clone's agent.git level.
# shellcheck disable=SC2016 # the backticks are literal: they quote a command
spec_ship_hint() {
  local step="$1" id="$2" branch="$3" rel="$4" level default does
  level=$(spec_ship_level)
  default=$(cfg git.base_branch main)
  case "$step" in
    declare)
      case "$level" in
        commit) does="it commits; the push and the pull request into $default are yours" ;;
        push) does="it commits and pushes; the pull request into $default is yours" ;;
        pr | merge) does="it commits, pushes and opens the pull request into $default" ;;
        *)
          printf 'commit %s and merge it into %s, then run `jig spec epic %s` again to cut %s\n' "$rel" "$default" "$id" "$branch"
          return 0 ;;
      esac
      printf 'stage %s/ and run `jig spec ship %s` (agent.git: %s — %s); once it is merged into %s, run `jig spec epic %s` again to cut %s\n' \
        "${rel%/roadmap.md}" "$id" "$level" "$does" "$default" "$id" "$branch"
      ;;
    cut)
      case "$level" in
        push | pr | merge) printf 'push it with `jig spec ship %s`\n' "$id" ;;
        *) printf 'push it with `git push -u origin %s` — yours at agent.git: %s\n' "$branch" "$level" ;;
      esac
      ;;
    finish)
      case "$level" in
        commit) does="it commits; pushing $branch and the pull request into $default are yours" ;;
        push) does="it commits and pushes $branch; the pull request into $default is yours" ;;
        pr) does="it commits, pushes $branch and opens the pull request into $default" ;;
        merge) does="it commits, pushes $branch and opens the pull request into $default, and merges it once CI passed only in an unattended run" ;;
        *)
          printf 'commit the removal with the version bump, then open the pull request from %s into %s\n' "$branch" "$default"
          return 0 ;;
      esac
      printf 'stage the removal with the version bump and run `jig spec ship %s` (agent.git: %s — %s)\n' "$id" "$level" "$does"
      ;;
  esac
}

# spec_ship <id> [--message-file <file>] [--title <t>] [--body-file <file>]
#
# Carries spec work as far as `agent.git` allows, through the same git steps as
# `task ship` (jig_ship_*, common.sh). What to ship is read from the state of
# the checkout, never from a flag, and printed first as `mode: <mode>`:
#
# - declare — the spec is here and its Epic: line is not on the freshest
#   default branch yet (or it has no epic): commit what is staged, all of it
#   under the spec's own directory, on a branch of its own — `spec/<id>`,
#   switched to from the default branch — push it and open the pull request
#   into the default branch.
# - epic — the Epic: line is on the default branch and the epic exists here:
#   push it (after it was cut, or after the default branch was merged into it).
#   Commits nothing.
# - final — on the epic, with the spec removed by `spec epic --finish`: commit
#   the staged removal and version bump, push the epic, open its pull request
#   into the default branch — and at `merge`, in an unattended run only, merge
#   it (spec_ship_final).
#
# - remove — the spec is gone from the checkout (`spec close`) and never had an
#   open epic: commit the staged removal, all of it under the spec's own
#   directory, on a branch of its own — `close/<id>`, switched to from the
#   default branch — push it and open the pull request into the default branch
#   (spec_ship_remove).
#
# A declaration's or a removal's pull request is never merged here, and outside
# an unattended run neither is the final one: that merge is the release. At `none` it exits
# 3, like `task ship`: the skill reads it as "the human's step".
spec_ship() {
  [ $# -ge 1 ] || jig_die "spec ship: missing spec id (usage: jig spec ship <id> [--message-file <file>] [--title <t>] [--body-file <file>])"
  local id="$1" message_file="" title="" body_file=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --message-file)
        [ $# -ge 2 ] || jig_die "spec ship: --message-file requires a value"
        message_file="$2"
        shift 2 ;;
      --title)
        [ $# -ge 2 ] || jig_die "spec ship: --title requires a value"
        title="$2"
        shift 2 ;;
      --body-file)
        [ $# -ge 2 ] || jig_die "spec ship: --body-file requires a value"
        body_file="$2"
        shift 2 ;;
      *) jig_die "spec ship: unexpected argument: $1" ;;
    esac
  done
  spec_valid_id "$id" || jig_die "spec ship: invalid spec id: $id"
  jig_require_init
  [ -z "$message_file" ] || [ -f "$message_file" ] || jig_die "spec ship: --message-file: no such file: $message_file"
  [ -z "$body_file" ] || [ -f "$body_file" ] || jig_die "spec ship: --body-file: no such file: $body_file"

  # Level first, before anything else changes (as `task ship`).
  local level key line lrc=0
  line=$(spec_ship_git) || lrc=$?
  level=${line%%$'\t'*}
  key=${line#*$'\t'}
  [ "$lrc" -eq 0 ] || jig_die "spec ship: invalid $key: $level (expected none|commit|push|pr|merge)"
  if [ "$level" = none ]; then
    printf "spec ship: %s is none in this clone; committing, pushing and the pull request are the human's\n" "$key" >&2
    exit 3
  fi

  local dir rel roadmap here default line branch mode rc=0 start on_default src
  dir="$(spec_dir)/$id"
  rel="$JIG_AI_DIR/specs/$id"
  roadmap="$rel/roadmap.md"
  default=$(cfg git.base_branch main)
  here=$(git -C "$JIG_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$here" ] || jig_die "spec ship: HEAD is detached; switch to a branch first"

  if [ -d "$dir" ]; then
    [ -f "$dir/roadmap.md" ] || jig_die "spec ship: $rel has no roadmap"
    line=$(jig_spec_epic "$dir/roadmap.md") || rc=$?
    [ "$rc" -ne 2 ] || jig_die "spec ship: $roadmap declares more than one epic; keep one Epic: line"
    spec_release_check "spec ship" "$roadmap" < "$dir/roadmap.md" >/dev/null
    mode=declare
    if [ -n "$line" ]; then
      branch=${line% *}
      [ "${line##* }" = open ] || jig_die "spec ship: $roadmap marks epic $branch finished, as an older jig did; a finished epic's spec is removed now"
      git check-ref-format --branch "$branch" >/dev/null 2>&1 \
        || jig_die "spec ship: git rejects the branch name: $branch"
      if [ "$here" = "$branch" ]; then
        mode=epic
      else
        jig_fetch_branches "spec ship" "$default"
        start=$(jig_fresh_base_ref "$default" "spec ship") || exit 1
        if [ "$start" != HEAD ]; then
          rc=0
          on_default=$(jig_git_show_path "$start" "$roadmap" 2>/dev/null | jig_spec_epic -) || rc=$?
          [ "$rc" -ne 0 ] || [ "$on_default" != "$branch open" ] || mode=epic
        fi
      fi
    fi
  else
    # A removed spec with an open epic is the epic's final pull request; any
    # other removal (`spec close`) ships on a branch of its own.
    src=$(spec_ship_removed_src "$id") || exit 1
    rc=0
    line=$(jig_git_show_path "$src" "$roadmap" 2>/dev/null | jig_spec_epic -) || rc=$?
    [ "$rc" -ne 2 ] || jig_die "spec ship: the removed $roadmap declares more than one epic; keep one Epic: line"
    if [ "$rc" -eq 0 ] && [ -n "$line" ] && [ "${line##* }" = open ]; then
      mode=final
      branch=$(spec_ship_removed_epic "$id") || exit 1
      spec_epic_site "spec ship" "$branch" "an epic's final pull request"
    else
      mode=remove
    fi
  fi

  printf 'mode: %s\n' "$mode"
  printf 'spec ship: git level %s (%s)\n' "$level" "$key"
  case "$mode" in
    declare) spec_ship_declare "$id" "$level" "$here" "$default" "$message_file" "$title" "$body_file" "$line" ;;
    epic) spec_ship_epic "$id" "$level" "$branch" ;;
    final) spec_ship_final "$id" "$level" "$branch" "$default" "$message_file" "$title" "$body_file" "$here" ;;
    remove) spec_ship_remove "$id" "$level" "$here" "$default" "$message_file" "$title" "$body_file" ;;
  esac
}

# spec_ship_removed_epic <id> — the epic a removed spec declared, read from git
# the way `epic --reopen` reads it: HEAD while the removal is not committed,
# else the commit before the one that deleted the roadmap. Dies when this
# branch never held the spec with an open Epic: line.
spec_ship_removed_epic() {
  local id="$1" roadmap src line rc=0
  roadmap="$JIG_AI_DIR/specs/$id/roadmap.md"
  src=$(spec_ship_removed_src "$id") || exit 1
  line=$(jig_git_show_path "$src" "$roadmap" 2>/dev/null | jig_spec_epic -) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$line" ] || [ "${line##* }" != open ]; then
    jig_die "spec ship: the removed $roadmap declares no open epic; only an epic's final pull request ships a removed spec"
  fi
  # Validated where it is read, as the release level the final PR carries.
  jig_git_show_path "$src" "$roadmap" 2>/dev/null | spec_release_check "spec ship" "$roadmap" >/dev/null || exit 1
  printf '%s\n' "${line% *}"
}

# spec_ship_removed_src <id> — the commit a removed spec is read from, as a
# hash: HEAD while its removal is not committed, else the commit before the
# one that deleted its roadmap. A hash, not `HEAD`: the final ship commits the
# removal and reads the roadmap again after that. Dies when this branch never
# held it.
spec_ship_removed_src() {
  local id="$1" roadmap del ref
  roadmap="$JIG_AI_DIR/specs/$id/roadmap.md"
  if git -C "$JIG_PROJECT" cat-file -e "HEAD:$roadmap" 2>/dev/null; then
    ref=HEAD
  else
    del=$(git -C "$JIG_PROJECT" log -1 --diff-filter=D --format=%H -- "$roadmap" 2>/dev/null) || del=""
    [ -n "$del" ] || jig_die "spec ship: no spec $id here, and none removed in the history of this branch"
    ref="$del^"
  fi
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null \
    || jig_die "spec ship: cannot resolve $ref"
}

# spec_ship_steps <level> <branch> <base> <message-file> <title> <body-file> [<draft>] —
# commit, push <branch>, open its pull request into <base>, stopping where
# <level> stops; the same steps and stop lines as `task ship`.
spec_ship_steps() {
  local level="$1" branch="$2" base="$3" message_file="$4" title="$5" body_file="$6" draft="${7:-0}"
  jig_ship_commit "spec ship" "$message_file"
  # The same order as `task ship` (common.sh, "what a ship may send out"):
  # a declaration and a final pull request both carry commits, and both are
  # refused here rather than on the forge.
  jig_ship_require_commits "spec ship" "$branch" "$base"
  if [ "$level" = commit ]; then
    printf "stopped at commit: push is the human's\n"
    return 0
  fi
  jig_ship_push "spec ship" "$branch"
  if [ "$level" = push ]; then
    printf "stopped at push: the pull request is the human's\n"
    return 0
  fi
  jig_ship_pr "spec ship" "$branch" "$base" "$message_file" "$title" "$body_file" "$draft"
}

spec_ship_declare() {
  local id="$1" level="$2" here="$3" default="$4" message_file="$5" title="$6" body_file="$7" line="$8"
  local rel branch p bad=""
  rel="$JIG_AI_DIR/specs/$id"
  [ -n "$message_file" ] || jig_die "spec ship: declaring commits; --message-file is required"
  case "$here" in
    epic/*) jig_die "spec ship: $here is an epic branch; the declaration goes into $default from a branch of its own" ;;
  esac
  jig_ship_check_staged "spec ship"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$rel/"*) ;;
      *) bad="$bad
$p" ;;
    esac
  done <<EOF
$(jig_ship_staged)
EOF
  bad=$(printf '%s\n' "$bad" | sed '/^$/d')
  if [ -n "$bad" ]; then
    jig_die "spec ship: a declaration commits only $rel/; staged outside it:
$bad"
  fi
  branch="$here"
  if [ "$here" = "$default" ]; then
    # Nothing is committed to the default branch: the declaration gets a
    # branch of its own, and the working tree and index come along unchanged.
    branch=$(_spec_cut_own_branch "$id" "spec ship") || exit 1
    printf 'switched to %s\n' "$branch"
  fi
  spec_ship_steps "$level" "$branch" "$default" "$message_file" "$title" "$body_file"
  [ -z "$line" ] || jig_info "spec ship: once $branch is merged into $default, run \`jig spec epic $id\` to cut ${line% *}"
}

# spec_ship_remove — the removal of a spec that had no open epic: stage only
# its own directory, refuse anything staged outside it, and ship from a branch
# of its own. Never merges.
spec_ship_remove() {
  local id="$1" level="$2" here="$3" default="$4" message_file="$5" title="$6" body_file="$7"
  local rel branch p bad=""
  rel="$JIG_AI_DIR/specs/$id"
  [ -n "$message_file" ] || jig_die "spec ship: removing commits; --message-file is required"
  case "$here" in
    epic/*) jig_die "spec ship: $here is an epic branch; the removal goes into $default from a branch of its own" ;;
  esac
  # Fails when the removal is staged already and nothing of the spec is left in
  # the index or on disk: nothing to add then, and the staged check below
  # says what is there.
  git -C "$JIG_PROJECT" add -A -- "$rel" >/dev/null 2>&1 || true
  jig_ship_check_staged "spec ship"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$rel/"*) ;;
      *) bad="$bad
$p" ;;
    esac
  done <<EOF
$(jig_ship_staged)
EOF
  bad=$(printf '%s\n' "$bad" | sed '/^$/d')
  if [ -n "$bad" ]; then
    jig_die "spec ship: a removal commits only $rel/; staged outside it:
$bad"
  fi
  # Cut a branch only for a removal there is to commit: one already merged
  # leaves nothing staged, and a branch cut for it would be left empty.
  if [ "$here" = "$default" ] && [ -z "$(jig_ship_staged)" ]; then
    jig_die "spec ship: nothing of $rel/ is left to commit; the removal is already in $default"
  fi
  branch="$here"
  if [ "$here" = "$default" ]; then
    branch=$(_spec_cut_own_branch "$id" "spec ship" close) || exit 1
    printf 'switched to %s\n' "$branch"
  fi
  spec_ship_steps "$level" "$branch" "$default" "$message_file" "$title" "$body_file"
}

spec_ship_epic() {
  local id="$1" level="$2" branch="$3"
  [ -z "$(jig_ship_staged)" ] \
    || jig_die "spec ship: pushing $branch commits nothing, and something is staged; commit it through a task or unstage it first"
  git -C "$JIG_PROJECT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 \
    || jig_die "spec ship: $branch is not a local branch here; cut it with \`jig spec epic $id\`"
  if [ "$level" = commit ]; then
    printf "stopped at commit: pushing %s is the human's\n" "$branch"
    return 0
  fi
  # The one ship that sends no commit and means to: an epic is pushed so that
  # it exists on the forge for its tasks to target, and one cut an hour ago
  # has nothing of its own yet (common.sh, "what a ship may send out").
  jig_ship_sends_no_commit "an epic branch is pushed to exist, not to carry a change"
  jig_ship_push "spec ship" "$branch"
}

# The body file spec_ship_final writes for a draft; script-global because the
# exit cleanup that removes it runs after the function returned
# (conventions/shell.md).
_SPEC_SHIP_BODY_TMP=""

# spec_ship_final — the epic's final pull request. At `merge`, in an unattended
# run (`autopilot.unattended`, the key itself: an epic finish belongs to no
# task's run), the merge is the agent's too
# (adr-20260922-unattended-runs-ask-nothing-and-merge-on-green-ci), and only
# after spec_ship_final_ready finds nothing left; the release level the
# roadmap recorded decides first: `major` is never released without a human —
# the pull request opens as a draft that says so — and no `Release:` line
# reads as `minor`. Anywhere else the merge is the human's, as it was.
spec_ship_final() {
  local id="$1" level="$2" branch="$3" default="$4" message_file="$5" title="$6" body_file="$7" here="$8"
  local rel start src release draft=0 unattended=0 head="$8" refused=""
  rel="$JIG_AI_DIR/specs/$id"
  [ -n "$message_file" ] || jig_die "spec ship: the final pull request commits; --message-file is required"
  jig_fetch_branches "spec ship" "$default"
  start=$(jig_fresh_base_ref "$default" "spec ship") || exit 1
  # Checked again although --finish checked it: the default branch may have
  # moved between the finish and the ship.
  if [ "$start" != HEAD ] \
     && ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$start" HEAD 2>/dev/null; then
    jig_die "spec ship: $branch does not contain the latest $default; merge $default into it first"
  fi
  jig_ship_check_staged "spec ship"
  [ -z "$(git -C "$JIG_PROJECT" ls-files --cached -- "$rel/" 2>/dev/null)" ] \
    || jig_die "spec ship: the removal of $rel/ is not staged; stage it with the version bump first"

  src=$(spec_ship_removed_src "$id") || exit 1
  if [ "$level" = merge ] && jig_unattended; then
    [ "$(jig_release_merge)" = agent ] || refused=human
  fi
  if [ "$level" = merge ] && jig_unattended && [ -z "$refused" ]; then
    unattended=1
    release=$(jig_git_show_path "$src" "$rel/roadmap.md" 2>/dev/null \
      | spec_release_check "spec ship" "$rel/roadmap.md") || exit 1
    if [ -z "$release" ]; then
      printf 'release: minor (no Release: line; the unattended default)\n'
    else
      printf 'release: %s\n' "$release"
    fi
    if [ "$release" = major ]; then
      draft=1
      _SPEC_SHIP_BODY_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-spec-body.XXXXXX")
      jig_cleanup_add "$_SPEC_SHIP_BODY_TMP"
      {
        printf 'Needs a human: major release?\n\n'
        if [ -n "$body_file" ]; then cat "$body_file"; else tail -n +2 "$message_file"; fi
      } > "$_SPEC_SHIP_BODY_TMP"
      body_file="$_SPEC_SHIP_BODY_TMP"
    fi
  fi

  # The epic is never pushed to by a finish: where it is protected like the
  # default branch that would need a bypass. The finish and the version bump
  # go on a branch cut from it, and that branch is the pull request's head.
  # Always `finish/<id>`, from the epic or from a branch cut from it: that
  # name is what the `epic-pr` check of CI watches.
  if [ "$here" != "finish/$id" ]; then
    head=$(_spec_cut_own_branch "$id" "spec ship" finish) || exit 1
    printf 'switched to %s\n' "$head"
  fi
  spec_ship_steps "$level" "$head" "$default" "$message_file" "$title" "$body_file" "$draft"
  [ "$level" = merge ] || return 0
  if [ "$refused" = human ]; then
    printf "not merged: release.merge is human in this clone; the release's merge is the person's\n"
    return 0
  fi
  if [ "$unattended" -eq 0 ]; then
    printf "not merged: the epic's final merge is the release, and outside an unattended run it is the human's\n"
    return 0
  fi
  if [ "$draft" -eq 1 ]; then
    printf 'not merged: a major release needs a human; the pull request is a draft\n'
    return 0
  fi
  local left
  left=$(spec_ship_final_ready "$id" "$branch" "$default" "$src")
  if [ -n "$left" ]; then
    printf 'not merged: %s\n' "$left"
    return 0
  fi
  local sha
  sha=$(git -C "$JIG_PROJECT" rev-parse HEAD)
  jig_ship_merge "spec ship" "$JIG_SHIP_URL" "$sha" merge-commit
  # The finish branch goes with the release; the epic is never Jig's to delete
  # (jig_branch_is_jigs, adr-20261007-a-merged-branch-leaves-with-its-work).
  jig_ship_leave "spec ship" "$head" "$default" "$sha"
}

# spec_ship_final_ready <id> <branch> <default> <src> — what still stands in
# the way of merging the epic, as one line, or nothing: the epic behind the
# freshest default branch, the spec back on disk, a roadmap item left
# unchecked (fog is not an item: it is dropped with the spec, and the skill
# quotes it in the pull request), or a task cut from the epic whose branch is
# not in it. Read again right before the merge, not trusted from the finish.
spec_ship_final_ready() {
  local id="$1" branch="$2" default="$3" src="$4" start items tasks
  jig_fetch_branches "spec ship" "$default"
  start=$(jig_fresh_base_ref "$default" "spec ship") || exit 1
  if [ "$start" != HEAD ] \
     && ! git -C "$JIG_PROJECT" merge-base --is-ancestor "$start" HEAD 2>/dev/null; then
    printf '%s does not contain the latest %s\n' "$branch" "$default"
    return 0
  fi
  if [ -e "$(spec_dir)/$id" ]; then
    printf 'the spec %s is on disk again\n' "$id"
    return 0
  fi
  items=$(jig_git_show_path "$src" "$JIG_AI_DIR/specs/$id/roadmap.md" 2>/dev/null | spec_unchecked_items)
  if [ -n "$items" ]; then
    printf 'the epic is not finished: %s roadmap item(s) unchecked, first: %s\n' \
      "$(printf '%s\n' "$items" | wc -l | tr -d ' ')" "${items%%$'\n'*}"
    return 0
  fi
  tasks=$(spec_epic_unmerged_tasks "$branch")
  if [ -n "$tasks" ]; then
    printf 'task(s) cut from %s not merged into it: %s\n' "$branch" "$(printf '%s\n' "$tasks" | tr '\n' ' ' | sed 's/ $//')"
    return 0
  fi
}

# spec_unchecked_items — read a roadmap on stdin and print each unchecked item
# that is real work: not a `fog:` item and not a template `<placeholder>`,
# the way spec_leftovers names them.
spec_unchecked_items() {
  awk '/^[[:space:]]*[-*][[:space:]]+\[ \]/ {
    t = $0; sub(/^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]*/, "", t)
    if (t !~ /^</ && t !~ /^fog:/) print t
  }'
}

# spec_epic_unmerged_tasks <branch> — the ids of the tasks in this checkout's
# workspace cut from <branch> (base_branch) whose own branch is not in HEAD.
# An abandoned or archived task, one never started, and one whose branch exists nowhere
# any more are not counted: there is nothing of theirs left to merge. A task
# merged by squash is counted — its commits are not in the epic, and saying
# so is the safe side.
spec_epic_unmerged_tasks() {
  local want="$1" root dir name state base tbranch status ref
  root="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  [ -d "$root" ] || return 0
  for dir in "$root"/*/; do
    name=${dir%/}
    name=${name##*/}
    jig_valid_id "$name" || continue
    state="$root/$name/state"
    [ -f "$state" ] || continue
    base=$(sed -n 's/^base_branch:[[:space:]]*//p' "$state" | head -n 1)
    [ "$base" = "$want" ] || continue
    status=$(sed -n 's/^status:[[:space:]]*//p' "$state" | head -n 1)
    case "$status" in abandoned | archived) continue ;; esac
    tbranch=$(sed -n 's/^branch:[[:space:]]*//p' "$state" | head -n 1)
    [ -n "$tbranch" ] || continue
    ref=$(jig_base_ref "$tbranch")
    [ -n "$ref" ] || continue
    git -C "$JIG_PROJECT" merge-base --is-ancestor "$ref" HEAD 2>/dev/null || printf '%s\n' "$name"
  done
  return 0
}

# --- closing a spec --------------------------------------------------------------

# spec_leftovers <spec-dir> — what removing the spec would lose, one line each:
# `item: <text>` for every unchecked roadmap item, fog included, and
# `question: <text>` / `assumption: <text>` for every entry of the spec's
# "Open questions" and "Assumptions left untested" sections. The template's own
# `<placeholder>` entries are not leftovers. Only the first line of a wrapped
# entry is printed: enough to name it.
spec_leftovers() {
  local dir="$1"
  if [ -f "$dir/roadmap.md" ]; then
    awk '/^[[:space:]]*[-*][[:space:]]+\[ \]/ {
      t = $0; sub(/^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]*/, "", t)
      if (t !~ /^</) print "item: " t
    }' "$dir/roadmap.md"
  fi
  if [ -f "$dir/spec.md" ]; then
    awk '
      /^## / { kind = ""; if ($0 ~ /^## Open questions[[:space:]]*$/) kind = "question"
               else if ($0 ~ /^## Assumptions left untested[[:space:]]*$/) kind = "assumption"; next }
      kind != "" && /^[-*][[:space:]]+/ {
        t = $0; sub(/^[-*][[:space:]]+/, "", t)
        if (t !~ /^</ && t != "") print kind ": " t
      }' "$dir/spec.md"
  fi
}

# spec_close_dir <id> <who> <handled> — the removal both `spec close` and
# `spec epic --finish` end in: refuse while leftovers are undecided, then move
# the spec to trash like `spec remove` — without unlinking any task: they are
# closed, or the one closing the spec has not landed yet and keeps its link.
spec_close_dir() {
  local id="$1" who="$2" handled="$3" dir leftovers dest rel_dest
  dir="$(spec_dir)/$id"
  leftovers=$(spec_leftovers "$dir")
  if [ -n "$leftovers" ] && [ "$handled" -ne 1 ]; then
    printf '%s\n' "$leftovers" | sed 's/^/  /' >&2
    jig_die "$who: $JIG_AI_DIR/specs/$id still holds what knowledge does not (above); move each one to another spec or task, or drop it, then run again with --leftovers-handled"
  fi
  dest=$(jig_trash_dest "spec-$id")
  rel_dest=${dest#"$JIG_PROJECT"/}
  mkdir -p "${dest%/*}" || jig_die "$who: cannot create ${rel_dest%/*}"
  mv "$dir" "$dest" || jig_die "$who: could not move $JIG_AI_DIR/specs/$id to $rel_dest"
  jig_record_changed
  printf 'removed: %s/specs/%s -> %s\n' "$JIG_AI_DIR" "$id" "$rel_dest"
}

# spec_close <id> [--leftovers-handled] — remove a spec whose work is done, in
# the change that finished it (ADR-0035 as amended). A spec built on an epic is
# closed by `spec epic --finish`, on the epic.
spec_close() {
  [ $# -ge 1 ] || jig_die "spec close: missing spec id (usage: jig spec close <id> [--leftovers-handled])"
  local id="$1" handled=0 dir line rc=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --leftovers-handled) handled=1 ;;
      *) jig_die "spec close: unexpected argument: $1" ;;
    esac
    shift
  done
  spec_valid_id "$id" || jig_die "spec close: invalid spec id: $id"
  jig_require_init
  dir="$(spec_dir)/$id"
  [ -d "$dir" ] || jig_die "spec close: no such spec: $JIG_AI_DIR/specs/$id"
  if [ -f "$dir/roadmap.md" ]; then
    line=$(jig_spec_epic "$dir/roadmap.md") || rc=$?
    if [ "$rc" -eq 2 ] || [ -n "$line" ]; then
      jig_die "spec close: $id is built on an epic; close it with \`jig spec epic $id --finish\` on the epic"
    fi
  fi
  spec_close_dir "$id" "spec close" "$handled"
  jig_info "spec close: commit the removal together with the change that finished the spec, or ship it on its own with \`jig spec ship $id\`"
}

# spec_epic_write <roadmap> declare <branch> [<release>] — add the Epic: line,
# and the Release: line under it when a level is given (replacing any Release:
# line already there), atomically, after the Destination: paragraph; refuses a
# roadmap without one.
spec_epic_write() {
  local roadmap="$1" branch="$3" release="${4:-}" tmp
  tmp="$roadmap.tmp.$$"
  jig_cleanup_add "$tmp"
  # The destination is a paragraph and may wrap: the line goes after the
  # paragraph ends, never inside the sentence.
  awk -v b="$branch" -v r="$release" '
    function declare() { print ""; print "Epic: " b; if (r != "") print "Release: " r }
    r != "" && /^Release:/ { next }
    {
      if (pending && !done && $0 ~ /^[[:space:]]*$/) { declare(); done = 1 }
      print
      if (!pending && $0 ~ /^Destination:/) pending = 1
    }
    END {
      if (done) exit 0
      if (!pending) exit 3
      declare()
    }
  ' "$roadmap" > "$tmp" || {
    rm -f "$tmp"
    jig_die "spec epic: $roadmap has no Destination: line to put the Epic: line after"
  }
  mv "$tmp" "$roadmap" || jig_die "spec epic: could not write $roadmap"
  jig_record_changed
}

# --- task links ----------------------------------------------------------------

# spec_task_dir <task-id> — a task workspace in this checkout. The one place
# spec.sh builds a path from a task id (RULES.md): spec.sh may not source
# task.sh, so it cannot reach task_dir, and checks the same grammar through
# jig_valid_id. Returns 1 for an invalid id instead of dying, because callers
# run it inside $(...), where jig_die would only leave the subshell.
spec_task_dir() {
  jig_valid_id "$1" || return 1
  printf '%s/%s/workspace/tasks/%s\n' "$JIG_PROJECT" "$JIG_AI_DIR" "$1"
}

# spec_task_state <task-dir> <key> — one key of a task's state file, or
# nothing. Read-only: `state` is written by `jig task` alone.
spec_task_state() {
  [ -f "$1/state" ] || return 0
  sed -n "s/^$2:[[:space:]]*//p" "$1/state" | head -n 1
}

# _spec_done_phase_refusal <task-id> <task-dir> — the reason `spec done` must
# not run here, or nothing.
#
# A task of a phase run (`autopilot_phase`, set by `task autopilot start
# --phase`) is one of a wave whose tasks all change neighbouring lines of the
# same roadmap. Checking an item from inside the task's own branch is how
# those branches conflict, so in a phase run the coordinator checks items in
# the epic checkout after the merge, not the agent before it
# (adr-20260922-a-phase-run-is-coordinated). The refusal is narrow on purpose:
# only in the task's own branch, which is where an agent runs, and never in
# the epic checkout the coordinator runs from.
#
# `spec drop` asks the same question with its own name as the third argument:
# closing an abandoned task's item is the same edit of a neighbouring line.
_spec_done_phase_refusal() {
  local tid="$1" tdir="$2" cmd="${3:-done}" phase branch here
  phase=$(spec_task_state "$tdir" autopilot_phase)
  [ -n "$phase" ] || return 0
  branch=$(spec_task_state "$tdir" branch)
  [ -n "$branch" ] || return 0
  here=$(git -C "$JIG_PROJECT" symbolic-ref --short HEAD 2>/dev/null) || here=""
  [ "$here" = "$branch" ] || return 0
  if [ "$cmd" = drop ]; then
    printf 'spec drop: %s runs in phase %s; in a phase run the coordinator rewrites its roadmap item after the merge, in the epic checkout: jig spec drop %s\n' \
      "$tid" "$phase" "$tid"
    return 0
  fi
  printf 'spec done: %s runs in phase %s; in a phase run the coordinator checks items after the merge, in the epic checkout. Leave the roadmap alone and finish consolidation.\n' \
    "$tid" "$phase"
}

# spec_done <task-id> — check the roadmap items that name a linked task.
#
# Called by jig-consolidate when the knowledge decision is recorded, before the
# commit, so the checkmark lands on the base branch in the same change as the
# work (ADR-0035 as amended). An item names the task when its text starts with
# the backticked id and a dash, the grammar `jig spec list` counts as filed.
# A phase run is the exception: see _spec_done_phase_refusal.
spec_done() {
  [ $# -ge 1 ] || jig_die "spec done: missing task id (usage: jig spec done <task-id>)"
  [ $# -eq 1 ] || jig_die "spec done: unexpected argument: $2"
  local tid="$1" tdir sid roadmap tmp out rc=0 refusal
  jig_require_init
  tdir=$(spec_task_dir "$tid") || jig_die "spec done: invalid task id: $tid"
  [ -f "$tdir/task.md" ] || jig_die "spec done: unknown task: $tid (no $JIG_AI_DIR/workspace/tasks/$tid/task.md)"
  refusal=$(_spec_done_phase_refusal "$tid" "$tdir")
  [ -z "$refusal" ] || jig_die "$refusal"
  sid=$(jig_spec_link "$tdir/task.md") || rc=$?
  [ "$rc" = 0 ] || jig_die "spec done: $tid links to more than one spec in its task.md"
  if [ -z "$sid" ]; then
    printf 'spec done: %s is not linked to a spec\n' "$tid"
    return 0
  fi
  [ -d "$(spec_dir)/$sid" ] \
    || jig_die "spec done: $tid links to $JIG_AI_DIR/specs/$sid/, which does not exist"
  roadmap="$(spec_dir)/$sid/roadmap.md"
  [ -f "$roadmap" ] || jig_die "spec done: no roadmap.md in $JIG_AI_DIR/specs/$sid/"

  tmp="$roadmap.tmp.$$"
  jig_cleanup_add "$tmp"
  rc=0
  # Exit 3: no item names the task. Exit 4: every item that does is checked.
  # The id is compared as a string, not a pattern: `.` is legal in an id.
  out=$(awk -v id="$tid" -v tmp="$tmp" '
    {
      line = $0
      if (line ~ /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/) {
        text = line
        sub(/^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/, "", text)
        head = "`" id "`"
        if (substr(text, 1, length(head)) == head &&
            substr(text, length(head) + 1) ~ /^[[:space:]]+(—|-|--)[[:space:]]/) {
          matched++
          if (line ~ /^[[:space:]]*[-*][[:space:]]+\[ \]/) {
            sub(/\[ \]/, "[x]", line)
            marked++
            print line
          }
        }
      }
      print line > tmp
    }
    END {
      close(tmp)
      if (matched == 0) exit 3
      if (marked == 0) exit 4
    }
  ' "$roadmap") || rc=$?
  case "$rc" in
    0)
      mv "$tmp" "$roadmap" || jig_die "spec done: could not write $JIG_AI_DIR/specs/$sid/roadmap.md"
      jig_record_changed
      printf 'spec done: %s checked in %s/specs/%s/roadmap.md\n' "$tid" "$JIG_AI_DIR" "$sid"
      printf '%s\n' "$out" | sed 's/^/  /'
      spec_done_complete_hint "$sid" "$roadmap"
      ;;
    3)
      rm -f "$tmp"
      jig_die "spec done: no item in $JIG_AI_DIR/specs/$sid/roadmap.md names $tid; the roadmap and the task disagree"
      ;;
    4)
      rm -f "$tmp"
      printf 'spec done: %s already done in %s/specs/%s/roadmap.md\n' "$tid" "$JIG_AI_DIR" "$sid"
      ;;
    *)
      rm -f "$tmp"
      jig_die "spec done: could not read $JIG_AI_DIR/specs/$sid/roadmap.md"
      ;;
  esac
}

# _spec_drop_own_branch_refusal <task-id> <task-dir> — why `spec drop` must
# not edit the roadmap here, or nothing: HEAD is the abandoned task's own
# branch, which never ships. An edit there would stay in that tree — in a
# task worktree, one that goes away, and whose dirt keeps it from going — and
# never reach the base. The item waits, unclosed and visible to `spec plan`
# and the lifecycle, for a run on a checkout of the base.
_spec_drop_own_branch_refusal() {
  local tid="$1" tdir="$2" branch here base
  branch=$(spec_task_state "$tdir" branch)
  [ -n "$branch" ] || return 0
  # Only a branch the task was started on is its own: a filed task's
  # recorded branch with no fork point, or a project on one branch
  # (git.branch_per_task: false) whose task records the base itself, is not.
  [ -n "$(spec_task_state "$tdir" base_commit)" ] || return 0
  here=$(git -C "$JIG_PROJECT" symbolic-ref --short HEAD 2>/dev/null) || here=""
  [ "$here" = "$branch" ] || return 0
  base=$(jig_task_base "$tid")
  [ "$branch" != "$base" ] || return 0
  [ "$branch" != "$(cfg git.base_branch main)" ] || return 0
  printf 'spec drop: %s is checked out here on its own branch, which never ships; run jig spec drop %s in a checkout of %s\n' \
    "$tid" "$tid" "$base"
}

# _spec_drop_rewrite <roadmap> <task-id> <suffix> <tmp> — write <roadmap> to
# <tmp> with every unchecked item that names the task checked and <suffix>
# after its last line, and print the rewritten lines. Exit 3: no item names
# the task. Exit 4: every item that does is checked already. The id is
# compared as a string, not a pattern: `.` is legal in an id. A matched item
# is held until the line after its last continuation line, so the suffix ends
# the item rather than its first line. Values reach awk through the
# environment: a `-v` value has its escapes expanded.
_spec_drop_rewrite() {
  local roadmap="$1" tid="$2" suffix="$3" tmp="$4"
  JIG_SD_ID="$tid" JIG_SD_SUFFIX="$suffix" awk -v tmp="$tmp" '
    function flush() {
      if (!held) return
      hold[nh] = hold[nh] ENVIRON["JIG_SD_SUFFIX"]
      for (k = 1; k <= nh; k++) { print hold[k] > tmp; print hold[k] }
      held = 0; nh = 0
    }
    BEGIN { id = ENVIRON["JIG_SD_ID"]; head = "`" id "`" }
    held && /^[[:space:]]+[^[:space:]]/ && !/^[[:space:]]*[-*][[:space:]]/ { hold[++nh] = $0; next }
    {
      flush()
      line = $0
      if (line ~ /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/) {
        text = line
        sub(/^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/, "", text)
        if (substr(text, 1, length(head)) == head &&
            substr(text, length(head) + 1) ~ /^[[:space:]]+(—|-|--)[[:space:]]/) {
          matched++
          if (line ~ /^[[:space:]]*[-*][[:space:]]+\[ \]/) {
            sub(/\[ \]/, "[x]", line)
            marked++
            held = 1; nh = 1; hold[1] = line
            next
          }
        }
      }
      print line > tmp
    }
    END {
      flush()
      close(tmp)
      if (matched == 0) exit 3
      if (marked == 0) exit 4
    }
  ' "$roadmap"
}

# _spec_drop_to_spec_branch <task-id> <spec-id> <roadmap> <suffix> <default>
# — for a spec with no open epic, put HEAD on `spec/<sid>` the way
# `spec resume` does, before the roadmap is edited: the edit is jig's, and
# jig edits a spec on its own branch, never straight on the default one
# (adr-20260930-a-spec-lives-on-its-own-branch-from-the-first-minute).
# Already there: nothing to do. On the default branch: asked first whether
# there is anything to close at all — exit 3 or 4 of _spec_drop_rewrite,
# printed, and the branch stays — then a dirty tree is refused by the rule
# `task start` uses, and the existing branch is switched to (here or on
# origin) or a new one cut. Anywhere else: exit 3, naming the two checkouts
# it runs on. Prints what it says on stdout; returns 1 when nothing is left
# to do.
_spec_drop_to_spec_branch() {
  local tid="$1" sid="$2" roadmap="$3" suffix="$4" default="$5" here branch tmp rc=0
  branch="spec/$sid"
  here=$(git -C "$JIG_PROJECT" symbolic-ref --short HEAD 2>/dev/null) || here=""
  [ "$here" != "$branch" ] || return 0
  if [ "$here" != "$default" ]; then
    printf 'spec drop: %s lands on %s through %s, and neither is checked out here; run jig spec drop %s on %s or on %s\n' \
      "$tid" "$default" "$branch" "$tid" "$default" "$branch" >&2
    exit 3
  fi
  tmp="$roadmap.tmp.$$"
  jig_cleanup_add "$tmp"
  _spec_drop_rewrite "$roadmap" "$tid" "$suffix" "$tmp" >/dev/null || rc=$?
  rm -f "$tmp"
  case "$rc" in
    0) ;;
    3)
      printf 'spec drop: no item in %s/specs/%s/roadmap.md names %s; nothing to rewrite\n' "$JIG_AI_DIR" "$sid" "$tid"
      return 1 ;;
    4)
      printf 'spec drop: %s already closed in %s/specs/%s/roadmap.md\n' "$tid" "$JIG_AI_DIR" "$sid"
      return 1 ;;
    *) jig_die "spec drop: could not read $JIG_AI_DIR/specs/$sid/roadmap.md" ;;
  esac
  _spec_refuse_dirty_tree "spec drop"
  branch=$(_spec_switch_to_existing_branch "$sid" "spec drop") || branch=""
  if [ -z "$branch" ]; then
    branch=$(_spec_cut_own_branch "$sid" "spec drop") || exit 1
  fi
  printf 'spec drop: switched to %s\n' "$branch"
}

# _spec_drop_commit <task-id> <spec-id> <rel-roadmap> <was-clean> — land the
# edit on `spec/<sid>` as a local commit of the roadmap alone, so that neither
# the default branch nor the tree is left holding it and the next `task start`
# is not refused; push and the pull request stay `spec ship`'s. Not at git
# level `none`, where committing is the person's, and not when the roadmap
# already held uncommitted changes, or is not tracked yet (<was-clean> is 0):
# a `jig-idea` session's work on this branch is not jig's to commit, and
# leaves with that session's `spec ship`. Hooks run. Prints the line that says how it
# lands either way.
_spec_drop_commit() {
  local tid="$1" sid="$2" rel="$3" clean="$4" level line key branch reason moved
  branch="spec/$sid"
  line=$(spec_ship_git 2>/dev/null) || line=$'none\tagent.git'
  level=${line%%$'\t'*}
  key=${line#*$'\t'}
  if [ "$level" = none ]; then
    printf "spec drop: %s is none in this clone; commit %s on %s and open its pull request yourself\n" \
      "$key" "$rel" "$branch"
    return 0
  fi
  if [ "$clean" != 1 ]; then
    printf 'spec drop: %s holds changes not committed on %s yet; land them together with jig spec ship %s --message-file <file>\n' \
      "$rel" "$branch" "$sid"
    return 0
  fi
  reason=$(spec_task_state "$(spec_task_dir "$tid")" abandoned_reason)
  moved=$(spec_task_state "$(spec_task_dir "$tid")" moved_to)
  if git -C "$JIG_PROJECT" commit --quiet \
      -m "Close $tid in the roadmap of $sid" \
      -m "${moved:+Moved to $moved. }${reason:-Abandoned.}" \
      -- "$rel" >/dev/null 2>&1; then
    printf 'spec drop: committed %s on %s; land it with jig spec ship %s --message-file <file>\n' \
      "$(git -C "$JIG_PROJECT" rev-parse --short HEAD)" "$branch" "$sid"
  else
    jig_warn "spec drop: could not commit $rel on $branch; commit it yourself, then jig spec ship $sid --message-file <file>"
  fi
}

# spec_drop <task-id> — close the roadmap items that name an abandoned task,
# with why in their text (adr-20261029-an-abandoned-task-says-why-and-its-roadmap-item-follows).
#
# Run by `jig task abandon` through the dispatcher, and by a phase run's
# coordinator in the epic checkout for an item a task branch could not touch.
# The reason, the day and the move's target are read from the task's `state`
# (read only: `state` is `jig task`'s), so a later run writes what abandon
# recorded. An unchecked item that names the task — the grammar `spec done`
# matches — is checked, and its last line, continuation lines included, gets
# ` — moved to <ref> (<day>): <reason>` or ` — dropped (<day>): <reason>`.
# The suffix opens with a dash between spaces, which is where a wave entry's
# title ends (_spec_plan_parse), so the waves still name the item. A checked
# item counts as done everywhere and as closed for the lifecycle: the why is
# in its text, not in a count of its own.
#
# Where the edit is made: a spec with an open epic, on the epic; a spec with
# none, on `spec/<sid>`, switched to or cut from the default branch the way
# `spec resume` does and committed there (_spec_drop_to_spec_branch,
# _spec_drop_commit) — the roadmap is never left edited on the default branch.
#
# Exit 3, with the reason on stderr: in a phase run's task branch, where the
# coordinator closes the item (_spec_done_phase_refusal), in any checkout of
# the task's own branch (_spec_drop_own_branch_refusal), and wherever neither
# the epic nor, for a spec without one, the default branch or `spec/<sid>` is
# checked out. No item naming the task, or every one already checked, is not
# an error: there is nothing left for the roadmap to say. Neither is a spec
# `spec remove` is taking away (JIG_INTERNAL_SPEC_REMOVING): its roadmap goes
# with it, and switching branches under that command would split it in two.
spec_drop() {
  [ $# -ge 1 ] || jig_die "spec drop: missing task id (usage: jig spec drop <task-id>)"
  [ $# -eq 1 ] || jig_die "spec drop: unexpected argument: $2"
  local tid="$1" tdir st from sid roadmap rel tmp out rc=0 refusal day reason moved suffix base
  jig_require_init
  tdir=$(spec_task_dir "$tid") || jig_die "spec drop: invalid task id: $tid"
  [ -f "$tdir/task.md" ] || jig_die "spec drop: unknown task: $tid (no $JIG_AI_DIR/workspace/tasks/$tid/task.md)"
  st=$(spec_task_state "$tdir" status)
  from=$(spec_task_state "$tdir" archived_from)
  case "$st:$from" in
    abandoned:* | archived:abandoned) ;;
    *) jig_die "spec drop: $tid is ${st:-unknown}; abandon it first: jig task abandon $tid --reason <text>" ;;
  esac
  refusal=$(_spec_done_phase_refusal "$tid" "$tdir" drop)
  [ -n "$refusal" ] || refusal=$(_spec_drop_own_branch_refusal "$tid" "$tdir")
  if [ -n "$refusal" ]; then
    printf '%s\n' "$refusal" >&2
    exit 3
  fi
  sid=$(jig_spec_link "$tdir/task.md") || rc=$?
  [ "$rc" = 0 ] || jig_die "spec drop: $tid links to more than one spec in its task.md"
  if [ -z "$sid" ]; then
    printf 'spec drop: %s is not linked to a spec\n' "$tid"
    return 0
  fi
  if [ "${JIG_INTERNAL_SPEC_REMOVING:-}" = "$sid" ]; then
    printf 'spec drop: spec %s is being removed; nothing to rewrite\n' "$sid"
    return 0
  fi
  # A spec that is not here, or has no roadmap yet, has no item to say
  # anything: an ordinary state (`incomplete (no roadmap.md)`), never a reason
  # to fail the abandon that ran this — or `spec remove`, which runs that.
  rel="$JIG_AI_DIR/specs/$sid/roadmap.md"
  roadmap="$(spec_dir)/$sid/roadmap.md"
  if [ ! -f "$roadmap" ]; then
    printf 'spec drop: %s/specs/%s/ has no roadmap.md here; nothing to rewrite\n' "$JIG_AI_DIR" "$sid"
    return 0
  fi

  day=$(spec_task_state "$tdir" abandoned_at)
  [ -n "$day" ] || day=$(jig_today)
  reason=$(spec_task_state "$tdir" abandoned_reason)
  moved=$(spec_task_state "$tdir" moved_to)
  if [ -n "$moved" ]; then
    suffix=" — moved to $moved ($day)"
  else
    suffix=" — dropped ($day)"
  fi
  [ -z "$reason" ] || suffix="$suffix: $reason"

  # Where the edit has to land. A spec with an open epic: the epic, whose copy
  # of the roadmap is the current one, whatever base the task recorded. A
  # spec without one whose task belongs on the default branch: `spec/<sid>`.
  # Anything else: the task's own base when it started, else what `task
  # start` would have cut it from — and only on a checkout of it, since
  # anywhere else the edit would sit in a tree it never leaves.
  local epic="" here here_before="" default on_spec=0 clean=0
  epic=$(jig_spec_epic "$roadmap" 2>/dev/null) || epic=""
  case "$epic" in
    *' open') epic=${epic% open} ;;
    *) epic="" ;;
  esac
  default=$(cfg git.base_branch main)
  base=$epic
  [ -n "$base" ] || base=$(spec_task_state "$tdir" base_branch)
  [ -n "$base" ] || base=$(jig_task_base "$tid")
  if [ -z "$epic" ] && [ "$base" = "$default" ]; then
    on_spec=1
    here_before=$(git -C "$JIG_PROJECT" symbolic-ref --short HEAD 2>/dev/null) || here_before=""
    _spec_drop_to_spec_branch "$tid" "$sid" "$roadmap" "$suffix" "$default" || return 0
    # A `spec/<sid>` left from an earlier session may predate the item the
    # default branch holds: nothing would be closed, and HEAD would have moved
    # for nothing. Back to the default branch, naming what to do.
    rc=0
    if [ -f "$roadmap" ]; then
      tmp="$roadmap.tmp.$$"
      jig_cleanup_add "$tmp"
      _spec_drop_rewrite "$roadmap" "$tid" "$suffix" "$tmp" >/dev/null || rc=$?
      rm -f "$tmp"
    else
      rc=3
    fi
    if [ "$rc" -eq 3 ] && [ "$here_before" = "$default" ]; then
      git -C "$JIG_PROJECT" switch --quiet "$default" >/dev/null 2>&1 \
        || jig_die "spec drop: spec/$sid does not name $tid, and switching back to $default failed"
      printf 'spec drop: spec/%s does not name %s, %s does; switched back to %s. Merge %s into spec/%s, then run jig spec drop %s again\n' \
        "$sid" "$tid" "$default" "$default" "$default" "$sid" "$tid" >&2
      exit 3
    fi
    if [ ! -f "$roadmap" ]; then
      printf 'spec drop: spec/%s has no %s; nothing to rewrite\n' "$sid" "$rel"
      return 0
    fi
    if git -C "$JIG_PROJECT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 \
      && git -C "$JIG_PROJECT" diff --quiet HEAD -- "$rel" 2>/dev/null; then
      clean=1
    fi
  else
    here=$(git -C "$JIG_PROJECT" symbolic-ref --short HEAD 2>/dev/null) || here=""
    if [ "$here" != "$base" ]; then
      printf 'spec drop: %s lands on %s, which is not checked out here; run jig spec drop %s in a checkout of %s\n' \
        "$tid" "$base" "$tid" "$base" >&2
      exit 3
    fi
  fi

  tmp="$roadmap.tmp.$$"
  jig_cleanup_add "$tmp"
  rc=0
  out=$(_spec_drop_rewrite "$roadmap" "$tid" "$suffix" "$tmp") || rc=$?
  case "$rc" in
    0)
      mv "$tmp" "$roadmap" || jig_die "spec drop: could not write $rel"
      jig_record_changed
      printf 'spec drop: %s closed in %s\n' "$tid" "$rel"
      printf '%s\n' "$out" | sed 's/^/  /'
      if [ "$on_spec" = 1 ]; then
        _spec_drop_commit "$tid" "$sid" "$rel" "$clean"
      else
        # On an epic the way a phase run's checkmarks are made: a commit on
        # the epic, by whoever runs this there
        # (adr-20260922-a-phase-run-is-coordinated).
        printf 'spec drop: commit %s on %s now, as the checkmarks of a phase run are\n' "$rel" "$base"
      fi
      spec_done_complete_hint "$sid" "$roadmap"
      ;;
    3)
      rm -f "$tmp"
      printf 'spec drop: no item in %s names %s; nothing to rewrite\n' "$rel" "$tid"
      ;;
    4)
      rm -f "$tmp"
      printf 'spec drop: %s already closed in %s\n' "$tid" "$rel"
      ;;
    *)
      rm -f "$tmp"
      jig_die "spec drop: could not read $rel"
      ;;
  esac
}

# spec_done_complete_hint <spec-id> <roadmap> — say so when no planned item is
# left unchecked: the spec is closed in the change that finished it, and fog
# alone does not keep it open (ADR-0035 as amended).
spec_done_complete_hint() {
  local sid="$1" roadmap="$2" epic
  if awk '/^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]+/ && !/\[ \][[:space:]]+fog:/ { found = 1 } END { exit !found }' "$roadmap"; then
    return 0
  fi
  epic=$(jig_spec_epic "$roadmap" 2>/dev/null) || epic=""
  if [ -n "$epic" ]; then
    printf 'spec done: %s roadmap complete; close it with %s on %s\n' "$sid" "\`jig spec epic $sid --finish\`" "${epic% *}"
  else
    printf 'spec done: %s roadmap complete; close it with %s\n' "$sid" "\`jig spec close $sid\`"
  fi
}

# spec_roadmap_ids <roadmap.md> — task ids named by unchecked items, one per
# line, each once.
spec_roadmap_ids() {
  awk '
    /^[[:space:]]*[-*][[:space:]]+\[ \]/ {
      text = $0
      sub(/^[[:space:]]*[-*][[:space:]]+\[ \][[:space:]]*/, "", text)
      if (text ~ /^`[A-Za-z0-9._-]+`[[:space:]]+(—|-|--)[[:space:]]/) {
        id = substr(text, 2)
        sub(/`.*$/, "", id)
        # The same grammar as jig_valid_id: no leading dot or dash.
        if (id ~ /^[.-]/) next
        if (!(id in seen)) { seen[id] = 1; print id }
      }
    }
  ' "$1"
}

# spec_remove <id> [--dry-run] [--abandon-unstarted] — take a spec out of the
# project: unlink its open tasks in this checkout, optionally abandon the ones
# never started, and move the spec directory to trash.
#
# Tasks are found through their own `Spec:` lines, not the roadmap: the
# roadmap is shared and may not name a task filed here, while workspaces are
# local. Roadmap ids with no workspace here are reported, never guessed at.
# Workspace links are skipped, as housekeeping skips them: a workspace belongs
# to the checkout that filed it (ADR-0029).
#
# Abandoning goes through the dispatcher, `"$JIG_SELF" task abandon`, so a task
# `state` is still written by `jig task` alone. A started task is never
# abandoned: its branch may hold work.
spec_remove() {
  local sid="" dry=0 abandon=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --abandon-unstarted) abandon=1; shift ;;
      -*) jig_die "spec remove: unknown argument: $1" ;;
      *)
        [ -z "$sid" ] || jig_die "spec remove: unexpected argument: $1"
        sid="$1"
        shift
        ;;
    esac
  done
  [ -n "$sid" ] || jig_die "spec remove: missing spec id (usage: jig spec remove <id> [--dry-run] [--abandon-unstarted])"
  spec_valid_id "$sid" || jig_die "spec remove: invalid spec id: $sid"
  jig_require_init

  local root dir expect real
  root=$(spec_dir)
  dir="$root/$sid"
  [ -d "$dir" ] || jig_die "spec remove: no such spec: $JIG_AI_DIR/specs/$sid"
  expect=$(cd "$root" && pwd -P) || jig_die "spec remove: cannot resolve $JIG_AI_DIR/specs"
  real=$(cd "$dir" && pwd -P) || jig_die "spec remove: cannot resolve $JIG_AI_DIR/specs/$sid"
  case "$real" in
    "$expect"/*) ;;
    *) jig_die "spec remove: refusing to move a path outside $JIG_AI_DIR/specs: $real" ;;
  esac

  # Collect every decision before changing anything.
  local tasks_root d tid link lrc st branch base plan="" local_ids=""
  tasks_root="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  # A checkout whose task directory is itself a link owns none of the tasks
  # under it: the link leads into the checkout that filed them, and unlinking
  # a spec here would rewrite another checkout's `task.md` from a branch it
  # knows nothing about. Per task that refusal is the `[ ! -L "$d" ]` skip
  # below; for a borrowed directory the answer is the same for every task at
  # once, and is said rather than left to look like an empty queue.
  local borrowed=0
  # A link above the tasks directory (`.ai/workspace`) leads outside the same
  # way and `-L` on the directory does not see it: the directory must
  # physically be this checkout's own, as spec link asks of one workspace.
  if [ ! -L "$tasks_root" ] && [ -d "$tasks_root" ] \
    && [ "$(cd -P "$tasks_root" 2>/dev/null && pwd -P)" != "$(cd -P "$JIG_PROJECT" 2>/dev/null && pwd -P)/$JIG_AI_DIR/workspace/tasks" ]; then
    borrowed=1
    jig_warn "spec remove: $JIG_AI_DIR/workspace/tasks is not inside this checkout, so no task is unlinked here; run it in the checkout that owns them"
  elif [ -L "$tasks_root" ]; then
    borrowed=1
    jig_warn "spec remove: this checkout borrows its task workspaces, so no task is unlinked here; run it in the checkout that owns them"
  fi
  for d in "$tasks_root"/*/; do
    [ "$borrowed" = 0 ] || break
    d=${d%/}
    [ -d "$d" ] || continue
    [ ! -L "$d" ] || continue
    tid=${d##*/}
    jig_valid_id "$tid" || continue
    local_ids="$local_ids $tid "
    [ -f "$d/task.md" ] || continue
    lrc=0
    link=$(jig_spec_link "$d/task.md") || lrc=$?
    if [ "$lrc" != 0 ]; then
      # A task that links to two specs cannot be unlinked by guessing which
      # line is meant; it is left alone and named when one of them is this
      # spec.
      if spec_links_to "$d/task.md" "$sid"; then
        plan="${plan}conflict $tid
"
      fi
      continue
    fi
    [ "$link" = "$sid" ] || continue
    st=$(spec_task_state "$d" status)
    case "$st" in
      consolidated | abandoned | archived)
        plan="${plan}keep $tid $st
"
        continue
        ;;
    esac
    # Abandon comes before unlink: the `Spec:` line is what finds the task, so
    # removing it first would make a failed abandon impossible to retry — the
    # rerun would no longer see the task at all. An abandoned task that still
    # links is closed, and closed tasks keep their line.
    if [ "$abandon" = 1 ]; then
      branch=$(spec_task_state "$d" branch)
      base=$(spec_task_state "$d" base_commit)
      if [ -z "$branch" ] || [ -z "$base" ]; then
        plan="${plan}abandon $tid
"
      fi
    fi
    plan="${plan}unlink $tid
"
  done
  if [ -f "$dir/roadmap.md" ]; then
    while IFS= read -r tid; do
      [ -n "$tid" ] || continue
      case "$local_ids" in
        *" $tid "*) ;;
        *) plan="${plan}elsewhere $tid
" ;;
      esac
    done < <(spec_roadmap_ids "$dir/roadmap.md")
  fi

  local dest rel_dest action rest
  dest=$(jig_trash_dest "spec-$sid")
  rel_dest=${dest#"$JIG_PROJECT"/}

  while IFS=' ' read -r action tid rest; do
    [ -n "$action" ] || continue
    case "$action" in
      unlink)
        if [ "$dry" = 1 ]; then
          printf 'would-unlink   %s\n' "$tid"
          continue
        fi
        spec_unlink_task "$tasks_root/$tid/task.md" "$sid" \
          || jig_die "spec remove: could not unlink $tid; nothing else was changed after it"
        printf 'unlinked       %s\n' "$tid"
        ;;
      abandon)
        if [ "$dry" = 1 ]; then
          printf 'would-abandon  %s (not started)\n' "$tid"
          continue
        fi
        JIG_INTERNAL_SPEC_REMOVING="$sid" "$JIG_SELF" task abandon "$tid" --reason "spec $sid removed" >/dev/null \
          || jig_die "spec remove: could not abandon $tid; the spec was not moved"
        printf 'abandoned      %s (not started)\n' "$tid"
        ;;
      keep) printf 'kept           %s (%s)\n' "$tid" "$rest" ;;
      conflict) printf 'kept           %s (links to more than one spec)\n' "$tid" ;;
      elsewhere) printf 'not-here       %s (named in the roadmap, no workspace in this checkout)\n' "$tid" ;;
    esac
  done < <(printf '%s' "$plan")

  if [ "$dry" = 1 ]; then
    printf 'would-move     %s/specs/%s -> %s\n' "$JIG_AI_DIR" "$sid" "$rel_dest"
    return 0
  fi
  mkdir -p "${dest%/*}" || jig_die "spec remove: cannot create ${rel_dest%/*}"
  mv "$dir" "$dest" || jig_die "spec remove: could not move $JIG_AI_DIR/specs/$sid to $rel_dest"
  jig_record_changed
  printf 'moved          %s/specs/%s -> %s\n' "$JIG_AI_DIR" "$sid" "$rel_dest"
}

# spec_link <spec-id> <task-id> — link a task that is already filed to a spec:
# write its `Spec: .ai/specs/<spec-id>/ — Phase <n>` line, the line `jig-idea`
# §10 writes for a task filed from a roadmap item, under the first heading of
# its task.md. The opposite of what `spec remove` does to the same line
# (adr-20261002-a-release-is-a-spec-with-an-epic).
#
# The phase is read from the roadmap, never given: the item that names the
# task (`` `<task-id>` — ``) sits under one `## Phase <n>` heading, and a
# second source could disagree with it. The roadmap item is the agent's to
# write first; this command checks that the roadmap and the task agree, the
# condition `spec done` later stands on.
#
# A started task is refused: its branch was cut when it started, from the
# default branch, and it reaches an epic only by being rewritten. It ships
# where it was cut from, and an epic gets it when the default branch is merged
# into it — which `spec epic --finish` requires anyway. A borrowed task
# directory is refused as `spec remove` refuses it: the task.md belongs to the
# checkout that filed it.
spec_link() {
  [ $# -ge 2 ] || jig_die "spec link: missing argument (usage: jig spec link <spec-id> <task-id>)"
  [ $# -eq 2 ] || jig_die "spec link: unexpected argument: $3"
  local sid="$1" tid="$2" roadmap tdir tasks_root st branch link rc=0 phases count phase line real phys
  spec_valid_id "$sid" || jig_die "spec link: invalid spec id: $sid"
  jig_valid_id "$tid" || jig_die "spec link: invalid task id: $tid"
  jig_require_init
  roadmap="$(spec_dir)/$sid/roadmap.md"
  [ -d "$(spec_dir)/$sid" ] || jig_die "spec link: no such spec in this checkout: $JIG_AI_DIR/specs/$sid"
  [ -f "$roadmap" ] || jig_die "spec link: $JIG_AI_DIR/specs/$sid has no roadmap.md"
  tasks_root="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  [ ! -L "$tasks_root" ] \
    || jig_die "spec link: this checkout borrows its task workspaces; run it in the checkout that owns them"
  tdir=$(spec_task_dir "$tid") || jig_die "spec link: invalid task id: $tid"
  [ ! -L "$tdir" ] || jig_die "spec link: the workspace of $tid is a link; run it in the checkout that owns it"
  [ -f "$tdir/task.md" ] || jig_die "spec link: unknown task: $tid (no $JIG_AI_DIR/workspace/tasks/$tid/task.md)"
  # A link anywhere above the workspace (`.ai/workspace` too) would carry the
  # write out of this checkout: the workspace must physically be the one this
  # checkout keeps. spec.sh sources no other command library, so the check is
  # the plain comparison, and a borrowing checkout is refused as above.
  real=$(cd -P "$JIG_PROJECT" 2>/dev/null && pwd -P) || real=""
  phys=""
  [ -z "$real" ] || phys=$(cd -P "$tdir" 2>/dev/null && pwd -P) || phys=""
  if [ -z "$real" ] || [ "$phys" != "$real/$JIG_AI_DIR/workspace/tasks/$tid" ]; then
    jig_die "spec link: the workspace of $tid is not inside this checkout; run it in the checkout that owns it"
  fi

  st=$(spec_task_state "$tdir" status)
  case "$st" in
    consolidated | abandoned | archived) jig_die "spec link: $tid is $st; only a live task is linked" ;;
  esac
  link=$(jig_spec_link "$tdir/task.md") || rc=$?
  [ "$rc" = 0 ] || jig_die "spec link: $tid links to more than one spec in its task.md"
  if [ "$link" = "$sid" ]; then
    printf 'spec link: %s already linked to %s\n' "$tid" "$sid"
    return 0
  fi
  [ -z "$link" ] || jig_die "spec link: $tid is linked to spec $link; unlink it there first"
  branch=$(spec_task_state "$tdir" branch)
  [ -z "$branch" ] \
    || jig_die "spec link: $tid is started on $branch; a started task is not moved — ship it where it was cut from, and an epic gets it when the default branch is merged into it"

  # Every phase whose items name the task, once each; `-` for an item above
  # the first `## Phase` heading.
  phases=$(awk -v id="$tid" '
    /^##[[:space:]]/ {
      phase = "-"
      h = $0
      sub(/^##[[:space:]]+/, "", h)
      if (h ~ /^Phase[[:space:]]+[0-9]+/) {
        sub(/^Phase[[:space:]]+/, "", h)
        sub(/[^0-9].*$/, "", h)
        phase = h
      }
      next
    }
    /^[[:space:]]*[-*][[:space:]]+\[[ xX]\]/ {
      text = $0
      sub(/^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]*/, "", text)
      head = "`" id "`"
      if (substr(text, 1, length(head)) == head &&
          substr(text, length(head) + 1) ~ /^[[:space:]]+(—|-|--)[[:space:]]/) {
        p = (phase == "" ? "-" : phase)
        if (!(p in seen)) { seen[p] = 1; print p }
      }
    }
  ' "$roadmap")
  [ -n "$phases" ] \
    || jig_die "spec link: no item in $JIG_AI_DIR/specs/$sid/roadmap.md names $tid; add \`- [ ] \`$tid\` — <goal>\` to its phase first"
  count=$(printf '%s\n' "$phases" | wc -l | tr -d ' ')
  [ "$count" = 1 ] \
    || jig_die "spec link: items naming $tid sit in more than one phase of $JIG_AI_DIR/specs/$sid/roadmap.md; keep them in one"
  phase="$phases"
  if [ "$phase" = - ]; then
    line="Spec: .ai/specs/$sid/"
  else
    line="Spec: .ai/specs/$sid/ — Phase $phase"
  fi
  spec_link_task "$tdir/task.md" "$line" || jig_die "spec link: could not write $JIG_AI_DIR/workspace/tasks/$tid/task.md"
  printf 'spec link: %s linked: %s\n' "$tid" "$line"
}

# spec_link_task <task.md> <line> — put <line> under the first `# ` heading,
# after a blank line, or at the top when there is none. Written atomically.
spec_link_task() {
  local file="$1" line="$2" tmp
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  if ! JIG_SL_LINE="$line" awk '
    { lines[NR] = $0; if (!at && /^# /) at = NR }
    END {
      if (!at) { print ENVIRON["JIG_SL_LINE"]; print "" }
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (i == at) { print ""; print ENVIRON["JIG_SL_LINE"] }
      }
    }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  jig_record_changed
}

# spec_links_to <task.md> <spec-id> — whether any `Spec:` line names exactly
# <spec-id>. The id is compared as a string: `.` is legal in an id, and as a
# pattern it would match `a.b` against `axb`.
spec_links_to() {
  awk -v sid="$2" '
    /^Spec: \.ai\/specs\// {
      id = $0
      sub(/^Spec: \.ai\/specs\//, "", id)
      sub(/\/.*$/, "", id)
      if (id == sid) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# spec_unlink_task <task.md> <spec-id> — drop the task's `Spec:` lines that
# link to <spec-id>, and nothing else. Written atomically.
spec_unlink_task() {
  local file="$1" sid="$2" tmp
  tmp="$file.tmp.$$"
  jig_cleanup_add "$tmp"
  if ! awk -v sid="$sid" '
    /^Spec: \.ai\/specs\// {
      id = $0
      sub(/^Spec: \.ai\/specs\//, "", id)
      sub(/\/.*$/, "", id)
      if (id == sid) next
    }
    { print }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  jig_record_changed
}
