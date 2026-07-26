# Monthly Download Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe monthly maintenance job that clears old terminal CSV files out of `download\` without deleting files needed for recovery or active imports.

**Architecture:** Add a small cleanup service that reads `sharepoint_file_queue`, identifies only safe terminal files in the local download directory, and moves them to a dated cleanup archive folder by default. A CLI script runs the service with dry-run support, and a Windows batch file can be scheduled monthly.

**Tech Stack:** PHP 8, PDO MySQL/MariaDB, Composer autoload, Windows Task Scheduler, existing `App\Config\AppConfig`, `App\Queue\FileQueueRepository`, and `App\Support\Logger`.

## Global Constraints

- Do not permanently delete files by default; move them out of `download\` to `archive\download-cleanup\YYYY-MM\`.
- Never touch files whose queue status may still be needed for recovery: `DISCOVERED`, `DOWNLOADING`, `DOWNLOADED`, `MOVING`, `MOVED`, `IMPORTING`, `ERROR`, `IMPORT_ERROR`, `RECOVERY_ERROR`, `RECOVERY_DOWNLOADING`.
- Only clean files inside configured `CSV_LOCAL_DOWNLOAD_DIR`.
- Only clean `.csv` files.
- Default retention is 30 days, configurable via `DOWNLOAD_CLEANUP_RETENTION_DAYS`.
- Cleanup must support dry-run mode before real move.
- Cleanup must log every moved/skipped file without exposing secrets.
- Existing operational import entrypoint remains `import/run_pipeline.php`; cleanup is a separate monthly maintenance entrypoint.

---

## File Structure

- Create `src/Maintenance/DownloadCleanup.php`
  - Owns cleanup rules and file moves.
  - Consumes `FileQueueRepository`, `AppConfig`, and `Logger`.
  - Produces a result summary with moved/skipped counts.
- Modify `src/Queue/FileQueueRepository.php`
  - Add query methods for terminal local download rows and for updating `local_path` after cleanup move.
- Create `maintenance/cleanup_download.php`
  - CLI entrypoint for dry-run and real cleanup.
  - Loads `.env`, creates PDO, config, logger, repository, and cleanup service.
- Create `run_download_cleanup.bat`
  - Batch wrapper for Windows Task Scheduler.
- Modify `config/.env.example`
  - Add cleanup config defaults.
- Add `tests/Maintenance/DownloadCleanupTest.php`
  - Unit tests for safe/unsafe cleanup behavior.
- Modify `tests/run.php`
  - Include the new maintenance test file.
- Modify `Readme.txt`
  - Document monthly cleanup flow and scheduler command.

---

### Task 1: Repository Support for Cleanup

**Files:**
- Modify: `src/Queue/FileQueueRepository.php`
- Test: `tests/Queue/FileQueueRepositoryTest.php`

**Interfaces:**
- Produces: `findTerminalRowsInDownload(string $downloadDir, int $olderThanDays): array`
- Produces: `updateLocalPath(int $id, string $localPath): void`
- Consumes: existing PDO connection and `sharepoint_file_queue`

- [ ] **Step 1: Write failing repository tests**

Add these tests to `tests/Queue/FileQueueRepositoryTest.php`:

```php
'repository finds only terminal rows in download for cleanup' => function (): void {
    $pdo = new PDO('sqlite::memory:');
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $migration = str_replace(
        ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
        ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', 'DEFAULT CURRENT_TIMESTAMP'],
        file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
    );
    $pdo->exec(preg_replace('/,\s*\);\s*$/', "\n);", $migration));
    $repo = new FileQueueRepository($pdo);

    $downloadDir = str_replace('\\', '/', sys_get_temp_dir()) . '/download-cleanup-test';
    $oldDate = (new DateTimeImmutable('-45 days'))->format('Y-m-d H:i:s');
    $newDate = (new DateTimeImmutable('-5 days'))->format('Y-m-d H:i:s');

    $pdo->exec("INSERT INTO sharepoint_file_queue
        (item_id, source_folder, processed_folder, file_name, local_path, status, imported_at, created_at, updated_at)
        VALUES
        ('terminal-old', 'src', 'done', 'old.csv', '{$downloadDir}/old.csv', 'SKIPPED_DUPLICATE', '{$oldDate}', '{$oldDate}', '{$oldDate}'),
        ('terminal-new', 'src', 'done', 'new.csv', '{$downloadDir}/new.csv', 'SKIPPED_DUPLICATE', '{$newDate}', '{$newDate}', '{$newDate}'),
        ('active-old', 'src', 'done', 'active.csv', '{$downloadDir}/active.csv', 'MOVED', '{$oldDate}', '{$oldDate}', '{$oldDate}')");

    $rows = $repo->findTerminalRowsInDownload($downloadDir, 30);

    assert(count($rows) === 1);
    assert($rows[0]['item_id'] === 'terminal-old');
},
'repository updates local path after cleanup move' => function (): void {
    $pdo = new PDO('sqlite::memory:');
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $migration = str_replace(
        ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
        ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', 'DEFAULT CURRENT_TIMESTAMP'],
        file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
    );
    $pdo->exec(preg_replace('/,\s*\);\s*$/', "\n);", $migration));
    $repo = new FileQueueRepository($pdo);

    $pdo->exec("INSERT INTO sharepoint_file_queue
        (item_id, source_folder, processed_folder, file_name, local_path, status)
        VALUES ('path-update', 'src', 'done', 'file.csv', 'download/file.csv', 'SKIPPED_DUPLICATE')");

    $repo->updateLocalPath(1, 'archive/download-cleanup/2026-07/file.csv');
    $row = $repo->findByItemId('path-update');

    assert($row['local_path'] === 'archive/download-cleanup/2026-07/file.csv');
},
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
php tests\run.php
```

Expected: fails because `findTerminalRowsInDownload()` and `updateLocalPath()` do not exist.

- [ ] **Step 3: Implement repository methods**

Add to `src/Queue/FileQueueRepository.php`:

```php
public function findTerminalRowsInDownload(string $downloadDir, int $olderThanDays): array
{
    $normalized = rtrim(str_replace('\\', '/', $downloadDir), '/') . '/';
    $stmt = $this->pdo->prepare(
        "SELECT * FROM sharepoint_file_queue
         WHERE status IN ('SUCCESS', 'IMPORTED', 'SKIPPED_DUPLICATE')
           AND local_path IS NOT NULL
           AND REPLACE(local_path, '\\\\', '/') LIKE :download_prefix
           AND COALESCE(imported_at, updated_at, created_at) < DATE_SUB(NOW(), INTERVAL :days DAY)
         ORDER BY COALESCE(imported_at, updated_at, created_at) ASC, id ASC"
    );
    $stmt->bindValue(':download_prefix', $normalized . '%.csv');
    $stmt->bindValue(':days', $olderThanDays, PDO::PARAM_INT);
    $stmt->execute();

    return $stmt->fetchAll(PDO::FETCH_ASSOC);
}

public function updateLocalPath(int $id, string $localPath): void
{
    $stmt = $this->pdo->prepare(
        'UPDATE sharepoint_file_queue
         SET local_path = :local_path, updated_at = CURRENT_TIMESTAMP
         WHERE id = :id'
    );
    $stmt->execute([':local_path' => $localPath, ':id' => $id]);
}
```

For SQLite tests, if `DATE_SUB` is not supported, add a test-only adapter query or compute cutoff in PHP and use `:cutoff` instead. Preferred implementation:

```php
$cutoff = (new DateTimeImmutable("-{$olderThanDays} days"))->format('Y-m-d H:i:s');
...
AND COALESCE(imported_at, updated_at, created_at) < :cutoff
...
$stmt->bindValue(':cutoff', $cutoff);
```

- [ ] **Step 4: Run tests**

Run:

```powershell
php tests\run.php
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```powershell
git add src\Queue\FileQueueRepository.php tests\Queue\FileQueueRepositoryTest.php
git commit -m "feat: add queue cleanup repository methods"
```

---

### Task 2: Download Cleanup Service

**Files:**
- Create: `src/Maintenance/DownloadCleanup.php`
- Test: `tests/Maintenance/DownloadCleanupTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- Consumes: `FileQueueRepository::findTerminalRowsInDownload(string $downloadDir, int $olderThanDays): array`
- Consumes: `FileQueueRepository::updateLocalPath(int $id, string $localPath): void`
- Produces: `DownloadCleanup::run(bool $dryRun = true): array`

- [ ] **Step 1: Create failing tests**

Create `tests/Maintenance/DownloadCleanupTest.php`:

```php
<?php

use App\Config\AppConfig;
use App\Maintenance\DownloadCleanup;
use App\Queue\FileQueueRepository;
use App\Support\Logger;

return [
    'download cleanup dry run does not move files' => function (): void {
        [$root, $pdo, $repo, $file] = cleanupFixture('SKIPPED_DUPLICATE', '-45 days');
        $config = new AppConfig($root, 'src', 'done', $root . '/download', $root . '/archive', $root . '/error', 3, $root . '/temp/pipeline.lock');
        $cleanup = new DownloadCleanup($repo, $config, new Logger($root . '/logs/test.log'), 30);

        $result = $cleanup->run(true);

        assert($result['moved'] === 0);
        assert($result['candidates'] === 1);
        assert(file_exists($file));
    },
    'download cleanup moves old duplicate csv to dated cleanup archive' => function (): void {
        [$root, $pdo, $repo, $file] = cleanupFixture('SKIPPED_DUPLICATE', '-45 days');
        $config = new AppConfig($root, 'src', 'done', $root . '/download', $root . '/archive', $root . '/error', 3, $root . '/temp/pipeline.lock');
        $cleanup = new DownloadCleanup($repo, $config, new Logger($root . '/logs/test.log'), 30);

        $result = $cleanup->run(false);
        $row = $repo->findByItemId('cleanup-item');

        assert($result['moved'] === 1);
        assert(!file_exists($file));
        assert(str_contains(str_replace('\\', '/', $row['local_path']), '/archive/download-cleanup/'));
        assert(file_exists($row['local_path']));
    },
    'download cleanup skips active queue files' => function (): void {
        [$root, $pdo, $repo, $file] = cleanupFixture('MOVED', '-45 days');
        $config = new AppConfig($root, 'src', 'done', $root . '/download', $root . '/archive', $root . '/error', 3, $root . '/temp/pipeline.lock');
        $cleanup = new DownloadCleanup($repo, $config, new Logger($root . '/logs/test.log'), 30);

        $result = $cleanup->run(false);

        assert($result['moved'] === 0);
        assert(file_exists($file));
    },
];

function cleanupFixture(string $status, string $age): array
{
    $root = sys_get_temp_dir() . '/download-cleanup-' . bin2hex(random_bytes(4));
    mkdir($root . '/download', 0777, true);
    mkdir($root . '/archive', 0777, true);
    mkdir($root . '/logs', 0777, true);
    $file = $root . '/download/payment.csv';
    file_put_contents($file, "company\nSHF\n");

    $pdo = new PDO('sqlite::memory:');
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $migration = str_replace(
        ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
        ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', 'DEFAULT CURRENT_TIMESTAMP'],
        file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
    );
    $pdo->exec(preg_replace('/,\s*\);\s*$/', "\n);", $migration));
    $repo = new FileQueueRepository($pdo);
    $date = (new DateTimeImmutable($age))->format('Y-m-d H:i:s');
    $stmt = $pdo->prepare("INSERT INTO sharepoint_file_queue
        (item_id, source_folder, processed_folder, file_name, local_path, status, imported_at, created_at, updated_at)
        VALUES ('cleanup-item', 'src', 'done', 'payment.csv', :path, :status, :date, :date, :date)");
    $stmt->execute([':path' => $file, ':status' => $status, ':date' => $date]);

    return [$root, $pdo, $repo, $file];
}
```

Modify `tests/run.php` to include:

```php
__DIR__ . '/Maintenance/DownloadCleanupTest.php',
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
php tests\run.php
```

Expected: fails because `App\Maintenance\DownloadCleanup` does not exist.

- [ ] **Step 3: Implement cleanup service**

Create `src/Maintenance/DownloadCleanup.php`:

```php
<?php

namespace App\Maintenance;

use App\Config\AppConfig;
use App\Queue\FileQueueRepository;
use App\Support\Logger;
use RuntimeException;

final class DownloadCleanup
{
    public function __construct(
        private readonly FileQueueRepository $repo,
        private readonly AppConfig $config,
        private readonly Logger $logger,
        private readonly int $retentionDays,
    ) {
    }

    public function run(bool $dryRun = true): array
    {
        $rows = $this->repo->findTerminalRowsInDownload($this->config->downloadDir, $this->retentionDays);
        $result = ['candidates' => count($rows), 'moved' => 0, 'skipped' => 0];

        foreach ($rows as $row) {
            $source = (string) $row['local_path'];
            if (!$this->isSafeDownloadCsv($source)) {
                $result['skipped']++;
                $this->logger->info('Download cleanup skipped unsafe path', ['file' => $source, 'queue_id' => $row['id']]);
                continue;
            }

            if (!is_file($source)) {
                $result['skipped']++;
                $this->logger->info('Download cleanup skipped missing file', ['file' => $source, 'queue_id' => $row['id']]);
                continue;
            }

            $target = $this->targetPath($source);
            if ($dryRun) {
                $this->logger->info('Download cleanup dry run', ['from' => $source, 'to' => $target, 'queue_id' => $row['id']]);
                continue;
            }

            $targetDir = dirname($target);
            if (!is_dir($targetDir) && !mkdir($targetDir, 0777, true) && !is_dir($targetDir)) {
                throw new RuntimeException("Unable to create cleanup directory {$targetDir}");
            }

            $finalTarget = $this->uniquePath($target);
            if (!rename($source, $finalTarget)) {
                throw new RuntimeException("Unable to move {$source} to {$finalTarget}");
            }

            $this->repo->updateLocalPath((int) $row['id'], $finalTarget);
            $result['moved']++;
            $this->logger->info('Download cleanup moved file', ['from' => $source, 'to' => $finalTarget, 'queue_id' => $row['id']]);
        }

        return $result;
    }

    private function isSafeDownloadCsv(string $path): bool
    {
        $download = rtrim(str_replace('\\', '/', realpath($this->config->downloadDir) ?: $this->config->downloadDir), '/') . '/';
        $candidate = str_replace('\\', '/', realpath($path) ?: $path);

        return str_starts_with($candidate, $download)
            && strcasecmp(pathinfo($candidate, PATHINFO_EXTENSION), 'csv') === 0;
    }

    private function targetPath(string $source): string
    {
        $month = date('Y-m');
        return rtrim($this->config->archiveDir, "\\/") . DIRECTORY_SEPARATOR
            . 'download-cleanup' . DIRECTORY_SEPARATOR
            . $month . DIRECTORY_SEPARATOR
            . basename($source);
    }

    private function uniquePath(string $path): string
    {
        if (!file_exists($path)) {
            return $path;
        }

        $dir = dirname($path);
        $name = pathinfo($path, PATHINFO_FILENAME);
        $ext = pathinfo($path, PATHINFO_EXTENSION);
        $suffix = date('Ymd_His');

        return $dir . DIRECTORY_SEPARATOR . $name . '_' . $suffix . ($ext === '' ? '' : '.' . $ext);
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```powershell
php tests\run.php
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```powershell
git add src\Maintenance\DownloadCleanup.php tests\Maintenance\DownloadCleanupTest.php tests\run.php
git commit -m "feat: add safe download cleanup service"
```

---

### Task 3: Cleanup CLI Entrypoint

**Files:**
- Create: `maintenance/cleanup_download.php`
- Test: `tests/Maintenance/DownloadCleanupCliTest.php` if a CLI harness is added, otherwise cover via service tests and manual command verification.

**Interfaces:**
- Consumes: `DownloadCleanup::run(bool $dryRun = true): array`
- Produces: CLI flags `--dry-run` and `--run`

- [ ] **Step 1: Create CLI script**

Create `maintenance/cleanup_download.php`:

```php
<?php

use App\Config\AppConfig;
use App\Maintenance\DownloadCleanup;
use App\Queue\FileQueueRepository;
use App\Support\Logger;
use Dotenv\Dotenv;

require dirname(__DIR__) . '/vendor/autoload.php';

$rootDir = dirname(__DIR__);
Dotenv::createImmutable($rootDir . '/config')->safeLoad();

$dryRun = !in_array('--run', $argv, true);
$retentionDays = max(1, (int) ($_ENV['DOWNLOAD_CLEANUP_RETENTION_DAYS'] ?? 30));

$config = AppConfig::fromEnv($rootDir);
$logger = new Logger($rootDir . '/logs/download_cleanup.log');
$pdo = new PDO(
    sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $_ENV['DB_HOST'], $_ENV['DB_NAME']),
    $_ENV['DB_USER'],
    $_ENV['DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);

$cleanup = new DownloadCleanup(new FileQueueRepository($pdo), $config, $logger, $retentionDays);
$result = $cleanup->run($dryRun);

echo ($dryRun ? 'DRY RUN' : 'RUN') . PHP_EOL;
echo 'Candidates: ' . $result['candidates'] . PHP_EOL;
echo 'Moved: ' . $result['moved'] . PHP_EOL;
echo 'Skipped: ' . $result['skipped'] . PHP_EOL;
```

- [ ] **Step 2: Dry-run manually**

Run:

```powershell
C:\xampp\php\php.exe maintenance\cleanup_download.php --dry-run
```

Expected: prints candidates/moved/skipped, with `Moved: 0`.

- [ ] **Step 3: Real-run manually**

Run:

```powershell
C:\xampp\php\php.exe maintenance\cleanup_download.php --run
```

Expected: old safe CSV files move from `download\` to `archive\download-cleanup\YYYY-MM\`.

- [ ] **Step 4: Commit**

```powershell
git add maintenance\cleanup_download.php
git commit -m "feat: add download cleanup cli"
```

---

### Task 4: Config, Batch, and Scheduler Documentation

**Files:**
- Create: `run_download_cleanup.bat`
- Modify: `config/.env.example`
- Modify: `Readme.txt`

**Interfaces:**
- Consumes: `maintenance/cleanup_download.php --run`
- Produces: monthly Task Scheduler command target

- [ ] **Step 1: Update env example**

Add to `config/.env.example`:

```env
DOWNLOAD_CLEANUP_RETENTION_DAYS=30
```

- [ ] **Step 2: Create batch wrapper**

Create `run_download_cleanup.bat`:

```bat
@echo off
cd /d C:\xampp\htdocs\D365_Sharedpoint_csv_import
if not exist logs mkdir logs
C:\xampp\php\php.exe maintenance\cleanup_download.php --run >> logs\download_cleanup.log 2>&1
```

- [ ] **Step 3: Document manual commands**

Add to `Readme.txt`:

```text
Monthly Download Cleanup
--------------------------------------------------------

Purpose:
- Clear old terminal CSV files out of download\
- Preserve files by moving them to archive\download-cleanup\YYYY-MM\
- Never clean files still needed by active import or recovery statuses

Dry run:
C:\xampp\php\php.exe maintenance\cleanup_download.php --dry-run

Real run:
C:\xampp\php\php.exe maintenance\cleanup_download.php --run

Windows Task Scheduler target:
C:\xampp\htdocs\D365_Sharedpoint_csv_import\run_download_cleanup.bat

Recommended schedule:
- Monthly
- Day 1
- 01:00
- Run after the import scheduler window is quiet
```

- [ ] **Step 4: Commit**

```powershell
git add config\.env.example run_download_cleanup.bat Readme.txt
git commit -m "docs: add monthly download cleanup operation"
```

---

### Task 5: Verification and Operational Rollout

**Files:**
- No new production files.
- Verify: `logs/download_cleanup.log`, `sharepoint_file_queue`, `download\`, `archive\download-cleanup\YYYY-MM\`

**Interfaces:**
- Consumes: `run_download_cleanup.bat`
- Produces: validated monthly cleanup procedure

- [ ] **Step 1: Run full tests**

Run:

```powershell
php tests\run.php
```

Expected: all tests pass.

- [ ] **Step 2: Run dry-run on current server**

Run:

```powershell
C:\xampp\php\php.exe maintenance\cleanup_download.php --dry-run
```

Expected:

```text
DRY RUN
Candidates: <number>
Moved: 0
Skipped: <number>
```

- [ ] **Step 3: Confirm no active queue rows would be touched**

Run:

```sql
SELECT status, COUNT(*)
FROM sharepoint_file_queue
GROUP BY status;
```

Do not run real cleanup if any file in `download\` belongs to these statuses:

```text
DOWNLOADED
MOVING
MOVED
IMPORTING
ERROR
IMPORT_ERROR
RECOVERY_ERROR
RECOVERY_DOWNLOADING
```

- [ ] **Step 4: Run real cleanup**

Run:

```powershell
C:\xampp\php\php.exe maintenance\cleanup_download.php --run
```

Expected: eligible old CSV files leave `download\` and appear under:

```text
archive\download-cleanup\YYYY-MM\
```

- [ ] **Step 5: Verify DB local paths were updated**

Run:

```sql
SELECT file_name, status, local_path
FROM sharepoint_file_queue
WHERE status IN ('SUCCESS', 'IMPORTED', 'SKIPPED_DUPLICATE')
ORDER BY updated_at DESC
LIMIT 20;
```

Expected: cleaned rows point to `archive/download-cleanup/YYYY-MM/...`.

- [ ] **Step 6: Create monthly scheduler**

Use Windows Task Scheduler:

```text
Program/script:
C:\xampp\htdocs\D365_Sharedpoint_csv_import\run_download_cleanup.bat

Schedule:
Monthly, day 1, 01:00
```

Avoid scheduling it at the same time as `run_import.bat`.

- [ ] **Step 7: Commit any final verification/doc fixes**

```powershell
git status --short
php tests\run.php
git add <changed-files>
git commit -m "chore: verify monthly download cleanup"
```

---

## Self-Review

- Spec coverage: monthly cleanup is covered by service, CLI, batch wrapper, docs, tests, and rollout verification.
- Safety coverage: cleanup only moves terminal CSV files, never active/recovery statuses, and defaults to dry-run at CLI level.
- Operational coverage: Task Scheduler target and recommended monthly timing are documented.
- No destructive default: files are moved to cleanup archive, not permanently deleted.
- Type consistency: `DownloadCleanup::run(bool $dryRun = true): array`, `FileQueueRepository::findTerminalRowsInDownload(string $downloadDir, int $olderThanDays): array`, and `FileQueueRepository::updateLocalPath(int $id, string $localPath): void` are consistently referenced.
