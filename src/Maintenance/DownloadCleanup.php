<?php

namespace App\Maintenance;

use App\Config\AppConfig;
use App\Queue\FileQueueRepository;
use App\Support\Logger;
use RuntimeException;

final class DownloadCleanup
{
    public function __construct(
        private readonly FileQueueRepository $repo,
        private readonly AppConfig $config,
        private readonly Logger $logger,
        private readonly int $retentionDays,
    ) {
    }

    public function run(bool $dryRun = true): array
    {
        $rows = $this->repo->findTerminalRowsInDownload($this->config->downloadDir, $this->retentionDays);
        $result = [
            'candidates' => count($rows),
            'moved' => 0,
            'skipped' => 0,
        ];

        foreach ($rows as $row) {
            $source = (string) ($row['local_path'] ?? '');
            $queueId = (int) $row['id'];

            if (!$this->isSafeDownloadCsv($source)) {
                $result['skipped']++;
                $this->logger->info("Download cleanup skipped unsafe path queue_id={$queueId} file={$source}");
                continue;
            }

            if (!is_file($source)) {
                $result['skipped']++;
                $this->logger->info("Download cleanup skipped missing file queue_id={$queueId} file={$source}");
                continue;
            }

            $target = $this->uniquePath($this->targetPath($source));
            if ($dryRun) {
                $this->logger->info("Download cleanup dry-run queue_id={$queueId} from={$source} to={$target}");
                continue;
            }

            $targetDir = dirname($target);
            if (!is_dir($targetDir) && !mkdir($targetDir, 0777, true) && !is_dir($targetDir)) {
                throw new RuntimeException("Unable to create cleanup directory {$targetDir}");
            }

            if (!rename($source, $target)) {
                throw new RuntimeException("Unable to move {$source} to {$target}");
            }

            $this->repo->updateLocalPath($queueId, $target);
            $result['moved']++;
            $this->logger->info("Download cleanup moved queue_id={$queueId} from={$source} to={$target}");
        }

        return $result;
    }

    private function isSafeDownloadCsv(string $path): bool
    {
        $downloadRoot = realpath($this->config->downloadDir);
        $candidate = realpath($path);

        if ($downloadRoot === false || $candidate === false) {
            return false;
        }

        $downloadPrefix = rtrim(str_replace('\\', '/', $downloadRoot), '/') . '/';
        $normalizedCandidate = str_replace('\\', '/', $candidate);

        return str_starts_with($normalizedCandidate, $downloadPrefix)
            && strcasecmp(pathinfo($normalizedCandidate, PATHINFO_EXTENSION), 'csv') === 0;
    }

    private function targetPath(string $source): string
    {
        return rtrim($this->config->archiveDir, "\\/")
            . DIRECTORY_SEPARATOR . 'download-cleanup'
            . DIRECTORY_SEPARATOR . date('Y-m')
            . DIRECTORY_SEPARATOR . basename($source);
    }

    private function uniquePath(string $path): string
    {
        if (!file_exists($path)) {
            return $path;
        }

        $dir = dirname($path);
        $name = pathinfo($path, PATHINFO_FILENAME);
        $extension = pathinfo($path, PATHINFO_EXTENSION);

        return $dir
            . DIRECTORY_SEPARATOR
            . $name
            . '_'
            . date('Ymd_His')
            . ($extension === '' ? '' : '.' . $extension);
    }
}
