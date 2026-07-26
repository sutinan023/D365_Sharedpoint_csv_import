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
        $pdo->exec(preg_replace('/,\s*\);\s*$/', "\n);", $migration));

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
        $pdo->exec(preg_replace('/,\s*\);\s*$/', "\n);", $migration));
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
        $pdo->exec(preg_replace('/,\s*\);\s*$/', "\n);", $migration));
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
    'repository clears invalid local metadata and keeps recovery error ahead of newer moved files' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $migration = str_replace(
            ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
            ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', "DEFAULT CURRENT_TIMESTAMP"],
            file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
        );
        $pdo->exec(preg_replace('/,\s*\);\s*$/', "\n);", $migration));
        $repo = new FileQueueRepository($pdo);

        $older = $repo->upsertDiscovered([
            'drive_id' => 'drive',
            'id' => 'missing-old',
            'name' => 'missing-old.csv',
            'lastModifiedDateTime' => '2026-07-24T01:00:00Z',
        ], 'PaymentBeforePost', 'PaymentBeforePost_Downloaded');
        $repo->markDownloaded($older, 'C:\\queue\\missing-old.csv', str_repeat('a', 64));
        $repo->resetForRedownload($older, 'Downloaded local file is missing; redownload required');

        $newer = $repo->upsertDiscovered([
            'drive_id' => 'drive',
            'id' => 'ready-new',
            'name' => 'ready-new.csv',
            'lastModifiedDateTime' => '2026-07-24T02:00:00Z',
        ], 'PaymentBeforePost', 'PaymentBeforePost_Downloaded');
        $repo->markMoved($newer);

        $olderRow = $repo->findByItemId('missing-old');
        $ready = $repo->findReadyForImport();

        assert($olderRow['status'] === 'RECOVERY_ERROR');
        assert($olderRow['local_path'] === null);
        assert($olderRow['local_sha256'] === null);
        assert(array_column($ready, 'item_id') === ['missing-old', 'ready-new']);
    },
    'repository finds only terminal rows in download for cleanup' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $migration = str_replace(
            ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
            ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', "DEFAULT CURRENT_TIMESTAMP"],
            file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
        );
        $pdo->exec(preg_replace('/,\s*\);\s*$/', "\n);", $migration));
        $repo = new FileQueueRepository($pdo);

        $downloadDir = 'C:/queue/download';
        $oldDate = '2020-01-01 00:00:00';
        $newDate = '2099-01-01 00:00:00';

        $stmt = $pdo->prepare("INSERT INTO sharepoint_file_queue
            (item_id, source_folder, processed_folder, file_name, local_path, status, imported_at, created_at, updated_at)
            VALUES
            ('terminal-old', 'src', 'done', 'old.csv', :old_path, 'SKIPPED_DUPLICATE', :old_date, :old_date, :old_date),
            ('terminal-new', 'src', 'done', 'new.csv', :new_path, 'SKIPPED_DUPLICATE', :new_date, :new_date, :new_date),
            ('active-old', 'src', 'done', 'active.csv', :active_path, 'MOVED', :old_date, :old_date, :old_date),
            ('outside-old', 'src', 'done', 'outside.csv', :outside_path, 'SKIPPED_DUPLICATE', :old_date, :old_date, :old_date),
            ('txt-old', 'src', 'done', 'notes.txt', :txt_path, 'SKIPPED_DUPLICATE', :old_date, :old_date, :old_date)");
        $stmt->execute([
            ':old_path' => $downloadDir . '/old.csv',
            ':new_path' => $downloadDir . '/new.csv',
            ':active_path' => $downloadDir . '/active.csv',
            ':outside_path' => 'C:/queue/archive/outside.csv',
            ':txt_path' => $downloadDir . '/notes.txt',
            ':old_date' => $oldDate,
            ':new_date' => $newDate,
        ]);

        $rows = $repo->findTerminalRowsInDownload($downloadDir, 30);

        assert(count($rows) === 1);
        assert($rows[0]['item_id'] === 'terminal-old');
    },
    'repository updates local path after cleanup move' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $migration = str_replace(
            ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
            ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', "DEFAULT CURRENT_TIMESTAMP"],
            file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
        );
        $pdo->exec(preg_replace('/,\s*\);\s*$/', "\n);", $migration));
        $repo = new FileQueueRepository($pdo);

        $pdo->exec("INSERT INTO sharepoint_file_queue
            (item_id, source_folder, processed_folder, file_name, local_path, status)
            VALUES ('path-update', 'src', 'done', 'file.csv', 'download/file.csv', 'SKIPPED_DUPLICATE')");

        $repo->updateLocalPath(1, 'archive/download-cleanup/2026-07/file.csv');
        $row = $repo->findByItemId('path-update');

        assert($row['local_path'] === 'archive/download-cleanup/2026-07/file.csv');
    },
];
