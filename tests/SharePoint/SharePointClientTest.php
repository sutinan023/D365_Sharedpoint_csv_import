<?php

use App\SharePoint\SharePointClient;

return [
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
