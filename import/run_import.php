<?php

error_reporting(E_ALL);
ini_set('display_errors', 1);

$pipeline = __DIR__ . '/run_pipeline.php';
if (is_file($pipeline)) {
    require $pipeline;
    return;
}

require __DIR__ . '/../vendor/autoload.php';

use App\Import\PaymentBeforePostImporter;
use Dotenv\Dotenv;

$dotenv = Dotenv::createImmutable(__DIR__ . '/../config');
$dotenv->load();

echo "=========================\n";
echo "START IMPORT\n";
echo "=========================\n";

require __DIR__ . '/download_csv.php';

$downloadDir = __DIR__ . '/../download';
$files = glob($downloadDir . '/*.csv');
if (!$files) {
    die("NO CSV FILE FOUND\n");
}
usort($files, static fn (string $left, string $right): int => filemtime($right) <=> filemtime($left));
$filePath = $files[0];
$fileName = basename($filePath);
$fileHash = hash_file('sha256', $filePath);

echo "LATEST FILE: {$fileName}\n";
echo "FILE HASH: {$fileHash}\n";

$pdo = new PDO(
    "mysql:host={$_ENV['DB_HOST']};dbname={$_ENV['DB_NAME']};charset=utf8mb4",
    $_ENV['DB_USER'],
    $_ENV['DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION],
);
echo "DB CONNECTED\n";

$importer = new PaymentBeforePostImporter($pdo, __DIR__ . '/../archive');
if ($fileHash !== false && $importer->isDuplicateHash($fileHash)) {
    echo "THIS FILE HASH ALREADY IMPORTED - SKIPPED\n";
    exit(0);
}

try {
    $importer->importFile($filePath);
} catch (Throwable $exception) {
    die('IMPORT ERROR: ' . $exception->getMessage() . "\n");
}

echo "=========================\n";
echo "FINISH IMPORT\n";
echo "=========================\n";
