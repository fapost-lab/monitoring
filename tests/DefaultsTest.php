<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Fapost\Foundation\Operator\Enums\OperatorSurface;

final class DefaultsTest extends TestCase
{
    protected bool $logsEnabled = false;

    public function test_the_log_viewer_is_off_unless_switched_on_and_a_yes_does_not_switch_it_on(): void
    {
        $this->open = [OperatorSurface::Logs, OperatorSurface::Pulse];

        $this->assertFalse((bool) config('log-viewer.enabled'));
        $this->get('/log-viewer')->assertNotFound();
    }
}
