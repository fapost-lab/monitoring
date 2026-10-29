<?php

declare(strict_types=1);

namespace Fapost\Monitoring\ErrorReporting;

use Illuminate\Contracts\Config\Repository;
use Illuminate\Contracts\Debug\ExceptionHandler;
use Illuminate\Contracts\Events\Dispatcher;
use Illuminate\Contracts\Foundation\Application;
use Illuminate\Foundation\Exceptions\Handler;
use Illuminate\Queue\Events\JobExceptionOccurred;
use Illuminate\Queue\Events\JobFailed;
use Illuminate\Queue\Events\JobProcessed;
use Illuminate\Queue\Events\JobProcessing;
use Illuminate\Queue\Events\Looping;
use Illuminate\Queue\Events\WorkerStopping;
use Sentry\Laravel\Integration;
use Throwable;

/**
 * Error reporting to Sentry for an installation: privacy first, off without a DSN.
 *
 * `sentry/sentry-laravel` is found by package discovery and reads the `sentry` configuration. This class owns that
 * configuration: once every provider has registered and none has booted ({@see configure()}) it writes the
 * installation's settings (`monitoring.error_reporting`, from the environment) and forces the privacy settings over
 * whatever the environment or a published `config/sentry.php` says, so no variable can switch on personal data, request
 * bodies, local variables, logs, metrics, SQL bindings or Spotlight. The scrubber ({@see EventScrubber}) is the
 * `before_send` of every event, transaction and breadcrumb.
 *
 * Without a DSN {@see enable()} does nothing: no handler hook, no listener, and Sentry's own client has no transport.
 * With one, unhandled exceptions are sent from Laravel's exception handler, so web requests, queue workers (Horizon),
 * the scheduler and console commands all reach Sentry the same way: each of them reports its exception through the
 * handler. Core's own `bootstrap/app.php` is not touched.
 */
final class ErrorReporting
{
    public function __construct(private readonly Application $app)
    {
    }

    public function register(): void
    {
        $this->app->singleton(JobContext::class);
        $this->app->singleton(IgnoredExceptions::class);
        $this->app->singleton(EventScrubber::class, fn (): EventScrubber => new EventScrubber(
            $this->app->make(IgnoredExceptions::class),
            $this->app->make(JobContext::class),
        ));

        // Sentry's provider merges its default file while registering, in an order that depends on package names;
        // writing after all of them leaves nothing to merge over.
        $this->app->booting($this->configure(...));
    }

    public function enable(): void
    {
        if (! $this->enabled()) {
            return;
        }

        $handler = $this->app->make(ExceptionHandler::class);

        if ($handler instanceof Handler) {
            // After Laravel's own "do not report" list (validation, authentication, 404, 419 and other HTTP errors).
            // Returns nothing, so the log channels still report the exception.
            $handler->reportable(static function (Throwable $exception): void {
                try {
                    Integration::captureUnhandledException($exception);
                } catch (Throwable) {
                    // Reporting must never fail the request, the job or the command that is being reported.
                }
            });
        }

        $jobs   = $this->app->make(JobContext::class);
        $events = $this->app->make(Dispatcher::class);

        // Name and queue only: the job's payload is never read.
        $events->listen(JobProcessing::class, static function (JobProcessing $event) use ($jobs): void {
            try {
                $jobs->begin($event->job->resolveName(), $event->job->getQueue());
            } catch (Throwable) {
                $jobs->begin('unknown', null);
            }
        });
        $events->listen(JobProcessed::class, static fn () => $jobs->finish());
        $events->listen([JobExceptionOccurred::class, JobFailed::class], static fn () => $jobs->fail());
        $events->listen([Looping::class, WorkerStopping::class], static fn () => $jobs->clear());
    }

    public function enabled(): bool
    {
        return filled($this->config()->get('sentry.dsn'));
    }

    public function configure(): void
    {
        $config = $this->config();
        $ours   = (array) $config->get('monitoring.error_reporting', []);
        $dsn    = $ours['dsn'] ?? null;
        $rate   = is_numeric($ours['traces_sample_rate'] ?? null) ? min(1.0, max(0.0, (float) $ours['traces_sample_rate'])) : 0.0;

        $sentry = (array) $config->get('sentry', []);

        $sentry = array_replace_recursive($sentry, [
            'dsn'                   => filled($dsn) ? (string) $dsn : null,
            'environment'           => filled($ours['environment'] ?? null) ? (string) $ours['environment'] : $this->app->environment(),
            'release'               => filled($ours['release'] ?? null) ? (string) $ours['release'] : null,
            'traces_sample_rate'    => $rate,
            'profiles_sample_rate'  => 0.0,
            'send_default_pii'      => false,
            'data_collection'       => null,
            'spotlight'             => false,
            'max_request_body_size' => 'none',
            'enable_logs'           => false,
            'enable_metrics'        => false,
            'breadcrumbs'           => [
                'logs'                 => false,
                'cache'                => false,
                'livewire'             => false,
                'sql_queries'          => false,
                'sql_bindings'         => false,
                'http_client_requests' => false,
                'notifications'        => false,
                'command_info'         => false,
            ],
            'tracing' => [
                'sql_queries'          => false,
                'sql_bindings'         => false,
                'views'                => false,
                'livewire'             => false,
                'http_client_requests' => false,
                'cache'                => false,
                'redis_commands'       => false,
                'notifications'        => false,
                'missing_routes'       => false,
            ],
        ]);

        $sentry['ignore_exceptions']       = IgnoredExceptions::CLASSES;
        $sentry['before_send']             = [EventScrubber::class, 'send'];
        $sentry['before_send_transaction'] = [EventScrubber::class, 'send'];
        $sentry['before_breadcrumb']       = [EventScrubber::class, 'sendBreadcrumb'];

        $config->set('sentry', $sentry);
    }

    private function config(): Repository
    {
        return $this->app->make('config');
    }
}
