<?php

namespace App\SharePoint;

use App\Config\AppConfig;
use RuntimeException;

final class DownloadQueue
{
    private $renameFile;
    private $hashFile;

    public function __construct(
        private readonly object $client,
        private readonly object $repo,
        private readonly AppConfig $config,
        ?callable $renameFile = null,
        ?callable $hashFile = null,
    ) {
        $this->renameFile = $renameFile ?? static fn (string $from, string $to): bool => @rename($from, $to);
        $this->hashFile = $hashFile ?? static fn (string $path): string|false => @hash_file('sha256', $path);
    }

    public function run(): void
    {
        if (!is_dir($this->config->downloadDir)
            && !mkdir($this->config->downloadDir, 0777, true)
            && !is_dir($this->config->downloadDir)
        ) {
            throw new RuntimeException("Unable to create download directory: {$this->config->downloadDir}");
        }

        $processedFolderId = $this->client->resolveFolderItemId($this->config->processedFolder);
        $recoveredItemIds = $this->recoverPendingMoves($processedFolderId);
        $items = $this->client->listCsvFiles($this->config->sourceFolder);

        usort($items, fn (array $a, array $b): int =>
            strcmp($a['lastModifiedDateTime'] ?? '', $b['lastModifiedDateTime'] ?? '')
            ?: strcmp($a['name'] ?? '', $b['name'] ?? '')
        );

        foreach ($items as $item) {
            $existing = $this->repo->findByItemId($item['id']);
            $id = $this->repo->upsertDiscovered($item, $this->config->sourceFolder, $this->config->processedFolder);
            if (isset($recoveredItemIds[$item['id']]) || !$this->shouldDownload($existing)) {
                continue;
            }

            $safeName = basename($item['name']);
            $finalPath = $this->config->downloadDir . DIRECTORY_SEPARATOR . $safeName;
            $partPath = $finalPath . '.part';
            $finalizedPath = null;
            $downloadRecorded = false;
            $moving = false;

            try {
                $this->repo->markStatus($id, 'DOWNLOADING');
                if (is_file($partPath)) {
                    unlink($partPath);
                }

                $this->client->downloadItem($item['drive_id'], $item['id'], $partPath);
                $this->validateDownload($partPath, isset($item['size']) ? (int) $item['size'] : null);

                $finalPath = $this->unusedFinalPath($finalPath, $safeName, $item['id']);

                if (!(($this->renameFile)($partPath, $finalPath))) {
                    throw new RuntimeException("Unable to finalize downloaded file: {$finalPath}");
                }
                $finalizedPath = $finalPath;

                $sha256 = ($this->hashFile)($finalPath);
                if ($sha256 === false || $sha256 === '') {
                    throw new RuntimeException("Unable to hash downloaded file: {$finalPath}");
                }
                $this->repo->markDownloaded($id, $finalPath, $sha256);
                $downloadRecorded = true;

                $moving = true;
                $this->repo->markStatus($id, 'MOVING');
                $this->client->moveItem($item['drive_id'], $item['id'], $processedFolderId);
                $this->repo->markMoved($id);
            } catch (\Throwable $e) {
                if (is_file($partPath)) {
                    unlink($partPath);
                }
                if (!$downloadRecorded && $finalizedPath !== null && is_file($finalizedPath)) {
                    unlink($finalizedPath);
                }
                $this->repo->markStatus($id, $moving ? 'MOVING' : 'ERROR', $e->getMessage());
            }
        }
    }

    private function recoverPendingMoves(string $processedFolderId): array
    {
        $recoveredItemIds = [];

        foreach ($this->repo->findPendingMoves() as $row) {
            $id = (int) $row['id'];
            $itemId = (string) $row['item_id'];

            try {
                $localPath = (string) ($row['local_path'] ?? '');
                $expectedHash = (string) ($row['local_sha256'] ?? '');
                if ($localPath === '' || !is_file($localPath)) {
                    throw new RuntimeException('Downloaded local file is missing');
                }

                $actualHash = ($this->hashFile)($localPath);
                if ($actualHash === false || $actualHash === '' || !hash_equals($expectedHash, $actualHash)) {
                    throw new RuntimeException('Downloaded local file hash does not match');
                }
            } catch (\Throwable $e) {
                $this->repo->resetForRedownload(
                    $id,
                    $e->getMessage()
                        . '; redownload required from the SharePoint source folder, or operator recovery if it is no longer listed'
                );
                continue;
            }

            $recoveredItemIds[$itemId] = true;
            try {
                $this->repo->markStatus($id, 'MOVING');
                $this->client->moveItem((string) $row['drive_id'], $itemId, $processedFolderId);
                $this->repo->markMoved($id);
            } catch (\Throwable $e) {
                $this->repo->markStatus($id, 'MOVING', $e->getMessage());
            }
        }

        return $recoveredItemIds;
    }

    private function shouldDownload(?array $existing): bool
    {
        if ($existing === null) {
            return true;
        }

        if (in_array($existing['status'] ?? '', ['DISCOVERED', 'DOWNLOADING'], true)) {
            return true;
        }

        return in_array($existing['status'] ?? '', ['ERROR', 'RECOVERY_ERROR'], true)
            && empty($existing['local_path']);
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
