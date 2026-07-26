<?php

namespace App\Import;

final class ImportQueue
{
    public function __construct(
        private readonly object $repo,
        private readonly object $importer,
    ) {
    }

    public function run(): void
    {
        $this->recoverInterruptedImports();

        foreach ($this->repo->findReadyForImport() as $row) {
            if (($row['status'] ?? 'MOVED') !== 'MOVED') {
                break;
            }

            $id = (int) $row['id'];
            $path = $row['local_path'];
            $sha256 = $row['local_sha256'] ?? (is_file($path) ? hash_file('sha256', $path) : '');

            try {
                if ($sha256 !== '' && $this->importer->isDuplicateHash($sha256)) {
                    $this->repo->markSkippedDuplicate($id, $sha256);
                    continue;
                }

                $this->repo->markStatus($id, 'IMPORTING');
                $this->importer->importFile($path, $id);
                $this->repo->markImported($id);
            } catch (\Throwable $e) {
                $this->repo->markStatus($id, 'IMPORT_ERROR', $e->getMessage());
                break;
            }
        }
    }

    private function recoverInterruptedImports(): void
    {
        foreach ($this->repo->findInterruptedImports() as $row) {
            $id = (int) $row['id'];

            try {
                $result = $this->importer->reconcileInterruptedImport($row);
                $action = $result['action'] ?? 'BLOCKED';

                if ($action === 'IMPORTED') {
                    $this->repo->markImported($id);
                    continue;
                }

                if ($action === 'RETRY') {
                    $this->repo->markStatus($id, 'MOVED');
                    break;
                }

                $this->repo->markStatus(
                    $id,
                    'RECOVERY_ERROR',
                    $result['message'] ?? 'Interrupted import requires operator recovery'
                );
                break;
            } catch (\Throwable $e) {
                $this->repo->markStatus(
                    $id,
                    'RECOVERY_ERROR',
                    'Interrupted import recovery failed: ' . $e->getMessage()
                );
                break;
            }
        }
    }
}
