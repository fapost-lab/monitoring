# Rules and Invariants

Normative requirements for this project. Rules say how work must be done; invariants say
what must always hold. Both are enforced in review and verification. Area-specific rules
are added as sections of this file.

## Invariants

- No `App\*` reference anywhere in the package. Enforced: `tests/BoundaryTest.php`.
- Every operator screen is reachable only through its surface middleware (`AllowPulse`, `AllowLogs`), which asks
  the contract and answers 404 on no, on an exception and when nothing is bound. Enforced: `tests/AccessTest.php`.
- Pulse and log-viewer tables/files are never written to a tenant schema; the migration runs on `landlord`.
  Enforced: `tests/StorageTest.php`.
- A secret in a request (query, body, header, cookie, support-entry token, webhook hash) leaves nothing in
  `pulse_*`. Enforced: `tests/PrivacyTest.php`.

## Rules

- A screen middleware that Livewire must repeat takes no parameters (Livewire drops them). Enforced: the
  Livewire update tests in `tests/AccessTest.php`.
- Package settings are read while the provider registers (Testbench registers providers before
  `defineEnvironment`): tests set switches through the process environment.
- New third-party screens (Telescope next) arrive with their own surface, their own middleware class and the same
  tests: refused by the contract, refused on a Livewire/API sub-request, secrets masked.

- **Privacy policy of the recorders.** Pulse's own recorders keep counters and route patterns; this package adds:
  ignored request paths (`monitoring.pulse.ignore`, domain-aware), outgoing calls kept as their host only, cache
  keys kept by their first segment. A new or newly enabled recorder arrives with a test that a secret does not
  reach `pulse_*`. Known and accepted: slow SQL text may hold hand-written literals; exception locations name files.
- The migration's `down()` is empty on purpose (a tenant-side rollback would drop the installation's Pulse data
  from `landlord`); `up()` creates each table only if missing. The DDL is a copy of Pulse's: on a Pulse upgrade
  that changes its schema, add a new migration with the change.
- `viewPulse` is defined after boot (`booted`) so that no other definition wins; the route middleware, not the
  gate, is the guarantee (a host `Gate::before` cannot bypass `AllowPulse`).
- The log viewer's assets are served inline by the viewer: no publish step is needed in an image.
