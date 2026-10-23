<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Pulse;

use Illuminate\Contracts\Auth\Authenticatable;
use Illuminate\Support\Collection;
use Laravel\Pulse\Contracts\ResolvesUsers;

/**
 * Pulse's user resolver that never reads a table.
 *
 * Pulse's own resolver looks recorded user ids up through the model of `auth.providers.users.model` on the
 * default connection. In a schema-per-tenant installation that table lives in a tenant's schema: on the
 * platform host it is absent (the Usage card answers 500), and platform operators and tenant users live in
 * different places, so one query by id would not find all of them anyway. A recorded id is answered with a
 * short label made of the id itself, so that nothing here depends on where users are stored, and no name,
 * e-mail or avatar ever reaches the dashboard.
 *
 * An application replaces it by calling `Pulse::users()` (which binds its own resolver after this one) or
 * through `monitoring.pulse.resolve_users`.
 */
final class NeutralUsers implements ResolvesUsers
{
    private const LABEL_LENGTH = 8;

    public function key(Authenticatable $user): int|string|null
    {
        return $user->getAuthIdentifier();
    }

    public function load(Collection $keys): self
    {
        return $this;
    }

    /**
     * @return object{name: string, extra: string}
     */
    public function find(int|string|null $key): object
    {
        return (object) [
            // The tail: the head of a ULID is its timestamp, the same for users made in the same second.
            'name'  => null === $key || '' === (string) $key ? 'user ?' : 'user ' . mb_substr((string) $key, -self::LABEL_LENGTH),
            'extra' => '',
        ];
    }

    /**
     * Part of what `Pulse::user()` needs from a resolver. There is no loaded user to apply a field resolver
     * to, so it is accepted and left unused: an application that wants names binds a resolver of its own.
     *
     * @param  callable(Authenticatable): array<string, mixed>  $resolver
     */
    public function setFieldResolver(callable $resolver): self
    {
        return $this;
    }
}
