<?php

use App\SharePoint\SharePointClient;

return [
    'sharepoint client encodes normalized site paths from environment' => function (): void {
        $calls = [];
        $http = function (string $method, string $url, array $headers = [], ?string $body = null) use (&$calls): array {
            $calls[] = [$method, $url];

            if ($method === 'POST') {
                return [200, [], json_encode(['access_token' => 'test-token'])];
            }

            if (str_contains($url, '/sites/contoso.sharepoint.com:/')) {
                return [200, [], json_encode(['id' => 'site-id'])];
            }

            return [200, [], json_encode(['value' => [['id' => 'drive-id', 'name' => 'Documents']]])];
        };

        SharePointClient::fromEnv([
            'TENANT_ID' => 'tenant',
            'CLIENT_ID' => 'client',
            'CLIENT_SECRET' => 'secret',
            'SITE_HOST' => 'contoso.sharepoint.com',
            'SITE_PATH' => '/sites/Finance Team/#Planning/',
            'LIBRARY' => 'Documents',
        ], $http);

        assert($calls[1][1] === 'https://graph.microsoft.com/v1.0/sites/contoso.sharepoint.com:/sites/Finance%20Team/%23Planning');
    },
    'sharepoint client throws when download cannot be written locally' => function (): void {
        $client = new SharePointClient([
            'ACCESS_TOKEN' => 'test-token',
        ], static fn (): array => [200, [], 'contents']);

        $thrown = false;
        set_error_handler(static fn (): bool => true);
        try {
            $client->downloadItem('drive', 'item', sys_get_temp_dir());
        } catch (RuntimeException $exception) {
            $thrown = str_contains($exception->getMessage(), 'write');
        } finally {
            restore_error_handler();
        }

        assert($thrown);
    },
    'sharepoint client requires a drive ID to resolve folders' => function (): void {
        $client = new SharePointClient([
            'ACCESS_TOKEN' => 'test-token',
        ], static function (): array {
            throw new RuntimeException('HTTP must not be called without DRIVE_ID');
        });

        $thrown = false;
        try {
            $client->resolveFolderItemId('Processed');
        } catch (RuntimeException $exception) {
            $thrown = $exception->getMessage() === 'DRIVE_ID is required';
        }

        assert($thrown);
    },
    'sharepoint client follows pagination and filters csv files' => function (): void {
        $calls = [];
        $http = function (string $method, string $url, array $headers = [], ?string $body = null) use (&$calls): array {
            $calls[] = [$method, $url];

            if (str_contains($url, 'page2')) {
                return [200, [], json_encode([
                    'value' => [
                        ['id' => '3', 'name' => 'C.CSV', 'size' => 3, 'eTag' => 'e3', 'lastModifiedDateTime' => '2026-07-24T03:00:00Z', 'file' => new stdClass()],
                    ],
                ])];
            }

            return [200, [], json_encode([
                'value' => [
                    ['id' => '1', 'name' => 'A.csv', 'size' => 1, 'eTag' => 'e1', 'lastModifiedDateTime' => '2026-07-24T01:00:00Z', 'file' => new stdClass()],
                    ['id' => '2', 'name' => 'B.txt', 'size' => 2, 'eTag' => 'e2', 'lastModifiedDateTime' => '2026-07-24T02:00:00Z', 'file' => new stdClass()],
                    ['id' => 'folder', 'name' => 'Nested', 'folder' => new stdClass()],
                ],
                '@odata.nextLink' => 'https://graph.microsoft.com/v1.0/page2',
            ])];
        };

        $client = new SharePointClient([
            'DRIVE_ID' => 'drive',
            'ACCESS_TOKEN' => 'test-token',
        ], $http);

        $files = $client->listCsvFiles('PaymentBeforePost');

        assert(array_column($files, 'name') === ['A.csv', 'C.CSV']);
        assert(count($calls) === 2);
    },
];
