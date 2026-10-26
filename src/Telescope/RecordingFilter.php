<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Telescope;

use Illuminate\Container\Container;
use Illuminate\Contracts\Foundation\Application;
use Laravel\Telescope\IncomingEntry;

/**
 * Which entries Telescope keeps.
 *
 * Everything when `monitoring.telescope.record_all` says so (by default: on a `local` machine). Otherwise only
 * what an operator needs after something went wrong: reportable exceptions, failed requests and jobs, scheduled
 * tasks, and entries carrying a tag an operator chose to monitor. The application and its setting are looked up on
 * every call, never captured: Telescope keeps its filters in static state, which outlives an application instance.
 */
final readonly class RecordingFilter
{
    public function __invoke(IncomingEntry $entry): bool
    {
        $app = Container::getInstance();

        return ($app instanceof Application && self::recordsAll($app))
            || $entry->isReportableException()
            || $entry->isFailedRequest()
            || $entry->isFailedJob()
            || $entry->isScheduledTask()
            || $entry->hasMonitoredTag();
    }
    public static function recordsAll(Application $app): bool
    {
        $setting = $app->make('config')->get('monitoring.telescope.record_all');

        if (null === $setting || '' === $setting) {
            return $app->environment('local');
        }

        return filter_var($setting, FILTER_VALIDATE_BOOLEAN);
    }
}
