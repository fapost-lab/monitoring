<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Fapost\Foundation\Operator\Contracts\OperatorAccessInterface;
use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Fapost\Monitoring\MonitoringServiceProvider;
use Illuminate\Http\Request;
use Laravel\Reverb\ReverbServiceProvider;
use Laravel\Telescope\Telescope;
use Livewire\LivewireServiceProvider;
use Orchestra\Testbench\TestCase as Orchestra;

abstract class TestCase extends Orchestra
{
    /** The environment variables {@see setUp()} set, cleared again after the test. */
    private const ENV = ['MONITORING_LOGS_ENABLED', 'PULSE_INGEST_DRIVER', 'MONITORING_TELESCOPE_ENABLED', 'MONITORING_TELESCOPE_RECORD_ALL'];
    /**
     * Surfaces the fake contract opens; null opens none.
     *
     * @var list<OperatorSurface>
     */
    public array $open = [];

    protected bool $logsEnabled = true;

    protected bool $telescopeEnabled = false;

    /** `MONITORING_TELESCOPE_RECORD_ALL`; null leaves it unset (the environment decides). */
    protected ?string $telescopeRecordAll = null;

    /** The ingest driver pinned by the environment; null leaves the package's own default. */
    protected ?string $ingest = 'storage';

    /**
     * Testbench registers the providers before it runs {@see defineEnvironment()}, and this package reads its
     * switches while registering: they have to be in the environment by then.
     */
    protected function setUp(): void
    {
        $this->setEnv('MONITORING_LOGS_ENABLED', $this->logsEnabled ? 'true' : 'false');
        if (null !== $this->ingest) {
            $this->setEnv('PULSE_INGEST_DRIVER', $this->ingest);
        }
        $this->setEnv('MONITORING_TELESCOPE_ENABLED', $this->telescopeEnabled ? 'true' : 'false');
        if (null !== $this->telescopeRecordAll) {
            $this->setEnv('MONITORING_TELESCOPE_RECORD_ALL', $this->telescopeRecordAll);
        }

        parent::setUp();
    }

    protected function tearDown(): void
    {
        parent::tearDown();

        // Telescope keeps its recording switch and queue in static state; nothing may reach the next test.
        Telescope::stopRecording();
        Telescope::flushEntries();

        foreach (self::ENV as $name) {
            putenv($name);
            unset($_ENV[$name], $_SERVER[$name]);
        }
    }

    protected function getPackageProviders($app): array
    {
        return [LivewireServiceProvider::class, ReverbServiceProvider::class, MonitoringServiceProvider::class];
    }

    protected function defineEnvironment($app): void
    {
        $app['config']->set('app.key', 'base64:' . base64_encode(str_repeat('k', 32)));
        $app['config']->set('database.default', 'sqlite');
        $app['config']->set('database.connections.sqlite', ['driver' => 'sqlite', 'database' => ':memory:', 'prefix' => '']);
        // The stand-in for Core's `landlord`: a connection of its own, apart from the default (a tenant's).
        $app['config']->set('database.connections.landlord', ['driver' => 'sqlite', 'database' => ':memory:', 'prefix' => '']);
        $app['config']->set('session.driver', 'array');
        $app['config']->set('cache.default', 'array');

        $app->singleton(OperatorAccessInterface::class, fn (): OperatorAccessInterface => new class ($this) implements OperatorAccessInterface {
            public function __construct(private readonly TestCase $case)
            {
            }

            public function canView(Request $request, OperatorSurface $surface): bool
            {
                return in_array($surface, $this->case->open, true);
            }
        });
    }

    protected function defineDatabaseMigrations(): void
    {
        $this->artisan('migrate', ['--database' => 'landlord', '--force' => true]);
    }

    private function setEnv(string $name, string $value): void
    {
        putenv("{$name}={$value}");
        $_ENV[$name] = $_SERVER[$name] = $value;
    }
}
