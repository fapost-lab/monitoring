# `jig gh <args>...` — gh as the GitHub account of this clone
# (adr-20261110-a-clone-names-its-github-account). Sourced by the dispatcher.
#
# What an agent runs instead of plain `gh` when it asks GitHub about the
# project's repository: the account is the one `jig task ship` opens the pull
# request as (jig_gh_resolve, common.sh), whichever account is active in gh.
# Jig adds nothing to gh's output and returns gh's exit status. A refusal —
# `github.account` names an account gh does not hold, or several accounts may
# push and none was named — is exit 1 before gh runs.
# bash 3.2 compatible.
# shellcheck shell=bash

cmd_gh() {
  command -v gh >/dev/null 2>&1 || jig_die "gh: the GitHub CLI is not installed (https://cli.github.com)"
  jig_gh_require gh
  jig_gh "$@"
}
