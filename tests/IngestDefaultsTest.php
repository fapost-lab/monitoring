<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

final class IngestDefaultsTest extends TestCase
{
    protected ?string $ingest = null;

    public function test_ingest_goes_through_redis_unless_the_environment_says_otherwise(): void
    {
        $this->assertSame('redis', config('pulse.ingest.driver'));
    }
}
