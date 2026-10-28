<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests\ErrorReporting;

use Fapost\Monitoring\ErrorReporting\ErrorReporting;
use Fapost\Monitoring\ErrorReporting\JobContext;
use Fapost\Monitoring\Tests\ErrorReporting\Support\SentryTestCase;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use RuntimeException;
use Sentry\State\HubInterface;

final class ErrorReportingOffTest extends SentryTestCase
{
    public function test_without_a_dsn_the_application_boots_and_the_integration_is_off(): void
    {
        $this->assertFalse((new ErrorReporting($this->app))->enabled());
        $this->assertNull(config('sentry.dsn'));
        $this->assertNull($this->app->make(HubInterface::class)->getClient()->getOptions()->getDsn());
    }

    public function test_without_a_dsn_nothing_is_reported_and_nothing_is_hooked(): void
    {
        report(new RuntimeException('not sent'));

        $this->assertSame(0, $this->transport->count());

        try {
            FailingOffJob::dispatch();
        } catch (RuntimeException) {
            // expected
        }

        $this->assertNull($this->app->make(JobContext::class)->job());
    }
}

final class FailingOffJob implements ShouldQueue
{
    use Dispatchable;

    public function handle(): void
    {
        throw new RuntimeException('failing');
    }
}
