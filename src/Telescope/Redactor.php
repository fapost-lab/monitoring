<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Telescope;

use Laravel\Telescope\EntryType;
use Laravel\Telescope\IncomingEntry;

/**
 * Masks what Telescope's own hiding lists do not reach, before anything is written to storage.
 *
 * Telescope hides listed parameters in a request's payload and listed headers, but keeps a request's URI with
 * its query string (`?token=…`, a signed URL's `signature`) and an outgoing call's full URL (a bot API puts its
 * token in the path: `https://api.telegram.org/bot<id>:<token>/sendMessage`). Exception and log messages repeat
 * such URLs. Applied by {@see RedactingEntriesRepository} to new entries and to the updates written into them.
 */
final class Redactor
{
    public const string MASK = '********';

    /**
     * Request and response parameters never stored: the support entry's single-use `token`, channel secrets,
     * passwords and credentials. Applied to payloads by Telescope and to query strings here.
     *
     * @var list<string>
     */
    public const array PARAMETERS = [
        '_token',
        'token',
        'secret_token',
        'password',
        'password_confirmation',
        'current_password',
        'secret',
        'client_secret',
        'access_token',
        'refresh_token',
        'api_key',
        'signature',
    ];

    /**
     * Request headers never stored, in every environment.
     *
     * @var list<string>
     */
    public const array HEADERS = [
        'cookie',
        'authorization',
        'php-auth-pw',
        'x-csrf-token',
        'x-xsrf-token',
        'x-telegram-bot-api-secret-token',
    ];

    /**
     * Response parameters never stored.
     *
     * @var list<string>
     */
    public const array RESPONSE_PARAMETERS = [
        'token',
        'secret_token',
        'access_token',
        'refresh_token',
        'password',
    ];

    /** A bot token in a URL path (`/bot123456:AAE…/`). */
    private const string BOT_TOKEN = '#/bot\d+:[A-Za-z0-9_-]+#';

    /**
     * @param list<string> $parameters the query keys to mask, lower case
     */
    public function __construct(private readonly array $parameters = self::PARAMETERS)
    {
    }

    /**
     * Rewrites the entry in place; always "keep".
     */
    public function __invoke(IncomingEntry $entry): bool
    {
        if (in_array($entry->type, [EntryType::REQUEST, EntryType::CLIENT_REQUEST], true) && is_string($entry->content['uri'] ?? null)) {
            $entry->content['uri'] = $this->maskQuery($entry->content['uri']);
        }

        $entry->content = $this->maskStrings($entry->content);

        return true;
    }

    /**
     * The changes of an entry update (a failed job's exception, a response written later).
     *
     * @param array<array-key, mixed> $changes
     *
     * @return array<array-key, mixed>
     */
    public function maskChanges(array $changes): array
    {
        if (is_string($changes['uri'] ?? null)) {
            $changes['uri'] = $this->maskQuery($changes['uri']);
        }

        return $this->maskStrings($changes);
    }

    /**
     * Masks the values of listed keys in a URI's query string, keeping the keys.
     */
    public function maskQuery(string $uri): string
    {
        $start = mb_strpos($uri, '?');

        if (false === $start) {
            return $uri;
        }

        $fragment = '';
        $query    = mb_substr($uri, $start + 1);
        $hash     = mb_strpos($query, '#');

        if (false !== $hash) {
            $fragment = mb_substr($query, $hash);
            $query    = mb_substr($query, 0, $hash);
        }

        $pairs = array_map(function (string $pair): string {
            [$key] = explode('=', $pair, 2);

            $name = mb_strtolower(urldecode($key));
            $name = (string) preg_replace('/\[.*$/', '', $name);

            return in_array($name, $this->parameters, true) ? $key . '=' . self::MASK : $pair;
        }, explode('&', $query));

        return mb_substr($uri, 0, $start + 1) . implode('&', $pairs) . $fragment;
    }

    /**
     * @param array<array-key, mixed> $content
     *
     * @return array<array-key, mixed>
     */
    private function maskStrings(array $content): array
    {
        foreach ($content as $key => $value) {
            if (is_string($value)) {
                $content[$key] = (string) preg_replace(self::BOT_TOKEN, '/bot' . self::MASK, $value);
            } elseif (is_array($value)) {
                $content[$key] = $this->maskStrings($value);
            }
        }

        return $content;
    }
}
