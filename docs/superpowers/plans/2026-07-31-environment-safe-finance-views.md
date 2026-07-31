# Environment-safe Finance Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add environment-safe Finance views to release `2026-07-31.9`, prove them on UAT, and stop before Production mutation.

**Architecture:** Two ordered, forward-only MySQL migrations each own one view and use unqualified table references plus `SQL SECURITY INVOKER`. Static contract tests prevent environment database qualifiers from entering the SQL, while real UAT migration and smoke tests prove MySQL compatibility and view behavior. The release manifest generator is updated under test so the immutable manifest includes migrations 004 and 005.

**Tech Stack:** PHP 8.2, MySQL/MariaDB, PDO, PowerShell, Git, the existing custom PHP test runner and deployment scripts.

## Global Constraints

- Release ID is exactly `2026-07-31.9`.
- Never hard-code `D365_finance` or `D365_finance_prod` as a schema qualifier in either view migration.
- Use `CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY INVOKER VIEW`.
- Keep one view per migration file so ledger failure is isolated.
- Do not deploy Production code, create Production `.env`, apply Production migrations, redirect legacy URLs, or enable Production tasks.
- Preserve the immutable `2026-07-31.8` manifest and receipts.
- Do not touch user-owned untracked files in `C:\xampp\htdocs\finance_report`.

---

### Task 1: Add migration contract tests and environment-safe views

**Files:**
- Create: `tests/Database/FinanceViewMigrationContractTest.php`
- Modify: `tests/run.php`
- Create: `database/migrations/004_create_vw_import_report.sql`
- Create: `database/migrations/005_create_v_tbpayin_from_payment_outbound.sql`

**Interfaces:**
- Consumes: migration 003's nullable `stg_received_outbound.effective_date`, plus existing staging, payment outbound, and payment mail tables.
- Produces: two contract tests plus `vw_import_report` and `v_tbpayin_from_payment_outbound` in whichever database the migration connection selected.

- [ ] **Step 1: Install the committed PHP dependencies in the worktree**

Run:

```powershell
C:\composer\composer.bat install --no-interaction --prefer-dist --no-progress
```

Expected: `vendor/autoload.php` exists and `git status --porcelain --untracked-files=all` remains clean because runtime dependencies are excluded from Git.

- [ ] **Step 2: Create the contract test**

Create `tests/Database/FinanceViewMigrationContractTest.php` with:

```php
<?php

$readMigration = static function (string $name): string {
    $path = dirname(__DIR__, 2) . '/database/migrations/' . $name;
    if (!is_file($path)) {
        throw new RuntimeException("Migration missing: {$name}");
    }
    $sql = file_get_contents($path);
    if ($sql === false || trim($sql) === '') {
        throw new RuntimeException("Migration unreadable: {$name}");
    }
    return $sql;
};

$assertEnvironmentSafe = static function (string $sql, string $view): void {
    assert(stripos($sql, 'CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY INVOKER VIEW `' . $view . '`') !== false);
    assert(preg_match('/`?D365_finance(?:_prod)?`?\s*\./i', $sql) === 0);
    assert(stripos($sql, 'SQL SECURITY DEFINER') === false);
};

return [
    'vw import report migration is environment safe' => function () use ($readMigration, $assertEnvironmentSafe): void {
        $sql = $readMigration('004_create_vw_import_report.sql');
        $assertEnvironmentSafe($sql, 'vw_import_report');
        foreach (['`stg_payment_outbound`', '`stg_received_outbound`', '`effective_date`', '`source_type`', 'UNION ALL'] as $required) {
            assert(stripos($sql, $required) !== false);
        }
    },
    'payment advice migration is environment safe' => function () use ($readMigration, $assertEnvironmentSafe): void {
        $sql = $readMigration('005_create_v_tbpayin_from_payment_outbound.sql');
        $assertEnvironmentSafe($sql, 'v_tbpayin_from_payment_outbound');
        foreach (['`payment_outbound`', '`payment_mail_log`', '`fee_total`', '`tax_total`', '`sent_at`', '`recid`'] as $required) {
            assert(stripos($sql, $required) !== false);
        }
    },
];
```

- [ ] **Step 3: Register the contract test**

Add this entry after `MigrationRunnerTest.php` in `tests/run.php`:

```php
    __DIR__ . '/Database/FinanceViewMigrationContractTest.php',
```

- [ ] **Step 4: Run the tests and verify RED**

Run:

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: FAIL with `Migration missing: 004_create_vw_import_report.sql`. The failure must be caused by the absent production migration, not a PHP syntax error.

---

- [ ] **Step 5: Add migration 004 only**

Create `database/migrations/004_create_vw_import_report.sql`:

```sql
CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY INVOKER VIEW `vw_import_report` AS
SELECT
    p.`id` AS `no`, p.`bank_account_code`, p.`transaction_date`, p.`effective_date`,
    p.`cashflow`, p.`journal_batch`, p.`voucher_number`, p.`description`, p.`type`,
    p.`vendor_account` AS `account_no`, p.`vendor_name` AS `account_name`,
    p.`email_address`, p.`purchase_order` AS `order_no`, p.`invoice_number`,
    p.`vendor_bank_account_code`, p.`vendor_bank_account_number`,
    p.`bank_transaction_type`, p.`method_of_payment`, p.`invoice_amount`, p.`fee`,
    p.`withholding_tax_amount`, p.`total_amount`, 'PAYMENT_OUTBOUND' AS `source_type`
FROM `stg_payment_outbound` AS p
UNION ALL
SELECT
    r.`id` AS `no`, r.`bank_account_code`, r.`transaction_date`, r.`effective_date`,
    r.`cashflow`, r.`journal_batch`, r.`voucher_number`, r.`description`, r.`type`,
    r.`customer_account` AS `account_no`, r.`customer_name` AS `account_name`,
    r.`email_address`, r.`sales_order` AS `order_no`, r.`invoice_number`,
    r.`vendor_bank_account_code`, r.`vendor_bank_account_number`,
    r.`bank_transaction_type`, r.`method_of_payment`, r.`invoice_amount`, r.`fee`,
    r.`withholding_tax_amount`, r.`total_amount`, 'RECEIVED_OUTBOUND' AS `source_type`
FROM `stg_received_outbound` AS r;
```

- [ ] **Step 6: Run the tests and verify the second RED boundary**

Run `C:\xampp\php\php.exe tests\run.php`.

Expected: the 004 contract passes, then the suite fails with `Migration missing: 005_create_v_tbpayin_from_payment_outbound.sql`.

- [ ] **Step 7: Add migration 005**

Create `database/migrations/005_create_v_tbpayin_from_payment_outbound.sql`:

```sql
CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY INVOKER VIEW `v_tbpayin_from_payment_outbound` AS
SELECT
    UPPER(COALESCE(po.`company_id`, '')) AS `comp`,
    COALESCE(po.`eft_file_name`, '') AS `bulk`,
    COALESCE(po.`vendor_account`, '') AS `cust_code`,
    COALESCE(po.`vendor_name`, '') AS `cust_name`,
    COALESCE(po.`invoice_number`, '') AS `invoice`,
    COALESCE(po.`voucher_number`, '') AS `pv_no`,
    COALESCE(po.`purchase_order`, '') AS `po_no`,
    COALESCE(po.`effective_date`, po.`transaction_date`) AS `pay_date`,
    SUBSTRING_INDEX(COALESCE(po.`vendor_bank_account_code`, ''), '-', 1) AS `bank_code`,
    SUBSTRING_INDEX(COALESCE(po.`vendor_bank_account_code`, ''), '-', 1) AS `bank`,
    COALESCE(po.`vendor_bank_account_number`, '') AS `account`,
    COALESCE(po.`email_address`, '') AS `email`,
    COALESCE(po.`invoice_amount`, 0) AS `amount`,
    COALESCE(grp.`fee_total`, 0) AS `fee`,
    COALESCE(po.`withholding_tax_amount`, 0) AS `tax`,
    COALESCE(grp.`total_amount`, 0) AS `total`,
    CASE WHEN sent.`sent_at` IS NULL THEN '' ELSE '1' END AS `flag`,
    sent.`sent_at` AS `senddate`,
    COALESCE(grp.`tax_total`, 0) AS `tax1`,
    COALESCE(po.`description`, '') AS `detail`,
    CAST(po.`id` AS CHAR CHARACTER SET utf8) AS `recid`
FROM `payment_outbound` AS po
LEFT JOIN (
    SELECT
        UPPER(COALESCE(`company_id`, '')) AS `comp`,
        COALESCE(`eft_file_name`, '') AS `bulk`,
        COALESCE(`vendor_account`, '') AS `cust_code`,
        SUM(COALESCE(`fee`, 0)) AS `fee_total`,
        SUM(COALESCE(`withholding_tax_amount`, 0)) AS `tax_total`,
        SUM(COALESCE(`total_amount`, 0)) AS `total_amount`
    FROM `payment_outbound`
    WHERE `eft_file_name` IS NOT NULL AND `eft_file_name` <> ''
    GROUP BY
        UPPER(COALESCE(`company_id`, '')),
        COALESCE(`eft_file_name`, ''),
        COALESCE(`vendor_account`, '')
) AS grp
    ON grp.`comp` = UPPER(COALESCE(po.`company_id`, ''))
   AND grp.`bulk` = COALESCE(po.`eft_file_name`, '')
   AND grp.`cust_code` = COALESCE(po.`vendor_account`, '')
LEFT JOIN (
    SELECT `comp`, `bulk`, `cust_code`, MAX(`sent_at`) AS `sent_at`
    FROM `payment_mail_log`
    WHERE `status` = 'sent'
    GROUP BY `comp`, `bulk`, `cust_code`
) AS sent
    ON sent.`comp` = UPPER(COALESCE(po.`company_id`, ''))
   AND sent.`bulk` = COALESCE(po.`eft_file_name`, '')
   AND sent.`cust_code` = COALESCE(po.`vendor_account`, '')
WHERE po.`eft_file_name` IS NOT NULL AND po.`eft_file_name` <> '';
```

- [ ] **Step 8: Run the focused and full PHP tests and verify GREEN**

Run:

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: all PHP tests pass, including the two new finance view migration contracts.

- [ ] **Step 9: Commit the migrations and contract tests**

```powershell
git add tests/Database/FinanceViewMigrationContractTest.php tests/run.php database/migrations/004_create_vw_import_report.sql database/migrations/005_create_v_tbpayin_from_payment_outbound.sql
git commit -m "feat: add environment-safe finance views"
```

---

### Task 2: Make release manifests include migrations 004 and 005

**Files:**
- Modify: `tests/test_release_manifest.ps1`
- Modify: `tools/new_release_manifest.ps1`

**Interfaces:**
- Consumes: the ordered SharePoint migration list.
- Produces: a manifest whose `migrations.D365_Sharedpoint_csv_import` ends with 004 and 005.

- [ ] **Step 1: Add the failing manifest assertion**

After the project SHA loop in `tests/test_release_manifest.ps1`, add:

```powershell
    $expectedMigrations = @(
        '000_create_schema_migrations.sql',
        '001_create_sharepoint_file_queue.sql',
        '002_add_pending_archive_to_import_files_status.sql',
        '003_add_effective_date_to_stg_received_outbound.sql',
        '004_create_vw_import_report.sql',
        '005_create_v_tbpayin_from_payment_outbound.sql'
    )
    $actualMigrations = @($manifest.migrations.D365_Sharedpoint_csv_import)
    if ((Compare-Object $expectedMigrations $actualMigrations -SyncWindow 0).Count -ne 0) {
        throw 'Release manifest does not contain the complete ordered migration set'
    }
```

- [ ] **Step 2: Run the PowerShell test and verify RED**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\test_release_manifest.ps1
```

Expected: FAIL with `Release manifest does not contain the complete ordered migration set`.

- [ ] **Step 3: Add 004 and 005 to the generator**

Append these entries to `migrations.D365_Sharedpoint_csv_import` in `tools/new_release_manifest.ps1`:

```powershell
            '004_create_vw_import_report.sql',
            '005_create_v_tbpayin_from_payment_outbound.sql'
```

- [ ] **Step 4: Run the manifest test and verify GREEN**

Run the same PowerShell command. Expected: `Release manifest generation checks passed.`

- [ ] **Step 5: Commit the generator change**

```powershell
git add tests/test_release_manifest.ps1 tools/new_release_manifest.ps1
git commit -m "fix: include finance views in release manifests"
```

---

### Task 3: Verify the complete code release

**Files:**
- Verify only; no new production files.

**Interfaces:**
- Consumes: branch commits from Tasks 2 and 3.
- Produces: a clean, tested SharePoint repository commit for the immutable release manifest.

- [ ] **Step 1: Run the full PHP suite**

Run `C:\xampp\php\php.exe tests\run.php`.

Expected: 69 tests pass (67 existing plus 2 view contracts).

- [ ] **Step 2: Run every PowerShell safety test**

```powershell
Get-ChildItem tests -Filter '*.ps1' | ForEach-Object {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" }
}
```

Expected: database checkpoint, environment preparation, release manifest, sync, and scheduler checks all pass.

- [ ] **Step 3: Run static safety checks**

```powershell
rg -n "D365_finance(_prod)?\s*\." database/migrations/004_create_vw_import_report.sql database/migrations/005_create_v_tbpayin_from_payment_outbound.sql
git diff --check
git status --porcelain --untracked-files=all
```

Expected: `rg` has no matches, `git diff --check` has no output, and Git status is clean.

---

### Task 4: Build and compare the immutable UAT release

**Files:**
- Generate (ignored audit artifact): `deployment/releases/2026-07-31.9.json`

**Interfaces:**
- Consumes: clean SharePoint release branch, unchanged File Importer commit `6abdd6299e4daa259534bcbfcb49dcfc53359d98`, and unchanged Finance Report commit `c9e16f2b7b5d96d865f7dab4be8b046f83b0dbd2`.
- Produces: immutable manifest and CompareOnly reports for all three UAT projects.

- [ ] **Step 1: Create a clean detached Finance Report worktree**

```powershell
$financeReleaseRoot = Join-Path ([IO.Path]::GetTempPath()) 'd365-finance-release-2026-07-31.9'
git -C C:\xampp\htdocs\finance_report worktree add --detach $financeReleaseRoot c9e16f2b7b5d96d865f7dab4be8b046f83b0dbd2
```

- [ ] **Step 2: Create the manifest from exact source roots**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\new_release_manifest.ps1 `
  -ReleaseId 2026-07-31.9 `
  -SharePointRoot $PWD.Path `
  -FileImporterRoot C:\xampp\htdocs\D365_file_csv_import `
  -FinanceReportRoot $financeReleaseRoot `
  -OutputPath deployment\releases\2026-07-31.9.json
```

Verify the manifest contains the current SharePoint branch HEAD and migrations 000 through 005.

- [ ] **Step 3: Run UAT CompareOnly for all three projects**

Run `tools\sync_to_server.ps1 -Environment UAT -ReleaseId 2026-07-31.9 -ManifestPath deployment\releases\2026-07-31.9.json -CompareOnly` once per project with its exact source root. Confirm `.env`, credentials, logs, CSV, archive, processed, error, temp, and vendor paths are absent.

- [ ] **Step 4: Keep the Finance worktree clean for UAT deployment**

```powershell
git -C $financeReleaseRoot status --porcelain --untracked-files=all
```

Expected: no output. Remove this worktree only after all three UAT project deployments in Task 5 succeed.

---

### Task 5: Deploy and prove release 2026-07-31.9 on UAT

**Files:**
- Deploy only to: `C:\xampp\htdocs\uat\D365_Sharedpoint_csv_import`
- Audit artifacts under: `C:\xampp\backups\d365\uat` and `C:\xampp\backups\d365\inventory`

**Interfaces:**
- Consumes: release manifest, UAT `.env`, dedicated UAT backup/migration accounts, and existing restore-rehearsal tools.
- Produces: UAT migrations 004/005 marked APPLIED, queryable views, fresh schema inventory, and a new UAT approval receipt.

- [ ] **Step 1: Deploy all three manifest projects to UAT**

Use `tools\sync_to_server.ps1` with approval token `APPROVE UAT 2026-07-31.9`. SharePoint receives the new migration/test/tool files; unchanged projects update only when CompareOnly reports changes or release metadata requires it. Never copy `.env` or runtime content.

- [ ] **Step 2: Remove the clean temporary Finance worktree**

```powershell
git -C C:\xampp\htdocs\finance_report worktree remove $financeReleaseRoot
```

Expected: the temporary directory is removed and the user's main Finance Report checkout remains unchanged.

- [ ] **Step 3: Create a fresh UAT checkpoint and restore receipt**

On server `100.1.1.166`, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\xampp\htdocs\uat\D365_Sharedpoint_csv_import\tools\database_checkpoint.ps1 `
  -Environment UAT -ReleaseId 2026-07-31.9 `
  -ProjectRoot C:\xampp\htdocs\uat\D365_Sharedpoint_csv_import `
  -ApprovalToken 'CHECKPOINT UAT 2026-07-31.9'
```

Immediately before backup, record exact live counts for `import_files`, `payment_outbound`, `payment_mail_log`, and `sharepoint_file_queue`. Restore the resulting SQL into an isolated rehearsal database and assert that the same four `COUNT(*)` results match exactly. Drop only that verified rehearsal database, then create the hash-bound receipt with `approve_restore_rehearsal.ps1`.

- [ ] **Step 4: Apply migrations through the guarded runner**

On the server, run `tools\apply_migrations.php --apply` with project `D365_Sharedpoint_csv_import`, directory `database\migrations`, release `2026-07-31.9`, the current operator, and the exact checkpoint manifest/restore receipt from Step 2.

Expected JSON: `applied` contains exactly `004_create_vw_import_report.sql` and `005_create_v_tbpayin_from_payment_outbound.sql`. A second identical invocation must return an empty `applied` array.

- [ ] **Step 5: Verify the real UAT views**

Using the UAT application account, run:

```sql
SELECT COUNT(*) FROM vw_import_report;
SELECT COUNT(*) FROM v_tbpayin_from_payment_outbound;
SELECT TABLE_NAME, SECURITY_TYPE
FROM information_schema.VIEWS
WHERE TABLE_SCHEMA = 'D365_finance'
  AND TABLE_NAME IN ('vw_import_report', 'v_tbpayin_from_payment_outbound')
ORDER BY TABLE_NAME;
```

Expected: both queries succeed and both views report `INVOKER`.

- [ ] **Step 6: Re-run UAT verification**

Run config guards for all three deployed projects, the SharePoint/File/Finance test suites, UAT Monitor/Finance/Statement HTTP smoke tests, database isolation check, migration checksum check, and a fresh schema inventory. Confirm the views contain no Production schema reference and Production has not changed.

- [ ] **Step 7: Create the UAT approval receipt**

After acceptance, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\approve_uat_release.ps1 `
  -ManifestPath deployment\releases\2026-07-31.9.json `
  -ApprovalToken 'APPROVE UAT RESULT 2026-07-31.9'
```

Record the receipt SHA-256. Do not use the 008 receipt for release 009.

---

### Task 6: Re-run Production readiness and stop at the cutover gate

**Files:**
- Read-only comparison and inventory outputs only.

**Interfaces:**
- Consumes: release 009 manifest and its matching UAT approval receipt.
- Produces: Production CompareOnly counts and a cutover checklist; no Production mutation.

- [ ] **Step 1: Run Production CompareOnly for all three projects**

Use the same exact clean source roots and pass `-Environment Production`, `-UatApprovalPath`, and `-CompareOnly`. Review every New/Modified/Deleted path and confirm secret/runtime exclusions.

- [ ] **Step 2: Compare schemas against the reviewed migration set**

Confirm the only expected pre-migration Production differences are `schema_migrations`, `stg_received_outbound.effective_date`, `vw_import_report`, and `v_tbpayin_from_payment_outbound`. Any additional difference blocks cutover.

- [ ] **Step 3: Stop and request explicit Production approval**

Do not copy Production code, create Production credentials, apply migrations, replace legacy redirects, or enable Production tasks. Present the backup, restore, migration, deployment, smoke-test, scheduler, rollback, and 15-minute/1-hour/next-business-day monitoring checklist for explicit approval.
