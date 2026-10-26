<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Pulse;

use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Fapost\Monitoring\Access\OperatorGate;
use Fapost\Monitoring\Health\HealthReader;
use Illuminate\Contracts\Support\Renderable;
use Illuminate\Support\Facades\View;
use Laravel\Pulse\Livewire\Card;

/**
 * The installation's health (Reverb, the webhook gateway and registry, the queues) as a Pulse card.
 *
 * Shown on Pulse's dashboard and on the package's own health page. The card asks the operator access contract for
 * {@see OperatorSurface::Health} on every render, the first one and every poll: on Pulse's dashboard the route only
 * checked {@see OperatorSurface::Pulse}. Without access it renders a hidden, empty element and reads nothing.
 */
final class HealthCard extends Card
{
    /**
     * The lazy placeholder: nothing for an operator without the Health surface, so Pulse's dashboard does not flash a
     * skeleton at someone who then gets an empty card.
     */
    public function placeholder(): Renderable
    {
        if (! app(OperatorGate::class)->allows(request(), OperatorSurface::Health)) {
            return View::make('monitoring::health.hidden');
        }

        return parent::placeholder();
    }

    public function render(): Renderable
    {
        if (! app(OperatorGate::class)->allows(request(), OperatorSurface::Health)) {
            return View::make('monitoring::health.hidden');
        }

        return View::make('monitoring::health.card', ['health' => app(HealthReader::class)->read()]);
    }
}
