# FaPost Monitoring

`fapost/monitoring` is the optional package for whoever wants **full control over a running
installation**: [Laravel Pulse](https://laravel.com/docs/pulse) (server load, slow requests and
jobs, exceptions, Reverb's connection and message cards), access to
[Horizon](https://laravel.com/docs/horizon)'s screens, a log viewer, and the operator tools that
come later — all behind one switch.

FaPost Core already has a health page of its own in the console (Reverb, the webhook gateway,
the queues) that every installation gets. This package is for the people who run the
installation and want more than that page shows.

> **Status: not built yet.** This repository holds the skeleton and the plan. The plan is the
> spec [`installation-health`](https://github.com/fapost-lab/core/tree/main/.ai/specs/installation-health)
> in FaPost Core (phase 3), and the package's own specification will live in `.ai/specs/` here
> once the contracts it depends on exist.

## Design rules

- **No dependency on Core.** `use App\...` is forbidden here. The package depends on
  [`fapost/foundation`](https://github.com/fapost-lab/foundation) contracts and on
  [`fapost/support`](https://github.com/fapost-lab/support) where it needs them, never on Core's
  domain classes.
- **Sign-in is not this package's job.** A Foundation contract answers "may this request look at
  the operator screens"; the package only asks it. Core's default: the owner and admins of the
  tenant on a single-tenant installation, closed on a multi-tenant one until an operator layer
  (the SaaS package, for its operators) gives its own answer.
- **Core works without it.** Nothing in Core checks whether this package is installed.

## Requirements

- PHP `^8.4`
- Laravel `^12`
- `fapost/foundation`

## Namespace

```
Fapost\Monitoring\   →  src/
```

## Licence

Apache-2.0, like Core, Foundation and Support. The software it wires — Pulse, Horizon, the log
viewer — is MIT-licensed. The FaPost name and logo are covered by the
[Trademark Policy](https://github.com/fapost-lab/core/blob/main/TRADEMARK.md), not by this
licence.
