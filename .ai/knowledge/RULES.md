# Rules and Invariants

Normative requirements for this project. Rules say how work must be done; invariants say
what must always hold. Both are enforced in review and verification. Area-specific rules
are added as sections of this file.

## Invariants

- No `App\*` reference anywhere in the package. Enforced: `tests/BoundaryTest.php`.
- Every operator screen is reachable only through its surface middleware (`AllowPulse`, `AllowTelescope`, `AllowLogs`,
  `AllowHealth`), which asks
  the contract and answers 404 on no, on an exception and when nothing is bound. Enforced: `tests/AccessTest.php`.
- Pulse, Telescope and log-viewer tables/files are never written to a tenant schema; the migrations run on `landlord`.
  Enforced: `tests/StorageTest.php`, `tests/TelescopeRecordingTest.php`.
- A secret in a request (query, body, header, cookie, support-entry token, webhook hash) leaves nothing in
  `pulse_*`. Enforced: `tests/PrivacyTest.php`.
- Telescope never stores the support-entry token, listed credentials (body, query string, headers, cookies) or a bot
  token in a URL, in any environment, in new entries or in later updates. Enforced: `tests/TelescopePrivacyTest.php`.
- Telescope records nothing and has no routes unless `monitoring.telescope.enabled`; Telescope's own
  `TELESCOPE_ENABLED` does not decide. Enforced: `tests/DefaultsTest.php`.

## Rules

- **Installation health is rendered, never computed, here.** The figures come only from Foundation's
  `InstallationHealthInterface` (`HealthReader`): unbound means "not available in this version of Core", a throw means
  "could not be read", an unknown enum case shows as unknown, a missing service as "not monitored", a null figure as
  "not measured" — never folded into up or 0. The health card is on a screen of another surface (Pulse's dashboard),
  so it asks the contract for `OperatorSurface::Health` itself on every render and reads nothing without it.
  Enforced: `tests/HealthTest.php`.

- A screen middleware that Livewire must repeat takes no parameters (Livewire drops them). Enforced: the
  Livewire update tests in `tests/AccessTest.php`.
- Package settings are read while the provider registers (Testbench registers providers before
  `defineEnvironment`): tests set switches through the process environment.
- New third-party screens arrive with their own surface, their own middleware class and the same
  tests: refused by the contract, refused on a Livewire/API sub-request, secrets masked.

- **Privacy policy of the recorders.** Pulse's own recorders keep counters and route patterns; this package adds:
  ignored request paths (`monitoring.pulse.ignore`, domain-aware), outgoing calls kept as their host only, cache
  keys kept by their first segment. A new or newly enabled recorder arrives with a test that a secret does not
  reach `pulse_*`. Known and accepted: slow SQL text may hold hand-written literals; exception locations name files.
- **Error reports carry no personal data and are off without a DSN.** `ErrorReporting` wires sentry-laravel only
  when `SENTRY_LARAVEL_DSN` is set and forces the privacy options whatever the environment says (no PII, request
  bodies, headers, cookies, SQL bindings, logs or input-carrying breadcrumbs); the config stays cacheable (static
  callables, never closures). `EventScrubber` keeps only method and path, scrubs sensitive keys, replaces every
  database exception message with SQLSTATE plus placeholder SQL, also where a wrapper such as `ViewException`
  copied it, and drops the event if it fails. `JobContext` is a deliberate singleton (worker state reset on
  `JobProcessed`, `Looping`, `WorkerStopping`). Moved here from fapost/saas, where it was reviewed (saas#119).
  (`tests/ErrorReporting`.)
- **Pulse resolves no users from a table.** The `ResolvesUsers` binding is `NeutralUsers` (a label made of the id,
  no query, no name/e-mail/avatar) unless `monitoring.pulse.resolve_users` says `true` (Pulse's own lookup) or gives
  a callable; the application's `Pulse::users()` rebinds later and wins. Reason: users live in tenant schemas, absent
  on the platform host. A card that needs names gets them through that setting, never by a query of this package's
  own into a table it does not own. Enforced: `tests/UsersTest.php` (a schema without `users`).
- The migration's `down()` is empty on purpose (a tenant-side rollback would drop the installation's Pulse data
  from `landlord`); `up()` creates each table only if missing. The DDL is a copy of Pulse's: on a Pulse upgrade
  that changes its schema, add a new migration with the change.
- `viewPulse` is defined after boot (`booted`) so that no other definition wins; the route middleware, not the
  gate, is the guarantee (a host `Gate::before` cannot bypass `AllowPulse`).
- The log viewer's assets are served inline by the viewer: no publish step is needed in an image.
- **Telescope's masking lives at the storage, not in a filter.** `RedactingEntriesRepository` (Telescope's database
  repository, subclassed and bound to its three contracts) masks `store()` and `update()`: a Telescope filter sees
  new entries only, and a failed job's exception arrives as an update. Telescope's hide lists are fed from
  `Redactor`'s constants plus `monitoring.telescope.hidden.*` (additions only). Known and accepted: matching is by
  top-level (or dot-path) key; nested keys, job data, mail bodies and SQL bindings are kept under `record_all` or a
  monitored tag. Another storage driver chosen by an installation is not masked by this package.
- **Telescope's static state is set for the last application to win.** `Telescope::auth()` and `viewTelescope` are
  set in `booted` (after a host's `TelescopeApplicationServiceProvider`); filters read the application and config at
  call time (`Container::getInstance()`), never capture them, since Telescope's filters outlive an application.
- The Telescope migration is create-if-missing with an empty `down()` (it adopts tables Core created); the DDL is a
  copy of Telescope 5's. `telescope:prune` is scheduled whether Telescope is on or not (`keep_hours`, 0 = none).
- Do not call `telescope:publish` in an image: it publishes Telescope's config only; its assets are inline.
