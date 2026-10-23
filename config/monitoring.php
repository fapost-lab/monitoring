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
