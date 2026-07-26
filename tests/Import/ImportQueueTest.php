<?php

use App\Import\ImportQueue;

return [
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
