@use('Laravel\Pulse\Facades\Pulse')
{{-- Pulse's own layout carries its title and a period selector the health card has no use for; this page borrows only its assets. --}}
<!DOCTYPE html>
<html lang="{{ str_replace('_', '-', app()->getLocale()) }}">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">

        <title>Installation health</title>

        <link rel="preconnect" href="https://fonts.bunny.net">
        <link href="https://fonts.bunny.net/css?family=figtree:300,400,500,600" rel="stylesheet" />

        {!! Pulse::css() !!}
        @livewireStyles

        {!! Pulse::js() !!}
        @livewireScriptConfig
    </head>
    <body class="bg-gray-50 dark:bg-gray-950 font-sans antialiased">
        <div class="min-h-screen">
            <header class="px-5">
                <div class="container py-3 sm:py-5 mx-auto border-b border-gray-200 dark:border-gray-900">
                    <div class="flex items-center justify-between">
                        <h1 class="text-lg sm:text-2xl text-gray-700 dark:text-gray-300 font-bold">Installation health</h1>
                        <x-pulse::theme-switcher />
                    </div>
                </div>
            </header>

            <main class="pt-6 px-6 pb-12">
                <div class="mx-auto grid default:grid-cols-12 default:gap-6 container">
                    <livewire:fapost.health cols="full" />
                </div>
            </main>
        </div>
    </body>
</html>
