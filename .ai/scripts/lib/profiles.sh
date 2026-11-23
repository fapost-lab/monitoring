# Profile discovery, activation, detection and the requires closure
# (domains/verify). Sourced by scripts/lib/verify.sh; scripts/lib/init.sh also
# sources it directly to compute the profile suggestion at init time.
# Depends on scripts/lib/common.sh (JIG_AI_DIR, jig_source_root, jig_warn)
# and scripts/lib/config.sh (cfg_list), both already sourced by the
# dispatcher before any command library.
# bash 3.2 compatible: no associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

# --- profile.yaml reader -----------------------------------------------------

# profile_get <profile-dir> <key> — scalar value of <key> in
# <profile-dir>/profile.yaml. Same flat-YAML shape as .ai/config.yaml, but a
# plain file, not a frontmatter block, so it is read directly rather than
# through `cfg` (bound to .ai/config.yaml) or `fm_get` (bound to a
# frontmatter block). Prints the raw value, including a literal `[...]` for
# list keys — see _profiles_list_lines to read those. Prints nothing when
# the file or the key is absent.
profile_get() {
  local __pgp_value
  profile_get_v __pgp_value "$1" "$2" || return 0
  printf '%s\n' "$__pgp_value"
}

# profile_get_v <var> <profile-dir> <key> — profile_get's value into <var>;
# exit 1, with <var> empty, when there is no profile.yaml. Builtins only:
# `init` and `verify` ask several keys of every profile (convention-shell,
# `<name>_v`). The first line that sets <key> answers; its value ends at a `#`
# and carries no trailing whitespace.
profile_get_v() {
  local __pg_line __pg_re="^${3}:[[:space:]]*"
  printf -v "$1" '%s' ""
  [ -f "$2/profile.yaml" ] || return 1
  while IFS= read -r __pg_line || [ -n "$__pg_line" ]; do
    [[ $__pg_line =~ $__pg_re ]] || continue
    __pg_line=${__pg_line#"${BASH_REMATCH[0]}"}
    __pg_line=${__pg_line%%#*}
    __pg_line=${__pg_line%"${__pg_line##*[![:space:]]}"}
    printf -v "$1" '%s' "$__pg_line"
    return 0
  done < "$2/profile.yaml"
  return 0
}

# _profiles_list_lines <profile-dir> <key> — items of an inline list
# `key: [a, b]`, one per line, quotes stripped. Prints nothing for a scalar
# value (e.g. generic's `detect: always`) or an absent key.
#
# One-per-line output is deliberate: every caller consumes it with
# `while read`, never a bareword `for` loop — an unquoted `for x in $list`
# would let bash apply pathname expansion to glob-shaped items such as
# `scripts/**/*.sh` against the real tree, silently replacing the literal
# pattern with whatever files happen to match (or nothing at all).
_profiles_list_lines() {
  local raw item
  profile_get_v raw "$1" "$2" || return 0
  case "$raw" in
    \[*\]) ;;
    *) return 0 ;;
  esac
  raw=${raw#\[}
  raw=${raw%\]}
  # Each item between commas: trimmed, one pair of surrounding quotes off,
  # and dropped when nothing is left.
  while :; do
    item=${raw%%,*}
    item=${item#"${item%%[![:space:]]*}"}
    item=${item%"${item##*[![:space:]]}"}
    case "$item" in
      \"*\")
        item=${item#\"}
        item=${item%\"}
        ;;
    esac
    [ -z "$item" ] || printf '%s\n' "$item"
    case "$raw" in
      *,*) raw=${raw#*,} ;;
      *) break ;;
    esac
  done
}

# _profiles_dedup <words> — space-separated words, first-occurrence order
# kept, duplicates dropped.
_profiles_dedup() {
  local w result=""
  for w in $1; do
    case " $result " in
      *" $w "*) ;;
      *) result="$result $w" ;;
    esac
  done
  printf '%s\n' "${result# }"
}

# profiles_is_fallback <profile-dir> — true when the profile declares that it
# claims nothing about the code: `verifies: nothing` in its profile.yaml.
#
# **Declared, never inferred, and in particular never read off `detect`.**
# `detect` answers when a profile *applies*; this answers what it *asserts*.
# They coincide in `generic` and nowhere else by necessity: a secret scanner or
# a licence-header check is exactly the kind of profile that should apply
# everywhere and does make a claim about the code. Reading `detect: always` as
# "claims nothing" would put such a profile in the wrong bucket, and the day its
# tool was missing it would report that nothing checks the project and ship
# unverified — the very inversion this distinction exists to prevent.
#
# Absence means the profile verifies something, which is the cautious default:
# a profile written before this field existed keeps refusing when its checks all
# skip, rather than quietly becoming unverifiable
# (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass).
profiles_is_fallback() {
  local __pif_value
  profile_get_v __pif_value "$1" verifies || return 1
  [ "$__pif_value" = "nothing" ]
}

# profiles_supports <profile-dir> <capability> — true when the profile's
# profile.yaml lists <capability> under `scope`. Support is declared, never
# inferred: profiles are copied into projects (ADR-0003) and `upgrade` keeps
# user-modified copies, so a caller meets scripts written before a capability
# existed. Absence is the answer for all of them.
profiles_supports() {
  local item
  while IFS= read -r item; do
    [ "$item" = "$2" ] && return 0
  done < <(_profiles_list_lines "$1" scope)
  return 1
}

# profiles_names_check <profile-dir> <check> — true when the profile lists
# <check> under `checks`: its verify.sh answers to that role name through
# jp_covered, so a profile declaring `covers: [<name>:<check>]` can take the
# check over. Declared like `scope`, never inferred: a verify.sh written
# before the key existed does not stand its check down, and absence says so.
profiles_names_check() {
  local item
  while IFS= read -r item; do
    [ "$item" = "$2" ] && return 0
  done < <(_profiles_list_lines "$1" checks)
  return 1
}

# --- the check table ---------------------------------------------------------
#
# `checks.<role>.<field>: <value>` lines of profile.yaml declare a check's
# command and arguments as data (schemas/profile.md, **Check table**;
# adr-20261117-a-profile-declares-its-checks-in-a-table). The flat reader
# cannot enumerate keys, so the roles are the existing `checks: [..]` list and
# the table is read line by line here, never through profile_get.

# _profiles_check_err <line> <reason> — `<line>: <reason>` on stdout, exit 1.
_profiles_check_err() {
  printf '%d: %s\n' "$1" "$2"
  return 1
}

# profiles_check_table <profile-dir> — lint the check table of
# <profile-dir>/profile.yaml. Prints `<line>: <reason>` for the first bad line
# and exits 1; exits 0 when the table is fine, and for a profile with no table
# at all (`checks: [tests]` alone is what the releases before the table wrote).
# The reader ignores an unknown key in silence, so without this a typo is an
# override that does nothing; `jig verify` runs it and fails the profile.
#
# Checked: a role that `checks:` does not list, a role outside `[a-z0-9_-]`, an
# unknown field, a key set twice (the reader would take the first and drop the
# rest), an indented `checks.` key (invisible to the reader), a character the
# word grammar forbids (`"` `'` `$` backtick backslash), an empty value (`[]` is
# the explicit empty), `command: []`, and `{selection}` — exactly once, as a
# whole word, in `narrowed` and nowhere else.
#
# A layer's table (adr-20261118-a-layer-overrides-its-bases-checks-by-role)
# passes <base-roles>, space-separated: the roles of its bases it may write
# beside its own. Only for those is `drop` a field, and its value is exactly
# `true`, alone in its role; <note> names the chain in the error for a role
# nobody in it lists. Without <base-roles> `drop` is refused: a profile with no
# base has no check to remove.
profiles_check_table() {
  local file="$1/profile.yaml" line n=0 key after role field value roles
  local seen="" sub whole tmp w baser=$'\n' isbase dropped=$'\n' touched=$'\n'
  local note="${3:-}"
  local -a ws br
  local indented_re='^[[:space:]]+checks\.' role_re='^[a-z0-9_-]+$'
  local tok='{selection}'
  [ -f "$file" ] || return 0
  roles=$'\n'"$(_profiles_list_lines "$1" checks)"$'\n'
  IFS=$' \t' read -r -a br <<EOF
${2:-}
EOF
  for w in ${br[@]+"${br[@]}"}; do baser="$baser$w"$'\n'; done
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if [[ $line =~ $indented_re ]]; then
      _profiles_check_err "$n" "an indented checks.* key is invisible to the reader; write it at column 0" || return 1
    fi
    case $line in
      checks.*) ;;
      *) continue ;;
    esac
    key=${line%%:*}
    [ "$key" != "$line" ] || _profiles_check_err "$n" "no ':' after the key" || return 1
    after=${key#checks.}
    case $after in
      *.*) ;;
      *) _profiles_check_err "$n" "the key must be checks.<role>.<field>" || return 1 ;;
    esac
    role=${after%%.*}
    field=${after#*.}
    [[ $role =~ $role_re ]] \
      || _profiles_check_err "$n" "role '$role' must be lowercase letters, digits, '_' and '-'" || return 1
    case $field in
      command|full|narrowed|drop) ;;
      *) _profiles_check_err "$n" "unknown field '$field' (command, full, narrowed)" || return 1 ;;
    esac
    isbase=0
    case $baser in
      *$'\n'"$role"$'\n'*) isbase=1 ;;
    esac
    case $roles in
      *$'\n'"$role"$'\n'*) ;;
      *)
        if [ "$isbase" = 0 ] && [ -n "$note" ]; then
          _profiles_check_err "$n" "role '$role' is in no checks: of $note" || return 1
        elif [ "$isbase" = 0 ]; then
          _profiles_check_err "$n" "role '$role' is not listed in checks:" || return 1
        fi
        ;;
    esac
    if [ "$field" = drop ] && [ "$isbase" = 0 ]; then
      _profiles_check_err "$n" "field 'drop' removes the check of a base; role '$role' is not one of a base's" || return 1
    fi
    case $seen in
      *$'\n'"$role.$field"$'\n'*) _profiles_check_err "$n" "checks.$role.$field is set twice" || return 1 ;;
    esac
    seen="$seen"$'\n'"$role.$field"$'\n'
    case $dropped in
      *$'\n'"$role"$'\n'*)
        _profiles_check_err "$n" "checks.$role.drop cannot be combined with another field of $role" || return 1 ;;
    esac
    value=${line#*:}
    value=${value%%#*}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [ "$field" = drop ]; then
      [ "$value" = true ] || _profiles_check_err "$n" "drop must be exactly true" || return 1
      case $touched in
        *$'\n'"$role"$'\n'*)
          _profiles_check_err "$n" "checks.$role.drop cannot be combined with another field of $role" || return 1 ;;
      esac
      dropped="$dropped$role"$'\n'
      continue
    fi
    touched="$touched$role"$'\n'
    case $value in
      *\"*|*\'*|*\$*|*\`*|*\\*)
        _profiles_check_err "$n" "a value cannot contain quotes, \$, backtick or backslash" || return 1 ;;
    esac
    [ -n "$value" ] || _profiles_check_err "$n" "empty value; write [] for no words" || return 1
    if [ "$value" = "[]" ]; then
      [ "$field" != command ] || _profiles_check_err "$n" "command cannot be []" || return 1
    else
      case $value in
        \[*\]) _profiles_check_err "$n" "inline lists are not supported; write plain words separated by blanks" || return 1 ;;
      esac
    fi
    # {selection}: occurrences anywhere, and occurrences that are a whole word.
    sub=0
    tmp=$value
    while [[ $tmp == *"$tok"* ]]; do
      sub=$((sub + 1))
      tmp=${tmp#*"$tok"}
    done
    whole=0
    IFS=$' \t' read -r -a ws <<EOF
$value
EOF
    for w in ${ws[@]+"${ws[@]}"}; do
      [ "$w" != "$tok" ] || whole=$((whole + 1))
    done
    if [ "$field" = narrowed ]; then
      [ "$sub" -ge 1 ] || _profiles_check_err "$n" "narrowed needs exactly one $tok, found none" || return 1
      [ "$sub" -le 1 ] || _profiles_check_err "$n" "narrowed has more than one $tok" || return 1
      [ "$whole" -eq 1 ] || _profiles_check_err "$n" "$tok must be a whole word, not part of one" || return 1
    else
      [ "$sub" -eq 0 ] || _profiles_check_err "$n" "$tok is only for narrowed, not $field" || return 1
    fi
  done < "$file"
  return 0
}

# profiles_check_rows <profile-dir> [--lines] — the check table as `<role><TAB>
# <field><TAB><value>` lines, the value as written (comment and outer blanks
# off, `[]` kept), in file order; with --lines each is led by its line number
# in profile.yaml and a tab. Prints nothing for a profile without a table. Call
# profiles_check_table first: a line it would refuse is not filtered here.
profiles_check_rows() {
  local file="$1/profile.yaml" line after role field value n=0 lead=0
  local row_re='^checks\.([a-z0-9_-]+)\.([a-z]+):'
  [ "${2:-}" != --lines ] || lead=1
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ $line =~ $row_re ]] || continue
    role=${BASH_REMATCH[1]}
    field=${BASH_REMATCH[2]}
    value=${line#"${BASH_REMATCH[0]}"}
    value=${value%%#*}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    [ "$lead" = 0 ] || printf '%s\t' "$n"
    printf '%s\t%s\t%s\n' "$role" "$field" "$value"
  done < "$file"
}

# --- layers over a check table -------------------------------------------------
# A layer writes `checks.<role>.<field>` lines for the checks of its bases; the
# role belongs to the first profile of the layer's chain (itself, then the
# bases by `extends`) that lists it in `checks:`
# (adr-20261118-a-layer-overrides-its-bases-checks-by-role). A profile with no
# verify.sh and an `extends` is a pure layer: it runs nothing, so it owns no role.
# <edges> are `<layer><TAB><base>` lines, profiles_stack_v --edges: the layers
# of the run, never a layer the run does not contain.

# _profiles_is_pure <profile-dir> — true for a profile with an `extends` and no
# verify.sh of its own.
_profiles_is_pure() {
  local __pi_ext
  [ -f "$1/profile.yaml" ] && [ ! -f "$1/verify.sh" ] || return 1
  profile_get_v __pi_ext "$1" extends || return 1
  [ -n "$__pi_ext" ]
}

# _profiles_roles_v <var> <profile-dir> — the roles of `checks:`, each between
# newlines (`\nlint\ntests\n`), for a `case` match; `\n` alone for none.
_profiles_roles_v() {
  local __pr_item __pr_out=$'\n'
  while IFS= read -r __pr_item; do
    [ -z "$__pr_item" ] || __pr_out="$__pr_out$__pr_item"$'\n'
  done < <(_profiles_list_lines "$2" checks)
  printf -v "$1" '%s' "$__pr_out"
}

# _profiles_chain_v <var> <name> <edges> — <name>, then the base it extends, then
# that one's base: space-separated.
_profiles_chain_v() {
  local __pc_cur="$2" __pc_out="$2" __pc_l __pc_b __pc_next
  while :; do
    __pc_next=""
    while IFS=$'\t' read -r __pc_l __pc_b; do
      if [ "$__pc_l" = "$__pc_cur" ]; then __pc_next=$__pc_b; break; fi
    done <<EOF
$3
EOF
    [ -n "$__pc_next" ] || break
    __pc_out="$__pc_out $__pc_next"
    __pc_cur=$__pc_next
  done
  printf -v "$1" '%s' "$__pc_out"
}

# _profiles_role_owner_v <var> <role> <chain> <root> — the first profile of
# <chain> (under <root>) that is not a pure layer and lists <role>; empty when
# nobody does.
_profiles_role_owner_v() {
  local __po_n __po_roles
  printf -v "$1" '%s' ""
  for __po_n in $3; do
    [ -d "$4/$__po_n" ] || continue
    ! _profiles_is_pure "$4/$__po_n" || continue
    _profiles_roles_v __po_roles "$4/$__po_n"
    case $__po_roles in
      *$'\n'"$2"$'\n'*) printf -v "$1" '%s' "$__po_n"; return 0 ;;
    esac
  done
  return 0
}

# profiles_layer_maps_v <var> <root> <name> <edges> — the pure layers of <edges>
# whose `tests` run in <name>: a layer whose chain finds <name> as the owner of
# the role `tests`, space-separated, topmost layer first (the order of <edges>).
# A pure layer has no verify.sh and reads no map of its own, so its project map
# `.ai/verify/<layer>.map` follows the tests to whoever runs them
# (schemas/verify-map.md). Empty when there is none.
profiles_layer_maps_v() {
  local __pl_l __pl_b __pl_chain __pl_owner __pl_out=""
  printf -v "$1" '%s' ""
  [ -n "$4" ] || return 0
  while IFS=$'\t' read -r __pl_l __pl_b; do
    [ -n "$__pl_l" ] || continue
    [ -d "$2/$__pl_l" ] || continue
    _profiles_is_pure "$2/$__pl_l" || continue
    case " $__pl_out " in *" $__pl_l "*) continue ;; esac
    _profiles_chain_v __pl_chain "$__pl_l" "$4"
    _profiles_role_owner_v __pl_owner tests "$__pl_chain" "$2"
    [ "$__pl_owner" = "$3" ] || continue
    __pl_out="${__pl_out:+$__pl_out }$__pl_l"
  done <<EOF
$4
EOF
  printf -v "$1" '%s' "$__pl_out"
}

# _profiles_base_roles_v <var> <name> <root> <edges> — the role words the bases
# in <name>'s chain list and <name> itself does not: what a layer may write
# beside its own roles.
_profiles_base_roles_v() {
  local __pb_chain __pb_bases __pb_n __pb_r __pb_own=$'\n' __pb_theirs __pb_out=""
  _profiles_chain_v __pb_chain "$2" "$4"
  case $__pb_chain in
    *" "*) __pb_bases=${__pb_chain#* } ;;
    *) __pb_bases="" ;;
  esac
  if [ -d "$3/$2" ] && ! _profiles_is_pure "$3/$2"; then
    _profiles_roles_v __pb_own "$3/$2"
  fi
  for __pb_n in $__pb_bases; do
    [ -d "$3/$__pb_n" ] || continue
    ! _profiles_is_pure "$3/$__pb_n" || continue
    _profiles_roles_v __pb_theirs "$3/$__pb_n"
    while IFS= read -r __pb_r; do
      [ -n "$__pb_r" ] || continue
      case $__pb_own in *$'\n'"$__pb_r"$'\n'*) continue ;; esac
      case " $__pb_out " in *" $__pb_r "*) continue ;; esac
      __pb_out="${__pb_out:+$__pb_out }$__pb_r"
    done <<EOF
$__pb_theirs
EOF
  done
  printf -v "$1" '%s' "$__pb_out"
}

# _profiles_key_line_v <var> <profile-dir> <key> — the line number of `<key>:`
# in profile.yaml (0 when there is none).
_profiles_key_line_v() {
  local __pk_line __pk_n=0
  printf -v "$1" '%s' 0
  [ -f "$2/profile.yaml" ] || return 0
  while IFS= read -r __pk_line || [ -n "$__pk_line" ]; do
    __pk_n=$((__pk_n + 1))
    case $__pk_line in
      "$3:"*) printf -v "$1" '%s' "$__pk_n"; return 0 ;;
    esac
  done < "$2/profile.yaml"
  return 0
}

# _profiles_check_layer <root> <edges> <name> <claims-var> — the lint of one
# layer for profiles_check_layers: one `<name><TAB><line><TAB><reason>` line for
# its first problem, exit 1; exit 0 when it is fine. <claims-var> names the
# variable of `<base>:<role><TAB><layer>` lines of the layers checked so far;
# a layer that passes adds its own.
_profiles_check_layer() {
  local root="$1" edges="$2" name="$3" cv="$4" dir="$1/$3" chain bases baseroles
  local err n role field value owner brows key claimed=" " other lyr ochain row
  local haverows
  _profiles_chain_v chain "$name" "$edges"
  case $chain in
    *" "*) bases=${chain#* } ;;
    *) bases="" ;;
  esac
  _jig_replace_all_v bases "$bases" ' ' ', '
  if _profiles_is_pure "$dir"; then
    _profiles_roles_v owner "$dir"
    if [ "$owner" != $'\n' ]; then
      _profiles_key_line_v n "$dir" checks
      printf '%s\t%s\t%s\n' "$name" "$n" "a layer with no verify.sh runs no check of its own, so checks: must be empty; its checks.<role>.* rows name roles of its bases"
      return 1
    fi
  fi
  _profiles_base_roles_v baseroles "$name" "$root" "$edges"
  if ! err=$(profiles_check_table "$dir" "$baseroles" "$name's chain ($bases)"); then
    printf '%s\t%s\t%s\n' "$name" "${err%%: *}" "${err#*: }"
    return 1
  fi
  while IFS=$'\t' read -r n role field value; do
    [ -n "$n" ] || continue
    _profiles_role_owner_v owner "$role" "$chain" "$root"
    [ -n "$owner" ] && [ "$owner" != "$name" ] || continue
    brows=$(profiles_check_rows "$root/$owner")
    if [ -z "$brows" ]; then
      printf '%s\t%s\t%s\n' "$name" "$n" "$owner declares no check table; an override of $owner:$role would not be read"
      return 1
    fi
    # A layer between this one and the owner that dropped the role: whatever is
    # written here would never be read.
    for lyr in ${chain#"$name"}; do
      [ "$lyr" != "$owner" ] || break
      while IFS=$'\t' read -r row other _; do
        if [ "$row" = "$role" ] && [ "$other" = drop ]; then
          printf '%s\t%s\t%s\n' "$name" "$n" "$owner:$role is dropped by $lyr; an override here would never be read"
          return 1
        fi
      done < <(profiles_check_rows "$root/$lyr")
    done
    if [ "$field" = narrowed ]; then
      haverows=0
      while IFS=$'\t' read -r row other _; do
        if [ "$row" = "$role" ] && [ "$other" = narrowed ]; then haverows=1; break; fi
      done <<EOF
$brows
EOF
      if [ "$haverows" = 0 ]; then
        printf '%s\t%s\t%s\n' "$name" "$n" "$owner:$role does not narrow; a narrowed override would never be read"
        return 1
      fi
    fi
    key="$owner:$role"
    case $claimed in *" $key "*) continue ;; esac
    claimed="$claimed$key "
    while IFS=$'\t' read -r other lyr; do
      [ "$other" = "$key" ] || continue
      _profiles_chain_v ochain "$lyr" "$edges"
      case " $ochain " in *" $name "*) continue ;; esac
      case " $chain " in *" $lyr "*) continue ;; esac
      printf '%s\t%s\t%s\n' "$name" "$n" "$lyr and $name both override $key; $owner runs once, so one of them would be ignored"
      return 1
    done <<EOF
${!cv}
EOF
  done < <(profiles_check_rows "$dir" --lines)
  for key in $claimed; do
    printf -v "$cv" '%s' "${!cv}${!cv:+$'\n'}$key"$'\t'"$name"
  done
  return 0
}

# profiles_check_layers <root> <edges> [<name>...] — lint the check table of every
# profile among <name>... (the run's stack, in run order) that has an `extends`,
# before any profile runs (adr-20261118-a-layer-overrides-its-bases-checks-by-role).
# Prints `<layer><TAB><line><TAB><reason>` for the first problem of each layer
# and exits 1; prints nothing and exits 0 when every layer is fine.
#
# Checked: profiles_check_table's grammar, over the roles of the layer and its
# chain; a role in no `checks:` of the chain; an override of a base that has no
# check table (its verify.sh would not read it) and a `narrowed` for a check the
# base never narrows; a role a layer below already dropped (so a field or a
# second drop would never be read); a non-empty `checks:` on a pure layer, whose role would
# hide the base's; and two layers on different branches over one base changing
# the same role, which would leave one of them ignored in silence.
profiles_check_layers() {
  # shellcheck disable=SC2034 # claims is read and set by name in _profiles_check_layer
  local root="$1" edges="$2" name ext failed=0 claims=""
  shift 2
  for name in "$@"; do
    profile_get_v ext "$root/$name" extends || continue
    [ -n "$ext" ] || continue
    _profiles_check_layer "$root" "$edges" "$name" claims || failed=1
  done
  [ "$failed" = 0 ]
}

# _profiles_tab_find_v <var> <table> <role> <field> [<layer-var>] — the value of
# the line `<role><TAB><field><TAB><value>[<TAB><layer>]` of <table> into <var>
# (and the layer into <layer-var>); exit 1 when there is none.
_profiles_tab_find_v() {
  local __pf_r __pf_f __pf_v __pf_l
  printf -v "$1" '%s' ""
  [ -z "${5:-}" ] || printf -v "$5" '%s' ""
  while IFS=$'\t' read -r __pf_r __pf_f __pf_v __pf_l; do
    if [ "$__pf_r" = "$3" ] && [ "$__pf_f" = "$4" ]; then
      printf -v "$1" '%s' "$__pf_v"
      [ -z "${5:-}" ] || printf -v "$5" '%s' "$__pf_l"
      return 0
    fi
  done <<EOF
$2
EOF
  return 1
}

# profiles_check_overrides_v <var> <profile-dir> <edges> — what the layers above
# <profile-dir> in the run change of its check table, into <var>, one
# `<role><TAB><field><TAB><value><TAB><layer>` line each. The layers come nearest
# first and each of their rows for a role this profile owns (the first profile of
# the layer's chain that lists it) replaces the same field of the layers below,
# so the top layer wins field by field. A `drop` stands whatever a layer writes
# beside it or above it: the role keeps only that line, value `true`, <layer> the
# topmost layer that dropped it. Empty when no layer in <edges> reaches it.
profiles_check_overrides_v() {
  local __po_dir="$2" __po_root __po_name __po_edges="$3" __po_frontier __po_above=""
  local __po_next __po_l __po_b __po_acc="" __po_new __po_chain __po_owner
  local __po_r __po_f __po_v __po_x __po_lyr __po_drops=" " __po_cf __po_cv __po_cl
  __po_root=${__po_dir%/*}
  __po_name=${__po_dir##*/}
  printf -v "$1" '%s' ""
  [ -n "$__po_edges" ] || return 0
  __po_frontier=" $__po_name "
  while :; do
    __po_next=""
    while IFS=$'\t' read -r __po_l __po_b; do
      [ -n "$__po_l" ] || continue
      case $__po_frontier in
        *" $__po_b "*) __po_next="$__po_next $__po_l" ;;
      esac
    done <<EOF
$__po_edges
EOF
    [ -n "$__po_next" ] || break
    __po_above="$__po_above$__po_next"
    __po_frontier="$__po_next "
  done
  for __po_lyr in $__po_above; do
    _profiles_chain_v __po_chain "$__po_lyr" "$__po_edges"
    while IFS=$'\t' read -r __po_r __po_f __po_v; do
      [ -n "$__po_r" ] || continue
      _profiles_role_owner_v __po_owner "$__po_r" "$__po_chain" "$__po_root"
      [ "$__po_owner" = "$__po_name" ] || continue
      # The older line of the same field goes; the new one is last.
      __po_new=""
      while IFS=$'\t' read -r __po_x __po_cf __po_cv __po_cl; do
        [ -n "$__po_x" ] || continue
        if [ "$__po_x" = "$__po_r" ] && [ "$__po_cf" = "$__po_f" ]; then continue; fi
        __po_new="${__po_new:+$__po_new$'\n'}$__po_x"$'\t'"$__po_cf"$'\t'"$__po_cv"$'\t'"$__po_cl"
      done <<EOF
$__po_acc
EOF
      [ "$__po_f" != drop ] || __po_v=true
      __po_acc="${__po_new:+$__po_new$'\n'}$__po_r"$'\t'"$__po_f"$'\t'"$__po_v"$'\t'"$__po_lyr"
    done < <(profiles_check_rows "$__po_root/$__po_lyr")
  done
  # A dropped role keeps its drop line alone.
  __po_new=""
  while IFS=$'\t' read -r __po_r __po_f __po_v __po_x; do
    [ "$__po_f" != drop ] || __po_drops="$__po_drops$__po_r "
  done <<EOF
$__po_acc
EOF
  while IFS=$'\t' read -r __po_r __po_f __po_v __po_x; do
    [ -n "$__po_r" ] || continue
    case $__po_drops in
      *" $__po_r "*) [ "$__po_f" = drop ] || continue ;;
    esac
    __po_new="${__po_new:+$__po_new$'\n'}$__po_r"$'\t'"$__po_f"$'\t'"$__po_v"$'\t'"$__po_x"
  done <<EOF
$__po_acc
EOF
  printf -v "$1" '%s' "$__po_new"
}

# profiles_check_merged <profile-dir> [<edges>] — what `jig verify` hands a profile
# as JIG_VERIFY_CHECKS: a `<role><TAB>listed<TAB>` row for every role in `checks`,
# then the table's rows (profiles_check_rows) of the roles the profile owns, each
# field as the layers above it in <edges> set it (profiles_check_overrides_v). A
# role a layer dropped has no field rows and one `<role><TAB>drop<TAB><layer>`
# row. Prints nothing for a profile without table rows: the rows are the
# declaration, and `checks: [tests]` alone is not one. One producer, so a test
# that runs a profile's verify.sh directly hands it the same file `jig verify`
# would.
profiles_check_merged() {
  local dir="$1" edges="${2:-}" ovr rows="" roles ext r f v x lyr used=$'\n' dropped
  local line
  profiles_check_overrides_v ovr "$dir" "$edges"
  profile_get_v ext "$dir" extends || true
  _profiles_roles_v roles "$dir"
  while IFS=$'\t' read -r r f v; do
    [ -n "$r" ] || continue
    if [ -n "$ext" ]; then
      case $roles in *$'\n'"$r"$'\n'*) ;; *) continue ;; esac
      ! _profiles_is_pure "$dir" || continue
    fi
    rows="${rows:+$rows$'\n'}$r"$'\t'"$f"$'\t'"$v"
  done < <(profiles_check_rows "$dir")
  [ -n "$rows" ] || return 0
  while IFS= read -r r; do
    [ -z "$r" ] || printf '%s\tlisted\t\n' "$r"
  done < <(_profiles_list_lines "$dir" checks)
  while IFS=$'\t' read -r r f v; do
    if _profiles_tab_find_v x "$ovr" "$r" drop; then continue; fi
    if _profiles_tab_find_v x "$ovr" "$r" "$f"; then v=$x; fi
    printf '%s\t%s\t%s\n' "$r" "$f" "$v"
    used="$used$r.$f"$'\n'
  done <<EOF
$rows
EOF
  while IFS=$'\t' read -r r f v lyr; do
    [ -n "$r" ] || continue
    case $f in
      drop) printf '%s\tdrop\t%s\n' "$r" "$lyr" ;;
      *)
        case $used in *$'\n'"$r.$f"$'\n'*) continue ;; esac
        printf '%s\t%s\t%s\n' "$r" "$f" "$v"
        ;;
    esac
  done <<EOF
$ovr
EOF
}

# profiles_check_handdown <profile-dir> — profiles_check_merged with no layers:
# the profile's own check table as it stands.
profiles_check_handdown() { profiles_check_merged "$1" ""; }

# profiles_applies <profile-dir> — true when the profile's own stack is in
# the project: `detect` is `always`, absent (a project's profile, activated
# by name), or one of its globs matches. A profile covers another's check only
# where it applies — a profile whose command needs a file the project lacks
# runs nothing, and the check it would have taken over must stay where it was.
profiles_applies() {
  local glob raw
  profile_get_v raw "$1" detect || true
  case "$raw" in
    ''|always) return 0 ;;
    \[*\]) ;;
    *) return 1 ;;
  esac
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    _profiles_glob_matches "$glob" && return 0
  done < <(_profiles_list_lines "$1" detect)
  return 1
}

# --- validation ----------------------------------------------------------------
# A profile or adapter name can arrive from --profile/--profiles/--adapters
# or from .ai/config.yaml (profiles_active, cfg_list). Every consumer that
# turns such a name into a filesystem path goes through profiles_dir or
# adapters_dir below instead of concatenating it directly, so a name like
# `..` or `../../x` can never resolve outside the given root (mirrors
# scripts/lib/task.sh's task_dir / _task_valid_id).

# _profiles_valid_name <name> — true when <name> is safe as a single path
# segment: starts with a letter or digit (rules out `.`, `..`, and hidden
# directories) and contains only [A-Za-z0-9_-] thereafter (rules out `/`, so
# a name can never walk into a parent directory).
_profiles_valid_name() {
  case "$1" in
    [A-Za-z0-9]*) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# profiles_dir <root> <name> — absolute path of <name>'s directory under
# <root> (profiles_source_dir or profiles_installed_dir). Dies via jig_die
# with "invalid profile name: <name>" before printing anything when <name>
# is not shaped like a profile name; otherwise prints <root>/<name>.
profiles_dir() {
  _profiles_valid_name "$2" || jig_die "invalid profile name: $2"
  printf '%s/%s\n' "$1" "$2"
}

# _adapters_valid_name <name> — same shape constraint as
# _profiles_valid_name; adapter names come from the same untrusted sources
# (--adapters/.ai/config.yaml's `adapters` list) and are used to build a
# path under <source>/adapters/.
_adapters_valid_name() {
  case "$1" in
    [A-Za-z0-9]*) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# adapters_dir <root> <name> — absolute path of <name>'s directory under
# <root> (e.g. <source>/adapters). Mirrors profiles_dir; used by init.sh and
# upgrade.sh before sourcing <root>/<name>/adapter.sh.
adapters_dir() {
  _adapters_valid_name "$2" || jig_die "invalid adapter name: $2"
  printf '%s/%s\n' "$1" "$2"
}

# --- directories --------------------------------------------------------------

# profiles_source_dir — the profiles/ directory under the framework source
# checkout this copy of jig runs from (jig_source_root), or nothing when
# this is not a source checkout (installed copy, no JIG_SOURCE match).
profiles_source_dir() {
  local src
  src=$(jig_source_root)
  [ -n "$src" ] || return 0
  printf '%s/profiles\n' "$src"
}

# profiles_installed_dir — where profiles are installed inside the current
# project. JIG_PROJECT must already be set (jig_require_repo/init).
profiles_installed_dir() {
  printf '%s/%s/profiles\n' "$JIG_PROJECT" "$JIG_AI_DIR"
}

# --- glob matching -------------------------------------------------------------
# Mirrors scripts/lib/knowledge.sh's km_glob_to_findpath / km_glob_matches.
# Not shared by sourcing knowledge.sh: each command sources only the
# libraries it needs, and knowledge.sh's helpers are private to km_check.

# Translate a `detect` glob (repo-relative) into a `find -path` pattern.
# `**` matches any depth, including zero directories; BSD/GNU `find -path`
# both match `*` against `/` too (no FNM_PATHNAME), so collapsing `**/` and
# `**` down to a single `*` is sufficient and correct.
#
# _profiles_glob_to_findpath_v <var> <glob> — the pattern into <var>, without a
# process: `init` asks it of every detect glob of every profile.
_profiles_glob_to_findpath_v() {
  local __pgf_out
  _jig_replace_all_v __pgf_out "$2" '**/' '*'
  _jig_replace_all_v __pgf_out "$__pgf_out" '**' '*'
  printf -v "$1" '%s' "$__pgf_out"
}

# _profiles_glob_matches <glob> — exit 0 when <glob> matches at least one
# path in JIG_PROJECT. .git/ and the directories other stacks install their
# dependencies into are not searched: `jig init` activates what it detects
# (adr-20260918-init-activates-detected-profiles), and a .sh file inside node_modules/ or a .csproj inside a
# vendored package is not what the project is written in.
_profiles_glob_matches() {
  local glob="$1" pattern hit
  _profiles_glob_to_findpath_v pattern "$glob"
  hit=$(find "$JIG_PROJECT" \
    \( -path "$JIG_PROJECT/.git" -o -name node_modules -o -name vendor \
       -o -name .venv -o -name venv -o -name .dart_tool -o -name .ai \) -prune -o \
    -path "$JIG_PROJECT/$pattern" -print -quit 2>/dev/null)
  [ -n "$hit" ]
}

# --- activation ----------------------------------------------------------------

# profiles_active — the project's configured `profiles` list (.ai/config.yaml),
# with `generic` always first and duplicates dropped. Dies via jig_die when
# the config lists a name that is not shaped like a profile name: a
# traversal attempt in .ai/config.yaml is reachable through every command
# that defaults to the active profiles (verify, upgrade, flag-less init),
# not just an explicit --profile flag, so it is rejected here too.
profiles_active() {
  local configured p
  configured=$(cfg_list profiles generic)
  for p in $configured; do
    _profiles_valid_name "$p" || jig_die "invalid profile name: $p"
  done
  _profiles_dedup "generic $configured"
}

# profiles_reached — the names of the profiles the active set reaches,
# space-separated like profiles_active: the stack, `profiles:` closed over
# `extends` (profiles_stack_v). This is the single place that decides
# "reached", so callers ask it and not profiles_active. Exit 1, printing
# nothing, when the stack does not resolve: what it would reach is unknown,
# and nothing may be named unreached on a guess.
profiles_reached() {
  local __pr_names
  profiles_stack_v __pr_names || return 1
  printf '%s\n' "$__pr_names"
}

# profiles_unreached — one name per line, sorted, of each directory directly
# under the installed profiles dir that profiles_reached does not name: a
# profile that is installed but never runs. Prints nothing when the dir is
# missing. A report must not die on a bad entry, so non-directories and names
# that are not shaped like a profile name are skipped, and an invalid
# configured name, or a stack that does not resolve, makes this return
# non-zero quietly (profiles_reached), so nothing is named on a guess.
profiles_unreached() {
  local dir reached entry name out=""
  dir=$(profiles_installed_dir)
  [ -d "$dir" ] || return 0
  reached=$( (profiles_reached) 2>/dev/null) || return 1
  for entry in "$dir"/*; do
    [ -d "$entry" ] || continue
    name=${entry##*/}
    _profiles_valid_name "$name" || continue
    case " $reached " in *" $name "*) continue ;; esac
    out="$out$name"$'\n'
  done
  [ -n "$out" ] || return 0
  printf '%s' "$out" | LC_ALL=C sort
}

# --- detection -------------------------------------------------------------

# profiles_detect [<profiles-root>] — names of every profile under
# <profiles-root> whose `detect` globs match a path in the current project
# (JIG_PROJECT), one per line; `generic` is always first. Defaults
# <profiles-root> to profiles_source_dir; prints just `generic` when no
# root can be determined. Applies the `requires` closure: a matched profile
# pulls in every profile it requires, even one whose own detect globs did
# not match (a profile that requires php pulls it in).
profiles_detect() {
  local root="${1:-}" p name matched glob result="generic" req changed detect
  [ -n "$root" ] || root=$(profiles_source_dir)

  if [ -n "$root" ] && [ -d "$root" ]; then
    for p in "$root"/*/; do
      [ -d "$p" ] || continue
      p="${p%/}"
      name=${p##*/}
      [ "$name" = "generic" ] && continue
      profile_get_v detect "$p" detect || true
      case "$detect" in
        always)
          result="$result $name"
          ;;
        \[*\])
          matched=0
          while IFS= read -r glob; do
            [ -n "$glob" ] || continue
            _profiles_glob_matches "$glob" && { matched=1; break; }
          done < <(_profiles_list_lines "$p" detect)
          [ "$matched" = 1 ] && result="$result $name"
          ;;
      esac
    done

    # requires closure: keep pulling in required profiles until a full pass
    # adds nothing new.
    changed=1
    while [ "$changed" = 1 ]; do
      changed=0
      for name in $result; do
        p=$(profiles_dir "$root" "$name")
        [ -d "$p" ] || continue
        while IFS= read -r req; do
          [ -n "$req" ] || continue
          case " $result " in
            *" $req "*) ;;
            *) result="$result $req"; changed=1 ;;
          esac
        done < <(_profiles_list_lines "$p" requires)
      done
    done
  fi

  result=$(_profiles_dedup "$result")
  printf '%s\n' "$result" | tr ' ' '\n' | sed '/^$/d'
}

# --- stacks --------------------------------------------------------------------
# A profile may build on one other: `extends: <name>` in its profile.yaml
# (schemas/profile.md, adr-20261117-profiles-lists-top-layers-and-jig-resolves-the-stack).
# `profiles:` in .ai/config.yaml lists the top layers; the stack is that list
# closed over `extends`, and profiles_stack_v is the one place that closes it:
# verify, upgrade, init, carry/lock and ship all read the stack from here.

# _profiles_extends_v <var> <name> <ext-root> — the base <name> extends into
# <var> (empty when it extends nothing, or when there is no such profile). Reads
# <ext-root>/<name> when that directory exists, else the installed profile: a
# project's own profile lives nowhere but .ai/profiles. Exit 1, with
# PROFILES_STACK_ERROR and PROFILES_STACK_LAYER set, for a value that is not one
# profile name.
_profiles_extends_v() {
  local __pe_dir __pe_raw
  printf -v "$1" '%s' ""
  __pe_dir="$3/$2"
  [ -d "$__pe_dir" ] || __pe_dir="$JIG_PROJECT/$JIG_AI_DIR/profiles/$2"
  profile_get_v __pe_raw "$__pe_dir" extends || return 0
  [ -n "$__pe_raw" ] || return 0
  PROFILES_STACK_LAYER=$2
  case "$__pe_raw" in
    \[*)
      PROFILES_STACK_ERROR="$2: extends names one profile, not a list ($__pe_raw)"
      return 1
      ;;
  esac
  if ! _profiles_valid_name "$__pe_raw"; then
    PROFILES_STACK_ERROR="$2: extends '$__pe_raw' is not a profile name"
    return 1
  fi
  if [ "$__pe_raw" = generic ]; then
    PROFILES_STACK_ERROR="$2: extends 'generic', which is always first and is no base"
    return 1
  fi
  printf -v "$1" '%s' "$__pe_raw"
}

# _profiles_tracked_v <var> — `<name>` words, one per profile the install
# manifest tracks a file of under .ai/profiles/<name>/ (copy mode): the profiles
# jig placed. Read once per question, with builtins only, so asking it of every
# profile of a stack starts no process per profile (conventions/shell.md).
_profiles_tracked_v() {
  local __pt_file __pt_line __pt_body=0 __pt_name __pt_out=" "
  local __pt_prefix="$JIG_AI_DIR/profiles/"
  __pt_file="$JIG_PROJECT/$JIG_AI_DIR/manifest"
  printf -v "$1" '%s' " "
  [ -f "$__pt_file" ] || return 0
  while IFS= read -r __pt_line || [ -n "$__pt_line" ]; do
    __pt_line=${__pt_line%$'\r'}
    if [ "$__pt_body" = 0 ]; then
      [ "$__pt_line" != "---" ] || __pt_body=1
      continue
    fi
    __pt_line=${__pt_line#* }
    case "$__pt_line" in
      "$__pt_prefix"*/*) ;;
      *) continue ;;
    esac
    __pt_name=${__pt_line#"$__pt_prefix"}
    __pt_name=${__pt_name%%/*}
    case "$__pt_out" in
      *" $__pt_name "*) ;;
      *) __pt_out="$__pt_out$__pt_name " ;;
    esac
  done < "$__pt_file"
  printf -v "$1" '%s' "$__pt_out"
}

# _profiles_stock_in <name> <stock-root> <tracked> — profiles_is_stock with what
# it reads handed in: <stock-root> may be empty, <tracked> is _profiles_tracked_v's.
_profiles_stock_in() {
  [ -z "$2" ] || [ ! -d "$2/$1" ] || return 0
  [ ! -L "$JIG_PROJECT/$JIG_AI_DIR/profiles/$1" ] || return 0
  case "$3" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# _profiles_project_in <name> <stock-root> <tracked> — profiles_is_project with
# what it reads handed in. Only a real, untracked directory that also exists in
# the source is compared file by file: the one rare case that costs a process.
_profiles_project_in() {
  local dir="$JIG_PROJECT/$JIG_AI_DIR/profiles/$1" f rel
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  case "$3" in
    *" $1 "*) return 1 ;;
  esac
  [ -n "$2" ] && [ -d "$2/$1" ] || return 0
  while IFS= read -r f; do
    rel=${f#"$dir"/}
    [ -f "$2/$1/$rel" ] && cmp -s "$f" "$2/$1/$rel" || return 0
  done < <(find "$dir" -type f)
  return 1
}

# profiles_is_stock <name> [<stock-root>] — true when <name> is a profile jig
# ships or has installed: it exists under <stock-root> (a source's profiles/;
# default profiles_source_dir, when this is a source checkout), the manifest
# tracks .ai/profiles/<name>/ (copy mode), or .ai/profiles/<name> is a symlink
# (link mode, where the manifest body is empty). False for a name that is not
# shaped like a profile name: it never becomes a path.
profiles_is_stock() {
  local root="${2:-}" tracked
  _profiles_valid_name "$1" || return 1
  [ -n "$root" ] || root=$(profiles_source_dir)
  _profiles_tracked_v tracked
  _profiles_stock_in "$1" "$root" "$tracked"
}

# profiles_is_project <name> [<stock-root>] — true when .ai/profiles/<name> is a
# profile the project wrote: a real directory the manifest does not track whose
# files are not all byte-identical to the source's copy. A directory that is
# identical is a stock profile whose install was interrupted — copy mode places
# files one by one and writes the manifest once, at the end — and the next run
# finishes it rather than refuses it. False for a name that is not shaped like a
# profile name.
profiles_is_project() {
  local root="${2:-}" tracked
  _profiles_valid_name "$1" || return 1
  [ -n "$root" ] || root=$(profiles_source_dir)
  _profiles_tracked_v tracked
  _profiles_project_in "$1" "$root" "$tracked"
}

# profiles_stack_v <var> [--edges] [--stock-root <dir>] [<name>...] — the stack
# of <name>... (default: generic and `profiles:`) into <var>: names separated by
# spaces, in run order. With --edges, lines `<layer><TAB><base>` instead, one per
# extends in the stack, in run order of the layer.
#
# Run order is topological, a layer always before its base, and otherwise the
# order the names were first met: each name listed, then its chain down, repeats
# dropped, then names are taken one at a time, each the first one all of whose
# layers are out. `[generic, a, b]` over a shared `laravel`, over `php`, is
# generic a b laravel php; a walk down each chain in turn would put laravel
# before b. A list that names both a layer and its base is allowed and runs the
# base once.
#
# <stock-root> is a source's profiles/ (upgrade, init): the `extends` of a stock
# profile is read there, because the version being installed may change it, and
# the name is stock when it exists there. By default the extends of every
# profile is read from what is installed (verify: what runs is what is there).
#
# Called in the caller's own shell, never in `$( )`, like profile_get_v: the
# reason must reach the caller. It never dies. Exit 1, <var> empty, and
# PROFILES_STACK_ERROR holds `<layer>: <reason>` (PROFILES_STACK_LAYER the layer)
# for: a name that is not a profile name, an extends that is a list, `generic` or
# not a name, a base that is not there, a cycle, and a profile the project wrote
# under the name of a stock one.
# shellcheck disable=SC2034 # read by the callers
PROFILES_STACK_ERROR=""
# shellcheck disable=SC2034
PROFILES_STACK_LAYER=""
profiles_stack_v() {
  local __ps_var="$1" __ps_edges=0 __ps_root="" __ps_names="" __ps_n
  shift
  PROFILES_STACK_ERROR=""
  PROFILES_STACK_LAYER=""
  printf -v "$__ps_var" '%s' ""
  while [ $# -gt 0 ]; do
    case "$1" in
      --edges) __ps_edges=1; shift ;;
      --stock-root)
        __ps_root="$2"
        shift 2
        ;;
      *) __ps_names="$__ps_names $1"; shift ;;
    esac
  done
  if [ -z "$__ps_names" ]; then
    __ps_names="generic $(cfg_list profiles generic)"
  fi
  local __ps_installed="$JIG_PROJECT/$JIG_AI_DIR/profiles"
  local __ps_ext_root="${__ps_root:-$__ps_installed}" __ps_out=""
  local __ps_order="" __ps_chain __ps_cur __ps_base __ps_seen __ps_edgelist="" __ps_name

  for __ps_name in $__ps_names; do
    if ! _profiles_valid_name "$__ps_name"; then
      PROFILES_STACK_LAYER=$__ps_name
      PROFILES_STACK_ERROR="$__ps_name: invalid profile name"
      return 1
    fi
    __ps_cur=$__ps_name
    __ps_chain=""
    while :; do
      case " $__ps_chain " in
        *" $__ps_cur "*)
          PROFILES_STACK_LAYER=$__ps_cur
          _jig_replace_all_v __ps_out "${__ps_chain# } $__ps_cur" ' ' ' -> '
          PROFILES_STACK_ERROR="$__ps_cur: extends cycle: $__ps_out"
          return 1
          ;;
      esac
      __ps_chain="$__ps_chain $__ps_cur"
      __ps_seen=1
      case " $__ps_order " in
        *" $__ps_cur "*) ;;
        *) __ps_seen=0; __ps_order="$__ps_order $__ps_cur" ;;
      esac
      # A name met before had its chain walked then.
      [ "$__ps_seen" = 0 ] || break
      _profiles_extends_v __ps_base "$__ps_cur" "$__ps_ext_root" || return 1
      [ -n "$__ps_base" ] || break
      if [ ! -d "$__ps_ext_root/$__ps_base" ] && [ ! -d "$__ps_installed/$__ps_base" ]; then
        PROFILES_STACK_LAYER=$__ps_cur
        if [ -n "$__ps_root" ]; then
          PROFILES_STACK_ERROR="$__ps_cur: extends '$__ps_base', which is neither shipped with jig nor in $JIG_AI_DIR/profiles"
        else
          PROFILES_STACK_ERROR="$__ps_cur: extends '$__ps_base', which is not installed (run jig upgrade)"
        fi
        return 1
      fi
      __ps_edgelist="$__ps_edgelist $__ps_cur>$__ps_base"
      __ps_cur=$__ps_base
    done
  done
  __ps_out=""
  __ps_order=${__ps_order# }
  __ps_edgelist=${__ps_edgelist# }

  # The project's own profile under a stock name: one refusal naming both.
  # What the check reads is read once here, not once per profile.
  local __ps_src="$__ps_root" __ps_tracked
  [ -n "$__ps_src" ] || __ps_src=$(profiles_source_dir)
  _profiles_tracked_v __ps_tracked
  for __ps_name in $__ps_order; do
    [ "$__ps_name" != generic ] || continue
    if _profiles_project_in "$__ps_name" "$__ps_src" "$__ps_tracked" \
       && _profiles_stock_in "$__ps_name" "$__ps_src" "$__ps_tracked"; then
      # shellcheck disable=SC2034
      PROFILES_STACK_LAYER=$__ps_name
      # shellcheck disable=SC2034
      PROFILES_STACK_ERROR="$__ps_name: profile '$JIG_AI_DIR/profiles/$__ps_name' is the project's own, but '$__ps_name' is a stock profile; rename the project's (and its extends: lines), or, if it is an interrupted install of the stock one, remove the directory and run jig upgrade"
      return 1
    fi
  done

  local __ps_emitted="" __ps_e __ps_ok __ps_progress=1
  while [ "$__ps_progress" = 1 ]; do
    __ps_progress=0
    for __ps_n in $__ps_order; do
      case " $__ps_emitted " in
        *" $__ps_n "*) continue ;;
      esac
      __ps_ok=1
      for __ps_e in $__ps_edgelist; do
        [ "${__ps_e#*>}" = "$__ps_n" ] || continue
        case " $__ps_emitted " in
          *" ${__ps_e%%>*} "*) ;;
          *) __ps_ok=0; break ;;
        esac
      done
      [ "$__ps_ok" = 1 ] || continue
      __ps_emitted="$__ps_emitted $__ps_n"
      __ps_progress=1
      break
    done
  done
  __ps_emitted=${__ps_emitted# }

  if [ "$__ps_edges" = 1 ]; then
    for __ps_n in $__ps_emitted; do
      for __ps_e in $__ps_edgelist; do
        [ "${__ps_e%%>*}" = "$__ps_n" ] || continue
        __ps_out="${__ps_out:+$__ps_out$'\n'}$__ps_n"$'\t'"${__ps_e#*>}"
      done
    done
  else
    __ps_out=$__ps_emitted
  fi
  printf -v "$__ps_var" '%s' "$__ps_out"
}

# --- requires check ----------------------------------------------------------

# profiles_check_requires — jig_warn (stderr) for every profile of the stack
# whose `requires` are not all in it. Advisory only: always returns 0. A stack
# that does not resolve is verify's refusal to make; here the plain list is read.
profiles_check_requires() {
  local active p name req installed_dir
  profiles_stack_v active || active=$(profiles_active)
  installed_dir=$(profiles_installed_dir)
  for name in $active; do
    p=$(profiles_dir "$installed_dir" "$name")
    [ -d "$p" ] || continue
    while IFS= read -r req; do
      [ -n "$req" ] || continue
      case " $active " in
        *" $req "*) ;;
        *) jig_warn "profile '$name' requires '$req', which is not active" ;;
      esac
    done < <(_profiles_list_lines "$p" requires)
  done
  return 0
}

# --- worktree bootstrap declarations -----------------------------------------
# A task worktree starts as a git checkout, so it holds nothing git does not
# track: no vendor/, no node_modules/, no .env. A profile declares what its
# stack keeps outside git, and `jig task start --worktree` carries it over
# from the owning checkout (adr-20260924-a-worktree-carries-what-git-does-not).

# _profiles_declared <key> — `<profile><TAB><item>` for every item the profiles
# of the stack declare under <key>, first-occurrence order, an item never repeated
# whichever profile named it first. Reads the profiles installed in this
# project: those are the ones it actually runs, and `upgrade` keeps a copy a
# user edited (ADR-0003).
_profiles_declared() {
  local key="$1" root name dir item seen="" names
  root=$(profiles_installed_dir)
  # The stack, not the list: a base is installed and runs. One that does not
  # resolve reads as the plain list; refusing is verify's work, not carry's.
  profiles_stack_v names || names=$(profiles_active)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    dir=$(profiles_dir "$root" "$name") || return 1
    [ -d "$dir" ] || continue
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      case "$seen" in
        *"<$item>"*) continue ;;
      esac
      seen="$seen<$item>"
      printf '%s\t%s\n' "$name" "$item"
    done < <(_profiles_list_lines "$dir" "$key")
  done < <(printf '%s\n' "$names" | tr ' ' '\n')
  return 0
}

# profiles_carry — `<profile><TAB><path>` for each path the active profiles
# declare as derived state to copy into a new task worktree.
profiles_carry() { _profiles_declared carry; }

# profiles_lock — `<profile><TAB><path>` for each lock file the active
# profiles name. A lock file that differs between the owning checkout and the
# worktree means carried state is stale, not wrong.
profiles_lock() { _profiles_declared lock; }

# profiles_install <profile> — the command that installs <profile>'s
# dependencies from the network, or nothing. It is printed for a human to run,
# never executed: `task start` is not a build command, the agent's sandbox may
# hold no network, and the case this whole mechanism exists for is a host with
# no toolchain at all, where running it could not work anyway (adr-20260924-a-worktree-carries-what-git-does-not).
profiles_install() {
  local dir
  dir=$(profiles_dir "$(profiles_installed_dir)" "$1") || return 0
  profile_get "$dir" install
}
