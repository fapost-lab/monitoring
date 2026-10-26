# jig queue — priority, order and dependencies of tasks and epics, one queue
# per clone (adr-20261019-the-queue-is-one-file-written-against-a-revision).
#
# The queue is one file, `.ai/runtime/queue` in the clone's main checkout
# (jig_config_clone_root), shared by every worktree and never under git. This
# command is its only writer. Every write is checked against the clone revision
# its caller read (`--revision <n>`, or the one this command reads itself before
# it reads the queue): it claims the revision right above that one
# (jig_revision_claim) and is refused with the failure code `stale-revision`
# when anybody wrote since. The new file is built first and moved into place
# whole, so a reader sees the old queue or the new one, never half of either.
#
# The format, one record per line, fields separated by a tab:
#
#   # jig queue 1 — ...                    the version of the format, first line
#   item <ref> <level> <position> <priority>
#   dep  <ref> <on-ref> <reason>
#   request <ref> <kind> <requested_at> <reason>
#
# <ref> is `task:<id>` or `epic:<spec-id>`; <level> is `-` (the top) or the
# `epic:<spec-id>` a task is built on; <position> a non-negative integer,
# sparse (step 100) and compared only within a level; <priority> `0` (most
# urgent) to `5`, or `-`. A request is a person's ask a running task honours
# at its next stage boundary (adr-20261019-a-pause-request-is-honoured-at-the-
# stage-boundary): <ref> a `task:<id>`, <kind> `pause`, <requested_at> UTC
# `YYYY-MM-DDTHH:MM:SSZ`, <reason> one line, possibly empty. A line of any
# other kind is kept as it is, so a later record kind does not lose its lines
# to a writer that predates it. A file of another format version is refused,
# never rewritten.
# shellcheck shell=bash

QUEUE_USAGE="usage: jig queue [list] [--json] | jig queue next [--json] | jig queue set <ref> --priority <0-5|none> | jig queue move <ref> (--before <ref> | --after <ref> | --top | --bottom) | jig queue depend <ref> --on <ref> --reason <text> | jig queue undepend <ref> --on <ref> | jig queue remove <ref> | jig queue request <ref> pause [--reason <text>] | jig queue cancel <ref> pause; every write takes [--revision <n>] [--json]; <ref> is task:<id>, epic:<spec-id> or <id>"

QUEUE_FORMAT=$_JIG_QUEUE_FORMAT
QUEUE_STEP=100

# Set by cmd_queue when `--json` is among the arguments; the producer runs in
# json_run's subshell and inherits it.
_QUEUE_AS_JSON=""

# cmd_queue — `--json` anywhere runs the whole command as the producer of
# json_run (conventions/json-output.md), so every refusal is an envelope too.
cmd_queue() {
  local arg
  for arg in "$@"; do
    if [ "$arg" = --json ]; then
      _QUEUE_AS_JSON=1
      # shellcheck source=lib/json.sh
      . "$JIG_LIB/json.sh"
      json_run _queue_main "$@"
      return
    fi
  done
  _queue_main "$@"
}

_queue_main() {
  local sub="list" arg args=()
  for arg in "$@"; do
    [ "$arg" = --json ] || args+=("$arg")
  done
  if [ "${#args[@]}" -gt 0 ]; then
    sub=${args[0]}
    args=("${args[@]:1}")
  fi
  case "$sub" in
    list) _queue_list ${args[@]+"${args[@]}"} ;;
    next) _queue_next ${args[@]+"${args[@]}"} ;;
    set | move | depend | undepend | remove | request | cancel) _queue_write "$sub" ${args[@]+"${args[@]}"} ;;
    help | -h | --help) printf '%s\n' "$QUEUE_USAGE" ;;
    *) jig_fail usage "queue: unknown subcommand: $sub; $QUEUE_USAGE" ;;
  esac
}

# --- where the queue is -------------------------------------------------------

# queue_file — the queue's path in the clone's main checkout; common.sh's
# answer, which `task` reads the pause requests by too.
queue_file() {
  jig_queue_file
}

# --- references -----------------------------------------------------------------

# _queue_ref <text> <what> — _QREF <- the canonical reference `task:<id>` or
# `epic:<id>`, _QKIND and _QID its parts. A bare id is a task. Refused with
# `usage` when it is not a reference at all, and with `not-found` when it names
# no task or epic of this clone: a task has a state file in the workspace, an
# epic is a spec in this checkout whose roadmap declares an epic branch. The id
# passes jig_valid_id before it becomes a path (RULES.md).
_QREF=""
_QKIND=""
_QID=""
_queue_ref() {
  local rc=0 line
  _queue_ref_form "$1" "$2"
  if [ "$_QKIND" = task ]; then
    [ -f "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$_QID/state" ] \
      || jig_fail not-found "queue: no task $_QID in this clone"
    return 0
  fi
  [ -f "$JIG_PROJECT/$JIG_AI_DIR/specs/$_QID/roadmap.md" ] \
    || jig_fail not-found "queue: no spec $_QID in this checkout"
  line=$(jig_spec_epic "$JIG_PROJECT/$JIG_AI_DIR/specs/$_QID/roadmap.md") || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$line" ]; then
    jig_fail not-found "queue: spec $_QID declares no epic (one Epic: line in its roadmap)"
  fi
  return 0
}

# _queue_ref_form <text> <what> — _queue_ref's grammar alone: _QREF, _QKIND
# and _QID, refused with `usage` when <text> is not a reference, and nothing
# asked about what it names.
_queue_ref_form() {
  local text="$1" what="$2"
  case "$text" in
    task:*) _QKIND=task; _QID=${text#task:} ;;
    epic:*) _QKIND=epic; _QID=${text#epic:} ;;
    *:*) jig_fail usage "queue: $what is not task:<id>, epic:<id> or <id>: $text" ;;
    *) _QKIND=task; _QID=$text ;;
  esac
  jig_valid_id "$_QID" || jig_fail usage "queue: $what is not a valid id: $text"
  _QREF="$_QKIND:$_QID"
}

# _queue_level <kind> <id> — _QLEVEL <- the level the item belongs to: `-` for
# an epic and for a task built on no epic, `epic:<spec>` for a task built on
# its spec's open epic (jig_task_epic: the answer `task start` cuts by). A task
# whose record makes that answer a guess — two Spec: lines, two Epic: lines —
# is refused, as `task start` refuses it. A spec this checkout does not have
# and a finished epic put the task on the top level, where `task start`
# refuses: the queue records where work sits, and a write from a worktree
# without the spec is the accepted risk of
# adr-20261019-the-queue-is-one-file-written-against-a-revision.
_QLEVEL="-"
_queue_level() {
  local rc=0
  _QLEVEL="-"
  [ "$1" = task ] || return 0
  jig_task_epic "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$2/task.md" || rc=$?
  case "$rc" in
    2) jig_die "queue: task $2 links to more than one spec; keep one Spec: line" ;;
    4) jig_die "queue: spec $_JIG_TASK_SPEC declares more than one epic; keep one Epic: line" ;;
  esac
  [ "$_JIG_TASK_EPIC_STATE" != open ] || _QLEVEL="epic:$_JIG_TASK_SPEC"
  return 0
}

# --- the file -------------------------------------------------------------------

# _queue_apply <file> — print the queue <file> (absent: empty) with one change
# applied, in canonical order: items by level (the top first) and position,
# then dependencies, then requests (by reference and kind), then the lines of
# other kinds as they were. The change comes through the environment
# (conventions/shell.md: free text never through `awk -v`): Q_OP
# set|move|depend|undepend|remove|request|cancel|read, Q_REF, Q_LEVEL, Q_PRIO,
# Q_PLACE top|bottom|before|after, Q_ANCHOR, Q_ON, Q_REASON, Q_KIND, Q_AT.
# Exit status names a refusal: 3 the anchor is not in the queue, 4 the anchor
# is on another level, 5 a reference to itself, 6 another format version, 7 a
# dependency cycle, 8 the item, dependency or request is not in the queue, 9
# the request is already there.
_queue_apply() {
  local file="$1"
  [ -f "$file" ] || file=/dev/null
  Q_FORMAT="$QUEUE_FORMAT" Q_STEP="$QUEUE_STEP" awk -F '\t' '
    function num(s) { return s + 0 }
    function before(a, b) {   # item a sorts before item b
      if (lvl[a] != lvl[b]) {
        if (lvl[a] == "-") return 1
        if (lvl[b] == "-") return 0
        return lvl[a] < lvl[b]
      }
      if (num(pos[a]) != num(pos[b])) return num(pos[a]) < num(pos[b])
      return ref[a] < ref[b]
    }
    function maxpos(level,   i, m) {
      m = 0
      for (i = 1; i <= n; i++) if (alive[i] && lvl[i] == level && num(pos[i]) > m) m = num(pos[i])
      return m
    }
    function add(r, level,   i) {
      i = ++n; ref[i] = r; lvl[i] = level; pri[i] = "-"; alive[i] = 1; idx[r] = i
      pos[i] = maxpos(level) + step
      return i
    }
    # place item i into its level at the place asked: between its neighbours
    # when there is room, otherwise the whole level respaced in this one write.
    function place(i, how, anchor,   m, j, k, s, t, lo, hi, a) {
      m = 0
      for (j = 1; j <= n; j++) if (alive[j] && j != i && lvl[j] == lvl[i]) s[++m] = j
      for (j = 2; j <= m; j++) { t = s[j]; k = j - 1
        while (k >= 1 && before(t, s[k])) { s[k + 1] = s[k]; k-- }
        s[k + 1] = t }
      if (how == "top") k = 0
      else if (how == "bottom") k = m
      else {
        a = idx[anchor]
        for (j = 1; j <= m; j++) if (s[j] == a) break
        k = (how == "before") ? j - 1 : j
      }
      lo = (k > 0) ? num(pos[s[k]]) : 0
      if (k == m) { pos[i] = lo + step; return }
      hi = num(pos[s[k + 1]])
      if (hi - lo >= 2) { pos[i] = lo + int((hi - lo) / 2); return }
      t = 0
      for (j = 1; j <= m; j++) {
        if (j == k + 1) pos[i] = (++t) * step
        pos[s[j]] = (++t) * step
      }
    }
    function reaches(from, to,   j, seen, stack, sp, cur) {
      sp = 0; stack[++sp] = from
      while (sp > 0) {
        cur = stack[sp--]
        if (cur == to) return 1
        if (cur in seen) continue
        seen[cur] = 1
        for (j = 1; j <= dn; j++) if (dalive[j] && dsub[j] == cur) stack[++sp] = don[j]
      }
      return 0
    }
    BEGIN {
      step = ENVIRON["Q_STEP"] + 0
      op = ENVIRON["Q_OP"]; r = ENVIRON["Q_REF"]; level = ENVIRON["Q_LEVEL"]
      n = 0; dn = 0; on = 0; rn = 0
    }
    FNR == 1 && /^# jig queue / {
      split($0, w, " ")
      if (w[4] != ENVIRON["Q_FORMAT"]) { bad = 6; exit 6 }
      next
    }
    /^#/ || /^[ \t]*$/ { next }
    $1 == "item" && NF >= 5 {
      if ($2 in idx) next
      i = ++n; ref[i] = $2; lvl[i] = $3; pos[i] = $4; pri[i] = $5; alive[i] = 1; idx[$2] = i
      next
    }
    $1 == "dep" && NF >= 4 {
      k = $2 SUBSEP $3
      if (k in didx) next
      j = ++dn; dsub[j] = $2; don[j] = $3; drea[j] = $4; dalive[j] = 1; didx[k] = j
      next
    }
    $1 == "request" && NF >= 4 {
      k = $2 SUBSEP $3
      if (k in ridx) next
      j = ++rn; rsub[j] = $2; rkind[j] = $3; rat[j] = $4; rrea[j] = $5; ralive[j] = 1; ridx[k] = j
      next
    }
    { other[++on] = $0 }
    END {
      if (bad) exit bad
      if (op == "set" || op == "move" || op == "depend") {
        if (r in idx) {
          i = idx[r]
          if (lvl[i] != level) { lvl[i] = level; pos[i] = maxpos(level) + step }
          fresh = 0
        } else { i = add(r, level); fresh = 1 }
      }
      if (op == "set") pri[i] = ENVIRON["Q_PRIO"]
      else if (op == "move") {
        how = ENVIRON["Q_PLACE"]; anchor = ENVIRON["Q_ANCHOR"]
        if (how == "before" || how == "after") {
          if (anchor == r) exit 5
          if (!(anchor in idx)) exit 3
          if (lvl[idx[anchor]] != lvl[i]) exit 4
        }
        place(i, how, anchor)
      } else if (op == "depend") {
        o = ENVIRON["Q_ON"]
        if (o == r) exit 5
        if (reaches(o, r)) exit 7
        k = r SUBSEP o
        if (k in didx) drea[didx[k]] = ENVIRON["Q_REASON"]
        else { j = ++dn; dsub[j] = r; don[j] = o; drea[j] = ENVIRON["Q_REASON"]; dalive[j] = 1; didx[k] = j }
      } else if (op == "undepend") {
        k = r SUBSEP ENVIRON["Q_ON"]
        if (!(k in didx)) exit 8
        dalive[didx[k]] = 0
      } else if (op == "request") {
        k = r SUBSEP ENVIRON["Q_KIND"]
        if (k in ridx) exit 9
        j = ++rn; rsub[j] = r; rkind[j] = ENVIRON["Q_KIND"]; rat[j] = ENVIRON["Q_AT"]
        rrea[j] = ENVIRON["Q_REASON"]; ralive[j] = 1; ridx[k] = j
      } else if (op == "cancel") {
        k = r SUBSEP ENVIRON["Q_KIND"]
        if (!(k in ridx)) exit 8
        ralive[ridx[k]] = 0
      } else if (op == "remove") {
        if (!(r in idx)) exit 8
        alive[idx[r]] = 0
        for (j = 1; j <= dn; j++) if (dsub[j] == r) dalive[j] = 0
      }
      m = 0
      for (j = 1; j <= n; j++) if (alive[j]) s[++m] = j
      for (j = 2; j <= m; j++) { t = s[j]; k = j - 1
        while (k >= 1 && before(t, s[k])) { s[k + 1] = s[k]; k-- }
        s[k + 1] = t }
      printf "# jig queue %s — written by `jig queue` only; do not edit by hand\n", ENVIRON["Q_FORMAT"]
      for (j = 1; j <= m; j++) printf "item\t%s\t%s\t%.0f\t%s\n", ref[s[j]], lvl[s[j]], num(pos[s[j]]), pri[s[j]]
      md = 0
      for (j = 1; j <= dn; j++) if (dalive[j]) d[++md] = j
      for (j = 2; j <= md; j++) { t = d[j]; k = j - 1
        while (k >= 1 && (dsub[t] < dsub[d[k]] || (dsub[t] == dsub[d[k]] && don[t] < don[d[k]]))) { d[k + 1] = d[k]; k-- }
        d[k + 1] = t }
      for (j = 1; j <= md; j++) printf "dep\t%s\t%s\t%s\n", dsub[d[j]], don[d[j]], drea[d[j]]
      mr = 0
      for (j = 1; j <= rn; j++) if (ralive[j]) q[++mr] = j
      for (j = 2; j <= mr; j++) { t = q[j]; k = j - 1
        while (k >= 1 && (rsub[t] < rsub[q[k]] || (rsub[t] == rsub[q[k]] && rkind[t] < rkind[q[k]]))) { q[k + 1] = q[k]; k-- }
        q[k + 1] = t }
      for (j = 1; j <= mr; j++) printf "request\t%s\t%s\t%s\t%s\n", rsub[q[j]], rkind[q[j]], rat[q[j]], rrea[q[j]]
      for (j = 1; j <= on; j++) print other[j]
    }
  ' "$file"
}

# _queue_commit <expected> <new> <file> — land the queue built in <new> as
# <file>, if nobody wrote in this clone since revision <expected>: claim the
# revision above it (jig_revision_claim), move the file into place, then raise
# the revision again (jig_record_changed), because the claim raised it before
# the write landed and a read in between took the old queue with it.
_queue_commit() {
  local expected="$1" new="$2" file="$3" rc=0
  jig_revision_claim "$expected" || rc=$?
  case "$rc" in
    0) ;;
    1) jig_fail stale-revision "queue: the clone changed since revision $expected; read the queue again and retry" ;;
    *) jig_die "queue: cannot claim the clone revision in $(jig_revision_dir)" ;;
  esac
  mv "$new" "$file"
  jig_record_changed
}

# --- writes ---------------------------------------------------------------------

_queue_need_value() {
  [ "$2" -ge 2 ] || jig_fail usage "queue: $1 requires a value"
}

_queue_write() {
  local sub="$1" target="" rev="" rev_given="" prio="" place="" anchor="" on="" reason="" seen_reason=""
  local file new rc=0 expected ref level kind="" at="" refusal
  shift
  [ $# -ge 1 ] || jig_fail usage "queue $sub: missing <ref>; $QUEUE_USAGE"
  case "$1" in
    -*) jig_fail usage "queue $sub: missing <ref> before $1; $QUEUE_USAGE" ;;
  esac
  target=$1
  shift
  if [ "$sub" = request ] || [ "$sub" = cancel ]; then
    # What is asked, after the reference: `pause` is the one kind there is.
    [ $# -ge 1 ] || jig_fail usage "queue $sub: missing the kind after $target (pause); $QUEUE_USAGE"
    kind=$1
    shift
    [ "$kind" = pause ] || jig_fail usage "queue $sub: unknown kind: $kind (expected pause)"
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --revision) _queue_need_value "$1" $#; rev=$2; rev_given=1; shift 2 ;;
      --priority)
        [ "$sub" = set ] || jig_fail usage "queue $sub: unexpected argument: $1"
        _queue_need_value "$1" $#; prio=$2; shift 2 ;;
      --before | --after)
        [ "$sub" = move ] || jig_fail usage "queue $sub: unexpected argument: $1"
        _queue_need_value "$1" $#
        [ -z "$place" ] || jig_fail usage "queue move: give one of --before, --after, --top, --bottom"
        place=${1#--}; anchor=$2; shift 2 ;;
      --top | --bottom)
        [ "$sub" = move ] || jig_fail usage "queue $sub: unexpected argument: $1"
        [ -z "$place" ] || jig_fail usage "queue move: give one of --before, --after, --top, --bottom"
        place=${1#--}; shift ;;
      --on)
        [ "$sub" = depend ] || [ "$sub" = undepend ] || jig_fail usage "queue $sub: unexpected argument: $1"
        _queue_need_value "$1" $#; on=$2; shift 2 ;;
      --reason)
        [ "$sub" = depend ] || [ "$sub" = request ] || jig_fail usage "queue $sub: unexpected argument: $1"
        _queue_need_value "$1" $#; reason=$2; seen_reason=1; shift 2 ;;
      *) jig_fail usage "queue $sub: unexpected argument: $1" ;;
    esac
  done
  [ -z "$rev_given" ] || [ -n "$rev" ] || jig_fail usage "queue: --revision is empty"
  [ -z "$rev" ] || jig_revision_valid "$rev" || jig_fail usage "queue: --revision is not a revision: $rev"
  case "$sub" in
    set)
      [ -n "$prio" ] || jig_fail usage "queue set: --priority is required"
      case "$prio" in
        [0-5]) ;;
        none) prio="-" ;;
        *) jig_fail usage "queue set: --priority is 0 (most urgent) to 5, or none: $prio" ;;
      esac ;;
    move) [ -n "$place" ] || jig_fail usage "queue move: give one of --before, --after, --top, --bottom" ;;
    depend)
      [ -n "$on" ] || jig_fail usage "queue depend: --on is required"
      [ -n "$seen_reason" ] || jig_fail usage "queue depend: --reason is required: a dependency without a reason is not one"
      # One line in the file: tabs and line breaks become spaces.
      reason=$(printf '%s' "$reason" | tr '\t\r\n' '   ')
      case "$reason" in
        *[![:space:]]*) ;;
        *) jig_fail usage "queue depend: --reason is empty" ;;
      esac ;;
    undepend) [ -n "$on" ] || jig_fail usage "queue undepend: --on is required" ;;
    request)
      # One line in the file, as a dependency's reason; an empty one is none.
      reason=$(printf '%s' "$reason" | tr '\t\r\n' '   ')
      case "$reason" in
        *[![:space:]]*) ;;
        *) reason="" ;;
      esac ;;
  esac

  jig_require_init
  # The revision this write is checked against: the caller's, or the one read
  # here before the queue is, so the queue read below is never newer than it.
  if [ -n "$rev" ]; then
    expected=$rev
  else
    expected=$(jig_revision_read)
  fi

  if [ "$sub" = remove ] || [ "$sub" = undepend ] || [ "$sub" = cancel ]; then
    # Taking something out needs nothing behind the reference: the task may
    # have gone to trash, the spec been retired, and the item must still go.
    _queue_ref_form "$target" "<ref>"
    level="-"
  elif [ "$sub" = request ]; then
    _queue_ref "$target" "<ref>"
    level="-"
  else
    _queue_ref "$target" "<ref>"
    _queue_level "$_QKIND" "$_QID"
    level=$_QLEVEL
  fi
  ref=$_QREF
  if [ -n "$kind" ]; then
    [ "$_QKIND" = task ] || jig_fail usage "queue $sub: a $kind is asked of a task, not of $ref"
    if [ "$sub" = request ]; then
      # The table of what a person may do asks the same guard (common.sh).
      # The table of what a person may do asks the same guards (common.sh).
      # The task's state is refused before the request's presence, so a
      # paused or closed task that still holds a request reads `failed`.
      refusal=$(jig_pause_request_state_refusal "$_QID")
      [ -z "$refusal" ] || jig_die "$refusal"
      refusal=$(jig_pause_request_refusal "$_QID")
      [ -z "$refusal" ] || jig_fail already-exists "$refusal"
      at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fi
  fi
  if [ -n "$anchor" ]; then
    # An anchor that names nothing in this clone, or is not queued, is not-found.
    _queue_ref "$anchor" "--$place"
    anchor=$_QREF
  fi
  if [ -n "$on" ]; then
    if [ "$sub" = depend ]; then
      _queue_ref "$on" "--on"
      on=$_QREF
    else
      # Undepend needs no task behind the reference: it may be gone.
      _queue_ref_form "$on" "--on"
      on=$_QREF
    fi
  fi

  file=$(queue_file)
  mkdir -p "${file%/*}" || jig_die "queue: cannot create ${file%/*}"
  new="$file.tmp.$$"
  jig_cleanup_add "$new"
  rc=0
  Q_OP="$sub" Q_REF="$ref" Q_LEVEL="$level" Q_PRIO="$prio" Q_PLACE="$place" \
    Q_ANCHOR="$anchor" Q_ON="$on" Q_REASON="$reason" Q_KIND="$kind" Q_AT="$at" \
    _queue_apply "$file" > "$new" || rc=$?
  case "$rc" in
    0) ;;
    3) jig_fail not-found "queue move: $anchor is not in the queue" ;;
    4) jig_fail usage "queue move: $anchor is on another level of the queue than $ref" ;;
    5) jig_fail usage "queue $sub: $ref cannot be placed against or depend on itself" ;;
    6) jig_die "queue: $file is in another format than this jig writes ($QUEUE_FORMAT); upgrade jig" ;;
    7) jig_fail usage "queue depend: $on already waits for $ref; the dependency would close a cycle" ;;
    8)
      if [ "$sub" = undepend ]; then
        jig_fail not-found "queue undepend: $ref does not wait for $on"
      fi
      if [ "$sub" = cancel ]; then
        jig_fail not-found "queue cancel: no $kind of $ref is requested"
      fi
      jig_fail not-found "queue $sub: $ref is not in the queue" ;;
    9) jig_fail already-exists "queue request: a $kind of $ref is already requested" ;;
    *) jig_die "queue: cannot read $file" ;;
  esac
  _queue_commit "$expected" "$new" "$file"
  # The status page shows each task's place in the queue (`jig status`), so a
  # landed write redraws it, as a task write does.
  jig_status_page_flush

  if [ -n "$_QUEUE_AS_JSON" ]; then
    if [ -n "$kind" ]; then
      _queue_request_json "$file" "$ref" "$kind"
    else
      _queue_item_json "$file" "$ref"
    fi
    return 0
  fi
  case "$sub" in
    request) printf 'queue: %s of %s requested at %s\n' "$kind" "$ref" "$at" ;;
    cancel) printf 'queue: %s request of %s cancelled\n' "$kind" "$ref" ;;
    remove) printf 'queue: %s removed\n' "$ref" ;;
    undepend) printf 'queue: %s no longer waits for %s\n' "$ref" "$on" ;;
    depend) printf 'queue: %s waits for %s\n' "$ref" "$on" ;;
    *) _queue_item_line "$file" "$ref" ;;
  esac
}

# _queue_item_line <file> <ref> — `queue: <ref> at <position> on <level>, priority <p>`.
_queue_item_line() {
  Q_REF="$2" awk -F '\t' '
    $1 == "item" && $2 == ENVIRON["Q_REF"] {
      printf "queue: %s at %s on %s, priority %s\n", $2, $4, ($3 == "-" ? "the top level" : $3), ($5 == "-" ? "none" : $5)
      found = 1
    }
    END { if (!found) exit 1 }
  ' "$1"
}

# _queue_item_json <file> <ref> — the producer's data after a write:
# {"ref": <ref>, "item": {...} | null} (schemas/json.md, "Queue writes").
_queue_item_json() {
  _queue_item_object "$1" "$2"
  json_quote "$2"
  printf '{"ref":%s,"item":%s}\n' "$_JSON" "$_QITEM"
}

# _queue_item_object <file> <ref> — _QITEM <- the item <ref> as the queue
# <file> holds it, or `null` when it is not queued.
_QITEM=""
_queue_item_object() {
  local kind f2 f3 f4 f5
  _QITEM=null
  while IFS=$'\t' read -r kind f2 f3 f4 f5; do
    case "$kind" in
      item) _queue_item_begin "$f2" "$f3" "$f4" "$f5" ;;
      dep) _queue_item_dep "$f2" "$f3" ;;
    esac
  done <<EOF
$(jig_queue_items "$1" "$2")
EOF
  [ -z "$_QI_REF" ] || _queue_item_end
}

# The item being built: _queue_item_begin starts it, _queue_item_dep adds one
# dependency, _queue_item_end sets _QITEM — the one object a write's answer and
# the listing both print (schemas/json.md).
_QI_REF=""
_QI_HEAD=""
_QI_DEPS=""
_queue_item_begin() {
  local ref="$1" lvl="$2" pos="$3" pri="$4" out
  json_quote "$ref"; out="{\"ref\":$_JSON"
  json_quote "${ref%%:*}"; out="$out,\"kind\":$_JSON"
  json_quote "${ref#*:}"; out="$out,\"id\":$_JSON"
  if [ "$lvl" = "-" ]; then out="$out,\"level\":null"; else json_quote "$lvl"; out="$out,\"level\":$_JSON"; fi
  json_int_or_null "$pos"; out="$out,\"position\":$_JSON"
  json_int_or_null "$pri"; out="$out,\"priority\":$_JSON"
  _QI_REF=$ref
  _QI_HEAD=$out
  _QI_DEPS=""
}

_queue_item_dep() {
  [ -z "$_QI_DEPS" ] || _QI_DEPS="$_QI_DEPS,"
  json_quote "$1"; _QI_DEPS="$_QI_DEPS{\"on\":$_JSON"
  json_quote "$2"; _QI_DEPS="$_QI_DEPS,\"reason\":$_JSON}"
}

_queue_item_end() {
  _QITEM="$_QI_HEAD,\"depends_on\":[$_QI_DEPS]}"
  _QI_REF=""
}

# _queue_request_json <file> <ref> <kind> — the producer's data after a
# request or a cancel: {"ref": <ref>, "request": {"kind", "requested_at",
# "reason"} | null} (schemas/json.md, "Queue writes").
_queue_request_json() {
  local line out at reason
  line=$(Q_REF="$2" Q_KIND="$3" awk -F '\t' '
    $1 == "request" && $2 == ENVIRON["Q_REF"] && $3 == ENVIRON["Q_KIND"] && NF >= 4 { print $4 "\t" $5; exit }
  ' "$1")
  json_quote "$2"
  out="{\"ref\":$_JSON,\"request\":"
  if [ -n "$line" ]; then
    at=${line%%$'\t'*}
    reason=${line#*$'\t'}
    json_quote "$3"; out="$out{\"kind\":$_JSON"
    json_quote "$at"; out="$out,\"requested_at\":$_JSON"
    json_str_or_null "$reason"; out="$out,\"reason\":$_JSON}"
  else
    out="${out}null"
  fi
  printf '%s}\n' "$out"
}

# --- the listing -------------------------------------------------------------------

# _queue_list — the queue for a person: the top level in order, each epic's
# tasks indented under it (an epic not queued itself is listed after the top
# level), every item with its priority and what it waits for.
_queue_list() {
  [ $# -eq 0 ] || jig_fail usage "queue list: unexpected argument: $1"
  jig_require_init
  local file
  file=$(queue_file)
  if [ ! -f "$file" ]; then
    if [ -n "$_QUEUE_AS_JSON" ]; then printf '{"items":[]}\n'; else printf 'queue: empty\n'; fi
    return 0
  fi
  local rc=0 canonical
  # Read in the writer's canonical order, so a listing never depends on how
  # the lines happen to lie in the file.
  canonical=$(Q_OP=read Q_REF="" _queue_apply "$file") || rc=$?
  case "$rc" in
    0) ;;
    6) jig_die "queue: $file is in another format than this jig reads ($QUEUE_FORMAT); upgrade jig" ;;
    *) jig_die "queue: cannot read $file" ;;
  esac
  if [ -n "$_QUEUE_AS_JSON" ]; then
    _queue_list_json "$canonical"
    return 0
  fi
  awk -F '\t' '
    function show(i, indent,   j, p) {
      p = (pri[i] == "-") ? "-" : "P" pri[i]
      printf "%s%s  %s\n", indent, ref[i], p
      for (j = 1; j <= dn; j++) if (dsub[j] == ref[i]) printf "%s    waits for %s: %s\n", indent, don[j], drea[j]
    }
    $1 == "item" { i = ++n; ref[i] = $2; lvl[i] = $3; pri[i] = $5; queued[$2] = 1 }
    $1 == "dep" { j = ++dn; dsub[j] = $2; don[j] = $3; drea[j] = $4 }
    END {
      if (n == 0) { print "queue: empty"; exit }
      for (i = 1; i <= n; i++) {
        if (lvl[i] != "-") continue
        show(i, "")
        for (k = 1; k <= n; k++) if (lvl[k] == ref[i]) show(k, "  ")
      }
      for (i = 1; i <= n; i++) {
        if (lvl[i] == "-" || (lvl[i] in queued) || (lvl[i] in head)) continue
        head[lvl[i]] = 1
        printf "%s  (not queued)\n", lvl[i]
        for (k = 1; k <= n; k++) if (lvl[k] == lvl[i]) show(k, "  ")
      }
    }
  ' <<EOF
$canonical
EOF
}

# _queue_list_json <canonical> — the producer's data for `jig queue list
# --json`: {"items": [...]}, every item in the writer's canonical order (the
# top level by position, then each epic's level), each the object a write
# answers with (schemas/json.md, "jig queue list --json").
_queue_list_json() {
  local kind f2 f3 f4 f5 items=""
  _QI_REF=""
  while IFS=$'\t' read -r kind f2 f3 f4 f5; do
    case "$kind" in
      item)
        if [ -n "$_QI_REF" ]; then
          _queue_item_end
          items="$items${items:+,}$_QITEM"
        fi
        _queue_item_begin "$f2" "$f3" "$f4" "$f5" ;;
      dep) _queue_item_dep "$f2" "$f3" ;;
    esac
  done <<EOF
$(printf '%s\n' "$1" | jig_queue_items -)
EOF
  if [ -n "$_QI_REF" ]; then
    _queue_item_end
    items="$items${items:+,}$_QITEM"
  fi
  printf '{"items":[%s]}\n' "$items"
}

# --- the next task -----------------------------------------------------------------

# _queue_next — `jig queue next [--json]`: which queued task to take next, by
# the rules of the next-task-advice spec. Read-only: the queue file, the
# revision and every task's state stay as they are, and nothing asks the
# network — what the forge said is what the last housekeeping run wrote down.
#
# The facts are gathered here, in the shell, as one table of lines on stdin of
# the one awk that decides (_queue_next_decide): the queue's items and
# dependencies as jig_queue_items prints them, then `tf` (a queued task's state
# facts) and `ds` (the state of every dependency's target) lines.
_queue_next() {
  [ $# -eq 0 ] || jig_fail usage "queue next: unexpected argument: $1"
  jig_require_init
  # shellcheck source=lib/hklog.sh
  . "$JIG_LIB/hklog.sh"
  local file items="" facts="" kind f2 f3 f4 f5 id tasks_dir notq=0 d
  local seen=" " merged open_ids
  file=$(queue_file)
  if [ -f "$file" ]; then
    _jig_queue_readable "$file" \
      || jig_die "queue: $file is in another format than this jig reads ($QUEUE_FORMAT); upgrade jig"
    items=$(jig_queue_items "$file")
  fi
  # What housekeeping saw at its last run; `closed` is a pull request that was
  # not merged, so the work is still open as far as a dependency goes.
  merged=" $(hklog_ids ' remote=merged ' | tr '\n' ' ') "
  open_ids=" $(hklog_ids ' remote=(open|closed) ' | tr '\n' ' ') "
  while IFS=$'\t' read -r kind f2 f3 f4 f5; do
    case "$kind" in
      item)
        case "$f2" in
          task:*) facts="$facts$(_queue_next_task_fact "${f2#task:}")"$'\n' ;;
        esac ;;
      dep)
        case "$seen" in *" $f2 "*) continue ;; esac
        seen="$seen$f2 "
        facts="${facts}ds"$'\t'"$f2"$'\t'"$(_queue_next_dep_state "$f2" "$merged" "$open_ids")"$'\n' ;;
    esac
  done <<EOF
$items
EOF
  # An epic's dependencies are inherited by its tasks, so the epic itself is
  # asked about only through them; a task that is not queued is only counted.
  tasks_dir="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  for d in "$tasks_dir"/*/; do
    [ -f "${d}state" ] || continue
    id=$(basename "$d")
    jig_valid_id "$id" || continue
    case "$(_jig_task_state_value "$id" status)" in active) ;; *) continue ;; esac
    [ "$(_jig_task_state_value "$id" paused)" != true ] || continue
    printf '%s\n' "$items" | awk -F '\t' -v r="task:$id" '$1 == "item" && $2 == r { f = 1 } END { exit !f }' && continue
    notq=$((notq + 1))
  done
  local result
  result=$(printf '%s\n%s\n' "$items" "$facts" | _queue_next_decide)
  if [ -n "$_QUEUE_AS_JSON" ]; then
    _queue_next_json "$result" "$notq"
  else
    _queue_next_text "$result" "$notq"
  fi
}

# _queue_next_task_fact <id> — the `tf` line for a queued task: ref, status
# (`gone` without a state file), paused, started (a branch and a base commit
# both recorded) and whether a pause request waits in the queue.
_queue_next_task_fact() {
  local id="$1" st="gone" paused=false started=0 req=0
  if jig_valid_id "$id" && [ -f "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$id/state" ]; then
    st=$(_jig_task_state_value "$id" status)
    [ -n "$st" ] || st=unknown
    [ "$(_jig_task_state_value "$id" paused)" != true ] || paused=true
    if [ -n "$(_jig_task_state_value "$id" branch)" ] && [ -n "$(_jig_task_state_value "$id" base_commit)" ]; then
      started=1
    fi
    if jig_pause_request "$id"; then req=1; fi
  fi
  printf 'tf\t%s\t%s\t%s\t%s\t%s' "task:$id" "$st" "$paused" "$started" "$req"
}

# _queue_next_dep_state <on-ref> <merged ids> <open ids> — what a dependency's
# target stands at: finished, open, broken or unknown.
#
# A task is finished when it is consolidated or housekeeping saw it merged;
# broken when it was abandoned or its workspace is gone (the dependency can
# never be met — the person drops it); open when housekeeping saw its pull
# request open or closed unmerged; unknown otherwise, which is what a task
# housekeeping never ran for answers. An epic is open or finished by its
# spec's Epic: line; a spec this checkout does not have is read by the branch
# alone — an ancestor of the default base is finished, a branch that is not is
# broken, no branch at all unknown — locally, from refs already fetched.
_queue_next_dep_state() {
  local on="$1" merged="$2" open_ids="$3" id st roadmap line rc=0 branch ref base
  id=${on#*:}
  if ! jig_valid_id "$id"; then printf 'unknown'; return 0; fi
  case "$on" in
    task:*)
      if [ ! -f "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$id/state" ]; then printf 'broken'; return 0; fi
      st=$(_jig_task_state_value "$id" status)
      case "$st" in
        consolidated) printf 'finished'; return 0 ;;
        abandoned) printf 'broken'; return 0 ;;
      esac
      case "$merged" in *" $id "*) printf 'finished'; return 0 ;; esac
      case "$open_ids" in *" $id "*) printf 'open'; return 0 ;; esac
      printf 'unknown' ;;
    epic:*)
      roadmap="$JIG_PROJECT/$JIG_AI_DIR/specs/$id/roadmap.md"
      branch="epic/$id"
      if [ -f "$roadmap" ]; then
        line=$(jig_spec_epic "$roadmap") || rc=$?
        if [ "$rc" -ne 0 ]; then printf 'unknown'; return 0; fi
        if [ -n "$line" ]; then
          printf '%s' "${line##* }"
          return 0
        fi
      fi
      ref=$(jig_base_ref "$branch")
      base=$(jig_base_ref "$(jig_task_base "")")
      if [ -z "$ref" ] || [ -z "$base" ]; then printf 'unknown'; return 0; fi
      if git -C "$JIG_PROJECT" merge-base --is-ancestor "$ref" "$base" 2>/dev/null; then
        printf 'finished'
      else
        printf 'broken'
      fi ;;
    *) printf 'unknown' ;;
  esac
}

# _queue_next_decide — the advice, from the table on stdin. Prints:
#   next <ref> <level> <position> <priority> <started> <rank> <count>   (none when nothing)
#   reason <waiting|paused|empty>                                       (only without next)
#   wait <holder> <on> <state> <reason>                                  (each unfinished dependency holding a candidate)
#
# A candidate is a queued task whose state file says `active`, with no pause
# and no pause request; everything else queued is silently not one. It waits
# while any dependency of its own or of the epic it is built on is not
# finished. Among the rest the lowest priority number goes first (`-` last),
# then a started task before one not started, then the position of the item
# on the top level (a task's epic's, an epic that is not queued after every
# queued one), then its own position, then its ref.
_queue_next_decide() {
  awk -F '\t' '
    function pnum(p) { return (p == "-") ? 6 : p + 0 }
    function topkey(i) {
      if (lvl[i] == "-") return pos[i]
      if (lvl[i] in idx) return pos[idx[lvl[i]]]
      return 1e18
    }
    # better(a, b): item a goes before item b.
    function better(a, b,   x, y) {
      x = pnum(pri[a]); y = pnum(pri[b])
      if (x != y) return x < y
      x = (sd[ref[a]] == 1) ? 0 : 1; y = (sd[ref[b]] == 1) ? 0 : 1
      if (x != y) return x < y
      x = topkey(a); y = topkey(b)
      if (x != y) return x < y
      if (pos[a] != pos[b]) return pos[a] < pos[b]
      return ref[a] < ref[b]
    }
    # note(j): record the unfinished dependencies of item j.
    function note(j,   k, key) {
      for (k = 1; k <= nd[j]; k++) {
        if (dst[don[j, k]] == "finished") continue
        unfinished = 1
        key = ref[j] SUBSEP don[j, k]
        if (key in wseen) continue
        wseen[key] = 1
        wl[++nw] = "wait\t" ref[j] "\t" don[j, k] "\t" dst[don[j, k]] "\t" drea[j, k]
      }
    }
    $1 == "item" { n++; ref[n] = $2; lvl[n] = $3; pos[n] = $4 + 0; pri[n] = $5; idx[$2] = n; nd[n] = 0 }
    $1 == "dep" { k = ++nd[n]; don[n, k] = $2; drea[n, k] = $3 }
    $1 == "tf" { st[$2] = $3; pz[$2] = $4; sd[$2] = $5; rq[$2] = $6 }
    $1 == "ds" { dst[$2] = $3 }
    END {
      for (i = 1; i <= n; i++) {
        r = ref[i]
        if (r !~ /^task:/ || st[r] != "active") continue
        if (pz[r] == "true" || rq[r] == 1) { paused++; continue }
        unfinished = 0
        note(i)
        if (lvl[i] != "-" && (lvl[i] in idx)) note(idx[lvl[i]])
        if (unfinished) { waiting++; continue }
        if (!best || better(i, best)) best = i
      }
      if (best) {
        rank = 0; cnt = 0
        for (i = 1; i <= n; i++) if (lvl[i] == lvl[best]) { cnt++; if (pos[i] < pos[best]) rank++ }
        printf "next\t%s\t%s\t%s\t%s\t%d\t%d\t%d\n", ref[best], lvl[best], pos[best], pri[best], (sd[ref[best]] == 1), rank + 1, cnt
      } else if (waiting) print "reason\twaiting"
      else if (paused) print "reason\tpaused"
      else print "reason\tempty"
      for (i = 1; i <= nw; i++) print wl[i]
    }
  '
}

# _queue_next_json <result> <not queued> — the producer's data for `jig queue
# next --json` (schemas/json.md, "jig queue next --json").
_queue_next_json() {
  local kind f2 f3 f4 f5 f6 f7 f8 next=null reason=null waiting=""
  while IFS=$'\t' read -r kind f2 f3 f4 f5 f6 f7 f8; do
    case "$kind" in
      next)
        json_quote "$f2"; next="{\"ref\":$_JSON"
        next="$next,\"kind\":\"task\""
        json_quote "${f2#task:}"; next="$next,\"id\":$_JSON"
        if [ "$f3" = "-" ]; then next="$next,\"level\":null"; else json_quote "$f3"; next="$next,\"level\":$_JSON"; fi
        json_int_or_null "$f4"; next="$next,\"position\":$_JSON"
        json_int_or_null "$f5"; next="$next,\"priority\":$_JSON"
        if [ "$f6" = 1 ]; then next="$next,\"started\":true}"; else next="$next,\"started\":false}"; fi ;;
      reason) json_quote "$f2"; reason=$_JSON ;;
      wait)
        waiting="$waiting${waiting:+,}"
        json_quote "$f2"; waiting="$waiting{\"ref\":$_JSON"
        json_quote "$f3"; waiting="$waiting,\"on\":$_JSON"
        json_quote "$f4"; waiting="$waiting,\"state\":$_JSON"
        json_quote "$f5"; waiting="$waiting,\"reason\":$_JSON}" ;;
    esac
  done <<EOF
$1
EOF
  printf '{"next":%s,"reason":%s,"waiting":[%s],"not_queued":%s}\n' "$next" "$reason" "$waiting" "$2"
}

# _queue_next_text <result> <not queued> — the advice for a person: the
# verdict line, each unfinished dependency that holds a candidate with what to
# do about it, and how many active tasks the queue does not know. An `open`
# dependency is only the way things are while something is advised, so it is
# printed when nothing is; a `broken` or `unknown` one is a thing to fix.
_queue_next_text() {
  local kind f2 f3 f4 f5 f6 f7 f8 advised=""
  while IFS=$'\t' read -r kind f2 f3 f4 f5 f6 f7 f8; do
    case "$kind" in
      next)
        advised=1
        printf 'next: %s — %s of %s on %s, priority %s, %s\n' "$f2" "$f7" "$f8" \
          "$([ "$f3" = "-" ] && printf 'the top level' || printf '%s' "$f3")" \
          "$([ "$f5" = "-" ] && printf none || printf '%s' "$f5")" \
          "$([ "$f6" = 1 ] && printf started || printf 'not started')" ;;
      reason)
        case "$f2" in
          waiting) printf 'next: none — every queued task waits for a dependency\n' ;;
          paused) printf 'next: none — every queued task is paused\n' ;;
          *) printf 'next: none — the queue holds no task to take\n' ;;
        esac ;;
      wait)
        case "$f4" in
          broken) printf '  %s waits for %s: broken — jig queue undepend %s --on %s\n' "$f2" "$f3" "$f2" "$f3" ;;
          unknown)
            case "$f3" in
              task:*) printf '  %s waits for %s: unknown — jig housekeeping\n' "$f2" "$f3" ;;
              *) printf '  %s waits for %s: unknown\n' "$f2" "$f3" ;;
            esac ;;
          *) [ -n "$advised" ] || printf '  %s waits for %s: %s\n' "$f2" "$f3" "$f4" ;;
        esac ;;
    esac
  done <<EOF
$1
EOF
  if [ "$2" -gt 0 ]; then
    printf 'not queued: %s %s — jig queue set <id> --priority <p>\n' "$2" "$([ "$2" = 1 ] && printf task || printf tasks)"
  fi
}
