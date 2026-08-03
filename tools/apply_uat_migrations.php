<?php
declare(strict_types=1);

use App\Config\EnvironmentGuard;
use App\Database\MigrationRunner;
use Dotenv\Dotenv;

$options = getopt('', [
    'apply',
    'project:',
    'directory:',
    'release:',
    'applied-by:',
]);

foreach (['apply', 'project', 'directory', 'release', 'applied-by'] as $required) {
    if (!array_key_exists($required, $options) || $options[$required] === '') {
        fwrite(STDERR, "Missing required --{$required} option." . PHP_EOL);
        exit(2);
    }
}

$rootDir = dirname(__DIR__);
require $rootDir . '/vendor/autoload.php';
Dotenv::createImmutable($rootDir . '/config')->load();
$environment = EnvironmentGuard::validate($_ENV, $rootDir, true);

if ($environment['APP_ENV'] !== 'UAT') {
    throw new RuntimeException('UAT migrations require APP_ENV=UAT.');
}

if ($environment['DB_NAME'] !== 'D365_finance') {
    throw new RuntimeException('UAT migrations require DB_NAME=D365_finance.');
}

foreach (['MIGRATION_DB_USER', 'MIGRATION_DB_PASS'] as $key) {
    if (trim((string) ($environment[$key] ?? '')) === '') {
        throw new RuntimeException("{$key} is required for database migrations.");
    }
}

$pdo = new PDO(
    sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $environment['DB_HOST'], $environment['DB_NAME']),
    $environment['MIGRATION_DB_USER'],
    $environment['MIGRATION_DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
);

if (strcasecmp((string) $pdo->query('SELECT DATABASE()')->fetchColumn(), 'D365_finance') !== 0) {
    throw new RuntimeException('Connected database is not the UAT finance database.');
}

$applied = (new MigrationRunner($pdo))->applyDirectory(
    (string) $options['project'],
    (string) $options['directory'],
    (string) $options['release'],
    (string) $options['applied-by'],
);

echo json_encode([
    'environment' => $environment['APP_ENV'],
    'database' => $environment['DB_NAME'],
    'release' => $options['release'],
    'applied' => $applied,
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
