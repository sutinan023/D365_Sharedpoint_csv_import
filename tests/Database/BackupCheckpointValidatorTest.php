<?php

use App\Database\BackupCheckpointValidator;

function checkpointFixture(string $directory): array
{
    $backup = $directory . '/backup.sql';
    $sanitized = $directory . '/backup.sanitized.sql';
    file_put_contents($backup, 'SQL BACKUP');
    file_put_contents($sanitized, 'SANITIZED SQL BACKUP');
    $manifest = $directory . '/backup.sql.json';
    file_put_contents($manifest, json_encode([
        'database' => 'D365_finance_prod', 'release_id' => 'r1', 'backup_file' => $backup,
        'sha256' => hash_file('sha256', $backup), 'size_bytes' => filesize($backup),
    ]));
    $audit = $directory . '/backup.sanitized.audit.json';
    file_put_contents($audit, json_encode([
        'source_database' => 'D365_finance_prod', 'source_sha256' => hash_file('sha256', $backup),
        'sanitized_path' => $sanitized, 'sanitized_sha256' => hash_file('sha256', $sanitized),
        'sanitized_size_bytes' => filesize($sanitized),
    ]));
    $evidence = $directory . '/restore.evidence.json';
    file_put_contents($evidence, json_encode([
        'status' => 'VERIFIED', 'release_id' => 'r1', 'database' => 'D365_finance_prod',
        'rehearsal_database' => 'D365_finance_prod_rehearsal_r1',
        'backup_sha256' => hash_file('sha256', $backup), 'sanitized_sha256' => hash_file('sha256', $sanitized),
        'row_counts' => ['import_files' => 1, 'payment_outbound' => 2, 'payment_mail_log' => 0, 'sharepoint_file_queue' => 3],
        'views' => ['vw_import_report' => ['row_count' => 1, 'security_type' => 'INVOKER'], 'v_tbpayin_from_payment_outbound' => ['row_count' => 2, 'security_type' => 'INVOKER']],
        'live_schema_reference_count' => 0, 'verified_at' => '2026-08-01T00:00:00Z', 'verified_by' => 'tester',
    ]));
    $receipt = $directory . '/backup.sql.restore-approved.json';
    file_put_contents($receipt, json_encode([
        'status' => 'PASSED', 'release_id' => 'r1', 'database' => 'D365_finance_prod', 'rehearsal_database' => 'D365_finance_prod_rehearsal_r1',
        'backup_sha256' => hash_file('sha256', $backup), 'backup_path' => $backup, 'backup_size_bytes' => filesize($backup),
        'sanitized_sha256' => hash_file('sha256', $sanitized), 'sanitized_path' => $sanitized, 'sanitized_size_bytes' => filesize($sanitized),
        'evidence_sha256' => hash_file('sha256', $evidence), 'evidence_path' => $evidence, 'evidence_size_bytes' => filesize($evidence),
        'row_counts' => ['import_files' => 1, 'payment_outbound' => 2, 'payment_mail_log' => 0, 'sharepoint_file_queue' => 3],
        'views' => ['vw_import_report' => ['row_count' => 1, 'security_type' => 'INVOKER'], 'v_tbpayin_from_payment_outbound' => ['row_count' => 2, 'security_type' => 'INVOKER']],
        'live_schema_reference_count' => 0, 'approved_at' => '2026-08-01T00:00:00Z', 'approved_by' => 'tester',
    ]));
    return compact('backup', 'sanitized', 'manifest', 'audit', 'evidence', 'receipt');
}

return [
    'backup checkpoint validator binds durable restore evidence to backup' => function (): void {
        $directory = sys_get_temp_dir() . '/checkpoint-validator-' . bin2hex(random_bytes(4)); mkdir($directory); $f = checkpointFixture($directory);
        BackupCheckpointValidator::validate($f['manifest'], $f['receipt'], 'D365_finance_prod', 'r1');
        foreach ($f as $path) { if (is_file($path)) unlink($path); } rmdir($directory);
    },
    'backup checkpoint validator rejects tampered durable evidence' => function (): void {
        $directory = sys_get_temp_dir() . '/checkpoint-validator-' . bin2hex(random_bytes(4)); mkdir($directory); $f = checkpointFixture($directory); file_put_contents($f['evidence'], "\nTAMPERED", FILE_APPEND);
        try { BackupCheckpointValidator::validate($f['manifest'], $f['receipt'], 'D365_finance_prod', 'r1'); }
        catch (RuntimeException $e) { assert(str_contains($e->getMessage(), 'evidence')); foreach ($f as $path) { if (is_file($path)) unlink($path); } rmdir($directory); return; }
        throw new RuntimeException('Expected tampered evidence to be rejected');
    },
];
