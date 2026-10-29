<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests\ErrorReporting;

use Fapost\Monitoring\Tests\ErrorReporting\Support\SentryTestCase;

final class ErrorReportingConfigTest extends SentryTestCase
{
    public function test_the_environment_cannot_switch_on_personal_data(): void
    {
        $this->assertFalse(config('sentry.send_default_pii'));
        $this->assertFalse(config('sentry.enable_logs'));
        $this->assertFalse(config('sentry.enable_metrics'));
        $this->assertFalse(config('sentry.spotlight'));
        $this->assertFalse(config('sentry.breadcrumbs.sql_bindings'));
        $this->assertFalse(config('sentry.breadcrumbs.logs'));
        $this->assertFalse(config('sentry.tracing.sql_bindings'));
        $this->assertSame(0.0, config('sentry.profiles_sample_rate'));
        $this->assertSame('none', config('sentry.max_request_body_size'));
        $this->assertNull(config('sentry.data_collection'));
    }

    public function test_the_client_runs_with_the_forced_options(): void
    {
        $options = $this->app->make(\Sentry\State\HubInterface::class)->getClient()->getOptions();

        $this->assertFalse($options->shouldSendDefaultPii());
        $this->assertSame('none', $options->getMaxRequestBodySize());
        $this->assertSame('staging', $options->getEnvironment());
        $this->assertSame('app-1.2.3', $options->getRelease());
        $this->assertSame(0.0, (float) $options->getTracesSampleRate());
    }
    protected function sentryEnvironment(): array
    {
        return [
            'SENTRY_LARAVEL_DSN'                      => self::FAKE_DSN,
            'SENTRY_SEND_DEFAULT_PII'                 => 'true',
            'SENTRY_ENABLE_LOGS'                      => 'true',
            'SENTRY_ENABLE_METRICS'                   => 'true',
            'SENTRY_SPOTLIGHT'                        => 'true',
            'SENTRY_BREADCRUMBS_SQL_BINDINGS_ENABLED' => 'true',
            'SENTRY_BREADCRUMBS_LOGS_ENABLED'         => 'true',
            'SENTRY_TRACE_SQL_BINDINGS_ENABLED'       => 'true',
            'SENTRY_PROFILES_SAMPLE_RATE'             => '1',
            'SENTRY_ENVIRONMENT'                      => 'staging',
            'SENTRY_RELEASE'                          => 'app-1.2.3',
        ];
    }
}

final class ErrorReportingTracesRateTest extends SentryTestCase
{
    public function test_the_traces_sample_rate_is_a_probability(): void
    {
        $this->assertSame(1.0, config('sentry.traces_sample_rate'));
    }
    protected function sentryEnvironment(): array
    {
        return ['SENTRY_LARAVEL_DSN' => self::FAKE_DSN, 'SENTRY_TRACES_SAMPLE_RATE' => '7'];
    }
}

final class ErrorReportingDefaultsTest extends SentryTestCase
{
    public function test_tracing_is_off_and_the_environment_is_the_application_s_by_default(): void
    {
        $this->assertSame(0.0, config('sentry.traces_sample_rate'));
        $this->assertSame($this->app->environment(), config('sentry.environment'));
        $this->assertNull(config('sentry.release'));
    }
}
