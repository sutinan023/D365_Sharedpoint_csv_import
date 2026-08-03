# Expand Staging Invoice Number Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ขยาย `stg_payment_before_post.invoice_number` เป็น `VARCHAR(255)` ทดสอบไฟล์จริงบน UAT และ retry Production queue ID `44` อย่างมี guard โดยไม่ลบ business data

**Architecture:** ใช้ migration ลำดับ `006` แบบ forward-only ให้ staging ตรงกับตารางหลัก เพิ่มคำสั่ง UAT migration ที่ใช้ `MigrationRunner` เดิม และเพิ่ม recovery service ที่ reset เฉพาะ queue record ซึ่งผ่าน filename/hash/status/zero-row preconditions เท่านั้น Production ยังคงผ่าน checkpoint/rehearsal flow เดิม

**Tech Stack:** PHP 8.2, PDO/MySQL, PowerShell 5.1, existing `MigrationRunner`, existing Thai release wizard

## Global Constraints

- Production task `D365 SharePoint CSV Import [PROD]` ต้องคง Disabled จนกว่า migration, queue reset และ verification พร้อม
- Target file: `GLB_20260803101939_before_post.csv`
- Target queue: ID `44`, SHA-256 `3605a718e95097fe1c90e3d7892a20d23f5b7b3d8c48050e92be7ff146039cd8`
- เปลี่ยนเฉพาะ `stg_payment_before_post.invoice_number` จาก `VARCHAR(100)` เป็น `VARCHAR(255) NULL`
- ห้าม truncate, cast เป็นตัวเลข, ลบ `payment_before_post`, ลบ history หรือลบ queue record
- UAT ต้องผ่านด้วยไฟล์จริงก่อน Production
- Production migration ต้องใช้ checkpoint/rehearsal และบันทึก `schema_migrations`
- Queue reset ต้อง fail closed ถ้า ID, filename, hash, status หรือ zero-row evidence ไม่ตรง

---

### Task 1: Migration และ contract tests

**Files:**
- Create: `database/migrations/006_expand_stg_payment_before_post_invoice_number.sql`
- Create: `tests/Database/StagingInvoiceNumberMigrationContractTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- Consumes: MySQL table `stg_payment_before_post`
- Produces: ordered migration `006_expand_stg_payment_before_post_invoice_number.sql`

- [ ] **Step 1: เขียน failing contract test**

Create `tests/Database/StagingInvoiceNumberMigrationContractTest.php`:

```php
<?php

return [
    'staging invoice migration widens text without destructive SQL' => function (): void {
        $path = dirname(__DIR__, 2) . '/database/migrations/006_expand_stg_payment_before_post_invoice_number.sql';
        assert(is_file($path), 'Migration 006 is missing.');
        $sql = (string) file_get_contents($path);
        assert(preg_match('/ALTER\s+TABLE\s+`?stg_payment_before_post`?/i', $sql) === 1);
        assert(preg_match('/MODIFY\s+(?:COLUMN\s+)?`?invoice_number`?\s+VARCHAR\s*\(\s*255\s*\)\s+NULL/i', $sql) === 1);
        assert(preg_match('/\b(DROP|DELETE|TRUNCATE)\b/i', $sql) === 0);
        assert(preg_match('/ALTER\s+TABLE\s+`?payment_before_post`?/i', $sql) === 0);
        assert(preg_match('/D365_finance(?:_prod)?\s*\./i', $sql) === 0);
    },
];
```

Add after `MigrationRunnerTest.php` in `tests/run.php`:

```php
__DIR__ . '/Database/StagingInvoiceNumberMigrationContractTest.php',
```

- [ ] **Step 2: รัน RED**

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: FAIL with `Migration 006 is missing.`

- [ ] **Step 3: เพิ่ม minimal migration**

Create `database/migrations/006_expand_stg_payment_before_post_invoice_number.sql`:

```sql
ALTER TABLE `stg_payment_before_post`
    MODIFY COLUMN `invoice_number` VARCHAR(255) NULL;
```

- [ ] **Step 4: รัน GREEN และ manifest test**

```powershell
C:\xampp\php\php.exe tests\run.php
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_manifest.ps1
```

Expected: PHP suite และ release manifest checks ผ่าน; manifest เรียง migration `006` หลัง `005`

- [ ] **Step 5: Commit**

```powershell
git add database/migrations/006_expand_stg_payment_before_post_invoice_number.sql tests/Database/StagingInvoiceNumberMigrationContractTest.php tests/run.php
git commit -m "fix: widen staging invoice number"
```

---

### Task 2: UAT-only migration command

**Files:**
- Create: `tools/apply_uat_migrations.php`
- Create: `tests/Database/UatMigrationToolContractTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- Consumes: UAT `.env`, `MIGRATION_DB_USER`, `MIGRATION_DB_PASS`, migration directory
- Produces: JSON `{environment,database,release,applied}` and `schema_migrations` records

- [ ] **Step 1: เขียน failing source contract**

Create `tests/Database/UatMigrationToolContractTest.php`:

```php
<?php

return [
    'uat migration command is environment locked and uses migration runner' => function (): void {
        $path = dirname(__DIR__, 2) . '/tools/apply_uat_migrations.php';
        assert(is_file($path), 'UAT migration tool is missing.');
        $source = (string) file_get_contents($path);
        foreach (['EnvironmentGuard::validate', "APP_ENV'] !== 'UAT'", "DB_NAME'] !== 'D365_finance'", 'MIGRATION_DB_USER', 'MIGRATION_DB_PASS', 'MigrationRunner', 'applyDirectory'] as $required) {
            assert(str_contains($source, $required), "Missing UAT migration guard: {$required}");
        }
        assert(!str_contains($source, "DB_PASS']"));
        assert(!str_contains($source, 'D365_finance_prod'));
    },
];
```

Add it to `tests/run.php` immediately after the staging migration contract.

- [ ] **Step 2: รัน RED**

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: FAIL with `UAT migration tool is missing.`

- [ ] **Step 3: Implement UAT-only command**

Create `tools/apply_uat_migrations.php` with exactly these required CLI options: `--apply`, `--project`, `--directory`, `--release`, and `--applied-by`. Reject the command with exit code `2` if any option is absent. Load `config/.env`, call `EnvironmentGuard::validate($_ENV, $rootDir, true)`, require exact `APP_ENV=UAT` and `DB_NAME=D365_finance`, connect only with `MIGRATION_DB_USER/MIGRATION_DB_PASS`, verify `SELECT DATABASE()` equals `D365_finance`, then call:

```php
$applied = (new MigrationRunner($pdo))->applyDirectory(
    (string) $options['project'],
    (string) $options['directory'],
    (string) $options['release'],
    (string) $options['applied-by'],
);
```

The tool must reject Production and must never print credentials.

- [ ] **Step 4: รัน GREEN**

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: all PHP tests pass.

- [ ] **Step 5: Commit**

```powershell
git add tools/apply_uat_migrations.php tests/Database/UatMigrationToolContractTest.php tests/run.php
git commit -m "feat: add guarded UAT migration command"
```

---

### Task 3: Guarded failed-import retry

**Files:**
- Create: `src/Import/FailedImportRetry.php`
- Create: `tools/retry_failed_import.php`
- Create: `tests/Import/FailedImportRetryTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- Produces: `FailedImportRetry::retry(int $id, string $fileName, string $sha256): array`
- Output: `['id'=>44,'old_status'=>'IMPORT_ERROR','new_status'=>'MOVED','sha256'=>'3605a718e95097fe1c90e3d7892a20d23f5b7b3d8c48050e92be7ff146039cd8']`

- [ ] **Step 1: เขียน failing behavior tests**

Create SQLite fixtures with only the columns read or written by the service:

```sql
CREATE TABLE sharepoint_file_queue (
    id INTEGER PRIMARY KEY, file_name TEXT, local_sha256 TEXT, status TEXT,
    last_error TEXT, import_started_at TEXT, imported_at TEXT, updated_at TEXT
);
CREATE TABLE import_files (source_file_name TEXT, file_hash TEXT, status TEXT);
CREATE TABLE payment_before_post (source_file_name TEXT, file_hash TEXT);
CREATE TABLE stg_payment_before_post (source_file_name TEXT, file_hash TEXT);
CREATE TABLE payment_before_post_history (source_file_name TEXT);
```

Insert queue ID `44` with the exact filename/hash and `IMPORT_ERROR`, plus one `import_files` row with the same filename/hash and `ERROR`. Test the successful transition:

```php
$result = (new FailedImportRetry($pdo))->retry(44, $fileName, $hash);
assert($result['new_status'] === 'MOVED');
assert($pdo->query('SELECT status FROM sharepoint_file_queue WHERE id = 44')->fetchColumn() === 'MOVED');
```

Add parameterized failure cases. For every case, assert that `retry()` throws and queue ID `44` remains `IMPORT_ERROR`:

- requested ID, filename, or SHA-256 differs from the stored queue row
- queue status is not `IMPORT_ERROR` or `imported_at` is non-null
- no matching `import_files` row exists, or its status is not `ERROR`
- `payment_before_post` contains the exact filename/hash
- `stg_payment_before_post` contains the exact filename/hash
- `payment_before_post_history` contains the exact filename

- [ ] **Step 2: รัน RED**

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: FAIL because `App\Import\FailedImportRetry` does not exist.

- [ ] **Step 3: Implement minimal transactional guard**

`FailedImportRetry::retry()` must begin a transaction, read queue ID, validate exact filename/hash/`IMPORT_ERROR`/`imported_at IS NULL`, require matching `import_files.status=ERROR`, query all three zero-row conditions, then execute one conditional update:

```sql
UPDATE sharepoint_file_queue
SET status = 'MOVED', last_error = NULL, import_started_at = NULL, updated_at = CURRENT_TIMESTAMP
WHERE id = :id
  AND file_name = :file_name
  AND local_sha256 = :sha256
  AND status = 'IMPORT_ERROR'
  AND imported_at IS NULL
```

Require `rowCount() === 1`, commit, and return the transition. Any failure rolls back.

`tools/retry_failed_import.php` must load `config/.env`, call `EnvironmentGuard::validate`, require all four options `--apply --id --file --sha256`, require exact `APP_ENV=PRODUCTION` and `DB_NAME=D365_finance_prod`, connect with `DB_USER/DB_PASS`, verify `SELECT DATABASE()` equals `D365_finance_prod`, invoke the service, and emit only the JSON transition. Missing options exit `2`; a failed guard exits nonzero without changing the queue or printing secrets.

- [ ] **Step 4: รัน GREEN และ full suite**

```powershell
C:\xampp\php\php.exe tests\run.php
Get-ChildItem tests -Filter 'test_*.ps1' | Sort-Object Name | ForEach-Object {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" }
}
```

Expected: all PHP and PowerShell tests pass.

- [ ] **Step 5: Commit**

```powershell
git add src/Import/FailedImportRetry.php tools/retry_failed_import.php tests/Import/FailedImportRetryTest.php tests/run.php
git commit -m "feat: retry failed imports with strict guards"
```

---

### Task 4: UAT, Production migration, retry และเปิด task คืน

**Files:**
- Deploy release: `2026-08-03.2`
- UAT root: `\\100.1.1.166\htdocs\uat\D365_Sharedpoint_csv_import`
- Production root: `\\100.1.1.166\htdocs\prod\D365_Sharedpoint_csv_import`

**Interfaces:**
- Consumes: committed release, exact CSV/hash/queue ID, existing migration wizard
- Produces: applied migration in both environments and queue ID `44` imported successfully

- [ ] **Step 1: Verify release preconditions**

Confirm all three repositories are clean, Production SharePoint task is Disabled, queue ID `44` remains `IMPORT_ERROR`, and zero rows exist for the exact hash in main/staging/history.

- [ ] **Step 2: Deploy UAT release `2026-08-03.2`**

Run `release.ps1`, choose menu `1`, and answer `Y`. Then update UAT `APP_RELEASE` with the existing guarded updater:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\update_app_release.ps1 `
  -Environment UAT `
  -ReleaseId 2026-08-03.2 `
  -EnvironmentRoot '\\100.1.1.166\c$\xampp\htdocs\uat' `
  -AuditRoot '\\100.1.1.166\c$\xampp\backups\d365' `
  -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-08-03.2'
```

- [ ] **Step 3: Apply migration on UAT**

On server `100.1.1.166`:

```powershell
C:\xampp\php\php.exe C:\xampp\htdocs\uat\D365_Sharedpoint_csv_import\tools\apply_uat_migrations.php `
  --apply `
  --project=D365_Sharedpoint_csv_import `
  --directory=C:\xampp\htdocs\uat\D365_Sharedpoint_csv_import\database\migrations `
  --release=2026-08-03.2 `
  --applied-by=$env:USERNAME
```

Expected: JSON `applied` contains exactly `006_expand_stg_payment_before_post_invoice_number.sql`; a second invocation returns `applied: []`.

- [ ] **Step 4: Test exact CSV on UAT**

Human step: upload `D:\Downloads\GLB_20260803101939_before_post.csv` to the UAT SharePoint source folder only. Verify its SHA-256 locally before upload:

```powershell
(Get-FileHash -Algorithm SHA256 -LiteralPath 'D:\Downloads\GLB_20260803101939_before_post.csv').Hash.ToLowerInvariant()
```

Expected: `3605a718e95097fe1c90e3d7892a20d23f5b7b3d8c48050e92be7ff146039cd8`.

Run the UAT scheduled task once:

```powershell
schtasks /Run /S 100.1.1.166 /TN "D365 SharePoint CSV Import [UAT]"
```

Confirm the exact UAT queue row becomes `IMPORTED`, `import_files.status` becomes `SUCCESS`, two `invoice_number` values have `CHAR_LENGTH(invoice_number)=129`, and no Production row count changes. Record UAT main/staging/import counts before and after.

- [ ] **Step 5: Promote the same release to Production**

Run `release.ps1`, choose menu `2`, approve UAT/Production, and follow the existing Migration checkpoint/rehearsal prompts. Migration output must apply only `006_expand_stg_payment_before_post_invoice_number.sql`.

The current wizard does not update deployed `APP_RELEASE` automatically. After its file copy completes and it stops at the known config-guard message, run the guarded updater once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\update_app_release.ps1 `
  -Environment Production `
  -ReleaseId 2026-08-03.2 `
  -EnvironmentRoot '\\100.1.1.166\c$\xampp\htdocs\prod' `
  -AuditRoot '\\100.1.1.166\c$\xampp\backups\d365' `
  -ApprovalToken 'UPDATE PRODUCTION APP_RELEASE 2026-08-03.2'
```

Run each deployed `tools/check_config.php` with `C:\xampp\php\php.exe`, then use release menu `3` to confirm code differences are zero. Verify Production staging and main columns are both `VARCHAR(255)` and `schema_migrations` records migration `006` as `APPLIED` for release `2026-08-03.2`.

- [ ] **Step 6: Reset only queue ID `44`**

On server `100.1.1.166`, run the deployed retry tool:

```powershell
C:\xampp\php\php.exe C:\xampp\htdocs\prod\D365_Sharedpoint_csv_import\tools\retry_failed_import.php `
  --apply `
  --id=44 `
  --file=GLB_20260803101939_before_post.csv `
  --sha256=3605a718e95097fe1c90e3d7892a20d23f5b7b3d8c48050e92be7ff146039cd8
```

Expected: JSON transition `IMPORT_ERROR -> MOVED`. No other queue row changes.

- [ ] **Step 7: Enable task and verify recovery**

Enable `D365 SharePoint CSV Import [PROD]` and run it once:

```powershell
schtasks /Change /S 100.1.1.166 /TN "D365 SharePoint CSV Import [PROD]" /ENABLE
schtasks /Run /S 100.1.1.166 /TN "D365 SharePoint CSV Import [PROD]"
```

Then verify:

- queue ID `44` becomes `IMPORTED`
- `import_files` for exact hash becomes `SUCCESS`
- no truncation and invoice length 129 is preserved
- backlog proceeds in SharePoint modified-time order
- task last result is `0`
- monitor no longer reports queue ID `44` as oldest blocker

- [ ] **Step 8: Final verification**

Run release menu `3`; expect UAT/Production code differences `0` for all projects. Run config guards, compare schema, record final counts, and verify Production task is Enabled. Do not delete the queue or import audit rows.

---

## Rollback / stop conditions

- Before Production apply: stop and keep task Disabled if UAT file test fails
- After schema widening: use forward fix; do not shrink the column while 129-character values may exist
- Before queue reset: any precondition mismatch stops without data changes
- After queue reset: if import fails, disable task again and preserve the new error; do not delete rows manually
