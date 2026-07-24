# SharePoint CSV Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a safe SharePoint CSV pipeline that sweeps every `.csv` from `PaymentBeforePost`, downloads each file, moves the SharePoint item to `PaymentBeforePost_Downloaded` after verified download, and imports local files oldest-to-newest with recoverable queue state.

**Architecture:** Replace the current "download latest then import latest" coupling with a queue-backed pipeline. Keep SharePoint download/move in `DownloadQueue`, database import sequencing in `ImportQueue`, and durable file status in `sharepoint_file_queue`.

**Tech Stack:** PHP, Composer autoload, PDO, vlucas/phpdotenv, Microsoft Graph REST via cURL, Windows Task Scheduler.

## Global Constraints

- Source SharePoint folder is `PaymentBeforePost`.
- Processed SharePoint folder is `PaymentBeforePost_Downloaded`.
- Process only `.csv` files, case-insensitive.
- Move the SharePoint item only after local download validation passes.
- Import local files oldest-to-newest.
- Stop Import Queue at the first older file import failure.
- Never log `CLIENT_SECRET`, database passwords, access tokens, or Microsoft Graph preauthenticated download URLs.
- Keep `config/.env` local-only and ignored by git.
- Keep `download/`, `archive/`, `error/`, `temp/`, `logs/`, and `vendor/` ignored by git.
- Do not delete a local downloaded CSV before successful import and archive.
- Use Microsoft Graph pagination when listing folder children.
- Use one scheduler entrypoint for the whole pipeline.

---

## File Structure

- Create `database/migrations/001_create_sharepoint_file_queue.sql`: queue table and indexes.
- Create `src/Config/AppConfig.php`: reads environment values and normalizes local paths.
- Create `src/Support/Logger.php`: safe logger that masks secrets and URLs.
- Create `src/Support/PipelineLock.php`: local filesystem lock to prevent overlap.
- Create `src/Queue/FileQueueRepository.php`: queue table CRUD and status transitions.
- Create `src/SharePoint/SharePointClient.php`: Microsoft Graph auth/list/download/move.
- Create `src/SharePoint/DownloadQueue.php`: discover/download/move stage.
- Create `src/Import/PaymentBeforePostImporter.php`: import one specified local CSV.
- Create `src/Import/ImportQueue.php`: queue-ordered import stage.
- Create `import/run_pipeline.php`: scheduler entrypoint.
- Modify `import/run_import.php`: keep backward-compatible wrapper around `run_pipeline.php` or retire latest-file logic.
- Modify `import/download_csv.php`: keep backward-compatible wrapper around Download Queue or mark as deprecated.
- Modify `monitor/index.php`: show queue status and errors.
- Modify `run_import.bat`: call `import/run_pipeline.php`.
- Modify `install_task_scheduler.ps1`: point task scheduler to `run_import.bat` after the batch file is updated.
- Modify `config/.env.example`: include new queue folder and retry keys.
- Modify `Readme.txt`: document new flow and operational recovery.
- Create `tests/bootstrap.php`: lightweight test bootstrap.
- Create `tests/run.php`: test runner.
- Create focused test files under `tests/`.

---

### Task 1: Configuration, Safe Logging, and Test Harness

**Files:**
- Modify: `composer.json`
- Modify: `config/.env.example`
- Create: `src/Config/AppConfig.php`
- Create: `src/Support/Logger.php`
- Create: `tests/bootstrap.php`
- Create: `tests/run.php`
- Create: `tests/Config/AppConfigTest.php`
- Create: `tests/Support/LoggerTest.php`

**Interfaces:**
- Produces: `App\Config\AppConfig::fromEnv(string $rootDir): App\Config\AppConfig`
- Produces: `App\Config\AppConfig->path(string $relativeOrAbsolute): string`
- Produces: `App\Support\Logger->__construct(string $logFile)`
- Produces: `App\Support\Logger->info(string $message): void`
- Produces: `App\Support\Logger->error(string $message): void`

- [ ] **Step 1: Add PSR-4 autoload-dev**

In `composer.json`, keep existing `autoload` and add this block:

```json
"autoload-dev": {
  "psr-4": {
    "Tests\\": "tests/"
  }
}
```

Run:

```powershell
composer dump-autoload
```

Expected: Composer regenerates autoload files without errors.

- [ ] **Step 2: Extend config example**

Ensure `config/.env.example` contains exactly these new queue keys with safe values:

```env
CSV_FOLDER=PaymentBeforePost
CSV_DOWNLOADED_FOLDER=PaymentBeforePost_Downloaded
CSV_LOCAL_DOWNLOAD_DIR=download
CSV_LOCAL_ARCHIVE_DIR=archive
CSV_LOCAL_ERROR_DIR=error
GRAPH_RETRY_ATTEMPTS=3
PIPELINE_LOCK_FILE=temp/pipeline.lock
```

- [ ] **Step 3: Write failing AppConfig test**

Create `tests/Config/AppConfigTest.php`:

```php
<?php

use App\Config\AppConfig;

return [
    'app config reads queue defaults' => function (): void {
        $_ENV['CSV_FOLDER'] = 'PaymentBeforePost';
        $_ENV['CSV_DOWNLOADED_FOLDER'] = 'PaymentBeforePost_Downloaded';
        $_ENV['CSV_LOCAL_DOWNLOAD_DIR'] = 'download';
        $_ENV['CSV_LOCAL_ARCHIVE_DIR'] = 'archive';
        $_ENV['CSV_LOCAL_ERROR_DIR'] = 'error';
        $_ENV['GRAPH_RETRY_ATTEMPTS'] = '3';
        $_ENV['PIPELINE_LOCK_FILE'] = 'temp/pipeline.lock';

        $config = AppConfig::fromEnv(dirname(__DIR__, 2));

        assert($config->sourceFolder === 'PaymentBeforePost');
        assert($config->processedFolder === 'PaymentBeforePost_Downloaded');
        assert($config->retryAttempts === 3);
        assert(str_ends_with($config->downloadDir, DIRECTORY_SEPARATOR . 'download'));
        assert(str_ends_with($config->archiveDir, DIRECTORY_SEPARATOR . 'archive'));
        assert(str_ends_with($config->errorDir, DIRECTORY_SEPARATOR . 'error'));
        assert(str_ends_with($config->lockFile, DIRECTORY_SEPARATOR . 'temp' . DIRECTORY_SEPARATOR . 'pipeline.lock'));
    },
];
```

- [ ] **Step 4: Write failing Logger test**

Create `tests/Support/LoggerTest.php`:

```php
<?php

use App\Support\Logger;

return [
    'logger masks secrets and graph download urls' => function (): void {
        $logFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'queue_logger_test_' . uniqid('', true) . '.log';
        $logger = new Logger($logFile);

        $logger->info('CLIENT_SECRET=abc123 token=secret-token https://contoso.sharepoint.com/download.aspx?authkey=secret');

        $content = file_get_contents($logFile);
        assert(str_contains($content, 'CLIENT_SECRET=[masked]'));
        assert(str_contains($content, 'token=[masked]'));
        assert(str_contains($content, 'https://contoso.sharepoint.com/[masked-url]'));
        assert(!str_contains($content, 'abc123'));
        assert(!str_contains($content, 'secret-token'));

        unlink($logFile);
    },
];
```

- [ ] **Step 5: Create test bootstrap and runner**

Create `tests/bootstrap.php`:

```php
<?php

require dirname(__DIR__) . '/vendor/autoload.php';

assert_options(ASSERT_ACTIVE, 1);
assert_options(ASSERT_EXCEPTION, 1);
```

Create `tests/run.php`:

```php
<?php

require __DIR__ . '/bootstrap.php';

$files = [
    __DIR__ . '/Config/AppConfigTest.php',
    __DIR__ . '/Support/LoggerTest.php',
];

$passed = 0;

foreach ($files as $file) {
    $tests = require $file;
    foreach ($tests as $name => $test) {
        $test();
        echo "PASS {$name}\n";
        $passed++;
    }
}

echo "Tests passed: {$passed}\n";
```

- [ ] **Step 6: Run tests and verify they fail**

Run:

```powershell
php tests/run.php
```

Expected: fails because `AppConfig` and `Logger` do not exist.

- [ ] **Step 7: Implement AppConfig**

Create `src/Config/AppConfig.php`:

```php
<?php

namespace App\Config;

final class AppConfig
{
    public function __construct(
        public readonly string $rootDir,
        public readonly string $sourceFolder,
        public readonly string $processedFolder,
        public readonly string $downloadDir,
        public readonly string $archiveDir,
        public readonly string $errorDir,
        public readonly int $retryAttempts,
        public readonly string $lockFile,
    ) {
    }

    public static function fromEnv(string $rootDir): self
    {
        return new self(
            rtrim($rootDir, "\\/"),
            $_ENV['CSV_FOLDER'] ?? 'PaymentBeforePost',
            $_ENV['CSV_DOWNLOADED_FOLDER'] ?? 'PaymentBeforePost_Downloaded',
            self::resolvePath($rootDir, $_ENV['CSV_LOCAL_DOWNLOAD_DIR'] ?? 'download'),
            self::resolvePath($rootDir, $_ENV['CSV_LOCAL_ARCHIVE_DIR'] ?? 'archive'),
            self::resolvePath($rootDir, $_ENV['CSV_LOCAL_ERROR_DIR'] ?? 'error'),
            max(1, (int)($_ENV['GRAPH_RETRY_ATTEMPTS'] ?? 3)),
            self::resolvePath($rootDir, $_ENV['PIPELINE_LOCK_FILE'] ?? 'temp/pipeline.lock'),
        );
    }

    public function path(string $relativeOrAbsolute): string
    {
        return self::resolvePath($this->rootDir, $relativeOrAbsolute);
    }

    private static function resolvePath(string $rootDir, string $path): string
    {
        if (preg_match('/^[A-Za-z]:[\\\\\\/]/', $path) === 1 || str_starts_with($path, '\\\\')) {
            return rtrim($path, "\\/");
        }

        return rtrim($rootDir, "\\/") . DIRECTORY_SEPARATOR . trim($path, "\\/");
    }
}
```

- [ ] **Step 8: Implement Logger**

Create `src/Support/Logger.php`:

```php
<?php

namespace App\Support;

final class Logger
{
    public function __construct(private readonly string $logFile)
    {
        $dir = dirname($this->logFile);
        if (!is_dir($dir)) {
            mkdir($dir, 0777, true);
        }
    }

    public function info(string $message): void
    {
        $this->write('INFO', $message);
    }

    public function error(string $message): void
    {
        $this->write('ERROR', $message);
    }

    private function write(string $level, string $message): void
    {
        $line = sprintf("[%s] %s %s\n", date('Y-m-d H:i:s'), $level, self::sanitize($message));
        file_put_contents($this->logFile, $line, FILE_APPEND);
    }

    public static function sanitize(string $message): string
    {
        $message = preg_replace('/CLIENT_SECRET=\\S+/i', 'CLIENT_SECRET=[masked]', $message);
        $message = preg_replace('/token=\\S+/i', 'token=[masked]', $message);
        $message = preg_replace('/https:\\/\\/[^\\s]*sharepoint\\.com\\/\\S+/i', 'https://contoso.sharepoint.com/[masked-url]', $message);

        return $message;
    }
}
```

- [ ] **Step 9: Run tests and commit**

Run:

```powershell
php tests/run.php
git status --short
git add composer.json composer.lock config/.env.example src/Config/AppConfig.php src/Support/Logger.php tests
git commit -m "chore: add queue config and safe logging"
```

Expected: tests pass; commit contains no `config/.env`.

---

### Task 2: Queue Database Migration and Repository

**Files:**
- Create: `database/migrations/001_create_sharepoint_file_queue.sql`
- Create: `src/Queue/FileQueueRepository.php`
- Create: `tests/Queue/FileQueueRepositoryTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- Consumes: `PDO`
- Produces: `App\Queue\FileQueueRepository->__construct(PDO $pdo)`
- Produces: `upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int`
- Produces: `markStatus(int $id, string $status, ?string $error = null): void`
- Produces: `findReadyForImport(): array`
- Produces: `findByItemId(string $itemId): ?array`
- Produces: `markDownloaded(int $id, string $localPath, string $sha256): void`
- Produces: `markMoved(int $id): void`
- Produces: `markImported(int $id): void`
- Produces: `markSkippedDuplicate(int $id, string $sha256): void`

- [ ] **Step 1: Write migration**

Create `database/migrations/001_create_sharepoint_file_queue.sql`:

```sql
CREATE TABLE IF NOT EXISTS sharepoint_file_queue (
    id INT AUTO_INCREMENT PRIMARY KEY,
    drive_id VARCHAR(255) NULL,
    item_id VARCHAR(255) NOT NULL,
    source_folder VARCHAR(255) NOT NULL,
    processed_folder VARCHAR(255) NOT NULL,
    file_name VARCHAR(512) NOT NULL,
    sharepoint_size BIGINT NULL,
    sharepoint_etag VARCHAR(255) NULL,
    sharepoint_last_modified_at DATETIME NULL,
    local_path VARCHAR(1024) NULL,
    local_sha256 CHAR(64) NULL,
    status VARCHAR(40) NOT NULL,
    attempt_count INT NOT NULL DEFAULT 0,
    last_error TEXT NULL,
    next_retry_at DATETIME NULL,
    downloaded_at DATETIME NULL,
    moved_at DATETIME NULL,
    import_started_at DATETIME NULL,
    imported_at DATETIME NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),
    KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),
    KEY idx_sharepoint_file_queue_sha256 (local_sha256)
);
```

- [ ] **Step 2: Write failing repository test**

Create `tests/Queue/FileQueueRepositoryTest.php` using SQLite for repository behavior:

```php
<?php

use App\Queue\FileQueueRepository;

return [
    'repository upserts discovered and orders moved files oldest first' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec(str_replace(
            ['INT AUTO_INCREMENT PRIMARY KEY', 'BIGINT', 'DATETIME', 'TEXT', 'UNIQUE KEY uq_sharepoint_file_queue_item_id (item_id),', 'KEY idx_sharepoint_file_queue_status_modified (status, sharepoint_last_modified_at),', 'KEY idx_sharepoint_file_queue_sha256 (local_sha256)', 'DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP'],
            ['INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER', 'TEXT', 'TEXT', 'UNIQUE (item_id),', '', '', "DEFAULT CURRENT_TIMESTAMP"],
            file_get_contents(dirname(__DIR__, 2) . '/database/migrations/001_create_sharepoint_file_queue.sql')
        ));

        $repo = new FileQueueRepository($pdo);

        $newer = $repo->upsertDiscovered([
            'drive_id' => 'drive',
            'id' => 'item-new',
            'name' => 'new.csv',
            'size' => 20,
            'eTag' => 'etag-new',
            'lastModifiedDateTime' => '2026-07-24T10:00:00Z',
        ], 'PaymentBeforePost', 'PaymentBeforePost_Downloaded');

        $older = $repo->upsertDiscovered([
            'drive_id' => 'drive',
            'id' => 'item-old',
            'name' => 'old.csv',
            'size' => 10,
            'eTag' => 'etag-old',
            'lastModifiedDateTime' => '2026-07-24T09:00:00Z',
        ], 'PaymentBeforePost', 'PaymentBeforePost_Downloaded');

        $repo->markMoved($newer);
        $repo->markMoved($older);

        $ready = $repo->findReadyForImport();

        assert($ready[0]['file_name'] === 'old.csv');
        assert($ready[1]['file_name'] === 'new.csv');
    },
];
```

Add the file to `tests/run.php`:

```php
__DIR__ . '/Queue/FileQueueRepositoryTest.php',
```

- [ ] **Step 3: Run test and verify failure**

Run:

```powershell
php tests/run.php
```

Expected: fails because `FileQueueRepository` does not exist.

- [ ] **Step 4: Implement repository**

Create `src/Queue/FileQueueRepository.php`:

```php
<?php

namespace App\Queue;

use DateTimeImmutable;
use PDO;

final class FileQueueRepository
{
    public function __construct(private readonly PDO $pdo)
    {
    }

    public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int
    {
        $modified = $this->toSqlDate($item['lastModifiedDateTime'] ?? null);
        $existing = $this->findByItemId($item['id']);

        if ($existing !== null) {
            $stmt = $this->pdo->prepare(
                'UPDATE sharepoint_file_queue
                 SET drive_id = :drive_id, file_name = :file_name, sharepoint_size = :size,
                     sharepoint_etag = :etag, sharepoint_last_modified_at = :modified,
                     updated_at = CURRENT_TIMESTAMP
                 WHERE item_id = :item_id'
            );
            $stmt->execute([
                ':drive_id' => $item['drive_id'] ?? null,
                ':file_name' => $item['name'],
                ':size' => $item['size'] ?? null,
                ':etag' => $item['eTag'] ?? null,
                ':modified' => $modified,
                ':item_id' => $item['id'],
            ]);
            return (int)$existing['id'];
        }

        $stmt = $this->pdo->prepare(
            'INSERT INTO sharepoint_file_queue
             (drive_id, item_id, source_folder, processed_folder, file_name, sharepoint_size, sharepoint_etag, sharepoint_last_modified_at, status)
             VALUES (:drive_id, :item_id, :source_folder, :processed_folder, :file_name, :size, :etag, :modified, :status)'
        );
        $stmt->execute([
            ':drive_id' => $item['drive_id'] ?? null,
            ':item_id' => $item['id'],
            ':source_folder' => $sourceFolder,
            ':processed_folder' => $processedFolder,
            ':file_name' => $item['name'],
            ':size' => $item['size'] ?? null,
            ':etag' => $item['eTag'] ?? null,
            ':modified' => $modified,
            ':status' => 'DISCOVERED',
        ]);

        return (int)$this->pdo->lastInsertId();
    }

    public function findByItemId(string $itemId): ?array
    {
        $stmt = $this->pdo->prepare('SELECT * FROM sharepoint_file_queue WHERE item_id = :item_id');
        $stmt->execute([':item_id' => $itemId]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);

        return $row === false ? null : $row;
    }

    public function findReadyForImport(): array
    {
        $stmt = $this->pdo->query(
            "SELECT * FROM sharepoint_file_queue
             WHERE status = 'MOVED'
             ORDER BY sharepoint_last_modified_at ASC, id ASC"
        );

        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    public function markStatus(int $id, string $status, ?string $error = null): void
    {
        $stmt = $this->pdo->prepare(
            'UPDATE sharepoint_file_queue
             SET status = :status, last_error = :error, attempt_count = attempt_count + 1, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id'
        );
        $stmt->execute([':status' => $status, ':error' => $error, ':id' => $id]);
    }

    public function markDownloaded(int $id, string $localPath, string $sha256): void
    {
        $stmt = $this->pdo->prepare(
            "UPDATE sharepoint_file_queue
             SET status = 'DOWNLOADED', local_path = :local_path, local_sha256 = :sha256, downloaded_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id"
        );
        $stmt->execute([':local_path' => $localPath, ':sha256' => $sha256, ':id' => $id]);
    }

    public function markMoved(int $id): void
    {
        $stmt = $this->pdo->prepare(
            "UPDATE sharepoint_file_queue
             SET status = 'MOVED', moved_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id"
        );
        $stmt->execute([':id' => $id]);
    }

    public function markImported(int $id): void
    {
        $stmt = $this->pdo->prepare(
            "UPDATE sharepoint_file_queue
             SET status = 'IMPORTED', imported_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id"
        );
        $stmt->execute([':id' => $id]);
    }

    public function markSkippedDuplicate(int $id, string $sha256): void
    {
        $stmt = $this->pdo->prepare(
            "UPDATE sharepoint_file_queue
             SET status = 'SKIPPED_DUPLICATE', local_sha256 = :sha256, imported_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
             WHERE id = :id"
        );
        $stmt->execute([':sha256' => $sha256, ':id' => $id]);
    }

    private function toSqlDate(?string $value): ?string
    {
        if ($value === null || $value === '') {
            return null;
        }

        return (new DateTimeImmutable($value))->format('Y-m-d H:i:s');
    }
}
```

- [ ] **Step 5: Run tests and commit**

Run:

```powershell
php tests/run.php
git add database/migrations/001_create_sharepoint_file_queue.sql src/Queue/FileQueueRepository.php tests/run.php tests/Queue/FileQueueRepositoryTest.php
git commit -m "feat: add SharePoint file queue repository"
```

Expected: tests pass.

---

### Task 3: SharePoint Client

**Files:**
- Create: `src/SharePoint/SharePointClient.php`
- Create: `tests/SharePoint/SharePointClientTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- Produces: `SharePointClient::fromEnv(array $env, ?callable $http = null): SharePointClient`
- Produces: `SharePointClient->listCsvFiles(string $folderPath): array`
- Produces: `SharePointClient->downloadItem(string $driveId, string $itemId, string $targetPath): void`
- Produces: `SharePointClient->moveItem(string $driveId, string $itemId, string $processedFolderItemId): void`
- Produces: `SharePointClient->resolveFolderItemId(string $folderPath): string`
- Produces: injectable constructor `__construct(array $env, ?callable $http = null)`

- [ ] **Step 1: Write failing pagination/filter test**

Create `tests/SharePoint/SharePointClientTest.php`:

```php
<?php

use App\SharePoint\SharePointClient;

return [
    'sharepoint client follows pagination and filters csv files' => function (): void {
        $calls = [];
        $http = function (string $method, string $url, array $headers = [], ?string $body = null) use (&$calls): array {
            $calls[] = [$method, $url];

            if (str_contains($url, 'page2')) {
                return [200, [], json_encode([
                    'value' => [
                        ['id' => '3', 'name' => 'C.CSV', 'size' => 3, 'eTag' => 'e3', 'lastModifiedDateTime' => '2026-07-24T03:00:00Z', 'file' => new stdClass()],
                    ],
                ])];
            }

            return [200, [], json_encode([
                'value' => [
                    ['id' => '1', 'name' => 'A.csv', 'size' => 1, 'eTag' => 'e1', 'lastModifiedDateTime' => '2026-07-24T01:00:00Z', 'file' => new stdClass()],
                    ['id' => '2', 'name' => 'B.txt', 'size' => 2, 'eTag' => 'e2', 'lastModifiedDateTime' => '2026-07-24T02:00:00Z', 'file' => new stdClass()],
                    ['id' => 'folder', 'name' => 'Nested', 'folder' => new stdClass()],
                ],
                '@odata.nextLink' => 'https://graph.microsoft.com/v1.0/page2',
            ])];
        };

        $client = new SharePointClient([
            'DRIVE_ID' => 'drive',
            'ACCESS_TOKEN' => 'test-token',
        ], $http);

        $files = $client->listCsvFiles('PaymentBeforePost');

        assert(array_column($files, 'name') === ['A.csv', 'C.CSV']);
        assert(count($calls) === 2);
    },
];
```

- [ ] **Step 2: Run test and verify failure**

Run:

```powershell
php tests/run.php
```

Expected: fails because `SharePointClient` does not exist.

- [ ] **Step 3: Implement SharePointClient with injectable HTTP**

Create `src/SharePoint/SharePointClient.php`:

```php
<?php

namespace App\SharePoint;

use RuntimeException;

final class SharePointClient
{
    private $http;

    public function __construct(private readonly array $env, ?callable $http = null)
    {
        $this->http = $http ?? [$this, 'curlRequest'];
    }

    public static function fromEnv(array $env, ?callable $http = null): self
    {
        $client = new self($env, $http);
        $token = $client->requestAccessToken(
            $env['TENANT_ID'] ?? '',
            $env['CLIENT_ID'] ?? '',
            $env['CLIENT_SECRET'] ?? ''
        );
        $siteId = $client->resolveSiteId($env['SITE_HOST'] ?? '', $env['SITE_PATH'] ?? '', $token);
        $driveId = $client->resolveDriveId($siteId, $env['LIBRARY'] ?? '', $token);

        return new self(array_merge($env, [
            'ACCESS_TOKEN' => $token,
            'SITE_ID' => $siteId,
            'DRIVE_ID' => $driveId,
        ]), $http);
    }

    public function listCsvFiles(string $folderPath): array
    {
        $driveId = $this->env['DRIVE_ID'] ?? null;
        if ($driveId === null) {
            throw new RuntimeException('DRIVE_ID is required');
        }

        $encoded = implode('/', array_map('rawurlencode', explode('/', trim($folderPath, '/'))));
        $url = "https://graph.microsoft.com/v1.0/drives/{$driveId}/root:/{$encoded}:/children";
        $files = [];

        while ($url !== null) {
            [$status, , $body] = ($this->http)('GET', $url, $this->headers());
            if ($status < 200 || $status >= 300) {
                throw new RuntimeException("Graph list children failed with HTTP {$status}");
            }

            $json = json_decode($body, true, flags: JSON_THROW_ON_ERROR);
            foreach ($json['value'] ?? [] as $item) {
                $isFile = array_key_exists('file', $item);
                $isCsv = strcasecmp(pathinfo($item['name'] ?? '', PATHINFO_EXTENSION), 'csv') === 0;
                if ($isFile && $isCsv) {
                    $item['drive_id'] = $driveId;
                    $files[] = $item;
                }
            }
            $url = $json['@odata.nextLink'] ?? null;
        }

        return $files;
    }

    public function resolveFolderItemId(string $folderPath): string
    {
        $driveId = $this->env['DRIVE_ID'] ?? null;
        $encoded = implode('/', array_map('rawurlencode', explode('/', trim($folderPath, '/'))));
        $url = "https://graph.microsoft.com/v1.0/drives/{$driveId}/root:/{$encoded}";
        [$status, , $body] = ($this->http)('GET', $url, $this->headers());
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph resolve folder failed with HTTP {$status}");
        }

        $json = json_decode($body, true, flags: JSON_THROW_ON_ERROR);
        return $json['id'];
    }

    public function downloadItem(string $driveId, string $itemId, string $targetPath): void
    {
        $url = "https://graph.microsoft.com/v1.0/drives/{$driveId}/items/{$itemId}/content";
        [$status, , $body] = ($this->http)('GET', $url, $this->headers());
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph download failed with HTTP {$status}");
        }

        file_put_contents($targetPath, $body);
    }

    public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void
    {
        $url = "https://graph.microsoft.com/v1.0/drives/{$driveId}/items/{$itemId}";
        $body = json_encode(['parentReference' => ['id' => $processedFolderItemId]], JSON_THROW_ON_ERROR);
        [$status] = ($this->http)('PATCH', $url, array_merge($this->headers(), ['Content-Type: application/json']), $body);
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph move failed with HTTP {$status}");
        }
    }

    private function headers(): array
    {
        $token = $this->env['ACCESS_TOKEN'] ?? '';
        return ['Authorization: Bearer ' . $token];
    }

    private function requestAccessToken(string $tenantId, string $clientId, string $clientSecret): string
    {
        if ($tenantId === '' || $clientId === '' || $clientSecret === '') {
            throw new RuntimeException('TENANT_ID, CLIENT_ID, and CLIENT_SECRET are required');
        }

        $url = "https://login.microsoftonline.com/{$tenantId}/oauth2/v2.0/token";
        $body = http_build_query([
            'client_id' => $clientId,
            'client_secret' => $clientSecret,
            'scope' => 'https://graph.microsoft.com/.default',
            'grant_type' => 'client_credentials',
        ]);

        [$status, , $response] = ($this->http)('POST', $url, ['Content-Type: application/x-www-form-urlencoded'], $body);
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph token request failed with HTTP {$status}");
        }

        $json = json_decode($response, true, flags: JSON_THROW_ON_ERROR);
        return $json['access_token'];
    }

    private function resolveSiteId(string $siteHost, string $sitePath, string $token): string
    {
        if ($siteHost === '' || $sitePath === '') {
            throw new RuntimeException('SITE_HOST and SITE_PATH are required');
        }

        $url = 'https://graph.microsoft.com/v1.0/sites/' . rawurlencode($siteHost) . ':' . $sitePath;
        [$status, , $response] = ($this->http)('GET', $url, ['Authorization: Bearer ' . $token]);
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph site resolve failed with HTTP {$status}");
        }

        $json = json_decode($response, true, flags: JSON_THROW_ON_ERROR);
        return $json['id'];
    }

    private function resolveDriveId(string $siteId, string $libraryName, string $token): string
    {
        if ($libraryName === '') {
            throw new RuntimeException('LIBRARY is required');
        }

        $url = "https://graph.microsoft.com/v1.0/sites/{$siteId}/drives";
        [$status, , $response] = ($this->http)('GET', $url, ['Authorization: Bearer ' . $token]);
        if ($status < 200 || $status >= 300) {
            throw new RuntimeException("Graph drive resolve failed with HTTP {$status}");
        }

        $json = json_decode($response, true, flags: JSON_THROW_ON_ERROR);
        foreach ($json['value'] ?? [] as $drive) {
            if (($drive['name'] ?? '') === $libraryName) {
                return $drive['id'];
            }
        }

        throw new RuntimeException("SharePoint library not found: {$libraryName}");
    }

    private function curlRequest(string $method, string $url, array $headers = [], ?string $body = null): array
    {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_HTTPHEADER => $headers,
        ]);
        if ($body !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
        }

        $responseBody = curl_exec($ch);
        if ($responseBody === false) {
            $error = curl_error($ch);
            curl_close($ch);
            throw new RuntimeException($error);
        }
        $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        return [$status, [], $responseBody];
    }
}
```

- [ ] **Step 4: Add test file to runner, run, commit**

Add to `tests/run.php`:

```php
__DIR__ . '/SharePoint/SharePointClientTest.php',
```

Run:

```powershell
php tests/run.php
git add src/SharePoint/SharePointClient.php tests/SharePoint/SharePointClientTest.php tests/run.php
git commit -m "feat: add SharePoint client"
```

Expected: tests pass.

---

### Task 4: Download Queue

**Files:**
- Create: `src/SharePoint/DownloadQueue.php`
- Create: `tests/SharePoint/DownloadQueueTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- Consumes: `App\SharePoint\SharePointClient`
- Consumes: `App\Queue\FileQueueRepository`
- Consumes: `App\Config\AppConfig`
- Produces: `DownloadQueue->run(): void`

- [ ] **Step 1: Write failing DownloadQueue test**

Create `tests/SharePoint/DownloadQueueTest.php`:

```php
<?php

use App\Config\AppConfig;
use App\SharePoint\DownloadQueue;

return [
    'download queue downloads to part validates then moves' => function (): void {
        $root = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'download_queue_' . uniqid('', true);
        mkdir($root . DIRECTORY_SEPARATOR . 'download', 0777, true);

        $_ENV['CSV_FOLDER'] = 'PaymentBeforePost';
        $_ENV['CSV_DOWNLOADED_FOLDER'] = 'PaymentBeforePost_Downloaded';
        $_ENV['CSV_LOCAL_DOWNLOAD_DIR'] = 'download';
        $_ENV['CSV_LOCAL_ARCHIVE_DIR'] = 'archive';
        $_ENV['CSV_LOCAL_ERROR_DIR'] = 'error';
        $_ENV['PIPELINE_LOCK_FILE'] = 'temp/pipeline.lock';

        $config = AppConfig::fromEnv($root);
        $client = new class {
            public array $moved = [];
            public function listCsvFiles(string $folder): array {
                return [[
                    'drive_id' => 'drive',
                    'id' => 'item1',
                    'name' => 'first.csv',
                    'size' => 5,
                    'eTag' => 'etag1',
                    'lastModifiedDateTime' => '2026-07-24T01:00:00Z',
                ]];
            }
            public function resolveFolderItemId(string $folder): string {
                return 'processed-folder-id';
            }
            public function downloadItem(string $driveId, string $itemId, string $targetPath): void {
                file_put_contents($targetPath, '12345');
            }
            public function moveItem(string $driveId, string $itemId, string $processedFolderItemId): void {
                $this->moved[] = [$driveId, $itemId, $processedFolderItemId];
            }
        };
        $repo = new class {
            public int $id = 10;
            public array $downloaded = [];
            public array $moved = [];
            public function upsertDiscovered(array $item, string $sourceFolder, string $processedFolder): int { return $this->id; }
            public function markStatus(int $id, string $status, ?string $error = null): void {}
            public function markDownloaded(int $id, string $localPath, string $sha256): void { $this->downloaded[] = [$id, $localPath, $sha256]; }
            public function markMoved(int $id): void { $this->moved[] = $id; }
        };

        (new DownloadQueue($client, $repo, $config))->run();

        assert(is_file($root . DIRECTORY_SEPARATOR . 'download' . DIRECTORY_SEPARATOR . 'first.csv'));
        assert(!is_file($root . DIRECTORY_SEPARATOR . 'download' . DIRECTORY_SEPARATOR . 'first.csv.part'));
        assert(count($client->moved) === 1);
        assert($repo->moved === [10]);
    },
];
```

- [ ] **Step 2: Run test and verify failure**

Run:

```powershell
php tests/run.php
```

Expected: fails because `DownloadQueue` does not exist.

- [ ] **Step 3: Implement DownloadQueue**

Create `src/SharePoint/DownloadQueue.php`:

```php
<?php

namespace App\SharePoint;

use App\Config\AppConfig;
use RuntimeException;

final class DownloadQueue
{
    public function __construct(
        private readonly object $client,
        private readonly object $repo,
        private readonly AppConfig $config,
    ) {
    }

    public function run(): void
    {
        if (!is_dir($this->config->downloadDir)) {
            mkdir($this->config->downloadDir, 0777, true);
        }

        $processedFolderId = $this->client->resolveFolderItemId($this->config->processedFolder);
        $items = $this->client->listCsvFiles($this->config->sourceFolder);

        usort($items, fn (array $a, array $b): int =>
            strcmp($a['lastModifiedDateTime'] ?? '', $b['lastModifiedDateTime'] ?? '')
            ?: strcmp($a['name'] ?? '', $b['name'] ?? '')
        );

        foreach ($items as $item) {
            $id = $this->repo->upsertDiscovered($item, $this->config->sourceFolder, $this->config->processedFolder);
            $safeName = basename($item['name']);
            $finalPath = $this->config->downloadDir . DIRECTORY_SEPARATOR . $safeName;
            $partPath = $finalPath . '.part';

            try {
                $this->repo->markStatus($id, 'DOWNLOADING');
                if (is_file($partPath)) {
                    unlink($partPath);
                }

                $this->client->downloadItem($item['drive_id'], $item['id'], $partPath);
                $this->validateDownload($partPath, isset($item['size']) ? (int)$item['size'] : null);

                if (is_file($finalPath)) {
                    $finalPath = $this->config->downloadDir . DIRECTORY_SEPARATOR . pathinfo($safeName, PATHINFO_FILENAME) . '_' . $item['id'] . '.csv';
                }

                rename($partPath, $finalPath);
                $sha256 = hash_file('sha256', $finalPath);
                $this->repo->markDownloaded($id, $finalPath, $sha256);

                $this->repo->markStatus($id, 'MOVING');
                $this->client->moveItem($item['drive_id'], $item['id'], $processedFolderId);
                $this->repo->markMoved($id);
            } catch (\Throwable $e) {
                if (is_file($partPath)) {
                    unlink($partPath);
                }
                $this->repo->markStatus($id, 'ERROR', $e->getMessage());
            }
        }
    }

    private function validateDownload(string $path, ?int $expectedSize): void
    {
        if (!is_file($path)) {
            throw new RuntimeException('Downloaded file was not created');
        }
        if ($expectedSize !== null && filesize($path) !== $expectedSize) {
            throw new RuntimeException('Downloaded file size does not match SharePoint size');
        }
    }
}
```

- [ ] **Step 4: Run tests and commit**

Run:

```powershell
php tests/run.php
git add src/SharePoint/DownloadQueue.php tests/SharePoint/DownloadQueueTest.php tests/run.php
git commit -m "feat: add SharePoint download queue"
```

Expected: tests pass.

---

### Task 5: Extract Single-File Importer

**Files:**
- Create: `src/Import/PaymentBeforePostImporter.php`
- Modify: `import/run_import.php`
- Create: `tests/Import/PaymentBeforePostImporterTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- Produces: `PaymentBeforePostImporter->__construct(PDO $pdo, string $archiveDir)`
- Produces: `PaymentBeforePostImporter->isDuplicateHash(string $sha256): bool`
- Produces: `PaymentBeforePostImporter->importFile(string $filePath, ?int $queueId = null): string`
- Returns: archive path string on success.

- [ ] **Step 1: Write failing importer duplicate test**

Create `tests/Import/PaymentBeforePostImporterTest.php`:

```php
<?php

use App\Import\PaymentBeforePostImporter;

return [
    'importer detects duplicate hash from import_files' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('CREATE TABLE import_files (file_hash TEXT NOT NULL, status TEXT NOT NULL)');
        $pdo->exec("INSERT INTO import_files (file_hash, status) VALUES ('abc', 'SUCCESS')");

        $importer = new PaymentBeforePostImporter($pdo, sys_get_temp_dir());

        assert($importer->isDuplicateHash('abc') === true);
        assert($importer->isDuplicateHash('def') === false);
    },
];
```

- [ ] **Step 2: Run test and verify failure**

Run:

```powershell
php tests/run.php
```

Expected: fails because `PaymentBeforePostImporter` does not exist.

- [ ] **Step 3: Implement importer shell with duplicate detection**

Create `src/Import/PaymentBeforePostImporter.php`:

```php
<?php

namespace App\Import;

use PDO;
use RuntimeException;

final class PaymentBeforePostImporter
{
    public function __construct(
        private readonly PDO $pdo,
        private readonly string $archiveDir,
    ) {
    }

    public function isDuplicateHash(string $sha256): bool
    {
        $stmt = $this->pdo->prepare("SELECT COUNT(*) FROM import_files WHERE file_hash = :hash AND status = 'SUCCESS'");
        $stmt->execute([':hash' => $sha256]);

        return (int)$stmt->fetchColumn() > 0;
    }

    public function importFile(string $filePath, ?int $queueId = null): string
    {
        if (!is_file($filePath)) {
            throw new RuntimeException("CSV file not found: {$filePath}");
        }

        if (!is_dir($this->archiveDir)) {
            mkdir($this->archiveDir, 0777, true);
        }

        /*
         * Move the existing import body from import/run_import.php into this method.
         * Replace its newest-file discovery with the provided $filePath.
         * Keep the existing staging/current/history transaction behavior.
         * After a successful transaction, move the local file to archive and return that archive path.
         */
        throw new RuntimeException('PaymentBeforePostImporter import body has not been extracted yet');
    }
}
```

- [ ] **Step 4: Extract current import logic**

In `import/run_import.php`, identify the block that starts after local CSV selection and ends after archive/logging. Move that import body into `PaymentBeforePostImporter::importFile()`.

Required concrete changes inside the moved logic:

```php
$latestFile = $filePath;
$fileName = basename($filePath);
$fileHash = hash_file('sha256', $filePath);
```

Replace final archive copy with move:

```php
$archivePath = rtrim($this->archiveDir, "\\/") . DIRECTORY_SEPARATOR . date('Ymd_His_') . $fileName;
rename($filePath, $archivePath);
return $archivePath;
```

Keep existing database transaction behavior:

```php
$this->pdo->beginTransaction();
try {
    // Existing staging/current/history import statements live here after extraction.
    $this->pdo->commit();
} catch (\Throwable $e) {
    if ($this->pdo->inTransaction()) {
        $this->pdo->rollBack();
    }
    throw $e;
}
```

Modify `import/run_import.php` so it becomes a compatibility entrypoint:

```php
<?php

require __DIR__ . '/run_pipeline.php';
```

- [ ] **Step 5: Remove the temporary exception**

After extraction, remove this line from `PaymentBeforePostImporter::importFile()`:

```php
throw new RuntimeException('PaymentBeforePostImporter import body has not been extracted yet');
```

- [ ] **Step 6: Run syntax checks and tests**

Run:

```powershell
php -l src/Import/PaymentBeforePostImporter.php
php -l import/run_import.php
php tests/run.php
```

Expected: no syntax errors; tests pass.

- [ ] **Step 7: Commit**

Run:

```powershell
git add src/Import/PaymentBeforePostImporter.php import/run_import.php tests/Import/PaymentBeforePostImporterTest.php tests/run.php
git commit -m "refactor: extract single file importer"
```

---

### Task 6: Import Queue and Pipeline Lock

**Files:**
- Create: `src/Import/ImportQueue.php`
- Create: `src/Support/PipelineLock.php`
- Create: `tests/Import/ImportQueueTest.php`
- Create: `tests/Support/PipelineLockTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- Consumes: `FileQueueRepository->findReadyForImport()`
- Consumes: `PaymentBeforePostImporter`
- Produces: `ImportQueue->run(): void`
- Produces: `PipelineLock->run(callable $callback): mixed`

- [ ] **Step 1: Write failing ImportQueue test**

Create `tests/Import/ImportQueueTest.php`:

```php
<?php

use App\Import\ImportQueue;

return [
    'import queue stops after first import error' => function (): void {
        $repo = new class {
            public array $statuses = [];
            public function findReadyForImport(): array {
                return [
                    ['id' => 1, 'local_path' => 'old.csv', 'local_sha256' => 'oldhash'],
                    ['id' => 2, 'local_path' => 'new.csv', 'local_sha256' => 'newhash'],
                ];
            }
            public function markStatus(int $id, string $status, ?string $error = null): void { $this->statuses[] = [$id, $status, $error]; }
            public function markImported(int $id): void { $this->statuses[] = [$id, 'IMPORTED', null]; }
            public function markSkippedDuplicate(int $id, string $sha256): void { $this->statuses[] = [$id, 'SKIPPED_DUPLICATE', null]; }
        };
        $importer = new class {
            public array $called = [];
            public function isDuplicateHash(string $sha256): bool { return false; }
            public function importFile(string $filePath, ?int $queueId = null): string {
                $this->called[] = $filePath;
                throw new RuntimeException('bad csv');
            }
        };

        (new ImportQueue($repo, $importer))->run();

        assert($importer->called === ['old.csv']);
        assert($repo->statuses[0][1] === 'IMPORTING');
        assert($repo->statuses[1][1] === 'IMPORT_ERROR');
    },
];
```

- [ ] **Step 2: Write failing PipelineLock test**

Create `tests/Support/PipelineLockTest.php`:

```php
<?php

use App\Support\PipelineLock;

return [
    'pipeline lock runs callback once and releases file' => function (): void {
        $lockFile = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'pipeline_lock_' . uniqid('', true) . '.lock';
        $lock = new PipelineLock($lockFile);
        $ran = false;

        $result = $lock->run(function () use (&$ran): string {
            $ran = true;
            return 'done';
        });

        assert($result === 'done');
        assert($ran === true);
        assert(!is_file($lockFile));
    },
];
```

- [ ] **Step 3: Implement ImportQueue**

Create `src/Import/ImportQueue.php`:

```php
<?php

namespace App\Import;

final class ImportQueue
{
    public function __construct(
        private readonly object $repo,
        private readonly object $importer,
    ) {
    }

    public function run(): void
    {
        foreach ($this->repo->findReadyForImport() as $row) {
            $id = (int)$row['id'];
            $path = $row['local_path'];
            $sha256 = $row['local_sha256'] ?? (is_file($path) ? hash_file('sha256', $path) : '');

            try {
                if ($sha256 !== '' && $this->importer->isDuplicateHash($sha256)) {
                    $this->repo->markSkippedDuplicate($id, $sha256);
                    continue;
                }

                $this->repo->markStatus($id, 'IMPORTING');
                $this->importer->importFile($path, $id);
                $this->repo->markImported($id);
            } catch (\Throwable $e) {
                $this->repo->markStatus($id, 'IMPORT_ERROR', $e->getMessage());
                break;
            }
        }
    }
}
```

- [ ] **Step 4: Implement PipelineLock**

Create `src/Support/PipelineLock.php`:

```php
<?php

namespace App\Support;

use RuntimeException;

final class PipelineLock
{
    public function __construct(private readonly string $lockFile)
    {
    }

    public function run(callable $callback): mixed
    {
        $dir = dirname($this->lockFile);
        if (!is_dir($dir)) {
            mkdir($dir, 0777, true);
        }

        $handle = fopen($this->lockFile, 'c');
        if ($handle === false) {
            throw new RuntimeException('Unable to open pipeline lock file');
        }

        if (!flock($handle, LOCK_EX | LOCK_NB)) {
            fclose($handle);
            throw new RuntimeException('Pipeline is already running');
        }

        try {
            fwrite($handle, (string)getmypid());
            $result = $callback();
            flock($handle, LOCK_UN);
            fclose($handle);
            unlink($this->lockFile);
            return $result;
        } catch (\Throwable $e) {
            flock($handle, LOCK_UN);
            fclose($handle);
            if (is_file($this->lockFile)) {
                unlink($this->lockFile);
            }
            throw $e;
        }
    }
}
```

- [ ] **Step 5: Run tests and commit**

Add both test files to `tests/run.php`, then run:

```powershell
php tests/run.php
git add src/Import/ImportQueue.php src/Support/PipelineLock.php tests/Import/ImportQueueTest.php tests/Support/PipelineLockTest.php tests/run.php
git commit -m "feat: add import queue and pipeline lock"
```

Expected: tests pass.

---

### Task 7: Pipeline Entrypoint and Scheduler

**Files:**
- Create: `import/run_pipeline.php`
- Modify: `run_import.bat`
- Modify: `install_task_scheduler.ps1`
- Modify: `import/download_csv.php`

**Interfaces:**
- Consumes: `AppConfig`, `Logger`, `PipelineLock`, `SharePointClient`, `DownloadQueue`, `ImportQueue`, `PaymentBeforePostImporter`
- Produces: CLI command `php import/run_pipeline.php`

- [ ] **Step 1: Create pipeline entrypoint**

Create `import/run_pipeline.php`:

```php
<?php

use App\Config\AppConfig;
use App\Import\ImportQueue;
use App\Import\PaymentBeforePostImporter;
use App\Queue\FileQueueRepository;
use App\SharePoint\DownloadQueue;
use App\SharePoint\SharePointClient;
use App\Support\Logger;
use App\Support\PipelineLock;
use Dotenv\Dotenv;

require dirname(__DIR__) . '/vendor/autoload.php';

$rootDir = dirname(__DIR__);
$dotenv = Dotenv::createImmutable($rootDir . '/config');
$dotenv->safeLoad();

$config = AppConfig::fromEnv($rootDir);
$logger = new Logger($rootDir . '/logs/import.log');

$pdo = new PDO(
    sprintf('mysql:host=%s;dbname=%s;charset=utf8mb4', $_ENV['DB_HOST'], $_ENV['DB_NAME']),
    $_ENV['DB_USER'],
    $_ENV['DB_PASS'],
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);

$lock = new PipelineLock($config->lockFile);

$lock->run(function () use ($config, $logger, $pdo): void {
    $logger->info('Pipeline started');

    $repo = new FileQueueRepository($pdo);
    $client = SharePointClient::fromEnv($_ENV);
    $downloadQueue = new DownloadQueue($client, $repo, $config);
    $importer = new PaymentBeforePostImporter($pdo, $config->archiveDir);
    $importQueue = new ImportQueue($repo, $importer);

    $downloadQueue->run();
    $importQueue->run();

    $logger->info('Pipeline finished');
});
```

- [ ] **Step 2: Update batch file**

Replace `run_import.bat` contents with:

```bat
@echo off
cd /d C:\xampp\htdocs\D365_Sharedpoint_csv_import
php import\run_pipeline.php >> logs\import.log 2>&1
```

- [ ] **Step 3: Update deprecated download script**

Replace `import/download_csv.php` contents with:

```php
<?php

require __DIR__ . '/run_pipeline.php';
```

- [ ] **Step 4: Syntax check**

Run:

```powershell
php -l import/run_pipeline.php
php -l import/download_csv.php
php -l import/run_import.php
```

Expected: no syntax errors.

- [ ] **Step 5: Commit**

Run:

```powershell
git add import/run_pipeline.php import/download_csv.php import/run_import.php run_import.bat install_task_scheduler.ps1
git commit -m "feat: add queue pipeline entrypoint"
```

---

### Task 8: Monitor Queue Visibility

**Files:**
- Modify: `monitor/index.php`
- Create: `tests/Monitor/MonitorQueryTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- Produces SQL queries for queue status counts and oldest error row.

- [ ] **Step 1: Add queue queries to monitor**

In `monitor/index.php`, after the existing `import_files` summary queries, add:

```php
$queueStatusStmt = $pdo->query("
    SELECT status, COUNT(*) AS total
    FROM sharepoint_file_queue
    GROUP BY status
    ORDER BY status
");
$queueStatusCounts = $queueStatusStmt->fetchAll(PDO::FETCH_ASSOC);

$queueLatestStmt = $pdo->query("
    SELECT file_name, status, attempt_count, last_error, downloaded_at, moved_at, imported_at, updated_at
    FROM sharepoint_file_queue
    ORDER BY updated_at DESC
    LIMIT 20
");
$queueLatestFiles = $queueLatestStmt->fetchAll(PDO::FETCH_ASSOC);

$oldestImportErrorStmt = $pdo->query("
    SELECT file_name, last_error, updated_at
    FROM sharepoint_file_queue
    WHERE status = 'IMPORT_ERROR'
    ORDER BY sharepoint_last_modified_at ASC, id ASC
    LIMIT 1
");
$oldestImportError = $oldestImportErrorStmt->fetch(PDO::FETCH_ASSOC);
```

Render a compact section:

```php
<?php if ($oldestImportError): ?>
    <div class="alert alert-danger">
        Oldest import error: <?= htmlspecialchars($oldestImportError['file_name']) ?>
        <?= htmlspecialchars($oldestImportError['last_error'] ?? '') ?>
    </div>
<?php endif; ?>
```

- [ ] **Step 2: Write monitor query smoke test**

Create `tests/Monitor/MonitorQueryTest.php`:

```php
<?php

return [
    'monitor queue queries run against queue schema' => function (): void {
        $pdo = new PDO('sqlite::memory:');
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('CREATE TABLE sharepoint_file_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_name TEXT,
            status TEXT,
            attempt_count INTEGER DEFAULT 0,
            last_error TEXT,
            downloaded_at TEXT,
            moved_at TEXT,
            imported_at TEXT,
            sharepoint_last_modified_at TEXT,
            updated_at TEXT
        )');
        $pdo->exec("INSERT INTO sharepoint_file_queue (file_name, status, last_error, sharepoint_last_modified_at, updated_at) VALUES ('bad.csv', 'IMPORT_ERROR', 'bad row', '2026-07-24 01:00:00', '2026-07-24 02:00:00')");

        $counts = $pdo->query("SELECT status, COUNT(*) AS total FROM sharepoint_file_queue GROUP BY status ORDER BY status")->fetchAll(PDO::FETCH_ASSOC);
        $oldest = $pdo->query("SELECT file_name, last_error, updated_at FROM sharepoint_file_queue WHERE status = 'IMPORT_ERROR' ORDER BY sharepoint_last_modified_at ASC, id ASC LIMIT 1")->fetch(PDO::FETCH_ASSOC);

        assert($counts[0]['status'] === 'IMPORT_ERROR');
        assert($oldest['file_name'] === 'bad.csv');
    },
];
```

- [ ] **Step 3: Run tests and commit**

Run:

```powershell
php tests/run.php
git add monitor/index.php tests/Monitor/MonitorQueryTest.php tests/run.php
git commit -m "feat: show SharePoint queue in monitor"
```

Expected: tests pass and monitor page loads locally.

---

### Task 9: Documentation and Staging Verification

**Files:**
- Modify: `Readme.txt`
- Modify: `docs/superpowers/specs/2026-07-24-sharepoint-csv-queue-design.md` only if implementation reveals a real design adjustment.

**Interfaces:**
- Produces: operator instructions for migration, config, scheduler, and recovery.

- [ ] **Step 1: Document migration**

Add to `Readme.txt`:

```text
Database migration:
Run database/migrations/001_create_sharepoint_file_queue.sql before enabling the new scheduler.
```

- [ ] **Step 2: Document folders**

Add:

```text
SharePoint folders:
- Source: PaymentBeforePost
- Processed: PaymentBeforePost_Downloaded

Local folders:
- download/: verified downloaded CSVs waiting for import
- archive/: successfully imported CSVs
- error/: operator-controlled error storage
- logs/: runtime logs
```

- [ ] **Step 3: Document recovery rules**

Add:

```text
Recovery:
- DOWNLOADING: remove stale .part file and retry.
- DOWNLOADED: retry SharePoint move.
- MOVED: ready for local import.
- IMPORT_ERROR: fix the CSV or data issue before newer files are imported.
- SKIPPED_DUPLICATE: file hash already imported successfully.
```

- [ ] **Step 4: Run final verification**

Run:

```powershell
php tests/run.php
php -l import/run_pipeline.php
php -l src/SharePoint/SharePointClient.php
php -l src/SharePoint/DownloadQueue.php
php -l src/Import/ImportQueue.php
php -l src/Import/PaymentBeforePostImporter.php
git status --short
```

Expected: tests pass, syntax checks pass, only intentional docs changes before commit.

- [ ] **Step 5: Commit**

Run:

```powershell
git add Readme.txt docs/superpowers/specs/2026-07-24-sharepoint-csv-queue-design.md
git commit -m "docs: document SharePoint queue operations"
```

---

## Final Acceptance Checklist

- [ ] `config/.env` is still present locally and not tracked by git.
- [ ] `git ls-files config/.env` returns no output.
- [ ] `git log --all -- config/.env` returns no output.
- [ ] `php tests/run.php` passes.
- [ ] `php import/run_pipeline.php` runs in staging without overlapping process.
- [ ] Three CSV files in `PaymentBeforePost` are downloaded locally.
- [ ] The same three SharePoint files are moved to `PaymentBeforePost_Downloaded`.
- [ ] One non-CSV file in `PaymentBeforePost` remains ignored.
- [ ] Successful imports move local files from `download/` to `archive/`.
- [ ] A bad older CSV results in `IMPORT_ERROR` and newer CSVs remain unimported.
- [ ] `monitor/index.php` shows queue statuses and the oldest import error.
- [ ] No logs contain `CLIENT_SECRET`, access token, database password, or preauthenticated Graph download URL.

## Execution Notes

- Run the database migration before enabling the new scheduler.
- Rotate `CLIENT_SECRET` if it was ever sent to GitHub during a rejected push attempt.
- The Microsoft Graph app registration needs write/move permission for the target SharePoint drive or site before staging verification.
- Do not push `download/`, `archive/`, `logs/`, `vendor/`, or `config/.env`.
