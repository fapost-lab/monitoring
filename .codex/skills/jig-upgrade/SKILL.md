---
name: jig-upgrade
description: Bring a project's copy of Jig up to the version on this machine — update the tool when a newer release is out, run `jig upgrade`, do the steps the release asks for by hand, and ship the change as far as the person's git rights allow. Use when the user says "upgrade Jig", "update Jig", "bring Jig up to date", "jig upgrade", or `jig status` says the project's Jig is older than this machine's.
---

# jig-upgrade — one project, up to date

`jig upgrade` does the work and ships it on a branch of its own, as far as `agent.git` allows
([upgrading](https://jig.fapost.in/upgrading)). What it leaves is yours: the tool on the machine,
a refusal to resolve, and the steps a release asks for by hand.

## 1. Look

```
.ai/scripts/jig status --json
```

`upgrade-available` means this project runs an older Jig than the tool (`versions.from`,
`versions.to`). `release-available` means a newer Jig is published than the tool, but it comes from
housekeeping's daily check, and its absence proves nothing: no check yet, or one that failed. Ask the
origin itself:

```
.ai/scripts/jig doctor
```

Its `latest release` line says a newer release is out, this is the newest, or it could not check.

## 2. The tool first

When a newer release is out, run `jig self-update`, then read the status again: the project may
now be behind the new tool. Asked to upgrade Jig, the person asked for this too. When `doctor`
could not check, say so — never "up to date". Nothing newer and no `upgrade-available`: the
project runs the newest Jig, and you stop.

## 3. A dry run, and what would stop it

```
.ai/scripts/jig upgrade --dry-run --json
```

Each line of `would_stop` names its remedy; the remedy is the one that line names, not one you
pick. Do it yourself only where it touches nothing of anyone else's: `jig verify` running here —
wait for it and look again. The others are the person's: uncommitted changes, a started task's
branch checked out here, the `.gitattributes` lines (the team's file). Quote the line and wait.
Their yes allows the remedy that line names and nothing more; stashing or committing their
changes is never yours, yes or no. On autopilot without questions, stop there and report it.

## 4. Upgrade

```
.ai/scripts/jig upgrade --json
```

`outcome`: `upgraded` or `linked` — go on; `staged` — the change waits for the person's commit
(`git commit -F .ai/runtime/upgrade/message`, as the run printed): name it and go on;
`incomplete` — run it once more on the same branch, and report if it is still incomplete;
`nothing-to-do` — done. `git` says how far it went: the pull request and whether it was merged.
Never push, open or merge it yourself: the run did all that `agent.git` allows.

A refusal is `error.code`: `upgrade-blocked` — back to §3; `failed` — report its message as it is.
A failure after the commit leaves the commit and the branch; the push or pull request is then the
person's, not a second run's.

## 5. The steps the release asks for by hand

`manual_steps` lists them. A step that changes files (run a skill, add a key to a profile) is a
task of its own: `jig-task`, T0, after the upgrade has landed. A step about the machine (install
a tool a check needs) — do it when the person's request covers it, otherwise name it.

## 6. Report

From and to, the pull request and whether it merged, each manual step and whether you did it,
and what is still the person's. Several projects: one at a time, each in its own checkout.
