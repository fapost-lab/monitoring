<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Http\Middleware;

use Fapost\Foundation\Operator\Enums\OperatorSurface;

final class AllowHealth extends AllowOperatorSurface
{
    protected function surface(): OperatorSurface
    {
        return OperatorSurface::Health;
    }
}
