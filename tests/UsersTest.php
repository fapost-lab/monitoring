<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Fapost\Monitoring\Pulse\NeutralUsers;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Schema;
use Illuminate\View\ViewException;
use InvalidArgumentException;
use Laravel\Pulse\Contracts\ResolvesUsers;
use Laravel\Pulse\Facades\Pulse;
use Laravel\Pulse\Livewire\Usage;
use Laravel\Pulse\Users;
use Livewire\Livewire;
use Orchestra\Testbench\Attributes\WithEnv;

/**
 * The schema of these tests has no `users` table, as the platform host of a schema-per-tenant installation:
 * the Usage card must be drawn from the recorded ids alone.
 */
final class UsersTest extends TestCase
{
    private const ID = '01a15eeb7q3c0000000000abcd';

    public function test_the_users_table_is_absent_from_every_connection(): void
    {
        $this->assertFalse(Schema::connection('sqlite')->hasTable('users'));
        $this->assertFalse(Schema::connection('landlord')->hasTable('users'));
    }

    public function test_the_usage_card_is_drawn_without_the_users_table(): void
    {
        $this->recordUserRequest();

        Livewire::test(Usage::class, ['lazy' => false])
            ->assertOk()
            ->assertSee('user 0000abcd');
    }

    public function test_the_default_resolver_reads_no_table_and_shows_no_personal_data(): void
    {
        $resolver = Pulse::resolveUsers(new Collection([self::ID, 7]));

        $this->assertInstanceOf(NeutralUsers::class, $resolver);
        $this->assertEquals((object) ['name' => 'user 0000abcd', 'extra' => ''], $resolver->find(self::ID));
        $this->assertSame('user 7', $resolver->find(7)->name);
        $this->assertFalse(isset($resolver->find(self::ID)->avatar));
    }

    public function test_pulses_own_lookup_is_what_true_asks_for_and_it_needs_the_table(): void
    {
        config(['monitoring.pulse.resolve_users' => true]);
        $this->app->forgetInstance(ResolvesUsers::class);

        $this->assertInstanceOf(Users::class, $this->app->make(ResolvesUsers::class));

        $this->recordUserRequest();

        $this->expectException(ViewException::class);
        $this->expectExceptionMessageMatches('/no such table: users/');

        Livewire::test(Usage::class, ['lazy' => false]);
    }

    public function test_a_callable_in_the_setting_names_the_users(): void
    {
        config(['monitoring.pulse.resolve_users' => static fn (Collection $ids): array => $ids
            ->map(static fn ($id): array => ['id' => $id, 'name' => 'Operator ' . $id])
            ->all()]);
        $this->app->forgetInstance(ResolvesUsers::class);

        $this->recordUserRequest();

        Livewire::test(Usage::class, ['lazy' => false])->assertSee('Operator ' . self::ID);
    }

    public function test_the_class_of_an_invokable_resolver_in_the_setting_is_made_by_the_container(): void
    {
        config(['monitoring.pulse.resolve_users' => InvokableResolver::class]);
        $this->app->forgetInstance(ResolvesUsers::class);

        $this->recordUserRequest();

        Livewire::test(Usage::class, ['lazy' => false])->assertSee('Invoked ' . self::ID);
    }

    public function test_the_application_calling_pulse_users_wins_over_the_setting(): void
    {
        Pulse::users(static fn (Collection $ids): Collection => $ids
            ->map(static fn ($id): array => ['id' => $id, 'name' => 'Own ' . $id]));

        $this->recordUserRequest();

        Livewire::test(Usage::class, ['lazy' => false])->assertSee('Own ' . self::ID);
    }

    public function test_pulse_user_does_not_fail_on_the_default_resolver(): void
    {
        Pulse::user(static fn (): array => ['name' => 'ignored']);

        $this->assertSame('user 0000abcd', Pulse::resolveUsers(new Collection([self::ID]))->find(self::ID)->name);
    }

    #[WithEnv('MONITORING_PULSE_ENABLED', 'false')]
    public function test_nothing_breaks_while_pulse_is_off(): void
    {
        $this->assertFalse(config('pulse.enabled'));
        $this->assertSame('user 0000abcd', Pulse::resolveUsers(new Collection([self::ID]))->find(self::ID)->name);
        $this->assertNull(Pulse::resolveAuthenticatedUserId());
    }

    public function test_a_missing_key_has_a_label_and_a_setting_that_is_unusable_is_refused(): void
    {
        $this->assertSame('user ?', (new NeutralUsers())->find(null)->name);

        config(['monitoring.pulse.resolve_users' => 'yes']);
        $this->app->forgetInstance(ResolvesUsers::class);

        $this->expectException(InvalidArgumentException::class);

        $this->app->make(ResolvesUsers::class);
    }

    public function test_a_static_method_string_is_cache_safe_and_works(): void
    {
        config(['monitoring.pulse.resolve_users' => InvokableResolver::class . '::named']);
        $this->app->forgetInstance(ResolvesUsers::class);

        $this->assertSame('Static 1', Pulse::resolveUsers(new Collection([1]))->find(1)->name);
    }

    public function test_the_recorded_identifier_is_the_key_alone(): void
    {
        $user = new class (self::ID) extends Model implements \Illuminate\Contracts\Auth\Authenticatable {
            use \Illuminate\Auth\Authenticatable;

            public function __construct(private readonly string $id = '')
            {
                parent::__construct();
            }

            public function getAuthIdentifier(): string
            {
                return $this->id;
            }
        };

        $this->assertSame(self::ID, (new NeutralUsers())->key($user));
    }

    protected function defineEnvironment($app): void
    {
        parent::defineEnvironment($app);

        $app['config']->set('auth.providers.users.model', UserModel::class);
    }

    private function recordUserRequest(): void
    {
        app(\Laravel\Pulse\Pulse::class)->record('user_request', self::ID)->count();
        app(\Laravel\Pulse\Pulse::class)->ingest();
    }
}

final class UserModel extends Model
{
    protected $table = 'users';
}

final class InvokableResolver
{
    /**
     * @param  Collection<int, string>  $ids
     * @return list<array{id: string, name: string}>
     */
    public function __invoke(Collection $ids): array
    {
        return $ids->map(static fn ($id): array => ['id' => $id, 'name' => 'Invoked ' . $id])->values()->all();
    }
    /**
     * @param  Collection<int, mixed>  $ids
     * @return list<array{id: mixed, name: string}>
     */
    public static function named(Collection $ids): array
    {
        return $ids->map(static fn ($id): array => ['id' => $id, 'name' => 'Static ' . $id])->values()->all();
    }
}
