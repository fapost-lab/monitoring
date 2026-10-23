<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Redis;
use Illuminate\Support\Facades\Schema;
use Laravel\Pulse\Pulse;

/**
 * Needs a running Redis and PostgreSQL and the phpredis extension, as production has; skipped without
 * MONITORING_TEST_REDIS_HOST (and _PORT) and MONITORING_TEST_PGSQL_HOST / _DATABASE / _USERNAME.
 *
 * Proves what sqlite cannot: the Redis ingest stream under Core's `REDIS_PREFIX`, the `pulse:work` consumer
 * reading it back, and the PostgreSQL DDL (generated `key_hash`) on a connection named `landlord`.
 */
final class IntegrationTest extends TestCase
{
    protected ?string $ingest = 'redis';

    protected function setUp(): void
    {
        if (false === getenv('MONITORING_TEST_REDIS_HOST') || false === getenv('MONITORING_TEST_PGSQL_HOST')) {
            $this->markTestSkipped('MONITORING_TEST_REDIS_HOST and MONITORING_TEST_PGSQL_HOST are not set.');
        }

        parent::setUp();
    }

    public function test_pulse_writes_to_the_redis_stream_and_the_work_daemon_stores_it_on_landlord(): void
    {
        $this->assertSame('redis', config('pulse.ingest.driver'));

        Redis::connection()->flushdb();

        app(Pulse::class)->record('slow_request', '["GET","/probe","Closure"]', 12)->max()->count();
        app(Pulse::class)->ingest();

        // Under Core's REDIS_PREFIX (`fapost:` here): the client adds it, the daemon reads the same key.
        $this->assertSame(1, Redis::connection()->xlen('laravel:pulse:ingest'));
        $this->assertSame(0, DB::connection('landlord')->table('pulse_entries')->count(), 'nothing is stored before the daemon drains the stream');

        $this->artisan('pulse:work', ['--stop-when-empty' => true])->assertExitCode(0);

        $this->assertSame(1, DB::connection('landlord')->table('pulse_entries')->where('type', 'slow_request')->count());
        $this->assertTrue(Schema::connection('landlord')->hasTable('pulse_aggregates'));
    }

    protected function defineEnvironment($app): void
    {
        parent::defineEnvironment($app);

        $app['config']->set('database.connections.landlord', [
            'driver'   => 'pgsql',
            'host'     => getenv('MONITORING_TEST_PGSQL_HOST'),
            'port'     => getenv('MONITORING_TEST_PGSQL_PORT') ?: '5432',
            'database' => getenv('MONITORING_TEST_PGSQL_DATABASE'),
            'username' => getenv('MONITORING_TEST_PGSQL_USERNAME') ?: 'postgres',
            'password' => getenv('MONITORING_TEST_PGSQL_PASSWORD') ?: '',
            'charset'  => 'utf8',
            'schema'   => 'public',
        ]);
        $app['config']->set('database.redis.client', 'phpredis');
        $app['config']->set('database.redis.options', ['prefix' => 'fapost:']);
        $app['config']->set('database.redis.default', [
            'host'     => getenv('MONITORING_TEST_REDIS_HOST'),
            'port'     => getenv('MONITORING_TEST_REDIS_PORT') ?: '6379',
            'database' => 0,
        ]);
        $app['config']->set('pulse.recorders.' . \Laravel\Pulse\Recorders\SlowRequests::class . '.threshold', 0);
    }

    protected function defineDatabaseMigrations(): void
    {
        Schema::connection('landlord')->dropAllTables();
        parent::defineDatabaseMigrations();
    }
}
