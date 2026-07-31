<?php

namespace App\Database;

use PDO;
use RuntimeException;
use Throwable;

final class MigrationRunner
{
    public function __construct(private readonly PDO $pdo)
    {
        $this->ensureLedger();
    }

    public function applyDirectory(
        string $projectName,
        string $directory,
        string $releaseId,
        string $appliedBy
    ): array {
        $lockName = 'd365-migrations-' . substr(hash('sha256', $projectName), 0, 32);
        $this->acquireLock($lockName);
        try {
            return $this->applyDirectoryLocked($projectName, $directory, $releaseId, $appliedBy);
        } finally {
            $this->releaseLock($lockName);
        }
    }

    private function applyDirectoryLocked(
        string $projectName,
        string $directory,
        string $releaseId,
        string $appliedBy
    ): array {
        $files = glob(rtrim($directory, '\\/') . DIRECTORY_SEPARATOR . '*.sql') ?: [];
        sort($files, SORT_NATURAL | SORT_FLAG_CASE);
        $applied = [];

        foreach ($files as $file) {
            $version = basename($file);
            $checksum = $this->checksum($file);
            if ($checksum === null) {
                throw new RuntimeException("Unable to hash migration: {$version}");
            }

            $existing = $this->find($projectName, $version);
            if ($existing !== null) {
                if (!hash_equals($existing['checksum_sha256'], $checksum)) {
                    throw new RuntimeException("Migration checksum mismatch: {$projectName}/{$version}");
                }
                if ($existing['status'] !== 'APPLIED') {
                    throw new RuntimeException(
                        "Migration {$projectName}/{$version} is {$existing['status']}; manual recovery is required."
                    );
                }
                continue;
            }

            $sql = file_get_contents($file);
            if ($sql === false || trim($sql) === '') {
                throw new RuntimeException("Migration is empty or unreadable: {$version}");
            }

            try {
                $statement = $this->pdo->prepare(
                    'INSERT INTO schema_migrations '
                    . '(project_name, version, checksum_sha256, release_id, applied_by, status, started_at) '
                    . 'VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)'
                );
                $statement->execute([$projectName, $version, $checksum, $releaseId, $appliedBy, 'APPLYING']);
                $this->pdo->exec($sql);
                $statement = $this->pdo->prepare(
                    'UPDATE schema_migrations SET status = ?, finished_at = CURRENT_TIMESTAMP, error_message = NULL '
                    . 'WHERE project_name = ? AND version = ?'
                );
                $statement->execute(['APPLIED', $projectName, $version]);
            } catch (Throwable $exception) {
                $statement = $this->pdo->prepare(
                    'UPDATE schema_migrations SET status = ?, finished_at = CURRENT_TIMESTAMP, error_message = ? '
                    . 'WHERE project_name = ? AND version = ?'
                );
                $statement->execute([
                    'FAILED',
                    substr($exception->getMessage(), 0, 2000),
                    $projectName,
                    $version,
                ]);
                if ($this->pdo->inTransaction()) {
                    $this->pdo->commit();
                }
                throw new RuntimeException("Migration failed: {$projectName}/{$version}", 0, $exception);
            }

            $applied[] = $version;
        }

        return $applied;
    }

    private function ensureLedger(): void
    {
        $this->pdo->exec(
            'CREATE TABLE IF NOT EXISTS schema_migrations ('
            . 'project_name VARCHAR(100) NOT NULL,'
            . 'version VARCHAR(255) NOT NULL,'
            . 'checksum_sha256 CHAR(64) NOT NULL,'
            . 'release_id VARCHAR(100) NOT NULL,'
            . 'applied_by VARCHAR(255) NOT NULL,'
            . "status VARCHAR(16) NOT NULL DEFAULT 'APPLYING',"
            . 'started_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,'
            . 'finished_at TIMESTAMP NULL DEFAULT NULL,'
            . 'error_message TEXT NULL,'
            . 'PRIMARY KEY (project_name, version)'
            . ')'
        );
    }

    private function find(string $projectName, string $version): ?array
    {
        $statement = $this->pdo->prepare(
            'SELECT checksum_sha256, status FROM schema_migrations WHERE project_name = ? AND version = ?'
        );
        $statement->execute([$projectName, $version]);
        $row = $statement->fetch(PDO::FETCH_ASSOC);
        return $row === false ? null : $row;
    }

    private function checksum(string $file): ?string
    {
        $contents = file_get_contents($file);
        if ($contents === false) {
            return null;
        }

        return hash('sha256', str_replace(["\r\n", "\r"], "\n", $contents));
    }

    private function acquireLock(string $name): void
    {
        if ($this->pdo->getAttribute(PDO::ATTR_DRIVER_NAME) !== 'mysql') {
            return;
        }
        $statement = $this->pdo->prepare('SELECT GET_LOCK(?, 30)');
        $statement->execute([$name]);
        if ((int)$statement->fetchColumn() !== 1) {
            throw new RuntimeException('Unable to acquire the database migration lock.');
        }
    }

    private function releaseLock(string $name): void
    {
        if ($this->pdo->getAttribute(PDO::ATTR_DRIVER_NAME) !== 'mysql') {
            return;
        }
        $statement = $this->pdo->prepare('SELECT RELEASE_LOCK(?)');
        $statement->execute([$name]);
    }
}
