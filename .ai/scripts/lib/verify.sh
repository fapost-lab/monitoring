# cmd_verify — run active profiles' checks (ARCHITECTURE.md, Scripts layout;
# domains/verify). Sourced by
# scripts/jig; defines cmd_verify.
#
# Scope protocol (ADR-0013): with --changed, the changed-file list is computed
# once here and handed to each profile that declares `scope: [changed]` in its
# profile.yaml, through JIG_VERIFY_SCOPE and JIG_VERIFY_FILES. A profile that
# does not declare support is run unscoped and reported as such: a silently
# ignored scope would make `pass` mean something different per profile.
#
# CI-backed projects (ADR-0041): `verify.full_run: ci` in .ai/config.yaml is
# the project's claim that its CI runs the full set. A flag-less `jig verify`
# then narrows to what changed since the merge base with the base the current
# task was cut from (jig_task_base, ADR-0039), or git.base_branch when there is
# no current task, unless CI is set or --full is given. A project map
# (.ai/verify/<profile>.map) is parsed here, never in a profile, and handed to
# profiles declaring `scope: [changed, map]` as JIG_VERIFY_MAPPED.
#
# One run per clone, and a run that dies is not a pass
# (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass): a run
# takes a record every worktree of the clone can see and waits while another
# holds it, and a profile that was killed rather than failed is reported as a
# third outcome, `incomplete`, with exit code 3.
# bash 3.2 compatible: no associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

# --- scope helpers -----------------------------------------------------------

# _verify_changed_files [<base>] — repo-relative paths of files that differ
# from <base> (when given) or from HEAD, plus untracked files, one per line,
# sorted and deduplicated. Staged and unstaged changes both count: a project
# is verified in the state it is in, not in the state it was committed in.
_verify_changed_files() {
  local base="$1"
  if [ -n "$base" ]; then
    git -C "$JIG_PROJECT" rev-parse --verify --quiet "$base^{commit}" >/dev/null \
      || jig_die "verify: not a commit: $base"
  fi
  {
    [ -z "$base" ] || git -C "$JIG_PROJECT" diff --name-only "$base" --
    git -C "$JIG_PROJECT" rev-parse --verify --quiet HEAD >/dev/null \
      && git -C "$JIG_PROJECT" diff --name-only HEAD --
    git -C "$JIG_PROJECT" ls-files --others --exclude-standard
  } 2>/dev/null | sed '/^$/d' | LC_ALL=C sort -u
}

# _verify_task_base <base-var> <which-var> — the base the task in this
# checkout was cut from into <base-var>, and which task into <which-var>
# (`task <id>`); both empty when there is no task to ask. The answer is
# jig_task_base's, the one `task ship`, housekeeping and context judge the
# task by (ADR-0039). The current task comes from `jig task current` run as a
# process, not from sourcing task.sh (ARCHITECTURE.md: one command library
# never sources another). Several live tasks on one branch (exit 2, one
# candidate per stderr line, id first) give their base only when they all
# agree on it; tasks that disagree, or no task, leave the configured base to
# the caller.
_verify_task_base() {
  local __vtb_cur __vtb_rc=0 __vtb_err __vtb_ids __vtb_id __vtb_b
  local __vtb_agreed="" __vtb_which=""
  printf -v "$1" '%s' ""
  printf -v "$2" '%s' ""
  __vtb_err=$(mktemp "${TMPDIR:-/tmp}/jig-verify-current.XXXXXX") || return 0
  jig_cleanup_add "$__vtb_err"
  # JIG_INTERNAL_REDRAW: a re-entry, not a session's command — it must neither
  # rewrite the checkout record nor spend a pending HEAD-moved notice, whose
  # stderr lines would also be read below as task ids.
  __vtb_cur=$(JIG_INTERNAL_REDRAW=1 "$JIG_SELF" task current 2>"$__vtb_err") || __vtb_rc=$?
  case "$__vtb_rc" in
    0)
      jig_task_base_v __vtb_agreed "$__vtb_cur"
      __vtb_which="task $__vtb_cur"
      ;;
    2)
      __vtb_ids=$(awk '{ print $1 }' "$__vtb_err")
      for __vtb_id in $__vtb_ids; do
        jig_task_base_v __vtb_b "$__vtb_id"
        if [ -z "$__vtb_agreed" ]; then
          __vtb_agreed="$__vtb_b"
        elif [ "$__vtb_b" != "$__vtb_agreed" ]; then
          __vtb_agreed=""
          break
        fi
        __vtb_which="${__vtb_which:+$__vtb_which, }$__vtb_id"
      done
      __vtb_which="tasks $__vtb_which"
      ;;
  esac
  rm -f "$__vtb_err"
  if [ -n "$__vtb_agreed" ]; then
    printf -v "$1" '%s' "$__vtb_agreed"
    printf -v "$2" '%s' "$__vtb_which"
  fi
  return 0
}

# _verify_merge_base <base-branch> <ref-var> <mb-var> — the ref <base-branch>
# is judged by (jig_base_ref) into <ref-var>, and its merge base with HEAD into
# <mb-var>; <mb-var> is empty when either cannot be found.
_verify_merge_base() {
  local __vmb_ref __vmb_mb=""
  __vmb_ref=$(jig_base_ref "$1")
  if [ -n "$__vmb_ref" ]; then
    __vmb_mb=$(git -C "$JIG_PROJECT" merge-base "$__vmb_ref" HEAD 2>/dev/null) || __vmb_mb=""
  fi
  printf -v "$2" '%s' "$__vmb_ref"
  printf -v "$3" '%s' "$__vmb_mb"
  return 0
}

# _verify_ref_label <ref> — how a base ref reads in the report:
# refs/remotes/origin/main -> origin/main, refs/heads/main -> main.
_verify_ref_label() {
  local ref="$1"
  ref=${ref#refs/remotes/}
  ref=${ref#refs/heads/}
  printf '%s\n' "$ref"
}

# _verify_map_check <map> — validate a project map before anything uses it.
# Prints `<line>: <reason>` for the first bad line and exits 1; exits 0 when
# every line is usable. A line is `<glob> <decision>...` where the decision is
# `-`, `ALL`, or one or more filters; `-` and `ALL` stand alone. Checked as a
# whole, not only the lines a run happens to match: a line that is wrong today
# narrows the wrong way the day a path starts matching it.
_verify_map_check() {
  local map="$1" line n=0 glob rest tok count special
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    # A map saved on Windows ends its lines in CR; the filter must not.
    line=${line//$'\r'/}
    line=${line%%#*}
    # Word splitting must not expand a glob against the working directory.
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    [ $# -gt 0 ] || continue
    glob="$1"
    shift
    [ $# -gt 0 ] || { printf '%d: no decision for %s\n' "$n" "$glob"; return 1; }
    count=$#
    special=0
    for tok in "$@"; do
      case "$tok" in
        -|ALL) special=1 ;;
      esac
    done
    if [ "$special" = 1 ] && [ "$count" -gt 1 ]; then
      rest="$*"
      printf "%d: '-' and 'ALL' stand alone: %s\n" "$n" "$rest"
      return 1
    fi
  done < "$map"
  return 0
}

# _verify_map_apply <map> <files> — one `<path><TAB><decision>` line per path
# in <files>: the tokens of the first map line whose glob matches, or `?` when
# none does. Globs follow `detect`: `**` and `*` both match across `/`, and a
# glob is matched against the path string, never the filesystem. Run only on
# a map _verify_map_check accepted.
_verify_map_apply() {
  local map="$1" files="$2" path line glob decision found
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    found=0
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line//$'\r'/}
      line=${line%%#*}
      # Word splitting must not expand a glob against the working directory.
      set -f
      # shellcheck disable=SC2086
      set -- $line
      set +f
      [ $# -gt 0 ] || continue
      glob=${1//\*\*/*}
      shift
      # shellcheck disable=SC2254
      case "$path" in
        $glob) decision="$*"; found=1; break ;;
      esac
    done < "$map"
    [ "$found" = 1 ] || decision='?'
    printf '%s\t%s\n' "$path" "$decision"
  done < "$files"
}

# --- one run per clone -------------------------------------------------------
#
# Eight agents, each obeying "avoid simultaneous duplicate full runs" with one
# run of its own, produced eight full sets on one machine: load average 364, a
# set that takes 5-6 minutes alone taking forty, and two reviews stalled at 40
# and 50 minutes. The rule was written for one actor and says nothing about a
# population, so nobody broke it. What was missing is a fact the machine can
# see for itself.
#
# Waiting, not refusing: run serially and the eight sets finish at 6, 12, 18 …
# 48 minutes — seven of the eight answers sooner than under contention, the
# average at 27 minutes against forty, only the last later by one set's length.
# What settles it is everything else on the machine: the two reviews that
# stalled at 40 and 50 minutes were not running a suite, they were queued
# behind eight of them. A refusal would break CI and honest parallel work; a
# warning is the same prose that already failed.
#
# The record is read by jig_verify_busy_holder and its helpers in common.sh:
# `jig upgrade` asks the same question before it replaces scripts.

# _verify_busy_claim <dir> — take the record, or fail.
#
# Creating `busy/run` exclusively is the claim (jig_claim_file,
# adr-20261023-a-claim-is-an-exclusive-create); `busy/` is only its container.
# Atomicity is the whole point: with a plain flag file, eight waiters wake
# together when the holder leaves and produce the eight simultaneous sets
# again. The kernel is the arbiter, so the reclaim of an expired record races
# safely too.
#
# The body is written straight into the claimed directory rather than through a
# temporary: only the claimant can write there, a reader that catches a partial
# file falls back to the ttl, and a leftover temporary would make `rmdir` refuse
# for good.
_verify_busy_claim() {
  local dir="$1"
  mkdir -p "$dir/busy" 2>/dev/null || return 1
  jig_claim_file "$dir/busy/run" || return 1
  printf 'checkout: %s\npid: %s\n' "$JIG_PROJECT" "$$" > "$dir/busy/run" 2>/dev/null || {
    rm -f "$dir/busy/run" 2>/dev/null || true
    rmdir "$dir/busy" 2>/dev/null || true
    return 1
  }
  return 0
}

# _verify_busy_release <dir> — give the record back.
#
# The shape ADR-0035 allows `jig spec new`: one named file removed, then
# `rmdir`, which refuses a directory that is not empty. No `rm -rf` on a
# computed path anywhere, and the path is checked to be the one this code
# builds before anything is deleted (RULES.md).
_verify_busy_release() {
  local dir="$1"
  [ -n "$dir" ] || return 0
  case "$dir" in
    */"$JIG_AI_DIR"/runtime/verify) ;;
    *) return 0 ;;
  esac
  rm -f "$dir/busy/run" 2>/dev/null || true
  rmdir "$dir/busy" 2>/dev/null || true
  return 0
}

# _verify_busy_acquire — hold the clone for this run, waiting while another has
# it. Sets JIG_VERIFY_BUSY to the directory when the record is ours, so the
# EXIT trap gives it back, and prints one line to stdout when a wait happened:
# the evidence belongs in the report, while the waiting itself goes to stderr,
# where it cannot become part of output a caller reads.
#
# Nothing here may fail `jig verify`. Every path that cannot answer gives up and
# lets the run go ahead: a record that cannot be taken is a missed serialisation,
# which is today's behaviour, while a refusal would be a new way to break.
_verify_busy_acquire() {
  local dir ttl holder age checkout waited=0 announced=0 said=0 ago futile=0

  # CI parallelism is deliberate and each job has a machine of its own. `CI` is
  # the signal this command already trusts for `verify.full_run` (ADR-0041), so
  # the mechanism is off there rather than queueing jobs meant to run at once.
  [ -z "${CI:-}" ] || return 0

  ttl=$(jig_verify_busy_ttl)
  [ "$ttl" -gt 0 ] || return 0
  dir=$(jig_verify_busy_dir) || return 0
  [ -n "$dir" ] || return 0

  # A `jig verify` started by a run that already holds this clone — a suite that
  # verifies its own project — must not wait for itself.
  [ "${JIG_VERIFY_BUSY_HELD:-}" != "$dir" ] || return 0

  # A directory that cannot be made at all — a read-only clone root, a
  # permission the agent does not have — is not a reason to refuse to verify.
  mkdir -p "$dir" 2>/dev/null || return 0

  while :; do
    if _verify_busy_claim "$dir"; then
      JIG_VERIFY_BUSY="$dir"
      export JIG_VERIFY_BUSY_HELD="$dir"
      if [ "$waited" -gt 0 ]; then
        printf 'verify: waited %s for the run in %s\n' \
          "$(jig_checkout_ago "$waited")" "$checkout"
      fi
      return 0
    fi
    holder=$(jig_verify_busy_holder "$dir" "$ttl") || holder=""
    if [ -z "$holder" ]; then
      # Nobody live is behind the record: take it back, by the two bounded
      # deletions above, and let the loop claim it. The exclusive create of
      # `busy/run` still decides between two reclaimers.
      _verify_busy_release "$dir"
      # Neither claiming nor reclaiming worked, and nobody is holding it: the
      # filesystem is answering no, not another run. A few attempts allow for
      # losing the reclaim race to a neighbour; after that, verify anyway. A
      # record that cannot be taken is a missed serialisation, which is what
      # every run did until today — spinning here would be a new way to hang.
      futile=$((futile + 1))
      if [ "$futile" -ge 5 ]; then
        jig_info "verify: cannot take the run record in $dir; running without it"
        return 0
      fi
      continue
    fi
    futile=0
    age=${holder%% *}
    checkout=${holder#* }
    ago=$(jig_checkout_ago "$age")
    if [ "$announced" = 0 ]; then
      announced=1
      jig_info "verify: another run holds this clone (in $checkout, started $ago ago); waiting for it"
      jig_info "  two sets at once make both slower than running them in turn;" \
        "set verify.busy_ttl: 0 in .ai/config.local.yaml never to wait"
    elif [ $((waited - said)) -ge 60 ]; then
      said="$waited"
      jig_info "verify: still waiting ($(jig_checkout_ago "$waited"))"
    fi
    sleep 2
    waited=$((waited + 2))
  done
}

# _verify_skip_lines_all_scoped <output> — true when <output> (a covered
# profile's captured run, one printed line per check) names at least one
# "<check>: skip (…)" line and every such line's reason starts with "scope:".
# That wording is the profile contract's own for a narrowed-out check
# (ADR-0013's example, and every stack profile shipped with jig follows it:
# profiles/{shell,php,node,go}/verify.sh). Output with no skip line at all is
# read as the cautious default and answered false, same as an undeclared
# scope capability elsewhere in this file: a profile that skipped everything
# without saying why is a defect, not proof of narrowing.
_verify_skip_lines_all_scoped() {
  local line any=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *": skip ("*)
        any=1
        case "$line" in
          *": skip (scope:"*) ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done <<EOF
$1
EOF
  [ "$any" = 1 ]
}

# _verify_count_left_to_ci <output> — how many of a profile's check lines say
# a narrowed run left the full set to CI: a skip `<check>: skip (scope: …, full
# set left to CI)` as jp_full_left_to_ci prints it, and a check that ran its
# filters after an ALL beside them was dropped (`pass (…, full set left to CI)`).
_verify_count_left_to_ci() {
  local line n=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      RESULT\ *) ;;
      *": "*" ("*", full set left to CI)") n=$((n + 1)) ;;
    esac
  done <<EOF
$1
EOF
  printf '%s\n' "$n"
}

# _verify_cleanup — the one EXIT trap: temporary files and the run record. Its
# variables are script-global, never `local`, because the trap runs after the
# function that set them has returned (conventions/shell.md).
_verify_cleanup() {
  if [ -n "${JIG_VERIFY_MAP_ALL_TMP:-}" ]; then
    rm -f "$JIG_VERIFY_MAP_ALL_TMP.list" 2>/dev/null || true
  fi
  if [ -n "${JIG_VERIFY_MAP_TMP:-}" ]; then
    rm -f "$JIG_VERIFY_MAP_TMP.src" 2>/dev/null || true
  fi
  rm -f "${JIG_VERIFY_TMP:-}" "${JIG_VERIFY_MAP_TMP:-}" "${JIG_VERIFY_MAP_ALL_TMP:-}" "${JIG_VERIFY_CHECKS_TMP:-}" 2>/dev/null || true
  if [ -n "${JIG_VERIFY_BUSY:-}" ]; then
    _verify_busy_release "$JIG_VERIFY_BUSY"
    JIG_VERIFY_BUSY=""
  fi
  return 0
}

# --- a profile covers a check of another ------------------------------------
#
# A profile above another can run the same work one of its checks does — a
# project's own test runner is a stack's suite — and a run with both paid for
# it twice. The profile above says so, `covers: [php:tests]`;
# the profile below names the check it can hand over, `checks: [tests]`, and
# nothing about who takes it. Which covers hold in a run is decided here,
# once, and handed down as JIG_VERIFY_COVERED; the profile's jp_covered prints
# the skip (adr-20261107-a-profile-covers-a-check-of-another).

# _verify_covers <installed-dir> <run-profiles> <narrowed> [<edges>] — the covers
# that hold in this run, one line each as _verify_covers_resolve prints them,
# first covering profile in run order kept. <run-profiles> are the
# profiles the run will start: a profile that never starts covers nothing,
# and a check of a profile that never starts needs no cover. A cover holds
# only where the covering profile applies (profiles_applies), only for a
# check the covered profile names (else a warning: the check still runs), and
# the check is addressed as a layer's row is (adr-20261118-a-layer-overrides-its-bases-checks-by-role):
# `covers: [laravel:tests]` over a pure layer laravel is the check of the first
# profile of laravel's chain that is no pure layer and lists `tests`; a pure
# layer whose chain lists none is warned about, nothing is covered. And
# not when the covering profile's own check of that name is dropped by a layer
# above it in <edges>: nothing would run it, so the covered profile does (said
# on stderr, with the other notes of this function).
_verify_covers() {
  local dir="$1" run=" $2 " narrowed="$3" edges="${4:-}" u udir item b check bdir seen="" raw=""
  local named chain owner
  # shellcheck disable=SC2034 # dv takes the value _profiles_tab_find_v is not asked for
  local ovr dropper dv lifted=""
  for u in $2; do
    udir=$(profiles_dir "$dir" "$u")
    profiles_check_overrides_v ovr "$udir" "$edges"
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      b=${item%%:*}
      check=${item#*:}
      if [ "$b" = "$item" ] || [ -z "$check" ] || ! _profiles_valid_name "$b"; then
        jig_warn "profile '$u' covers '$item', which is not <profile>:<check>; ignored"
        continue
      fi
      # The letters are spelled out: a range such as a-z follows the locale,
      # and under some (macOS en_US.UTF-8) it admits capitals.
      case "$check" in
        *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) jig_warn "profile '$u' covers '$item', which is not <profile>:<check>; ignored"; continue ;;
      esac
      # The profile the cover names may be a layer, or a profile over one: the
      # check is the one its chain runs.
      named=$b
      if [ -n "$edges" ]; then
        _profiles_chain_v chain "$b" "$edges"
        _profiles_role_owner_v owner "$check" "$chain" "$dir"
        if [ -n "$owner" ]; then
          b=$owner
        elif [ "$chain" != "$b" ] && _profiles_is_pure "$(profiles_dir "$dir" "$b")"; then
          # A pure layer of this run's stack (it has a base in <edges>); one
          # outside the stack covers nothing, as a profile that never starts.
          jig_warn "profile '$u' covers '$item', but no profile of $b's chain names a check '$check' (checks:), so nothing is covered"
          continue
        fi
      fi
      [ "$b" != "$u" ] || continue
      case "$run" in
        *" $b "*) ;;
        *) continue ;;
      esac
      case "$seen" in
        *" $b:$check "*) continue ;;
      esac
      profiles_applies "$udir" || continue
      bdir=$(profiles_dir "$dir" "$b")
      if ! profiles_names_check "$bdir" "$check"; then
        jig_warn "profile '$u' covers '$b:$check', but '$b' names no check '$check' (checks:), so it still runs"
        continue
      fi
      if [ -n "$ovr" ] && _profiles_tab_find_v dv "$ovr" "$check" drop dropper; then
        # Lifted for now: decided below, once the covers that hold are known.
        lifted="${lifted}$b	$check	$u	$named	$dropper
"
        continue
      fi
      seen="$seen $b:$check "
      raw="${raw}$b	$check	$u	$named
"
    done < <(_profiles_list_lines "$udir" covers)
  done
  # A dropped check that another profile still runs by a cover is not left to
  # nobody: the drop has no effect there (the override warning says so), so the
  # dropped profile's own cover stands and follows the chain to that runner —
  # `myapp covers up:tests`, `up covers low:tests` and up's tests dropped still
  # run the suite once, in myapp. Decided on the covers that survive
  # _verify_covers_resolve (a narrowed run may drop one over maps), until no
  # lifted cover comes back; its warnings are printed once, by the last call.
  local resolved rest changed lb lc lu ln ld
  while [ -n "$lifted" ]; do
    resolved=$(_verify_covers_resolve "$dir" "$raw" "$narrowed" "$edges" 2>/dev/null)
    rest=""
    changed=0
    while IFS=$'\t' read -r lb lc lu ln ld; do
      [ -n "$lb" ] || continue
      if _verify_covers_held "$resolved" "$lu" "$lc"; then
        case "$seen" in
          *" $lb:$lc "*) ;;
          *)
            seen="$seen $lb:$lc "
            raw="${raw}$lb	$lc	$lu	$ln
"
            ;;
        esac
        changed=1
      else
        rest="${rest}$lb	$lc	$lu	$ln	$ld
"
      fi
    done <<EOF
$lifted
EOF
    lifted=$rest
    [ "$changed" = 1 ] || break
  done
  resolved=$(_verify_covers_resolve "$dir" "$raw" "$narrowed" "$edges")
  _verify_covers_lifted_lines "$dir" "$resolved" "$lifted" "$edges"
  [ -z "$resolved" ] || printf '%s\n' "$resolved"
}

# _verify_covers_held <covers> <profile> <check> — true when <covers> (as
# _verify_covers_resolve prints them) hands <profile>'s <check> to another profile.
_verify_covers_held() {
  local b c _r
  while IFS=$'\t' read -r b c _r; do
    [ "$b" = "$2" ] && [ "$c" = "$3" ] && return 0
  done <<EOF
$1
EOF
  return 1
}

# _verify_covers_lifted_lines <installed-dir> <covers> <lifted> [<edges>] — on stderr,
# one line per cover a drop lifted, naming the profile that really runs the check:
# the covered profile, or, when its own check is dropped too, the one its own lifted
# cover falls to, or the profile a cover that holds hands it to; `nothing runs it`
# when the last of them has the check dropped as well.
_verify_covers_lifted_lines() {
  # shellcheck disable=SC2034 # dv and dl take the values _profiles_tab_find_v is not asked for
  local dir="$1" b check u named dropper r hops nb nc nu runner ov dv dl
  while IFS=$'\t' read -r b check u named dropper; do
    [ -n "$b" ] || continue
    r=$b
    runner=""
    hops=0
    while [ "$hops" -lt 32 ]; do
      hops=$((hops + 1))
      while IFS=$'\t' read -r nb nc nu _; do
        if [ "$nb" = "$r" ] && [ "$nc" = "$check" ]; then runner=$nu; break; fi
      done <<EOF
$2
EOF
      [ -z "$runner" ] || break
      nb=""
      while IFS=$'\t' read -r nb nc nu _; do
        [ "$nu" = "$r" ] && [ "$nc" = "$check" ] && break
        nb=""
      done <<EOF
$3
EOF
      [ -n "$nb" ] || break
      r=$nb
    done
    if [ -z "$runner" ]; then
      runner=$r
      profiles_check_overrides_v ov "$(profiles_dir "$dir" "$r")" "${4:-}"
      if [ -n "$ov" ] && _profiles_tab_find_v dv "$ov" "$check" drop dl; then
        runner=""
      fi
    fi
    if [ -n "$runner" ]; then
      printf 'verify: %s:%s is dropped by %s, so %s no longer covers %s:%s; %s runs it\n' \
        "$u" "$check" "$dropper" "$u" "$b" "$check" "$runner" >&2
    else
      printf 'verify: %s:%s is dropped by %s, so %s no longer covers %s:%s; nothing runs it\n' \
        "$u" "$check" "$dropper" "$u" "$b" "$check" >&2
    fi
  done <<EOF
$3
EOF
  return 0
}

# _verify_profile_maps_v <var> <installed-dir> <profile> <edges> — the project maps
# that exist for <profile>, space-separated, each written as
# `$JIG_AI_DIR/verify/<name>.map`: the maps of the pure layers whose tests it runs
# (profiles_layer_maps_v), topmost first, then its own. Empty when there is none.
_verify_profile_maps_v() {
  local __pm_lyrs __pm_n __pm_out=""
  profiles_layer_maps_v __pm_lyrs "$2" "$3" "$4"
  for __pm_n in $__pm_lyrs "$3"; do
    [ ! -f "$JIG_PROJECT/$JIG_AI_DIR/verify/$__pm_n.map" ] || __pm_out="${__pm_out:+$__pm_out }$JIG_AI_DIR/verify/$__pm_n.map"
  done
  printf -v "$1" '%s' "$__pm_out"
}

# _verify_covers_resolve <installed-dir> <covers> <narrowed> [<edges>] — the covers of
# _verify_covers, each followed to the profile that finally runs the check:
# `shop covers myapp:tests` and `myapp covers laravel:tests` (laravel's tests being
# php's) make php's tests shop's, so php's skip names shop and php.map reaches the
# profile that runs them. Prints
# `<profile><TAB><check><TAB><runner><TAB><depth><TAB><named>`, <depth> the number
# of covers between them and <named> the profile the cover was written against
# (`laravel` for `covers: [laravel:tests]`, where <profile> is php). A chain that comes back to where
# it started runs the check nowhere: those covers are dropped with a warning,
# and every profile in it keeps its check. A cover whose map would be dropped
# — a narrowed run, the covered profile reads a map of its own, the profile
# that runs the check narrows without reading maps — is dropped with a warning
# too, and the covered profile keeps its tests; the maps of a pure layer that
# runs its tests in the covered profile count as the covered profile's own.
_verify_covers_resolve() {
  local dir="$1" all="$2" narrowed="$3" edges="${4:-}"
  local b check u named final depth seen cycle nb nc nu found wdir bdir pmaps mapfile
  while IFS=$'\t' read -r b check u named; do
    [ -n "$b" ] || continue
    final="$u"
    depth=1
    seen=" $b $u "
    cycle=0
    while :; do
      found=""
      while IFS=$'\t' read -r nb nc nu _; do
        if [ "$nb" = "$final" ] && [ "$nc" = "$check" ]; then found="$nu"; break; fi
      done <<EOF
$all
EOF
      [ -n "$found" ] || break
      case "$seen" in
        *" $found "*) cycle=1; break ;;
      esac
      final="$found"
      depth=$((depth + 1))
      seen="$seen$found "
    done
    if [ "$cycle" = 1 ]; then
      jig_warn "profile '$u' covers '$b:$check' in a circle of covers that runs it nowhere; ignored, so it still runs"
      continue
    fi
    if [ "$narrowed" = 1 ] && [ "$check" = tests ]; then
      _verify_profile_maps_v pmaps "$dir" "$b" "$edges"
      mapfile="${pmaps%% *}"
      if [ -n "$mapfile" ]; then
        bdir=$(profiles_dir "$dir" "$b")
        wdir=$(profiles_dir "$dir" "$final")
        if profiles_supports "$bdir" map && profiles_supports "$wdir" changed \
           && ! profiles_supports "$wdir" map; then
          jig_warn "profile '$final' runs '$b:$check' but reads no map, so $mapfile keeps '$b' running it"
          continue
        fi
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$check" "$final" "$depth" "$named"
  done <<EOF
$all
EOF
  return 0
}

# _verify_covered_words <covers> <profile> — the JIG_VERIFY_COVERED words for
# <profile>: `<check>=<covering profile>`, space-separated.
_verify_covered_words() {
  local b check u depth named words=""
  while IFS=$'\t' read -r b check u depth named; do
    [ "$b" = "$2" ] || continue
    words="${words:+$words }$check=$u"
  done <<EOF
$1
EOF
  printf '%s\n' "$words"
}

# _verify_handed_maps <installed-dir> <covers> <profile> — the covered profiles whose map
# (and the maps of the pure layers over them) follows their tests to <profile>, one
# `<depth><TAB><name>` line each; whether a map file exists is for the caller. A map's decisions
# narrow its profile's tests (schemas/verify-map.md), so the profile that
# took the tests over reads them: without this, a project's php.map either
# kept php running the suite beside the profile that took it or was dropped
# in silence.
_verify_handed_maps() {
  local b check u depth named
  while IFS=$'\t' read -r b check u depth named; do
    [ "$u" = "$3" ] && [ "$check" = tests ] || continue
    # A map its own profile never reads is not a decision anyone made for it.
    profiles_supports "$(profiles_dir "$1" "$b")" map || continue
    printf '%s\t%s\n' "$depth" "$b"
  done <<EOF
$2
EOF
  return 0
}

# _verify_override_lines <base> <overrides> <covers> [<edges>] — what `jig verify` says
# before a base runs about the layers that changed its checks: one line per
# overridden role, `verify: <base>:<role>: <field>[, <field>] from <layer>` (several
# layers: `full from a; narrowed from b`), so a failure names whose argument it
# ran with; a drop says nothing here, the check's own skip names the layer. A role
# another profile covers in this run is also warned about: the override has no
# effect where the check does not run (adr-20261118-a-layer-overrides-its-bases-checks-by-role).
# Not warned about: a layer on the chain from the profile the cover names down to
# <base> (the profile itself included) — `covers: [laravel:tests]` replaces what
# laravel's tests were, its own override of them too, and nobody can act on a
# warning about that.
_verify_override_lines() {
  local base="$1" roles="" role field lyr c text lyrs="" runner cb cc cu depth cn warned=" "
  local named="" nchain nl inchain
  local r f l
  while IFS=$'\t' read -r role _ _ _; do
    [ -n "$role" ] || continue
    case " $roles " in *" $role "*) ;; *) roles="$roles $role" ;; esac
  done <<EOF
$2
EOF
  for role in $roles; do
    text=""
    lyrs=""
    # Layers in the order of the fields they won: command, full, narrowed.
    for field in command full narrowed; do
      while IFS=$'\t' read -r r f _ l; do
        [ "$r" = "$role" ] && [ "$f" = "$field" ] || continue
        case " $lyrs " in *" $l "*) ;; *) lyrs="$lyrs $l" ;; esac
      done <<EOF
$2
EOF
    done
    for lyr in $lyrs; do
      c=""
      for field in command full narrowed; do
        while IFS=$'\t' read -r r f _ l; do
          if [ "$r" = "$role" ] && [ "$f" = "$field" ] && [ "$l" = "$lyr" ]; then
            c="${c:+$c, }$field"
          fi
        done <<EOF
$2
EOF
      done
      text="${text:+$text; }$c from $lyr"
    done
    [ -z "$text" ] || printf 'verify: %s:%s: %s\n' "$base" "$role" "$text"
  done
  # Every layer that wrote a field of a role, drops included, for the warning.
  while IFS=$'\t' read -r role _ _ lyr; do
    [ -n "$role" ] || continue
    runner=""
    named=""
    while IFS=$'\t' read -r cb cc cu depth cn; do
      if [ "$cb" = "$base" ] && [ "$cc" = "$role" ]; then runner=$cu; named=$cn; break; fi
    done <<EOF
$3
EOF
    [ -n "$runner" ] || continue
    if [ -n "$named" ] && [ -n "${4:-}" ]; then
      _profiles_chain_v nchain "$named" "$4"
      inchain=0
      for nl in $nchain; do
        [ "$nl" != "$lyr" ] || inchain=1
        [ "$nl" != "$base" ] || break
      done
      [ "$inchain" = 0 ] || continue
    fi
    case "$warned" in *" $lyr:$role "*) continue ;; esac
    warned="$warned$lyr:$role "
    printf 'verify: warning: %s overrides %s:%s, but %s runs it in this run (covers), so the override has no effect\n' \
      "$lyr" "$base" "$role" "$runner"
  done <<EOF
$2
EOF
}

# _verify_all_dropped_v <var> <rows> — when every role the table <rows>
# (profiles_check_merged) lists is dropped by a layer, those layers, comma
# separated, into <var>; empty otherwise. Decided from the rows `jig verify`
# wrote, never from what the profile printed.
_verify_all_dropped_v() {
  local __ad_r __ad_f __ad_v __ad_listed=0 __ad_dropped=0 __ad_layers=""
  printf -v "$1" '%s' ""
  while IFS=$'\t' read -r __ad_r __ad_f __ad_v; do
    case "$__ad_f" in
      listed) __ad_listed=$((__ad_listed + 1)) ;;
      drop)
        __ad_dropped=$((__ad_dropped + 1))
        case ", $__ad_layers," in *", $__ad_v,"*) ;; *) __ad_layers="${__ad_layers:+$__ad_layers, }$__ad_v" ;; esac
        ;;
    esac
  done <<EOF
$2
EOF
  if [ "$__ad_listed" -gt 0 ] && [ "$__ad_dropped" -ge "$__ad_listed" ]; then
    printf -v "$1" '%s' "$__ad_layers"
  fi
  return 0
}

cmd_verify() {
  jig_require_init
  # shellcheck source=lib/profiles.sh
  . "$JIG_LIB/profiles.sh"

  # Each --profile value is split on commas only (never on internal
  # whitespace) and every resulting token is validated immediately via
  # _profiles_valid_name. Splitting on generic whitespace instead of just
  # ',' would silently turn one malformed token containing a space (e.g.
  # "a b") into two well-formed single-word names, defeating validation
  # entirely; an entirely empty value (`--profile ''`) is checked up front
  # since piping an empty string through `tr`/`read` yields zero lines, not
  # one empty line, and would otherwise be dropped rather than rejected.
  local list_only=0 explain=0 profile_given=0 profiles_words="" p pdir raw tok
  local scope=0 base="" nfiles=0 scope_ok note full=0 explicit=0 full_run
  local header="" base_branch base_ref mb map map_ok map_err maps maps_listed map_bad b pmaps stale_base stock_src stale_why tracked_profiles=""
  local incomplete=0 covered=0 explained=0 unknown=0 plan_output plan_bad hr_state hr_rt hr_text
  local table_err table_rows table_overrides="" base_roles="" p_dropped="" dropped_msg="" dropped_needs=0 covered_needs_install=0 is_fallback=0 run_output ci_left=0 task_base="" task_which="" task_note=""
  JIG_VERIFY_TMP=""
  JIG_VERIFY_MAP_TMP=""
  JIG_VERIFY_MAP_ALL_TMP=""
  JIG_VERIFY_CHECKS_TMP=""
  JIG_VERIFY_BUSY=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --changed) scope=1; explicit=1; shift ;;
      --full) full=1; shift ;;
      --base)
        [ $# -ge 2 ] || jig_die "verify: --base requires a value"
        base="$2"
        shift 2
        ;;
      --profile)
        [ $# -ge 2 ] || jig_die "verify: --profile requires a value"
        profile_given=1
        raw="$2"
        [ -n "$raw" ] || jig_die "invalid profile name: $raw"
        while IFS= read -r tok; do
          tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
          _profiles_valid_name "$tok" || jig_die "invalid profile name: $tok"
          case " $profiles_words " in
            *" $tok "*) ;;
            *) profiles_words="$profiles_words $tok" ;;
          esac
        done < <(printf '%s\n' "$raw" | tr ',' '\n')
        shift 2
        ;;
      --list) list_only=1; shift ;;
      --explain) explain=1; shift ;;
      *) jig_die "verify: unknown argument: $1" ;;
    esac
  done
  profiles_words="${profiles_words# }"

  if [ "$list_only" = 1 ] && [ "$explain" = 1 ]; then
    jig_die "verify: --list cannot be combined with --explain"
  fi

  [ "$profile_given" = 1 ] || profiles_words=$(profiles_active)

  local installed_dir
  installed_dir=$(profiles_installed_dir)

  # The stack: the names asked for (a `--profile` list, or `profiles:`) and every
  # base they extend, a layer before its base. `--profile php` runs php and what
  # php extends, never what extends php. A stack that does not resolve is refused
  # below, after the staleness gate; here the names stay as they were asked.
  local plain_words="$profiles_words" stack_err="" stack_layer="" stack_edges=""
  # shellcheck disable=SC2086
  if profiles_stack_v profiles_words $plain_words; then
    # shellcheck disable=SC2086
    profiles_stack_v stack_edges --edges $plain_words || true
  else
    stack_err=$PROFILES_STACK_ERROR
    stack_layer=$PROFILES_STACK_LAYER
    profiles_words=$plain_words
  fi

  if [ "$list_only" = 1 ]; then
    local over under e
    for p in $profiles_words; do
      pdir=$(profiles_dir "$installed_dir" "$p")
      if [ -d "$pdir" ]; then
        over=""
        under=""
        while IFS=$'\t' read -r e b; do
          [ -n "$e" ] || continue
          [ "$e" != "$p" ] || over=$b
          [ "$b" != "$p" ] || under="${under:+$under, }$e"
        done <<EOF
$stack_edges
EOF
        note=""
        [ -z "$over" ] || note="layer over $over"
        [ -z "$under" ] || note="${note:+$note; }base of $under"
        printf '%s: installed%s\n' "$p" "${note:+ ($note)}"
      else
        printf '%s: not installed\n' "$p"
      fi
    done
    if [ -n "$stack_err" ]; then
      printf 'FAIL %s\n' "$stack_err"
      return 1
    fi
    return 0
  fi

  # --- mode -------------------------------------------------------------------
  # `verify.full_run` is a claim the project makes, so a value that is neither
  # answer is refused rather than read as one of them: a typo must not quietly
  # narrow every run, nor quietly stop narrowing.
  full_run=$(cfg verify.full_run local)
  case "$full_run" in
    local|ci) ;;
    *) jig_die "verify: invalid verify.full_run: $full_run (expected local or ci)" ;;
  esac

  if [ "$full" = 1 ] && { [ "$scope" = 1 ] || [ -n "$base" ]; }; then
    jig_die "verify: --full cannot be combined with --changed or --base"
  fi
  if [ -n "$base" ] && [ "$scope" = 0 ]; then
    [ "$full_run" = ci ] || jig_die "verify: --base requires --changed"
    explicit=1
  fi

  if [ "$full_run" = ci ] && [ "$scope" = 0 ] && [ "$explicit" = 0 ]; then
    # Explicit narrowing (--changed, --base) wins over CI; CI and --full win
    # over the configured default. Without the CI check, a project whose CI
    # calls `jig verify` would narrow the one run the key relies on.
    if [ "$full" = 1 ]; then
      header="verify: full run (--full)"
    elif [ -n "${CI:-}" ]; then
      header="verify: full run (CI is set)"
    else
      scope=1
      # The current task's own base first (ADR-0039): a task cut from an epic
      # is measured from the epic, not from main, or every task re-runs the
      # whole epic's diff. A recorded base this clone cannot resolve (an epic
      # deleted after its merge, never fetched) falls back to the configured
      # one, never to the working tree alone.
      base_branch=$(cfg git.base_branch main)
      _verify_task_base task_base task_which
      base_ref=""
      mb=""
      if [ -n "$task_base" ]; then
        _verify_merge_base "$task_base" base_ref mb
        if [ -n "$mb" ]; then
          base_branch="$task_base"
          task_note="base of $task_which; "
        fi
      fi
      [ -n "$mb" ] || _verify_merge_base "$base_branch" base_ref mb
      if [ -n "$mb" ]; then
        base="$mb"
        header=$(printf 'verify: scope changed since %s@%s (%sverify.full_run: ci, full set runs in CI)' \
          "$(_verify_ref_label "$base_ref")" "$(git -C "$JIG_PROJECT" rev-parse --short "$mb")" \
          "$task_note")
      else
        header="verify: scope changed in the working tree only, no merge base with $base_branch (verify.full_run: ci, full set runs in CI)"
      fi
    fi
  elif [ "$full_run" = ci ] && [ "$scope" = 0 ] && [ -n "$base" ]; then
    scope=1
    header=$(printf 'verify: scope changed since %s (--base)' "$base")
  fi

  # --- staleness gate --------------------------------------------------------
  # A pass from a stale install is meaningless: refuse before running any
  # profile when the current config would still need `jig upgrade` to place
  # framework-owned files (a skill or profile added to the source but never
  # copied/linked in — the gap `jig status`'s drift count used to miss
  # entirely, since drift only covers paths already recorded in the
  # manifest). Skipped only for `--list`, handled above; not folded into the
  # `verify: %d profiles, ...` tally below, which counts profiles, not
  # framework files.
  # shellcheck source=lib/upgrade.sh
  . "$JIG_LIB/upgrade.sh"
  local fw_pending fw_pending_rc=0 fw_pending_n
  fw_pending=$(upgrade_pending) || fw_pending_rc=$?
  if [ "$fw_pending_rc" = 0 ]; then
    fw_pending_n=$(printf '%s\n' "$fw_pending" | grep -c . || true)
    if [ "$fw_pending_n" -gt 0 ]; then
      printf '%s\n' "$fw_pending"
      local fw_word='files'
      if [ "$fw_pending_n" = 1 ]; then fw_word='file'; fi
      printf 'FAIL framework: %d framework %s not installed (run jig upgrade)\n' \
        "$fw_pending_n" "$fw_word"
      return 1
    fi
  fi
  # fw_pending_rc != 0: pending state unknown (e.g. no source checkout on
  # this machine, domains/install) — proceed and verify the profiles normally.

  # A stack that does not resolve, or a layer whose check table is wrong, is
  # refused before any profile starts: a layer that runs without its base, or
  # whose override is ignored, passes for something it did not check. After the
  # gate above, which catches a missing stock base first.
  if [ -n "$stack_err" ]; then
    if [ "$explain" = 1 ]; then
      printf 'PLAN %s: error (%s)\n' "$stack_layer" "${stack_err#"$stack_layer: "}"
    else
      printf 'FAIL %s\n' "$stack_err"
    fi
    return 1
  fi
  local layer_refused=0 lint_layer lint_n lint_reason
  while IFS=$'\t' read -r lint_layer lint_n lint_reason; do
    [ -n "$lint_layer" ] || continue
    layer_refused=1
    if [ "$explain" = 1 ]; then
      printf 'PLAN %s: error (profile.yaml:%s: %s)\n' "$lint_layer" "$lint_n" "$lint_reason"
    else
      printf 'FAIL %s: profile.yaml:%s: %s\n' "$lint_layer" "$lint_n" "$lint_reason"
    fi
  done < <(
    # shellcheck disable=SC2086
    profiles_check_layers "$installed_dir" "$stack_edges" $profiles_words || true
  )
  [ "$layer_refused" = 0 ] || return 1

  # One trap for both the temporary files and the run record: the record has to
  # come back on every exit, not only on a run that narrowed.
  jig_on_exit '_verify_cleanup'

  if [ "$scope" = 1 ]; then
    JIG_VERIFY_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-verify-files.XXXXXX") \
      || jig_die "verify: cannot create temporary file"
    _verify_changed_files "$base" > "$JIG_VERIFY_TMP"
    nfiles=$(grep -c . < "$JIG_VERIFY_TMP" || true)
  fi

  [ -z "$header" ] || printf '%s\n' "$header"

  # Where the project's commands run, decided once for every profile
  # (adr-20261001-checks-run-where-the-project-runs). A refusal means nothing
  # was checked: exit 3, before anyone waits for the clone.
  # shellcheck source=lib/runenv.sh
  . "$JIG_LIB/runenv.sh"
  unset JIG_RUN_EXEC
  runenv_resolve
  if [ -n "$RUNENV_REFUSAL" ]; then
    printf 'verify: refused: %s\n' "$RUNENV_REFUSAL"
    if [ "$explain" = 1 ]; then return 1; fi
    return 3
  fi
  if [ "$explain" = 1 ] || [ -n "$RUNENV_EXEC" ] || [ -n "$RUNENV_PATH" ]; then
    printf 'verify: checks run in %s\n' "$RUNENV_WHERE"
  fi
  # A host runtime that is not first on PATH (Herd, or run.path): every
  # profile runs on this machine as before, with that directory first — the
  # PHP a person's own terminal finds, not a capability a profile must learn.
  if [ -n "$RUNENV_PATH" ]; then
    PATH="$RUNENV_PATH:$PATH"
    export PATH
  fi

  # On the host, say when its runtime is not the one the project asks for.
  if [ "$explain" = 1 ] && [ -z "$RUNENV_EXEC" ]; then
    # shellcheck source=lib/hostruntime.sh
    . "$JIG_LIB/hostruntime.sh"
    while IFS=$'\t' read -r hr_state hr_rt hr_text; do
      case "$hr_state" in
        mismatch | unknown) printf 'verify: warning: host %s: %s\n' "$hr_rt" "$hr_text" ;;
      esac
    done < <(hostruntime_report)
  fi

  # Taken here, after every refusal above has had its chance: nobody should
  # wait for the clone only to be told their arguments were wrong.
  if [ "$explain" = 0 ]; then
    _verify_busy_acquire
  else
    printf 'verify: plan only — no checks have run\n'
  fi

  profiles_check_requires

  # The profiles this run will actually start, and the covers that hold
  # between them. A profile the loop below will not start covers nothing: no
  # verify.sh, no `explain` in a preview, no `environment` under one — the
  # same gates, in the same order, so a check never stands down for a profile
  # that never runs.
  local run_profiles="" covers
  for p in $profiles_words; do
    pdir=$(profiles_dir "$installed_dir" "$p")
    [ -f "$pdir/verify.sh" ] || continue
    if [ "$explain" = 1 ] && ! profiles_supports "$pdir" explain; then continue; fi
    if [ -n "$RUNENV_EXEC" ] && ! profiles_supports "$pdir" environment; then continue; fi
    run_profiles="${run_profiles:+$run_profiles }$p"
  done
  covers=$(_verify_covers "$installed_dir" "$run_profiles" "$scope" "$stack_edges")

  local total=0 pass=0 failn=0 skip=0 rc
  for p in $profiles_words; do
    pdir=$(profiles_dir "$installed_dir" "$p")

    # A pure layer — it extends a profile and has no verify.sh of its own — is
    # a few lines of configuration over its base, not a broken install: it runs
    # nothing, is not counted, and says where its checks run. Whether anything
    # was covered is what its bases say.
    if [ -f "$pdir/profile.yaml" ] && [ ! -f "$pdir/verify.sh" ]; then
      profile_get_v ext "$pdir" extends || true
      if [ -n "$ext" ]; then
        printf 'verify: %s is a layer over %s; its checks run in its bases\n' "$p" "$ext"
        continue
      fi
    fi

    total=$((total + 1))

    if [ ! -d "$pdir" ]; then
      if [ "$explain" = 1 ]; then
        printf 'PLAN %s: unknown (not installed; run jig upgrade)\n' "$p"
        unknown=$((unknown + 1))
      else
        printf 'FAIL %s: not installed (run jig upgrade)\n' "$p"
        failn=$((failn + 1))
      fi
      continue
    fi

    # Did anything here have something to check? A profile that covers a stack
    # says yes by being here at all — the stack was recognised, whatever its
    # tools, or its missing verify.sh, then did. A fallback says nothing either
    # way. Asked before the checks below, so a profile that is installed but
    # broken still counts as "there was something to check": that is a defect to
    # fix, not a project nothing covers.
    is_fallback=0
    if profiles_is_fallback "$pdir"; then
      is_fallback=1
    else
      covered=1
    fi

    if [ ! -f "$pdir/verify.sh" ]; then
      # A stock profile that became a layer while the installed profile.yaml was
      # kept (hand-edited, so upgrade left it and deleted the verify.sh): without
      # `extends` it is not a layer, and its base would run the checks its own
      # way, silently. With the source at hand the stock copy names the base;
      # without it (a copy-mode project running its own jig) a profile the
      # manifest tracks — one jig placed — with neither a verify.sh nor an
      # `extends` fails the same way: its checks run nowhere.
      stale_base=""
      stale_why=""
      ext=""
      [ ! -f "$pdir/profile.yaml" ] || profile_get_v ext "$pdir" extends || true
      if [ -f "$pdir/profile.yaml" ] && [ -z "$ext" ]; then
        stock_src=$(profiles_source_dir)
        if [ -n "$stock_src" ] && [ -f "$stock_src/$p/profile.yaml" ]; then
          profile_get_v stale_base "$stock_src/$p" extends || stale_base=""
          [ -z "$stale_base" ] || stale_why="profile.yaml has no extends, but the stock $p now extends $stale_base and ships no verify.sh; jig upgrade kept your edited profile.yaml — carry your edits onto the new one"
        fi
        if [ -z "$stale_why" ] && [ -z "$stock_src" ]; then
          [ -n "$tracked_profiles" ] || _profiles_tracked_v tracked_profiles
          case "$tracked_profiles" in
            *" $p "*) stale_why="a profile jig installed, with neither a verify.sh nor an extends, so its checks run nowhere; if jig upgrade kept your edited profile.yaml, the stock $p may now be a layer over another profile — carry your edits onto the new one, else run jig upgrade" ;;
          esac
        fi
      fi
      if [ -n "$stale_why" ]; then
        failn=$((failn + 1))
        if [ "$explain" = 1 ]; then
          printf 'PLAN %s: error (%s)\n' "$p" "$stale_why"
        else
          printf 'FAIL %s: %s\n' "$p" "$stale_why"
        fi
        continue
      fi
      if [ "$explain" = 1 ]; then
        printf 'PLAN %s: unknown (no verify.sh)\n' "$p"
        unknown=$((unknown + 1))
      else
        printf 'SKIP %s: no verify.sh\n' "$p"
        skip=$((skip + 1))
        # A missing verify.sh is a broken install, never scope narrowing: a
        # covered profile in this state always needs a person's action.
        [ "$is_fallback" = 1 ] || covered_needs_install=$((covered_needs_install + 1))
      fi
      continue
    fi

    if [ "$explain" = 1 ] && ! profiles_supports "$pdir" explain; then
      printf 'PLAN %s: unknown (profile does not support explain)\n' "$p"
      unknown=$((unknown + 1))
      continue
    fi

    # Under an environment, a profile that never declared it can reach it
    # would run its checks on the host: it is not run at all, and says so.
    if [ -n "$RUNENV_EXEC" ] && ! profiles_supports "$pdir" environment; then
      if [ "$explain" = 1 ]; then
        printf 'PLAN %s: unknown (not adapted to run in %s)\n' "$p" "$RUNENV_WHERE"
        unknown=$((unknown + 1))
      else
        printf 'RESULT %s: skip (not adapted to run in %s; its checks were not run on the host)\n' "$p" "$RUNENV_WHERE"
        skip=$((skip + 1))
        [ "$is_fallback" = 1 ] || covered_needs_install=$((covered_needs_install + 1))
      fi
      continue
    fi
    if [ -n "$RUNENV_EXEC" ]; then
      JIG_RUN_EXEC="$RUNENV_EXEC"
      export JIG_RUN_EXEC
    else
      unset JIG_RUN_EXEC
    fi
    # Set for a profile whose check another covers, cleared for every other:
    # a caller's own JIG_VERIFY_COVERED must never stand a check down.
    JIG_VERIFY_COVERED=$(_verify_covered_words "$covers" "$p")
    if [ -n "$JIG_VERIFY_COVERED" ]; then
      export JIG_VERIFY_COVERED
    else
      unset JIG_VERIFY_COVERED
    fi

    # The profile's check table (schemas/profile.md): linted here, once, and
    # handed down as a file of rows, so a typo is a failed profile rather than
    # an override that does nothing. Rows reach only a profile that has them —
    # the rows are the declaration, and `checks: [tests]` alone, as released
    # before the table, is not one; every other profile runs with the variable
    # unset, so a caller's own JIG_VERIFY_CHECKS never reaches one. A listed
    # role is a `<role> listed` row, so the library can tell a role with no
    # arguments from a role the profile.yaml does not know.
    rm -f "$JIG_VERIFY_CHECKS_TMP" 2>/dev/null || true
    JIG_VERIFY_CHECKS_TMP=""
    # A profile over a base may write the base's roles too; the layer lint above
    # has already judged those rows, so here they are only let through.
    base_roles=""
    if [ -n "$stack_edges" ]; then
      _profiles_base_roles_v base_roles "$p" "$installed_dir" "$stack_edges"
    fi
    if ! table_err=$(profiles_check_table "$pdir" "$base_roles"); then
      failn=$((failn + 1))
      if [ "$explain" = 1 ]; then
        printf 'PLAN %s: error (profile.yaml:%s)\n' "$p" "$table_err"
      else
        printf 'RESULT %s: fail (profile.yaml:%s)\n' "$p" "$table_err"
      fi
      continue
    fi
    profiles_check_overrides_v table_overrides "$pdir" "$stack_edges"
    table_rows=$(profiles_check_merged "$pdir" "$stack_edges")
    _verify_all_dropped_v p_dropped "$table_rows"
    if [ -n "$table_rows" ]; then
      JIG_VERIFY_CHECKS_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-verify-checks.XXXXXX") \
        || jig_die "verify: cannot create temporary file"
      printf '%s\n' "$table_rows" > "$JIG_VERIFY_CHECKS_TMP"
      JIG_VERIFY_CHECKS="$JIG_VERIFY_CHECKS_TMP"
      export JIG_VERIFY_CHECKS
    else
      unset JIG_VERIFY_CHECKS
    fi

    note=""
    scope_ok=0
    if [ "$scope" = 1 ]; then
      if profiles_supports "$pdir" changed; then
        scope_ok=1
        note=" (scope: changed, $nfiles files)"
      else
        note=" (scope ignored: profile declares no scope support, ran full set)"
      fi
    fi

    if [ "$scope_ok" = 1 ] && [ "$nfiles" -eq 0 ] && [ "$explain" = 0 ]; then
      skip=$((skip + 1))
      printf 'RESULT %s: skip (scope: changed, no changed files)\n' "$p"
      continue
    fi

    # The project map (ADR-0041): parsed here, once, so every profile reads
    # the same decisions. A broken map fails this profile without running it
    # — a line silently skipped would narrow the checks the wrong way.
    map_ok=0
    if [ "$scope_ok" = 1 ] && [ "$nfiles" -gt 0 ] && profiles_supports "$pdir" map; then
      # The maps of the pure layers whose tests this profile runs, topmost
      # first (warehouse.map before laravel.map), then the profile's own map,
      # then the map of every profile whose tests it covers, each behind the
      # maps of its own layers: the decisions follow the tests
      # (_verify_handed_maps, _verify_profile_maps_v), and with the nearest
      # lines first, first match wins across all of them.
      maps=""
      _verify_profile_maps_v maps "$installed_dir" "$p" "$stack_edges"
      # Nearest first.
      for b in $(_verify_handed_maps "$installed_dir" "$covers" "$p" | LC_ALL=C sort -n -k1,1 | cut -f2); do
        _verify_profile_maps_v pmaps "$installed_dir" "$b" "$stack_edges"
        [ -z "$pmaps" ] || maps="${maps:+$maps }$pmaps"
      done
      map_bad=0
      for map in $maps; do
        if ! map_err=$(_verify_map_check "$JIG_PROJECT/$map"); then
          failn=$((failn + 1))
          if [ "$explain" = 1 ]; then
            printf 'PLAN %s: error (map %s:%s)\n' "$p" "$map" "$map_err"
          else
            printf 'RESULT %s: fail (map %s:%s)\n' "$p" "$map" "$map_err"
          fi
          map_bad=1
          break
        fi
      done
      [ "$map_bad" = 0 ] || continue
      if [ -n "$maps" ]; then
        JIG_VERIFY_MAP_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-verify-map.XXXXXX") \
          || jig_die "verify: cannot create temporary file"
        # One file of rules, each map ended by a newline of its own so a map
        # without a final one cannot join its last rule to the next map's first.
        for map in $maps; do
          cat "$JIG_PROJECT/$map"
          printf '\n'
        done > "$JIG_VERIFY_MAP_TMP.src"
        _verify_map_apply "$JIG_VERIFY_MAP_TMP.src" "$JIG_VERIFY_TMP" > "$JIG_VERIFY_MAP_TMP"
        # The same decisions for every tracked file that could call a changed
        # function: a profile that narrows by caller needs the map's answer for
        # a path the change did not touch, and must not parse the map itself.
        JIG_VERIFY_MAP_ALL_TMP=$(mktemp "${TMPDIR:-/tmp}/jig-verify-mapall.XXXXXX") \
          || jig_die "verify: cannot create temporary file"
        { git -C "$JIG_PROJECT" ls-files -co --exclude-standard \
            | grep -v -e '^tests/' -e '^docs/' -e '\.mdx\{0,1\}$' || true; } \
          > "$JIG_VERIFY_MAP_ALL_TMP.list"
        _verify_map_apply "$JIG_VERIFY_MAP_TMP.src" "$JIG_VERIFY_MAP_ALL_TMP.list" \
          > "$JIG_VERIFY_MAP_ALL_TMP"
        rm -f "$JIG_VERIFY_MAP_ALL_TMP.list" "$JIG_VERIFY_MAP_TMP.src"
        map_ok=1
        _jig_replace_all_v maps_listed "$maps" ' ' ', '
        note=" (scope: changed, $nfiles files, map $maps_listed)"
      fi
    fi

    # Whose argument a check runs with: said before the base's own lines, in a
    # preview and in a run alike.
    [ -z "$table_overrides" ] || _verify_override_lines "$p" "$table_overrides" "$covers" "$stack_edges"

    # A profile without declared support is run with the scope variables
    # cleared, never merely unset by the caller's environment: an installed
    # verify.sh kept by `upgrade` as keep-modified must not read a scope it
    # was never written to honour.
    set +e
    # Run through `bash`, never exec the file directly: a profile committed
    # from Windows (or by any checkout that lost the executable bit, e.g.
    # `upgrade`'s keep-modified path copying a user file) has mode 100644,
    # and the result of a check must not depend on file mode.
    if [ "$explain" = 1 ]; then
      if [ "$map_ok" = 1 ]; then
        plan_output=$( cd "$JIG_PROJECT" \
          && JIG_VERIFY_EXPLAIN=1 JIG_VERIFY_SCOPE=changed JIG_VERIFY_FILES="$JIG_VERIFY_TMP" \
             JIG_VERIFY_BASE="$base" JIG_VERIFY_FULL_RUN="$full_run" \
             JIG_VERIFY_MAPPED="$JIG_VERIFY_MAP_TMP" JIG_VERIFY_MAPPED_ALL="$JIG_VERIFY_MAP_ALL_TMP" bash "$pdir/verify.sh" )
      elif [ "$scope_ok" = 1 ]; then
        plan_output=$( cd "$JIG_PROJECT" \
          && unset JIG_VERIFY_MAPPED JIG_VERIFY_MAPPED_ALL \
          && JIG_VERIFY_EXPLAIN=1 JIG_VERIFY_SCOPE=changed JIG_VERIFY_FILES="$JIG_VERIFY_TMP" \
             JIG_VERIFY_BASE="$base" JIG_VERIFY_FULL_RUN="$full_run" \
             bash "$pdir/verify.sh" )
      else
        plan_output=$( cd "$JIG_PROJECT" \
          && unset JIG_VERIFY_SCOPE JIG_VERIFY_FILES JIG_VERIFY_MAPPED JIG_VERIFY_MAPPED_ALL JIG_VERIFY_BASE JIG_VERIFY_FULL_RUN \
          && JIG_VERIFY_EXPLAIN=1 bash "$pdir/verify.sh" )
      fi
      rc=$?
    elif [ "$map_ok" = 1 ]; then
      run_output=$( cd "$JIG_PROJECT" \
        && unset JIG_VERIFY_EXPLAIN \
        && JIG_VERIFY_SCOPE=changed JIG_VERIFY_FILES="$JIG_VERIFY_TMP" \
             JIG_VERIFY_BASE="$base" JIG_VERIFY_FULL_RUN="$full_run" \
           JIG_VERIFY_MAPPED="$JIG_VERIFY_MAP_TMP" JIG_VERIFY_MAPPED_ALL="$JIG_VERIFY_MAP_ALL_TMP" \
           bash "$pdir/verify.sh" 2>&1 )
      rc=$?
      [ -z "$run_output" ] || printf '%s\n' "$run_output"
    elif [ "$scope_ok" = 1 ]; then
      run_output=$( cd "$JIG_PROJECT" \
        && unset JIG_VERIFY_EXPLAIN JIG_VERIFY_MAPPED JIG_VERIFY_MAPPED_ALL \
        && JIG_VERIFY_SCOPE=changed JIG_VERIFY_FILES="$JIG_VERIFY_TMP" \
             JIG_VERIFY_BASE="$base" JIG_VERIFY_FULL_RUN="$full_run" \
           bash "$pdir/verify.sh" 2>&1 )
      rc=$?
      [ -z "$run_output" ] || printf '%s\n' "$run_output"
    else
      # Never scope-aware (no --changed, or the profile declares no scope
      # support): a skip here cannot be scope narrowing, so there is nothing
      # to classify and the run streams live like every branch did before
      # this change — run_output stays empty, which _verify_skip_lines_all_scoped
      # reads as "not narrowed", the same answer this branch always gave.
      run_output=""
      ( cd "$JIG_PROJECT" \
        && unset JIG_VERIFY_EXPLAIN JIG_VERIFY_SCOPE JIG_VERIFY_FILES JIG_VERIFY_MAPPED JIG_VERIFY_MAPPED_ALL JIG_VERIFY_BASE JIG_VERIFY_FULL_RUN \
        && bash "$pdir/verify.sh" )
      rc=$?
    fi
    set -e
    if [ "$map_ok" = 1 ]; then
      rm -f "$JIG_VERIFY_MAP_TMP" "$JIG_VERIFY_MAP_ALL_TMP"
      JIG_VERIFY_MAP_TMP=""
      JIG_VERIFY_MAP_ALL_TMP=""
    fi

    if [ "$explain" = 1 ]; then
      plan_bad=$(printf '%s\n' "$plan_output" \
        | grep -vE "^PLAN $p: .+: (full|filtered|skip|conditional) \\(.+\\)$") || plan_bad=""
      if [ "$rc" -ne 0 ] || [ -z "$plan_output" ] || [ -n "$plan_bad" ]; then
        printf 'PLAN %s: error (profile explain contract failed)\n' "$p"
        failn=$((failn + 1))
      else
        printf '%s\n' "$plan_output"
        explained=$((explained + 1))
      fi
      continue
    fi

    # A check whose full set a narrowed run left to CI (verify.full_run: ci,
    # adr-0041 amendment 2026-10-08) is counted, so the summary can say the
    # full set ran nowhere here and how to run it.
    ci_left=$((ci_left + $(_verify_count_left_to_ci "$run_output")))

    # A run that died is neither a pass nor a fail. Exit code 3 is a profile
    # saying so; 128+N is the profile itself killed by a signal, which no
    # profile has to be taught — `Killed: 9` and `Terminated: 15` reach every
    # stack the same way.
    case "$rc" in
      0) pass=$((pass + 1)); printf 'RESULT %s: pass%s\n' "$p" "$note" ;;
      2)
        skip=$((skip + 1))
        # A profile that skipped every check of its own either had nothing in
        # scope (every "<check>: skip (…)" line names a scope reason, ADR-0013's
        # own wording) or hit a real gap (a missing tool, a broken check) — and
        # only the second is a person's to fix. Absence of any skip line at all
        # is read as the cautious default, same as an undeclared capability.
        # The count is what it always was; a profile whose every check a layer
        # dropped is also remembered (known from the table, never from the
        # profile's output), so the summary can say what happened (see below). A streamed
        # `--full` run leaves no output to read, and counts as a gap.
        if [ "$is_fallback" != 1 ] && ! _verify_skip_lines_all_scoped "$run_output"; then
          covered_needs_install=$((covered_needs_install + 1))
          [ -z "$p_dropped" ] || dropped_needs=$((dropped_needs + 1))
        fi
        if [ -n "$p_dropped" ]; then
          dropped_msg="${dropped_msg:+$dropped_msg; }every check of $p was dropped by $p_dropped"
        fi
        printf 'RESULT %s: skip%s\n' "$p" "$note"
        ;;
      3)
        incomplete=$((incomplete + 1))
        printf 'RESULT %s: incomplete%s\n' "$p" "$note"
        ;;
      *)
        if [ "$rc" -ge 128 ]; then
          incomplete=$((incomplete + 1))
          printf 'RESULT %s: incomplete (killed by signal %d)%s\n' "$p" "$((rc - 128))" "$note"
        else
          failn=$((failn + 1))
          printf 'RESULT %s: fail%s\n' "$p" "$note"
        fi
        ;;
    esac
  done

  if [ "$explain" = 1 ]; then
    printf 'verify: %d profiles explained, %d unknown, %d error; no checks ran\n' \
      "$explained" "$unknown" "$failn"
    if [ "$failn" -gt 0 ] || [ "$total" -eq 0 ]; then return 1; fi
    if [ "$unknown" -gt 0 ]; then return 2; fi
    return 0
  fi

  printf 'verify: %d profiles, %d pass, %d fail, %d skip, %d incomplete\n' \
    "$total" "$pass" "$failn" "$skip" "$incomplete"
  if [ "$ci_left" -gt 0 ]; then
    printf 'verify: %d check(s) left their full set to CI (verify.full_run: ci); jig verify --full runs it here\n' \
      "$ci_left"
  fi
  # A layer that dropped every check of its base is said on every run where it
  # is true, whatever else passed or failed (the exit code is not changed by
  # it). The one run that says it inside another sentence — the nothing-checked
  # ending below, which names the dropped checks instead of "install" — does
  # not say it twice.
  if [ -n "$dropped_msg" ] && ! { [ "$incomplete" -eq 0 ] && [ "$pass" -eq 0 ] \
       && [ "$failn" -eq 0 ] && [ "$total" -gt 0 ] && [ "$covered" = 1 ] \
       && [ "$covered_needs_install" -gt 0 ] \
       && [ "$covered_needs_install" -eq "$dropped_needs" ]; }; then
    printf 'verify: %s; nothing verified it\n' "$dropped_msg"
  fi
  # Incomplete outranks fail: a run something was killed in is not evidence, so
  # the failures in it cannot be trusted either. Nothing is lost — a real
  # failure comes back on the next run, and an artefact of an overloaded
  # machine does not. Exit 3 means "run it again", never "it is broken".
  if [ "$incomplete" -gt 0 ]; then
    printf 'verify: the run did not finish, so it neither passed nor failed — run it again\n'
    return 3
  fi
  # A run in which nothing passed and nothing failed checked nothing, and the
  # exit code has to say so. `[ "$failn" -eq 0 ]` alone answered 0 for a set of
  # pure skips: on a project with no shellcheck and no test runner, `jig verify`
  # reported success having examined not one line of it, and `jig task ship` and
  # the autopilot read that code.
  #
  # But "nothing was checked" is three states, and only one of them is
  # anybody's fault. **The difference is whether there was anything to check,
  # and whether the change at hand was the reason it went unchecked.**
  #
  #   - A profile covering this stack took part and every check skipped for a
  #     reason of its own (a missing tool, a broken verify.sh): the stack was
  #     recognised and there was something to check that was not, for a reason
  #     somebody can fix. That is the blind pass this rule exists to stop, and
  #     it is refused — exit 3, sharing the code with the killed run because
  #     both mean no verdict was produced.
  #   - Only fallback profiles took part: no profile covers this project at
  #     all. There is nothing to install and nothing to wait for, so refusing
  #     would stop work over a state the person cannot resolve.
  #   - Every skip came from scope narrowing: a profile covers this stack and
  #     its tools are fine, but this diff does not touch anything within its
  #     scope — either `jig verify` narrowed it to no changed files at all
  #     before the profile ever ran, or the profile ran and every check of its
  #     own said so (ADR-0013's own wording: every "<check>: skip (…)" line
  #     names a scope reason). A docs-only change beside a `shell` profile is
  #     exactly this. Nothing here is broken and nothing needs installing; the
  #     narrowing did exactly what it was asked to. Refusing would repeat the
  #     wrong advice this rule exists to stop, just from a different cause.
  #
  # The last two states share their answer — there is no action for the
  # person to take, so this does not refuse — but not their text, since only
  # the first names a stack this project actually has. `covered_needs_install`
  # counts covered profiles whose skip does NOT reduce to scope narrowing:
  # zero of those, and the state is the third one above, not the first.
  if [ "$pass" -eq 0 ] && [ "$failn" -eq 0 ] && [ "$total" -gt 0 ]; then
    # Only the dropped checks kept the run from a verdict: say so, not "install".
    if [ "$covered" = 1 ] && [ "$covered_needs_install" -gt 0 ] \
       && [ "$covered_needs_install" -eq "$dropped_needs" ]; then
      printf 'verify: nothing was checked, so this is not a pass — %s; nothing verified it\n' "$dropped_msg"
      return 3
    fi
    if [ "$covered" = 1 ] && [ "$covered_needs_install" -gt 0 ]; then
      printf 'verify: nothing was checked, so this is not a pass — install the project'"'"'s tools so its profile can run\n'
      return 3
    fi
    if [ "$covered" = 1 ] && [ "$ci_left" -gt 0 ]; then
      printf 'verify: every check in scope skipped or left its full set to CI, so this run verified nothing here\n'
      return 0
    fi
    if [ "$covered" = 1 ]; then
      printf 'verify: every check in scope skipped — this change touches nothing any profile covers, so this run verified nothing\n'
      return 0
    fi
    printf 'verify: nothing here checks this project — no profile covers it, so this run verified nothing\n'
    return 0
  fi
  [ "$failn" -eq 0 ]
}
