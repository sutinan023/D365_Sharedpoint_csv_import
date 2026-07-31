<?php
declare(strict_types=1);

use App\Config\EnvironmentGuard;
use App\Database\MigrationRunner;
use App\Database\BackupCheckpointValidator;
use Dotenv\Dotenv;

$options = getopt('', [
    'apply',
    'project:',
    'directory:',
    'release:',
    'applied-by:',
    'backup-manifest:',
    'restore-receipt:',
]);

foreach (['apply', 'project', 'directory', 'release', 'applied-by', 'backup-manifest', 'restore-receipt'] as $required) {
    if (!array_key_exists($required, $options) || $options[$required] === '') {
        fwrite(STDERR, "Missing required --{$required} option." . PHP_EOL);
        exit(2);
    }
}

$rootDir = dirname(__DIR__);
require $rootDir . '/vendor/autoload.php';
Dotenv::createImmutable($rootDir . '/config')->load();
$environment = EnvironmentGuard::validate($_ENV, $rootDir, true);

BackupCheckpointValidator::validate(
    (string)$options['backup-manifest'],
    (string)$options['restore-receipt'],
    $environment['DB_NAME'],
    (string)$options['release']
);

$pdo = new PDO(
    sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $environment['DB_HOST'], $environment['DB_NAME']),
    $environment['DB_USER'],
    $environment['DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
);
if (strcasecmp((string)$pdo->query('SELECT DATABASE()')->fetchColumn(), $environment['DB_NAME']) !== 0) {
    throw new RuntimeException('Connected database does not match validated configuration.');
}

$runner = new MigrationRunner($pdo);
$applied = $runner->applyDirectory(
    (string)$options['project'],
    (string)$options['directory'],
    (string)$options['release'],
    (string)$options['applied-by']
);

echo json_encode([
    'environment' => $environment['APP_ENV'],
    'database' => $environment['DB_NAME'],
    'release' => $options['release'],
    'applied' => $applied,
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
