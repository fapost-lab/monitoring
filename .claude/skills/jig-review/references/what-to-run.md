# What a reviewer runs

A review runs checks to test a finding, never to re-prove the change. Four things earn
their time, in this order.

- **`jig verify`, unflagged, once.** It is the evidence, and it already narrows itself to
  whatever the project configured (`verify.full_run`, `schemas/config.md`) and prints the
  mode it ran in. A narrowed report that names its mode is sufficient here. `--full` is not
  the reviewer's flag.
- **Targeted filters on the files a finding names.** A finding is about one thing, so the
  run that tests it is about one thing. Everything wider is noise around the answer.
- **Revert the code and watch the new tests go red.** A test that passes against the fix
  and against its absence tests nothing, and nobody after the reviewer is positioned to
  notice. This is the check that finds real defects.
- **Not the project's raw runner over everything** — `php artisan test`, `phpunit`, `pytest`,
  `npm test` or `tests/run.sh` without a filter. A `jig verify` line that says `full set left to
  CI` is the project's setting at work, not a gap for the reviewer to fill. The runner reads
  no configuration: it does not know `verify.full_run`, so it walks straight past the
  project's own setting, and it cannot name the mode it ran in, which is what makes a
  narrowed report count as evidence.
  The full set belongs to CI, where it runs once per pull request and in parallel across
  platforms.

## Why the rerun is not the safe choice

A suite that passed proves, when run again, that it still passes. The defects that actually
survive a mature suite are of two shapes it cannot see: a test passing against the wrong
fixture, and behaviour with no test at all. The first is found by reading the fixtures, the
second by writing the test that was missing — neither by running the set a second time.

So the prohibition is not about saving minutes. A rerun pays in the currency of confidence
without producing any, and it competes for the machine with the CI pass that is holding the
merge.
