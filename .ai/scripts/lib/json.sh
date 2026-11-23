# JSON output: the one place Jig writes JSON, and the envelope every `--json`
# read is printed in (adr-20261015-a-read-is-one-json-envelope; schemas/json.md).
# Sourced by the commands that offer `--json`; sourcing it twice is harmless,
# since it only defines functions and constants.
#
#   json_run <producer> [args...]
#       Run <producer> and print exactly one envelope line on stdout:
#         {"schema":1,"revision":…,"generated_at":"…","data":<producer's stdout>}
#       with the revision and the time both taken before the producer runs
#       or, when the producer fails or prints nothing,
#         {"schema":1,"revision":…,"generated_at":"…","error":{"code":"…","message":"…"}}
#       The producer prints one JSON value and nothing else on stdout; what it
#       prints on stderr reaches stderr unchanged, but for the code markers
#       below. Returns the producer's status (1 when it succeeded without
#       printing anything).
#       `code` is the stable failure code the refusal named — `jig_fail <code>`
#       (common.sh) — or `failed` when it named none (schemas/json.md, "Failure
#       codes").
#
#   json_quote <s>        _JSON <- <s> as a JSON string, quotes included
#   json_str_or_null <s>  _JSON <- null for an empty <s>, else json_quote
#   json_int_or_null <s>  _JSON <- <s> when it is a non-negative integer, else null
#   json_bool <s>         _JSON <- true for `true`, else false
#
# The builders set the global _JSON rather than print, so a producer can build
# a record field by field without a subshell per field.
#
# Written by the shell, without jq or any other dependency (ADR-0002). Strings
# are escaped for `"`, `\` and every control byte; other bytes, UTF-8 included,
# pass through as they are.
# shellcheck shell=bash

_JSON=""

# The control bytes other than tab, newline and carriage return, which
# json_quote replaces by name before it looks for these. Built once, not typed:
# a literal control byte in a source file is invisible in every editor.
_JSON_CTRL=$(printf '\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037')

json_quote() {
  local s="$1" c i n code
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  case "$s" in
    *["$_JSON_CTRL"]*)
      # Rare (a hand-edited state file, an escape sequence in a reason or a
      # task document), so the pass is paid only when one is there. One
      # substitution per control byte, not a loop over the string's
      # characters: a long field can reach here, and a per-character loop
      # that appends grows with the square of its size.
      # The replacement is quoted, so neither `\` nor `&` (bash 5.2's
      # patsub_replacement) means anything in it.
      n=${#_JSON_CTRL}
      i=0
      while [ "$i" -lt "$n" ]; do
        c=${_JSON_CTRL:$i:1}
        case "$s" in
          *"$c"*)
            printf -v code '\\u%04x' "'$c"
            s=${s//"$c"/"$code"}
            ;;
        esac
        i=$((i + 1))
      done
      ;;
  esac
  _JSON="\"$s\""
}

# json_quote_text <s> — _JSON <- what json_quote <s> sets, for a text that may be
# long: a whole document or a diff. json_quote's substitutions cost the length of
# the string once per match on bash 3.2, so over a whole text they grow with the
# square of its size (an 83 KB diff took minutes, a 37 KB spec 3 s). Here they run
# on one line at a time, so the cost grows with the number of lines, and with the
# square of the longest line only. The lines are read by the shell, which keeps a
# carriage return (awk under Git Bash drops it, conventions/shell.md), and no
# process is started. Each escaped line is kept in an array and the array joined
# once: appending to one string would copy all of it again per line.
json_quote_text() {
  local line i=0 IFS
  local -a acc
  # The here-document ends the text with one newline more, so every line read
  # was followed by one; the last `\n` is taken off again after the join.
  while IFS= read -r line; do
    json_quote "$line"
    _JSON=${_JSON#\"}
    acc[i]="${_JSON%\"}\\n"
    i=$((i + 1))
  done <<EOF
$1
EOF
  IFS=
  _JSON="${acc[*]}"
  _JSON="\"${_JSON%\\n}\""
}

json_str_or_null() {
  if [ -z "$1" ]; then _JSON=null; else json_quote "$1"; fi
}

json_int_or_null() {
  case "$1" in
    '' | *[!0-9]*) _JSON=null ;;
    *) _JSON=$((10#$1)) ;;
  esac
}

json_bool() {
  if [ "$1" = true ]; then _JSON=true; else _JSON=false; fi
}

# json_revision — the clone's revision every envelope reports: the counter
# every Jig write raises (jig_revision_read, common.sh;
# adr-20261016-the-clone-revision-is-a-claimed-name), `0` before the first one.
json_revision() {
  jig_revision_read
}

# The marker _jig_die_as (common.sh) prints just before a refusal's message
# inside a producer: a unit separator and `jig: code: `, then the code.
_JSON_CODE_MARK=$(printf '\037jig: code: ')

# _json_error_from <stderr-file> <status> — the refusal as two lines: its
# code, then its message. The message is what the last `jig: error: ` said, to
# the end of the file (a message can span lines), or the bare exit status when
# nothing said why (`set -e` on a failed command). The code is the one the
# marker on the line right before that message named; `failed` when there is
# no such marker — a refusal by plain jig_die, by a child jig, by a message
# printed without either, or no message at all — or when what it names is not
# a code (lowercase words joined by `-`).
_json_error_from() {
  local both code msg
  both=$(JIG_JSON_MARK="$_JSON_CODE_MARK" awk '
    BEGIN { mark = ENVIRON["JIG_JSON_MARK"]; pending = "" }
    index($0, mark) == 1 { pending = substr($0, length(mark) + 1); next }
    index($0, "jig: error: ") == 1 {
      code = pending; text = substr($0, 13); on = 1; pending = ""; next
    }
    { pending = "" }
    on { text = text "\n" $0 }
    END { printf "%s\n%s", code, text }
  ' "$1")
  code=${both%%$'\n'*}
  msg=${both#*$'\n'}
  # The letters are spelled out: a range such as [a-z] takes capitals too in
  # some locales, and a code is lowercase.
  case "$code" in
    [abcdefghijklmnopqrstuvwxyz]*)
      case "$code" in *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) code=failed ;; esac
      ;;
    *) code=failed ;;
  esac
  [ -n "$msg" ] || { msg="exited with status $2"; code=failed; }
  printf '%s\n%s' "$code" "$msg"
}

json_run() {
  local producer="$1" out err rc at rev both code
  shift
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Read before the data, never after: a write that lands while the producer
  # reads then raises the revision past this one, and the consumer's next read
  # sees it. Read after, the revision could cover a write the data missed, and
  # the consumer would never learn of it.
  rev=$(json_revision)
  out=$(mktemp "${TMPDIR:-/tmp}/jig-json.XXXXXX")
  jig_cleanup_add "$out"
  err=$(mktemp "${TMPDIR:-/tmp}/jig-json.XXXXXX")
  jig_cleanup_add "$err"
  # The producer runs in a subshell of its own, so that whatever ends it — a
  # jig_die anywhere below it, `set -e`, an unknown argument — ends there and
  # is reported here, in the one envelope. Not `( … ) || rc=$?`: inside a
  # condition bash ignores `set -e` for the whole subshell, and the producer
  # would run on past its own failures.
  # _JIG_JSON_CODES asks _jig_die_as for its code marker, in the producer's
  # subshell only, and unexported: a child jig's refusal is plain text, and
  # reads as `failed`.
  set +e
  ( set -e; _JIG_JSON_CODES=1; "$producer" "$@" ) >"$out" 2>"$err"
  rc=$?
  set -e
  # The person reads stderr as the text form prints it: the markers are for
  # the code below, never for them. One awk, never `LC_ALL=C grep` first: a
  # locale variable assigned for one command makes bash reset its own locale
  # around it, and Homebrew's bash 5.3 on macOS died there now and then
  # (SIGSEGV, exit 139) — after the producer's write had landed, with no
  # envelope printed (pause-request-cancel-landed-but-failed).
  JIG_JSON_MARK="$_JSON_CODE_MARK" awk 'index($0, ENVIRON["JIG_JSON_MARK"]) != 1' "$err" >&2
  printf '{"schema":1,"revision":%s,"generated_at":"%s",' "$rev" "$at"
  if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
    printf '"data":%s}\n' "$(cat "$out")"
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    rc=1
    both=$(printf 'failed\nprinted no data')
  else
    both=$(_json_error_from "$err" "$rc")
  fi
  code=${both%%$'\n'*}
  json_quote "${both#*$'\n'}"
  printf '"error":{"code":"%s","message":%s}}\n' "$code" "$_JSON"
  return "$rc"
}

# json_utf8_clean <s> — _JSON_CLEAN <- <s> without the bytes that are not valid
# UTF-8, _JSON_LOSSY <- true when there were any. Shared by every read that hands
# JSON the text of a file a person committed (knowledge.sh, spec.sh). json_quote lets such bytes
# through as they are, and one of them makes the whole line invalid JSON: a
# source file is anything a person committed. Strict UTF-8 is checked and
# repaired by iconv; where there is none, every byte outside ASCII becomes `?`,
# one per byte, which is the lossy end of the same thing.
json_utf8_clean() {
  local ascii src
  _JSON_CLEAN=$1
  _JSON_LOSSY=false
  if command -v iconv >/dev/null 2>&1; then
    # Some iconv builds (macOS) accept what is not UTF-8 to a JSON parser: bytes
    # F5 to FF, which lead no character, and F4 followed by 90 to BF, which leads
    # one above U+10FFFF. Those go first; the continuation bytes they leave alone
    # are iconv's to drop. F4 followed by 80 to 8F is U+100000 to U+10FFFF, valid
    # and kept.
    src=$(printf '%sx' "$1" | LC_ALL=C tr -d '\365-\377')
    src=${src%x}
    if [ -n "$(printf '%s' "$src" | LC_ALL=C tr -cd '\364')" ]; then
      _json_drop_above_unicode "$src"
      src=$_JSON_CLEAN
      _JSON_CLEAN=$1
    fi
    if [ "$src" = "$1" ] && printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
      return 0
    fi
    # The sentinel keeps the trailing newlines $(...) would strip, and ends a
    # truncated sequence the way following bytes would: three of them, since a
    # four-byte lead left with fewer behind it takes them down with it (macOS
    # iconv drops an incomplete last character whole).
    _JSON_CLEAN=$(printf '%sxxx' "$src" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true)
    _JSON_CLEAN=${_JSON_CLEAN%xxx}
    _JSON_LOSSY=true
    return 0
  fi
  # Printable ASCII, tab, carriage return and newline stay.
  ascii=$(printf '\t\r -~')
  if [ -z "$(printf '%s' "$1" | LC_ALL=C tr -d "\n$ascii")" ]; then
    return 0
  fi
  _JSON_CLEAN=$(printf '%sx' "$1" | LC_ALL=C tr -c "\n$ascii" '?')
  _JSON_CLEAN=${_JSON_CLEAN%x}
  _JSON_LOSSY=true
}

# _json_drop_above_unicode <s> — _JSON_CLEAN <- <s> without each F4 byte and the byte
# from 90 to BF that follows it. Matched by the shell, byte by byte under the C locale: sed and awk
# would drop the carriage return of a CRLF line under Git Bash (conventions/shell.md). The text is
# split on F4 by word splitting, not stripped with ${s//pattern/}: on bash 3.2 that substitution
# costs the text's length once per match, and a source file can be long and hold many of them.
# The `x` keeps a trailing F4's empty field, and the trailing newlines $(...) would strip.
#
# The work runs in a $(...) with a plain LC_ALL=C, never under `local LC_ALL=C`: bash restores a
# local locale on return, which crashes Homebrew's bash on macOS now and then, while the
# subshell's assignment dies with it, unrestored (conventions/shell.md). The text comes back
# through the same sentinel-guarded $(...) that json_utf8_clean already passes it through first,
# and globbing needs no restoring there.
_json_drop_above_unicode() {
  _JSON_CLEAN=$(
    LC_ALL=C
    # Each pattern opens with `(`: bash 3.2 cannot parse a bare `pattern)` inside $(...).
    case $1 in (*$'\364'*) ;; (*) printf '%sx' "$1"; exit 0 ;; esac
    local IFS=$'\364' part first=1
    local -a parts acc
    set -f
    # shellcheck disable=SC2206 # the split on IFS is the point; globbing is off
    parts=(${1}x)
    # The pieces are joined once at the end: appending each to one string would
    # copy all of it again per F4.
    for part in "${parts[@]}"; do
      if [ -n "$first" ]; then acc[0]=$part; first=; continue; fi
      case $part in
        ([$'\220'-$'\277']*) acc[${#acc[@]}]=${part#?} ;;
        (*) acc[${#acc[@]}]=$'\364'$part ;;
      esac
    done
    IFS=
    printf '%s' "${acc[*]}"
  )
  _JSON_CLEAN=${_JSON_CLEAN%x}
}
