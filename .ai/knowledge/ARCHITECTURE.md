# Architecture

High-level map of the system. Describe engineering intent, not implementation:
what the domains are, where the boundaries lie, which direction dependencies may point,
and which constraints and invariants hold system-wide. Anything the code already says
does not belong here.

## Domains

**Operator screens** (`src/`): wires Laravel Pulse, Laravel Telescope and the log viewer into an installation and puts
the operator access contract in front of them. It owns no sign-in, no users and no policy: who may look
is answered by `Fapost\Foundation\Operator\Contracts\OperatorAccessInterface`, bound by Core (default)
or an operator layer (SaaS). It must not know Core's classes or the tenancy mode.

## Boundaries and dependency direction

The package depends on Foundation (contracts) and on third-party Pulse, Telescope and log-viewer (all in `require`:
the package is the optional part, its tools are not); Core and the SaaS
package depend on nothing here. Host-specific wiring (keeping operator routes off tenant hosts, sending a
guest to a sign-in) enters through two configuration lists, `monitoring.middleware` and
`monitoring.before_gate`, by class name; a Foundation host contract was
rejected for v0.1.0 as too wide a change, and stays a candidate.

## Runtime flows

- Browser → host route stack (`monitoring.middleware`, `before_gate`) → `AllowPulse` / `AllowTelescope` / `AllowLogs`
  (contract; 404 on no, error or no binding) → Pulse's own `viewPulse` gate (also asks the contract) → screen.
- Livewire card update → `/livewire/update` → Livewire re-applies the screen's middleware **by class name**,
  parameters dropped: hence one middleware class per surface, never a parameterised one.
- App process → Pulse recorders → Redis stream (`<REDIS_PREFIX>laravel:pulse:ingest`) → `pulse:work` daemon →
  `pulse_*` tables on `landlord`.
- App process (request, job, command) → Telescope watchers → `RecordingFilter` (everything only under `record_all`)
  → `RedactingEntriesRepository` (masks new entries and later updates) → `telescope_*` tables on `landlord`;
  `telescope:prune` daily from the installation's scheduler.

## System-wide constraints and invariants

- Fail closed: any doubt about access is a 404, never a 403 that confirms the screen exists.
- Pulse tables live on the `landlord` connection, never in a tenant schema (`pulse_*`, names fixed by Pulse).
- Pulse keeps counters and route patterns only; query strings, bodies, headers and cookies are not stored.
- The log viewer is off by default and read-only when on (no download, no delete).
- Telescope is off by default in every environment (`monitoring.telescope.enabled` overrides Telescope's own
  switch); when on, its entries live on `landlord` and pass the redactor. Horizon is not part of this package:
  it stays in Core behind the same contract.
- FaPost's secret-bearing paths and parameter names (support entry, webhook ingress, channel tokens) are known to
  this package as data, not through Core's classes or a Foundation contract: one privacy policy for every recorder,
  proved by this package's tests; an installation may add to the lists, never remove.
