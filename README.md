# FaPost Monitoring

`fapost/monitoring` is the optional package for whoever wants **full control over a running
installation**: [Laravel Pulse](https://laravel.com/docs/pulse) (server load, slow requests and
jobs, exceptions, Reverb's connection and message cards), [Laravel Telescope](https://laravel.com/docs/telescope)
(off by default) and a log viewer (off by default) — all behind one operator access contract.

FaPost Core already has a health page of its own in the console (Reverb, the webhook gateway,
the queues) that every installation gets. This package is for the people who run the
installation and want more than that page shows.

**Horizon is not part of this package.** Its supervisors and its dashboard stay in FaPost Core, behind the
same contract (`OperatorAccessInterface`, surface `OperatorSurface::Horizon`): every installation needs the
queue workers, with or without this package.

> **Status:** Pulse and the log viewer since v0.1.0; Telescope and installation health from the next release. The plan is the spec
> [`installation-health`](https://github.com/fapost-lab/core/tree/main/.ai/specs/installation-health)
> in FaPost Core (phase 3).

## What you get

- **Pulse** at `/pulse`: server load (CPU, memory, disk), slow requests, slow jobs, slow queries, slow
  outgoing requests, exceptions, queues, cache, usage, and Reverb's connection and message cards when
  `laravel/reverb` is installed.
- **Telescope** at `/telescope`, **off by default** in every environment (see [Telescope](#telescope)).
- **Installation health**: the state of live updates (Reverb), the webhook gateway, the webhook registry and the
  queues, with the reason and the figures each probe measured — a card at the top of Pulse's dashboard and a page of
  its own at `/monitoring/health` (see [Installation health](#installation-health)).
- **Log viewer** at `/log-viewer` ([opcodesio/log-viewer](https://github.com/opcodesio/log-viewer)),
  **off by default** and read-only when on (no download, no delete; a published `monitoring.logs.read_only` can lift it). Its assets are published to `public/vendor/log-viewer` by the `extra.fapost.post-install` step (`log-viewer:publish`) of the image build.

Each answers **404** to anyone the contract does not let in, and to everyone when no contract is bound.

## Install

```
composer require fapost/monitoring
php artisan migrate --database=landlord --force   # the pulse_* and telescope_* tables, never in a tenant schema
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
(`OperatorSurface::Pulse`, `::Telescope`, `::Logs`, `::Health`):

- Core's default: the signed-in staff member who holds the operator-screens permission on a `single`
  installation; closed on a `host` one.
- An operator layer (the SaaS package) binds its own answer for its operators; tenants' administrators
  never pass in `host` mode.
- Anything else, an error, or no binding: **404**.

The health card on Pulse's dashboard asks for `OperatorSurface::Health` as well, on every refresh: whoever may open
Pulse but not Health sees no card, and nothing is read for them.

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
| `MONITORING_TELESCOPE_ENABLED` | `false` | Telescope records and has routes only when `true`; Telescope's own `TELESCOPE_ENABLED` no longer decides |
| `MONITORING_TELESCOPE_CONNECTION` | `landlord` | where the `telescope_*` tables live |
| `MONITORING_TELESCOPE_RECORD_ALL` | unset | unset: everything on a `local` machine, elsewhere only what went wrong (see below); `true`/`false` decide it |
| `MONITORING_TELESCOPE_KEEP_HOURS` | `48` | entries older than this are pruned daily; `0` schedules no prune |
| `MONITORING_PULSE_ALLOW_CACHED_CLASSES` | `true` | adds the classes Pulse's cards cache to `cache.serializable_classes` (see below) |
| `PULSE_STORAGE_KEEP` | `7 days` | Pulse's own retention (trimmed by `pulse:work`) |

## Installation health

FaPost Core reports the health of the whole installation through Foundation's `InstallationHealthInterface` (since
Foundation 0.34, `@experimental`); this package only renders it. Each service shows its state — `up`, `down`,
`unknown` (its source could not be read: unreachable, timed out, not configured), `disabled` (switched off on
purpose) — with the one-sentence reason, what was asked (host and port, never a credential) and when, and its figures:
connections and channels for Reverb, the spec status per platform for the gateway, missing, stale and orphaned routes
for the registry, wait, throughput and failed jobs for the queues.

- A figure the probe could not measure is shown as **not measured**, never as 0.
- A service the installation does not probe is **not monitored**, never up.
- A Core that predates the contract binds nothing: the card says the figures are **not available in this version of
  FaPost Core**. A report that cannot be read says so; neither is an error.
- The card refreshes every 15 seconds and loads after the rest of Pulse's dashboard: a probe with a cold cache can
  take a few seconds. The figures are counts and platform or queue names, never a tenant's id or a channel's name.

The page at `/monitoring/health` is the same card on its own, for an operator who may see Health but not Pulse, or an
installation that switched Pulse off (`MONITORING_PULSE_ENABLED=false`).

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

## Users in Pulse

Pulse records the id of the signed-in user (a ULID in FaPost) for its Usage card and, by default, looks the
name up in the users table of the default connection when the page is drawn. In a schema-per-tenant
installation that table lives in a tenant's schema: on the platform host it does not exist (`/pulse` answers
500, `relation "users" does not exist`), and platform operators and tenant users live in different places.

So this package reads no users table: the card shows `user 0000abcd` (the last characters of the id) and
never a name, e-mail or avatar, and nothing personal is written to Pulse's tables, only the id. What decides
(`monitoring.pulse.resolve_users`, `false` by default):

| Value | Result |
|---|---|
| `false` | the label above, no query |
| `true` | Pulse's own lookup in the model of `auth.providers.users.model`; only for an installation whose users table is on the default connection |
| a callable, or the class of an invokable one (a closure cannot be cached by `config:cache`: use `Class::class` or `'Class::method'`) | `fn (Collection $ids): iterable` returning rows `['id' => ..., 'name' => ..., 'extra' => ...]`, the shape `Pulse::users()` takes (an operator layer uses it to name its operators) |

A `Pulse::users(...)` call made by the application itself (in a service provider) always wins over the setting.
`Pulse::user(...)` has nothing to act on with the default resolver and is ignored.

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
lines; the Usage card shows the ids of signed-in users as a short label (see [Users in Pulse](#users-in-pulse)).

The tables are part of the database dump a deploy takes; seven days of entries is small at one installation's
scale.

## Telescope

Telescope records request contents: payloads, SQL with its bindings, mails and notifications, the signed-in
user's id, name and e-mail — of every tenant, into one installation-wide table. That is why it is **off by
default, on a developer's machine too**, and why switching it on in production is a decision for the time it
takes to look at a problem: `MONITORING_TELESCOPE_ENABLED=true`, then `false` again (and a restart, or
`config:cache`). Off means no routes (404) and no recording; what was recorded expires with the prune.

When it is on:

- **Who may open it**: only whoever the contract lets in for `OperatorSurface::Telescope`, on a `local` machine
  as well (Telescope's own "open on a local machine" is replaced). A host's own `Telescope::auth()` does not win.
- **Where**: `telescope_*` tables on `landlord` (`MONITORING_TELESCOPE_CONNECTION`). The migration creates each
  table only if it is missing (an installation of FaPost Core already has them) and its rollback drops nothing.
- **What is kept**: everything when `record_all` holds (by default on `local`); otherwise only reportable
  exceptions, failed requests (5xx), failed jobs, scheduled tasks and entries tagged for monitoring (from
  Telescope's own screen). In that mode the cache, dump, event, gate, model, Redis and view watchers are off
  (`monitoring.telescope.quiet_watchers`).
- **How long**: `telescope:prune --hours=48` daily (`MONITORING_TELESCOPE_KEEP_HOURS`), scheduled also while
  Telescope is off. The installation's scheduler (`schedule:work` or cron) must run.
- **Never recorded**: the support access entry (`support/enter`), the webhook ingress (`webhook/*`), Pulse, the log
  viewer and Telescope itself.
- **Masked, in every environment**:
  - request and response parameters `_token`, `token`, `secret_token`, `password`, `password_confirmation`,
    `current_password`, `secret`, `client_secret`, `access_token`, `refresh_token`, `api_key`, `signature`;
  - headers `cookie`, `authorization`, `php-auth-pw`, `x-csrf-token`, `x-xsrf-token`,
    `x-telegram-bot-api-secret-token`;
  - the same keys in a request's or an outgoing call's **query string**, and a bot token in a URL path
    (`/bot<id>:<token>`) wherever it appears (an outgoing URL, an exception or log message).

  `monitoring.telescope.hidden.*` adds to these lists, never removes from them.

Masking applies to new entries and to the updates Telescope writes into them later (a failed job's exception).
Parameters are matched by their top-level key (or a dot path added to the list): the same name nested deeper in a
payload, a job's data, a mail's body and SQL bindings are kept as they are, whenever everything is recorded or a tag
is monitored. Not masked either: anything else a body, a query or a mail carries (names, addresses, message texts).
Switch Telescope on only where everyone the contract lets in may read all of that.

**On a multi-tenant production installation (`host` mode, SaaS), keep Telescope off.** Even outside `record_all` it
writes the payload of exceptions and failed jobs — the data of the tenants' customers — into the installation-wide
`landlord` database, and it adds a write on the hot path of every request and job. Use error reporting (Sentry) and
the logs for errors, Pulse for load and Horizon for the queues. Switch it on only for the time it takes to look at an
incident, then off again. On a self-hosted `single` installation it is the owner's call. The package does not enforce
this: it is a recommendation, not a check.

Outside `record_all`, a failed job shows as its exception entry: Telescope records the job itself as pending,
which the filter drops, and its later "failed" update has no entry to land on.

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
- `fapost/foundation` `>=0.34`
- Redis and PostgreSQL (or MySQL/SQLite for tests) with the `landlord` connection of FaPost Core; Pulse's
  tables name the connection through `MONITORING_PULSE_CONNECTION`
- `laravel/reverb` (optional) for the two Reverb cards

## Namespace

```
Fapost\Monitoring\   →  src/
```

## Licence

Apache-2.0, like Core, Foundation and Support. The software it wires — Pulse, Telescope, the log
viewer — is MIT-licensed. The FaPost name and logo are covered by the
[Trademark Policy](https://github.com/fapost-lab/core/blob/main/TRADEMARK.md), not by this
licence.
