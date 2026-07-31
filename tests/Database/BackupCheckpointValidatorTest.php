<?php

use App\Database\BackupCheckpointValidator;

return [
    'backup checkpoint validation binds rehearsal to backup hash' => function (): void {
        $directory = sys_get_temp_dir() . '/checkpoint-validator-' . bin2hex(random_bytes(4));
        mkdir($directory);
        $backup = $directory . '/backup.sql';
        file_put_contents($backup, 'SQL BACKUP');
        $hash = hash_file('sha256', $backup);
        $manifest = $directory . '/backup.sql.json';
        file_put_contents($manifest, json_encode([
            'database' => 'D365_finance_prod',
            'release_id' => 'r1',
            'backup_file' => $backup,
            'sha256' => $hash,
            'size_bytes' => filesize($backup),
        ]));
        $receipt = $directory . '/backup.sql.restore-approved.json';
        file_put_contents($receipt, json_encode([
            'status' => 'PASSED',
            'release_id' => 'r1',
            'backup_sha256' => $hash,
        ]));

        BackupCheckpointValidator::validate($manifest, $receipt, 'D365_finance_prod', 'r1');
        file_put_contents($backup, 'TAMPERED');
        try {
            BackupCheckpointValidator::validate($manifest, $receipt, 'D365_finance_prod', 'r1');
        } catch (RuntimeException $exception) {
            assert(str_contains($exception->getMessage(), 'checksum'));
            foreach ([$backup, $manifest, $receipt] as $file) {
                unlink($file);
            }
            rmdir($directory);
            return;
        }
        throw new RuntimeException('Expected tampered backup to be rejected');
    },
];
