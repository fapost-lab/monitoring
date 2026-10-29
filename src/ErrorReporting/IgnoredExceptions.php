<?php

declare(strict_types=1);

namespace Fapost\Monitoring\ErrorReporting;

use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;
use Throwable;

/**
 * The exceptions that are expected noise and never go to Sentry: a missing page (404), an expired form (419),
 * a failed validation (422), a guest or a refused user (401, 403, the operator screens' access denials), a throttled
 * client (429), a malformed or aborted request. Every HTTP exception below 500 is a client error by definition and
 * is ignored with the listed classes; a 5xx HTTP exception and every other exception are reported.
 */
final class IgnoredExceptions
{
    /** @var list<class-string<Throwable>> */
    public const array CLASSES = [
        \Illuminate\Auth\AuthenticationException::class,
        \Illuminate\Auth\Access\AuthorizationException::class,
        \Illuminate\Validation\ValidationException::class,
        \Illuminate\Session\TokenMismatchException::class,
        \Illuminate\Http\Exceptions\ThrottleRequestsException::class,
        \Illuminate\Http\Exceptions\HttpResponseException::class,
        \Illuminate\Http\Exceptions\PostTooLargeException::class,
        \Illuminate\Database\Eloquent\ModelNotFoundException::class,
        \Symfony\Component\HttpKernel\Exception\NotFoundHttpException::class,
        \Symfony\Component\HttpKernel\Exception\AccessDeniedHttpException::class,
        \Symfony\Component\HttpKernel\Exception\TooManyRequestsHttpException::class,
        \Symfony\Component\HttpFoundation\Exception\RequestExceptionInterface::class,
    ];

    public function ignores(Throwable $exception): bool
    {
        foreach (self::CLASSES as $class) {
            if ($exception instanceof $class) {
                return true;
            }
        }

        return $exception instanceof HttpExceptionInterface && $exception->getStatusCode() < 500;
    }
}
