<?php

use App\Queue\FileQueueRepository;

return [
    'repository upserts discovered and orders moved files oldest first' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $migration = str_replace(
            ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
            ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', "DEFAULT CURRENT_TIMESTAMP"],
            file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
        );
        $pdo->exec(preg_replace('/,\s*\);$/', "\n);", $migration));

        $repo = new FileQueueRepository($pdo);

        $newer = $repo->upsertDiscovered([
            'drive_id' => 'drive',
            'id' => 'item-new',
            'name' => 'new.csv',
            'size' => 20,
            'eTag' => 'etag-new',
            'lastModifiedDateTime' => '2026-07-24T10:00:00Z',
        ], 'PaymentBeforePost', 'PaymentBeforePost_Downloaded');

        $older = $repo->upsertDiscovered([
            'drive_id' => 'drive',
            'id' => 'item-old',
            'name' => 'old.csv',
            'size' => 10,
            'eTag' => 'etag-old',
            'lastModifiedDateTime' => '2026-07-24T09:00:00Z',
        ], 'PaymentBeforePost', 'PaymentBeforePost_Downloaded');

        $repo->markMoved($newer);
        $repo->markMoved($older);

        $ready = $repo->findReadyForImport();

        assert($ready[0]['file_name'] === 'old.csv');
        assert($ready[1]['file_name'] === 'new.csv');
    },
    'repository counts failures instead of ordinary status transitions as attempts' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $migration = str_replace(
            ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
            ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', "DEFAULT CURRENT_TIMESTAMP"],
            file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
        );
        $pdo->exec(preg_replace('/,\s*\);$/', "\n);", $migration));
        $repo = new FileQueueRepository($pdo);
        $id = $repo->upsertDiscovered([
            'drive_id' => 'drive',
            'id' => 'attempt-item',
            'name' => 'attempt.csv',
            'lastModifiedDateTime' => '2026-07-24T09:00:00Z',
        ], 'PaymentBeforePost', 'PaymentBeforePost_Downloaded');

        $repo->markStatus($id, 'DOWNLOADING');
        $repo->markStatus($id, 'ERROR', 'download failed');
        $repo->markStatus($id, 'DOWNLOADING');

        $row = $repo->findByItemId('attempt-item');
        assert((int) $row['attempt_count'] === 1);
        assert($row['last_error'] === null);
    },
    'repository finds durable move recovery rows and excludes download errors without local files' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $migration = str_replace(
            ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
            ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', "DEFAULT CURRENT_TIMESTAMP"],
            file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
        );
        $pdo->exec(preg_replace('/,\s*\);$/', "\n);", $migration));
        $repo = new FileQueueRepository($pdo);

        foreach ([
            ['downloaded', 'DOWNLOADED', 'C:\\queue\\downloaded.csv', str_repeat('a', 64)],
            ['moving', 'MOVING', 'C:\\queue\\moving.csv', str_repeat('b', 64)],
            ['legacy-move-error', 'ERROR', 'C:\\queue\\legacy.csv', str_repeat('c', 64)],
            ['download-error', 'ERROR', null, null],
        ] as $offset => [$itemId, $status, $localPath, $hash]) {
            $id = $repo->upsertDiscovered([
                'drive_id' => 'drive',
                'id' => $itemId,
                'name' => $itemId . '.csv',
                'lastModifiedDateTime' => sprintf('2026-07-24T0%d:00:00Z', $offset + 1),
            ], 'PaymentBeforePost', 'PaymentBeforePost_Downloaded');
            if ($localPath !== null) {
                $repo->markDownloaded($id, $localPath, $hash);
            }
            $repo->markStatus($id, $status, $status === 'ERROR' ? 'failed' : null);
        }

        assert(array_column($repo->findPendingMoves(), 'item_id') === [
            'downloaded',
            'moving',
            'legacy-move-error',
        ]);
    },
];
