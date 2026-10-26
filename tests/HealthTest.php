<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use DateTimeImmutable;
use Fapost\Foundation\Health\Contracts\InstallationHealthInterface;
use Fapost\Foundation\Health\DTO\HealthMetric;
use Fapost\Foundation\Health\DTO\InstallationHealthReport;
use Fapost\Foundation\Health\DTO\ServiceHealth;
use Fapost\Foundation\Health\Enums\HealthState;
use Fapost\Foundation\Health\Enums\HealthUnit;
use Fapost\Foundation\Health\Enums\MonitoredService;
use Fapost\Foundation\Operator\Contracts\OperatorAccessInterface;
use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Fapost\Monitoring\Http\Middleware\AllowHealth;
use Fapost\Monitoring\MonitoringServiceProvider;
use Fapost\Monitoring\Pulse\HealthCard;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use Livewire\Livewire;
use Livewire\Mechanisms\HandleRequests\HandleRequests;
use Livewire\Mechanisms\PersistentMiddleware\PersistentMiddleware;
use RuntimeException;
use stdClass;

final class HealthTest extends TestCase
{
    private const PATH = '/' . MonitoringServiceProvider::HEALTH_PATH;

    /** How many times the fake contract was asked for a report. */
    private int $reads = 0;

    public function test_the_page_is_closed_when_the_contract_does_not_open_the_health_surface(): void
    {
        $this->bindReport($this->report());

        $this->get(self::PATH)->assertNotFound();

        $this->open = [OperatorSurface::Pulse, OperatorSurface::Telescope, OperatorSurface::Logs, OperatorSurface::Horizon];
        $this->get(self::PATH)->assertNotFound();

        $this->assertSame(0, $this->reads, 'nothing is read for a refused request');
    }

    public function test_the_page_is_closed_when_the_access_contract_throws_or_is_not_bound(): void
    {
        $this->bindReport($this->report());

        $this->app->singleton(OperatorAccessInterface::class, static fn () => new class () implements OperatorAccessInterface {
            public function canView(Request $request, OperatorSurface $surface): bool
            {
                throw new RuntimeException('cannot tell');
            }
        });
        $this->get(self::PATH)->assertNotFound();

        $this->app->offsetUnset(OperatorAccessInterface::class);
        $this->app->forgetInstance(OperatorAccessInterface::class);
        $this->assertFalse($this->app->bound(OperatorAccessInterface::class));
        $this->get(self::PATH)->assertNotFound();

        $this->assertSame(0, $this->reads);
    }

    public function test_the_page_shows_every_service_with_its_state_reason_and_figures(): void
    {
        $this->bindReport($this->report());
        $this->open = [OperatorSurface::Health];

        $html = $this->get(self::PATH)->assertOk()->getContent();

        $this->assertStringContainsString('data-service="reverb" data-state="up"', $html);
        $this->assertStringContainsString('data-service="gateway" data-state="down"', $html);
        $this->assertStringContainsString('The gateway reports 2 failed deliveries.', $html);
        $this->assertStringContainsString('gateway.internal:8080', $html);
        $this->assertStringContainsString('data-service="webhook_registry" data-state="disabled"', $html);
        $this->assertStringContainsString('Connections', $html);
        $this->assertStringContainsString('1,204', $html);
        $this->assertStringContainsString('Spec (telegram)', $html);
        $this->assertStringContainsString('differs', $html);
    }

    public function test_a_service_left_out_of_the_report_is_not_monitored_and_never_up(): void
    {
        $this->bindReport($this->report());
        $this->open = [OperatorSurface::Health];

        $html = $this->get(self::PATH)->assertOk()->getContent();

        $this->assertStringContainsString('data-service="queues" data-state="not_monitored"', $html);
        $this->assertStringContainsString('Not monitored', $html);
    }

    public function test_a_figure_that_could_not_be_measured_is_shown_as_such_not_as_zero(): void
    {
        $this->bindReport(new InstallationHealthReport([
            new ServiceHealth(MonitoredService::Queues, HealthState::Unknown, 'The queue probe has not run yet.', new DateTimeImmutable(), null, [
                new HealthMetric('wait_seconds', null, HealthUnit::Seconds, 'default'),
                new HealthMetric('throughput', 42, HealthUnit::PerMinute, 'default'),
            ]),
        ], new DateTimeImmutable()));
        $this->open = [OperatorSurface::Health];

        $html = $this->get(self::PATH)->assertOk()->getContent();

        $this->assertStringContainsString('data-service="queues" data-state="unknown"', $html);
        $this->assertMatchesRegularExpression('#Wait \(default\)</span>\s*<span[^>]*>not measured</span>#', $html);
        $this->assertStringContainsString('42 / min', $html);
    }

    public function test_without_a_binding_the_page_says_the_figures_are_unavailable_in_this_core(): void
    {
        $this->assertFalse($this->app->bound(InstallationHealthInterface::class));
        $this->open = [OperatorSurface::Health];

        $this->get(self::PATH)->assertOk()->assertSee('not available in this version of FaPost Core');
    }

    public function test_a_contract_that_throws_anyway_is_reported_as_unreadable_not_as_an_error(): void
    {
        $this->app->bind(InstallationHealthInterface::class, static fn () => new class () implements InstallationHealthInterface {
            public function report(): InstallationHealthReport
            {
                throw new RuntimeException('probe exploded');
            }
        });
        $this->open = [OperatorSurface::Health];

        $this->get(self::PATH)->assertOk()->assertSee('could not be read')->assertDontSee('probe exploded');
    }

    public function test_the_card_reads_nothing_and_shows_nothing_without_the_health_surface(): void
    {
        $this->bindReport($this->report());
        $this->open = [OperatorSurface::Pulse];

        Livewire::test(HealthCard::class)->assertDontSee('Installation health')->assertDontSee('Webhook gateway');

        $this->assertSame(0, $this->reads);

        $this->open = [OperatorSurface::Health];
        Livewire::test(HealthCard::class)->assertSee('Installation health')->assertSee('Webhook gateway');
    }

    public function test_pulses_dashboard_carries_the_card(): void
    {
        $this->open = [OperatorSurface::Pulse];

        $this->get('/pulse')->assertOk()->assertSee('fapost.health', false);
    }

    public function test_livewire_reapplies_the_health_check_to_the_pages_card_updates(): void
    {
        $this->assertContains(AllowHealth::class, app(PersistentMiddleware::class)->getPersistentMiddleware());

        $payload = $this->pageCardPayload();

        $this->open = [];
        $this->postJson(app(HandleRequests::class)->getUpdateUri(), $payload, ['X-Livewire' => 'true'])->assertNotFound();
    }

    public function test_the_same_card_update_is_served_while_access_is_held(): void
    {
        // The control for the test above: its payload is valid, so that refusal is the check and not a broken request.
        $payload = $this->pageCardPayload();

        $this->postJson(app(HandleRequests::class)->getUpdateUri(), $payload, ['X-Livewire' => 'true'])
            ->assertOk()
            ->assertSee('Webhook gateway');
    }

    public function test_the_page_route_carries_the_health_middleware(): void
    {
        $route = Route::getRoutes()->getByName('monitoring.health');

        $this->assertNotNull($route);
        $this->assertContains(AllowHealth::class, app('router')->gatherRouteMiddleware($route));
        $this->assertSame('web', $route->middleware()[0]);
    }

    public function countRead(): void
    {
        ++$this->reads;
    }

    /**
     * @return array{components: list<array<string, mixed>>}
     */
    private function pageCardPayload(): array
    {
        $this->bindReport($this->report());
        $this->open = [OperatorSurface::Health];
        $html       = $this->get(self::PATH)->assertOk()->getContent();

        preg_match_all('/wire:snapshot="([^"]+)"/', $html, $found);
        $snapshot = collect($found[1])
            ->map(static fn (string $snapshot): string => html_entity_decode($snapshot))
            ->first(static fn (string $snapshot): bool => str_contains($snapshot, 'fapost.health'));
        $this->assertNotNull($snapshot, 'the page carries the card\'s snapshot');

        return ['components' => [['snapshot' => $snapshot, 'updates' => new stdClass(), 'calls' => []]]];
    }

    private function bindReport(InstallationHealthReport $report): void
    {
        $this->app->bind(InstallationHealthInterface::class, fn () => new class ($report, $this) implements InstallationHealthInterface {
            public function __construct(private readonly InstallationHealthReport $report, private readonly HealthTest $case)
            {
            }

            public function report(): InstallationHealthReport
            {
                $this->case->countRead();

                return $this->report;
            }
        });
    }

    private function report(): InstallationHealthReport
    {
        $now = new DateTimeImmutable();

        return new InstallationHealthReport([
            new ServiceHealth(MonitoredService::Reverb, HealthState::Up, 'Reverb answers.', $now, 'reverb:8080', [
                new HealthMetric('connections', 1204, HealthUnit::Count),
                new HealthMetric('channels', 31, HealthUnit::Count),
            ]),
            new ServiceHealth(MonitoredService::Gateway, HealthState::Down, 'The gateway reports 2 failed deliveries.', $now, 'http://gateway.internal:8080/health', [
                new HealthMetric('spec_status', 'differs', HealthUnit::Text, 'telegram'),
            ]),
            new ServiceHealth(MonitoredService::WebhookRegistry, HealthState::Disabled, 'The webhook gateway is switched off.', $now),
        ], $now);
    }
}
