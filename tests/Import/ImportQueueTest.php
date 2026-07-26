<?php

use App\Import\ImportQueue;
use App\Import\PaymentBeforePostImporter;
use App\Queue\FileQueueRepository;

function importQueueRepository(): array
{
    $pdo = new PDO('sqlite::memory:');
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $migration = str_replace(
        ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
        ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', "DEFAULT CURRENT_TIMESTAMP"],
        file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
    );
    $pdo->exec(preg_replace('/,\s*\);$/', "\n);", $migration));

    return [$pdo, new FileQueueRepository($pdo)];
}

function enqueueImportFile(FileQueueRepository $repo, string $itemId, string $name, string $modified, string $path): int
{
    file_put_contents($path, $itemId);
    $id = $repo->upsertDiscovered([
        'drive_id' => 'drive',
        'id' => $itemId,
        'name' => $name,
        'size' => strlen($itemId),
        'eTag' => 'etag-' . $itemId,
        'lastModifiedDateTime' => $modified,
    ], 'PaymentBeforePost', 'PaymentBeforePost_Downloaded');
    $repo->markDownloaded($id, $path, hash_file('sha256', $path));
    $repo->markMoved($id);

    return $id;
}

return [
    'import queue skips duplicate files without importing them' => function (): void {
        $repo = new class {
            public array $statuses = [];
            public function findInterruptedImports(): array { return []; }
            public function findReadyForImport(): array {
                return [['id' => 1, 'local_path' => 'duplicate.csv', 'local_sha256' => 'duplicate-hash']];
            }
            public function markStatus(int $id, string $status, ?string $error = null): void { $this->statuses[] = [$id, $status, $error]; }
            public function markImported(int $id): void { $this->statuses[] = [$id, 'IMPORTED', null]; }
            public function markSkippedDuplicate(int $id, string $sha256): void { $this->statuses[] = [$id, 'SKIPPED_DUPLICATE', $sha256]; }
        };
        $importer = new class {
            public array $called = [];
            public function isDuplicateHash(string $sha256): bool { return true; }
            public function importFile(string $filePath, ?int $queueId = null): string { $this->called[] = $filePath; return 'unused'; }
        };

        (new ImportQueue($repo, $importer))->run();

        assert($importer->called === []);
        assert($repo->statuses === [[1, 'SKIPPED_DUPLICATE', 'duplicate-hash']]);
    },
    'import queue marks a successfully imported file as importing then imported' => function (): void {
        $repo = new class {
            public array $statuses = [];
            public function findInterruptedImports(): array { return []; }
            public function findReadyForImport(): array {
                return [['id' => 1, 'local_path' => 'ready.csv', 'local_sha256' => 'ready-hash']];
            }
            public function markStatus(int $id, string $status, ?string $error = null): void { $this->statuses[] = [$id, $status, $error]; }
            public function markImported(int $id): void { $this->statuses[] = [$id, 'IMPORTED', null]; }
            public function markSkippedDuplicate(int $id, string $sha256): void { $this->statuses[] = [$id, 'SKIPPED_DUPLICATE', $sha256]; }
        };
        $importer = new class {
            public array $called = [];
            public function isDuplicateHash(string $sha256): bool { return false; }
            public function importFile(string $filePath, ?int $queueId = null): string { $this->called[] = [$filePath, $queueId]; return 'imported'; }
        };

        (new ImportQueue($repo, $importer))->run();

        assert($importer->called === [['ready.csv', 1]]);
        assert($repo->statuses === [[1, 'IMPORTING', null], [1, 'IMPORTED', null]]);
    },
    'import queue stops after first import error' => function (): void {
        $repo = new class {
            public array $statuses = [];
            public function findInterruptedImports(): array { return []; }
            public function findReadyForImport(): array {
                return [
                    ['id' => 1, 'local_path' => 'old.csv', 'local_sha256' => 'oldhash'],
                    ['id' => 2, 'local_path' => 'new.csv', 'local_sha256' => 'newhash'],
                ];
            }
            public function markStatus(int $id, string $status, ?string $error = null): void { $this->statuses[] = [$id, $status, $error]; }
            public function markImported(int $id): void { $this->statuses[] = [$id, 'IMPORTED', null]; }
            public function markSkippedDuplicate(int $id, string $sha256): void { $this->statuses[] = [$id, 'SKIPPED_DUPLICATE', null]; }
        };
        $importer = new class {
            public array $called = [];
            public function isDuplicateHash(string $sha256): bool { return false; }
            public function importFile(string $filePath, ?int $queueId = null): string {
                $this->called[] = $filePath;
                throw new RuntimeException('bad csv');
            }
        };

        (new ImportQueue($repo, $importer))->run();

        assert($importer->called === ['old.csv']);
        assert($repo->statuses[0][1] === 'IMPORTING');
        assert($repo->statuses[1][1] === 'IMPORT_ERROR');
    },
    'older import error blocks newer moved file on the next run' => function (): void {
        [$pdo, $repo] = importQueueRepository();
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'import_queue_' . uniqid('', true);
        mkdir($root, 0777, true);
        $oldId = enqueueImportFile($repo, 'old-item', 'old.csv', '2026-07-24T01:00:00Z', $root . DIRECTORY_SEPARATOR . 'old.csv');
        $newId = enqueueImportFile($repo, 'new-item', 'new.csv', '2026-07-24T02:00:00Z', $root . DIRECTORY_SEPARATOR . 'new.csv');

        $failingImporter = new class {
            public array $called = [];
            public function isDuplicateHash(string $sha256): bool { return false; }
            public function importFile(string $filePath, ?int $queueId = null): string {
                $this->called[] = basename($filePath);
                throw new RuntimeException('bad old csv');
            }
        };
        (new ImportQueue($repo, $failingImporter))->run();

        $secondRunImporter = new class {
            public array $called = [];
            public function isDuplicateHash(string $sha256): bool { return false; }
            public function importFile(string $filePath, ?int $queueId = null): string {
                $this->called[] = basename($filePath);
                return 'imported';
            }
        };
        (new ImportQueue($repo, $secondRunImporter))->run();

        $statuses = $pdo->query('SELECT id, status FROM sharepoint_file_queue ORDER BY id')->fetchAll(PDO::FETCH_KEY_PAIR);
        assert($failingImporter->called === ['old.csv']);
        assert($secondRunImporter->called === []);
        assert($statuses[$oldId] === 'IMPORT_ERROR');
        assert($statuses[$newId] === 'MOVED');
    },
    'interrupted importing row is recovered and reconsidered on the next run' => function (): void {
        [$pdo, $repo] = importQueueRepository();
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'import_queue_' . uniqid('', true);
        mkdir($root, 0777, true);
        $id = enqueueImportFile($repo, 'stale-item', 'stale.csv', '2026-07-24T01:00:00Z', $root . DIRECTORY_SEPARATOR . 'stale.csv');
        $repo->markStatus($id, 'IMPORTING');

        $importer = new class {
            public array $called = [];
            public function reconcileInterruptedImport(array $row): array {
                return ['action' => 'RETRY', 'message' => null];
            }
            public function isDuplicateHash(string $sha256): bool { return false; }
            public function importFile(string $filePath, ?int $queueId = null): string {
                $this->called[] = [basename($filePath), $queueId];
                return 'imported';
            }
        };
        (new ImportQueue($repo, $importer))->run();

        assert($importer->called === [['stale.csv', $id]]);
        assert($pdo->query("SELECT status FROM sharepoint_file_queue WHERE id = {$id}")->fetchColumn() === 'IMPORTED');
    },
    'interrupted import missing locally is completed from pending archive evidence' => function (): void {
        [$pdo, $repo] = importQueueRepository();
        $pdo->exec('CREATE TABLE import_files (
            file_hash TEXT PRIMARY KEY,
            source_file_name TEXT,
            local_file_name TEXT,
            status TEXT NOT NULL,
            imported_at TEXT
        )');
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'import_queue_' . uniqid('', true);
        $archiveDir = $root . DIRECTORY_SEPARATOR . 'archive';
        mkdir($archiveDir, 0777, true);
        $localPath = $root . DIRECTORY_SEPARATOR . 'archive-window.csv';
        $id = enqueueImportFile(
            $repo,
            'archive-window-item',
            'archive-window.csv',
            '2026-07-24T01:00:00Z',
            $localPath
        );
        $hash = hash_file('sha256', $localPath);
        $repo->markStatus($id, 'IMPORTING');
        $pdo->prepare(
            "INSERT INTO import_files (file_hash, source_file_name, local_file_name, status)
             VALUES (?, 'archive-window.csv', ?, 'PENDING_ARCHIVE')"
        )->execute([$hash, $localPath]);
        rename($localPath, $archiveDir . DIRECTORY_SEPARATOR . '20260724_010203_archive-window.csv');

        (new ImportQueue($repo, new PaymentBeforePostImporter($pdo, $archiveDir)))->run();

        assert($pdo->query("SELECT status FROM sharepoint_file_queue WHERE id = {$id}")->fetchColumn() === 'IMPORTED');
        assert($pdo->query("SELECT status FROM import_files WHERE file_hash = '{$hash}'")->fetchColumn() === 'SUCCESS');
    },
    'interrupted import missing locally is completed from successful import evidence' => function (): void {
        [$pdo, $repo] = importQueueRepository();
        $pdo->exec('CREATE TABLE import_files (
            file_hash TEXT PRIMARY KEY,
            source_file_name TEXT,
            local_file_name TEXT,
            status TEXT NOT NULL,
            imported_at TEXT
        )');
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'import_queue_' . uniqid('', true);
        $archiveDir = $root . DIRECTORY_SEPARATOR . 'archive';
        mkdir($archiveDir, 0777, true);
        $localPath = $root . DIRECTORY_SEPARATOR . 'completed.csv';
        $id = enqueueImportFile($repo, 'completed-item', 'completed.csv', '2026-07-24T01:00:00Z', $localPath);
        $hash = hash_file('sha256', $localPath);
        unlink($localPath);
        $repo->markStatus($id, 'IMPORTING');
        $pdo->prepare(
            "INSERT INTO import_files (file_hash, source_file_name, local_file_name, status)
             VALUES (?, 'completed.csv', ?, 'SUCCESS')"
        )->execute([$hash, $localPath]);

        (new ImportQueue($repo, new PaymentBeforePostImporter($pdo, $archiveDir)))->run();

        assert($pdo->query("SELECT status FROM sharepoint_file_queue WHERE id = {$id}")->fetchColumn() === 'IMPORTED');
    },
    'unresolved older interrupted import blocks a newer moved file' => function (): void {
        [$pdo, $repo] = importQueueRepository();
        $pdo->exec('CREATE TABLE import_files (
            file_hash TEXT PRIMARY KEY,
            source_file_name TEXT,
            local_file_name TEXT,
            status TEXT NOT NULL,
            imported_at TEXT
        )');
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'import_queue_' . uniqid('', true);
        $archiveDir = $root . DIRECTORY_SEPARATOR . 'archive';
        mkdir($archiveDir, 0777, true);

        $oldPath = $root . DIRECTORY_SEPARATOR . 'missing-old.csv';
        $oldId = enqueueImportFile($repo, 'missing-old-item', 'missing-old.csv', '2026-07-24T01:00:00Z', $oldPath);
        $oldHash = hash_file('sha256', $oldPath);
        unlink($oldPath);
        $repo->markStatus($oldId, 'IMPORTING');
        $pdo->prepare(
            "INSERT INTO import_files (file_hash, source_file_name, local_file_name, status)
             VALUES (?, 'missing-old.csv', ?, 'PENDING_ARCHIVE')"
        )->execute([$oldHash, $oldPath]);

        $newPath = $root . DIRECTORY_SEPARATOR . 'ready-new.csv';
        $newId = enqueueImportFile($repo, 'ready-new-item', 'ready-new.csv', '2026-07-24T02:00:00Z', $newPath);

        (new ImportQueue($repo, new PaymentBeforePostImporter($pdo, $archiveDir)))->run();

        $statuses = $pdo->query('SELECT id, status FROM sharepoint_file_queue ORDER BY id')->fetchAll(PDO::FETCH_KEY_PAIR);
        assert($statuses[$oldId] === 'RECOVERY_ERROR');
        assert($statuses[$newId] === 'MOVED');
        assert(str_contains(
            (string) $pdo->query("SELECT last_error FROM sharepoint_file_queue WHERE id = {$oldId}")->fetchColumn(),
            'PENDING_ARCHIVE'
        ));
    },
    'import recovery error is reconciled after its local file is restored' => function (): void {
        [$pdo, $repo] = importQueueRepository();
        $pdo->exec('CREATE TABLE import_files (
            file_hash TEXT PRIMARY KEY,
            source_file_name TEXT,
            local_file_name TEXT,
            status TEXT NOT NULL,
            imported_at TEXT
        )');
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'import_queue_' . uniqid('', true);
        $archiveDir = $root . DIRECTORY_SEPARATOR . 'archive';
        mkdir($archiveDir, 0777, true);
        $localPath = $root . DIRECTORY_SEPARATOR . 'restore-later.csv';
        $id = enqueueImportFile(
            $repo,
            'restore-later-item',
            'restore-later.csv',
            '2026-07-24T01:00:00Z',
            $localPath
        );
        $contents = file_get_contents($localPath);
        $hash = hash_file('sha256', $localPath);
        $repo->markStatus($id, 'IMPORTING');
        $pdo->prepare(
            "INSERT INTO import_files (file_hash, source_file_name, local_file_name, status)
             VALUES (?, 'restore-later.csv', ?, 'PENDING_ARCHIVE')"
        )->execute([$hash, $localPath]);
        unlink($localPath);

        $importer = new PaymentBeforePostImporter($pdo, $archiveDir);
        (new ImportQueue($repo, $importer))->run();
        assert($pdo->query("SELECT status FROM sharepoint_file_queue WHERE id = {$id}")->fetchColumn() === 'RECOVERY_ERROR');

        file_put_contents($localPath, $contents);
        (new ImportQueue($repo, $importer))->run();

        assert($pdo->query("SELECT status FROM sharepoint_file_queue WHERE id = {$id}")->fetchColumn() === 'IMPORTED');
        assert($pdo->query("SELECT status FROM import_files WHERE file_hash = '{$hash}'")->fetchColumn() === 'SUCCESS');
    },
    'interrupted import finds an archived fallback local filename by hash' => function (): void {
        [$pdo, $repo] = importQueueRepository();
        $pdo->exec('CREATE TABLE import_files (
            file_hash TEXT PRIMARY KEY,
            source_file_name TEXT,
            local_file_name TEXT,
            status TEXT NOT NULL,
            imported_at TEXT
        )');
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'import_queue_' . uniqid('', true);
        $archiveDir = $root . DIRECTORY_SEPARATOR . 'archive';
        mkdir($archiveDir, 0777, true);
        $localPath = $root . DIRECTORY_SEPARATOR . 'first_fallback.csv';
        $id = enqueueImportFile(
            $repo,
            'fallback-item',
            'first.csv',
            '2026-07-24T01:00:00Z',
            $localPath
        );
        $hash = hash_file('sha256', $localPath);
        $repo->markStatus($id, 'IMPORTING');
        $pdo->prepare(
            "INSERT INTO import_files (file_hash, source_file_name, local_file_name, status)
             VALUES (?, 'first.csv', ?, 'PENDING_ARCHIVE')"
        )->execute([$hash, $localPath]);
        rename($localPath, $archiveDir . DIRECTORY_SEPARATOR . '20260724_010203_first_fallback.csv');

        (new ImportQueue($repo, new PaymentBeforePostImporter($pdo, $archiveDir)))->run();

        assert($pdo->query("SELECT status FROM sharepoint_file_queue WHERE id = {$id}")->fetchColumn() === 'IMPORTED');
        assert($pdo->query("SELECT status FROM import_files WHERE file_hash = '{$hash}'")->fetchColumn() === 'SUCCESS');
    },
    'import evidence lookup failure becomes an actionable recovery error' => function (): void {
        [$pdo, $repo] = importQueueRepository();
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'import_queue_' . uniqid('', true);
        mkdir($root, 0777, true);
        $localPath = $root . DIRECTORY_SEPARATOR . 'db-failure.csv';
        $id = enqueueImportFile(
            $repo,
            'db-failure-item',
            'db-failure.csv',
            '2026-07-24T01:00:00Z',
            $localPath
        );
        $repo->markStatus($id, 'IMPORTING');

        (new ImportQueue($repo, new PaymentBeforePostImporter($pdo, $root . DIRECTORY_SEPARATOR . 'archive')))->run();

        $row = $repo->findByItemId('db-failure-item');
        assert($row['status'] === 'RECOVERY_ERROR');
        assert(str_contains($row['last_error'], 'Interrupted import recovery failed'));
        assert(str_contains($row['last_error'], 'import_files'));
    },
];
