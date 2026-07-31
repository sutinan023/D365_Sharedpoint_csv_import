<?php

use App\Config\EnvironmentBanner;

return [
    'environment banner marks UAT monitor output' => function (): void {
        $html = EnvironmentBanner::inject(
            '<html><body><main>Monitor</main></body></html>',
            'UAT',
            '2026-07-31.1'
        );

        assert(str_contains($html, 'UAT'));
        assert(str_contains($html, '2026-07-31.1'));
    },
    'environment banner leaves production output unchanged' => function (): void {
        $html = '<html><body><main>Monitor</main></body></html>';
        assert(EnvironmentBanner::inject($html, 'PRODUCTION', '2026-07-31.1') === $html);
    },
];
