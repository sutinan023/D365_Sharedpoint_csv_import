<?php

namespace App\Database;

use RuntimeException;

final class BackupCheckpointValidator
{
    public static function validate(
        string $manifestPath,
        string $receiptPath,
        string $database,
        string $releaseId
    ): array {
        $manifest = self::readJson($manifestPath, 'backup manifest');
        $backupFile = (string)($manifest['backup_file'] ?? '');
        if (
            strcasecmp((string)($manifest['database'] ?? ''), $database) !== 0
            || (string)($manifest['release_id'] ?? '') !== $releaseId
            || $backupFile === ''
            || !is_file($backupFile)
        ) {
            throw new RuntimeException('Backup manifest database, release, or file is invalid.');
        }

        $actualHash = hash_file('sha256', $backupFile);
        $actualSize = filesize($backupFile);
        if (
            $actualHash === false
            || !hash_equals(strtolower((string)($manifest['sha256'] ?? '')), strtolower($actualHash))
            || (int)($manifest['size_bytes'] ?? -1) !== $actualSize
        ) {
            throw new RuntimeException('Backup file checksum or size does not match its manifest.');
        }

        $receipt = self::readJson($receiptPath, 'restore rehearsal receipt');
        if (
            (string)($receipt['status'] ?? '') !== 'PASSED'
            || (string)($receipt['release_id'] ?? '') !== $releaseId
            || !hash_equals(strtolower((string)($receipt['backup_sha256'] ?? '')), strtolower($actualHash))
        ) {
            throw new RuntimeException('Restore rehearsal receipt is missing or does not match the backup.');
        }
        return $manifest;
    }

    private static function readJson(string $path, string $label): array
    {
        if (!is_file($path)) {
            throw new RuntimeException(ucfirst($label) . ' not found.');
        }
        $contents = (string)file_get_contents($path);
        if (str_starts_with($contents, "\xEF\xBB\xBF")) {
            $contents = substr($contents, 3);
        }
        $value = json_decode($contents, true);
        if (!is_array($value)) {
            throw new RuntimeException(ucfirst($label) . ' is not valid JSON.');
        }
        return $value;
    }
}
