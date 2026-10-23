<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Access;

use Fapost\Foundation\Operator\Contracts\OperatorAccessInterface;
use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Illuminate\Contracts\Container\Container;
use Illuminate\Http\Request;
use Throwable;

/**
 * The only place this package asks the operator access contract.
 *
 * Fails closed: no binding, an exception or anything but a plain `true` is a "no".
 */
final readonly class OperatorGate
{
    public function __construct(private Container $container)
    {
    }

    public function allows(Request $request, OperatorSurface $surface): bool
    {
        try {
            if (! $this->container->bound(OperatorAccessInterface::class)) {
                return false;
            }

            return true === $this->container->make(OperatorAccessInterface::class)->canView($request, $surface);
        } catch (Throwable) {
            return false;
        }
    }
}
