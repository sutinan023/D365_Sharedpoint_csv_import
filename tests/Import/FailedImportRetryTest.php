<?php

use App\Import\FailedImportRetry;

function failedImportRetryFixture(array $changes = []): PDO
{
    $pdo = new PDO('sqlite::memory:');
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->exec('CREATE TABLE sharepoint_file_queue (
        id INTEGER PRIMARY KEY, file_name TEXT, local_sha256 TEXT, status TEXT,
        last_error TEXT, import_started_at TEXT, imported_at TEXT, updated_at TEXT
    )');
    $pdo->exec('CREATE TABLE import_files (source_file_name TEXT, file_hash TEXT, status TEXT)');
    $pdo->exec('CREATE TABLE payment_before_post (source_file_name TEXT, file_hash TEXT)');
    $pdo->exec('CREATE TABLE stg_payment_before_post (source_file_name TEXT, file_hash TEXT)');
    $pdo->exec('CREATE TABLE payment_before_post_history (source_file_name TEXT)');

    $queue = array_replace([
        'id' => 44,
        'file_name' => 'PaymentBeforePost_20260803.csv',
        'local_sha256' => '3605a718e95097fe1c90e3d7892a20d23f5b7b3d8c48050e92be7ff146039cd8',
        'status' => 'IMPORT_ERROR',
        'last_error' => 'staging invoice number rejected',
        'import_started_at' => '2026-08-03 10:00:00',
        'imported_at' => null,
    ], $changes['queue'] ?? []);
    $pdo->prepare('INSERT INTO sharepoint_file_queue (
        id, file_name, local_sha256, status, last_error, import_started_at, imported_at
    ) VALUES (:id, :file_name, :local_sha256, :status, :last_error, :import_started_at, :imported_at)')->execute($queue);

    if (($changes['import_file'] ?? true) !== false) {
        $importFile = array_replace([
            'source_file_name' => $queue['file_name'],
            'file_hash' => $queue['local_sha256'],
            'status' => 'ERROR',
        ], is_array($changes['import_file'] ?? null) ? $changes['import_file'] : []);
        $pdo->prepare('INSERT INTO import_files (source_file_name, file_hash, status)
            VALUES (:source_file_name, :file_hash, :status)')->execute($importFile);
    }

    foreach (($changes['business_rows'] ?? []) as $row) {
        $pdo->prepare('INSERT INTO payment_before_post (source_file_name, file_hash) VALUES (?, ?)')
            ->execute($row);
    }
    foreach (($changes['staging_rows'] ?? []) as $row) {
        $pdo->prepare('INSERT INTO stg_payment_before_post (source_file_name, file_hash) VALUES (?, ?)')
            ->execute($row);
    }
    foreach (($changes['history_rows'] ?? []) as $row) {
        $pdo->prepare('INSERT INTO payment_before_post_history (source_file_name) VALUES (?)')->execute([$row]);
    }

    return $pdo;
}

function assertFailedImportRetryRejected(PDO $pdo, int $id, string $fileName, string $sha256): void
{
    $originalStatus = $pdo->query('SELECT status FROM sharepoint_file_queue WHERE id = 44')->fetchColumn();

    try {
        (new FailedImportRetry($pdo))->retry($id, $fileName, $sha256);
    } catch (RuntimeException) {
        assert($pdo->query('SELECT status FROM sharepoint_file_queue WHERE id = 44')->fetchColumn() === $originalStatus);
        return;
    }

    throw new RuntimeException('Expected failed-import retry to be rejected');
}

$failedImportRetryFileName = 'PaymentBeforePost_20260803.csv';
$failedImportRetryHash = '3605a718e95097fe1c90e3d7892a20d23f5b7b3d8c48050e92be7ff146039cd8';

return [
    'failed import retry returns a guarded IMPORT_ERROR to MOVED transition' => function () use ($failedImportRetryFileName, $failedImportRetryHash): void {
        $pdo = failedImportRetryFixture();

        $result = (new FailedImportRetry($pdo))->retry(44, $failedImportRetryFileName, $failedImportRetryHash);

        assert($result === [
            'id' => 44,
            'old_status' => 'IMPORT_ERROR',
            'new_status' => 'MOVED',
            'sha256' => '3605a718e95097fe1c90e3d7892a20d23f5b7b3d8c48050e92be7ff146039cd8',
        ]);
        assert($pdo->query('SELECT status FROM sharepoint_file_queue WHERE id = 44')->fetchColumn() === 'MOVED');
        assert($pdo->query('SELECT last_error FROM sharepoint_file_queue WHERE id = 44')->fetchColumn() === null);
        assert($pdo->query('SELECT import_started_at FROM sharepoint_file_queue WHERE id = 44')->fetchColumn() === null);
    },
    'failed import retry rejects every mismatched or unsafe retry condition without moving the queue row' => function () use ($failedImportRetryFileName, $failedImportRetryHash): void {
        $cases = [
            'different requested id' => [[], 45, $failedImportRetryFileName, $failedImportRetryHash],
            'different requested file name' => [[], 44, 'other.csv', $failedImportRetryHash],
            'different requested SHA-256' => [[], 44, $failedImportRetryFileName, str_repeat('a', 64)],
            'queue is not IMPORT_ERROR' => [['queue' => ['status' => 'MOVED']], 44, $failedImportRetryFileName, $failedImportRetryHash],
            'queue was already imported' => [['queue' => ['imported_at' => '2026-08-03 11:00:00']], 44, $failedImportRetryFileName, $failedImportRetryHash],
            'matching import_files row is missing' => [['import_file' => false], 44, $failedImportRetryFileName, $failedImportRetryHash],
            'matching import_files row is not ERROR' => [['import_file' => ['status' => 'SUCCESS']], 44, $failedImportRetryFileName, $failedImportRetryHash],
            'matching business row exists' => [['business_rows' => [[$failedImportRetryFileName, $failedImportRetryHash]]], 44, $failedImportRetryFileName, $failedImportRetryHash],
            'matching staging row exists' => [['staging_rows' => [[$failedImportRetryFileName, $failedImportRetryHash]]], 44, $failedImportRetryFileName, $failedImportRetryHash],
            'matching history row exists' => [['history_rows' => [$failedImportRetryFileName]], 44, $failedImportRetryFileName, $failedImportRetryHash],
        ];

        foreach ($cases as [$fixtureChanges, $id, $fileName, $sha256]) {
            assertFailedImportRetryRejected(failedImportRetryFixture($fixtureChanges), $id, $fileName, $sha256);
        }
    },
];
