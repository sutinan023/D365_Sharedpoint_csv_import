<?php
declare(strict_types=1);

namespace App\Import;

use PDO;

final class SqliteFailedImportRetrySql implements FailedImportRetrySql
{
    public function begin(PDO $pdo): void
    {
        $pdo->beginTransaction();
    }

    public function exactEquals(string $column, string $parameter): string
    {
        return "CAST({$column} AS BLOB) = CAST({$parameter} AS BLOB)";
    }

    public function lockingSuffix(string $purpose): string
    {
        return '';
    }
}
