<?php

use App\Config\AppConfig;
use App\Config\EnvironmentGuard;
use App\Maintenance\DownloadCleanup;
use App\Queue\FileQueueRepository;
use App\Support\Logger;
use Dotenv\Dotenv;

require dirname(__DIR__) . '/vendor/autoload.php';

$rootDir = dirname(__DIR__);
Dotenv::createImmutable($rootDir . '/config')->safeLoad();
EnvironmentGuard::validate($_ENV, $rootDir, true);

$dryRun = !in_array('--run', $argv, true);
$retentionDays = max(1, (int) ($_ENV['DOWNLOAD_CLEANUP_RETENTION_DAYS'] ?? 30));

$config = AppConfig::fromEnv($rootDir);
$logger = new Logger($rootDir . '/logs/download_cleanup.log');

$pdo = new PDO(
    sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $_ENV['DB_HOST'], $_ENV['DB_NAME']),
    $_ENV['DB_USER'],
    $_ENV['DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);

$cleanup = new DownloadCleanup(new FileQueueRepository($pdo), $config, $logger, $retentionDays);
$result = $cleanup->run($dryRun);

echo ($dryRun ? 'DRY RUN' : 'RUN') . PHP_EOL;
echo 'Retention days: ' . $retentionDays . PHP_EOL;
echo 'Candidates: ' . $result['candidates'] . PHP_EOL;
echo 'Moved: ' . $result['moved'] . PHP_EOL;
echo 'Skipped: ' . $result['skipped'] . PHP_EOL;
