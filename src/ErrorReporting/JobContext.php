<?php

declare(strict_types=1);

namespace Fapost\Monitoring\ErrorReporting;

/**
 * The queue job a worker is running now: its name and queue, nothing else. The payload is never kept.
 *
 * A job's exception is reported by the worker after the job's own scope has ended, so the tags cannot live on Sentry's
 * scope; the event scrubber reads them from here when the event is sent. Jobs nest (a job run inline by another), so
 * the running jobs form a stack: a finished inner job gives the outer one back. The worker loop and a stopping worker
 * forget everything. Held in a singleton on purpose: it is process state of a worker, reset by the events above.
 */
final class JobContext
{
    /** @var list<array{0: string, 1: ?string, 2: bool}> job, queue, failed */
    private array $running = [];

    public function begin(string $job, ?string $queue): void
    {
        $this->dropFailed();
        $this->running[] = [$job, $queue, false];
    }

    /**
     * The top job ended normally; a job above it that failed (and was caught by it) is gone with it.
     */
    public function finish(): void
    {
        $this->dropFailed();
        array_pop($this->running);
    }

    /**
     * The top job threw. Its tags stay for the report that follows, and are dropped by whatever comes next.
     */
    public function fail(): void
    {
        $top = array_key_last($this->running);

        if (null !== $top) {
            $this->running[$top][2] = true;
        }
    }

    public function clear(): void
    {
        $this->running = [];
    }

    public function job(): ?string
    {
        $top = array_key_last($this->running);

        return null === $top ? null : $this->running[$top][0];
    }

    public function queue(): ?string
    {
        $top = array_key_last($this->running);

        return null === $top ? null : $this->running[$top][1];
    }

    private function dropFailed(): void
    {
        while ([] !== $this->running && $this->running[array_key_last($this->running)][2]) {
            array_pop($this->running);
        }
    }
}
