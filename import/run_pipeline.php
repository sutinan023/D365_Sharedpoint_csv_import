<?php

use App\Config\AppConfig;
use App\Import\ImportQueue;
use App\Import\PaymentBeforePostImporter;
use App\Queue\FileQueueRepository;
use App\SharePoint\DownloadQueue;
use App\SharePoint\SharePointClient;
use App\Support\Logger;
use App\Support\PipelineLock;
use Dotenv\Dotenv;

require dirname(__DIR__) . '/vendor/autoload.php';

$rootDir = dirname(__DIR__);
$dotenv = Dotenv::createImmutable($rootDir . '/config');
$dotenv->safeLoad();

$config = AppConfig::fromEnv($rootDir);
$logger = new Logger($rootDir . '/logs/import.log');

$pdo = new PDO(
    sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $_ENV['DB_HOST'], $_ENV['DB_NAME']),
    $_ENV['DB_USER'],
    $_ENV['DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);

$lock = new PipelineLock($config->lockFile);

$lock->run(function () use ($config, $logger, $pdo): void {
    $logger->info('Pipeline started');

    $repo = new FileQueueRepository($pdo);
    $client = SharePointClient::fromEnv($_ENV);
    $downloadQueue = new DownloadQueue($client, $repo, $config);
    $importer = new PaymentBeforePostImporter($pdo, $config->archiveDir);
    $importQueue = new ImportQueue($repo, $importer);

    $downloadQueue->run();
    $importQueue->run();

    $logger->info('Pipeline finished');
});
