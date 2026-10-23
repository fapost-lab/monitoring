<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use Carbon\CarbonImmutable;
use Illuminate\Support\Collection;
use Laravel\Pulse\Facades\Pulse;
use Laravel\Pulse\Livewire\Servers;
use Laravel\Reverb\Pulse\Livewire\Connections;
use Livewire\Livewire;
use Orchestra\Testbench\Attributes\WithConfig;
use Orchestra\Testbench\Attributes\WithEnv;
use stdClass;

/**
 * Laravel 13 reads `cache.serializable_classes` for every cache store: with `false` an object comes back from
 * the cache as `__PHP_Incomplete_Class`, and a Pulse card that caches a collection fails on its second render.
 * Laravel 12 does not read the key, so everything here also holds there.
 */
final class CachedClassesTest extends TestCase
{
    #[WithConfig('cache.serializable_classes', false)]
    public function test_false_becomes_the_exact_list_of_what_pulses_cards_cache(): void
    {
        $this->assertEqualsCanonicalizing(
            [Collection::class, stdClass::class, CarbonImmutable::class],
            config('cache.serializable_classes'),
        );
    }

    #[WithConfig('cache.serializable_classes', false)]
    public function test_the_cards_read_their_own_cached_answer_back(): void
    {
        $this->seedPulse();

        // The first render fills the cache; the second one reads it.
        foreach ([Servers::class, Connections::class] as $card) {
            Livewire::withoutLazyLoading();
            $component = Livewire::test($card)->call('$refresh');
            $component->call('$refresh')->assertOk();
        }
    }

    #[WithConfig('cache.serializable_classes', [Pulse::class, stdClass::class])]
    public function test_a_list_the_installation_already_has_is_extended_not_replaced(): void
    {
        $this->assertEqualsCanonicalizing(
            [Pulse::class, stdClass::class, Collection::class, CarbonImmutable::class],
            config('cache.serializable_classes'),
        );
    }

    #[WithConfig('cache.serializable_classes', true)]
    public function test_a_cache_that_allows_everything_is_left_alone(): void
    {
        $this->assertTrue(config('cache.serializable_classes'));
    }

    #[WithConfig('cache.serializable_classes', null)]
    public function test_an_unset_value_is_not_turned_into_a_restriction(): void
    {
        $this->assertNull(config('cache.serializable_classes'));
    }

    #[WithConfig('cache.serializable_classes', false)]
    #[WithEnv('MONITORING_PULSE_ALLOW_CACHED_CLASSES', 'false')]
    public function test_the_flag_leaves_the_setting_alone(): void
    {
        $this->assertFalse(config('cache.serializable_classes'));
    }

    #[WithConfig('cache.serializable_classes', false)]
    #[WithEnv('MONITORING_PULSE_ENABLED', 'false')]
    public function test_nothing_is_allowed_while_pulse_is_off(): void
    {
        $this->assertFalse(config('cache.serializable_classes'));
    }
    protected function defineEnvironment($app): void
    {
        parent::defineEnvironment($app);

        // A cache that serializes, as Redis does.
        $app['config']->set('cache.stores.array.serialize', true);
    }

    private function seedPulse(): void
    {
        $at = now();

        Pulse::set('system', 'srv', json_encode(['name' => 'srv', 'cpu' => 3, 'memory_used' => 1, 'memory_total' => 2, 'storage' => [['directory' => '/', 'total' => 10, 'used' => 5]]]), $at);
        Pulse::record('cpu', 'srv', 5, $at)->avg()->onlyBuckets();
        Pulse::record('reverb_connections', 'app', 3, $at)->avg()->max()->onlyBuckets();
        Pulse::ingest();
    }
}
