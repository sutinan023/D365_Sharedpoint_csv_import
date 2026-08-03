<?php

return [
    'uat migration command is environment locked and uses migration runner' => function (): void {
        $path = dirname(__DIR__, 2) . '/tools/apply_uat_migrations.php';
        assert(is_file($path), 'UAT migration tool is missing.');
        $source = (string) file_get_contents($path);
        foreach (['EnvironmentGuard::validate', "APP_ENV'] !== 'UAT'", "DB_NAME'] !== 'D365_finance'", 'MIGRATION_DB_USER', 'MIGRATION_DB_PASS', 'MigrationRunner', 'applyDirectory'] as $required) {
            assert(str_contains($source, $required), "Missing UAT migration guard: {$required}");
        }
        assert(!str_contains($source, "\$environment['DB_PASS']"));
        assert(!str_contains($source, 'D365_finance_prod'));
    },
];
