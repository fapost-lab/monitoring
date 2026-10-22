# Release notes — what the notes task checks

The notes task writes the project's release pages — changelog, upgrade guide, known issues,
roadmap — for everything between the last release and the epic: the epic's tasks and whatever
reached the default branch directly. Only the pages the project has: a page it does not keep —
no known issues, no roadmap, no user documentation at all — is not created by the release. Say in
the pull request which ones are missing; whether to start one is the person's call. List the
changes from git, not from memory:

```
git log --first-parent --merges <last-tag>..HEAD
```

A pull request's title and body are claims; its diff is what happened (`gh pr diff <n>` or
`git show`). Every line below is checked against the diff.

- **Claims.** Each changelog line says what a user notices, and the diff shows it. Leave out
  what no user notices (the project's own CI, test fixtures) and say in the pull request that you
  did.
- **Numbers.** Only measured ones, with what was measured. Two measurements are never merged
  into one figure.
- **Proof.** Say how each claim was proven: on the real thing, or on a stand-in. A stand-in is
  named as one.
- **Known issues and roadmap.** An entry the release fixes is removed, even when the pull request
  that fixed it did not remove it. An entry it only narrows is rewritten. A fault the release
  introduced or a diff uncovered is added. The roadmap moves what was done out and says what comes
  next; an item a pull request quietly made obsolete goes too.
- **Every other page.** The changelog is not the release's only page. Walk the rest of the
  project's user documentation against the diffs: a page that describes behaviour the release
  changed is corrected, a capability it added gets a place where a user will look for it, and a
  passage it made pointless is cut. List in the pull request the pages you walked and left alone.
- **Upgrade claims.** Checked on every path a user upgrades by. Where an old copy of the tool runs
  the upgrade and a new one runs afterwards (in Jig: the project's `.ai/scripts/jig`, which still
  runs the old code, and the global `jig` after `self-update`), a claim true on one path can be
  false on the other.
- **Release checklists.** For each part the project releases with a checklist of its own (in Jig:
  the installer — `install.sh`, `install.ps1`, `scripts/jig.cmd` — and
  `.github/WINDOWS_RELEASE_CHECKLIST.md`), `git diff --quiet <last-tag> -- <paths>`. Changed: the
  checklist applies. A checklist only a person can walk is said so in the pull request, not
  skipped silently.
- **The level.** Read the diffs against the project's rule again. A "patch" that changes a
  command, a layout or an installer is not a patch. Do not edit the spec: say in the pull request
  which level the diffs call for and why, and leave the change to the person.
