<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests\ErrorReporting;

use Fapost\Monitoring\ErrorReporting\EventScrubber;
use Fapost\Monitoring\ErrorReporting\IgnoredExceptions;
use Fapost\Monitoring\ErrorReporting\JobContext;
use PDOException;
use PHPUnit\Framework\TestCase;
use RuntimeException;
use Sentry\Breadcrumb;
use Sentry\Event;
use Sentry\EventHint;
use Symfony\Component\HttpKernel\Exception\HttpException;
use Throwable;

final class EventScrubberTest extends TestCase
{
    private JobContext $job;

    protected function setUp(): void
    {
        $this->job = new JobContext();
    }

    public function test_sensitive_keys_are_replaced_at_any_depth(): void
    {
        $event = Event::createEvent();
        $event->setExtra(['nested' => ['_token' => 'A', 'Password' => 'B', 'apiKey' => 'C', 'cookie' => 'D', 'authorization' => 'E', 'email' => 'F', 'message' => 'G', 'name' => 'N', 'supportToken' => 'H', 'plan' => 'pro']]);

        $out = $this->scrubber()->beforeSend($event, null);

        $this->assertSame(['_token' => '[redacted]', 'Password' => '[redacted]', 'apiKey' => '[redacted]', 'cookie' => '[redacted]', 'authorization' => '[redacted]', 'email' => '[redacted]', 'message' => '[redacted]', 'name' => '[redacted]', 'supportToken' => '[redacted]', 'plan' => 'pro'], $out->getExtra()['nested']);
    }

    public function test_text_loses_addresses_and_credentials_and_is_capped(): void
    {
        $event = Event::createEvent();
        $event->setMessage('Mail to bob@example.com failed, Authorization: Bearer xyz123 at /x?token=ABC&password=hunter2 ' . str_repeat('a', 2000));

        $message = $this->scrubber()->beforeSend($event, null)->getMessage();

        foreach (['bob@example.com', 'xyz123', 'ABC', 'hunter2'] as $secret) {
            $this->assertStringNotContainsString($secret, $message);
        }

        $this->assertLessThan(600, mb_strlen($message));
    }

    public function test_the_request_keeps_only_the_method_and_a_clean_url(): void
    {
        $event = Event::createEvent();
        $event->setRequest([
            'method'       => 'POST',
            'url'          => 'https://saas.test/signup/confirm/abcdefghijklmnopqrstuvwxyz0123?token=T',
            'query_string' => 'token=T',
            'headers'      => ['authorization' => 'Bearer X'],
            'cookies'      => ['s' => 'C'],
            'data'         => ['password' => 'P'],
        ]);

        $request = $this->scrubber()->beforeSend($event, null)->getRequest();

        $this->assertSame(['method' => 'POST', 'url' => 'https://saas.test/signup/confirm/[redacted]'], $request);
    }

    public function test_lists_and_depth_are_capped(): void
    {
        $event = Event::createEvent();
        $event->setExtra(['list' => range(1, 500), 'deep' => ['a' => ['b' => ['c' => ['d' => ['e' => ['f' => 'x']]]]]]]);

        $extra = $this->scrubber()->beforeSend($event, null)->getExtra();

        $this->assertLessThanOrEqual(31, count($extra['list']));
        $this->assertStringNotContainsString('"f"', json_encode($extra['deep']));
    }

    public function test_breadcrumbs_are_cleaned(): void
    {
        $event = Event::createEvent();
        $event->setBreadcrumb([new Breadcrumb(Breadcrumb::LEVEL_INFO, Breadcrumb::TYPE_DEFAULT, 'queue.job', 'for a@b.com', ['password' => 'P', 'job' => 'App\Job'])]);

        $crumb = $this->scrubber()->beforeSend($event, null)->getBreadcrumbs()[0];

        $this->assertSame('for [email]', $crumb->getMessage());
        $this->assertSame(['password' => '[redacted]', 'job' => 'App\Job'], $crumb->getMetadata());
    }

    public function test_the_running_job_becomes_tags_and_nothing_else_is_added(): void
    {
        $this->job->begin('App\\Jobs\\Sync', 'mail.system');

        $tags = $this->scrubber()->beforeSend(Event::createEvent(), null)->getTags();

        $this->assertSame(['job' => 'App\\Jobs\\Sync', 'queue' => 'mail.system'], $tags);

        $this->job->clear();

        $this->assertSame([], $this->scrubber()->beforeSend(Event::createEvent(), null)->getTags());
    }

    public function test_client_errors_are_dropped_and_server_errors_are_kept(): void
    {
        $scrubber = $this->scrubber();

        $this->assertNull($scrubber->beforeSend(Event::createEvent(), EventHint::fromArray(['exception' => new HttpException(404)])));
        $this->assertNull($scrubber->beforeSend(Event::createEvent(), EventHint::fromArray(['exception' => new HttpException(419)])));
        $this->assertNotNull($scrubber->beforeSend(Event::createEvent(), EventHint::fromArray(['exception' => new HttpException(500)])));
        $this->assertNotNull($scrubber->beforeSend(Event::createEvent(), EventHint::fromArray(['exception' => new RuntimeException('x')])));
    }

    public function test_a_wrapper_that_copies_a_database_message_is_cleaned(): void
    {
        $secret  = strrev('X9wrapsecret9X');
        $query   = $this->databaseError($secret);
        $wrapper = new RuntimeException($query->getMessage() . ' (View: /app/x.blade.php)', 0, $query);

        $values = $this->valuesOf($wrapper);

        $this->assertStringNotContainsString($secret, implode("\n", $values));
        $this->assertStringContainsString('Database error SQLSTATE[23502] (SQL: select * from users where email = ?) (View: /app/x.blade.php)', $values[0]);
    }

    public function test_a_wrapper_two_levels_above_the_database_error_is_cleaned(): void
    {
        $secret = strrev('X9deepsecret9X');
        $query  = $this->databaseError($secret);
        $middle = new RuntimeException('middle', 0, $query);
        $outer  = new RuntimeException('Outer: ' . $query->getMessage(), 0, $middle);

        $values = $this->valuesOf($outer);

        $this->assertStringNotContainsString($secret, implode("\n", $values));
        $this->assertSame('middle', $values[1]);
    }

    public function test_a_wrapper_with_a_paraphrased_driver_text_is_cut_at_the_driver_text(): void
    {
        $secret  = strrev('X9paraphrase9X');
        $query   = $this->databaseError($secret);
        $wrapper = new RuntimeException('Import: SQLSTATE[22P02] bad "' . $secret . '" (View: /v.blade.php)', 0, $query);

        $values = $this->valuesOf($wrapper);

        $this->assertStringNotContainsString($secret, implode("\n", $values));
        $this->assertStringStartsWith('Import: Database error SQLSTATE[23502]', $values[0]);
        $this->assertStringEndsWith(' (View: /v.blade.php)', $values[0]);
    }

    public function test_a_wrapper_without_a_database_exception_below_it_is_not_cut(): void
    {
        $values = $this->valuesOf(new RuntimeException('Docs say SQLSTATE[HY000] is general'));

        $this->assertSame(['Docs say SQLSTATE[HY000] is general'], $values);
    }

    public function test_the_user_is_never_sent(): void
    {
        $event = Event::createEvent();
        $event->setUser(\Sentry\UserDataBag::createFromUserIdentifier('42'));

        $this->assertNull($this->scrubber()->beforeSend($event, null)->getUser());
    }

    private function databaseError(string $secret): \Illuminate\Database\QueryException
    {
        return new \Illuminate\Database\QueryException(
            'pgsql',
            'select * from users where email = ?',
            [$secret],
            new PDOException('SQLSTATE[23502]: Not null violation: 7 ERROR: bad' . "\nDETAIL:  Failing row contains (1, {$secret}\n{$secret}2).\nHINT: {$secret}3"),
        );
    }

    /**
     * @return list<string> the values of the exceptions of the event the scrubber lets through
     */
    private function valuesOf(Throwable $thrown): array
    {
        $event = Event::createEvent();
        $bags  = [];

        for ($current = $thrown; null !== $current; $current = $current->getPrevious()) {
            $bags[] = new \Sentry\ExceptionDataBag($current);
        }

        $event->setExceptions($bags);

        $out = $this->scrubber()->beforeSend($event, EventHint::fromArray(['exception' => $thrown]));

        return array_map(static fn ($bag): string => $bag->getValue(), $out->getExceptions());
    }

    private function scrubber(): EventScrubber
    {
        return new EventScrubber(new IgnoredExceptions(), $this->job);
    }
}
