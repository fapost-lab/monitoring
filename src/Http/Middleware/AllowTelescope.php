<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Http\Middleware;

use Fapost\Foundation\Operator\Enums\OperatorSurface;

/**
 * Telescope's gate: its screen and its `telescope-api` routes are one route group, so one check covers both.
 */
final class AllowTelescope extends AllowOperatorSurface
{
    protected function surface(): OperatorSurface
    {
        return OperatorSurface::Telescope;
    }
}
