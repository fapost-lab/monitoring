<?php

declare(strict_types=1);

namespace Fapost\Monitoring;

use Carbon\CarbonImmutable;
use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Fapost\Monitoring\Access\OperatorGate;
use Fapost\Monitoring\Http\Middleware\AllowLogs;
use Fapost\Monitoring\Http\Middleware\AllowPulse;
use Illuminate\Contracts\Config\Repository;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\Facades\View;
use Illuminate\Support\ServiceProvider;
use Laravel\Pulse\Http\Middleware\Authorize;
use Laravel\Pulse\Pulse;
use Laravel\Pulse\PulseServiceProvider;
use Laravel\Pulse\Recorders\CacheInteractions;
use Laravel\Pulse\Recorders\SlowOutgoingRequests;
use Laravel\Pulse\Recorders\SlowRequests;
use Laravel\Pulse\Recorders\UserRequests;
use Laravel\Reverb\Pulse\Recorders\ReverbConnections;
use Laravel\Reverb\Pulse\Recorders\ReverbMessages;
use Opcodes\LogViewer\LogViewerServiceProvider;
use stdClass;

/**
 * Pulse and a log viewer behind the operator access contract.
 *
 * There is no sign-in here: every screen asks {@see \Fapost\Foundation\Operator\Contracts\OperatorAccessInterface}
 * (through {@see OperatorGate}) and answers 404 when it says no or cannot say. The third-party providers are
 * registered first, so that their default configuration is in place before it is adjusted below, whatever
 * order discovery puts the providers in.
 */
final class MonitoringServiceProvider extends ServiceProvider
{
    /**
     * The classes Pulse's cards put into the cache and read back (found by rendering every card of Pulse and of
     * Reverb on a cache that serializes): the query result is a collection of `stdClass` rows, some with a
     * `CarbonImmutable` timestamp. On Laravel 13 a cache whose `serializable_classes` is `false` returns them as
     * `__PHP_Incomplete_Class` and the card answers 500.
     *
     * @var list<class-string>
     */
    public const PULSE_CACHED_CLASSES = [Collection::class, stdClass::class, CarbonImmutable::class];

    public function register(): void
    {
        $this->mergeConfigFrom(__DIR__ . '/../config/monitoring.php', 'monitoring');

        $this->app->singleton(OperatorGate::class);

        $this->app->register(PulseServiceProvider::class);
        $this->app->register(LogViewerServiceProvider::class);

        $config = $this->app->make('config');

        $this->configurePulse($config);
        $this->configureLogViewer($config);
    }

    public function boot(): void
    {
        $this->loadMigrationsFrom(__DIR__ . '/../database/migrations');

        // Ahead of Pulse's own `pulse::dashboard`: the same cards plus Reverb's when it is installed.
        View::prependNamespace('pulse', __DIR__ . '/../resources/views/pulse');

        // After every provider has booted, so that no other definition of the abilities wins. The user is
        // optional: the contract reads the request's own sign-in, and a guest is asked too.
        $this->app->booted(function (): void {
            $gate = $this->app->make(OperatorGate::class);

            Gate::define('viewPulse', static fn (mixed $user = null): bool => $gate->allows(request(), OperatorSurface::Pulse));
        });
    }

    private function configurePulse(Repository $config): void
    {
        $enabled = (bool) $config->get('monitoring.pulse.enabled', true);

        $config->set('pulse.enabled', $enabled && (bool) $config->get('pulse.enabled', true));

        if (! $enabled) {
            // Off means no dashboard route either, not a dashboard that shows nothing.
            // An instance method (Pulse's facade forwards to it): a static call is an error.
            $this->app->make(Pulse::class)->ignoreRoutes();
        }

        $config->set('pulse.storage.database.connection', $config->get('monitoring.pulse.connection'));
        $config->set('pulse.ingest.driver', $config->get('monitoring.pulse.ingest'));

        // The contract first (404 for whoever may not look), Pulse's own gate behind it.
        $config->set('pulse.middleware', [
            ...(array) $config->get('monitoring.middleware', ['web']),
            ...(array) $config->get('monitoring.before_gate', []),
            AllowPulse::class,
            Authorize::class,
        ]);

        $this->keepPrivate($config);
        $this->addReverbRecorders($config);

        if ($enabled && (bool) $config->get('monitoring.pulse.allow_cached_classes', true)) {
            $this->allowPulseCachedClasses($config);
        }
    }

    /**
     * Laravel 13's `cache.serializable_classes` is one list for every store (the cache manager ignores a store's
     * own), and Pulse's cards cache objects. A whitelist of exactly those classes is added instead of opening the
     * setting (`true`): `false` becomes the list, a list is extended, `true` and an unset value (everything is
     * allowed already) are left alone. Laravel 12 does not read the key; the entry is inert there.
     */
    private function allowPulseCachedClasses(Repository $config): void
    {
        $allowed = $config->get('cache.serializable_classes');

        if (false === $allowed) {
            $config->set('cache.serializable_classes', self::PULSE_CACHED_CLASSES);
        } elseif (is_array($allowed)) {
            $config->set('cache.serializable_classes', array_values(array_unique([...$allowed, ...self::PULSE_CACHED_CLASSES])));
        }
    }

    /**
     * Pulse keeps counters and route patterns, not requests. What it could still keep is trimmed here:
     * paths whose requests carry secrets are ignored by the recorders that look at request paths, an outgoing
     * call is kept as its host only, and a cache key as its first segment.
     */
    private function keepPrivate(Repository $config): void
    {
        /** @var list<string> $ignore */
        $ignore = (array) $config->get('monitoring.pulse.ignore', []);

        foreach ([SlowRequests::class, UserRequests::class] as $class) {
            $key = 'pulse.recorders.' . $class . '.ignore';

            $config->set($key, array_values(array_unique([...(array) $config->get($key, []), ...$ignore])));
        }

        // An outgoing call is kept as its host: a path can carry a secret (a bot token in an API URL), a query too.
        $this->group($config, SlowOutgoingRequests::class, ['#^(https?://[^/?\#]+).*$#i' => '$1/*']);

        // A cache key can be a rate-limiter or single-use key built from an e-mail, an address or a token: only
        // the part before its first separator is kept.
        $this->group($config, CacheInteractions::class, ['#^([^:|]*)[:|].*$#s' => '$1:*']);
    }

    /**
     * @param  class-string  $recorder
     * @param  array<string, string>  $groups
     */
    private function group(Repository $config, string $recorder, array $groups): void
    {
        $key = 'pulse.recorders.' . $recorder . '.groups';

        $config->set($key, [...$groups, ...(array) $config->get($key, [])]);
    }

    private function addReverbRecorders(Repository $config): void
    {
        if (! class_exists(ReverbConnections::class)) {
            return;
        }

        foreach ([ReverbConnections::class, ReverbMessages::class] as $recorder) {
            $key = 'pulse.recorders.' . $recorder;

            if (null === $config->get($key)) {
                $config->set($key, ['enabled' => true, 'sample_rate' => 1]);
            }
        }
    }

    private function configureLogViewer(Repository $config): void
    {
        $config->set('log-viewer.enabled', (bool) $config->get('monitoring.logs.enabled', false));

        $stack = [
            ...(array) $config->get('monitoring.middleware', ['web']),
            ...(array) $config->get('monitoring.before_gate', []),
            AllowLogs::class,
        ];

        // The viewer's own check (a gate, open on a local machine) is replaced by the contract's. The API
        // is served on the same stack: it needs the same session the contract reads.
        $config->set('log-viewer.middleware', $stack);
        $config->set('log-viewer.api_middleware', $stack);

        // Never a download or a delete through the viewer's abilities, for anyone.
        foreach (['downloadLogFile', 'downloadLogFolder', 'deleteLogFile', 'deleteLogFolder'] as $ability) {
            Gate::define($ability, static fn (): bool => false);
        }
    }
}
