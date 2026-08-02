<?php

namespace App\Config;

use RuntimeException;

final class EnvironmentGuard
{
    private const DATABASES = [
        'UAT' => 'D365_finance',
        'PRODUCTION' => 'D365_finance_prod',
    ];

    public static function validate(array $environment, string $rootDir, bool $validateSharePoint = false): array
    {
        foreach (['APP_ENV', 'APP_RELEASE', 'APP_BASE_URL', 'DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASS'] as $key) {
            if (trim((string)($environment[$key] ?? '')) === '') {
                throw new RuntimeException("{$key} is required");
            }
        }

        $appEnv = strtoupper(trim((string)$environment['APP_ENV']));
        if (!isset(self::DATABASES[$appEnv])) {
            throw new RuntimeException('APP_ENV must be UAT or PRODUCTION');
        }

        if (strcasecmp((string)$environment['DB_NAME'], self::DATABASES[$appEnv]) !== 0) {
            throw new RuntimeException("DB_NAME does not match {$appEnv}");
        }

        $expectedSegment = $appEnv === 'UAT' ? 'uat' : 'prod';
        self::requirePathSegment($rootDir, $expectedSegment, 'root path');
        self::requirePathSegment((string)$environment['APP_BASE_URL'], $expectedSegment, 'APP_BASE_URL');
        foreach (['CSV_LOCAL_DOWNLOAD_DIR', 'CSV_LOCAL_ARCHIVE_DIR', 'CSV_LOCAL_ERROR_DIR', 'PIPELINE_LOCK_FILE'] as $key) {
            $path = trim((string)($environment[$key] ?? ''));
            if ($path !== '' && self::isAbsolutePath($path)) {
                self::requirePathSegment($path, $expectedSegment, $key);
            }
        }

        if ($validateSharePoint) {
            $sharePointSegment = $appEnv === 'UAT' ? 'UAT' : 'Production';
            foreach (['CSV_FOLDER', 'CSV_DOWNLOADED_FOLDER'] as $key) {
                $value = str_replace('\\', '/', trim((string)($environment[$key] ?? '')));
                if ($value === '' || stripos("/{$value}/", "/{$sharePointSegment}/") === false) {
                    throw new RuntimeException("{$key} does not match {$appEnv}");
                }
            }
        }

        $environment['APP_ENV'] = $appEnv;
        return $environment;
    }

    public static function validateRehearsal(array $environment): array
    {
        if (strtoupper(trim((string)($environment['APP_ENV'] ?? ''))) !== 'PRODUCTION'
            || strcasecmp(trim((string)($environment['DB_NAME'] ?? '')), 'D365_finance_prod') !== 0) {
            throw new RuntimeException('Rehearsal verification requires Production configuration.');
        }
        foreach (['REHEARSAL_DB_HOST', 'REHEARSAL_DB_USER', 'REHEARSAL_DB_PASS'] as $key) {
            if (trim((string)($environment[$key] ?? '')) === '') {
                throw new RuntimeException("{$key} is required");
            }
        }
        $reader = trim((string)$environment['REHEARSAL_DB_USER']);
        foreach (['DB_USER', 'MIGRATION_DB_USER', 'BACKUP_DB_USER'] as $privilegedKey) {
            $privilegedUser = trim((string)($environment[$privilegedKey] ?? ''));
            if ($privilegedUser !== '' && strcasecmp($reader, $privilegedUser) === 0) {
                throw new RuntimeException("REHEARSAL_DB_USER must differ from {$privilegedKey}");
            }
        }
        return $environment;
    }

    private static function requirePathSegment(string $path, string $segment, string $label): void
    {
        $normalized = '/' . trim(str_replace('\\', '/', strtolower($path)), '/') . '/';
        if (!str_contains($normalized, '/' . strtolower($segment) . '/')) {
            throw new RuntimeException("{$label} does not match configured environment");
        }
    }

    private static function isAbsolutePath(string $path): bool
    {
        return str_starts_with($path, '/')
            || str_starts_with($path, '\\\\')
            || preg_match('/^[A-Za-z]:[\\\\\\/]/', $path) === 1;
    }
}
