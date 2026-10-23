<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Fapost\Foundation\Operator\Contracts\OperatorAccessInterface;
use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Fapost\Monitoring\Http\Middleware\AllowLogs;
use Fapost\Monitoring\Http\Middleware\AllowPulse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\Facades\Route;
use Livewire\Mechanisms\HandleRequests\HandleRequests;
use Livewire\Mechanisms\PersistentMiddleware\PersistentMiddleware;
use RuntimeException;
use stdClass;

final class AccessTest extends TestCase
{
    public function test_pulse_is_closed_when_the_contract_says_no(): void
    {
        $this->get('/pulse')->assertNotFound();
    }

    public function test_pulse_opens_only_for_its_own_surface(): void
    {
        $this->open = [OperatorSurface::Logs, OperatorSurface::Horizon];
        $this->get('/pulse')->assertNotFound();

        $this->open = [OperatorSurface::Pulse];
        $this->get('/pulse')->assertOk();
    }

    public function test_pulse_is_closed_when_the_contract_throws(): void
    {
        $this->app->singleton(OperatorAccessInterface::class, fn () => new class () implements OperatorAccessInterface {
            public function canView(Request $request, OperatorSurface $surface): bool
            {
                throw new RuntimeException('cannot tell');
            }
        });

        $this->get('/pulse')->assertNotFound();
    }

    public function test_pulse_is_closed_when_nothing_answers_the_contract(): void
    {
        $this->app->offsetUnset(OperatorAccessInterface::class);
        unset($this->app[OperatorAccessInterface::class]);
        $this->app->forgetInstance(OperatorAccessInterface::class);

        $this->get('/pulse')->assertNotFound();
    }

    public function test_the_view_pulse_gate_asks_the_contract_and_its_answer_is_not_a_gate_before_bypass(): void
    {
        $this->assertFalse(Gate::allows('viewPulse'));

        $this->open = [OperatorSurface::Pulse];
        $this->assertTrue(Gate::allows('viewPulse'));

        // A host whose administrators bypass gates (Core's Gate::before skips this ability, but a different host
        // might not) is still refused by the route.
        $this->open = [];
        Gate::before(static fn () => true);
        $this->get('/pulse')->assertNotFound();
    }

    public function test_pulse_middleware_keeps_the_stack_the_installation_configured(): void
    {
        $middleware = config('pulse.middleware');

        $this->assertSame('web', $middleware[0]);
        $this->assertContains(AllowPulse::class, $middleware);
        $this->assertLessThan(array_search(\Laravel\Pulse\Http\Middleware\Authorize::class, $middleware, true), array_search(AllowPulse::class, $middleware, true));
    }

    public function test_livewire_reapplies_the_surface_check_to_component_updates(): void
    {
        $this->assertContains(AllowPulse::class, app(PersistentMiddleware::class)->getPersistentMiddleware());

        // A real update: take a card's snapshot from the open dashboard, then ask again once access is gone.
        $payload = $this->updatePayload();

        $this->open = [];
        $this->postJson(app(HandleRequests::class)->getUpdateUri(), $payload, ['X-Livewire' => 'true'])->assertNotFound();
    }

    public function test_the_same_component_update_is_served_while_access_is_held(): void
    {
        // The control for the test above: its payload is valid, so that refusal is the check and not a broken request.
        $payload = $this->updatePayload();

        $this->postJson(app(HandleRequests::class)->getUpdateUri(), $payload, ['X-Livewire' => 'true'])->assertOk();
    }

    public function test_the_log_viewer_is_closed_when_the_contract_says_no_and_open_when_it_says_yes(): void
    {
        $this->get('/log-viewer')->assertNotFound();
        $this->getJson('/log-viewer/api/files')->assertNotFound();

        $this->open = [OperatorSurface::Logs];
        $this->get('/log-viewer')->assertOk();
        $this->getJson('/log-viewer/api/files')->assertOk();
    }

    public function test_the_log_viewer_stays_read_only_even_for_whoever_may_look(): void
    {
        $this->open = [OperatorSurface::Logs];

        $this->deleteJson('/log-viewer/api/files/abc')->assertNotFound();
        $this->postJson('/log-viewer/api/delete-multiple-files', ['files' => ['a']])->assertNotFound();
        $this->get('/log-viewer/api/files/abc/download')->assertNotFound();
        $this->getJson('/log-viewer/api/files/abc/download/request')->assertNotFound();

        foreach (['downloadLogFile', 'downloadLogFolder', 'deleteLogFile', 'deleteLogFolder'] as $ability) {
            $this->assertFalse(Gate::has($ability) && Gate::allows($ability, [new stdClass()]), $ability);
        }

        $this->assertContains(AllowLogs::class, config('log-viewer.middleware'));
        $this->assertContains(AllowLogs::class, config('log-viewer.api_middleware'));
    }

    public function test_every_route_of_an_operator_screen_carries_its_surface_middleware(): void
    {
        $checked = 0;

        foreach (Route::getRoutes() as $route) {
            $uri        = $route->uri();
            $middleware = app('router')->gatherRouteMiddleware($route);

            if (str_starts_with($uri, 'log-viewer')) {
                $this->assertContains(AllowLogs::class, $middleware, $uri);
                ++$checked;
            } elseif ('pulse' === $uri) {
                $this->assertContains(AllowPulse::class, $middleware, $uri);
                ++$checked;
            }
        }

        $this->assertGreaterThan(10, $checked, 'the log viewer\'s API routes and the dashboard were found');
    }

    public function test_the_viewer_serves_a_real_file_to_whoever_may_look_and_only_read_only_refuses_the_delete(): void
    {
        $name = 'monitoring-test-' . bin2hex(random_bytes(3)) . '.log';
        $path = storage_path('logs/' . $name);
        file_put_contents($path, "[2026-10-23 10:00:00] testing.ERROR: boom\n");

        try {
            $this->open = [OperatorSurface::Logs];

            $files = $this->getJson('/log-viewer/api/files')->assertOk()->json('0.files') ?? $this->getJson('/log-viewer/api/files')->json();
            $id    = collect(is_array($files) ? $files : [])->firstWhere('name', $name)['identifier'] ?? null;
            $this->assertNotNull($id, 'the file is listed');

            // Read-only (default): the delete is refused before the viewer looks at the file.
            $this->deleteJson("/log-viewer/api/files/{$id}")->assertNotFound();
            $this->assertFileExists($path);

            // The control: with the switch off the same request reaches the viewer (whatever it then answers), so
            // the 404 above was ours.
            config(['monitoring.logs.read_only' => false]);
            $this->assertNotSame(404, $this->deleteJson("/log-viewer/api/files/{$id}")->getStatusCode());
        } finally {
            @unlink($path);
        }
    }

    /**
     * @return array{components: list<array<string, mixed>>}
     */
    private function updatePayload(): array
    {
        $this->open = [OperatorSurface::Pulse];
        $html       = $this->get('/pulse')->assertOk()->getContent();

        preg_match('/wire:snapshot="([^"]+)"/', $html, $found);
        $this->assertNotEmpty($found, 'the dashboard carries a component snapshot');

        return ['components' => [['snapshot' => html_entity_decode($found[1]), 'updates' => new stdClass(), 'calls' => []]]];
    }
}
