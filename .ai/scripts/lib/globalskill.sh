# The per-user copy of jig-pr-review
# (adr-20261112-the-pr-review-skill-is-installed-per-user).
#
# Reviewing a colleague's pull request needs no project, so this one skill is
# placed where each runtime reads a person's own skills: ~/.claude/skills for
# Claude Code (when ~/.claude exists) and ~/.agents/skills for Codex (when
# ~/.codex exists). A symbolic link into the global framework checkout where
# links can be made, so `jig self-update` moves it along for free; elsewhere
# (Git Bash on Windows copies) a copy carrying a .jig-global marker, which is
# how a later run knows the copy is Jig's to replace or remove.
#
# Sourced by scripts/lib/self-update.sh and by install.sh from the checkout it
# just installed, before any other library exists for it, so it uses nothing
# but bash and the commands git needs anyway: no common.sh helper.
# shellcheck shell=bash

JIG_GLOBAL_SKILL=jig-pr-review
JIG_GLOBAL_SKILL_MARKER=.jig-global

# jig_global_skill_targets — one line per runtime present for this user: the
# path the skill goes to. Nothing for a runtime whose own directory is absent:
# a runtime the person does not use gets no directory made for it.
jig_global_skill_targets() {
  [ -n "${HOME:-}" ] || return 0
  if [ -d "$HOME/.claude" ]; then
    printf '%s\n' "$HOME/.claude/skills/$JIG_GLOBAL_SKILL"
  fi
  if [ -d "$HOME/.codex" ]; then
    printf '%s\n' "$HOME/.agents/skills/$JIG_GLOBAL_SKILL"
  fi
}

# _jig_global_skill_link_of <path> — the target a symbolic link at <path>
# names, with a relative one made absolute against the link's directory.
_jig_global_skill_link_of() {
  local t
  t=$(readlink "$1") || return 1
  case "$t" in
    /*) printf '%s\n' "$t" ;;
    *) printf '%s/%s\n' "$(dirname "$1")" "$t" ;;
  esac
}

# _jig_global_skill_same_dir <a> <b> — both name the same existing directory.
_jig_global_skill_same_dir() {
  local a b
  a=$(cd -P "$1" 2>/dev/null && pwd -P) || return 1
  b=$(cd -P "$2" 2>/dev/null && pwd -P) || return 1
  [ "$a" = "$b" ]
}

# jig_global_skill_owner <path> <source> — what is at <path>: `none` (nothing),
# `link` (a symbolic link to <source>'s skill), `copy` (a directory with Jig's
# marker), or `foreign` (anything else — never touched).
jig_global_skill_owner() {
  local path="$1" source="$2" target
  if [ -L "$path" ]; then
    target=$(_jig_global_skill_link_of "$path") || { printf 'foreign\n'; return 0; }
    if _jig_global_skill_same_dir "$target" "$source/skills/$JIG_GLOBAL_SKILL"; then
      printf 'link\n'
    else
      printf 'foreign\n'
    fi
  elif [ ! -e "$path" ]; then
    printf 'none\n'
  elif [ -d "$path" ] && [ -f "$path/$JIG_GLOBAL_SKILL_MARKER" ]; then
    printf 'copy\n'
  else
    printf 'foreign\n'
  fi
}

# _jig_global_skill_links_work <dir> — whether `ln -s` makes a real link in
# <dir>. Git Bash on Windows copies instead, unless Developer Mode is on.
_jig_global_skill_links_work() {
  local target="$1/.jig-link-target.$$" probe="$1/.jig-link-probe.$$" ok=1
  mkdir "$target" 2>/dev/null || return 1
  if ln -s "$target" "$probe" 2>/dev/null && [ -L "$probe" ]; then
    ok=0
  fi
  rm -rf "$probe" "$target"
  return "$ok"
}

# _jig_global_skill_copy <source> <path> <version> — a fresh marked copy at
# <path>, built beside it and moved in, so a failed copy never leaves half a
# skill where the runtime reads it.
_jig_global_skill_copy() {
  local source="$1" path="$2" version="$3" tmp old=""
  tmp="$path.jig-tmp.$$"
  rm -rf "$tmp"
  cp -R "$source/skills/$JIG_GLOBAL_SKILL" "$tmp" || { rm -rf "$tmp"; return 1; }
  printf 'source: %s\nversion: %s\n' "$source" "$version" > "$tmp/$JIG_GLOBAL_SKILL_MARKER" \
    || { rm -rf "$tmp"; return 1; }
  # The old copy is moved aside, not deleted, until the new one is in place:
  # a failed move leaves the person the skill they had.
  if [ -e "$path" ]; then
    old="$path.jig-old.$$"
    mv "$path" "$old" || { rm -rf "$tmp"; return 1; }
  fi
  if ! mv "$tmp" "$path"; then
    rm -rf "$tmp"
    [ -z "$old" ] || mv "$old" "$path"
    return 1
  fi
  [ -z "$old" ] || rm -rf "$old"
}

# jig_global_skill_place <source> <version> — place or refresh the skill for
# every runtime present. One line per path on stdout: `pr-review skill:
# <what> <path>`. Never fails the caller: a path it cannot write is reported
# and the next one tried, and foreign content is left exactly as it was.
jig_global_skill_place() {
  local source="$1" version="$2" path owner dir
  [ -d "$source/skills/$JIG_GLOBAL_SKILL" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    owner=$(jig_global_skill_owner "$path" "$source")
    dir=$(dirname "$path")
    case "$owner" in
      link)
        printf 'pr-review skill: linked %s\n' "$path"
        ;;
      foreign)
        printf 'pr-review skill: left alone %s (not installed by Jig)\n' "$path"
        ;;
      none|copy)
        if ! mkdir -p "$dir" 2>/dev/null; then
          printf 'pr-review skill: could not create %s\n' "$dir"
          continue
        fi
        if [ "$owner" = none ] && _jig_global_skill_links_work "$dir" \
          && ln -s "$source/skills/$JIG_GLOBAL_SKILL" "$path" 2>/dev/null; then
          printf 'pr-review skill: linked %s\n' "$path"
        elif _jig_global_skill_copy "$source" "$path" "$version"; then
          printf 'pr-review skill: copied %s (%s)\n' "$path" "$version"
        else
          printf 'pr-review skill: could not write %s\n' "$path"
        fi
        ;;
    esac
  done <<EOF
$(jig_global_skill_targets)
EOF
  return 0
}

# jig_global_skill_installed <source> — the Claude Code path when Jig placed
# the skill there (its link or its marked copy); fails otherwise. Claude Code
# lets a person's own skill win over a project's of the same name, which is
# what `jig status` reports.
jig_global_skill_installed() {
  local path owner
  [ -n "${HOME:-}" ] || return 1
  path="$HOME/.claude/skills/$JIG_GLOBAL_SKILL"
  owner=$(jig_global_skill_owner "$path" "$1")
  case "$owner" in
    link|copy) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}
