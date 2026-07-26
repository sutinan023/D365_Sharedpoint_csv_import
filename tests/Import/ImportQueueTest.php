<?php

use App\Import\ImportQueue;

return [
    'import queue skips duplicate files without importing them' => function (): void {
        $repo = new class {
            public array $statuses = [];
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
];
