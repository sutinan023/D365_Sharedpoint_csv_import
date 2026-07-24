<?php

use App\Config\AppConfig;
use App\SharePoint\DownloadQueue;

return [
    'download queue downloads to part validates then moves' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        mkdir($root . DIRECTORY_SEPARATOR . 'download', 0777, true);

        $_ENV['CSV_FOLDER'] = 'PaymentBeforePost';
        $_ENV['CSV_DOWNLOADED_FOLDER'] = 'PaymentBeforePost_Downloaded';
        $_ENV['CSV_LOCAL_DOWNLOAD_DIR'] = 'download';
        $_ENV['CSV_LOCAL_ARCHIVE_DIR'] = 'archive';
        $_ENV['CSV_LOCAL_ERROR_DIR'] = 'error';
        $_ENV['PIPELINE_LOCK_FILE'] = 'temp/pipeline.lock';

        $config = AppConfig::fromEnv($root);
        $client = new class {
            public array $moved = [];
            public function listCsvFiles(string $folder): array {
                return [[
                    'drive_id' => 'drive',
                    'id' => 'item1',
                    'name' => 'first.csv',
                    'size' => 5,
                    'eTag' => 'etag1',
                    'lastModifiedDateTime' => '2026-07-24T01:00:00Z',
                ]];
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
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return $this->id; }
            public function markStatus(int $id, string $status, ?string $error = null): void {}
            public function markDownloaded(int $id, string $localPath, string $sha256): void { $this->downloaded[] = [$id, $localPath, $sha256]; }
            public function markMoved(int $id): void { $this->moved[] = $id; }
        };

        (new DownloadQueue($client, $repo, $config))->run();

        assert(is_file($root . DIRECTORY_SEPARATOR . 'download' . DIRECTORY_SEPARATOR . 'first.csv'));
        assert(!is_file($root . DIRECTORY_SEPARATOR . 'download' . DIRECTORY_SEPARATOR . 'first.csv.part'));
        assert(count($client->moved) === 1);
        assert($repo->moved === [10]);
    },
];
