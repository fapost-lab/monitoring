<?php

declare(strict_types=1);

namespace Fapost\Monitoring\Tests;

use PHPUnit\Framework\TestCase;

/**
 * The image build runs the overlay package's post-install artisan commands, which must be bare
 * command names (tools/composer-overlay.php in Core accepts no arguments).
 */
final class ComposerManifestTest extends TestCase
{
    public function test_post_install_publishes_the_log_viewer_assets_with_bare_command_names(): void
    {
        $manifest = json_decode((string) file_get_contents(dirname(__DIR__) . '/composer.json'), true, flags: JSON_THROW_ON_ERROR);

        $commands = $manifest['extra']['fapost']['post-install'] ?? null;

        $this->assertSame(['log-viewer:publish'], $commands);

        foreach ($commands as $command) {
            $this->assertMatchesRegularExpression('/^[a-z0-9][a-z0-9:-]*$/', $command);
        }
    }

    public function test_telescope_is_a_dependency_of_the_package_not_of_the_host(): void
    {
        $manifest = json_decode((string) file_get_contents(dirname(__DIR__) . '/composer.json'), true, flags: JSON_THROW_ON_ERROR);

        $this->assertArrayHasKey('laravel/telescope', $manifest['require']);
    }

    public function test_sentry_is_a_dependency_of_the_package_not_of_the_host(): void
    {
        $manifest = json_decode((string) file_get_contents(dirname(__DIR__) . '/composer.json'), true, flags: JSON_THROW_ON_ERROR);

        $this->assertArrayHasKey('sentry/sentry-laravel', $manifest['require']);
    }
}
