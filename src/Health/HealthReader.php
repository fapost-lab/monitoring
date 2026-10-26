<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Health;

use Carbon\CarbonImmutable;
use Fapost\Foundation\Health\Contracts\InstallationHealthInterface;
use Fapost\Foundation\Health\DTO\HealthMetric;
use Fapost\Foundation\Health\DTO\InstallationHealthReport;
use Fapost\Foundation\Health\DTO\ServiceHealth;
use Fapost\Foundation\Health\Enums\HealthState;
use Fapost\Foundation\Health\Enums\HealthUnit;
use Fapost\Foundation\Health\Enums\MonitoredService;
use Illuminate\Contracts\Container\Container;
use Throwable;

/**
 * Reads the installation health contract and turns its report into rows a view can print.
 *
 * It does not decide who may see the figures: the caller asks the operator access contract first. It never throws:
 * a Core that predates the contract leaves it unbound ("unavailable"), and an implementation that throws anyway is
 * "unreadable". A case of an enum this package does not know yet is shown as unknown, a metric that could not be
 * measured as "not measured", and a service the report leaves out as "not monitored" — never as up.
 *
 * @phpstan-type MetricRow array{label: string, value: string, measured: bool}
 * @phpstan-type ServiceRow array{key: string, label: string, state: 'up'|'down'|'unknown'|'disabled'|'not_monitored', state_label: string, reason: ?string, endpoint: ?string, checked_at: ?CarbonImmutable, metrics: list<MetricRow>}
 */
final readonly class HealthReader
{
    public const STATUS_READY = 'ready';

    public const STATUS_UNAVAILABLE = 'unavailable';

    public const STATUS_UNREADABLE = 'unreadable';

    private const SERVICE_LABELS = [
        'reverb'           => 'Live updates (Reverb)',
        'gateway'          => 'Webhook gateway',
        'webhook_registry' => 'Webhook registry',
        'queues'           => 'Queues',
    ];

    private const METRIC_LABELS = [
        'connections'      => 'Connections',
        'channels'         => 'Channels',
        'spec_status'      => 'Spec',
        'drifted_channels' => 'Drifted channels',
        'missing'          => 'Missing',
        'stale'            => 'Stale',
        'orphaned'         => 'Orphaned',
        'wait_seconds'     => 'Wait',
        'throughput'       => 'Throughput',
        'failed_jobs'      => 'Failed jobs',
    ];

    public function __construct(private Container $container)
    {
    }

    /**
     * @return array{status: 'ready'|'unavailable'|'unreadable', generated_at: ?CarbonImmutable, services: list<ServiceRow>}
     */
    public function read(): array
    {
        if (! $this->container->bound(InstallationHealthInterface::class)) {
            return ['status' => self::STATUS_UNAVAILABLE, 'generated_at' => null, 'services' => []];
        }

        try {
            $report = $this->container->make(InstallationHealthInterface::class)->report();
        } catch (Throwable) {
            return ['status' => self::STATUS_UNREADABLE, 'generated_at' => null, 'services' => []];
        }

        return [
            'status'       => self::STATUS_READY,
            'generated_at' => CarbonImmutable::instance($report->generatedAt),
            'services'     => $this->services($report),
        ];
    }

    /**
     * Every service this version of Foundation knows, in its order: the ones the report leaves out are "not monitored".
     *
     * @return list<ServiceRow>
     */
    private function services(InstallationHealthReport $report): array
    {
        $rows = [];

        foreach (MonitoredService::cases() as $service) {
            $health = $report->service($service);

            $rows[] = null === $health ? [
                'key'         => $service->value,
                'label'       => $this->serviceLabel($service),
                'state'       => 'not_monitored',
                'state_label' => 'Not monitored',
                'reason'      => null,
                'endpoint'    => null,
                'checked_at'  => null,
                'metrics'     => [],
            ] : $this->service($health);
        }

        return $rows;
    }

    /**
     * @return ServiceRow
     */
    private function service(ServiceHealth $health): array
    {
        $state = match ($health->state) {
            HealthState::Up       => 'up',
            HealthState::Down     => 'down',
            HealthState::Disabled => 'disabled',
            default               => 'unknown',
        };

        return [
            'key'         => $health->service->value,
            'label'       => $this->serviceLabel($health->service),
            'state'       => $state,
            'state_label' => ucfirst($state),
            'reason'      => $health->reason,
            'endpoint'    => $health->endpoint,
            'checked_at'  => CarbonImmutable::instance($health->checkedAt),
            'metrics'     => array_map($this->metric(...), $health->metrics),
        ];
    }

    /**
     * @return MetricRow
     */
    private function metric(HealthMetric $metric): array
    {
        $label = self::METRIC_LABELS[$metric->name] ?? ucfirst(str_replace('_', ' ', $metric->name));

        if (null !== $metric->subject) {
            $label .= ' (' . $metric->subject . ')';
        }

        if (null === $metric->value) {
            return ['label' => $label, 'value' => 'not measured', 'measured' => false];
        }

        $value = is_string($metric->value) ? $metric->value : $this->number($metric->value);

        $value = match ($metric->unit) {
            HealthUnit::Seconds   => $value . ' s',
            HealthUnit::PerMinute => $value . ' / min',
            default               => $value,
        };

        return ['label' => $label, 'value' => $value, 'measured' => true];
    }

    private function number(int|float $value): string
    {
        if (is_int($value)) {
            return number_format($value);
        }

        // Up to three decimals, trailing zeros dropped: 0.04 stays 0.04, 12.5 stays 12.5, 3.0 becomes 3.
        return mb_rtrim(mb_rtrim(number_format($value, 3), '0'), '.');
    }

    private function serviceLabel(MonitoredService $service): string
    {
        return self::SERVICE_LABELS[$service->value] ?? ucfirst(str_replace('_', ' ', $service->value));
    }
}
