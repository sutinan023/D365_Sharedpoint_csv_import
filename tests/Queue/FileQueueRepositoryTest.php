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
];
