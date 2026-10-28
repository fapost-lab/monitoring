<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests\ErrorReporting\Support;

use Sentry\Event;
use Sentry\Options;
use Sentry\Serializer\PayloadSerializer;
use Sentry\Transport\Result;
use Sentry\Transport\ResultStatus;
use Sentry\Transport\TransportInterface;

/**
 * Stands in for Sentry's HTTP transport: nothing leaves the process. It keeps each event as it would have been
 * serialized for the wire, so a test can search everything that would have been sent.
 */
final class RecordingSentryTransport implements TransportInterface
{
    /** @var list<string> */
    private array $payloads = [];

    /** @var list<Event> */
    private array $events = [];

    public function __construct(private readonly Options $options)
    {
    }

    public function send(Event $event): Result
    {
        $this->events[]   = $event;
        $this->payloads[] = (new PayloadSerializer($this->options))->serialize($event);

        return new Result(ResultStatus::success(), $event);
    }

    public function close(?int $timeout = null): Result
    {
        return new Result(ResultStatus::success());
    }

    /**
     * @return list<Event>
     */
    public function events(): array
    {
        return $this->events;
    }

    public function count(): int
    {
        return count($this->events);
    }

    /**
     * Everything that would have been sent, as one string.
     */
    public function wire(): string
    {
        return implode("\n", $this->payloads);
    }
}
