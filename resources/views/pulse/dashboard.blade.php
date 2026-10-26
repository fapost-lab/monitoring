<x-pulse>
    {{-- Shown only to whoever the contract lets see the Health surface; lazy, since a cold probe can take seconds. --}}
    <livewire:fapost.health cols="full" lazy />

    <livewire:pulse.servers cols="full" />

    @if (class_exists(\Laravel\Reverb\Pulse\Livewire\Connections::class))
        <livewire:reverb.connections cols="4" />
        <livewire:reverb.messages cols="8" />
    @endif

    <livewire:pulse.usage cols="4" rows="2" />

    <livewire:pulse.queues cols="4" />

    <livewire:pulse.cache cols="4" />

    <livewire:pulse.slow-queries cols="8" />

    <livewire:pulse.exceptions cols="6" />

    <livewire:pulse.slow-requests cols="6" />

    <livewire:pulse.slow-jobs cols="6" />

    <livewire:pulse.slow-outgoing-requests cols="6" />
</x-pulse>
