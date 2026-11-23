#!/usr/bin/env bash
# Verification for the php profile. Called by `jig verify` from the
# repository root. Exit 0 = pass, 1 = fail, 2 = skip (no check could run).
# Prints one line per check: "php: <check>: pass|fail|skip (<note>)".
#
# Tools come from the project's own environment only (adr-20260918-profiles-narrow-per-check-with-project-tools): phpunit,
# pest, phpstan and pint are read from vendor/bin/ and nowhere else — a
# global install would check the project with another version and other
# rules. composer is the stack's own toolchain and comes from PATH.
#
# Narrowing (ADR-0041, adr-20260918-profiles-narrow-per-check-with-project-tools), per check: phpstan and pint each lint the
# changed .php files; phpstan runs in full when its own configuration
# changed, or under `verify.full_run: ci` leaves that to CI. phpunit/pest run
# the test files the changed paths map to — a
# changed *Test.php itself, or any FooTest.php under tests/ for a changed
# Foo.php — and everything when a path maps to nothing or a file that can
# affect any test (composer.json/lock, phpunit.xml*, and what a PHP framework
# loads on every request: routes/, config/, database/, bootstrap/) changed. composer
# validate is not narrowable by files: in a scoped run it runs only when
# composer.json or composer.lock changed, and skips with a reason otherwise;
# in a full run it always runs.
#
# Checks by role (`checks:` in profile.yaml): tests (phpunit or pest), static
# (phpstan), style (pint), manifest (composer validate). Every check answers
# to its role: when a profile in the same run declares `covers: [php:<role>]`
# and runs that check itself, jig verify hands the check over and jp_covered
# prints the skip. This profile names its checks and nothing about who covers
# them.
#
# The test rule is not "anything that is not .php needs no test". What decides
# is whether a path can change the result of the test run, which runs PHP: a
# front-end source is neither bundled nor served by it, while the build that
# produces the assets a browser test loads is a different matter and keeps the
# full set. The two lists below draw that line; what neither describes still
# runs everything, so an unrecognised path costs time rather than coverage
# (ADR-0013).
set -eu
set -o pipefail

# shellcheck source=../../scripts/lib/profile.sh
. "$(dirname "$0")/../../scripts/lib/profile.sh"

jp_begin php

PHP_WHERE="not found in vendor/bin"

# _php_tool <name> — the path of <name> in vendor/bin/, Unix and Windows
# layouts both probed by what exists, never by OS name (ADR-0037).
_php_tool() {
  local name="$1" b
  for b in "" .bat .exe; do
    if [ -f "vendor/bin/$name$b" ]; then
      printf 'vendor/bin/%s%s\n' "$name" "$b"
      return 0
    fi
  done
  return 0
}

# _php_is_test <path> — a PHPUnit/Pest test file by the stack's own naming
# convention.
_php_is_test() {
  case "${1##*/}" in
    *Test.php) return 0 ;;
  esac
  return 1
}

# _php_tests_named <stem> — the project's test files under tests/ named
# after a module. Not inlined into a `$( )`: bash 3.2 misparses a `case`
# written there.
_php_tests_named() {
  local g
  while IFS= read -r g; do
    case "$g" in
      tests/*) ;;
      *) continue ;;
    esac
    case "${g##*/}" in
      "${1}Test.php") printf '%s\n' "$g" ;;
    esac
  done < <(jp_files)
  return 0
}

# Files whose change can alter the result of any test: the dependency
# manifest/lock (autoloading), PHPUnit's own configuration, and the directories
# a PHP framework loads on every request — routes, configuration, migrations
# and seeders, its bootstrap — which no test is named after.
PHP_TEST_ALL_GLOBS="composer.json composer.lock phpunit.xml* routes/* config/* database/* bootstrap/*"

# Files that define how a project's front end is built: the package manifest,
# its lock file, and the bundler's configuration. A change to one can alter
# every built asset, and a browser test driven by phpunit loads the built
# assets. So the full set runs.
PHP_BUILD_ALL_GLOBS="package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb vite.config.* webpack.mix.js webpack.config.* rollup.config.* tailwind.config.* postcss.config.*"

# Front-end sources. The test run neither bundles nor serves them, so changing
# one cannot change what a test observes. Two kinds of path are excluded and
# fall through to the rules below, because for them it can: public/ holds what
# a browser test actually loads (the built asset, not this source), and a file
# under tests/ may be a fixture or a snapshot a test asserts on.
PHP_FRONTEND_GLOBS="*.vue *.svelte *.js *.mjs *.cjs *.jsx *.ts *.mts *.cts *.tsx *.css *.scss *.sass *.less *.styl resources/images/* resources/fonts/*"
PHP_FRONTEND_NOT_GLOBS="public/* tests/*"

# _php_builtin <path> — the tests a changed path needs: itself for a test
# file, the tests/*Test.php files named after a module, ALL for a
# project-wide file or anything that maps to nothing, nothing for
# documentation.
_php_builtin() {
  local f="$1" g stem hits
  if jp_path_matches "$f" "$PHP_TEST_ALL_GLOBS"; then
    printf 'ALL\n'
    return 0
  fi
  case "$f" in
    *.md|*.rst|docs/*|.ai/*) return 0 ;;
  esac
  # Before the front-end list, not after it: vite.config.ts matches *.ts
  # there, and the build has to win over the extension.
  if jp_path_matches "$f" "$PHP_BUILD_ALL_GLOBS"; then
    printf 'ALL\n'
    return 0
  fi
  if ! jp_path_matches "$f" "$PHP_FRONTEND_NOT_GLOBS" \
    && jp_path_matches "$f" "$PHP_FRONTEND_GLOBS"; then
    return 0
  fi
  case "$f" in
    *.php) ;;
    *) printf 'ALL\n'; return 0 ;;
  esac
  if _php_is_test "$f"; then
    printf '%s\n' "$f"
    return 0
  fi
  stem=${f##*/}
  stem=${stem%.php}
  hits=$(_php_tests_named "$stem")
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
  else
    printf 'ALL\n'
  fi
  return 0
}

# _php_all_reason <path> — why the full set runs, for the path
# jp_decide_cause named. "not narrowable" was one shrug for four different
# situations, and the person reading it could not tell their package.json from
# a class no test is named after. An empty <path> means the project's own map
# asked for the full set; that line's author knows why, so the old wording
# stands rather than a guess at their reason.
_php_all_reason() {
  local f="$1"
  if [ -z "$f" ]; then
    printf 'not narrowable\n'
  elif jp_path_matches "$f" "$PHP_BUILD_ALL_GLOBS"; then
    printf '%s changes the asset build, which browser tests load\n' "$f"
  elif jp_path_matches "$f" "$PHP_TEST_ALL_GLOBS"; then
    printf '%s can affect any test\n' "$f"
  else
    case "$f" in
      *.php) printf 'no test is named after %s\n' "$f" ;;
      *) printf 'the profile cannot map %s to tests\n' "$f" ;;
    esac
  fi
  return 0
}

# --- tests: phpunit / pest ------------------------------------------------
#
# Every check is named by its role, the tool inside the label
# (`tests (phpunit)`), and its command line comes from the profile's check
# table through jp_check_cmd (schemas/profile.md, Check table): the words
# below are the defaults the table leaves to this script — the runner chosen
# on the fly and the path of each vendor/bin tool. Every fallback to the full
# set (ALL, a filter that selects nothing, a changed configuration) is a
# `full` command line.

# _php_explain_cmd <role> <label> <selection> <default-cmd>... — under
# `--explain`, exit 0 when the check table can build the command line the
# planned run would use: `narrowed` for a selection of files, `full`
# otherwise. When it cannot, jp_check_cmd has printed the check's PLAN line.
_php_explain_cmd() {
  local role="$1" label="$2" selection="$3"
  shift 3
  if jp_scoped && [ -n "$selection" ] && [ "$selection" != ALL ]; then
    jp_check_cmd "$role" "$label" narrowed "$@"
  else
    jp_check_cmd "$role" "$label" full "$@"
  fi
}

test_bin=$(_php_tool phpunit)
test_check=phpunit
if [ -z "$test_bin" ]; then
  test_bin=$(_php_tool pest)
  test_check=pest
fi
# With neither runner, the check's lines name it phpunit.
[ -n "$test_bin" ] || test_check=phpunit
test_label="tests ($test_check)"

if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
  if jp_covered tests "$test_label"; then
    :
  elif [ -z "$test_bin" ]; then
    jp_plan "$test_label" skip "$PHP_WHERE"
  else
    jp_select _php_builtin
    filters=$JP_SELECTION
    if [ -n "$filters" ] && [ "$filters" != ALL ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ ! -e "$f" ]; then filters=ALL; break; fi
      done <<EOF
$filters
EOF
    fi
    if [ "$filters" = ALL ]; then
      why=$(_php_all_reason "$(jp_decide_cause _php_builtin)")
    else
      why=
    fi
    if jp_scoped && [ -z "$filters" ]; then
      jp_plan_select "$test_label" "$filters" "test files" "$why"
    elif _php_explain_cmd tests "$test_label" "$filters" "$test_bin"; then
      jp_plan_select "$test_label" "$filters" "test files" "$why"
    fi
  fi

  for role in static style; do
    case "$role" in
      static) check=phpstan ;;
      style) check=pint ;;
    esac
    label="$role ($check)"
    if jp_covered "$role" "$label"; then
      continue
    fi
    tool=$(_php_tool "$check")
    if [ -z "$tool" ]; then
      jp_plan "$label" skip "$PHP_WHERE"
    elif [ "$check" = phpstan ] && jp_scoped && jp_changed_any phpstan.neon phpstan.neon.dist; then
      if jp_check_cmd "$role" "$label" full "$tool"; then
        jp_plan_full "$label" "phpstan configuration changed"
      fi
    elif jp_scoped; then
      files=$(jp_changed php)
      if [ -z "$files" ]; then
        jp_plan "$label" skip "no changed .php files"
      elif jp_check_cmd "$role" "$label" narrowed "$tool"; then
        jp_plan "$label" filtered "changed .php files: $(printf '%s\n' "$files" | paste -sd, -)"
      fi
    elif jp_check_cmd "$role" "$label" full "$tool"; then
      jp_plan "$label" full "full scope"
    fi
  done

  label="manifest (composer validate)"
  if jp_covered manifest "$label"; then
    :
  elif ! jp_have composer; then
    jp_plan "$label" skip "composer not found in PATH"
  elif jp_scoped && ! jp_changed_any composer.json composer.lock; then
    jp_plan "$label" skip "composer.json/composer.lock not changed"
  elif jp_check_cmd manifest "$label" full composer; then
    jp_plan "$label" full "manifest validation"
  fi
  exit 0
fi

if jp_covered tests "$test_label"; then
  :
elif [ -z "$test_bin" ]; then
  jp_skip "$test_label" "$PHP_WHERE"
else
  v=$(jp_version "$test_bin" --version)
  if ! jp_scoped; then
    if jp_check_cmd tests "$test_label" full "$test_bin"; then
      jp_run "$test_label" "$v" "${JP_CMD[@]}"
    fi
  else
    jp_select _php_builtin
    filters=$JP_SELECTION
    if [ -z "$filters" ]; then
      jp_skip "$test_label" "scope: no changed file maps to a test"
    elif [ "$filters" = ALL ]; then
      why=$(_php_all_reason "$(jp_decide_cause _php_builtin)")
      jp_full_left_to_ci "$test_label" "$why" \
        || if jp_check_cmd tests "$test_label" full "$test_bin"; then
          jp_run "$test_label" "$v, scope: $why, ran full set" "${JP_CMD[@]}"
        fi
    else
      IFS='
'
      set -f
      # shellcheck disable=SC2086
      set -- $filters
      set +f
      IFS=$' \t\n'
      if missing=$(jp_first_missing "$@"); then
        jp_full_left_to_ci "$test_label" "filter '$missing' selects no tests" \
          || if jp_check_cmd tests "$test_label" full "$test_bin"; then
            jp_run "$test_label" "$v, scope: filter '$missing' selects no tests, ran full set" "${JP_CMD[@]}"
          fi
      elif jp_check_cmd tests "$test_label" narrowed "$test_bin" -- "$@"; then
        jp_run "$test_label" "$v, scope: $# test files$JP_SELECTION_NOTE" "${JP_CMD[@]}"
      fi
    fi
  fi
fi

# --- static: phpstan ---------------------------------------------------------

label="static (phpstan)"
if jp_covered static "$label"; then
  :
elif phpstan=$(_php_tool phpstan); [ -z "$phpstan" ]; then
  jp_skip "$label" "$PHP_WHERE"
else
  v=$(jp_version "$phpstan" --version)
  if jp_scoped && ! jp_changed_any phpstan.neon phpstan.neon.dist; then
    files=$(jp_changed php)
    if [ -z "$files" ]; then
      jp_skip "$label" "scope: no changed .php files"
    else
      n=$(printf '%s\n' "$files" | grep -c .)
      # One argument per line, so a path with a space stays one path.
      IFS='
'
      set -f
      # shellcheck disable=SC2086
      set -- $files
      set +f
      IFS=$' \t\n'
      if jp_check_cmd static "$label" narrowed "$phpstan" -- "$@"; then
        jp_run "$label" "$v, scope: $n files" "${JP_CMD[@]}"
      fi
    fi
  elif jp_scoped; then
    jp_full_left_to_ci "$label" "phpstan configuration changed" \
      || if jp_check_cmd static "$label" full "$phpstan"; then
        jp_run "$label" "$v, scope: phpstan configuration changed, whole project" "${JP_CMD[@]}"
      fi
  elif jp_check_cmd static "$label" full "$phpstan"; then
    jp_run "$label" "$v" "${JP_CMD[@]}"
  fi
fi

# --- style: pint -------------------------------------------------------------

label="style (pint)"
if jp_covered style "$label"; then
  :
elif pint=$(_php_tool pint); [ -z "$pint" ]; then
  jp_skip "$label" "$PHP_WHERE"
else
  v=$(jp_version "$pint" --version)
  if jp_scoped; then
    files=$(jp_changed php)
    if [ -z "$files" ]; then
      jp_skip "$label" "scope: no changed .php files"
    else
      n=$(printf '%s\n' "$files" | grep -c .)
      IFS='
'
      set -f
      # shellcheck disable=SC2086
      set -- $files
      set +f
      IFS=$' \t\n'
      if jp_check_cmd style "$label" narrowed "$pint" -- "$@"; then
        jp_run "$label" "$v, scope: $n files" "${JP_CMD[@]}"
      fi
    fi
  elif jp_check_cmd style "$label" full "$pint"; then
    jp_run "$label" "$v" "${JP_CMD[@]}"
  fi
fi

# --- manifest: composer validate ---------------------------------------------
# Not narrowable by files: composer.json describes the whole project. Runs
# always in full mode; in a scoped run, only when the manifest or lock file
# it validates actually changed.

label="manifest (composer validate)"
if jp_covered manifest "$label"; then
  :
elif jp_have composer; then
  v=$(jp_version composer --version)
  if jp_scoped && ! jp_changed_any composer.json composer.lock; then
    jp_skip "$label" "scope: composer.json/composer.lock not changed"
  elif jp_check_cmd manifest "$label" full composer; then
    jp_run "$label" "$v" "${JP_CMD[@]}"
  fi
else
  jp_skip "$label" "composer not found in PATH"
fi

jp_end
