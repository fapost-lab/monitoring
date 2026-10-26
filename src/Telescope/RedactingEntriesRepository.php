<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Telescope;

use Illuminate\Support\Collection;
use Laravel\Telescope\EntryUpdate;
use Laravel\Telescope\IncomingEntry;
use Laravel\Telescope\Storage\DatabaseEntriesRepository;

/**
 * Telescope's database storage with the {@see Redactor} applied to everything written: new entries and the
 * updates written into them later.
 *
 * A Telescope filter sees new entries only. An update goes straight to storage: a job's entry is recorded as
 * pending and receives its exception (message and trace) as an update when it fails, and a Guzzle message
 * carries the full URL, a bot token in it. Masking here covers both paths, including updates retried from the
 * queue (`ProcessPendingUpdates` calls the same repository).
 */
final class RedactingEntriesRepository extends DatabaseEntriesRepository
{
    private ?Redactor $redactor = null;

    public function redactWith(Redactor $redactor): self
    {
        $this->redactor = $redactor;

        return $this;
    }

    /**
     * @param Collection<int, IncomingEntry> $entries
     */
    public function store(Collection $entries): void
    {
        $redactor = $this->redactor ?? new Redactor();

        $entries->each(static fn (IncomingEntry $entry): bool => $redactor($entry));

        parent::store($entries);
    }

    /**
     * @param Collection<int, EntryUpdate> $updates
     *
     * @return Collection<int, EntryUpdate>
     */
    public function update(Collection $updates): Collection
    {
        $redactor = $this->redactor ?? new Redactor();

        foreach ($updates as $update) {
            $update->changes = $redactor->maskChanges($update->changes);
        }

        return parent::update($updates);
    }
}
