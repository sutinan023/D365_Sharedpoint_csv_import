<?php
declare(strict_types=1);

namespace App\Import;

use PDO;

final class MysqlFailedImportRetrySql implements FailedImportRetrySql
{
    public function begin(PDO $pdo): void
    {
        $pdo->exec('SET TRANSACTION ISOLATION LEVEL SERIALIZABLE');
        $pdo->beginTransaction();
    }

    public function exactEquals(string $column, string $parameter): string
    {
        return "BINARY {$column} = BINARY {$parameter}";
    }

    public function lockingSuffix(string $purpose): string
    {
        return ' FOR UPDATE';
    }
}
