<?php

use App\Import\PaymentBeforePostImporter;

return [
    'importer detects duplicate hash from import_files' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('CREATE TABLE import_files (file_hash TEXT NOT NULL, status TEXT NOT NULL)');
        $pdo->exec("INSERT INTO import_files (file_hash, status) VALUES ('abc', 'SUCCESS')");

        $importer = new PaymentBeforePostImporter($pdo, sys_get_temp_dir());

        assert($importer->isDuplicateHash('abc') === true);
        assert($importer->isDuplicateHash('def') === false);
    },
];
