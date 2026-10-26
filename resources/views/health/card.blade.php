<x-pulse::card :cols="$cols" :rows="$rows" :class="$class">
    {{-- Pulse's stylesheet is compiled for its own cards: the few rules this card needs travel with it. --}}
    <style>
        .fapost-health-grid { display: grid; gap: 1rem; grid-template-columns: repeat(auto-fit, minmax(14rem, 1fr)); }
        .fapost-health-service { display: flex; flex-direction: column; gap: .375rem; }
        .fapost-health-badge { display: inline-block; padding: .0625rem .5rem; border-radius: 9999px; font-size: .75rem; font-weight: 600; }
        .fapost-health-up { background: #dcfce7; color: #166534; }
        .fapost-health-down { background: #fee2e2; color: #991b1b; }
        .fapost-health-unknown { background: #fef3c7; color: #92400e; }
        .fapost-health-disabled, .fapost-health-not_monitored { background: #f3f4f6; color: #4b5563; }
        .dark .fapost-health-up { background: #14532d; color: #bbf7d0; }
        .dark .fapost-health-down { background: #7f1d1d; color: #fecaca; }
        .dark .fapost-health-unknown { background: #78350f; color: #fde68a; }
        .dark .fapost-health-disabled, .dark .fapost-health-not_monitored { background: #1f2937; color: #9ca3af; }
        .fapost-health-metrics { display: grid; grid-template-columns: 1fr auto; column-gap: .75rem; font-size: .75rem; }
    </style>

    <x-pulse::card-header
        name="Installation health"
        details="{{ $health['generated_at'] ? 'as of ' . $health['generated_at']->format('H:i:s') : '' }}"
    >
        <x-slot:icon>
            <x-pulse::icons.server />
        </x-slot:icon>
    </x-pulse::card-header>

    <x-pulse::scroll :expand="$expand" wire:poll.15s="">
        @if ($health['status'] === 'unavailable')
            <p class="text-sm text-gray-500 dark:text-gray-400">
                Installation health is not available in this version of FaPost Core.
            </p>
        @elseif ($health['status'] === 'unreadable')
            <p class="text-sm text-gray-500 dark:text-gray-400">
                Installation health could not be read. Try again in a moment.
            </p>
        @else
            <div class="fapost-health-grid">
                @foreach ($health['services'] as $service)
                    <div class="fapost-health-service" data-service="{{ $service['key'] }}" data-state="{{ $service['state'] }}">
                        <div class="flex items-center justify-between gap-2">
                            <span class="text-sm font-bold text-gray-700 dark:text-gray-300">{{ $service['label'] }}</span>
                            <span class="fapost-health-badge fapost-health-{{ $service['state'] }}">{{ $service['state_label'] }}</span>
                        </div>

                        @if ($service['reason'])
                            <p class="text-xs text-gray-600 dark:text-gray-400">{{ $service['reason'] }}</p>
                        @endif

                        @if ($service['metrics'])
                            <div class="fapost-health-metrics">
                                @foreach ($service['metrics'] as $metric)
                                    <span class="text-gray-500 dark:text-gray-400">{{ $metric['label'] }}</span>
                                    <span class="tabular-nums {{ $metric['measured'] ? 'text-gray-700 dark:text-gray-300' : 'text-gray-400 dark:text-gray-600' }}">{{ $metric['value'] }}</span>
                                @endforeach
                            </div>
                        @endif

                        @if ($service['endpoint'] || $service['checked_at'])
                            <p class="text-xs text-gray-400 dark:text-gray-600 truncate" @if ($service['checked_at']) title="{{ $service['checked_at']->toIso8601String() }}" @endif>
                                {{ $service['endpoint'] }}@if ($service['endpoint'] && $service['checked_at']) · @endif{{ $service['checked_at']?->diffForHumans() }}
                            </p>
                        @endif
                    </div>
                @endforeach
            </div>
        @endif
    </x-pulse::scroll>
</x-pulse::card>
