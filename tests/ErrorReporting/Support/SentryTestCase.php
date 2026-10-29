<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests\ErrorReporting\Support;

use Fapost\Monitoring\Tests\TestCase;
use Illuminate\Foundation\Application;
use Sentry\ClientBuilder;
use Sentry\SentrySdk;
use Sentry\State\HubInterface;

/**
 * Boots Core with the given environment variables for Sentry's configuration and, when a DSN is set, replaces Sentry's
 * HTTP transport with a recording one before anything is captured: no test sends anything over the network.
 */
abstract class SentryTestCase extends TestCase
{
    protected const string FAKE_DSN = 'https://publickey@o0.ingest.sentry.io/0';

    protected RecordingSentryTransport $transport;

    /** @var array<string, array{0: bool, 1: string|false}> */
    private array $savedEnvironment = [];

    protected function setUp(): void
    {
        parent::setUp();

        $this->useRecordingTransport();
    }

    protected function tearDown(): void
    {
        parent::tearDown();

        foreach ($this->savedEnvironment as $name => [$inEnv, $previous]) {
            if (false === $previous) {
                putenv($name);
                unset($_ENV[$name], $_SERVER[$name]);
            } else {
                putenv($name . '=' . $previous);
                $_ENV[$name]    = $previous;
                $_SERVER[$name] = $previous;
            }
        }

        $this->savedEnvironment = [];
        \Sentry\Laravel\Integration::setTransaction(null);
        SentrySdk::setCurrentHub(new \Sentry\State\Hub(ClientBuilder::create([])->getClient()));
    }

    public function createApplication(): Application
    {
        foreach ($this->sentryEnvironment() as $name => $value) {
            $this->savedEnvironment[$name] = [array_key_exists($name, $_ENV), getenv($name)];

            if (null === $value) {
                putenv($name);
                unset($_ENV[$name], $_SERVER[$name]);
            } else {
                putenv($name . '=' . $value);
                $_ENV[$name]    = $value;
                $_SERVER[$name] = $value;
            }
        }

        return parent::createApplication();
    }

    /**
     * Testbench does not run package discovery for the dependencies of the package under test; a host does.
     */
    protected function getPackageProviders($app): array
    {
        return [...parent::getPackageProviders($app), \Sentry\Laravel\ServiceProvider::class, \Sentry\Laravel\Tracing\ServiceProvider::class];
    }

    /**
     * @return array<string, string|null> variables to set before the application boots; null unsets
     */
    protected function sentryEnvironment(): array
    {
        return [];
    }

    /**
     * Rebuilds the hub the way the provider does, with the recording transport in place of the HTTP one.
     */
    private function useRecordingTransport(): void
    {
        $options         = ClientBuilder::create(['dsn' => self::FAKE_DSN])->getOptions();
        $this->transport = new RecordingSentryTransport($options);

        $this->app['config']->set('sentry.transport', $this->transport);
        $this->app->forgetInstance(HubInterface::class);
        $this->app->make(HubInterface::class);
    }
}
