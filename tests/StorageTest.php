<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Laravel\Pulse\Recorders\Exceptions;
use Laravel\Pulse\Recorders\SlowRequests;
use Laravel\Reverb\Pulse\Recorders\ReverbConnections;
use Laravel\Reverb\Pulse\Recorders\ReverbMessages;

final class StorageTest extends TestCase
{
    public function test_the_tables_are_made_on_the_landlord_connection_and_nowhere_else(): void
    {
        foreach (['pulse_values', 'pulse_entries', 'pulse_aggregates'] as $table) {
            $this->assertTrue(Schema::connection('landlord')->hasTable($table), $table);
            $this->assertFalse(Schema::connection('sqlite')->hasTable($table), "{$table} must stay out of the default (tenant) connection");
        }

        $this->assertSame('landlord', config('pulse.storage.database.connection'));
    }

    public function test_a_rollback_never_drops_the_installations_pulse_data(): void
    {
        $this->artisan('migrate:rollback', ['--database' => 'landlord', '--force' => true])->assertExitCode(0);

        $this->assertTrue(Schema::connection('landlord')->hasTable('pulse_entries'));
    }

    public function test_a_partly_made_set_of_tables_is_completed(): void
    {
        Schema::connection('landlord')->drop('pulse_aggregates');
        DB::connection('landlord')->table('migrations')->delete();

        $this->artisan('migrate', ['--database' => 'landlord', '--force' => true])->assertExitCode(0);

        $this->assertTrue(Schema::connection('landlord')->hasTable('pulse_aggregates'));
    }

    public function test_running_the_migration_twice_is_harmless(): void
    {
        $this->artisan('migrate', ['--database' => 'landlord', '--force' => true])->assertExitCode(0);
        $this->assertTrue(Schema::connection('landlord')->hasTable('pulse_entries'));
    }

    public function test_reverb_recorders_are_added_without_replacing_pulses_own(): void
    {
        $recorders = config('pulse.recorders');

        $this->assertArrayHasKey(ReverbConnections::class, $recorders);
        $this->assertArrayHasKey(ReverbMessages::class, $recorders);
        $this->assertArrayHasKey(Exceptions::class, $recorders);
        $this->assertArrayHasKey(SlowRequests::class, $recorders);
    }
}
