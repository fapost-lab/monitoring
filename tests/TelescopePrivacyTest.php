<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Fapost\Monitoring\Telescope\Redactor;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Str;
use Laravel\Telescope\Contracts\EntriesRepository;
use Laravel\Telescope\EntryType;
use Laravel\Telescope\EntryUpdate;
use Laravel\Telescope\IncomingEntry;
use Laravel\Telescope\Telescope;
use ReflectionMethod;
use RuntimeException;

/**
 * What Telescope must never keep, with everything recorded (`record_all`, as on a developer's machine): the
 * support entry's single-use token, credentials in bodies, query strings, headers and cookies, a bot token in an
 * outgoing URL or in an exception message.
 */
final class TelescopePrivacyTest extends TestCase
{
    private const SECRETS = [
        'SECRET-TOKEN-1',
        'hunter2-password',
        'SECRET-CHANNEL',
        'SECRET-SIGNATURE',
        'SECRET-COOKIE',
        'SECRET-HEADER',
        'SECRET-WEBHOOK-HEADER',
        'SECRET-RESPONSE',
        'SECRET-BOT',
        'SECRET-QUERY',
    ];
    protected bool $telescopeEnabled = true;

    protected ?string $telescopeRecordAll = 'true';

    public function test_nothing_secret_a_request_carries_is_stored(): void
    {
        $this->withHeader('Authorization', 'Bearer SECRET-HEADER')
            ->withHeader('X-Telegram-Bot-Api-Secret-Token', 'SECRET-WEBHOOK-HEADER')
            ->withUnencryptedCookie('session_secret', 'SECRET-COOKIE')
            ->postJson('/things/42?token=SECRET-TOKEN-1&signature=SECRET-SIGNATURE&page=2', [
                'token'        => 'SECRET-TOKEN-1',
                'password'     => 'hunter2-password',
                'secret_token' => 'SECRET-CHANNEL',
                'name'         => 'visible-name',
            ])
            ->assertOk();

        $stored = $this->stored();

        $this->assertStringContainsString('/things/42', $stored, 'the request is recorded');
        $this->assertStringContainsString('page=2', $stored, 'an ordinary query parameter is kept');
        $this->assertStringContainsString('visible-name', $stored, 'an ordinary field is kept');
        $this->assertSecretsAbsent($stored);
    }

    public function test_a_bot_token_in_an_outgoing_url_and_secret_query_values_are_masked(): void
    {
        Http::fake();

        Http::get('https://api.telegram.org/bot123456:SECRET-BOT/sendMessage?access_token=SECRET-QUERY&chat_id=7');

        $stored = $this->stored();

        $this->assertStringContainsString('api.telegram.org/bot' . Redactor::MASK . '/sendMessage', $stored);
        $this->assertStringContainsString('chat_id=7', $stored);
        $this->assertSecretsAbsent($stored);
    }

    public function test_a_bot_token_in_an_exception_message_is_masked(): void
    {
        $this->get('/broken')->assertStatus(500);

        $stored = $this->stored();

        // The exception's line preview shows this file's source, so only the bot token is looked for here.
        $this->assertStringContainsString('api.telegram.org/bot' . Redactor::MASK . '/sendMessage failed', $stored);
        $this->assertStringNotContainsString('SECRET-BOT', $stored);
    }

    public function test_a_failed_jobs_exception_written_as_an_update_is_masked_too(): void
    {
        $repository = $this->app->make(EntriesRepository::class);
        $job        = IncomingEntry::make(['status' => 'pending', 'name' => 'SendMessage'])->type(EntryType::JOB);

        $repository->store(collect([$job->batchId((string) Str::orderedUuid())]));

        // What JobWatcher writes when the job fails: an update, which no Telescope filter sees.
        $repository->update(collect([EntryUpdate::make($job->uuid, EntryType::JOB, [
            'status'    => 'failed',
            'exception' => ['message' => 'Client error: `POST https://api.telegram.org/bot123456:SECRET-BOT/sendMessage` resulted in 401'],
        ])]));

        $stored = $this->stored();

        $this->assertStringContainsString('"status":"failed"', $stored);
        $this->assertStringContainsString('api.telegram.org/bot' . Redactor::MASK . '/sendMessage', $stored);
        $this->assertStringNotContainsString('SECRET-BOT', $stored);
    }

    public function test_the_support_entry_and_the_webhook_ingress_are_never_recorded(): void
    {
        // Telescope decides at boot, from the request being handled, whether to record at all.
        $approved = new ReflectionMethod(Telescope::class, 'requestIsToApprovedUri');

        $this->assertFalse($approved->invoke(null, Request::create('/support/enter', 'POST')));
        $this->assertFalse($approved->invoke(null, Request::create('/webhook/telegram/SECRET-TOKEN-1', 'POST')));
        $this->assertTrue($approved->invoke(null, Request::create('/things/42', 'POST')));
    }

    public function test_an_installation_can_add_to_the_lists_but_not_take_away(): void
    {
        $this->assertContains('token', Telescope::$hiddenRequestParameters);
        $this->assertContains('pin', Telescope::$hiddenRequestParameters);
        $this->assertContains('cookie', Telescope::$hiddenRequestHeaders);
        $this->assertContains('token', Telescope::$hiddenResponseParameters);
    }

    /**
     * An installation's own addition, as a published config file holds it: in place before the package registers.
     */
    protected function resolveApplicationConfiguration($app): void
    {
        parent::resolveApplicationConfiguration($app);

        $monitoring = require dirname(__DIR__) . '/config/monitoring.php';

        $monitoring['telescope']['hidden']['parameters'] = ['pin'];

        $app['config']->set('monitoring', $monitoring);
    }

    protected function defineRoutes($router): void
    {
        Route::post('/things/{id}', static fn () => ['token' => 'SECRET-RESPONSE', 'ok' => true]);
        Route::get('/broken', static function (): never {
            throw new RuntimeException('POST https://api.telegram.org/bot123456:SECRET-BOT/sendMessage failed');
        });
    }

    private function assertSecretsAbsent(string $stored): void
    {
        foreach (self::SECRETS as $secret) {
            $this->assertStringNotContainsString($secret, $stored, $secret);
        }
    }

    /**
     * Everything Telescope holds, as one string.
     */
    private function stored(): string
    {
        Telescope::store($this->app->make(EntriesRepository::class));

        $rows = DB::connection('landlord')->table('telescope_entries')->pluck('content')
            ->map(static fn (string $content): mixed => json_decode($content, true, flags: JSON_THROW_ON_ERROR));

        return (string) json_encode($rows, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    }
}
