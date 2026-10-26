<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Fapost\Foundation\Operator\Contracts\OperatorAccessInterface;
use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Fapost\Monitoring\Http\Middleware\AllowTelescope;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\ServiceProvider;
use Laravel\Telescope\Http\Middleware\Authorize;
use Laravel\Telescope\Telescope;
use RuntimeException;

final class TelescopeAccessTest extends TestCase
{
    protected bool $telescopeEnabled = true;

    public function test_telescope_and_its_api_are_closed_when_the_contract_says_no(): void
    {
        $this->get('/telescope')->assertNotFound();
        $this->postJson('/telescope/telescope-api/requests')->assertNotFound();
    }

    public function test_telescope_opens_only_for_its_own_surface(): void
    {
        $this->open = [OperatorSurface::Pulse, OperatorSurface::Logs, OperatorSurface::Horizon];
        $this->get('/telescope')->assertNotFound();
        $this->postJson('/telescope/telescope-api/requests')->assertNotFound();

        $this->open = [OperatorSurface::Telescope];
        $this->get('/telescope')->assertOk();
        $this->postJson('/telescope/telescope-api/requests')->assertOk();
    }

    public function test_telescope_is_closed_when_the_contract_throws(): void
    {
        $this->app->singleton(OperatorAccessInterface::class, fn () => new class () implements OperatorAccessInterface {
            public function canView(Request $request, OperatorSurface $surface): bool
            {
                throw new RuntimeException('cannot tell');
            }
        });

        $this->get('/telescope')->assertNotFound();
    }

    public function test_telescope_is_closed_when_nothing_answers_the_contract(): void
    {
        unset($this->app[OperatorAccessInterface::class]);
        $this->app->forgetInstance(OperatorAccessInterface::class);

        $this->get('/telescope')->assertNotFound();
    }

    public function test_a_local_machine_does_not_open_it_without_the_contract(): void
    {
        $this->app['env'] = 'local';

        $this->assertFalse(Telescope::check(Request::create('/telescope')));
        $this->get('/telescope')->assertNotFound();
    }

    public function test_the_gate_and_telescopes_own_check_ask_the_contract(): void
    {
        $this->assertFalse(Gate::allows('viewTelescope'));
        $this->assertFalse(Telescope::check(Request::create('/telescope')));

        $this->open = [OperatorSurface::Telescope];

        $this->assertTrue(Gate::allows('viewTelescope'));
        $this->assertTrue(Telescope::check(Request::create('/telescope')));
    }

    public function test_a_hosts_own_telescope_authorization_does_not_win(): void
    {
        // HostOpensTelescope booted before the package's `booted` callback, as a host's provider does.
        $this->assertFalse(Telescope::check(Request::create('/telescope')));

        Gate::before(static fn () => true);
        $this->get('/telescope')->assertNotFound();
    }

    public function test_the_stack_runs_the_installations_steps_then_the_contract_then_telescopes_gate(): void
    {
        $middleware = config('telescope.middleware');

        $this->assertSame(['web', AllowTelescope::class, Authorize::class], $middleware);
    }

    protected function getPackageProviders($app): array
    {
        return [...parent::getPackageProviders($app), HostOpensTelescope::class];
    }
}

/**
 * What a host's TelescopeApplicationServiceProvider does while booting: opens Telescope to everybody.
 */
final class HostOpensTelescope extends ServiceProvider
{
    public function boot(): void
    {
        Telescope::auth(static fn (): bool => true);
    }
}
