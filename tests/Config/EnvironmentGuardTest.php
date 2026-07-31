<?php

use App\Config\EnvironmentGuard;

$validUat = [
    'APP_ENV' => 'UAT',
    'APP_RELEASE' => '2026-07-31.1',
    'APP_BASE_URL' => 'https://finance.example/uat/D365_Sharedpoint_csv_import',
    'DB_HOST' => '127.0.0.1',
    'DB_NAME' => 'D365_finance',
    'DB_USER' => 'd365_finance_uat_app',
    'DB_PASS' => 'secret',
    'CSV_FOLDER' => 'D365export/UAT/PaymentBeforePost',
    'CSV_DOWNLOADED_FOLDER' => 'D365export/UAT/PaymentBeforePost_Downloaded',
];

return [
    'environment guard accepts isolated UAT configuration' => function () use ($validUat): void {
        $config = EnvironmentGuard::validate(
            $validUat,
            'C:\\xampp\\htdocs\\uat\\D365_Sharedpoint_csv_import',
            true
        );

        assert($config['APP_ENV'] === 'UAT');
        assert($config['APP_RELEASE'] === '2026-07-31.1');
    },
    'environment guard rejects UAT pointed at production database' => function () use ($validUat): void {
        try {
            EnvironmentGuard::validate(
                array_replace($validUat, ['DB_NAME' => 'D365_finance_prod']),
                'C:\\xampp\\htdocs\\uat\\D365_Sharedpoint_csv_import',
                true
            );
        } catch (RuntimeException $exception) {
            assert(str_contains($exception->getMessage(), 'DB_NAME'));
            return;
        }

        throw new RuntimeException('Expected mismatched database to be rejected');
    },
    'environment guard rejects production pointed at UAT SharePoint folder' => function () use ($validUat): void {
        $production = array_replace($validUat, [
            'APP_ENV' => 'PRODUCTION',
            'APP_BASE_URL' => 'https://finance.example/prod/D365_Sharedpoint_csv_import',
            'DB_NAME' => 'D365_finance_prod',
        ]);

        try {
            EnvironmentGuard::validate(
                $production,
                'C:\\xampp\\htdocs\\prod\\D365_Sharedpoint_csv_import',
                true
            );
        } catch (RuntimeException $exception) {
            assert(str_contains($exception->getMessage(), 'CSV_FOLDER'));
            return;
        }

        throw new RuntimeException('Expected mismatched SharePoint folder to be rejected');
    },
    'environment guard rejects cross-environment application path' => function () use ($validUat): void {
        try {
            EnvironmentGuard::validate(
                $validUat,
                'C:\\xampp\\htdocs\\prod\\D365_Sharedpoint_csv_import',
                true
            );
        } catch (RuntimeException $exception) {
            assert(str_contains($exception->getMessage(), 'root path'));
            return;
        }

        throw new RuntimeException('Expected mismatched application path to be rejected');
    },
    'environment guard rejects cross-environment absolute runtime path' => function () use ($validUat): void {
        try {
            EnvironmentGuard::validate(
                array_replace($validUat, [
                    'CSV_LOCAL_DOWNLOAD_DIR' => 'C:\\xampp\\htdocs\\prod\\D365_Sharedpoint_csv_import\\download',
                ]),
                'C:\\xampp\\htdocs\\uat\\D365_Sharedpoint_csv_import',
                true
            );
        } catch (RuntimeException $exception) {
            assert(str_contains($exception->getMessage(), 'CSV_LOCAL_DOWNLOAD_DIR'));
            return;
        }

        throw new RuntimeException('Expected cross-environment runtime path to be rejected');
    },
];
