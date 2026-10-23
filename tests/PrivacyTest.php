<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Route;
use Laravel\Pulse\Pulse;
use Laravel\Pulse\Recorders\CacheInteractions;
use Laravel\Pulse\Recorders\SlowOutgoingRequests;
use Laravel\Pulse\Recorders\SlowRequests;

/**
 * What a request carries must not reach `pulse_*`: Pulse keeps counters, route patterns and durations, and
 * these tests hold the package to it for the secrets the installation knows about.
 */
final class PrivacyTest extends TestCase
{
    private const SECRETS = ['SECRET-TOKEN-1', 'hunter2-password', 'SECRET-COOKIE', 'SECRET-HEADER'];

    public function test_nothing_a_request_carries_is_stored(): void
    {
        $this->withHeader('Authorization', 'Bearer SECRET-HEADER')
            ->withUnencryptedCookie('session_secret', 'SECRET-COOKIE')
            ->postJson('/things/42?token=SECRET-TOKEN-1', ['password' => 'hunter2-password', 'token' => 'SECRET-TOKEN-1'])
            ->assertOk();

        $this->flush();

        $stored = $this->stored();

        $this->assertStringContainsString('/things/{id}', $stored, 'the route pattern is what is kept');

        foreach (self::SECRETS as $secret) {
            $this->assertStringNotContainsString($secret, $stored, $secret);
        }

        $this->assertStringNotContainsString('/things/42', $stored, 'the concrete path is not kept either');
    }

    public function test_the_support_entry_and_webhook_ingress_leave_nothing_at_all(): void
    {
        $this->postJson('/support/enter', ['token' => 'SECRET-TOKEN-1'])->assertOk();
        $this->postJson('/webhook/telegram/SECRET-TOKEN-1', ['x' => 1])->assertOk();

        $this->flush();

        $stored = $this->stored();

        $this->assertStringNotContainsString('support/enter', $stored);
        $this->assertStringNotContainsString('webhook', $stored);
        $this->assertStringNotContainsString('SECRET-TOKEN-1', $stored);
    }

    public function test_the_support_entry_on_a_tenants_own_host_leaves_nothing_either(): void
    {
        $this->postJson('http://tenant.example.com/support/enter', ['token' => 'SECRET-TOKEN-1'])->assertOk();

        $this->flush();

        $this->assertStringNotContainsString('support', $this->stored());
        $this->assertStringNotContainsString('tenant.example.com', $this->stored());
    }

    public function test_a_secret_in_an_outgoing_path_is_not_stored(): void
    {
        Http::fake();

        Http::get('https://api.telegram.org/botSECRET-TOKEN-1/sendMessage');

        $this->flush();

        $stored = $this->stored();

        $this->assertStringContainsString('api.telegram.org', $stored);
        $this->assertStringNotContainsString('SECRET-TOKEN-1', $stored);
        $this->assertStringNotContainsString('sendMessage', $stored);
    }

    public function test_a_cache_key_is_kept_by_its_first_segment_only(): void
    {
        config(['pulse.recorders.' . CacheInteractions::class . '.sample_rate' => 1]);

        \Illuminate\Support\Facades\Cache::get('login|SECRET-TOKEN-1|10.0.0.1');
        \Illuminate\Support\Facades\Cache::get('settings:tenant-7:SECRET-COOKIE');

        $this->flush();

        $stored = $this->stored();

        $this->assertStringContainsString('login:*', $stored);
        $this->assertStringContainsString('settings:*', $stored);
        $this->assertStringNotContainsString('SECRET-TOKEN-1', $stored);
        $this->assertStringNotContainsString('SECRET-COOKIE', $stored);
    }

    public function test_an_outgoing_request_is_kept_without_its_query_string(): void
    {
        Http::fake();

        Http::get('https://api.example.com/v1/items?token=SECRET-TOKEN-1&password=hunter2-password');

        $this->flush();

        $stored = $this->stored();

        $this->assertStringContainsString('api.example.com', $stored);
        $this->assertStringNotContainsString('v1/items', $stored);

        foreach (self::SECRETS as $secret) {
            $this->assertStringNotContainsString($secret, $stored, $secret);
        }
    }

    protected function defineEnvironment($app): void
    {
        parent::defineEnvironment($app);

        // Everything is "slow", so that every request is recorded.
        $app['config']->set('pulse.recorders.' . SlowRequests::class . '.threshold', 0);
        $app['config']->set('pulse.recorders.' . SlowOutgoingRequests::class . '.threshold', 0);
    }

    protected function defineRoutes($router): void
    {
        Route::post('/support/enter', fn () => 'ok');
        Route::post('/webhook/{channel}/{hash}', fn () => 'ok');
        Route::post('/things/{id}', fn () => 'ok');
        Route::domain('tenant.example.com')->group(function (): void {
            Route::post('/support/enter', fn () => 'ok');
        });
    }

    private function flush(): void
    {
        app(Pulse::class)->ingest();
    }

    /**
     * Everything Pulse holds, as one string.
     */
    private function stored(): string
    {
        $all = [];

        foreach (['pulse_values', 'pulse_entries', 'pulse_aggregates'] as $table) {
            $all[] = DB::connection('landlord')->table($table)->get()->toJson();
        }

        // Keys are JSON inside JSON: unescaped, so that a path reads as a path.
        return stripslashes(stripslashes(implode("\n", $all)));
    }
}
