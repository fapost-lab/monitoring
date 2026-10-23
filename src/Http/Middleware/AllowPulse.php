<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Http\Middleware;

use Fapost\Foundation\Operator\Enums\OperatorSurface;

final class AllowPulse extends AllowOperatorSurface
{
    protected function surface(): OperatorSurface
    {
        return OperatorSurface::Pulse;
    }
}
