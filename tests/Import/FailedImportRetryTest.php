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
        $importFiles = $changes['import_files'] ?? [$importFile];
        foreach ($importFiles as $row) {
            $pdo->prepare('INSERT INTO import_files (source_file_name, file_hash, status)
                VALUES (:source_file_name, :file_hash, :status)')->execute($row);
        }
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
    $before = failedImportRetrySnapshot($pdo);

    try {
        (new FailedImportRetry($pdo))->retry($id, $fileName, $sha256);
    } catch (RuntimeException) {
        assert(failedImportRetrySnapshot($pdo) === $before);
        assert($pdo->inTransaction() === false);
        return;
    }

    throw new RuntimeException('Expected failed-import retry to be rejected');
}

function failedImportRetrySnapshot(PDO $pdo): array
{
    return [
        'queue' => $pdo->query('SELECT id, file_name, local_sha256, status, last_error, import_started_at, imported_at, updated_at FROM sharepoint_file_queue ORDER BY id')->fetchAll(PDO::FETCH_ASSOC),
        'import_files' => $pdo->query('SELECT source_file_name, file_hash, status FROM import_files ORDER BY rowid')->fetchAll(PDO::FETCH_ASSOC),
        'business' => $pdo->query('SELECT source_file_name, file_hash FROM payment_before_post ORDER BY rowid')->fetchAll(PDO::FETCH_ASSOC),
        'staging' => $pdo->query('SELECT source_file_name, file_hash FROM stg_payment_before_post ORDER BY rowid')->fetchAll(PDO::FETCH_ASSOC),
        'history' => $pdo->query('SELECT source_file_name FROM payment_before_post_history ORDER BY rowid')->fetchAll(PDO::FETCH_ASSOC),
    ];
}

function runFailedImportRetryCli(array $arguments): array
{
    $command = escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(dirname(__DIR__, 2) . '/tools/retry_failed_import.php');
    foreach ($arguments as $argument) {
        $command .= ' ' . escapeshellarg($argument);
    }
    $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException('Unable to start failed-import retry CLI test.');
    }

    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);

    return ['exit' => proc_close($process), 'stdout' => $stdout, 'stderr' => $stderr];
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
            'matching import_files has duplicate ERROR rows' => [['import_files' => [
                ['source_file_name' => $failedImportRetryFileName, 'file_hash' => $failedImportRetryHash, 'status' => 'ERROR'],
                ['source_file_name' => $failedImportRetryFileName, 'file_hash' => $failedImportRetryHash, 'status' => 'ERROR'],
            ]], 44, $failedImportRetryFileName, $failedImportRetryHash],
            'matching business row exists' => [['business_rows' => [[$failedImportRetryFileName, $failedImportRetryHash]]], 44, $failedImportRetryFileName, $failedImportRetryHash],
            'matching staging row exists' => [['staging_rows' => [[$failedImportRetryFileName, $failedImportRetryHash]]], 44, $failedImportRetryFileName, $failedImportRetryHash],
            'matching history row exists' => [['history_rows' => [$failedImportRetryFileName]], 44, $failedImportRetryFileName, $failedImportRetryHash],
        ];

        foreach ($cases as [$fixtureChanges, $id, $fileName, $sha256]) {
            assertFailedImportRetryRejected(failedImportRetryFixture($fixtureChanges), $id, $fileName, $sha256);
        }
    },
    'failed import retry treats SQLite case variants as distinct evidence' => function () use ($failedImportRetryFileName, $failedImportRetryHash): void {
        $differentCaseName = strtolower($failedImportRetryFileName);
        $differentCaseHash = strtoupper($failedImportRetryHash);
        $businessFixture = failedImportRetryFixture([
            'business_rows' => [[$differentCaseName, $differentCaseHash]],
        ]);

        (new FailedImportRetry($businessFixture))->retry(44, $failedImportRetryFileName, $failedImportRetryHash);
        assert($businessFixture->query('SELECT status FROM sharepoint_file_queue WHERE id = 44')->fetchColumn() === 'MOVED');

        $importFixture = failedImportRetryFixture([
            'import_file' => false,
            'import_files' => [[
                'source_file_name' => $differentCaseName,
                'file_hash' => $differentCaseHash,
                'status' => 'ERROR',
            ]],
        ]);
        assertFailedImportRetryRejected($importFixture, 44, $failedImportRetryFileName, $failedImportRetryHash);
    },
    'failed import retry has a MySQL serialization and binary-comparison contract for every predicate' => function (): void {
        $source = file_get_contents(dirname(__DIR__, 2) . '/src/Import/FailedImportRetry.php');

        assert(str_contains($source, "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"));
        assert(str_contains($source, "return \$this->isMySql() ? ' FOR UPDATE' : '';"));
        assert(substr_count($source, '$this->lockingSuffix()') === 5);
        assert(str_contains($source, 'return "BINARY {$column} = BINARY {$parameter}";'));
        assert(substr_count($source, 'exactEquals(') === 11);
    },
    'failed import retry CLI rejects missing and invalid options before loading configuration' => function (): void {
        $missing = runFailedImportRetryCli([]);
        assert($missing === ['exit' => 2, 'stdout' => '', 'stderr' => "Missing required --apply option." . PHP_EOL]);

        $invalid = runFailedImportRetryCli(['--apply', '--id=0', '--file=retry.csv', '--sha256=not-a-hash']);
        assert($invalid === ['exit' => 2, 'stdout' => '', 'stderr' => 'Invalid retry identifier or SHA-256.' . PHP_EOL]);
    },
    'failed import retry CLI fails closed with a generic error before the service on this non-Production checkout' => function () use ($failedImportRetryHash): void {
        $result = runFailedImportRetryCli([
            '--apply', '--id=44', '--file=retry.csv', '--sha256=' . $failedImportRetryHash,
        ]);
        $source = file_get_contents(dirname(__DIR__, 2) . '/tools/retry_failed_import.php');

        assert($result === ['exit' => 1, 'stdout' => '', 'stderr' => 'Failed-import retry was not applied.' . PHP_EOL]);
        assert(strpos($source, 'EnvironmentGuard::validate') < strpos($source, 'new FailedImportRetry'));
        assert(str_contains($source, "\$environment['APP_ENV'] !== 'PRODUCTION'"));
        assert(str_contains($source, "\$environment['DB_NAME'] !== 'D365_finance_prod'"));
        assert(str_contains($source, "SELECT DATABASE()"));
        assert(!str_contains($source, 'catch (Throwable $'));
    },
];
