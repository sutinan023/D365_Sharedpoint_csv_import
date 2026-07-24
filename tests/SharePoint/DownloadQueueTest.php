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
        assert(array_column($repo->statuses, 0) === ['DOWNLOADING', 'MOVING', 'ERROR']);
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
];
