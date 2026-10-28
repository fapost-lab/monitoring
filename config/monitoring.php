<?php

declare(strict_types=1);

return [

    /*
    |--------------------------------------------------------------------------
    | Route middleware
    |--------------------------------------------------------------------------
    |
    | Every operator screen of this package (Pulse, Telescope, the log viewer, the health page) runs this list first, then
    | `before_gate`, then its own check of the operator access contract.
    |
    | `middleware` is where an installation that serves tenants on hosts of their own puts the guard
    | that keeps operator routes off those hosts (by class name; this package never refers to Core's
    | classes). `before_gate` is where an operator layer puts the redirect of a guest to its sign-in.
    | Neither replaces the contract: it decides who may look, whatever these lists hold.
    |
    */

    'middleware'  => ['web'],
    'before_gate' => [],

    /*
    |--------------------------------------------------------------------------
    | Pulse
    |--------------------------------------------------------------------------
    |
    | Server load, slow requests, jobs and queries, exceptions, queues and (when laravel/reverb is
    | installed) Reverb's connections and messages. The tables live on the `landlord` connection,
    | never in a tenant's schema. Ingest goes through Redis and the `pulse:work` daemon; run
    | `pulse:check` once per installation for the server card.
    |
    */

    'pulse' => [
        'enabled'    => (bool) env('MONITORING_PULSE_ENABLED', true),
        'connection' => env('MONITORING_PULSE_CONNECTION', 'landlord'),
        'ingest'     => env('PULSE_INGEST_DRIVER', 'redis'),

        // How the Usage card turns a recorded user id into a name. `false` (the default): a label made of the id
        // ("user 0000abcd", the end of the id), no query, no name, e-mail or avatar. `true`: Pulse's own lookup in the model of
        // `auth.providers.users.model` (only where that table exists on the default connection). A callable or
        // the class name of an invokable one: `fn (Collection $ids): iterable` returning rows of
        // ['id' => ..., 'name' => ..., 'extra' => ...], as `Pulse::users()` takes. Calling `Pulse::users()`
        // yourself, in a service provider, always wins over this setting.
        'resolve_users' => false,

        // Laravel 13 refuses to unserialize cached objects unless `cache.serializable_classes` lists their class,
        // and Pulse's cards cache collections and rows. true adds exactly those three classes to that list (only a
        // `false` or a list is touched); false leaves the setting alone, for an installation that lists them itself.
        'allow_cached_classes' => (bool) env('MONITORING_PULSE_ALLOW_CACHED_CLASSES', true),

        // Paths (regular expressions; Pulse puts a route's domain, if it has one, before the slash) no recorder may keep: the
        // single-use support access entry, webhook ingress and the operator screens themselves.
        'ignore' => [
            '#^([^/]*)/support/enter#',
            '#^([^/]*)/webhook/#',
            '#^([^/]*)/log-viewer#',
            '#^([^/]*)/telescope#',
            '#^([^/]*)/monitoring/health#',
        ],
    ],

    /*
    |--------------------------------------------------------------------------
    | Log viewer
    |--------------------------------------------------------------------------
    |
    | Off by default: logs hold exception traces and can hold secrets. When on, it is read-only
    | (no download, no delete). `read_only` is deliberately not an environment setting: lifting it takes a
    | published config file, a decision somebody wrote down.
    |
    */

    'logs' => [
        'enabled'   => (bool) env('MONITORING_LOGS_ENABLED', false),
        'read_only' => true,
    ],

    /*
    |--------------------------------------------------------------------------
    | Telescope
    |--------------------------------------------------------------------------
    |
    | Off by default, in every environment: Telescope keeps request contents (payloads, SQL with its
    | bindings, mails) of every tenant. When on, it answers only through the operator access contract,
    | keeps its entries on `landlord`, and outside `record_all` keeps only what went wrong. Secrets are
    | masked in every environment; the lists below can add to the package's own, never remove from them.
    |
    */

    'telescope' => [
        'enabled'    => (bool) env('MONITORING_TELESCOPE_ENABLED', false),
        'connection' => env('MONITORING_TELESCOPE_CONNECTION', 'landlord'),

        // null: everything on a `local` machine, elsewhere only exceptions, failed requests and jobs, scheduled
        // tasks and monitored tags. true / false decide it whatever the environment.
        'record_all' => env('MONITORING_TELESCOPE_RECORD_ALL'),

        // Entries older than this are pruned daily (`telescope:prune`), also while Telescope is off, so that what
        // it kept before being switched off expires too. 0: nothing is scheduled.
        'keep_hours' => (int) env('MONITORING_TELESCOPE_KEEP_HOURS', 48),

        // Watchers switched off when not everything is recorded: their entries would be filtered out anyway
        // (unless tagged for monitoring), so they only cost time.
        'quiet_watchers' => [
            Laravel\Telescope\Watchers\CacheWatcher::class,
            Laravel\Telescope\Watchers\DumpWatcher::class,
            Laravel\Telescope\Watchers\EventWatcher::class,
            Laravel\Telescope\Watchers\GateWatcher::class,
            Laravel\Telescope\Watchers\ModelWatcher::class,
            Laravel\Telescope\Watchers\RedisWatcher::class,
            Laravel\Telescope\Watchers\ViewWatcher::class,
        ],

        // Paths Telescope never records (merged into `telescope.ignore_paths`): the single-use support access
        // entry, the webhook ingress (its path holds a secret) and the operator screens.
        'ignore_paths' => [
            'support/enter',
            'webhook/*',
            'pulse*',
            'log-viewer*',
            'monitoring/health*',
            '_boost*',
            '.well-known*',
        ],

        // Added to the package's own lists (Fapost\Monitoring\Telescope\Redactor), never instead of them.
        'hidden' => [
            'parameters'          => [],
            'headers'             => [],
            'response_parameters' => [],
        ],
    ],

    /*
    |--------------------------------------------------------------------------
    | Error reporting (Sentry)
    |--------------------------------------------------------------------------
    |
    | Unhandled exceptions of requests, queue jobs, the scheduler and console commands go to Sentry through
    | `sentry/sentry-laravel`, and only when a DSN is set: without one nothing is hooked and nothing is sent. The
    | privacy options (no PII, no request bodies, no local variables, no SQL bindings, no logs) are forced over any
    | Sentry environment variable or published `config/sentry.php`; see the README.
    |
    | `dsn`: SENTRY_LARAVEL_DSN (or SENTRY_DSN), empty = off.
    | `environment`: SENTRY_ENVIRONMENT, default APP_ENV.
    | `release`: SENTRY_RELEASE, default APP_VERSION when set.
    | `traces_sample_rate`: SENTRY_TRACES_SAMPLE_RATE, 0 to 1, default 0 (no performance tracing).
    |
    */

    'error_reporting' => [
        'dsn'                => env('SENTRY_LARAVEL_DSN', env('SENTRY_DSN')),
        'environment'        => env('SENTRY_ENVIRONMENT'),
        'release'            => env('SENTRY_RELEASE', env('APP_VERSION')),
        'traces_sample_rate' => env('SENTRY_TRACES_SAMPLE_RATE', 0),
    ],
];
