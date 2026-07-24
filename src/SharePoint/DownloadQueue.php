<?php

namespace App\SharePoint;

use App\Config\AppConfig;
use RuntimeException;

final class DownloadQueue
{
    public function __construct(
        private readonly object $client,
        private readonly object $repo,
        private readonly AppConfig $config,
    ) {
    }

    public function run(): void
    {
        if (!is_dir($this->config->downloadDir)) {
            mkdir($this->config->downloadDir, 0777, true);
        }

        $processedFolderId = $this->client->resolveFolderItemId($this->config->processedFolder);
        $items = $this->client->listCsvFiles($this->config->sourceFolder);

        usort($items, fn (array $a, array $b): int =>
            strcmp($a['lastModifiedDateTime'] ?? '', $b['lastModifiedDateTime'] ?? '')
            ?: strcmp($a['name'] ?? '', $b['name'] ?? '')
        );

        foreach ($items as $item) {
            $id = $this->repo->upsertDiscovered($item, $this->config->sourceFolder, $this->config->processedFolder);
            $safeName = basename($item['name']);
            $finalPath = $this->config->downloadDir . DIRECTORY_SEPARATOR . $safeName;
            $partPath = $finalPath . '.part';

            try {
                $this->repo->markStatus($id, 'DOWNLOADING');
                if (is_file($partPath)) {
                    unlink($partPath);
                }

                $this->client->downloadItem($item['drive_id'], $item['id'], $partPath);
                $this->validateDownload($partPath, isset($item['size']) ? (int) $item['size'] : null);

                $finalPath = $this->unusedFinalPath($finalPath, $safeName, $item['id']);

                rename($partPath, $finalPath);
                $sha256 = hash_file('sha256', $finalPath);
                $this->repo->markDownloaded($id, $finalPath, $sha256);

                $this->repo->markStatus($id, 'MOVING');
                $this->client->moveItem($item['drive_id'], $item['id'], $processedFolderId);
                $this->repo->markMoved($id);
            } catch (\Throwable $e) {
                if (is_file($partPath)) {
                    unlink($partPath);
                }
                $this->repo->markStatus($id, 'ERROR', $e->getMessage());
            }
        }
    }

    private function validateDownload(string $path, ?int $expectedSize): void
    {
        if (!is_file($path)) {
            throw new RuntimeException('Downloaded file was not created');
        }
        if ($expectedSize !== null && filesize($path) !== $expectedSize) {
            throw new RuntimeException('Downloaded file size does not match SharePoint size');
        }
    }

    private function unusedFinalPath(string $originalPath, string $safeName, string $itemId): string
    {
        if (!is_file($originalPath)) {
            return $originalPath;
        }

        $directory = dirname($originalPath);
        $stem = pathinfo($safeName, PATHINFO_FILENAME);
        $extension = pathinfo($safeName, PATHINFO_EXTENSION);
        $suffix = 1;

        do {
            $number = $suffix === 1 ? '' : '_' . $suffix;
            $candidate = $directory . DIRECTORY_SEPARATOR . $stem . '_' . $itemId . $number
                . ($extension === '' ? '' : '.' . $extension);
            $suffix++;
        } while (is_file($candidate));

        return $candidate;
    }
}
