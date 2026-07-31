<?php

namespace App\Database;

use RuntimeException;

final class BackupCheckpointValidator
{
    private const COUNTS = ['import_files', 'payment_outbound', 'payment_mail_log', 'sharepoint_file_queue'];
    private const VIEWS = ['vw_import_report', 'v_tbpayin_from_payment_outbound'];
    public static function validate(string $manifestPath, string $receiptPath, string $database, string $releaseId): array
    {
        $manifest = self::readJson($manifestPath, 'backup manifest'); $backup = (string)($manifest['backup_file'] ?? '');
        if (strcasecmp((string)($manifest['database'] ?? ''), $database) !== 0 || (string)($manifest['release_id'] ?? '') !== $releaseId || $backup === '' || !is_file($backup)) throw new RuntimeException('Backup manifest database, release, or file is invalid.');
        self::assertArtifact($backup, (string)($manifest['sha256'] ?? ''), $manifest['size_bytes'] ?? null, 'Backup file');
        $receipt = self::readJson($receiptPath, 'restore rehearsal receipt');
        if (($receipt['status'] ?? '') !== 'PASSED' || ($receipt['release_id'] ?? '') !== $releaseId || strcasecmp((string)($receipt['database'] ?? ''), $database) !== 0) throw new RuntimeException('Restore rehearsal receipt is missing or does not match the backup.');
        self::assertArtifact($backup, (string)($receipt['backup_sha256'] ?? ''), $receipt['backup_size_bytes'] ?? null, 'Receipt backup');
        if (self::fullPath((string)($receipt['backup_path'] ?? '')) !== self::fullPath($backup)) throw new RuntimeException('Receipt backup path does not match the manifest.');
        $sanitized = (string)($receipt['sanitized_path'] ?? ''); $evidence = (string)($receipt['evidence_path'] ?? '');
        self::assertArtifact($sanitized, (string)($receipt['sanitized_sha256'] ?? ''), $receipt['sanitized_size_bytes'] ?? null, 'Receipt sanitized artifact'); self::assertArtifact($evidence, (string)($receipt['evidence_sha256'] ?? ''), $receipt['evidence_size_bytes'] ?? null, 'Receipt evidence');
        $proof = self::readJson($evidence, 'restore evidence');
        if (($proof['status'] ?? '') !== 'VERIFIED' || ($proof['release_id'] ?? '') !== $releaseId || strcasecmp((string)($proof['database'] ?? ''), $database) !== 0 || !hash_equals(strtolower((string)$receipt['backup_sha256']), strtolower((string)($proof['backup_sha256'] ?? ''))) || !hash_equals(strtolower((string)$receipt['sanitized_sha256']), strtolower((string)($proof['sanitized_sha256'] ?? '')))) throw new RuntimeException('Restore evidence does not bind to the receipt.');
        $rehearsal = (string)($proof['rehearsal_database'] ?? ''); if (!preg_match('/^[A-Za-z0-9_]+$/', $rehearsal) || strcasecmp($rehearsal, $database) === 0 || stripos($rehearsal, 'rehearsal') === false) throw new RuntimeException('Restore evidence rehearsal database is unsafe.');
        if (($receipt['rehearsal_database'] ?? '') !== $rehearsal || ($receipt['row_counts'] ?? null) !== ($proof['row_counts'] ?? null) || ($receipt['views'] ?? null) !== ($proof['views'] ?? null) || ($receipt['live_schema_reference_count'] ?? null) !== 0) throw new RuntimeException('Restore rehearsal receipt does not copy verified evidence exactly.');
        self::assertEvidence($proof); return $manifest;
    }
    private static function assertArtifact(string $path, string $hash, mixed $size, string $label): void { if ($path === '' || !is_file($path) || !preg_match('/^[a-f0-9]{64}$/i', $hash) || !is_int($size) && !ctype_digit((string)$size) || filesize($path) !== (int)$size || !hash_equals(strtolower($hash), strtolower((string)hash_file('sha256', $path)))) throw new RuntimeException("$label checksum, size, or path is invalid."); }
    private static function assertEvidence(array $proof): void { foreach (self::COUNTS as $count) self::nonNegative($proof['row_counts'][$count] ?? null, "row count $count"); foreach (self::VIEWS as $view) { self::nonNegative($proof['views'][$view]['row_count'] ?? null, "view count $view"); if (($proof['views'][$view]['security_type'] ?? '') !== 'INVOKER') throw new RuntimeException("Restore evidence view $view security is invalid."); } if (($proof['live_schema_reference_count'] ?? null) !== 0 || trim((string)($proof['verified_at'] ?? '')) === '' || trim((string)($proof['verified_by'] ?? '')) === '') throw new RuntimeException('Restore evidence verification metadata is invalid.'); }
    private static function nonNegative(mixed $value, string $label): void { if (!is_int($value) || $value < 0) throw new RuntimeException("Restore evidence $label is invalid."); }
    private static function fullPath(string $path): string { $resolved = realpath($path); return $resolved === false ? '' : strtolower(str_replace('/', '\\', $resolved)); }
    private static function readJson(string $path, string $label): array { if (!is_file($path)) throw new RuntimeException(ucfirst($label) . ' not found.'); $contents=(string)file_get_contents($path); if(str_starts_with($contents,"\xEF\xBB\xBF"))$contents=substr($contents,3); $value=json_decode($contents,true); if(!is_array($value))throw new RuntimeException(ucfirst($label).' is not valid JSON.'); return $value; }
}
