<?php
declare(strict_types=1);

namespace App\Import;

use PDO;
use RuntimeException;
use Throwable;

final class FailedImportRetry
{
    private readonly FailedImportRetrySql $sql;

    public function __construct(private readonly PDO $pdo, ?FailedImportRetrySql $sql = null)
    {
        $this->sql = $sql ?? ($pdo->getAttribute(PDO::ATTR_DRIVER_NAME) === 'mysql'
            ? new MysqlFailedImportRetrySql()
            : new SqliteFailedImportRetrySql());
    }

    public function retry(int $id, string $fileName, string $sha256): array
    {
        $this->sql->begin($this->pdo);

        try {
            $queue = $this->queueRow($id);
            if ($queue === false
                || $queue['file_name'] !== $fileName
                || $queue['local_sha256'] !== $sha256
                || $queue['status'] !== 'IMPORT_ERROR'
                || $queue['imported_at'] !== null) {
                throw new RuntimeException('Queue row does not meet failed-import retry requirements.');
            }

            $this->requireErroredImportFile($fileName, $sha256);
            $this->requireNoRows(
                'SELECT 1 FROM payment_before_post WHERE '
                . $this->sql->exactEquals('source_file_name', ':file_name')
                . ' AND ' . $this->sql->exactEquals('file_hash', ':sha256')
                . ' LIMIT 1' . $this->sql->lockingSuffix('business'),
                [':file_name' => $fileName, ':sha256' => $sha256],
                'Business rows exist for the failed import.'
            );
            $this->requireNoRows(
                'SELECT 1 FROM stg_payment_before_post WHERE '
                . $this->sql->exactEquals('source_file_name', ':file_name')
                . ' AND ' . $this->sql->exactEquals('file_hash', ':sha256')
                . ' LIMIT 1' . $this->sql->lockingSuffix('staging'),
                [':file_name' => $fileName, ':sha256' => $sha256],
                'Staging rows exist for the failed import.'
            );
            $this->requireNoRows(
                'SELECT 1 FROM payment_before_post_history WHERE '
                . $this->sql->exactEquals('source_file_name', ':file_name')
                . ' LIMIT 1' . $this->sql->lockingSuffix('history'),
                [':file_name' => $fileName],
                'History rows exist for the failed import.'
            );

            $update = $this->pdo->prepare(
                "UPDATE sharepoint_file_queue
                 SET status = 'MOVED', last_error = NULL, import_started_at = NULL, updated_at = CURRENT_TIMESTAMP
                 WHERE id = :id
                   AND " . $this->sql->exactEquals('file_name', ':file_name') . "
                   AND " . $this->sql->exactEquals('local_sha256', ':sha256') . "
                   AND " . $this->sql->exactEquals('status', "'IMPORT_ERROR'") . "
                   AND imported_at IS NULL"
            );
            $update->execute([':id' => $id, ':file_name' => $fileName, ':sha256' => $sha256]);
            if ($update->rowCount() !== 1) {
                throw new RuntimeException('Queue row changed before failed-import retry could be approved.');
            }

            $this->pdo->commit();

            return [
                'id' => $id,
                'old_status' => 'IMPORT_ERROR',
                'new_status' => 'MOVED',
                'sha256' => $sha256,
            ];
        } catch (Throwable $exception) {
            if ($this->pdo->inTransaction()) {
                $this->pdo->rollBack();
            }

            throw $exception;
        }
    }

    private function queueRow(int $id): array|false
    {
        $query = $this->pdo->prepare(
            'SELECT file_name, local_sha256, status, imported_at FROM sharepoint_file_queue WHERE id = :id'
            . $this->sql->lockingSuffix('queue')
        );
        $query->execute([':id' => $id]);

        return $query->fetch(PDO::FETCH_ASSOC);
    }

    private function requireErroredImportFile(string $fileName, string $sha256): void
    {
        $query = $this->pdo->prepare(
            'SELECT status FROM import_files WHERE '
            . $this->sql->exactEquals('source_file_name', ':file_name')
            . ' AND ' . $this->sql->exactEquals('file_hash', ':sha256')
            . $this->sql->lockingSuffix('import_files')
        );
        $query->execute([':file_name' => $fileName, ':sha256' => $sha256]);

        $statuses = $query->fetchAll(PDO::FETCH_COLUMN);
        if (count($statuses) !== 1 || $statuses[0] !== 'ERROR') {
            throw new RuntimeException('No unique ERROR import record matches the failed queue row.');
        }
    }

    private function requireNoRows(string $sql, array $parameters, string $message): void
    {
        $query = $this->pdo->prepare($sql);
        $query->execute($parameters);

        if ($query->fetchColumn() !== false) {
            throw new RuntimeException($message);
        }
    }

}
