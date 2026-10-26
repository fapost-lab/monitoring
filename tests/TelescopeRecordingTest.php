<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Fapost\Monitoring\Telescope\RecordingFilter;
use Illuminate\Console\Scheduling\Event;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\Schema;
use Laravel\Telescope\Contracts\EntriesRepository;
use Laravel\Telescope\Telescope;
use Laravel\Telescope\Watchers\CacheWatcher;
use Laravel\Telescope\Watchers\ModelWatcher;
use Laravel\Telescope\Watchers\QueryWatcher;
use Laravel\Telescope\Watchers\RequestWatcher;
use RuntimeException;

/**
 * Telescope switched on, outside `record_all`: what it keeps, where, and for how long.
 */
final class TelescopeRecordingTest extends TestCase
{
    protected bool $telescopeEnabled = true;

    public function test_a_request_that_went_well_is_not_kept_and_neither_are_its_queries(): void
    {
        $this->get('/fine')->assertOk();

        $this->assertSame([], $this->storedTypes());
    }

    public function test_a_failed_request_and_its_exception_are_kept(): void
    {
        $this->get('/broken')->assertStatus(500);

        $types = $this->storedTypes();

        $this->assertContains('request', $types);
        $this->assertContains('exception', $types);
        $this->assertNotContains('query', $types);
    }

    public function test_the_entries_live_on_landlord_and_nowhere_else(): void
    {
        $this->assertSame('landlord', config('telescope.storage.database.connection'));

        foreach (['telescope_entries', 'telescope_entries_tags', 'telescope_monitoring'] as $table) {
            $this->assertTrue(Schema::connection('landlord')->hasTable($table), $table);
            $this->assertFalse(Schema::connection('sqlite')->hasTable($table), "{$table} must stay out of the default (tenant) connection");
        }
    }

    public function test_the_migration_adopts_existing_tables_and_a_rollback_keeps_them(): void
    {
        Schema::connection('landlord')->drop('telescope_monitoring');
        DB::connection('landlord')->table('migrations')->delete();

        $this->artisan('migrate', ['--database' => 'landlord', '--force' => true])->assertExitCode(0);
        $this->assertTrue(Schema::connection('landlord')->hasTable('telescope_monitoring'));

        $this->artisan('migrate:rollback', ['--database' => 'landlord', '--force' => true])->assertExitCode(0);
        $this->assertTrue(Schema::connection('landlord')->hasTable('telescope_entries'));
    }

    public function test_watchers_whose_entries_would_be_filtered_out_are_switched_off(): void
    {
        $this->assertFalse((bool) data_get(config('telescope.watchers'), CacheWatcher::class . '.enabled', true));
        $this->assertFalse((bool) data_get(config('telescope.watchers'), ModelWatcher::class . '.enabled', true));
        $this->assertNotFalse(config('telescope.watchers')[QueryWatcher::class]['enabled']);
        $this->assertNotFalse(config('telescope.watchers')[RequestWatcher::class]['enabled']);
    }

    public function test_everything_is_kept_on_a_local_machine_unless_the_setting_says_otherwise(): void
    {
        $this->assertFalse(RecordingFilter::recordsAll($this->app));

        $this->app['env'] = 'local';
        $this->assertTrue(RecordingFilter::recordsAll($this->app));

        config(['monitoring.telescope.record_all' => 'false']);
        $this->assertFalse(RecordingFilter::recordsAll($this->app));

        $this->app['env'] = 'production';
        config(['monitoring.telescope.record_all' => 'true']);
        $this->assertTrue(RecordingFilter::recordsAll($this->app));
    }

    public function test_the_prune_runs_daily_keeping_48_hours(): void
    {
        $event = $this->prune();

        $this->assertNotNull($event);
        $this->assertStringContainsString('--hours=48', $event->command);
        $this->assertSame('0 0 * * *', $event->expression);
    }

    public function test_no_prune_is_scheduled_when_retention_is_zero(): void
    {
        config(['monitoring.telescope.keep_hours' => 0]);

        $this->assertNull($this->prune());
    }

    public function test_the_operator_screen_itself_is_never_recorded(): void
    {
        $this->open = [OperatorSurface::Telescope];
        $this->assertContains('pulse*', config('telescope.ignore_paths'));
        $this->assertContains('support/enter', config('telescope.ignore_paths'));
        $this->assertContains('webhook/*', config('telescope.ignore_paths'));
    }

    protected function defineRoutes($router): void
    {
        Route::get('/fine', static function (): string {
            DB::connection('sqlite')->select('select 1');

            return 'ok';
        });
        Route::get('/broken', static function (): never {
            DB::connection('sqlite')->select('select 1');

            throw new RuntimeException('it broke');
        });
    }

    private function prune(): ?Event
    {
        $this->app->forgetInstance(Schedule::class);

        foreach ($this->app->make(Schedule::class)->events() as $event) {
            if (str_contains((string) $event->command, 'telescope:prune')) {
                return $event;
            }
        }

        return null;
    }

    /**
     * @return list<string>
     */
    private function storedTypes(): array
    {
        Telescope::store($this->app->make(EntriesRepository::class));

        return DB::connection('landlord')->table('telescope_entries')->pluck('type')->all();
    }
}
