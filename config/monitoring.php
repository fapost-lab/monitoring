<?php

declare(strict_types=1);

return [

    /*
    |--------------------------------------------------------------------------
    | Route middleware
    |--------------------------------------------------------------------------
    |
    | Every operator screen of this package (Pulse, the log viewer) runs this list first, then
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
];
