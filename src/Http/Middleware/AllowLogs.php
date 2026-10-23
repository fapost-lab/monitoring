<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Http\Middleware;

use Closure;
use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

/**
 * The log viewer's gate. Besides the contract it keeps the viewer read-only: Core's administrators pass
 * `Gate::before` on any ability it does not list, so the viewer's own download and delete abilities cannot
 * be trusted to refuse them.
 */
final class AllowLogs extends AllowOperatorSurface
{
    public function handle(Request $request, Closure $next): Response
    {
        if ((bool) config('monitoring.logs.read_only', true) && $this->writes($request)) {
            throw new NotFoundHttpException();
        }

        return parent::handle($request, $next);
    }
    protected function surface(): OperatorSurface
    {
        return OperatorSurface::Logs;
    }

    private function writes(Request $request): bool
    {
        return $request->isMethod('DELETE')
            || 1 === preg_match('#/(download|delete-multiple-files)(/|$)#', $request->getPathInfo());
    }
}
