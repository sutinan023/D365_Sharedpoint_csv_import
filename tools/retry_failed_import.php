<?php
declare(strict_types=1);

use App\Config\EnvironmentGuard;
use App\Import\FailedImportRetry;
use App\Import\FailedImportRetryCli;
use Dotenv\Dotenv;

$rootDir = dirname(__DIR__);
require $rootDir . '/vendor/autoload.php';
$options = getopt('', ['apply', 'id:', 'file:', 'sha256:']);
$result = (new FailedImportRetryCli())->run(
    $options,
    static function () use ($rootDir): array {
        Dotenv::createImmutable($rootDir . '/config')->load();

        return EnvironmentGuard::validate($_ENV, $rootDir, true);
    },
    static function (array $environment): PDO {
        return new PDO(
            sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $environment['DB_HOST'], $environment['DB_NAME']),
            $environment['DB_USER'],
            $environment['DB_PASS'],
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
        );
    },
    static function (object $connection, int $id, string $fileName, string $sha256): array {
        if (!$connection instanceof PDO) {
            throw new RuntimeException('Retry connection is invalid.');
        }

        return (new FailedImportRetry($connection))->retry($id, $fileName, $sha256);
    }
);
fwrite(STDOUT, $result['stdout']);
fwrite(STDERR, $result['stderr']);
exit($result['exit']);
