<?php
declare(strict_types=1);

use App\Config\EnvironmentGuard;
use App\Import\FailedImportRetry;
use Dotenv\Dotenv;

$options = getopt('', ['apply', 'id:', 'file:', 'sha256:']);
foreach (['apply', 'id', 'file', 'sha256'] as $required) {
    if (!array_key_exists($required, $options) || $options[$required] === '') {
        fwrite(STDERR, "Missing required --{$required} option." . PHP_EOL);
        exit(2);
    }
}

if (filter_var($options['id'], FILTER_VALIDATE_INT, ['options' => ['min_range' => 1]]) === false
    || preg_match('/^[a-f0-9]{64}$/i', (string) $options['sha256']) !== 1) {
    fwrite(STDERR, 'Invalid retry identifier or SHA-256.' . PHP_EOL);
    exit(2);
}

try {
    $rootDir = dirname(__DIR__);
    require $rootDir . '/vendor/autoload.php';
    Dotenv::createImmutable($rootDir . '/config')->load();
    $environment = EnvironmentGuard::validate($_ENV, $rootDir, true);

    if ($environment['APP_ENV'] !== 'PRODUCTION' || $environment['DB_NAME'] !== 'D365_finance_prod') {
        throw new RuntimeException('Failed-import retry requires the Production finance database.');
    }

    $pdo = new PDO(
        sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $environment['DB_HOST'], $environment['DB_NAME']),
        $environment['DB_USER'],
        $environment['DB_PASS'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
    );

    if ($pdo->query('SELECT DATABASE()')->fetchColumn() !== 'D365_finance_prod') {
        throw new RuntimeException('Connected database is not the Production finance database.');
    }

    $result = (new FailedImportRetry($pdo))->retry(
        (int) $options['id'],
        (string) $options['file'],
        strtolower((string) $options['sha256'])
    );
    echo json_encode($result, JSON_UNESCAPED_SLASHES) . PHP_EOL;
} catch (Throwable) {
    fwrite(STDERR, 'Failed-import retry was not applied.' . PHP_EOL);
    exit(1);
}
