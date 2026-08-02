<?php
declare(strict_types=1);

use App\Config\EnvironmentGuard;
use App\Database\CheckpointBaseline;
use Dotenv\Dotenv;

$rootDir = dirname(__DIR__);
require $rootDir . '/vendor/autoload.php';
Dotenv::createImmutable($rootDir . '/config')->load();
$environment = EnvironmentGuard::validate($_ENV, $rootDir, true);
if ($environment['APP_ENV'] !== 'PRODUCTION' || $environment['DB_NAME'] !== 'D365_finance_prod') {
    throw new RuntimeException('Checkpoint baseline requires Production configuration.');
}
foreach (['BACKUP_DB_USER', 'BACKUP_DB_PASS'] as $key) {
    if (trim((string)($environment[$key] ?? '')) === '') {
        throw new RuntimeException("{$key} is required for checkpoint baseline.");
    }
}

$pdo = new PDO(
    sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $environment['DB_HOST'], $environment['DB_NAME']),
    $environment['BACKUP_DB_USER'],
    $environment['BACKUP_DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
);
if (strcasecmp((string)$pdo->query('SELECT DATABASE()')->fetchColumn(), 'D365_finance_prod') !== 0) {
    throw new RuntimeException('Checkpoint baseline connected to the wrong database.');
}

echo json_encode(
    (new CheckpointBaseline($pdo))->capture('D365_finance_prod'),
    JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
) . PHP_EOL;
