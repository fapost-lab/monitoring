<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests\ErrorReporting;

use Fapost\Monitoring\ErrorReporting\ErrorReporting;
use Fapost\Monitoring\Tests\ErrorReporting\Support\SentryTestCase;
use Illuminate\Auth\AuthenticationException;
use Illuminate\Contracts\Queue\Job as JobContract;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Database\Eloquent\ModelNotFoundException;
use Illuminate\Database\QueryException;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Http\Exceptions\ThrottleRequestsException;
use Illuminate\Queue\Events\JobExceptionOccurred;
use Illuminate\Queue\Events\JobProcessed;
use Illuminate\Queue\Events\JobProcessing;
use Illuminate\Queue\Events\Looping;
use Illuminate\Queue\Events\WorkerStopping;
use Illuminate\Queue\Jobs\Job;
use Illuminate\Session\TokenMismatchException;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\View;
use Illuminate\Validation\ValidationException;
use PDOException;
use RuntimeException;
use Sentry\State\HubInterface;
use Symfony\Component\HttpKernel\Exception\AccessDeniedHttpException;
use Symfony\Component\HttpKernel\Exception\HttpException;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

final class ErrorReportingTest extends SentryTestCase
{
    public function test_it_is_on_with_a_dsn(): void
    {
        $this->assertTrue((new ErrorReporting($this->app))->enabled());
        $this->assertSame(self::FAKE_DSN, config('sentry.dsn'));
    }

    public function test_a_failing_request_reaches_sentry_without_any_of_its_secrets(): void
    {
        // Built at run time: a stack trace carries the lines of source around each frame, and the test's own lines must not hold the secrets.
        $token    = $this->secret('token');
        $password = $this->secret('password');
        $bearer   = $this->secret('bearer');
        $apiKey   = $this->secret('apikey');
        $cookie   = $this->secret('cookie');
        $body     = $this->secret('contact message body');
        $email    = $this->secret('anna') . '@' . 'example.com';
        $signed   = $this->secret('signature');

        Route::match(['GET', 'POST'], '/boom', static function () use ($token, $email): never {
            throw new RuntimeException("Cannot confirm {$email}, token={$token}");
        });

        $this->withHeaders(['Authorization' => 'Bearer ' . $bearer, 'X-Api-Key' => $apiKey, 'Referer' => 'https://x.test/?token=' . $token])
            ->withUnencryptedCookie('laravel_session', $cookie)
            ->post('/boom?token=' . $token . '&sig=' . $signed, [
                '_token'   => $token,
                'token'    => $token,
                'password' => $password,
                'email'    => $email,
                'message'  => $body,
            ])
            ->assertStatus(500);

        $this->assertSame(1, $this->transport->count());

        $wire = $this->transport->wire();

        foreach ([$token, $password, $bearer, $apiKey, $cookie, $body, $email, $signed] as $secret) {
            $this->assertStringNotContainsString($secret, $wire, 'A secret value must not be sent.');
        }

        $this->assertStringContainsString('RuntimeException', $wire);
        $this->assertStringContainsString('Cannot confirm', $wire);

        $event = $this->transport->events()[0];

        $this->assertSame(['method', 'url'], array_keys($event->getRequest()));
        $this->assertNull($event->getUser());
    }

    public function test_the_exception_noise_is_not_reported(): void
    {
        $hub = $this->app->make(HubInterface::class);

        $validator = $this->app['validator']->make(['a' => ''], ['a' => 'required']);

        foreach ([
            new NotFoundHttpException(),
            new ModelNotFoundException(),
            new TokenMismatchException(),
            new AuthenticationException(),
            new AccessDeniedHttpException(),
            new ThrottleRequestsException(),
            new HttpException(403),
            new HttpException(499),
            new ValidationException($validator),
        ] as $exception) {
            $hub->captureException($exception);
        }

        $this->assertSame(0, $this->transport->count());

        $hub->captureException(new HttpException(503, 'down'));
        $hub->captureException(new RuntimeException('real'));

        $this->assertSame(2, $this->transport->count());
    }

    public function test_the_exception_handler_does_not_hand_over_ignored_exceptions(): void
    {
        report(new NotFoundHttpException());
        report(new AuthenticationException());

        $this->assertSame(0, $this->transport->count());

        report(new RuntimeException('reported'));

        $this->assertSame(1, $this->transport->count());
    }

    public function test_a_job_exception_carries_the_job_and_queue_and_never_the_payload(): void
    {
        $payload = $this->secret('payload');
        $owner   = $this->secret('owner') . '@' . 'example.com';

        try {
            FailingSentryJob::dispatch($payload, $owner);
            $this->fail('The job must throw.');
        } catch (RuntimeException $exception) {
            report($exception);
        }

        $this->assertSame(1, $this->transport->count());

        $event = $this->transport->events()[0];

        $this->assertSame(FailingSentryJob::class, $event->getTags()['job']);
        $this->assertArrayHasKey('queue', $event->getTags());
        $this->assertStringNotContainsString($payload, $this->transport->wire());
        $this->assertStringNotContainsString($owner, $this->transport->wire());
    }

    public function test_a_query_exception_is_replaced_by_its_sqlstate_and_placeholder_sql(): void
    {
        $hash  = '$2y$12$' . $this->secret('hashhashhashhashhash');
        $name  = $this->secret('Anna Smith');
        $mail  = $this->secret('anna') . '@' . 'example.com';
        $line2 = $this->secret('secretline2');
        $query = new QueryException(
            'pgsql',
            'insert into users (name, email, password) values (?, ?, ?)',
            [$name, $mail, $hash],
            new PDOException('SQLSTATE[23502]: Not null violation: 7 ERROR: null value in column "x" violates not-null constraint' . "\nDETAIL:  Failing row contains (1, hello\n{$line2}, {$name}, {$mail}).\nHINT: {$hash}"),
        );

        report($query);

        $this->assertSame(1, $this->transport->count());

        $wire = $this->transport->wire();

        foreach ([$hash, $name, $mail, $line2] as $secret) {
            $this->assertStringNotContainsString($secret, $wire);
        }

        $this->assertSame(
            'Database error SQLSTATE[23502] (SQL: insert into users (name, email, password) values (?, ?, ?))',
            $this->transport->events()[0]->getExceptions()[0]->getValue(),
        );
    }

    public function test_a_pdo_exception_loses_its_quoted_literals(): void
    {
        $name = $this->secret('SECRETNAME');

        report(new PDOException('SQLSTATE[22P02]: Invalid text representation: 7 ERROR: invalid input syntax for type uuid: "' . $name . '"'));

        $this->assertStringNotContainsString($name, $this->transport->wire());
        $this->assertSame('Database error SQLSTATE[22P02]', $this->transport->events()[0]->getExceptions()[0]->getValue());
    }

    public function test_a_pdo_exception_without_a_state_is_a_bare_database_error(): void
    {
        $name = $this->secret('SECRETNAME');

        report(new PDOException('driver said "' . $name . '"'));

        $this->assertStringNotContainsString($name, $this->transport->wire());
        $this->assertSame('Database error', $this->transport->events()[0]->getExceptions()[0]->getValue());
    }

    public function test_a_database_exception_nested_in_a_wrapper_is_replaced_too(): void
    {
        $name = $this->secret('SECRETNAME');

        report(new RuntimeException('Import failed', 0, new PDOException('SQLSTATE[22P02]: bad value "' . $name . '"')));

        $this->assertStringNotContainsString($name, $this->transport->wire());

        $values = array_map(static fn ($bag): string => $bag->getValue(), $this->transport->events()[0]->getExceptions());

        $this->assertContains('Import failed', $values);
        $this->assertContains('Database error SQLSTATE[22P02]', $values);
    }

    public function test_the_sql_of_a_query_exception_is_the_one_with_placeholders(): void
    {
        $value = $this->secret('boundvalue');
        $query = new QueryException('pgsql', 'select * from users where email = ?', [$value], new PDOException('x'));

        $this->assertStringNotContainsString($value, $query->getSql());
    }

    public function test_a_message_without_a_database_class_is_only_generically_cleaned(): void
    {
        report(new RuntimeException('Plain failure of step 3'));

        $this->assertSame('Plain failure of step 3', $this->transport->events()[0]->getExceptions()[0]->getValue());
    }

    public function test_a_nested_job_that_throws_does_not_leave_its_tags_behind(): void
    {
        $this->startJob('App\\Jobs\\Outer');
        $this->startJob('App\\Jobs\\Inner');
        $this->app['events']->dispatch(new JobExceptionOccurred('sync', $this->fakeJob('App\\Jobs\\Inner'), new RuntimeException('inner')));
        $this->app['events']->dispatch(new JobProcessed('sync', $this->fakeJob('App\\Jobs\\Outer')));

        report(new RuntimeException('later'));

        $this->assertArrayNotHasKey('job', $this->transport->events()[0]->getTags());
    }

    public function test_the_tags_of_a_failing_job_survive_until_its_report(): void
    {
        $this->startJob('App\\Jobs\\A');
        $this->app['events']->dispatch(new JobExceptionOccurred('sync', $this->fakeJob('App\\Jobs\\A'), new RuntimeException('boom')));

        report(new RuntimeException('boom'));

        $this->assertSame('App\\Jobs\\A', $this->transport->events()[0]->getTags()['job']);
    }

    public function test_a_view_that_wraps_a_query_error_does_not_send_the_bindings(): void
    {
        $secret = $this->secret('viewbinding');

        View::addNamespace('sentrytest', dirname(__DIR__) . '/Fixtures/views');
        Route::get('/view-boom', static fn () => view('sentrytest::boom', ['secret' => $secret]));

        $this->get('/view-boom')->assertStatus(500);

        $this->assertSame(1, $this->transport->count());
        $this->assertStringNotContainsString($secret, $this->transport->wire());
        $this->assertStringContainsString('no_such_table_y', $this->transport->wire());

        $values = array_map(static fn ($bag): string => $bag->getValue(), $this->transport->events()[0]->getExceptions());

        $this->assertNotEmpty(array_filter($values, static fn (string $value): bool => str_contains($value, 'Database error SQLSTATE[')));
    }

    public function test_the_sentry_configuration_can_be_cached(): void
    {
        $config = config('sentry');

        // The recording transport is the tests' own addition.
        unset($config['transport']);

        $exported = eval('return ' . var_export($config, true) . ';');

        $this->assertSame(config('sentry.send_default_pii'), $exported['send_default_pii']);
        $this->assertTrue(is_callable($exported['before_send']));
    }

    public function test_a_finished_job_leaves_no_tags_on_a_later_exception(): void
    {
        $this->startJob('App\\Jobs\\A');
        $this->app['events']->dispatch(new JobProcessed('sync', $this->fakeJob('App\\Jobs\\A')));

        report(new RuntimeException('later'));

        $this->assertArrayNotHasKey('job', $this->transport->events()[0]->getTags());
    }

    public function test_the_worker_loop_and_stopping_forget_the_job(): void
    {
        foreach ([new Looping('sync', 'default'), new WorkerStopping(0)] as $event) {
            $this->startJob('App\\Jobs\\A');
            $this->app['events']->dispatch($event);
            report(new RuntimeException('after'));
        }

        $this->assertSame(2, $this->transport->count());

        foreach ($this->transport->events() as $event) {
            $this->assertArrayNotHasKey('job', $event->getTags());
        }
    }

    public function test_a_nested_job_gives_the_outer_one_back(): void
    {
        $this->startJob('App\\Jobs\\Outer');
        $this->startJob('App\\Jobs\\Inner');
        $this->app['events']->dispatch(new JobProcessed('sync', $this->fakeJob('App\\Jobs\\Inner')));

        report(new RuntimeException('in outer'));

        $this->assertSame('App\\Jobs\\Outer', $this->transport->events()[0]->getTags()['job']);
    }

    protected function sentryEnvironment(): array
    {
        return ['SENTRY_LARAVEL_DSN' => self::FAKE_DSN];
    }

    private function startJob(string $name): void
    {
        $this->app['events']->dispatch(new JobProcessing('sync', $this->fakeJob($name)));
    }

    private function fakeJob(string $name): Job
    {
        return new class ($name) extends Job implements JobContract {
            public function __construct(private readonly string $jobName)
            {
            }

            public function getJobId(): string
            {
                return '1';
            }

            public function getRawBody(): string
            {
                return '{}';
            }

            public function attempts(): int
            {
                return 1;
            }

            public function resolveName(): string
            {
                return $this->jobName;
            }

            public function getName(): string
            {
                return $this->jobName;
            }

            public function getQueue(): string
            {
                return 'default';
            }
        };
    }

    private function secret(string $name): string
    {
        return strrev('X9' . $name . '9X');
    }
}

final class FailingSentryJob implements ShouldQueue
{
    use Dispatchable;

    public function __construct(public string $secret, public string $email)
    {
    }

    public function handle(): void
    {
        throw new RuntimeException('job failed');
    }
}
