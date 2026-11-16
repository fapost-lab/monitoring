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

QUEUE_USAGE="usage: jig queue [list] [--json] | jig queue next [--json] | jig queue set <ref> --priority <0-5|none> | jig queue move <ref> (--before <ref> | --after <ref> | --top | --bottom) | jig queue depend <ref> --on <ref> --reason <text> | jig queue undepend <ref> --on <ref> | jig queue remove <ref> | jig queue request <ref> pause [--reason <text>] | jig queue cancel <ref> pause | jig queue prune [--dry-run]; every write takes [--revision <n>] [--json]; <ref> is task:<id>, epic:<spec-id> or <id>"

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
    prune) _queue_prune ${args[@]+"${args[@]}"} ;;
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
# set|move|depend|undepend|remove|request|cancel|absorb|prune|read, Q_REF,
# Q_LEVEL, Q_PRIO, Q_PLACE top|bottom|before|after, Q_ANCHOR, Q_ON, Q_REASON,
# Q_KIND, Q_AT, and for prune Q_DROP and Q_MET (references, one per line).
# Exit status names a refusal: 3 the anchor is not in the queue, 4 the anchor
# is on another level, 5 a reference to itself, 6 another format version, 7 a
# dependency cycle, 8 the item, dependency or request is not in the queue, 9
# the request is already there.
_queue_apply() {
  local file="$1"
  [ -f "$file" ] || file=/dev/null
  Q_FORMAT="$QUEUE_FORMAT" Q_STEP="$QUEUE_STEP" awk -F '\t' '
    function num(s) { return s + 0 }
    function pnum(p) { return (p == "-") ? 6 : p + 0 }
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
          fresh = 0
          if (lvl[i] != level) { lvl[i] = level; pos[i] = maxpos(level) + step; fresh = (op == "set") }
        } else { i = add(r, level); fresh = 1 }
      }
      if (op == "set") {
        # A new item, one that changed its level, or one whose priority
        # changes is placed on its level by priority: right after the last
        # other item whose number is not above its own (`-` is 6), else at the
        # top. The same priority again leaves the place as it is.
        oldp = pri[i]; pri[i] = ENVIRON["Q_PRIO"]
        if (fresh || oldp != pri[i]) {
          anc = 0
          for (j = 1; j <= n; j++)
            if (alive[j] && j != i && lvl[j] == lvl[i] && pnum(pri[j]) <= pnum(pri[i]) && (!anc || before(anc, j))) anc = j
          if (anc) place(i, "after", ref[anc])
          else place(i, "top")
        }
      }
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
      } else if (op == "absorb") {
        # A task merged into another (`jig task merge`): what waited for the
        # absorbed task now waits for the one that took its work, and what the
        # absorbed task waited for, that one now waits for. A wait between the
        # two disappears; one that would close a cycle refuses the whole write.
        o = ENVIRON["Q_ON"]
        for (j = 1; j <= dn; j++) {
          if (!dalive[j]) continue
          if (don[j] == r) {
            dalive[j] = 0
            if (dsub[j] == o) continue
            k = dsub[j] SUBSEP o
            if (k in didx && dalive[didx[k]]) continue
            if (reaches(o, dsub[j])) exit 7
            jj = ++dn; dsub[jj] = dsub[j]; don[jj] = o; drea[jj] = drea[j]; dalive[jj] = 1; didx[k] = jj
          } else if (dsub[j] == r) {
            dalive[j] = 0
            if (don[j] == o) continue
            k = o SUBSEP don[j]
            if (k in didx && dalive[didx[k]]) continue
            if (reaches(don[j], o)) exit 7
            jj = ++dn; dsub[jj] = o; don[jj] = don[j]; drea[jj] = drea[j]; dalive[jj] = 1; didx[k] = jj
          }
        }
      } else if (op == "prune") {
        # Finished tasks leave the queue (adr-20261107-a-finished-task-leaves-
        # the-queue): each ref of Q_DROP goes with what it waits for and what
        # it asked, and every wait on a ref of Q_MET goes, being met. One
        # write, whatever the count.
        nq = split(ENVIRON["Q_DROP"], qd, "\n")
        for (j = 1; j <= nq; j++) if (qd[j] != "") drop[qd[j]] = 1
        nq = split(ENVIRON["Q_MET"], qd, "\n")
        for (j = 1; j <= nq; j++) if (qd[j] != "") met[qd[j]] = 1
        for (j = 1; j <= n; j++) if (ref[j] in drop) alive[j] = 0
        for (j = 1; j <= dn; j++) if ((dsub[j] in drop) || (don[j] in met)) dalive[j] = 0
        for (j = 1; j <= rn; j++) if (rsub[j] in drop) ralive[j] = 0
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

# queue_absorb <from-id> <into-id> — move the waits of a task that `jig task
# merge` absorbed onto the task that took its work, in one write against the
# revision read here (adr-20261019-the-queue-is-one-file-written-against-a-
# revision). The absorbed task's own item goes when it is archived
# (adr-20261107-a-finished-task-leaves-the-queue).
# Nothing to do, and nothing written, when the clone has no queue yet.
queue_absorb() {
  local from="task:$1" into="task:$2" file new expected rc=0
  file=$(queue_file)
  [ -f "$file" ] || return 0
  expected=$(jig_revision_read)
  new="$file.tmp.$$"
  jig_cleanup_add "$new"
  Q_OP=absorb Q_REF="$from" Q_ON="$into" _queue_apply "$file" > "$new" || rc=$?
  case "$rc" in
    0) ;;
    6) jig_die "queue: $file is in another format than this jig writes ($QUEUE_FORMAT); upgrade jig" ;;
    7) jig_die "task merge: moving the waits of $from onto $into would close a cycle in the queue; drop one with jig queue undepend first" ;;
    *) jig_die "queue: cannot read $file" ;;
  esac
  if cmp -s "$file" "$new"; then
    rm -f "$new"
    return 0
  fi
  _queue_commit "$expected" "$new" "$file"
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

# --- finished tasks ----------------------------------------------------------------

# _queue_prune — `jig queue prune [--dry-run] [--revision <n>] [--json]`: take
# out of the queue every task that is finished, in one write
# (adr-20261107-a-finished-task-leaves-the-queue). A task is finished when its
# status is consolidated, abandoned or archived, or its workspace is gone; its
# item goes with what it waits for and what it asked. A wait on a task the
# advice reads as finished (_queue_next_dep_state: closed, or merged as the
# last housekeeping run saw it) goes too, being met, so it never turns broken
# once the workspace is purged. A wait on an abandoned, archived or vanished
# task stays: it reads broken, and the advice names `jig queue undepend`.
# Epic items are left alone. `jig task` (close, abandon, archive) and `jig
# housekeeping` call it; with nothing to take out it writes nothing, and a
# dry run says what it would take out and writes nothing either.
_queue_prune() {
  local dry=0 rev="" rev_given=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --revision) _queue_need_value "$1" $#; rev=$2; rev_given=1; shift 2 ;;
      *) jig_fail usage "queue prune: unexpected argument: $1" ;;
    esac
  done
  [ -z "$rev_given" ] || [ -n "$rev" ] || jig_fail usage "queue: --revision is empty"
  [ -z "$rev" ] || jig_revision_valid "$rev" || jig_fail usage "queue: --revision is not a revision: $rev"
  jig_require_init
  # shellcheck source=lib/hklog.sh
  . "$JIG_LIB/hklog.sh"
  local file expected items kind f2 f3 f4 f5 id st gone_ok=0 seen=" " merged open_ids
  local drop="" met="" said=""
  if [ -n "$rev" ]; then expected=$rev; else expected=$(jig_revision_read); fi
  file=$(queue_file)
  if [ -f "$file" ]; then
    _jig_queue_readable "$file" \
      || jig_die "queue: $file is in another format than this jig writes ($QUEUE_FORMAT); upgrade jig"
    items=$(jig_queue_items "$file")
  else
    items=""
  fi
  ! _queue_prune_sees_workspace || gone_ok=1
  merged=" $(hklog_ids ' remote=merged ' | tr '\n' ' ') "
  open_ids=" $(hklog_ids ' remote=(open|closed) ' | tr '\n' ' ') "
  while IFS=$'\t' read -r kind f2 f3 f4 f5; do
    case "$kind" in
      item)
        case "$f2" in task:*) ;; *) continue ;; esac
        id=${f2#task:}
        jig_valid_id "$id" || continue
        if [ -f "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$id/state" ]; then
          st=$(_jig_task_state_value "$id" status)
          case "$st" in consolidated | abandoned | archived) ;; *) continue ;; esac
        else
          [ "$gone_ok" = 1 ] || continue
          st=gone
        fi
        drop="$drop$f2"$'\n'
        said="${said}removed"$'\t'"$f2"$'\t'"$st"$'\n' ;;
      dep)
        case "$f2" in task:*) ;; *) continue ;; esac
        case "$seen" in *" $f2 "*) continue ;; esac
        seen="$seen$f2 "
        [ "$(_queue_next_dep_state "$f2" "$merged" "$open_ids")" = finished ] || continue
        met="$met$f2"$'\n' ;;
    esac
  done <<EOF
$items
EOF
  # Which waits the met ones are, as the answer names them: every dependency
  # line whose target is met, held by an item that does not leave anyway.
  if [ -n "$met" ]; then
    said="$said$(printf '%s\n' "$items" | Q_MET="$met" Q_DROP="$drop" awk -F '\t' '
      BEGIN {
        n = split(ENVIRON["Q_MET"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") met[a[i]] = 1
        n = split(ENVIRON["Q_DROP"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") drop[a[i]] = 1
      }
      $1 == "item" { cur = $2 }
      $1 == "dep" && ($2 in met) && !(cur in drop) { print "met\t" cur "\t" $2 }
    ')"
  fi
  if [ "$dry" = 0 ] && [ -n "$drop$met" ]; then
    local new rc=0
    new="$file.tmp.$$"
    jig_cleanup_add "$new"
    Q_OP=prune Q_REF="" Q_DROP="$drop" Q_MET="$met" _queue_apply "$file" > "$new" || rc=$?
    case "$rc" in
      0) ;;
      6) jig_die "queue: $file is in another format than this jig writes ($QUEUE_FORMAT); upgrade jig" ;;
      *) jig_die "queue: cannot read $file" ;;
    esac
    if cmp -s "$file" "$new"; then
      rm -f "$new"
    else
      _queue_commit "$expected" "$new" "$file"
      jig_status_page_flush
    fi
  fi
  if [ -n "$_QUEUE_AS_JSON" ]; then
    _queue_prune_json "$said" "$dry"
  else
    _queue_prune_text "$said" "$dry"
  fi
}

# _queue_prune_sees_workspace — exit 0 when this checkout's task workspace is
# the one the queue's own checkout holds (the clone's main checkout, where a
# worktree's link leads). Only then is a task with no state file gone: a
# checkout that cannot see the workspace must not empty the queue.
_queue_prune_sees_workspace() {
  local here there root
  root=$(jig_config_clone_root)
  [ -d "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks" ] && [ -d "$root/$JIG_AI_DIR/workspace/tasks" ] || return 1
  here=$(cd "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks" && pwd -P) || return 1
  there=$(cd "$root/$JIG_AI_DIR/workspace/tasks" && pwd -P) || return 1
  [ "$here" = "$there" ]
}

# _queue_prune_text <said> <dry> — the answer for a person, one line per item
# taken out and per wait met.
_queue_prune_text() {
  local kind f2 f3 any=""
  while IFS=$'\t' read -r kind f2 f3; do
    case "$kind" in
      removed)
        any=1
        if [ "$2" = 1 ]; then printf 'queue: would remove %s (%s)\n' "$f2" "$f3"
        else printf 'queue: %s removed (%s)\n' "$f2" "$f3"; fi ;;
      met)
        any=1
        if [ "$2" = 1 ]; then printf 'queue: %s would no longer wait for %s (finished)\n' "$f2" "$f3"
        else printf 'queue: %s no longer waits for %s (finished)\n' "$f2" "$f3"; fi ;;
    esac
  done <<EOF
$1
EOF
  [ -n "$any" ] || printf 'queue: no finished task to take out\n'
}

# _queue_prune_json <said> <dry> — the producer's data for `jig queue prune
# --json` (schemas/json.md, "jig queue prune --json").
_queue_prune_json() {
  local kind f2 f3 removed="" met="" dry=false
  [ "$2" = 0 ] || dry=true
  while IFS=$'\t' read -r kind f2 f3; do
    case "$kind" in
      removed)
        removed="$removed${removed:+,}"
        json_quote "$f2"; removed="$removed{\"ref\":$_JSON"
        json_quote "$f3"; removed="$removed,\"status\":$_JSON}" ;;
      met)
        met="$met${met:+,}"
        json_quote "$f2"; met="$met{\"ref\":$_JSON"
        json_quote "$f3"; met="$met,\"on\":$_JSON}" ;;
    esac
  done <<EOF
$1
EOF
  printf '{"dry_run":%s,"removed":[%s],"met":[%s]}\n' "$dry" "$removed" "$met"
}

# --- the listing -------------------------------------------------------------------

# _queue_list — the queue for a person: the top level in order, each epic's
# tasks indented under it (an epic not queued itself is listed after the top
# level), every item with its priority, what it waits for and, for a task
# another session holds, who and since when (jig_checkout_taken).
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
  # Who holds each active task, as `tk <ref> <words>` lines after the queue's
  # own: the same answer `jig queue next` skips a task by.
  local kind f2 f3 f4 f5 tk taken="" c s a
  jig_checkout_taken_begin
  while IFS=$'\t' read -r kind f2 f3 f4 f5; do
    [ "$kind" = item ] || continue
    case "$f2" in task:*) ;; *) continue ;; esac
    jig_valid_id "${f2#task:}" || continue
    [ -f "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/${f2#task:}/state" ] || continue
    [ "$(_jig_task_state_value "${f2#task:}" status)" = active ] || continue
    tk=$(jig_checkout_taken "${f2#task:}")
    [ -n "$tk" ] || continue
    IFS=$'\t' read -r c s a _ <<EOF
$tk
EOF
    taken="${taken}tk"$'\t'"$f2"$'\t'"$(_queue_taken_words "$c" "$s" "$a")"$'\n'
  done <<EOF
$canonical
EOF
  awk -F '\t' '
    function show(i, indent,   j, p) {
      p = (pri[i] == "-") ? "-" : "P" pri[i]
      printf "%s%s  %s\n", indent, ref[i], p
      if (ref[i] in tk) printf "%s    %s\n", indent, tk[ref[i]]
      for (j = 1; j <= dn; j++) if (dsub[j] == ref[i]) printf "%s    waits for %s: %s\n", indent, don[j], drea[j]
    }
    $1 == "item" { i = ++n; ref[i] = $2; lvl[i] = $3; pri[i] = $5; queued[$2] = 1 }
    $1 == "dep" { j = ++dn; dsub[j] = $2; don[j] = $3; drea[j] = $4 }
    $1 == "tk" { tk[$2] = $3 }
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
$taken
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
# facts), `tk` (a queued task another session holds: jig_checkout_taken,
# adr-20261030-a-task-another-session-works-on-is-not-advised), `ds` (the
# state of every dependency's target), `rs` (a stopped run a person already
# answered, which waits for a free slot) and `sl` (the slot limit and how many
# runs are building) lines (adr-20261114-a-waiting-run-holds-no-slot).
_queue_next() {
  [ $# -eq 0 ] || jig_fail usage "queue next: unexpected argument: $1"
  jig_require_init
  _queue_next_gather 1
  local result
  result=$(printf '%s\n' "$_QN_TABLE" | _queue_next_decide)
  if [ -n "$_QUEUE_AS_JSON" ]; then
    _queue_next_json "$result" "$_QN_NOTQ"
  else
    _queue_next_text "$result" "$_QN_NOTQ"
  fi
}

# _queue_next_gather <count not queued: 1|0> — gather the table _queue_next_decide
# reads into _QN_TABLE (items and dependencies, then the `tf`/`tk`/`ds` lines)
# and, when asked, the number of active tasks the queue does not know into
# _QN_NOTQ. A queue in another format dies here, as `queue next` always did.
_queue_next_gather() {
  # shellcheck source=lib/hklog.sh
  . "$JIG_LIB/hklog.sh"
  local file items="" facts="" kind f2 f3 f4 f5 id tasks_dir notq=0 d st
  local seen=" " merged open_ids nl=$'\n' queued=$'\n' building=0 limit ans stopped ev at
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
  local tk
  jig_checkout_taken_begin
  while IFS=$'\t' read -r kind f2 f3 f4 f5; do
    case "$kind" in
      item)
        queued="$queued$f2$nl"
        case "$f2" in
          task:*)
            facts="$facts$(_queue_next_task_fact "${f2#task:}" "$merged")"$'\n'
            tk=$(jig_checkout_taken "${f2#task:}")
            [ -z "$tk" ] || facts="${facts}tk"$'\t'"$f2"$'\t'"$tk"$'\n'
            ;;
        esac ;;
      dep)
        case "$seen" in *" $f2 "*) continue ;; esac
        seen="$seen$f2 "
        facts="${facts}ds"$'\t'"$f2"$'\t'"$(_queue_next_dep_state "$f2" "$merged" "$open_ids")"$'\n' ;;
    esac
  done <<EOF
$items
EOF
  _QN_TABLE=$(printf '%s\n%s' "$items" "$facts")
  _QN_NOTQ=0
  [ "$1" = 1 ] || return 0
  limit=$(jig_autopilot_parallel) || limit=1
  # An epic's dependencies are inherited by its tasks, so the epic itself is
  # asked about only through them; a task that is not queued is only counted.
  # Every workspace is asked, so none of them costs a process: the id comes off
  # the path, the state into a variable, and "is it queued" is answered by the
  # item refs the loop above collected (convention-shell, `<name>_v`).
  tasks_dir="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks"
  for d in "$tasks_dir"/*/; do
    [ -f "${d}state" ] || continue
    id=${d%/}
    id=${id##*/}
    jig_valid_id "$id" || continue
    # Every workspace: a run an agent is building holds a slot, and a stopped
    # run a person answered waits for one (queued or not).
    if jig_autopilot_building "$id"; then building=$((building + 1)); fi
    jig_task_state_var st "$id" status
    # A stopped run a person answered is no stop a dependent waits on for ever,
    # whatever its status or whoever holds it (`an`).
    jig_task_state_var ans "$id" autopilot_answered
    if [ -n "$ans" ] && { [ "$st" = ready ] || [ "$st" = active ]; }; then
      jig_task_state_var stopped "$id" autopilot
      [ "$stopped" != stopped ] || _QN_TABLE="$_QN_TABLE${nl}an"$'\t'"task:$id"
    fi
    [ "$st" = active ] || continue
    if [ -n "$ans" ]; then
      jig_task_state_var stopped "$id" autopilot
      if [ "$stopped" = stopped ] && [ -z "$(jig_checkout_taken "$id")" ]; then
        stopped="-"
        if [ -f "${d}autopilot" ]; then
          while IFS=$'\t' read -r at ev _; do
            [ "$ev" != stop ] || stopped=$at
          done < "${d}autopilot"
        fi
        _QN_TABLE="$_QN_TABLE${nl}rs"$'\t'"task:$id"$'\t'"$stopped"$'\t'"$ans"
      fi
    fi
    jig_task_state_var st "$id" paused
    [ "$st" != true ] || continue
    case "$queued" in *"${nl}task:$id$nl"*) continue ;; esac
    notq=$((notq + 1))
  done
  _QN_NOTQ=$notq
  _QN_TABLE="$_QN_TABLE${nl}sl"$'\t'"$limit"$'\t'"$building"
}

# jig_queue_ahead_v <var> <id> — set <var> to `task:Y<TAB><priority or ->` of the
# task that should be started before task <id>, or to nothing. It is named when
# task:<id> is queued, `jig queue next` has an answer Y other than it, and Y goes
# before it by the order next uses (priority, the top-level position, its own
# position, the ref). <id> need not be a candidate itself: it may wait, be paused
# or held — the order is still the queue's. A task that is not queued, no queue
# file, or a queue this jig cannot read answer nothing; this is never an error.
# The table is worked out once per process (_QUEUE_AHEAD_SET), so asking about
# every task costs no process of its own.
_QUEUE_AHEAD_SET=""
_QUEUE_AHEAD_LINES=""
jig_queue_ahead_v() {
  local __qa_nl=$'\n' __qa_tab=$'\t' __qa_rest=""
  if [ -z "$_QUEUE_AHEAD_SET" ]; then
    _QUEUE_AHEAD_SET=1
    _QUEUE_AHEAD_LINES=""
    if [ -f "$(queue_file)" ] && _jig_queue_readable "$(queue_file)"; then
      _queue_next_gather 0
      _QUEUE_AHEAD_LINES=$(printf '%s\n' "$_QN_TABLE" | Q_AHEAD=1 _queue_next_decide)
    fi
  fi
  case "$__qa_nl$_QUEUE_AHEAD_LINES" in
    *"${__qa_nl}ahead${__qa_tab}task:$2${__qa_tab}"*)
      __qa_rest=${_QUEUE_AHEAD_LINES#*"ahead${__qa_tab}task:$2${__qa_tab}"}
      __qa_rest=${__qa_rest%%"$__qa_nl"*} ;;
  esac
  printf -v "$1" '%s' "$__qa_rest"
}

# _queue_next_task_fact <id> [<merged ids>] — the `tf` line for a queued task: ref, status
# (`gone` without a state file), paused, started (a branch and a base commit
# both recorded), whether a pause request waits in the queue, and the hold
# (_queue_next_hold).
_queue_next_task_fact() {
  local id="$1" merged="${2-}" st="gone" paused=false started=0 req=0 v hold="-"
  if jig_valid_id "$id" && [ -f "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$id/state" ]; then
    jig_task_state_var st "$id" status
    [ -n "$st" ] || st=unknown
    jig_task_state_var v "$id" paused
    [ "$v" != true ] || paused=true
    jig_task_state_var v "$id" branch
    if [ -n "$v" ]; then
      jig_task_state_var v "$id" base_commit
      [ -z "$v" ] || started=1
    fi
    if jig_pause_request "$id"; then req=1; fi
    _queue_next_hold_v hold "$id" "$st" "$started" "$merged"
  fi
  printf 'tf\t%s\t%s\t%s\t%s\t%s\t%s' "task:$id" "$st" "$paused" "$started" "$req" "$hold"
}

# _queue_next_hold_v <var> <id> <status> <started> [<merged ids>] — why a watcher could not
# start or go on with task <id> now, into <var>, or `-` for nothing
# (adr-20261022-the-next-task-is-advised-from-the-queue, amendment of 2026-11-16):
#   stopped  its autopilot run is stopped for a person who has not answered (an
#            answered run is in `resume`); a draft of the repair limit is one;
#   stub     not started, and task.md holds the template's `## Goal` heading with
#            no goal under it (jig_task_has_goal): filed, not yet briefed;
#   version  not started, and it is a release's notes task, which raises the
#            version and stays a person's: the id `release-notes-*` that
#            jig-release files, or a recorded `notes_through`.
#   not_merged  its run ended (`autopilot: done`) with an `end` line that starts
#            `not merged` and housekeeping has not seen the change merged since.
# A brief with no `## Goal` heading at all is not a stub: it
# is one written without the template, and `task start` only warns of it.
_queue_next_hold_v() {
  local __nh_var="$1" __nh_id="$2" __nh_st="$3" __nh_started="$4" __nh_merged="${5-}" __nh_v __nh_at __nh_ev __nh_tx __nh_ended __nh_hold="-" __nh_md __nh_line __nh_has=0
  local __nh_head='^##[[:space:]]+Goal[[:space:]]*$'
  case "$__nh_st" in
    active | ready)
      jig_task_state_var __nh_v "$__nh_id" autopilot
      if [ "$__nh_v" = stopped ]; then
        jig_task_state_var __nh_v "$__nh_id" autopilot_answered
        [ -n "$__nh_v" ] || __nh_hold=stopped
      fi ;;
  esac
  # A run that ended with its change not merged: the text `jig-autopilot` §4
  # has `end --reason` start with. A later `start` or `resume` is a new run.
  if [ "$__nh_hold" = "-" ]; then
    case "$__nh_st" in
      active | ready)
        jig_task_state_var __nh_v "$__nh_id" autopilot
        if [ "$__nh_v" = "done" ] && [ -f "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$__nh_id/autopilot" ]; then
          case "$__nh_merged" in *" $__nh_id "*) ;; *)
            __nh_ended=""
            while IFS=$'\t' read -r __nh_at __nh_ev __nh_tx || [ -n "$__nh_ev" ]; do
              case "$__nh_ev" in
                start | resume) __nh_ended="" ;;
                end) __nh_ended=$__nh_tx ;;
              esac
            done < "$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$__nh_id/autopilot"
            case "$__nh_ended" in "not merged"*) __nh_hold=not_merged ;; esac ;;
          esac
        fi ;;
    esac
  fi
  if [ "$__nh_hold" = "-" ] && [ "$__nh_st" = active ] && [ "$__nh_started" = 0 ]; then
    case "$__nh_id" in
      release-notes-*) __nh_hold=version ;;
      *)
        jig_task_state_var __nh_v "$__nh_id" notes_through
        if [ -n "$__nh_v" ]; then
          __nh_hold=version
        else
          __nh_md="$JIG_PROJECT/$JIG_AI_DIR/workspace/tasks/$__nh_id/task.md"
          if [ -f "$__nh_md" ]; then
            while IFS= read -r __nh_line || [ -n "$__nh_line" ]; do
              if [[ $__nh_line =~ $__nh_head ]]; then __nh_has=1; break; fi
            done < "$__nh_md"
            if [ "$__nh_has" = 1 ] && ! jig_task_has_goal "$__nh_md"; then __nh_hold=stub; fi
          fi
        fi ;;
    esac
  fi
  printf -v "$__nh_var" '%s' "$__nh_hold"
}

# _queue_next_dep_state <on-ref> <merged ids> <open ids> — what a dependency's
# target stands at: finished, waiting, open, not_started, broken or unknown.
#
# A task is finished when it is consolidated or housekeeping saw it merged;
# broken when it was abandoned or archived or its workspace is gone (the dependency can
# never be met — the person drops it); waiting when its autopilot run is
# stopped, answered or not (a person holds it up: `jig status`); open when housekeeping saw its pull
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
        # An archived task is out of the work (adr-20261027-a-task-nobody-finished-is-archived-not-purged).
        abandoned | archived) printf 'broken'; return 0 ;;
      esac
      case "$merged" in *" $id "*) printf 'finished'; return 0 ;; esac
      # A run stopped for a person is not moving; what is waited for is the
      # person, not the pull request (adr-20261114-a-waiting-run-holds-no-slot).
      [ "$(_jig_task_state_value "$id" autopilot)" != stopped ] || { printf 'waiting'; return 0; }
      case "$open_ids" in *" $id "*) printf 'open'; return 0 ;; esac
      # Never started (neither branch nor base commit recorded, as `task new` leaves it): there is no work
      # for housekeeping to judge, so it is not "unknown"; it is waiting to be
      # taken up.
      if [ -z "$(_jig_task_state_value "$id" branch)" ] && [ -z "$(_jig_task_state_value "$id" base_commit)" ]; then
        printf 'not_started'; return 0
      fi
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
#   next <ref> <level> <position> <priority> <started> <rank> <count>   (none when nothing; started is always 0)
#   reason <waiting|taken|in_progress|blocked|paused|empty>             (only without next)
#   wait <holder> <on> <state> <reason>                                  (each unfinished dependency holding a candidate)
#   blocked <ref> <stopped|not_merged|stub|version>                                 (each task a watcher could not take, once)
#   taken <ref> <checkout> <since> <idle seconds> <command>              (each candidate another session holds)
#   progress <ref> <priority>                                            (each started task, in queue order)
#   resume <ref> <priority> <stopped at> <answered at>                   (each answered stopped run: priority, earlier stop, ref)
#   slots <limit> <building> <free>
# With Q_AHEAD set it prints instead one line per queued task that the advice
# outranks: `ahead <ref> <advised ref> <advised priority>` (jig_queue_ahead_v).
#
# A candidate is a queued task whose state file says `active`, with no pause
# and no pause request; everything else queued is silently not one. One that
# another session holds (a `tk` line) is named instead of advised, and a task
# already started is named as in progress and never advised: the advice is
# what to start, and a started task is one the person or an agent already has.
# One a watcher could not start or go on with now is named as blocked, never
# advised and never in progress: its run is stopped for a person or ended not
# merged, its task.md holds only the template's stub, or it is a release's notes task
# (_queue_next_hold_v). So is the stopped run a candidate waits for, when that is
# all it waits for. It waits while any dependency of its own or of the epic it is
# built on is not finished. Among the rest the lowest priority number goes first (`-` last),
# then the position of the item on the top level (a task's epic's, an epic that
# is not queued after every queued one), then its own position, then its ref.
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
      x = topkey(a); y = topkey(b)
      if (x != y) return x < y
      if (pos[a] != pos[b]) return pos[a] < pos[b]
      return ref[a] < ref[b]
    }
    # addblock(r, kind): a task a watcher could not take now, once.
    function addblock(r, kind) {
      if (r in bseen) return
      bseen[r] = 1
      bl[++nb] = "blocked\t" r "\t" kind
    }
    # note(j): record the unfinished dependencies of item j; one in a stopped
    # run nobody answered, or a stub or a release that never starts by itself, is a stop; any other is something that will
    # resolve itself (an answered run resumes on a free slot).
    function note(j,   k, key) {
      for (k = 1; k <= nd[j]; k++) {
        if (dst[don[j, k]] == "finished") continue
        unfinished = 1
        if ((dst[don[j, k]] == "waiting" && !(don[j, k] in ansd)) || hd[don[j, k]] == "stub" || hd[don[j, k]] == "version") stopdep[++nsd] = don[j, k]
        else other = 1
        key = ref[j] SUBSEP don[j, k]
        if (key in wseen) continue
        wseen[key] = 1
        wl[++nw] = "wait\t" ref[j] "\t" don[j, k] "\t" dst[don[j, k]] "\t" drea[j, k]
      }
    }
    $1 == "item" { n++; ref[n] = $2; lvl[n] = $3; pos[n] = $4 + 0; pri[n] = $5; idx[$2] = n; nd[n] = 0 }
    $1 == "dep" { k = ++nd[n]; don[n, k] = $2; drea[n, k] = $3 }
    $1 == "tf" { st[$2] = $3; pz[$2] = $4; sd[$2] = $5; rq[$2] = $6; hd[$2] = $7 }
    $1 == "ds" { dst[$2] = $3 }
    $1 == "tk" { tk[$2] = substr($0, length($1) + length($2) + 3) }
    $1 == "an" { ansd[$2] = 1 }
    $1 == "rs" { ansd[$2] = 1; nr++; rr[nr] = $2; rst[nr] = $3; ran[nr] = $4 }
    $1 == "sl" { limit = $2 + 0; building = $3 + 0 }
    # rbetter(a, b): answered run a resumes before b — priority (`-` and an
    # unqueued run last), then the earlier stop (none last), then the ref.
    function rpri(a) { return (rr[a] in idx) ? pnum(pri[idx[rr[a]]]) : 6 }
    function rbetter(a, b,   x, y) {
      x = rpri(a); y = rpri(b)
      if (x != y) return x < y
      # A run with no stop goes last by an explicit test, never by a sentinel
      # string: awk compares strings by the collation of the locale, and "~" sorts
      # before the digits under some (macOS in a UTF-8 locale did).
      x = rst[a]; y = rst[b]
      if (x != y) {
        if (x == "-") return 0
        if (y == "-") return 1
        return x < y
      }
      return rr[a] < rr[b]
    }
    END {
      ahead = ENVIRON["Q_AHEAD"] != ""
      for (i = 1; i <= n; i++) {
        r = ref[i]
        if (r !~ /^task:/) continue
        # A run stopped for a person is a stop in whatever status it stopped.
        if (st[r] == "ready" && (hd[r] == "stopped" || hd[r] == "not_merged")) { addblock(r, hd[r]); continue }
        if (st[r] != "active") continue
        if (pz[r] == "true" || rq[r] == 1) { paused++; continue }
        if (r in tk) { taken++; tl[++nt] = "taken\t" r "\t" tk[r]; continue }
        # An answered stopped run waits for a free slot: it is in `resume`, not in progress.
        if (sd[r] == 1 && (r in ansd)) continue
        # What a watcher could not start or go on with: stopped, a stub, a release.
        if (hd[r] != "" && hd[r] != "-") { addblock(r, hd[r]); continue }
        if (sd[r] == 1) { inprog++; pl[++np] = "progress\t" r "\t" pri[i]; continue }
        unfinished = 0; other = 0; nsd = 0
        note(i)
        if (lvl[i] != "-" && (lvl[i] in idx)) note(idx[lvl[i]])
        if (unfinished && other) { waiting++; continue }
        # Everything it waits for is a stopped run: held by a stop, which is
        # not a wait that resolves itself.
        if (unfinished) { for (k = 1; k <= nsd; k++) addblock(stopdep[k], (hd[stopdep[k]] == "stub" || hd[stopdep[k]] == "version") ? hd[stopdep[k]] : "stopped"); continue }
        if (!best || better(i, best)) best = i
      }
      if (ahead) {
        if (best) for (i = 1; i <= n; i++)
          if (ref[i] ~ /^task:/ && i != best && better(best, i)) printf "ahead\t%s\t%s\t%s\n", ref[i], ref[best], pri[best]
        exit
      }
      if (best) {
        rank = 0; cnt = 0
        for (i = 1; i <= n; i++) if (lvl[i] == lvl[best]) { cnt++; if (pos[i] < pos[best]) rank++ }
        printf "next\t%s\t%s\t%s\t%s\t%d\t%d\t%d\n", ref[best], lvl[best], pos[best], pri[best], 0, rank + 1, cnt
      } else if (waiting) print "reason\twaiting"
      else if (taken) print "reason\ttaken"
      else if (inprog) print "reason\tin_progress"
      else if (nb) print "reason\tblocked"
      else if (paused) print "reason\tpaused"
      else print "reason\tempty"
      for (i = 1; i <= nw; i++) print wl[i]
      for (i = 1; i <= nb; i++) print bl[i]
      for (i = 1; i <= nt; i++) print tl[i]
      for (i = 1; i <= np; i++) print pl[i]
      # Answered runs, best first: a selection pass over a handful of rows.
      for (k = 1; k <= nr; k++) {
        b = 0
        for (i = 1; i <= nr; i++) if (!used[i] && (!b || rbetter(i, b))) b = i
        used[b] = 1
        p = (rr[b] in idx) ? pri[idx[rr[b]]] : "-"
        printf "resume\t%s\t%s\t%s\t%s\n", rr[b], p, rst[b], ran[b]
      }
      free = limit - building
      if (free < 0) free = 0
      printf "slots\t%d\t%d\t%d\n", limit, building, free
    }
  '
}

# _queue_next_json <result> <not queued> — the producer's data for `jig queue
# next --json` (schemas/json.md, "jig queue next --json").
_queue_next_json() {
  local kind f2 f3 f4 f5 f6 f7 f8 next=null reason=null waiting="" taken="" progress="" blocked="" resume="" slots='{"limit":1,"building":0,"free":1}'
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
        # `not_started` is the text's finer word for `unknown`; the pinned
        # JSON contract keeps the one value (jig-ui reads it).
        if [ "$f4" = not_started ]; then json_quote unknown; else json_quote "$f4"; fi
        waiting="$waiting,\"state\":$_JSON"
        json_quote "$f5"; waiting="$waiting,\"reason\":$_JSON}" ;;
      blocked)
        blocked="$blocked${blocked:+,}"
        json_quote "$f2"; blocked="$blocked{\"ref\":$_JSON"
        json_quote "${f2#task:}"; blocked="$blocked,\"id\":$_JSON"
        json_quote "$f3"; blocked="$blocked,\"kind\":$_JSON}" ;;
      taken)
        # `-` stands for a key the record does not hold (jig_checkout_taken).
        taken="$taken${taken:+,}"
        json_quote "$f2"; taken="$taken{\"ref\":$_JSON"
        if [ "$f3" = "-" ]; then taken="$taken,\"checkout\":null"; else json_quote "$f3"; taken="$taken,\"checkout\":$_JSON"; fi
        if [ "$f4" = "-" ]; then taken="$taken,\"since\":null"; else json_quote "$f4"; taken="$taken,\"since\":$_JSON"; fi
        json_int_or_null "$f5"; taken="$taken,\"idle_seconds\":$_JSON"
        if [ "$f6" = "-" ]; then taken="$taken,\"command\":null}"; else json_quote "$f6"; taken="$taken,\"command\":$_JSON}"; fi ;;
      progress)
        progress="$progress${progress:+,}"
        json_quote "$f2"; progress="$progress{\"ref\":$_JSON"
        json_quote "${f2#task:}"; progress="$progress,\"id\":$_JSON"
        json_int_or_null "$f3"; progress="$progress,\"priority\":$_JSON}" ;;
      resume)
        resume="$resume${resume:+,}"
        json_quote "$f2"; resume="$resume{\"ref\":$_JSON"
        json_quote "${f2#task:}"; resume="$resume,\"id\":$_JSON"
        json_int_or_null "$f3"; resume="$resume,\"priority\":$_JSON"
        if [ "$f4" = "-" ]; then resume="$resume,\"stopped_at\":null"; else json_quote "$f4"; resume="$resume,\"stopped_at\":$_JSON"; fi
        if [ "$f5" = "-" ]; then resume="$resume,\"answered_at\":null}"; else json_quote "$f5"; resume="$resume,\"answered_at\":$_JSON}"; fi ;;
      slots) slots="{\"limit\":$f2,\"building\":$f3,\"free\":$f4}" ;;
    esac
  done <<EOF
$1
EOF
  printf '{"next":%s,"reason":%s,"waiting":[%s],"taken":[%s],"in_progress":[%s],"blocked":[%s],"not_queued":%s,"resume":[%s],"slots":%s}\n' "$next" "$reason" "$waiting" "$taken" "$progress" "$blocked" "$2" "$resume" "$slots"
}

# _queue_taken_words <checkout> <since> <idle seconds> — who holds a task and
# since when, for a person: `taken by another session in <checkout>, since
# <since>, last active <n>m ago`. `-` is a key the record does not hold
# (jig_checkout_taken), and its words are left out.
_queue_taken_words() {
  local words="taken by another session"
  [ "$1" = "-" ] || words="$words in $1"
  [ "$2" = "-" ] || words="$words, since $2"
  case "$3" in
    '' | *[!0-9]*) ;;
    *) words="$words, last active $(jig_checkout_ago "$3") ago" ;;
  esac
  printf '%s\n' "$words"
}

# _queue_next_text <result> <not queued> — the advice for a person: the
# verdict line, each unfinished dependency that holds a candidate with what to
# do about it, and how many active tasks the queue does not know. An `open`
# dependency is only the way things are while something is advised, so it is
# printed when nothing is; a `broken` or `unknown` one is a thing to fix.
_queue_next_text() {
  local kind f2 f3 f4 f5 f6 f7 f8 advised="" progress="" pword resume="" ago slots="" blocked_why="" stop_of="" other_of=""
  # The verdict names the first stop; a queue held by a stub or a release only
  # names that one instead (the blocked lines say why, one each).
  while IFS=$'\t' read -r kind f2 f3; do
    [ "$kind" = blocked ] || continue
    if [ "$f3" = stopped ] || [ "$f3" = not_merged ]; then
      [ -n "$stop_of" ] || stop_of=${f2#task:}
    else
      [ -n "$other_of" ] || other_of="${f2#task:}:$f3"
    fi
  done <<EOF
$1
EOF
  if [ -n "$stop_of" ]; then
    blocked_why="blocked by a stop of $stop_of"
  elif [ -n "$other_of" ]; then
    case "${other_of#*:}" in
      stub) blocked_why="blocked: ${other_of%%:*} has no goal in its task.md yet" ;;
      *) blocked_why="blocked: ${other_of%%:*} raises the version, which stays a person's" ;;
    esac
  fi
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
          taken) printf 'next: none — every queued task left is taken by another session\n' ;;
          blocked) printf 'next: none — %s\n' "$blocked_why" ;;
          in_progress) printf 'next: none — every queued task left is in progress\n' ;;
          paused) printf 'next: none — every queued task is paused\n' ;;
          *) printf 'next: none — the queue holds no task to take\n' ;;
        esac ;;
      wait)
        case "$f4" in
          broken) printf '  %s waits for %s: broken — jig queue undepend %s --on %s\n' "$f2" "$f3" "$f2" "$f3" ;;
          waiting) printf '  %s waits for %s: its autopilot run is stopped, waiting for an answer or a free slot — jig status\n' "$f2" "$f3" ;;
          not_started) printf '  %s waits for %s: not started — jig task start %s\n' "$f2" "$f3" "${f3#task:}" ;;
          unknown)
            case "$f3" in
              task:*) printf '  %s waits for %s: unknown — jig housekeeping\n' "$f2" "$f3" ;;
              *) printf '  %s waits for %s: unknown\n' "$f2" "$f3" ;;
            esac ;;
          *) [ -n "$advised" ] || printf '  %s waits for %s: %s\n' "$f2" "$f3" "$f4" ;;
        esac ;;
      blocked)
        case "$f3" in
          stopped) printf '  %s is stopped: its autopilot run waits for a person — jig status\n' "$f2" ;;
          not_merged) printf '  %s ended not merged: its change waits for a person — jig status\n' "$f2" ;;
          stub) printf '  %s has no goal yet: task.md holds only the stub — jig task artifact write %s task --from <file>\n' "$f2" "${f2#task:}" ;;
          *) printf '  %s raises the version: a release stays a person'"'"'s — start it by hand\n' "$f2" ;;
        esac ;;
      taken) printf '  %s is %s\n' "$f2" "$(_queue_taken_words "$f3" "$f4" "$f5")" ;;
      progress)
        if [ "$f3" = "-" ]; then pword="no priority"; else pword="P$f3"; fi
        progress="$progress${progress:+, }$f2 ($pword)" ;;
      resume)
        if [ "$f3" = "-" ]; then pword="no priority"; else pword="P$f3"; fi
        ago=$(jig_utc_ago "$f5")
        case "$ago" in
          '') ago="answered" ;;
          "just now") ago="answered just now" ;;
          *) ago="answered $ago ago" ;;
        esac
        resume="$resume${resume:+, }$f2 ($pword, $ago)" ;;
      slots) slots="$f4 of $f2 free ($f3 building)" ;;
    esac
  done <<EOF
$1
EOF
  [ -z "$progress" ] || printf 'in progress: %s\n' "$progress"
  [ -z "$resume" ] || printf 'resume first: %s\n' "$resume"
  if [ "$2" -gt 0 ]; then
    printf 'not queued: %s %s — jig queue set <id> --priority <p>\n' "$2" "$([ "$2" = 1 ] && printf task || printf tasks)"
  fi
  [ -z "$slots" ] || printf 'slots: %s\n' "$slots"
}
