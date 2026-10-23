<?php

declare(strict_types=1);

use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;
use Laravel\Pulse\Support\PulseMigration;

return new class () extends PulseMigration {
    /**
     * Run the migrations.
     */
    public function up(): void
    {
        // The connection is Pulse's own storage connection, which this package points at `landlord`.
        if (! $this->shouldRun()) {
            return;
        }

        $this->make('pulse_values', function (Blueprint $table): void {
            $table->id();
            $table->unsignedInteger('timestamp');
            $table->string('type');
            $table->mediumText('key');
            match ($this->driver()) {
                'mariadb', 'mysql' => $table->char('key_hash', 16)->charset('binary')->virtualAs('unhex(md5(`key`))'),
                'pgsql'            => $table->uuid('key_hash')->storedAs('md5("key")::uuid'),
                'sqlite'           => $table->string('key_hash'),
            };
            $table->mediumText('value');

            $table->index('timestamp'); // For trimming...
            $table->index('type'); // For fast lookups and purging...
            $table->unique(['type', 'key_hash']); // For data integrity and upserts...
        });

        $this->make('pulse_entries', function (Blueprint $table): void {
            $table->id();
            $table->unsignedInteger('timestamp');
            $table->string('type');
            $table->mediumText('key');
            match ($this->driver()) {
                'mariadb', 'mysql' => $table->char('key_hash', 16)->charset('binary')->virtualAs('unhex(md5(`key`))'),
                'pgsql'            => $table->uuid('key_hash')->storedAs('md5("key")::uuid'),
                'sqlite'           => $table->string('key_hash'),
            };
            $table->bigInteger('value')->nullable();

            $table->index('timestamp'); // For trimming...
            $table->index('type'); // For purging...
            $table->index('key_hash'); // For mapping...
            $table->index(['timestamp', 'type', 'key_hash', 'value']); // For aggregate queries...
        });

        $this->make('pulse_aggregates', function (Blueprint $table): void {
            $table->id();
            $table->unsignedInteger('bucket');
            $table->unsignedMediumInteger('period');
            $table->string('type');
            $table->mediumText('key');
            match ($this->driver()) {
                'mariadb', 'mysql' => $table->char('key_hash', 16)->charset('binary')->virtualAs('unhex(md5(`key`))'),
                'pgsql'            => $table->uuid('key_hash')->storedAs('md5("key")::uuid'),
                'sqlite'           => $table->string('key_hash'),
            };
            $table->string('aggregate');
            $table->decimal('value', 20, 2);
            $table->unsignedInteger('count')->nullable();

            $table->unique(['bucket', 'period', 'type', 'aggregate', 'key_hash']); // Force "on duplicate update"...
            $table->index(['period', 'bucket']); // For trimming...
            $table->index('type'); // For purging...
            $table->index(['period', 'type', 'aggregate', 'bucket']); // For aggregate queries...
        });
    }

    /**
     * Reverse the migrations.
     *
     * Deliberately empty. The migration is recorded in whichever migrations table ran it, and a tenant-side
     * `migrate:rollback` would otherwise drop the whole installation's Pulse data from the landlord. Drop the
     * `pulse_*` tables by hand to remove them.
     */
    public function down(): void
    {
    }

    /**
     * Creates one table unless it exists: an installation may already hold some (a partial run on a database
     * without transactional DDL, or Pulse's own migration run before this package was added).
     */
    private function make(string $name, Closure $define): void
    {
        $schema = Schema::connection($this->getConnection());

        if (! $schema->hasTable($name)) {
            $schema->create($name, $define);
        }
    }
};
