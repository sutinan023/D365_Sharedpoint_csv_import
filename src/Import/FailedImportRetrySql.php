<?php
declare(strict_types=1);

namespace App\Import;

use PDO;

interface FailedImportRetrySql
{
    public function begin(PDO $pdo): void;

    public function exactEquals(string $column, string $parameter): string;

    public function lockingSuffix(string $purpose): string;
}
