<?php

use App\Import\ImportQueue;
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
            public function recoverInterruptedImports(): void {}
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
            public function recoverInterruptedImports(): void {}
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
            public function recoverInterruptedImports(): void {}
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
];
