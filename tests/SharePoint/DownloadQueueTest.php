<?php

use App\Config\AppConfig;
use App\SharePoint\DownloadQueue;

function downloadQueueConfig(string $root): AppConfig
{
    $_ENV['CSV_FOLDER'] = 'PaymentBeforePost';
    $_ENV['CSV_DOWNLOADED_FOLDER'] = 'PaymentBeforePost_Downloaded';
    $_ENV['CSV_LOCAL_DOWNLOAD_DIR'] = 'download';
    $_ENV['CSV_LOCAL_ARCHIVE_DIR'] = 'archive';
    $_ENV['CSV_LOCAL_ERROR_DIR'] = 'error';
    $_ENV['PIPELINE_LOCK_FILE'] = 'temp/pipeline.lock';

    return AppConfig::fromEnv($root);
}

function downloadQueueItem(string $id = 'item1', int $size = 5): array
{
    return [
        'drive_id' => 'drive',
        'id' => $id,
        'name' => 'first.csv',
        'size' => $size,
        'eTag' => 'etag1',
        'lastModifiedDateTime' => '2026-07-24T01:00:00Z',
    ];
}

return [
    'download queue downloads to part validates then moves' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        mkdir($root . DIRECTORY_SEPARATOR . 'download', 0777, true);

        $config = downloadQueueConfig($root);
        $client = new class {
            public array $moved = [];
            public function listCsvFiles(string $folder): array {
                return [downloadQueueItem()];
            }
            public function resolveFolderItemId(string $folder): string {
                return 'processed-folder-id';
            }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void {
                file_put_contents($targetPath, '12345');
            }
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void {
                $this->moved[] = [$driveId, $itemId, $processedFolderItemId];
            }
        };
        $repo = new class {
            public int $id = 10;
            public array $downloaded = [];
            public array $moved = [];
            public array $statuses = [];
            public array $events = [];
            public function findPendingMoves(): array { return []; }
            public function findByItemId(string $itemId): ?array { return null; }
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return $this->id; }
            public function markStatus(int $id, string $status, ?string $error = null): void { $this->statuses[] = [$id, $status, $error]; $this->events[] = $status; }
            public function markDownloaded(int $id, string $localPath, string $sha256): void { $this->downloaded[] = [$id, $localPath, $sha256]; $this->events[] = 'DOWNLOADED'; }
            public function markMoved(int $id): void { $this->moved[] = $id; $this->events[] = 'MOVED'; }
        };

        (new DownloadQueue($client, $repo, $config))->run();

        assert(is_file($root . DIRECTORY_SEPARATOR . 'download' . DIRECTORY_SEPARATOR . 'first.csv'));
        assert(!is_file($root . DIRECTORY_SEPARATOR . 'download' . DIRECTORY_SEPARATOR . 'first.csv.part'));
        assert(count($client->moved) === 1);
        assert($repo->moved === [10]);
        assert($repo->events === ['DOWNLOADING', 'DOWNLOADED', 'MOVING', 'MOVED']);
    },
    'download queue reports error and cleans part when size validation fails' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        mkdir($root . DIRECTORY_SEPARATOR . 'download', 0777, true);
        $config = downloadQueueConfig($root);
        $client = new class {
            public array $moved = [];
            public function listCsvFiles(string $folder): array { return [downloadQueueItem('item2', 5)]; }
            public function resolveFolderItemId(string $folder): string { return 'processed-folder-id'; }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void { file_put_contents($targetPath, '1234'); }
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void { $this->moved[] = $itemId; }
        };
        $repo = new class {
            public array $statuses = [];
            public array $downloaded = [];
            public function findPendingMoves(): array { return []; }
            public function findByItemId(string $itemId): ?array { return null; }
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return 20; }
            public function markStatus(int $id, string $status, ?string $error = null): void { $this->statuses[] = [$status, $error]; }
            public function markDownloaded(int $id, string $localPath, string $sha256): void { $this->downloaded[] = [$localPath, $sha256]; }
            public function markMoved(int $id): void {}
        };

        (new DownloadQueue($client, $repo, $config))->run();

        assert($client->moved === []);
        assert($repo->downloaded === []);
        assert(!is_file($root . DIRECTORY_SEPARATOR . 'download' . DIRECTORY_SEPARATOR . 'first.csv'));
        assert(!is_file($root . DIRECTORY_SEPARATOR . 'download' . DIRECTORY_SEPARATOR . 'first.csv.part'));
        assert(array_column($repo->statuses, 0) === ['DOWNLOADING', 'ERROR']);
    },
    'download queue records finalized file and error when SharePoint move fails' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        mkdir($root . DIRECTORY_SEPARATOR . 'download', 0777, true);
        $config = downloadQueueConfig($root);
        $client = new class {
            public function listCsvFiles(string $folder): array { return [downloadQueueItem('item3')]; }
            public function resolveFolderItemId(string $folder): string { return 'processed-folder-id'; }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void { file_put_contents($targetPath, '12345'); }
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void { throw new RuntimeException('move failed'); }
        };
        $repo = new class {
            public array $statuses = [];
            public array $downloaded = [];
            public array $moved = [];
            public function findPendingMoves(): array { return []; }
            public function findByItemId(string $itemId): ?array { return null; }
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return 30; }
            public function markStatus(int $id, string $status, ?string $error = null): void { $this->statuses[] = [$status, $error]; }
            public function markDownloaded(int $id, string $localPath, string $sha256): void { $this->downloaded[] = [$localPath, $sha256]; }
            public function markMoved(int $id): void { $this->moved[] = $id; }
        };

        (new DownloadQueue($client, $repo, $config))->run();

        $finalPath = $root . DIRECTORY_SEPARATOR . 'download' . DIRECTORY_SEPARATOR . 'first.csv';
        assert(is_file($finalPath));
        assert(!is_file($finalPath . '.part'));
        assert($repo->downloaded === [[$finalPath, hash_file('sha256', $finalPath)]]);
        assert($repo->moved === []);
        assert(array_column($repo->statuses, 0) === ['DOWNLOADING', 'MOVING', 'MOVING']);
    },
    'download queue preserves existing original and fallback CSV names' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        $downloadDir = $root . DIRECTORY_SEPARATOR . 'download';
        mkdir($downloadDir, 0777, true);
        file_put_contents($downloadDir . DIRECTORY_SEPARATOR . 'first.csv', 'original');
        file_put_contents($downloadDir . DIRECTORY_SEPARATOR . 'first_item4.csv', 'fallback');
        $config = downloadQueueConfig($root);
        $client = new class {
            public function listCsvFiles(string $folder): array { return [downloadQueueItem('item4')]; }
            public function resolveFolderItemId(string $folder): string { return 'processed-folder-id'; }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void { file_put_contents($targetPath, '12345'); }
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void {}
        };
        $repo = new class {
            public array $downloaded = [];
            public function findPendingMoves(): array { return []; }
            public function findByItemId(string $itemId): ?array { return null; }
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return 40; }
            public function markStatus(int $id, string $status, ?string $error = null): void {}
            public function markDownloaded(int $id, string $localPath, string $sha256): void { $this->downloaded[] = $localPath; }
            public function markMoved(int $id): void {}
        };

        (new DownloadQueue($client, $repo, $config))->run();

        assert(file_get_contents($downloadDir . DIRECTORY_SEPARATOR . 'first.csv') === 'original');
        assert(file_get_contents($downloadDir . DIRECTORY_SEPARATOR . 'first_item4.csv') === 'fallback');
        assert($repo->downloaded === [$downloadDir . DIRECTORY_SEPARATOR . 'first_item4_2.csv']);
        assert(file_get_contents($repo->downloaded[0]) === '12345');
    },
    'download queue resumes a failed move on the next run without redownloading' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        mkdir($root . DIRECTORY_SEPARATOR . 'download', 0777, true);
        $config = downloadQueueConfig($root);
        $client = new class {
            public int $downloads = 0;
            public int $moves = 0;
            public function listCsvFiles(string $folder): array { return [downloadQueueItem('recover-item')]; }
            public function resolveFolderItemId(string $folder): string { return 'processed-folder-id'; }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void {
                $this->downloads++;
                file_put_contents($targetPath, '12345');
            }
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void {
                $this->moves++;
                if ($this->moves === 1) {
                    throw new RuntimeException('temporary move failure');
                }
            }
        };
        $repo = new class {
            public ?array $row = null;
            public function findPendingMoves(): array {
                if ($this->row === null) {
                    return [];
                }
                $recoverable = in_array($this->row['status'], ['DOWNLOADED', 'MOVING'], true)
                    || ($this->row['status'] === 'ERROR' && $this->row['local_path'] !== null);
                return $recoverable ? [$this->row] : [];
            }
            public function findByItemId(string $itemId): ?array { return $this->row; }
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int {
                $this->row ??= [
                    'id' => 50,
                    'drive_id' => $item['drive_id'],
                    'item_id' => $item['id'],
                    'status' => 'DISCOVERED',
                    'local_path' => null,
                    'local_sha256' => null,
                ];
                return 50;
            }
            public function markStatus(int $id, string $status, ?string $error = null): void {
                $this->row['status'] = $status;
                $this->row['last_error'] = $error;
            }
            public function markDownloaded(int $id, string $localPath, string $sha256): void {
                $this->row['status'] = 'DOWNLOADED';
                $this->row['local_path'] = $localPath;
                $this->row['local_sha256'] = $sha256;
            }
            public function markMoved(int $id): void { $this->row['status'] = 'MOVED'; }
        };

        (new DownloadQueue($client, $repo, $config))->run();
        (new DownloadQueue($client, $repo, $config))->run();

        assert($client->downloads === 1);
        assert($client->moves === 2);
        assert($repo->row['status'] === 'MOVED');
    },
    'download queue redownloads a pending move whose local file is missing' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        mkdir($root . DIRECTORY_SEPARATOR . 'download', 0777, true);
        $config = downloadQueueConfig($root);
        $client = new class {
            public int $downloads = 0;
            public int $moves = 0;
            public function listCsvFiles(string $folder): array { return [downloadQueueItem('missing-item')]; }
            public function resolveFolderItemId(string $folder): string { return 'processed-folder-id'; }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void {
                $this->downloads++;
                file_put_contents($targetPath, '12345');
            }
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void { $this->moves++; }
        };
        $repo = new class {
            public array $row = [
                'id' => 55,
                'drive_id' => 'drive',
                'item_id' => 'missing-item',
                'status' => 'MOVING',
                'local_path' => 'C:\\queue\\missing.csv',
                'local_sha256' => 'missing-hash',
            ];
            public function findPendingMoves(): array { return [$this->row]; }
            public function findByItemId(string $itemId): ?array { return $this->row; }
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return 55; }
            public function resetForRedownload(int $id, string $error): void {
                $this->row['status'] = 'RECOVERY_ERROR';
                $this->row['local_path'] = null;
                $this->row['local_sha256'] = null;
                $this->row['last_error'] = $error;
            }
            public function markStatus(int $id, string $status, ?string $error = null): void {
                $this->row['status'] = $status;
                $this->row['last_error'] = $error;
            }
            public function markDownloaded(int $id, string $localPath, string $sha256): void {
                $this->row['status'] = 'DOWNLOADED';
                $this->row['local_path'] = $localPath;
                $this->row['local_sha256'] = $sha256;
            }
            public function markMoved(int $id): void { $this->row['status'] = 'MOVED'; }
        };

        (new DownloadQueue($client, $repo, $config))->run();

        assert($client->downloads === 1);
        assert($client->moves === 1);
        assert($repo->row['status'] === 'MOVED');
        assert(is_file($repo->row['local_path']));
    },
    'download queue redownloads a pending move whose local file hash is corrupt' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        $downloadDir = $root . DIRECTORY_SEPARATOR . 'download';
        mkdir($downloadDir, 0777, true);
        $corruptPath = $downloadDir . DIRECTORY_SEPARATOR . 'first.csv';
        file_put_contents($corruptPath, 'corrupt');
        $config = downloadQueueConfig($root);
        $client = new class {
            public int $downloads = 0;
            public int $moves = 0;
            public function listCsvFiles(string $folder): array { return [downloadQueueItem('corrupt-item')]; }
            public function resolveFolderItemId(string $folder): string { return 'processed-folder-id'; }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void {
                $this->downloads++;
                file_put_contents($targetPath, '12345');
            }
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void { $this->moves++; }
        };
        $repo = new class($corruptPath) {
            public array $row;
            public function __construct(string $corruptPath) {
                $this->row = [
                    'id' => 57,
                    'drive_id' => 'drive',
                    'item_id' => 'corrupt-item',
                    'status' => 'DOWNLOADED',
                    'local_path' => $corruptPath,
                    'local_sha256' => hash('sha256', '12345'),
                ];
            }
            public function findPendingMoves(): array { return [$this->row]; }
            public function findByItemId(string $itemId): ?array { return $this->row; }
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return 57; }
            public function resetForRedownload(int $id, string $error): void {
                $this->row['status'] = 'RECOVERY_ERROR';
                $this->row['local_path'] = null;
                $this->row['local_sha256'] = null;
                $this->row['last_error'] = $error;
            }
            public function markStatus(int $id, string $status, ?string $error = null): void {
                $this->row['status'] = $status;
                $this->row['last_error'] = $error;
            }
            public function markDownloaded(int $id, string $localPath, string $sha256): void {
                $this->row['status'] = 'DOWNLOADED';
                $this->row['local_path'] = $localPath;
                $this->row['local_sha256'] = $sha256;
            }
            public function markMoved(int $id): void { $this->row['status'] = 'MOVED'; }
        };

        (new DownloadQueue($client, $repo, $config))->run();

        assert($client->downloads === 1);
        assert($client->moves === 1);
        assert($repo->row['status'] === 'MOVED');
        assert($repo->row['local_path'] !== $corruptPath);
        assert(hash_file('sha256', $repo->row['local_path']) === hash('sha256', '12345'));
    },
    'download queue leaves an unlisted missing pending move as an actionable recovery blocker' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        mkdir($root . DIRECTORY_SEPARATOR . 'download', 0777, true);
        $config = downloadQueueConfig($root);
        $client = new class {
            public function listCsvFiles(string $folder): array { return []; }
            public function resolveFolderItemId(string $folder): string { return 'processed-folder-id'; }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void {}
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void {}
        };
        $repo = new class {
            public array $row = [
                'id' => 56,
                'drive_id' => 'drive',
                'item_id' => 'unlisted-missing-item',
                'status' => 'MOVING',
                'local_path' => 'C:\\queue\\unlisted-missing.csv',
                'local_sha256' => 'missing-hash',
            ];
            public function findPendingMoves(): array { return [$this->row]; }
            public function resetForRedownload(int $id, string $error): void {
                $this->row['status'] = 'RECOVERY_ERROR';
                $this->row['local_path'] = null;
                $this->row['local_sha256'] = null;
                $this->row['last_error'] = $error;
            }
            public function findByItemId(string $itemId): ?array { return $this->row; }
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return 56; }
            public function markStatus(int $id, string $status, ?string $error = null): void {}
            public function markDownloaded(int $id, string $localPath, string $sha256): void {}
            public function markMoved(int $id): void {}
        };

        (new DownloadQueue($client, $repo, $config))->run();

        assert($repo->row['status'] === 'RECOVERY_ERROR');
        assert(str_contains($repo->row['last_error'], 'redownload'));
    },
    'download queue does not move remote item when local rename fails' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        mkdir($root . DIRECTORY_SEPARATOR . 'download', 0777, true);
        $config = downloadQueueConfig($root);
        $client = new class {
            public int $moves = 0;
            public function listCsvFiles(string $folder): array { return [downloadQueueItem('rename-item')]; }
            public function resolveFolderItemId(string $folder): string { return 'processed-folder-id'; }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void { file_put_contents($targetPath, '12345'); }
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void { $this->moves++; }
        };
        $repo = new class {
            public array $statuses = [];
            public function findPendingMoves(): array { return []; }
            public function findByItemId(string $itemId): ?array { return null; }
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return 60; }
            public function markStatus(int $id, string $status, ?string $error = null): void { $this->statuses[] = [$status, $error]; }
            public function markDownloaded(int $id, string $localPath, string $sha256): void {}
            public function markMoved(int $id): void {}
        };

        (new DownloadQueue(
            $client,
            $repo,
            $config,
            static fn (string $from, string $to): bool => false,
            static fn (string $path): string => str_repeat('a', 64),
        ))->run();

        assert($client->moves === 0);
        assert(array_column($repo->statuses, 0) === ['DOWNLOADING', 'ERROR']);
    },
    'download queue does not move remote item when local hashing fails' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        mkdir($root . DIRECTORY_SEPARATOR . 'download', 0777, true);
        $config = downloadQueueConfig($root);
        $client = new class {
            public int $moves = 0;
            public function listCsvFiles(string $folder): array { return [downloadQueueItem('hash-item')]; }
            public function resolveFolderItemId(string $folder): string { return 'processed-folder-id'; }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void { file_put_contents($targetPath, '12345'); }
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void { $this->moves++; }
        };
        $repo = new class {
            public array $statuses = [];
            public function findPendingMoves(): array { return []; }
            public function findByItemId(string $itemId): ?array { return null; }
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return 70; }
            public function markStatus(int $id, string $status, ?string $error = null): void { $this->statuses[] = [$status, $error]; }
            public function markDownloaded(int $id, string $localPath, string $sha256): void {}
            public function markMoved(int $id): void {}
        };

        (new DownloadQueue(
            $client,
            $repo,
            $config,
            static fn (string $from, string $to): bool => rename($from, $to),
            static fn (string $path): bool => false,
        ))->run();

        assert($client->moves === 0);
        assert(array_column($repo->statuses, 0) === ['DOWNLOADING', 'ERROR']);
    },
];
