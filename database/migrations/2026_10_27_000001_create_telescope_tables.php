<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class () extends Migration {
    /**
     * Telescope's storage connection, which this package points at `landlord`.
     */
    public function getConnection(): ?string
    {
        return config('telescope.storage.database.connection');
    }

    /**
     * A copy of Telescope 5's own migration, each table made only if missing: an installation of FaPost Core may
     * already hold them (Core created them before Telescope moved here), and a partial run must be completable.
     * It runs whether Telescope is on or not, so that the scheduled prune always finds its tables.
     */
    public function up(): void
    {
        $schema = Schema::connection($this->getConnection());

        if (! $schema->hasTable('telescope_entries')) {
            $schema->create('telescope_entries', function (Blueprint $table): void {
                $table->bigIncrements('sequence');
                $table->uuid('uuid');
                $table->uuid('batch_id');
                $table->string('family_hash')->nullable();
                $table->boolean('should_display_on_index')->default(true);
                $table->string('type', 20);
                $table->longText('content');
                $table->dateTime('created_at')->nullable();

                $table->unique('uuid');
                $table->index('batch_id');
                $table->index('family_hash');
                $table->index('created_at');
                $table->index(['type', 'should_display_on_index']);
            });
        }

        if (! $schema->hasTable('telescope_entries_tags')) {
            $schema->create('telescope_entries_tags', function (Blueprint $table): void {
                $table->uuid('entry_uuid');
                $table->string('tag');

                $table->primary(['entry_uuid', 'tag']);
                $table->index('tag');

                $table->foreign('entry_uuid')
                    ->references('uuid')
                    ->on('telescope_entries')
                    ->cascadeOnDelete();
            });
        }

        if (! $schema->hasTable('telescope_monitoring')) {
            $schema->create('telescope_monitoring', function (Blueprint $table): void {
                $table->string('tag')->primary();
            });
        }
    }

    /**
     * Deliberately empty, as for Pulse: a tenant-side `migrate:rollback` must not drop the installation's
     * Telescope data from `landlord`. Drop the `telescope_*` tables by hand to remove them.
     */
    public function down(): void
    {
    }
};
