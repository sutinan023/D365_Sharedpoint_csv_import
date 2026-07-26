<?php

use App\Config\AppConfig;
use App\Maintenance\DownloadCleanup;
use App\Queue\FileQueueRepository;
use App\Support\Logger;

return [
    'download cleanup dry run does not move files' => function (): void {
        [$root, , $repo, $file] = cleanupFixture('SKIPPED_DUPLICATE', '2020-01-01 00:00:00');
        $config = cleanupConfig($root);
        $cleanup = new DownloadCleanup($repo, $config, new Logger($root . '/logs/test.log'), 30);

        $result = $cleanup->run(true);

        assert($result['candidates'] === 1);
        assert($result['moved'] === 0);
        assert($result['skipped'] === 0);
        assert(is_file($file));
    },
    'download cleanup moves old duplicate csv to dated cleanup archive' => function (): void {
        [$root, , $repo, $file] = cleanupFixture('SKIPPED_DUPLICATE', '2020-01-01 00:00:00');
        $config = cleanupConfig($root);
        $cleanup = new DownloadCleanup($repo, $config, new Logger($root . '/logs/test.log'), 30);

        $result = $cleanup->run(false);
        $row = $repo->findByItemId('cleanup-item');

        assert($result['candidates'] === 1);
        assert($result['moved'] === 1);
        assert($result['skipped'] === 0);
        assert(!file_exists($file));
        assert(str_contains(str_replace('\\', '/', $row['local_path']), '/archive/download-cleanup/'));
        assert(is_file($row['local_path']));
    },
    'download cleanup skips active queue files' => function (): void {
        [$root, , $repo, $file] = cleanupFixture('MOVED', '2020-01-01 00:00:00');
        $config = cleanupConfig($root);
        $cleanup = new DownloadCleanup($repo, $config, new Logger($root . '/logs/test.log'), 30);

        $result = $cleanup->run(false);

        assert($result['candidates'] === 0);
        assert($result['moved'] === 0);
        assert(is_file($file));
    },
];

function cleanupConfig(string $root): AppConfig
{
    return new AppConfig(
        $root,
        'src',
        'done',
        $root . '/download',
        $root . '/archive',
        $root . '/error',
        3,
        $root . '/temp/pipeline.lock'
    );
}

function cleanupFixture(string $status, string $date): array
{
    $root = sys_get_temp_dir() . '/download-cleanup-' . bin2hex(random_bytes(4));
    mkdir($root . '/download', 0777, true);
    mkdir($root . '/archive', 0777, true);
    mkdir($root . '/logs', 0777, true);

    $file = $root . '/download/payment.csv';
    file_put_contents($file, "company\nSHF\n");

    $pdo = new PDO('sqlite::memory:');
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $migration = str_replace(
        ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
        ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', 'DEFAULT CURRENT_TIMESTAMP'],
        file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
    );
    $pdo->exec(preg_replace('/,\s*\);\s*$/', "\n);", $migration));

    $stmt = $pdo->prepare("INSERT INTO sharepoint_file_queue
        (item_id, source_folder, processed_folder, file_name, local_path, status, imported_at, created_at, updated_at)
        VALUES ('cleanup-item', 'src', 'done', 'payment.csv', :path, :status, :date, :date, :date)");
    $stmt->execute([':path' => $file, ':status' => $status, ':date' => $date]);

    return [$root, $pdo, new FileQueueRepository($pdo), $file];
}
