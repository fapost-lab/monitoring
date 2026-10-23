# FaPost Monitoring

`fapost/monitoring` is the optional package for whoever wants **full control over a running
installation**: [Laravel Pulse](https://laravel.com/docs/pulse) (server load, slow requests and
jobs, exceptions, Reverb's connection and message cards), a log viewer, and the operator tools that
come later (Horizon's screens, Telescope) — all behind one switch.

FaPost Core already has a health page of its own in the console (Reverb, the webhook gateway,
the queues) that every installation gets. This package is for the people who run the
installation and want more than that page shows.

> **Status: v0.1.0.** Pulse and an (off by default) log viewer, behind the operator access contract.
> Horizon's access and Telescope are not part of this package yet: Horizon's gate lives in Core, and
> Telescope moves here later. The plan is the spec
> [`installation-health`](https://github.com/fapost-lab/core/tree/main/.ai/specs/installation-health)
> in FaPost Core (phase 3).

## What you get

- **Pulse** at `/pulse`: server load (CPU, memory, disk), slow requests, slow jobs, slow queries, slow
  outgoing requests, exceptions, queues, cache, usage, and Reverb's connection and message cards when
  `laravel/reverb` is installed.
- **Log viewer** at `/log-viewer` ([opcodesio/log-viewer](https://github.com/opcodesio/log-viewer)),
  **off by default** and read-only when on (no download, no delete; a published `monitoring.logs.read_only` can lift it). Its assets are published to `public/vendor/log-viewer` by the `extra.fapost.post-install` step (`log-viewer:publish`) of the image build.

Both answer **404** to anyone the contract does not let in, and to everyone when no contract is bound.

## Install

```
composer require fapost/monitoring
php artisan migrate --database=landlord --force   # the pulse_* tables, never in a tenant schema
```

In FaPost Core, use the composer overlay (`composer.overlay.json` with the package in `require`), as for
the other packages. The package registers itself (Laravel package discovery).

Run two daemons beside the application (the `app` image, a different command each):

| Daemon | Command | How many |
|---|---|---|
| `pulse:work` | `php artisan pulse:work` | one or more; it drains the Redis ingest stream into the tables |
| `pulse:check` | `php artisan pulse:check` | **exactly one** per installation; it measures the server |

```yaml
# Docker Compose, on top of the application's service definition
pulse-work:
  <<: *app
  command: ["php", "artisan", "pulse:work"]
pulse-check:
  <<: *app
  command: ["php", "artisan", "pulse:check"]
  environment:
    PULSE_SERVER_NAME: fapost   # a container's host name changes at every deploy
```

Without `pulse:work` the stream only grows. Rolling the migration back does nothing on purpose (it could run from a tenant's migrate set and would drop the installation's data): drop the `pulse_*` tables by hand to remove them.

Restart both after a deploy (`pulse:restart` signals them).
`pulse:check` inside a container measures what the container sees: good for "is the box healthy", not for
capacity planning.

## Who may open it

Nobody signs in here. Every request is put to Foundation's `OperatorAccessInterface` for the surface
(`OperatorSurface::Pulse`, `::Logs`):

- Core's default: the signed-in staff member who holds the operator-screens permission on a `single`
  installation; closed on a `host` one.
- An operator layer (the SaaS package) binds its own answer for its operators; tenants' administrators
  never pass in `host` mode.
- Anything else, an error, or no binding: **404**.

Two lists in `config/monitoring.php` let the host application add its own steps, by class name:
`middleware` (default `['web']`; put the guard that keeps operator routes off tenant hosts here) and
`before_gate` (put a redirect to the operator's sign-in here). They never replace the contract.

## Configuration

| Setting | Default | Meaning |
|---|---|---|
| `MONITORING_PULSE_ENABLED` | `true` | `false`: no recording, no dashboard route |
| `MONITORING_PULSE_CONNECTION` | `landlord` | where the tables live |
| `PULSE_INGEST_DRIVER` | `redis` | `storage` writes in the request, without the daemon |
| `MONITORING_LOGS_ENABLED` | `false` | the log viewer's routes exist only when `true` |
| `MONITORING_PULSE_ALLOW_CACHED_CLASSES` | `true` | adds the classes Pulse's cards cache to `cache.serializable_classes` (see below) |
| `PULSE_STORAGE_KEEP` | `7 days` | Pulse's own retention (trimmed by `pulse:work`) |

## Pulse's cards and Laravel 13's cache

Laravel 13 unserializes cached objects only if `cache.serializable_classes` lists their class (`false` turns every
object into `__PHP_Incomplete_Class`). Pulse's cards cache their query results, so with `false` a card answers 500 on
its second render ("call a method on an incomplete object"). The setting is one list for all stores (the cache manager
ignores a store's own), so a store of its own for Pulse cannot carry a different one. When Pulse is enabled, the package
therefore adds exactly `Illuminate\Support\Collection`, `stdClass` and `Carbon\CarbonImmutable` to it: `false`
becomes that list, a list is extended, `true` (or no value: everything is allowed already) is left alone. That is a
whitelist, not `true`; the cost is that a writer to your cache store could now plant those three classes, which carry no
behaviour of their own. `MONITORING_PULSE_ALLOW_CACHED_CLASSES=false` leaves the setting alone (list them yourself). Laravel 12
does not read the key. The list reaches only cache stores created after this package registers: a provider registered earlier that touches the cache in its `register()` keeps the old value. A card that caches another class (a custom `Pulse::user()` callback returning models) needs it listed by you.

## What is collected, and what is not

Pulse keeps counters, durations, route **patterns** (`/things/{id}`, not `/things/42`), exception classes with
their locations, job class names and SQL text without bound values. It does not keep request bodies, query
strings, headers or cookies. Beyond Pulse's defaults this package:

- ignores the single-use support entry, the webhook ingress and the log viewer by path
  (`monitoring.pulse.ignore`, also on a route bound to a domain of its own);
- keeps a slow outgoing request as its **host only** (`https://api.example.com/*`): its path or query can carry
  a token;
- keeps a cache key by its **first segment** (`login:*`): keys built from an e-mail, an address or a token stay out.

Slow SQL text may still contain literals written into a query by hand, and exception locations name files and
lines; the user cards show the identifiers of signed-in users that Pulse resolves when the page is drawn.

The tables are part of the database dump a deploy takes; seven days of entries is small at one installation's
scale.

## Logs hold secrets

Exceptions in `storage/logs` carry messages, stack traces and context arrays that can contain tokens,
addresses and personal data. Switch the viewer on only on an installation where everyone the contract lets
in may read all of that, and look at real log content first. It is read-only, but reading is the risk.

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
- Laravel `^12 || ^13`
- `fapost/foundation` `>=0.29`
- Redis and PostgreSQL (or MySQL/SQLite for tests) with the `landlord` connection of FaPost Core; Pulse's
  tables name the connection through `MONITORING_PULSE_CONNECTION`
- `laravel/reverb` (optional) for the two Reverb cards

## Namespace

```
Fapost\Monitoring\   →  src/
```

## Licence

Apache-2.0, like Core, Foundation and Support. The software it wires — Pulse, Horizon, the log
viewer — is MIT-licensed. The FaPost name and logo are covered by the
[Trademark Policy](https://github.com/fapost-lab/core/blob/main/TRADEMARK.md), not by this
licence.
