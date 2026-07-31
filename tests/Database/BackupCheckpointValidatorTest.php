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
        'source_path' => $backup, 'source_database' => 'D365_finance_prod', 'rehearsal_database' => 'D365_finance_prod_rehearsal_r1', 'source_sha256' => hash_file('sha256', $backup),
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
        'sanitizer_audit_path' => $audit, 'sanitizer_audit_sha256' => hash_file('sha256', $audit), 'sanitizer_audit_size_bytes' => filesize($audit),
        'sanitized_sha256' => hash_file('sha256', $sanitized), 'sanitized_path' => $sanitized, 'sanitized_size_bytes' => filesize($sanitized),
        'evidence_sha256' => hash_file('sha256', $evidence), 'evidence_path' => $evidence, 'evidence_size_bytes' => filesize($evidence),
        'row_counts' => ['import_files' => 1, 'payment_outbound' => 2, 'payment_mail_log' => 0, 'sharepoint_file_queue' => 3],
        'views' => ['vw_import_report' => ['row_count' => 1, 'security_type' => 'INVOKER'], 'v_tbpayin_from_payment_outbound' => ['row_count' => 2, 'security_type' => 'INVOKER']],
        'live_schema_reference_count' => 0, 'approved_at' => '2026-08-01T00:00:00Z', 'approved_by' => 'tester', 'approved_by_sid' => 'S-1-5-21-1-2-3-1001',
    ]));
    return compact('backup', 'sanitized', 'manifest', 'audit', 'evidence', 'receipt');
}

return [
    'backup checkpoint validator binds durable restore evidence to backup' => function (): void {
        $directory = sys_get_temp_dir() . '/checkpoint-validator-' . bin2hex(random_bytes(4)); mkdir($directory); $f = checkpointFixture($directory);
        BackupCheckpointValidator::validate($f['manifest'], $f['receipt'], 'D365_finance_prod', 'r1', $directory);
        foreach ($f as $path) { if (is_file($path)) unlink($path); } rmdir($directory);
    },
    'backup checkpoint validator rejects tampered durable evidence' => function (): void {
        $directory = sys_get_temp_dir() . '/checkpoint-validator-' . bin2hex(random_bytes(4)); mkdir($directory); $f = checkpointFixture($directory); file_put_contents($f['evidence'], "\nTAMPERED", FILE_APPEND);
        try { BackupCheckpointValidator::validate($f['manifest'], $f['receipt'], 'D365_finance_prod', 'r1', $directory); }
        catch (RuntimeException $e) { assert(str_contains($e->getMessage(), 'evidence')); foreach ($f as $path) { if (is_file($path)) unlink($path); } rmdir($directory); return; }
        throw new RuntimeException('Expected tampered evidence to be rejected');
    },
    'backup checkpoint validator rejects legacy receipt' => function (): void {
        $directory = sys_get_temp_dir() . '/checkpoint-validator-' . bin2hex(random_bytes(4)); mkdir($directory); $f = checkpointFixture($directory);
        file_put_contents($f['receipt'], json_encode(['status' => 'PASSED', 'release_id' => 'r1', 'backup_sha256' => hash_file('sha256', $f['backup'])]));
        try { BackupCheckpointValidator::validate($f['manifest'], $f['receipt'], 'D365_finance_prod', 'r1', $directory); } catch (RuntimeException $e) { assert(str_contains($e->getMessage(), 'legacy')); foreach ($f as $path) { if (is_file($path)) unlink($path); } rmdir($directory); return; }
        throw new RuntimeException('Expected legacy receipt to be rejected');
    },
    'backup checkpoint validator rejects nested duplicate evidence keys' => function (): void {
        $directory = sys_get_temp_dir() . '/checkpoint-validator-' . bin2hex(random_bytes(4)); mkdir($directory); $f = checkpointFixture($directory);
        $raw = (string)file_get_contents($f['evidence']);
        file_put_contents($f['evidence'], str_replace('"import_files":1', '"import_files":99,"import_files":1', $raw));
        $receipt = json_decode((string)file_get_contents($f['receipt']), true);
        $receipt['evidence_sha256'] = hash_file('sha256', $f['evidence']); $receipt['evidence_size_bytes'] = filesize($f['evidence']);
        file_put_contents($f['receipt'], json_encode($receipt));
        try { BackupCheckpointValidator::validate($f['manifest'], $f['receipt'], 'D365_finance_prod', 'r1', $directory); } catch (RuntimeException $e) { assert(str_contains($e->getMessage(), 'duplicate')); foreach ($f as $path) { if (is_file($path)) unlink($path); } rmdir($directory); return; }
        throw new RuntimeException('Expected nested duplicate evidence key to be rejected');
    },
    'backup checkpoint validator rejects extra evidence keys and numeric strings' => function (): void {
        foreach (['extra' => 4, 'string' => '1'] as $case => $value) {
            $directory = sys_get_temp_dir() . '/checkpoint-validator-' . bin2hex(random_bytes(4)); mkdir($directory); $f = checkpointFixture($directory);
            $proof = json_decode((string)file_get_contents($f['evidence']), true);
            if ($case === 'extra') { $proof['row_counts']['extra_table'] = $value; } else { $proof['row_counts']['import_files'] = $value; }
            file_put_contents($f['evidence'], json_encode($proof)); $receipt = json_decode((string)file_get_contents($f['receipt']), true); $receipt['evidence_sha256'] = hash_file('sha256', $f['evidence']); $receipt['evidence_size_bytes'] = filesize($f['evidence']); $receipt['row_counts'] = $proof['row_counts']; file_put_contents($f['receipt'], json_encode($receipt));
            try { BackupCheckpointValidator::validate($f['manifest'], $f['receipt'], 'D365_finance_prod', 'r1', $directory); } catch (RuntimeException) { foreach ($f as $path) { if (is_file($path)) unlink($path); } rmdir($directory); continue; }
            throw new RuntimeException("Expected $case evidence to be rejected");
        }
    },
    'backup checkpoint validator rejects artifacts outside injected test root' => function (): void {
        $directory = sys_get_temp_dir() . '/checkpoint-validator-' . bin2hex(random_bytes(4)); mkdir($directory); $f = checkpointFixture($directory);
        $outside = sys_get_temp_dir() . '/outside-receipt-' . bin2hex(random_bytes(4)) . '.json'; copy($f['receipt'], $outside);
        try { BackupCheckpointValidator::validate($f['manifest'], $outside, 'D365_finance_prod', 'r1', $directory); }
        catch (RuntimeException $e) { assert(str_contains($e->getMessage(), 'trusted root')); unlink($outside); foreach ($f as $path) { if (is_file($path)) unlink($path); } rmdir($directory); return; }
        throw new RuntimeException('Expected artifact outside injected root to be rejected');
    },
    'backup checkpoint ACL policy permits only approved SID writers and owner' => function (): void {
        BackupCheckpointValidator::validateAclEvidence(['owner_sid' => 'S-1-5-18', 'allow_aces' => [['sid' => 'S-1-5-32-544', 'rights_value' => 2, 'is_inherited' => true]]], 'S-1-5-21-1-2-3-1001');
        foreach ([['owner_sid' => 'S-1-5-21-9', 'allow_aces' => []], ['owner_sid' => 'S-1-5-18', 'allow_aces' => [['sid' => 'S-1-5-21-9', 'rights_value' => 2, 'is_inherited' => false]]]] as $bad) { try { BackupCheckpointValidator::validateAclEvidence($bad, 'S-1-5-21-1-2-3-1001'); } catch (RuntimeException) { continue; } throw new RuntimeException('Expected unapproved ACL identity to be rejected'); }
    },
    'backup checkpoint validator rejects sanitizer rehearsal mismatch' => function (): void {
        foreach (['missing', 'D365_finance_rehearsal_cross'] as $badValue) {
            $directory = sys_get_temp_dir() . '/checkpoint-validator-' . bin2hex(random_bytes(4)); mkdir($directory); $f = checkpointFixture($directory); $audit = json_decode((string)file_get_contents($f['audit']), true); if ($badValue === 'missing') { unset($audit['rehearsal_database']); } else { $audit['rehearsal_database'] = $badValue; } file_put_contents($f['audit'], json_encode($audit)); $receipt = json_decode((string)file_get_contents($f['receipt']), true); $receipt['sanitizer_audit_sha256'] = hash_file('sha256', $f['audit']); $receipt['sanitizer_audit_size_bytes'] = filesize($f['audit']); file_put_contents($f['receipt'], json_encode($receipt));
            try { BackupCheckpointValidator::validate($f['manifest'], $f['receipt'], 'D365_finance_prod', 'r1', $directory); } catch (RuntimeException) { foreach ($f as $path) { if (is_file($path)) unlink($path); } rmdir($directory); continue; } throw new RuntimeException('Expected sanitizer rehearsal mismatch to be rejected');
        }
    },
];
