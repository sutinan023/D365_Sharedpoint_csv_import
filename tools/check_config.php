<?php
declare(strict_types=1);

use App\Config\EnvironmentGuard;
use Dotenv\Dotenv;

$rootDir = dirname(__DIR__);
require $rootDir . '/vendor/autoload.php';
Dotenv::createImmutable($rootDir . '/config')->load();
$environment = EnvironmentGuard::validate($_ENV, $rootDir, true);

echo json_encode([
    'status' => 'OK',
    'app_env' => $environment['APP_ENV'],
    'app_release' => $environment['APP_RELEASE'],
    'app_base_url' => $environment['APP_BASE_URL'],
    'db_host' => $environment['DB_HOST'],
    'db_name' => $environment['DB_NAME'],
    'sharepoint_source' => $environment['CSV_FOLDER'],
    'sharepoint_processed' => $environment['CSV_DOWNLOADED_FOLDER'],
    'root_dir' => $rootDir,
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
