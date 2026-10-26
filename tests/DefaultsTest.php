<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Fapost\Foundation\Operator\Enums\OperatorSurface;
use Illuminate\Support\Facades\DB;
use Laravel\Telescope\Contracts\EntriesRepository;
use Laravel\Telescope\Telescope;

final class DefaultsTest extends TestCase
{
    protected bool $logsEnabled = false;

    protected function setUp(): void
    {
        // Telescope's own switch, on by default and set by an older installation: it no longer decides.
        putenv('TELESCOPE_ENABLED=true');
        $_ENV['TELESCOPE_ENABLED'] = $_SERVER['TELESCOPE_ENABLED'] = 'true';

        parent::setUp();
    }

    protected function tearDown(): void
    {
        parent::tearDown();

        putenv('TELESCOPE_ENABLED');
        unset($_ENV['TELESCOPE_ENABLED'], $_SERVER['TELESCOPE_ENABLED']);
    }

    public function test_the_log_viewer_is_off_unless_switched_on_and_a_yes_does_not_switch_it_on(): void
    {
        $this->open = [OperatorSurface::Logs, OperatorSurface::Pulse];

        $this->assertFalse((bool) config('log-viewer.enabled'));
        $this->get('/log-viewer')->assertNotFound();
    }

    public function test_telescope_is_off_unless_switched_on_whatever_its_own_setting_says(): void
    {
        $this->open = [OperatorSurface::Telescope];

        $this->assertFalse((bool) config('telescope.enabled'));
        $this->get('/telescope')->assertNotFound();

        Telescope::store($this->app->make(EntriesRepository::class));
        $this->assertSame(0, DB::connection('landlord')->table('telescope_entries')->count(), 'nothing is recorded');
    }
}
