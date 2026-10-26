<?php

declare(strict_types=1);

namespace Fapost\Monitoring;

use Carbon\CarbonImmutable;
use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Fapost\Monitoring\Access\OperatorGate;
use Fapost\Monitoring\Health\HealthReader;
use Fapost\Monitoring\Http\Middleware\AllowHealth;
use Fapost\Monitoring\Http\Middleware\AllowLogs;
use Fapost\Monitoring\Http\Middleware\AllowPulse;
use Fapost\Monitoring\Http\Middleware\AllowTelescope;
use Fapost\Monitoring\Pulse\HealthCard;
use Fapost\Monitoring\Pulse\NeutralUsers;
use Fapost\Monitoring\Telescope\RecordingFilter;
use Fapost\Monitoring\Telescope\RedactingEntriesRepository;
use Fapost\Monitoring\Telescope\Redactor;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Contracts\Config\Repository;
use Illuminate\Contracts\Foundation\Application;
use Illuminate\Http\Request;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\View;
use Illuminate\Support\ServiceProvider;
use InvalidArgumentException;
use Laravel\Pulse\Contracts\ResolvesUsers;
use Laravel\Pulse\Http\Middleware\Authorize;
use Laravel\Pulse\LegacyUsers;
use Laravel\Pulse\Pulse;
use Laravel\Pulse\PulseServiceProvider;
use Laravel\Pulse\Recorders\CacheInteractions;
use Laravel\Pulse\Recorders\SlowOutgoingRequests;
use Laravel\Pulse\Recorders\SlowRequests;
use Laravel\Pulse\Recorders\UserRequests;
use Laravel\Pulse\Users;
use Laravel\Reverb\Pulse\Recorders\ReverbConnections;
use Laravel\Reverb\Pulse\Recorders\ReverbMessages;
use Laravel\Telescope\Contracts\ClearableRepository;
use Laravel\Telescope\Contracts\EntriesRepository;
use Laravel\Telescope\Contracts\PrunableRepository;
use Laravel\Telescope\Http\Middleware\Authorize as TelescopeAuthorize;
use Laravel\Telescope\Telescope;
use Laravel\Telescope\TelescopeServiceProvider;
use Livewire\LivewireManager;
use Opcodes\LogViewer\LogViewerServiceProvider;
use stdClass;

/**
 * Pulse, Telescope, a log viewer and the installation's health behind the operator access contract.
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

    /** The package's own health page; the card is on Pulse's dashboard as well. */
    public const HEALTH_PATH = 'monitoring/health';

    public function register(): void
    {
        $this->mergeConfigFrom(__DIR__ . '/../config/monitoring.php', 'monitoring');

        $this->app->singleton(OperatorGate::class);
        $this->app->bind(HealthReader::class);

        $this->app->register(PulseServiceProvider::class);
        $this->app->register(LogViewerServiceProvider::class);
        $this->app->register(TelescopeServiceProvider::class);

        $config = $this->app->make('config');

        $this->configurePulse($config);
        $this->configureLogViewer($config);
        $this->configureTelescope($config);
    }

    public function boot(): void
    {
        $this->loadMigrationsFrom(__DIR__ . '/../database/migrations');

        // Ahead of Pulse's own `pulse::dashboard`: the same cards plus Reverb's when it is installed.
        View::prependNamespace('pulse', __DIR__ . '/../resources/views/pulse');
        $this->loadViewsFrom(__DIR__ . '/../resources/views', 'monitoring');

        $this->registerHealth();

        // After every provider has booted, so that no other definition of the abilities wins. The user is
        // optional: the contract reads the request's own sign-in, and a guest is asked too.
        $this->app->booted(function (): void {
            $gate = $this->app->make(OperatorGate::class);

            Gate::define('viewPulse', static fn (mixed $user = null): bool => $gate->allows(request(), OperatorSurface::Pulse));
            Gate::define('viewTelescope', static fn (mixed $user = null): bool => $gate->allows(request(), OperatorSurface::Telescope));

            // Telescope keeps its authorization in static state, and a host's TelescopeApplicationServiceProvider
            // sets it while booting ("open on a local machine"): this one is set last, and asks the contract only.
            Telescope::auth(static fn (Request $request): bool => $gate->allows($request, OperatorSurface::Telescope));
        });

        $this->schedulePrune();
    }

    /**
     * The health card (a Pulse card, on Pulse's dashboard and on a page of its own) and that page. The page runs the
     * installation's stack, then the contract's check for {@see OperatorSurface::Health} (404); Livewire repeats that
     * check on the card's updates by class name. The card asks the contract itself as well, since on Pulse's dashboard
     * only the Pulse surface was checked.
     */
    private function registerHealth(): void
    {
        $this->callAfterResolving('livewire', static function (LivewireManager $livewire): void {
            $livewire->addPersistentMiddleware([AllowHealth::class]);
            $livewire->component('fapost.health', HealthCard::class);
        });

        if ($this->app->routesAreCached()) {
            return;
        }

        $config = $this->app->make('config');

        Route::middleware([
            ...(array) $config->get('monitoring.middleware', ['web']),
            ...(array) $config->get('monitoring.before_gate', []),
            AllowHealth::class,
        ])->group(static function (): void {
            Route::view(self::HEALTH_PATH, 'monitoring::health.page')->name('monitoring.health');
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
        $this->bindUserResolver();

        if ($enabled && (bool) $config->get('monitoring.pulse.allow_cached_classes', true)) {
            $this->allowPulseCachedClasses($config);
        }
    }

    /**
     * Pulse resolves recorded user ids through the users table of the default connection, which a
     * schema-per-tenant installation does not have on the platform host. Unless `monitoring.pulse.resolve_users`
     * says otherwise, a resolver that reads no table is bound; `Pulse::users()` called by the application
     * later rebinds it, and wins.
     */
    private function bindUserResolver(): void
    {
        $this->app->singleton(ResolvesUsers::class, function (Application $app): ResolvesUsers {
            $setting = $app->make('config')->get('monitoring.pulse.resolve_users', false);

            if (is_string($setting) && ! is_callable($setting) && class_exists($setting)) {
                $setting = $app->make($setting);
            }

            if (is_callable($setting)) {
                // Pulse's legacy resolver wants a collection back; a plain array of rows is accepted here too.
                return new LegacyUsers(static fn (Collection $ids): Collection => collect($setting($ids)));
            }

            if (! is_bool($setting)) {
                throw new InvalidArgumentException('monitoring.pulse.resolve_users must be true, false, a callable or the class of an invokable one.');
            }

            // `true`: Pulse's own resolver, for an installation whose users sit where its model says.
            return $setting ? $app->make(Users::class) : new NeutralUsers();
        });
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

    /**
     * Telescope is off unless `monitoring.telescope.enabled` says so: its own `TELESCOPE_ENABLED` (on by default)
     * no longer decides. Its entries live on `landlord`; its routes run the installation's stack, then the
     * contract's check (404), then Telescope's own gate; secrets are masked in every environment.
     */
    private function configureTelescope(Repository $config): void
    {
        $config->set('telescope.enabled', (bool) $config->get('monitoring.telescope.enabled', false));
        $config->set('telescope.storage.database.connection', $config->get('monitoring.telescope.connection', 'landlord'));

        $config->set('telescope.middleware', [
            ...(array) $config->get('monitoring.middleware', ['web']),
            ...(array) $config->get('monitoring.before_gate', []),
            AllowTelescope::class,
            TelescopeAuthorize::class,
        ]);

        $config->set('telescope.ignore_paths', array_values(array_unique([
            ...(array) $config->get('telescope.ignore_paths', []),
            ...(array) $config->get('monitoring.telescope.ignore_paths', []),
        ])));

        if (! RecordingFilter::recordsAll($this->app)) {
            foreach ((array) $config->get('monitoring.telescope.quiet_watchers', []) as $watcher) {
                $key     = 'telescope.watchers.' . $watcher;
                $current = $config->get($key);

                $config->set($key, is_array($current) ? [...$current, 'enabled' => false] : false);
            }
        }

        $parameters = $this->hidden($config, 'parameters', Redactor::PARAMETERS);

        // Telescope merges these lists into static state: a host's own additions are kept, never replaced.
        Telescope::hideRequestParameters($parameters);
        Telescope::hideRequestHeaders($this->hidden($config, 'headers', Redactor::HEADERS));
        Telescope::hideResponseParameters($this->hidden($config, 'response_parameters', Redactor::RESPONSE_PARAMETERS));

        Telescope::filter((new RecordingFilter())(...));

        $this->redactStorage(new Redactor(array_map(mb_strtolower(...), $parameters)));
    }

    /**
     * Everything Telescope writes goes through the redactor: new entries and the updates written into them later
     * (a filter sees new entries only). Telescope's own database storage, replaced by a subclass that masks first;
     * another driver chosen by the installation is left alone.
     */
    private function redactStorage(Redactor $redactor): void
    {
        if ('database' !== $this->app->make('config')->get('telescope.driver', 'database')) {
            return;
        }

        $this->app->singleton(RedactingEntriesRepository::class, static function (Application $app) use ($redactor): RedactingEntriesRepository {
            $config = $app->make('config');
            $chunk  = $config->get('telescope.storage.database.chunk');

            return (new RedactingEntriesRepository((string) $config->get('telescope.storage.database.connection'), null === $chunk ? null : (int) $chunk))
                ->redactWith($redactor);
        });

        foreach ([EntriesRepository::class, ClearableRepository::class, PrunableRepository::class] as $contract) {
            $this->app->singleton($contract, static fn (Application $app): RedactingEntriesRepository => $app->make(RedactingEntriesRepository::class));
        }
    }

    /**
     * @param  list<string>  $base
     *
     * @return list<string>
     */
    private function hidden(Repository $config, string $list, array $base): array
    {
        return array_values(array_unique([...$base, ...array_map(strval(...), (array) $config->get('monitoring.telescope.hidden.' . $list, []))]));
    }

    /**
     * Telescope prunes nothing by itself. The prune is scheduled whether Telescope is on or not, so that entries
     * kept before it was switched off expire as well; the package's migration makes the tables either way.
     */
    private function schedulePrune(): void
    {
        $this->callAfterResolving(Schedule::class, function (Schedule $schedule): void {
            $hours = (int) $this->app->make('config')->get('monitoring.telescope.keep_hours', 48);

            if ($hours > 0) {
                $schedule->command('telescope:prune', ['--hours' => $hours])->daily();
            }
        });
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
