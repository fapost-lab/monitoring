# Reader for knowledge document frontmatter (schemas/frontmatter.md, ADR-0004).
# Grammar is a flat YAML subset: scalars, inline lists `[a, b]`, and one-level
# block lists `  - item` (two-space indent). No nesting, no multi-line scalars.
# bash 3.2 compatible: no associative arrays, no ${var,,}, no mapfile.
# shellcheck shell=bash

# _fm_scan_v <var> <file> — the raw lines strictly between the opening and the
# first closing `---` delimiter into <var>, the lines up to the end of the file
# when nothing closes it. Exit 0 when the file starts with a `---` line and has
# a closing one, 1 otherwise. Without a process: `jig context` reads every
# document of a project (convention-shell, `<name>_v`).
_fm_scan_v() {
  local __fms_line __fms_block="" __fms_first=1 __fms_closed=1 __fms_nl=$'\n' __fms_cr=$'\r' __fms_n=0 __fms_blanks=0
  local -a __fms_lines
  printf -v "$1" '%s' ''
  while IFS= read -r __fms_line || [ -n "$__fms_line" ]; do
    # A checkout may end its lines in CRLF (core.autocrlf, a Windows default;
    # templates/gitattributes pins no line ending for .ai/knowledge/).
    # Asked first: on a line with no CR the expansion alone tries every position.
    case "$__fms_line" in
      *"$__fms_cr") __fms_line=${__fms_line%"$__fms_cr"} ;;
    esac
    if [ "$__fms_first" -eq 1 ]; then
      [ "$__fms_line" = "---" ] || return 1
      __fms_first=0
      continue
    fi
    if [ "$__fms_line" = "---" ]; then
      __fms_closed=0
      break
    fi
    # Lines kept apart and joined once: appending to a string copies it, and a
    # large document that never closes its frontmatter took a minute that way.
    # A blank line waits for a line after it, so trailing ones never get in:
    # `$(...)` would have dropped them, and stripping them afterwards is
    # quadratic too.
    if [ -z "$__fms_line" ]; then
      __fms_blanks=$((__fms_blanks + 1))
      continue
    fi
    while [ "$__fms_blanks" -gt 0 ]; do
      __fms_lines[__fms_n]=""
      __fms_n=$((__fms_n + 1))
      __fms_blanks=$((__fms_blanks - 1))
    done
    __fms_lines[__fms_n]=$__fms_line
    __fms_n=$((__fms_n + 1))
  done < "$2"
  if [ "$__fms_n" -gt 0 ]; then
    local IFS=$__fms_nl
    __fms_block="${__fms_lines[*]}"
  fi
  printf -v "$1" '%s' "$__fms_block"
  return "$__fms_closed"
}

# fm_has <file> — exit 0 when the file starts with a `---` line and has a
# closing `---` line further down.
fm_has() {
  local __fmh_block
  [ -f "$1" ] || return 1
  _fm_scan_v __fmh_block "$1"
}

# fm_block <file> — print the raw lines strictly between the opening and the
# first closing `---` delimiter. Prints nothing when there is no frontmatter.
fm_block() {
  local __fmb_block
  fm_block_v __fmb_block "$1"
  [ -z "$__fmb_block" ] || printf '%s\n' "$__fmb_block"
}

# fm_block_v <var> <file> — fm_block into <var>, without a process: an unclosed
# frontmatter is read up to the end of the file, a file with none leaves <var>
# empty. Always exit 0; fm_read_v is the reader that refuses an unclosed one.
fm_block_v() {
  _fm_scan_v "$1" "$2" || :
}

# fm_read_v <var> <file> — the frontmatter into <var>; exit 1, with <var> empty,
# when fm_has would say the file has none. fm_has and fm_block in one reading.
fm_read_v() {
  printf -v "$1" '%s' ''
  [ -f "$2" ] || return 1
  _fm_scan_v "$1" "$2" || {
    printf -v "$1" '%s' ''
    return 1
  }
}

# _fm_trim_v <var> <text> — <text> without leading and trailing whitespace.
_fm_trim_v() {
  local __fmt_text="$2"
  __fmt_text=${__fmt_text#"${__fmt_text%%[![:space:]]*}"}
  __fmt_text=${__fmt_text%"${__fmt_text##*[![:space:]]}"}
  printf -v "$1" '%s' "$__fmt_text"
}

# _fm_unquote_v <var> <text> — <text> without one pair of surrounding double
# quotes, when it has both.
_fm_unquote_v() {
  local __fmu_text="$2"
  case "$__fmu_text" in
    \"*\")
      __fmu_text=${__fmu_text#\"}
      __fmu_text=${__fmu_text%\"}
      ;;
  esac
  printf -v "$1" '%s' "$__fmu_text"
}

# A caller reading one document rarely wants one field: `paths`, `domains`,
# `topics`, `stages`, `id`, `status` in the same loop iteration are the normal
# case (context.sh's selection, knowledge.sh's validation), and fm_get/fm_list
# below used to re-read the file and re-run fm_block's `awk` for every one of
# them. A cache keyed by file, read back on the next call, cannot fix that: a
# caller almost always holds `$(fm_get ...)` or `$(fm_list ...)`, and a command
# substitution runs the callee in a *subshell* — any variable it set is gone
# the instant that subshell exits, before the next call could ever see it
# (measured: knowledge-costs-one-walk task.md; a cache built that way missed
# every single time it was tried).
#
# fm_get_block/fm_list_block below are the same reader, taking the block as a
# plain string instead of a file. A caller that wants several fields of one
# document — exactly the callers above — fetches the block once with
# `block=$(fm_block "$doc")` in *its own* shell (a local variable a command
# substitution's exit cannot erase) and passes it to as many of these as it
# needs, paying for the file read and the block `awk` once per document
# instead of once per field. fm_get/fm_list stay the one-call, file-taking
# functions every other caller already uses; they just delegate now.

# fm_get_block <block> <key> — fm_get, given the block already read.
fm_get_block() {
  local __fmgb_val
  fm_get_block_v __fmgb_val "$1" "$2"
  [ -z "$__fmgb_val" ] || printf '%s\n' "$__fmgb_val"
}

# fm_get_block_v <var> <block> <key> — fm_get_block into <var>, without a process.
fm_get_block_v() {
  local __fmg_nl=$'\n' __fmg_rest __fmg_val
  printf -v "$1" '%s' ''
  case "$__fmg_nl$2" in
    *"$__fmg_nl$3:"*) ;;
    *) return 0 ;;
  esac
  __fmg_rest="$__fmg_nl$2"
  __fmg_rest=${__fmg_rest#*"$__fmg_nl$3:"}
  __fmg_val=${__fmg_rest%%"$__fmg_nl"*}
  # Cut at the first `#`, then trim: a `#` closes the value with or without a
  # space before it.
  __fmg_val=${__fmg_val%%#*}
  _fm_trim_v __fmg_val "$__fmg_val"
  case "$__fmg_val" in
    '' | \[*) return 0 ;;
  esac
  _fm_unquote_v "$1" "$__fmg_val"
}

# fm_get <file> <key> — print the trimmed scalar value of <key> (trailing
# `# comment` stripped, surrounding double quotes stripped). Prints nothing
# when the key is absent or is a list (inline or block).
fm_get() {
  fm_get_block "$(fm_block "$1")" "$2"
}

# fm_list_block <block> <key> — fm_list, given the block already read.
# Supports inline `key: [a, b]` and block `key:\n  - a\n  - b` forms.
fm_list_block() {
  local __fmlb_items
  fm_list_block_v __fmlb_items "$1" "$2"
  [ -z "$__fmlb_items" ] || printf '%s\n' "$__fmlb_items"
}

# fm_list_block_v <var> <block> <key> — the items into <var>, one per line,
# without a process. An inline list anywhere under the key wins over a block
# list; of several, the first that closes its `]` is read. An inline item keeps
# a `#` and an empty one is dropped; a block item ends at its `#`.
fm_list_block_v() {
  local __fml_block="$2" __fml_key="$3" __fml_line __fml_rest __fml_item __fml_nl=$'\n'
  local __fml_inline=0 __fml_content="" __fml_closed=0 __fml_capture=0 __fml_items="" __fml_sep=""
  printf -v "$1" '%s' ''
  [ -n "$__fml_block" ] || return 0
  while IFS= read -r __fml_line; do
    case "$__fml_line" in
      "$__fml_key:"*)
        _fm_trim_v __fml_rest "${__fml_line#"$__fml_key:"}"
        case "$__fml_rest" in
          \[*)
            __fml_inline=1
            if [ "$__fml_closed" -eq 0 ]; then
              case "$__fml_rest" in
                *\]*)
                  __fml_closed=1
                  __fml_content=${__fml_rest#\[}
                  __fml_content=${__fml_content%\]*}
                  ;;
              esac
            fi
            ;;
        esac
        ;;
    esac
    case "$__fml_capture" in
      0)
        case "$__fml_line" in
          "$__fml_key:"*)
            case "$__fml_rest" in
              '' | \#*) __fml_capture=1 ;;
            esac
            ;;
        esac
        ;;
      1)
        case "$__fml_line" in
          "  - "*)
            __fml_item=${__fml_line#"  - "}
            __fml_item=${__fml_item%%#*}
            _fm_trim_v __fml_item "$__fml_item"
            _fm_unquote_v __fml_item "$__fml_item"
            __fml_items="$__fml_items$__fml_sep$__fml_item"
            __fml_sep=$__fml_nl
            ;;
          *) __fml_capture=2 ;;
        esac
        ;;
    esac
  done <<EOF
$__fml_block
EOF
  if [ "$__fml_inline" -eq 1 ]; then
    __fml_items=""
    __fml_sep=""
    while [ -n "$__fml_content" ]; do
      __fml_item=${__fml_content%%,*}
      case "$__fml_content" in
        *,*) __fml_content=${__fml_content#*,} ;;
        *) __fml_content="" ;;
      esac
      _fm_trim_v __fml_item "$__fml_item"
      _fm_unquote_v __fml_item "$__fml_item"
      [ -n "$__fml_item" ] || continue
      __fml_items="$__fml_items$__fml_sep$__fml_item"
      __fml_sep=$__fml_nl
    done
  fi
  printf -v "$1" '%s' "$__fml_items"
}

# fm_list <file> <key> — print list items one per line, quotes stripped.
# Supports inline `key: [a, b]` and block `key:\n  - a\n  - b` forms.
fm_list() {
  fm_list_block "$(fm_block "$1")" "$2"
}

# fm_keys <file> — print top-level keys, one per line, in document order.
fm_keys() {
  local file="$1"
  fm_block "$file" | sed -n 's/^\([a-z_][a-z_]*\):.*/\1/p'
}

# fm_body_start <file> — print the 1-based line number of the first line
# after the closing `---`. Prints 1 when the file has no (valid) frontmatter,
# so callers can scan the whole file as the body.
fm_body_start() {
  local file="$1"
  awk '
    NR == 1 {
      if ($0 != "---") { print 1; found = 1; exit }
      in_block = 1; next
    }
    in_block && $0 == "---" { print NR + 1; found = 1; exit }
    END { if (!found) print 1 }
  ' "$file"
}

# --- writers -----------------------------------------------------------------
# Writers rewrite the whole file through a temporary and `mv`
# (convention-shell): a crash must not leave a half-written document. Keys and
# values reach awk as variables and are compared literally — never
# interpolated into a `sed` expression or a regex, because `paths` items are
# globs full of metacharacters (convention-shell, ADR-0008). A multi-line
# replacement is handed over as a *file* awk reads with getline, not as a
# `-v` assignment: BSD awk rejects a raw newline inside one.

# fm_is_list <file> <key> — exit 0 when <key> is written in either list form,
# inline `key: [...]` or a block `key:` with `  - ` items under it.
fm_is_list() {
  local file="$1" key="$2"
  fm_block "$file" | grep -c -E "^${key}:[[:space:]]*(\[|(#.*)?$)" >/dev/null
}

# _fm_valid_item <item> — exit 0 when the item can be read back unchanged.
# `#` cannot: fm_list strips a trailing comment before it strips the
# surrounding quotes, so a quoted `#` loses everything from the `#` onward
# *and* its closing quote. The grammar has no escape for it
# (schemas/frontmatter.md), so the writer refuses instead of corrupting.
_fm_valid_item() {
  case "$1" in
    *'#'*) return 1 ;;
    *) return 0 ;;
  esac
}

# _fm_valid_scalar <value> — exit 0 when the value can be written as a scalar
# and read back unchanged. `#` cannot, for the reason _fm_valid_item gives for
# list items: fm_get strips a trailing comment *before* it strips the
# surrounding quotes, so quoting does not rescue it. `"` cannot either — the
# grammar has no escape (schemas/frontmatter.md), so an inner quote ends the
# value for any real YAML parser. Both are refused rather than corrupted.
_fm_valid_scalar() {
  case "$1" in
    *'#'* | *'"'*) return 1 ;;
    *) return 0 ;;
  esac
}

# _fm_quote_scalar <value> — print the value ready to follow `key: `, quoted
# when plain YAML would read it as anything but this string.
#
# jig's own reader is forgiving: fm_get takes everything after the first
# `key: `, so `summary: Terms: a, b` reads back correctly here and breaks in
# every real YAML parser, which sees a nested mapping. The frontmatter is meant
# to be read by both, so the writer quotes what YAML requires and nothing more.
# Deliberately *not* quoted: values that merely look numeric or boolean. Doing
# so would rewrite `date: 2026-09-09` as a quoted string on every touch, which
# is churn for a field no caller reads as anything but text.
_fm_quote_scalar() {
  local value="$1" first="${1:0:1}"
  case "$first" in
    '-' | '?' | ':' | ',' | '[' | ']' | '{' | '}' | '&' | '*' | '!' | '|' \
      | '>' | "'" | '"' | '%' | '@' | '`' | ' ')
      printf '"%s"' "$value"
      return 0
      ;;
  esac
  case "$value" in
    '' | *': '* | *: | *' ') printf '"%s"' "$value" ;;
    *) printf '%s' "$value" ;;
  esac
}

# _fm_replace <file> — replace <file> with stdin, atomically. Refuses to write
# an empty document, so a failing awk upstream cannot truncate knowledge.
_fm_replace() {
  local file="$1" tmp="$1.tmp.$$"
  jig_cleanup_add "$tmp"
  cat > "$tmp"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    printf 'jig: error: frontmatter: refusing to write an empty document: %s\n' \
      "$file" >&2
    return 1
  fi
  mv "$tmp" "$file"
  # Every frontmatter write lands here, so this is where it raises the clone's
  # revision (jig_record_changed, common.sh) — except on the file
  # `knowledge new` is still building (`<doc>.new.<pid>`), which is not a
  # record until km_new moves it into place and records that. This parser is
  # also sourced alone, by its own tests, where there is no clone to count in.
  case "$file" in
    *.new.[0-9]*) return 0 ;;
  esac
  if type jig_record_changed >/dev/null 2>&1; then jig_record_changed; fi
}

# fm_set <file> <key> <value> — set a scalar key inside the frontmatter,
# replacing the existing line or appending just before the closing `---`.
# Scalars only: it refuses a key that currently holds a list, because
# overwriting `paths:` with a scalar would leave its `  - ` items orphaned
# under a key that no longer claims them, and every later read of that
# document would mis-parse them.
fm_set() {
  local file="$1" key="$2" value="$3"
  fm_has "$file" || return 1
  if fm_is_list "$file" "$key"; then
    printf 'jig: error: frontmatter: %s holds a list; use fm_list_set\n' "$key" >&2
    return 1
  fi
  if ! _fm_valid_scalar "$value"; then
    printf 'jig: error: frontmatter: %s may not contain '"'"'#'"'"' or '"'"'"'"'"': %s\n' \
      "$key" "$value" >&2
    return 1
  fi
  value=$(_fm_quote_scalar "$value")
  awk -v key="$key" -v value="$value" '
    NR == 1 { print; in_block = 1; next }
    in_block && $0 == "---" {
      if (!done) print key ": " value
      print; in_block = 0; done = 1; next
    }
    in_block && index($0, key ":") == 1 {
      if (!done) { print key ": " value; done = 1 }
      next
    }
    { print }
  ' "$file" | _fm_replace "$file"
}

# _fm_quote_item <item> — quote an item containing a character that reads as
# syntax, so `paths` globs come out `- "src/**"` while plain `domains` tags
# come out `- flow`, which is how the existing documents are written.
# `#` is deliberately absent: quoting does not save it (see _fm_valid_item),
# so it is rejected before reaching here rather than quoted into a lie.
_fm_quote_item() {
  case "$1" in
    *[][*?{},:\ ]*) printf '"%s"' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_list_set <file> <key> — read items from stdin (one per line) and write
# them as a block list, or `key: []` when stdin holds none. Replaces the key
# wherever it already is (inline or block), otherwise appends it before the
# closing `---`.
fm_list_set() {
  local file="$1" key="$2" items item rfile rc
  fm_has "$file" || return 1
  items=$(sed '/^$/d')

  while IFS= read -r item; do
    [ -n "$item" ] || continue
    _fm_valid_item "$item" && continue
    printf 'jig: error: frontmatter: %s item may not contain "#": %s\n' \
      "$key" "$item" >&2
    return 1
  done < <(printf '%s\n' "$items")

  rfile="${TMPDIR:-/tmp}/jig-fm-render.$$"
  if [ -z "$items" ]; then
    printf '%s: []\n' "$key" > "$rfile"
  else
    printf '%s:\n' "$key" > "$rfile"
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      printf '  - %s\n' "$(_fm_quote_item "$item")" >> "$rfile"
    done < <(printf '%s\n' "$items")
  fi

  awk -v key="$key" -v rfile="$rfile" '
    function emit(   line) {
      while ((getline line < rfile) > 0) print line
      close(rfile)
    }
    NR == 1 { print; in_block = 1; next }
    in_block && $0 == "---" {
      if (!done) emit()
      print; in_block = 0; done = 1; next
    }
    in_block && skipping {
      if ($0 ~ /^  - /) next
      skipping = 0
    }
    in_block && index($0, key ":") == 1 {
      emit(); done = 1; skipping = 1; next
    }
    { print }
  ' "$file" | _fm_replace "$file"
  rc=$?
  rm -f "$rfile"
  return "$rc"
}

# fm_list_add <file> <key> <item> — append an item unless it is already
# present. Returns 1 (nothing written) when the list already holds it.
fm_list_add() {
  local file="$1" key="$2" item="$3" current
  current=$(fm_list "$file" "$key" | sed '/^$/d')
  case $'\n'"$current"$'\n' in *$'\n'"$item"$'\n'*) return 1 ;; esac
  { printf '%s\n' "$current" | sed '/^$/d'; printf '%s\n' "$item"; } \
    | fm_list_set "$file" "$key"
}

# fm_list_remove <file> <key> <item> — drop an item. Returns 1 (nothing
# written) when the list does not hold it.
fm_list_remove() {
  local file="$1" key="$2" item="$3" current remaining
  current=$(fm_list "$file" "$key" | sed '/^$/d')
  case $'\n'"$current"$'\n' in *$'\n'"$item"$'\n'*) ;; *) return 1 ;; esac
  # `|| true`: removing the last item leaves grep with nothing to select, and
  # its exit 1 would otherwise become the function's status under `pipefail`
  # — reporting "nothing removed" for a removal that did happen.
  remaining=$(printf '%s\n' "$current" | grep -vxF -- "$item" || true)
  printf '%s\n' "$remaining" | fm_list_set "$file" "$key"
}
