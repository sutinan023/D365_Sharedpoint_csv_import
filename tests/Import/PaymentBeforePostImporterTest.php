<?php

use App\Import\PaymentBeforePostImporter;

function createImporterTestPdo(): PDO
{
    $pdo = new PDO('sqlite::memory:');
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->exec('CREATE TABLE import_files (
        source_file_name TEXT,
        file_type TEXT,
        local_file_name TEXT,
        file_hash TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        total_rows INTEGER NOT NULL,
        message TEXT NOT NULL,
        imported_at TEXT
    )');
    $pdo->exec('CREATE TABLE stg_payment_before_post (
        source_file_name TEXT, file_hash TEXT, import_export_reference TEXT, company TEXT,
        bank_account_code TEXT, transaction_date TEXT, cashflow TEXT, journal_batch TEXT,
        voucher_number TEXT, description TEXT, vendor_account TEXT, vendor_name TEXT,
        email_address TEXT, purchase_order TEXT, invoice_number TEXT,
        vendor_bank_account_code TEXT, vendor_bank_account_number TEXT,
        bank_transaction_type TEXT, method_of_payment TEXT, invoice_amount TEXT,
        currency TEXT, exchange_rate TEXT, fee TEXT, withholding_tax_amount TEXT,
        total_amount TEXT, workflow_approval_status TEXT, comment TEXT
    )');

    return $pdo;
}

function createImporterTestDirectory(): string
{
    $directory = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'payment-importer-' . bin2hex(random_bytes(6));
    mkdir($directory);

    return $directory;
}

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
    'importer archives an imported CSV and records SUCCESS after the move' => function (): void {
        $directory = createImporterTestDirectory();
        $archiveDirectory = $directory . DIRECTORY_SEPARATOR . 'archive';
        $filePath = $directory . DIRECTORY_SEPARATOR . 'payment.csv';
        file_put_contents($filePath, "company\n");

        try {
            $pdo = createImporterTestPdo();
            $importer = new PaymentBeforePostImporter($pdo, $archiveDirectory);

            $archivePath = $importer->importFile($filePath);

            assert(!is_file($filePath));
            assert(is_file($archivePath));
            assert(file_get_contents($archivePath) === "company\n");
            assert($pdo->query('SELECT status FROM import_files')->fetchColumn() === 'SUCCESS');
        } finally {
            foreach (glob($archiveDirectory . DIRECTORY_SEPARATOR . '*') ?: [] as $archivedFile) {
                unlink($archivedFile);
            }
            if (is_dir($archiveDirectory)) {
                rmdir($archiveDirectory);
            }
            if (is_file($filePath)) {
                unlink($filePath);
            }
            rmdir($directory);
        }
    },
    'importer preserves local CSV and records pending archive status when move fails' => function (): void {
        $directory = createImporterTestDirectory();
        $archiveDirectory = $directory . DIRECTORY_SEPARATOR . 'archive';
        $filePath = $directory . DIRECTORY_SEPARATOR . 'payment.csv';
        file_put_contents($filePath, "company\n");

        try {
            $pdo = createImporterTestPdo();
            $importer = new PaymentBeforePostImporter(
                $pdo,
                $archiveDirectory,
                static fn (string $source, string $destination): bool => false,
            );

            try {
                $importer->importFile($filePath);
                assert(false, 'Expected archival failure');
            } catch (RuntimeException $exception) {
                assert(str_contains($exception->getMessage(), 'Unable to archive CSV file'));
            }

            assert(is_file($filePath));
            assert($pdo->query('SELECT status FROM import_files')->fetchColumn() === 'PENDING_ARCHIVE');
            assert($importer->isDuplicateHash(hash_file('sha256', $filePath)) === false);
        } finally {
            if (is_dir($archiveDirectory)) {
                rmdir($archiveDirectory);
            }
            if (is_file($filePath)) {
                unlink($filePath);
            }
            rmdir($directory);
        }
    },
];
