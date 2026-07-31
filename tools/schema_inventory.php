<?php
declare(strict_types=1);

use App\Config\EnvironmentGuard;
use App\Database\SchemaInventory;
use Dotenv\Dotenv;

$rootDir = dirname(__DIR__);
require $rootDir . '/vendor/autoload.php';
Dotenv::createImmutable($rootDir . '/config')->load();
$environment = EnvironmentGuard::validate($_ENV, $rootDir, true);

$pdo = new PDO(
    sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $environment['DB_HOST'], $environment['DB_NAME']),
    $environment['DB_USER'],
    $environment['DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);

$inventory = (new SchemaInventory($pdo))->collect($environment['DB_NAME']);
echo json_encode($inventory, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . PHP_EOL;
