<?php
declare(strict_types=1);

use App\Config\EnvironmentGuard;
use App\Database\RehearsalVerifier;
use Dotenv\Dotenv;

$options = getopt('', ['database:', 'checkpoint:', 'sanitizer-audit:']);
foreach (['database', 'checkpoint', 'sanitizer-audit'] as $required) {
    if (!isset($options[$required]) || trim((string)$options[$required]) === '') {
        throw new RuntimeException("Missing required --{$required} option.");
    }
}

$rootDir = dirname(__DIR__);
require $rootDir . '/vendor/autoload.php';
Dotenv::createImmutable($rootDir . '/config')->load();
$environment = EnvironmentGuard::validate($_ENV, $rootDir, true);
$environment = EnvironmentGuard::validateRehearsal($environment);
$database = (string)$options['database'];

$readJson = static function (string $path, string $label): array {
    $bytes = file_get_contents($path);
    if ($bytes === false || !preg_match('//u', $bytes)) {
        throw new RuntimeException("{$label} cannot be read as UTF-8 JSON.");
    }
    $value = json_decode(ltrim($bytes, "\xEF\xBB\xBF"), true, 64, JSON_THROW_ON_ERROR);
    if (!is_array($value) || array_is_list($value)) {
        throw new RuntimeException("{$label} must be a JSON object.");
    }
    return ['value' => $value, 'hash' => hash('sha256', $bytes), 'path' => realpath($path) ?: $path];
};

$checkpoint = $readJson((string)$options['checkpoint'], 'Checkpoint manifest');
$audit = $readJson((string)$options['sanitizer-audit'], 'Sanitizer audit');
$manifest = $checkpoint['value'];
$auditValue = $audit['value'];
if (($manifest['database'] ?? null) !== 'D365_finance_prod'
    || ($auditValue['source_database'] ?? null) !== 'D365_finance_prod'
    || ($auditValue['rehearsal_database'] ?? null) !== $database
    || !isset($manifest['verification_baseline']) || !is_array($manifest['verification_baseline'])) {
    throw new RuntimeException('Checkpoint or sanitizer audit does not bind this rehearsal database.');
}
$backupBytes = file_get_contents((string)($manifest['backup_file'] ?? ''));
$sanitizedBytes = file_get_contents((string)($auditValue['sanitized_path'] ?? ''));
if ($backupBytes === false || $sanitizedBytes === false
    || !hash_equals(strtolower((string)($manifest['sha256'] ?? '')), hash('sha256', $backupBytes))
    || !hash_equals(strtolower((string)($auditValue['sanitized_sha256'] ?? '')), hash('sha256', $sanitizedBytes))) {
    throw new RuntimeException('Checkpoint or sanitized backup hash does not match.');
}

$pdo = new PDO(
    sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $environment['REHEARSAL_DB_HOST'], $database),
    $environment['REHEARSAL_DB_USER'],
    $environment['REHEARSAL_DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
);
$grantRows = $pdo->query('SHOW GRANTS FOR CURRENT_USER()')->fetchAll(PDO::FETCH_NUM);
$grants = array_map(static fn (array $row): string => (string)$row[0], $grantRows);
RehearsalVerifier::assertReadOnlyGrants($grants, $database);
$result = (new RehearsalVerifier($pdo))->verify($database, $manifest['verification_baseline']);
$result['release_id'] = (string)$manifest['release_id'];
$result['backup_sha256'] = strtolower((string)$manifest['sha256']);
$result['sanitized_sha256'] = strtolower((string)$auditValue['sanitized_sha256']);
$result['verified_at'] = gmdate('c');
$result['verified_by'] = get_current_user();

echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . PHP_EOL;
