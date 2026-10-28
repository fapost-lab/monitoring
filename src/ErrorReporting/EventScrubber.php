<?php

declare(strict_types=1);

namespace Fapost\Monitoring\ErrorReporting;

use Illuminate\Container\Container;
use Illuminate\Database\QueryException;
use PDOException;
use Sentry\Breadcrumb;
use Sentry\Event;
use Sentry\EventHint;
use Throwable;

/**
 * The `before_send` of the error reports: decides what leaves the installation.
 *
 * Allow-list first: an event keeps its exception type, message, stack trace, route name, environment and release,
 * and the tags `job` and `queue`. Everything that can carry a customer's data is dropped, not filtered: the
 * request's headers, cookies, body, query string and client address, the user, local variables of stack frames,
 * attachments. What remains free-form (extra data, contexts, breadcrumbs, tags, messages) is cleaned: a value under a
 * sensitive key (tokens, passwords, secrets, cookies, authorization, e-mail addresses, names, phone numbers, the text
 * of contact messages) is replaced, text is stripped of e-mail addresses, bearer credentials and `key=value` secrets,
 * and strings, lists and nesting are capped so an event stays small.
 *
 * Any failure drops the event: a report that cannot be proven clean is not sent.
 */
final class EventScrubber
{
    public const string REDACTED = '[redacted]';

    private const int MAX_STRING = 500;

    private const int MAX_ITEMS = 30;

    private const int MAX_DEPTH = 5;

    /** A key that contains one of these is sensitive. */
    private const array SENSITIVE_PARTS = ['token', 'password', 'passwd', 'secret', 'authorization', 'cookie', 'api_key', 'apikey', 'credential', 'csrf', 'xsrf', 'signature', 'session', 'bearer', 'private_key'];

    /** A key equal to one of these is sensitive: personal data and the content of messages people wrote. */
    private const array SENSITIVE_KEYS = ['email', 'e_mail', 'phone', 'message', 'body', 'content', 'text', 'subject', 'comment', 'payload', 'username', 'name', 'first_name', 'last_name', 'full_name', 'contact'];

    public function __construct(
        private readonly IgnoredExceptions $ignored,
        private readonly JobContext $job,
    ) {
    }

    /**
     * The `before_send` callable kept in the Sentry configuration: a static callable, because a Closure cannot be
     * written by `config:cache`.
     */
    public static function send(Event $event, ?EventHint $hint = null): ?Event
    {
        return Container::getInstance()->make(self::class)->beforeSend($event, $hint);
    }

    public static function sendBreadcrumb(Breadcrumb $breadcrumb): ?Breadcrumb
    {
        return Container::getInstance()->make(self::class)->beforeBreadcrumb($breadcrumb);
    }

    public function beforeSend(Event $event, ?EventHint $hint = null): ?Event
    {
        try {
            if (null !== $hint?->exception && $this->ignored->ignores($hint->exception)) {
                return null;
            }

            return $this->scrub($event, $hint?->exception);
        } catch (Throwable) {
            return null;
        }
    }

    public function beforeBreadcrumb(Breadcrumb $breadcrumb): ?Breadcrumb
    {
        try {
            return $this->breadcrumb($breadcrumb);
        } catch (Throwable) {
            return null;
        }
    }

    private function scrub(Event $event, ?Throwable $thrown): Event
    {
        $event->setRequest($this->request($event->getRequest()));
        $event->setUser(null);
        $event->setAttachments([]);
        $event->setExtra($this->array($event->getExtra(), 0));

        foreach ($event->getContexts() as $name => $data) {
            $event->setContext((string) $name, $this->array($data, 0));
        }

        $tags = [];

        foreach ($event->getTags() as $key => $value) {
            $tags[(string) $key] = $this->text((string) $value);
        }

        $event->setTags($tags);
        $this->tag($event, 'job', $this->job->job());
        $this->tag($event, 'queue', $this->job->queue());

        $event->setBreadcrumb(array_values(array_filter(array_map(fn (Breadcrumb $crumb): ?Breadcrumb => $this->breadcrumb($crumb), $event->getBreadcrumbs()))));

        $message = $event->getMessage();

        if (null !== $message) {
            $event->setMessage($this->text($message), $this->array($event->getMessageParams(), 0), null === $event->getMessageFormatted() ? null : $this->text($event->getMessageFormatted()));
        }

        $transaction = $event->getTransaction();

        if (null !== $transaction) {
            $event->setTransaction($this->url($transaction));
        }

        $exceptions = $event->getExceptions();

        $databases = $this->databaseExceptions($thrown);

        foreach ($exceptions as $exception) {
            $exception->setValue($this->exceptionValue($exception->getType(), $exception->getValue(), $databases));

            foreach ($exception->getStacktrace()?->getFrames() ?? [] as $frame) {
                $frame->setVars([]);
            }
        }

        $event->setExceptions($exceptions);

        foreach ($event->getStacktrace()?->getFrames() ?? [] as $frame) {
            $frame->setVars([]);
        }

        foreach ($event->getSpans() as $span) {
            $span->setData($this->array($span->getData(), 0));
            $span->setDescription(null === $span->getDescription() ? null : $this->url($span->getDescription()));
        }

        return $event;
    }

    /**
     * The database exceptions of the thrown chain with their raw messages and the fixed texts that replace them. A
     * driver message quotes values (a failing row, an invalid literal, a duplicate key) in forms no pattern can list, so
     * none of it is forwarded: only the SQLSTATE code and, for a query exception, the SQL with its placeholders (never
     * the bindings and never the raw SQL with values).
     *
     * @return list<array{0: class-string, 1: string, 2: string}> class, raw message, replacement
     */
    private function databaseExceptions(?Throwable $thrown): array
    {
        $found = [];

        for ($current = $thrown; null !== $current; $current = $current->getPrevious()) {
            if ($this->isDatabaseClass($current::class)) {
                $found[] = [$current::class, $current->getMessage(), $this->databaseMessage($current, $current->getMessage())];
            }
        }

        return $found;
    }

    /**
     * The value of one exception of the event. A database exception is replaced as a whole. Any other exception may
     * carry a database message in its own (the view engine wraps a query error with the view's name): the raw message is
     * replaced inside it; and when the chain holds a database exception and the value still shows a driver or SQL text,
     * the value is cut where that text starts, keeping a trailing ` (View: ...)` part.
     *
     * @param list<array{0: class-string, 1: string, 2: string}> $databases
     */
    private function exceptionValue(string $type, string $value, array $databases): string
    {
        foreach ($databases as [$class, , $replacement]) {
            if ($class === $type) {
                return $replacement;
            }
        }

        if ($this->isDatabaseClass($type)) {
            return $this->databaseMessage(null, $value);
        }

        $replaced = false;

        foreach ($databases as [, $raw, $replacement]) {
            if ('' !== $raw && str_contains($value, $raw)) {
                $value    = str_replace($raw, $replacement, $value);
                $replaced = true;
            }
        }

        if (! $replaced && [] !== $databases) {
            $cut = mb_strpos($value, 'SQLSTATE[');

            if (false === $cut) {
                $cut = mb_strpos($value, ' (SQL: ');
            }

            if (false !== $cut) {
                $suffix = mb_strrpos($value, ' (View:');
                $value  = mb_substr($value, 0, $cut) . $databases[0][2] . (false !== $suffix && $suffix > $cut ? mb_substr($value, $suffix) : '');
            }
        }

        return $this->text($value);
    }

    private function isDatabaseClass(string $class): bool
    {
        foreach ([QueryException::class, PDOException::class, 'Doctrine\\DBAL\\Exception', 'Doctrine\\DBAL\\Driver\\Exception'] as $family) {
            if (is_a($class, $family, true)) {
                return true;
            }
        }

        return false;
    }

    private function databaseMessage(?Throwable $exception, string $message): string
    {
        $code = $this->sqlState($exception, $message);
        $text = 'Database error' . (null === $code ? '' : ' SQLSTATE[' . $code . ']');

        if ($exception instanceof QueryException) {
            $text .= ' (SQL: ' . mb_substr($exception->getSql(), 0, 1000) . ')';
        }

        return $text;
    }

    private function sqlState(?Throwable $exception, string $message): ?string
    {
        for ($current = $exception; null !== $current; $current = $current->getPrevious()) {
            if ($current instanceof PDOException && is_array($current->errorInfo) && is_string($current->errorInfo[0] ?? null) && 1 === preg_match('/^[0-9A-Z]{5}$/', $current->errorInfo[0])) {
                return $current->errorInfo[0];
            }

            if (1 === preg_match('/SQLSTATE\[([0-9A-Z]{5})\]/', $current->getMessage(), $found)) {
                return $found[1];
            }
        }

        return 1 === preg_match('/SQLSTATE\[([0-9A-Z]{5})\]/', $message, $found) ? $found[1] : null;
    }

    /**
     * @param array<array-key, mixed> $request
     *
     * @return array<string, string>
     */
    private function request(array $request): array
    {
        $kept = [];

        if (isset($request['method']) && is_string($request['method'])) {
            $kept['method'] = $request['method'];
        }

        if (isset($request['url']) && is_string($request['url'])) {
            $kept['url'] = $this->url($request['url']);
        }

        return $kept;
    }

    private function breadcrumb(Breadcrumb $crumb): Breadcrumb
    {
        $message = $crumb->getMessage();

        return new Breadcrumb(
            $crumb->getLevel(),
            $crumb->getType(),
            $crumb->getCategory(),
            null === $message ? null : $this->text($message),
            $this->array($crumb->getMetadata(), 0),
            $crumb->getTimestamp(),
        );
    }

    private function tag(Event $event, string $key, ?string $value): void
    {
        if (null !== $value && '' !== $value) {
            $event->setTag($key, mb_substr($value, 0, 200));
        }
    }

    /**
     * @param array<array-key, mixed> $data
     *
     * @return array<array-key, mixed>
     */
    private function array(array $data, int $depth): array
    {
        if ($depth >= self::MAX_DEPTH) {
            return ['_' => '[nested too deep]'];
        }

        $clean = [];

        foreach ($data as $key => $value) {
            if (count($clean) >= self::MAX_ITEMS) {
                $clean['_'] = '[' . (count($data) - self::MAX_ITEMS) . ' more items]';

                break;
            }

            $clean[$key] = is_string($key) && $this->sensitive($key) ? self::REDACTED : $this->value($value, $depth);
        }

        return $clean;
    }

    private function value(mixed $value, int $depth): mixed
    {
        return match (true) {
            is_string($value)                  => $this->text($value),
            is_array($value)                   => $this->array($value, $depth + 1),
            null === $value, is_scalar($value) => $value,
            is_object($value)                  => '[object ' . $value::class . ']',
            default                            => '[' . get_debug_type($value) . ']',
        };
    }

    private function sensitive(string $key): bool
    {
        $snake      = mb_strtolower((string) preg_replace('/(?<=[a-z0-9])(?=[A-Z])/', '_', $key));
        $normalized = mb_trim((string) preg_replace('/[^a-z0-9]+/', '_', $snake), '_');

        if (in_array($normalized, self::SENSITIVE_KEYS, true)) {
            return true;
        }

        foreach (self::SENSITIVE_PARTS as $part) {
            if (str_contains($normalized, $part)) {
                return true;
            }
        }

        return false;
    }

    /**
     * Free text with the credentials and addresses taken out, and cut to a length that cannot hide a pasted body.
     */
    private function text(string $text): string
    {
        $text = (string) preg_replace('/DETAIL:.*$/m', 'DETAIL: [redacted]', $text);
        $text = (string) preg_replace('/[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}/', '[email]', $text);
        $text = (string) preg_replace('/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/=\-]+/i', '$1 ' . self::REDACTED, $text);
        $text = (string) preg_replace('/([\w\-]*(?:token|password|passwd|secret|api[_\-]?key|authorization|cookie|signature|session)[\w\-]*)(["\']?\s*[=:]\s*["\']?)[^\s&"\',;}]+/i', '$1$2' . self::REDACTED, $text);

        return mb_strlen($text) > self::MAX_STRING ? mb_substr($text, 0, self::MAX_STRING) . '...[truncated]' : $text;
    }

    /**
     * An address or a route name without its query string and fragment, and without path segments that look like
     * a one-time token (a long run of letters, digits, dashes and underscores).
     */
    private function url(string $url): string
    {
        $url = (string) preg_replace('/[?#].*$/s', '', $url);
        $url = (string) preg_replace('~(?<=/)[A-Za-z0-9_\-]{24,}(?=/|$)~', self::REDACTED, $url);

        return $this->text($url);
    }
}
