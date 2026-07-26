<?php

namespace App\Queue;

use DateTimeImmutable;
use PDO;

final class FileQueueRepository
{
    public function __construct(private readonly PDO $pdo)
    {
    }

    public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int
    {
        $modified = $this->toSqlDate($item['lastModifiedDateTime'] ?? null);
        $existing = $this->findByItemId($item['id']);

        if ($existing !== null) {
            $stmt = $this->pdo->prepare(
                'UPDATE sharepoint_file_queue
                 SET drive_id = :drive_id, file_name = :file_name, sharepoint_size = :size,
                     sharepoint_etag = :etag, sharepoint_last_modified_at = :modified,
                     updated_at = CURRENT_TIMESTAMP
                 WHERE item_id = :item_id'
            );
            $stmt->execute([
                ':drive_id' => $item['drive_id'] ?? null,
                ':file_name' => $item['name'],
                ':size' => $item['size'] ?? null,
                ':etag' => $item['eTag'] ?? null,
                ':modified' => $modified,
                ':item_id' => $item['id'],
            ]);

            return (int) $existing['id'];
        }

        $stmt = $this->pdo->prepare(
            'INSERT INTO sharepoint_file_queue
             (drive_id, item_id, source_folder, processed_folder, file_name, sharepoint_size, sharepoint_etag, sharepoint_last_modified_at, status)
             VALUES (:drive_id, :item_id, :source_folder, :processed_folder, :file_name, :size, :etag, :modified, :status)'
        );
        $stmt->execute([
            ':drive_id' => $item['drive_id'] ?? null,
            ':item_id' => $item['id'],
            ':source_folder' => $sourceFolder,
            ':processed_folder' => $processedFolder,
            ':file_name' => $item['name'],
            ':size' => $item['size'] ?? null,
            ':etag' => $item['eTag'] ?? null,
            ':modified' => $modified,
            ':status' => 'DISCOVERED',
        ]);

        return (int) $this->pdo->lastInsertId();
    }

    public function findByItemId(string $itemId): ?array
    {
        $stmt = $this->pdo->prepare('SELECT * FROM sharepoint_file_queue WHERE item_id = :item_id');
        $stmt->execute([':item_id' => $itemId]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);

        return $row === false ? null : $row;
    }

    public function findReadyForImport(): array
    {
        $stmt = $this->pdo->query(
            "SELECT * FROM sharepoint_file_queue
             WHERE status IN (
                 'MOVED', 'IMPORT_ERROR', 'RECOVERY_ERROR',
                 'DOWNLOADED', 'MOVING', 'IMPORTING', 'RECOVERY_DOWNLOADING'
             )
             ORDER BY sharepoint_last_modified_at ASC, id ASC"
        );

        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    public function findInterruptedImports(): array
    {
        $stmt = $this->pdo->query(
            "SELECT * FROM sharepoint_file_queue
             WHERE status = 'IMPORTING'
                OR (status = 'RECOVERY_ERROR' AND moved_at IS NOT NULL)
             ORDER BY sharepoint_last_modified_at ASC, id ASC"
        );

        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    public function findPendingMoves(): array
    {
        $stmt = $this->pdo->query(
            "SELECT * FROM sharepoint_file_queue
             WHERE status IN ('DOWNLOADED', 'MOVING')
                OR (status = 'ERROR' AND local_path IS NOT NULL AND local_sha256 IS NOT NULL)
                OR (
                    status = 'RECOVERY_ERROR'
                    AND moved_at IS NULL
                    AND local_path IS NOT NULL
                    AND local_sha256 IS NOT NULL
                )
             ORDER BY sharepoint_last_modified_at ASC, id ASC"
        );

        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    public function findTerminalRowsInDownload(string $downloadDir, int $olderThanDays): array
    {
        $downloadPrefix = rtrim(str_replace('\\', '/', $downloadDir), '/') . '/';
        $cutoff = (new DateTimeImmutable("-{$olderThanDays} days"))->format('Y-m-d H:i:s');

        $stmt = $this->pdo->prepare(
            "SELECT * FROM sharepoint_file_queue
             WHERE status IN ('SUCCESS', 'IMPORTED', 'SKIPPED_DUPLICATE')
               AND local_path IS NOT NULL
               AND REPLACE(local_path, CHAR(92), '/') LIKE :download_prefix
               AND LOWER(local_path) LIKE '%.csv'
               AND COALESCE(imported_at, updated_at, created_at) < :cutoff
             ORDER BY COALESCE(imported_at, updated_at, created_at) ASC, id ASC"
        );
        $stmt->execute([
            ':download_prefix' => $downloadPrefix . '%',
            ':cutoff' => $cutoff,
        ]);

        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    public function updateLocalPath(int $id, string $localPath): void
    {
        $stmt = $this->pdo->prepare(
            'UPDATE sharepoint_file_queue
             SET local_path = :local_path, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id'
        );
        $stmt->execute([':local_path' => $localPath, ':id' => $id]);
    }

    public function markStatus(int $id, string $status, ?string $error = null): void
    {
        $stmt = $this->pdo->prepare(
            'UPDATE sharepoint_file_queue
             SET status = :status, last_error = :error,
                 attempt_count = attempt_count + :attempt_increment,
                 updated_at = CURRENT_TIMESTAMP
             WHERE id = :id'
        );
        $stmt->execute([
            ':status' => $status,
            ':error' => $error,
            ':attempt_increment' => $error === null ? 0 : 1,
            ':id' => $id,
        ]);
    }

    public function markDownloaded(int $id, string $localPath, string $sha256): void
    {
        $stmt = $this->pdo->prepare(
            "UPDATE sharepoint_file_queue
             SET status = 'DOWNLOADED', local_path = :local_path, local_sha256 = :sha256,
                 last_error = NULL, downloaded_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id"
        );
        $stmt->execute([':local_path' => $localPath, ':sha256' => $sha256, ':id' => $id]);
    }

    public function resetForRedownload(int $id, string $error): void
    {
        $stmt = $this->pdo->prepare(
            "UPDATE sharepoint_file_queue
             SET status = 'RECOVERY_ERROR', local_path = NULL, local_sha256 = NULL,
                 downloaded_at = NULL, moved_at = NULL, last_error = :error,
                 attempt_count = attempt_count + 1, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id"
        );
        $stmt->execute([':error' => $error, ':id' => $id]);
    }

    public function markMoved(int $id): void
    {
        $stmt = $this->pdo->prepare(
            "UPDATE sharepoint_file_queue
             SET status = 'MOVED', last_error = NULL, moved_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id"
        );
        $stmt->execute([':id' => $id]);
    }

    public function markImported(int $id): void
    {
        $stmt = $this->pdo->prepare(
            "UPDATE sharepoint_file_queue
             SET status = 'IMPORTED', last_error = NULL, imported_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id"
        );
        $stmt->execute([':id' => $id]);
    }

    public function markSkippedDuplicate(int $id, string $sha256): void
    {
        $stmt = $this->pdo->prepare(
            "UPDATE sharepoint_file_queue
             SET status = 'SKIPPED_DUPLICATE', local_sha256 = :sha256, last_error = NULL,
                 imported_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id"
        );
        $stmt->execute([':sha256' => $sha256, ':id' => $id]);
    }

    private function toSqlDate(?string $value): ?string
    {
        if ($value === null || $value === '') {
            return null;
        }

        return (new DateTimeImmutable($value))->format('Y-m-d H:i:s');
    }
}
