<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Http\Middleware;

use Closure;
use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Fapost\Monitoring\Access\OperatorGate;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

/**
 * Lets a request through to an operator screen only when the operator access contract says so.
 *
 * A refusal is a 404, so that the screen does not confirm it exists. One class per surface rather than a
 * middleware parameter: Livewire re-applies a screen's middleware to its component updates by class name
 * and drops the parameters.
 */
abstract class AllowOperatorSurface
{
    public function __construct(private readonly OperatorGate $gate)
    {
    }

    abstract protected function surface(): OperatorSurface;

    public function handle(Request $request, Closure $next): Response
    {
        if (! $this->gate->allows($request, $this->surface())) {
            throw new NotFoundHttpException();
        }

        return $next($request);
    }
}
