<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use PHPUnit\Framework\TestCase;
use RecursiveDirectoryIterator;
use RecursiveIteratorIterator;

/**
 * The package depends on Foundation, never on FaPost Core.
 */
final class BoundaryTest extends TestCase
{
    public function test_nothing_in_the_package_refers_to_core(): void
    {
        $root  = dirname(__DIR__);
        $found = [];

        foreach (['src', 'config', 'database', 'resources'] as $dir) {
            foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root . '/' . $dir, RecursiveDirectoryIterator::SKIP_DOTS)) as $file) {
                if (1 === preg_match('/\bApp\\\\\\\\?[A-Z]/', (string) file_get_contents($file->getPathname()))) {
                    $found[] = $file->getPathname();
                }
            }
        }

        $this->assertSame([], $found, 'Core classes are referenced by name only from configuration, never from this package.');
    }
}
