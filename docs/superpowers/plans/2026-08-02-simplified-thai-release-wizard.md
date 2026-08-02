# Simplified Thai Release Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** เปลี่ยน `release.ps1` ให้เป็น Wizard ภาษาไทยที่สร้าง Release ID เองและลดงานประจำของผู้ใช้เหลือเพียงทดสอบ UAT, Import rehearsal ผ่าน phpMyAdmin และยืนยัน Production

**Architecture:** รักษา deployment/migration security scripts เดิมเป็นขอบเขตความปลอดภัย แล้วเพิ่มโมดูลเล็กสำหรับ Release ID, checkpoint baseline, rehearsal preparation และ read-only rehearsal verification ตัว Wizard เรียกโมดูลตามลำดับและแสดงเฉพาะข้อมูลที่คนต้องใช้ตัดสินใจ

**Tech Stack:** Windows PowerShell 5.1, PHP 8, PDO MySQL, Git, XAMPP MariaDB/MySQL และเครื่องมือ release เดิมของทั้งสามโปรเจกต์

## Global Constraints

- ผู้ใช้ commit code เอง; Wizard ห้าม stage หรือ commit application code
- Git commit เป็นแหล่ง deploy เท่านั้น; ห้ามคัดลอก UAT filesystem ไป Production
- UAT ใช้ `D365_finance`; Production ใช้ `D365_finance_prod`
- Release ID อัตโนมัติใช้ `YYYY-MM-DD.N` และ manifest เดิมห้ามถูกเขียนทับ
- ผู้ใช้ Restore rehearsal ผ่าน phpMyAdmin เอง; Wizard ห้ามสร้าง, Restore หรือลบฐาน
- `REHEARSAL_DB_USER` ต้อง read-only และห้ามมีสิทธิ์บน `D365_finance_prod`
- Password ห้ามอยู่ใน command line, log, receipt หรือ output
- หลังปิด Production Tasks หากขั้นตอนใดล้มเหลว Tasks ต้องคงปิดอยู่
- เปิดกลับเฉพาะ Task ที่เคยเปิดและเฉพาะหลัง migration, deploy, config, HTTP และ code verification ผ่าน
- LocalTestMode ห้ามเข้าถึง UAT, Production, MySQL หรือ Scheduled Tasks จริง

---

## File structure

- Modify `release.ps1`: action router, Thai wizard prompts และ orchestration เท่านั้น
- Modify `tools/release_common.ps1`: คำนวณ Release ID ถัดไปและเลือก UAT release ล่าสุด
- Modify `tools/new_release_manifest.ps1`: เขียน manifest แบบ atomic `CreateNew`
- Create `tools/checkpoint_baseline.php`: สร้าง baseline ที่ผูกกับ Production checkpoint
- Create `src/Database/CheckpointBaseline.php`: read-only baseline query logic
- Modify `tools/database_checkpoint.ps1`: เรียก baseline tool และบันทึกผลลง checkpoint manifest
- Modify `tools/prepare_restore_rehearsal.ps1`: โหมด auto-detect count ที่ยังใช้ SQL safety checks เดิม
- Create `src/Database/RehearsalVerifier.php`: read-only verification logic
- Create `tools/verify_restore_rehearsal.php`: CLI ที่โหลด Production config และคืน strict JSON evidence
- Modify `config/EnvironmentGuard.php`: ตรวจ rehearsal verifier configuration
- Modify `.env.example`: เพิ่มชื่อตัวแปรโดยไม่มี secret
- Modify `tools/release_migration.ps1`: เพิ่ม preparation/pause/verification orchestration
- Modify `tools/manual_restore_migration_adapter.ps1`: รับ evidence/receipt ที่ Wizard สร้างให้อัตโนมัติ
- Modify `README.md` และ `docs/uat-production-runbook.md`: คู่มือภาษาไทยเฉพาะงานที่คนต้องทำ
- Add/modify tests ตามแต่ละ Task ด้านล่าง

---

### Task 1: Generate daily Release IDs and select the current UAT release

**Files:**
- Modify: `tools/release_common.ps1`
- Modify: `tests/test_release_common.ps1`

**Interfaces:**
- Produces `Get-D365NextReleaseId([string] $ReleaseRoot, [datetime] $Now)` returning `YYYY-MM-DD.N`
- Produces `Get-D365CurrentUatReleaseId([string] $UatRoot)` returning the one exact release shared by all three UAT metadata files

- [ ] **Step 1: Write failing release-ID tests**

Add assertions using a temporary release root:

```powershell
Assert-Equal '2026-08-02.1' (Get-D365NextReleaseId -ReleaseRoot $releaseRoot -Now ([datetime]'2026-08-02'))
Set-Content (Join-Path $releaseRoot '2026-08-02.1.json') '{}'
Set-Content (Join-Path $releaseRoot '2026-08-02.3.json') '{}'
Assert-Equal '2026-08-02.4' (Get-D365NextReleaseId -ReleaseRoot $releaseRoot -Now ([datetime]'2026-08-02'))
```

Create three UAT metadata files with the same release and assert the release is returned. Change one release and assert the function throws `UAT ทั้งสามโปรเจกต์ใช้คนละ Release`.

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_common.ps1
```

Expected: FAIL because both functions are undefined.

- [ ] **Step 3: Implement the two functions**

Use exact filename matching and the existing strict JSON reader:

```powershell
function Get-D365NextReleaseId([string]$ReleaseRoot,[datetime]$Now) {
    $prefix = $Now.ToString('yyyy-MM-dd')
    $numbers = @(Get-ChildItem -LiteralPath $ReleaseRoot -File -Filter "$prefix.*.json" -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.BaseName -match ('^' + [regex]::Escape($prefix) + '\.(\d+)$')) { [int]$matches[1] } })
    $next = if ($numbers.Count -eq 0) { 1 } else { ([int](($numbers | Measure-Object -Maximum).Maximum) + 1) }
    "$prefix.$next"
}
```

`Get-D365CurrentUatReleaseId` must require the exact approved project set and ordinal equality of all `release_id` values.

- [ ] **Step 4: Run the test and verify GREEN**

Run the command from Step 2. Expected: `Shared release state checks passed.`

- [ ] **Step 5: Commit**

```powershell
git add tools/release_common.ps1 tests/test_release_common.ps1
git commit -m "feat: generate daily D365 release IDs"
```

---

### Task 2: Replace the technical menu with the minimal Thai wizard

**Files:**
- Modify: `release.ps1`
- Modify: `tools/new_release_manifest.ps1`
- Modify: `tests/test_release_menu.ps1`
- Modify: `tests/test_release_manifest.ps1`

**Interfaces:**
- Interactive menu labels are exactly `อัปเดต UAT`, `นำ Release ที่ผ่าน UAT ขึ้น Production`, `ตรวจสอบสถานะและเปรียบเทียบอย่างเดียว`, `ออก`
- `DeployUAT` accepts an omitted `ReleaseId` only in interactive mode and creates one automatically
- `PromoteProduction` accepts an omitted `ReleaseId` only in interactive mode and reads it from UAT metadata

- [ ] **Step 1: Write failing wizard tests**

Add a local input adapter parameter available only with `-LocalTestMode`:

```powershell
$answers = [Collections.Generic.Queue[string]]::new()
$answers.Enqueue('1')
$answers.Enqueue('ยืนยันอัปเดต UAT')
$inputAdapter = { param($Prompt) $answers.Dequeue() }.GetNewClosure()
```

Assert the wizard generates `2026-08-02.1`, does not ask for a release ID or path, and prints all four Thai menu labels. Assert menu 2 selects the common UAT release. Assert a mismatched UAT release stops before Production comparison.

- [ ] **Step 2: Run the test and verify RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
```

Expected: FAIL because the current menu asks for Release ID and exposes technical actions.

- [ ] **Step 3: Add a focused prompt adapter and atomic manifest retry**

Add these internal helpers to `release.ps1`:

```powershell
function Read-WizardAnswer([string]$Prompt) {
    if ($LocalTestMode -and $null -ne $WizardInputAdapter) { return & $WizardInputAdapter $Prompt }
    Read-Host $Prompt
}
function New-AutomaticReleaseManifest {
    for ($attempt=0; $attempt -lt 20; $attempt++) {
        $candidate = Get-D365NextReleaseId -ReleaseRoot $ReleaseRoot -Now (Get-Date)
        try {
            $path = Join-Path $ReleaseRoot "$candidate.json"
            & (Join-Path $toolRoot 'new_release_manifest.ps1') -ReleaseId $candidate -SourceParent $SourceParent -OutputPath $path | Out-Null
            return [pscustomobject]@{ReleaseId=$candidate;ManifestPath=$path}
        } catch {
            if ($_.Exception.Message -notmatch 'immutable') { throw }
        }
    }
    throw 'ไม่สามารถสร้างหมายเลข Release ที่ไม่ซ้ำได้'
}
```

Keep existing non-interactive actions for automation, but hide parameters and English implementation details from the interactive route. Catch tool exceptions once at the Wizard boundary and display a concrete stage such as `หยุดที่ขั้นตอน: ตรวจสอบ UAT` followed by the original technical detail.

Replace the manifest file write with `FileMode.CreateNew` so concurrent release attempts cannot overwrite each other:

```powershell
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
$stream = [IO.FileStream]::new($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
```

- [ ] **Step 4: Run menu/security regression tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_manifest.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
```

Expected: all pass.

- [ ] **Step 5: Commit**

```powershell
git add release.ps1 tools/new_release_manifest.ps1 tests/test_release_menu.ps1 tests/test_release_manifest.ps1
git commit -m "feat: simplify Thai release wizard"
```

---

### Task 3: Capture a checkpoint baseline automatically

**Files:**
- Create: `tools/checkpoint_baseline.php`
- Create: `src/Database/CheckpointBaseline.php`
- Modify: `tools/database_checkpoint.ps1`
- Create: `tests/Database/CheckpointBaselineTest.php`
- Modify: `tests/run.php`
- Modify: `tests/test_database_checkpoint.ps1`

**Interfaces:**
- `checkpoint_baseline.php` emits `{database,row_counts,views,live_schema_reference_count,definer_count,qualified_reference_count}`
- `database_checkpoint.ps1` stores the object as `verification_baseline` inside the generated file such as `D365_finance_prod_2026-08-02.1_20260802-090000.sql.json`

- [ ] **Step 1: Write failing PHP baseline tests**

Use an injected PDO fixture and assert exact keys and integer values:

```php
$baseline = CheckpointBaseline::capture($pdo, 'D365_finance_prod');
checkpointExpect(array_keys($baseline['row_counts']) === [
    'import_files','payment_outbound','payment_mail_log','sharepoint_file_queue'
], 'baseline row-count keys changed');
checkpointExpect($baseline['live_schema_reference_count'] === 0, 'live reference count is not native int');
```

Also assert a database other than `D365_finance_prod` is rejected.

- [ ] **Step 2: Run PHP tests and verify RED**

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: FAIL because `CheckpointBaseline` does not exist.

- [ ] **Step 3: Implement baseline capture**

Create a focused class or functions used by `checkpoint_baseline.php`. Use `SELECT COUNT(*)` for the four tables and two views, query `information_schema.VIEWS` for `SECURITY_TYPE`, count case-insensitive occurrences of `D365_finance_prod` in view definitions, and return native integers. Load `BACKUP_DB_USER/PASS` from protected Production config and place the password only in the PDO constructor.

Modify `database_checkpoint.ps1` to invoke the PHP tool after the dump, reject nonzero exit/invalid JSON, and include:

```powershell
verification_baseline = $baseline
```

in the immutable checkpoint manifest.

- [ ] **Step 4: Run baseline/checkpoint tests**

```powershell
C:\xampp\php\php.exe tests\run.php
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_database_checkpoint.ps1
```

Expected: all pass and no password appears in captured output.

- [ ] **Step 5: Commit**

```powershell
git add src/Database/CheckpointBaseline.php tools/checkpoint_baseline.php tools/database_checkpoint.ps1 tests/Database/CheckpointBaselineTest.php tests/run.php tests/test_database_checkpoint.ps1
git commit -m "feat: bind verification baseline to checkpoint"
```

---

### Task 4: Prepare sanitized rehearsal artifacts without manual counts

**Files:**
- Modify: `tools/prepare_restore_rehearsal.ps1`
- Modify: `tests/test_prepare_restore_rehearsal.ps1`

**Interfaces:**
- Adds switch `-UseCheckpointBaseline`
- With the switch, consumes `-BackupManifestPath` and derives expected definer/reference counts from `verification_baseline`
- Existing explicit-count interface remains supported

- [ ] **Step 1: Write failing automatic-preparation tests**

Create a checkpoint manifest containing:

```powershell
verification_baseline = [ordered]@{
    definer_count = 2
    qualified_reference_count = 22
}
```

Invoke with `-UseCheckpointBaseline -BackupManifestPath $manifest` and no explicit count parameters. Assert sanitized SQL and audit are created. Tamper either count and assert no sanitized artifact survives.

- [ ] **Step 2: Run and verify RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_prepare_restore_rehearsal.ps1
```

Expected: FAIL because the new parameters do not exist.

- [ ] **Step 3: Implement baseline mode**

Make explicit counts nullable and require exactly one mode:

```powershell
if ($UseCheckpointBaseline) {
    $checkpoint = (Read-D365StrictJsonSnapshot $BackupManifestPath 'Checkpoint manifest').Value
    $ExpectedDefinerCount = [int]$checkpoint.verification_baseline.definer_count
    $ExpectedQualifiedReferenceCount = [int]$checkpoint.verification_baseline.qualified_reference_count
} elseif ($null -eq $ExpectedDefinerCount -or $null -eq $ExpectedQualifiedReferenceCount) {
    throw 'ต้องระบุ count แบบเดิมหรือใช้ UseCheckpointBaseline'
}
```

Retain every existing lexical/dangerous-DDL/reparse/hash check and bind the checkpoint manifest hash into the sanitizer audit.

- [ ] **Step 4: Run sanitizer and restore approval tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_prepare_restore_rehearsal.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_approve_restore_rehearsal.ps1
```

Expected: both pass.

- [ ] **Step 5: Commit**

```powershell
git add tools/prepare_restore_rehearsal.ps1 tests/test_prepare_restore_rehearsal.ps1
git commit -m "feat: prepare rehearsal from checkpoint baseline"
```

---

### Task 5: Verify the manually restored rehearsal database read-only

**Files:**
- Create: `src/Database/RehearsalVerifier.php`
- Create: `tools/verify_restore_rehearsal.php`
- Modify: `config/EnvironmentGuard.php`
- Modify: `.env.example`
- Create: `tests/Database/RehearsalVerifierTest.php`
- Modify: `tests/Config/EnvironmentGuardTest.php`
- Modify: `tests/run.php`

**Interfaces:**
- `RehearsalVerifier::verify(PDO $pdo, string $database, array $baseline): array`
- CLI example: `php tools/verify_restore_rehearsal.php --database=D365_finance_prod_rehearsal_20260802_1 --checkpoint=C:\xampp\backups\d365\prod\D365_finance_prod_2026-08-02.1.sql.json --sanitizer-audit=C:\xampp\backups\d365\prod\D365_finance_prod_2026-08-02.1.sanitized.sql.audit.json`
- Emits the exact restore-evidence shape already accepted by `approve_restore_rehearsal.ps1`

- [ ] **Step 1: Write failing verifier tests**

Cover exact name, database identity, counts, view security, live references and grants:

```php
$result = RehearsalVerifier::verify($pdo, 'D365_finance_prod_rehearsal_20260802_1', $baseline);
rehearsalExpect($result['status'] === 'VERIFIED', 'rehearsal was not verified');
rehearsalExpect($result['row_counts'] === $baseline['row_counts'], 'row counts differ from checkpoint');
```

Assert rejection for `D365_finance_prod`, `D365_finance`, mismatched counts, `DEFINER`, a live-schema reference, a broad `GRANT ... ON *.*`, and any write grant on the rehearsal schema.

- [ ] **Step 2: Run PHP tests and verify RED**

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: FAIL because `RehearsalVerifier` does not exist.

- [ ] **Step 3: Implement config and verification**

Require `REHEARSAL_DB_HOST`, `REHEARSAL_DB_USER`, `REHEARSAL_DB_PASS` only when invoking the rehearsal CLI. Reject a rehearsal username equal to `DB_USER`, `MIGRATION_DB_USER` or `BACKUP_DB_USER`.

The CLI connects with a DSN containing only the exact rehearsal database, confirms `SELECT DATABASE()`, inspects `SHOW GRANTS FOR CURRENT_USER()`, then calls the verifier. It writes strict UTF-8 JSON containing hashes copied from the checkpoint/sanitizer audit, measured counts, views, `live_schema_reference_count=0`, UTC time and Windows operator. It never accepts counts from CLI parameters.

- [ ] **Step 4: Run PHP/config tests**

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: all pass with no secret values in output.

- [ ] **Step 5: Commit**

```powershell
git add src/Database/RehearsalVerifier.php tools/verify_restore_rehearsal.php config/EnvironmentGuard.php .env.example tests/Database/RehearsalVerifierTest.php tests/Config/EnvironmentGuardTest.php tests/run.php
git commit -m "feat: verify rehearsal restores read-only"
```

---

### Task 6: Orchestrate the pause-and-resume migration wizard

**Files:**
- Modify: `tools/release_migration.ps1`
- Modify: `tools/manual_restore_migration_adapter.ps1`
- Modify: `release.ps1`
- Modify: `tests/test_release_migration.ps1`
- Modify: `tests/test_manual_restore_migration_adapter.ps1`
- Modify: `tests/test_release_menu.ps1`

**Interfaces:**
- Produces `Start-D365ManualRestoreWizard` returning checkpoint manifest, rehearsal database, sanitized path and sanitizer audit
- Produces `Complete-D365ManualRestoreWizard` returning restore evidence and immutable receipt
- The interactive Production action invokes both around one `กด Enter หลัง Import สำเร็จ` pause

- [ ] **Step 1: Write failing stage/order tests**

Extend the injected adapter sequence to require:

```text
disable-production-tasks
checkpoint-production
prepare-rehearsal
show-manual-restore-instructions
wait-for-manual-restore
verify-rehearsal-read-only
approve-rehearsal-automatically
approve-production-migration
apply-production
apply-production-idempotence-check
verify-production
restore-production-task-states
```

Assert the instruction object contains only `RehearsalDatabase` and `SanitizedPath` as user actions. Assert verifier, approval, migration or deploy failure leaves tasks disabled.

- [ ] **Step 2: Run and verify RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_migration.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
```

Expected: FAIL because the current flow asks for artifact paths and does not prepare/verify in one session.

- [ ] **Step 3: Implement preparation and completion functions**

`Start-D365ManualRestoreWizard` calls the existing checkpoint and sanitizer tools, uses rehearsal name:

```powershell
$safeRelease = $ReleaseId.Replace('-','_').Replace('.','_')
$rehearsalDatabase = "D365_finance_prod_rehearsal_$safeRelease"
```

It prints:

```text
สิ่งที่คุณต้องทำ
1. เปิด phpMyAdmin และสร้างฐาน: D365_finance_prod_rehearsal_20260802_1
2. เลือกฐานนี้และ Import ไฟล์: C:\xampp\backups\d365\prod\D365_finance_prod_2026-08-02.1.sanitized.sql
3. เมื่อ Import สำเร็จ กลับมาหน้านี้แล้วกด Enter
```

`Complete-D365ManualRestoreWizard` calls `verify_restore_rehearsal.php`, writes evidence with `CreateNew`, calls `approve_restore_rehearsal.ps1` with the machine-verified token, and returns paths to the existing migration adapter. Remove interactive prompts for checkpoint manifest, sanitizer audit, evidence and receipt paths.

- [ ] **Step 4: Connect Thai confirmations and final task restoration**

Keep two human decisions after UAT testing:

```text
ยืนยันว่าทดสอบ UAT ผ่าน 2026-08-02.1
ยืนยันนำขึ้น PRODUCTION 2026-08-02.1
```

For migration add one decision immediately before apply:

```text
ยืนยันใช้ MIGRATION 2026-08-02.1
```

Internally translate these to the exact existing security tokens. Do not weaken ordinal/case-sensitive comparison. Restore task states only after post-deploy verification succeeds.

- [ ] **Step 5: Run wizard/migration/deployment tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_migration.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_manual_restore_migration_adapter.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
```

Expected: all pass and LocalTestMode adapters record no real external access.

- [ ] **Step 6: Commit**

```powershell
git add tools/release_migration.ps1 tools/manual_restore_migration_adapter.ps1 release.ps1 tests/test_release_migration.ps1 tests/test_manual_restore_migration_adapter.ps1 tests/test_release_menu.ps1
git commit -m "feat: automate the manual restore wizard"
```

---

### Task 7: Replace the runbook with a concise Thai operator guide

**Files:**
- Modify: `README.md`
- Modify: `docs/uat-production-runbook.md`

**Interfaces:**
- README shows one command and the four menu choices
- Runbook separates `ตั้งค่าครั้งเดียว`, `ทุกครั้งที่แก้โปรแกรม`, `เฉพาะเมื่อพบ migration` and `เมื่อระบบหยุดเพราะผิดพลาด`

- [ ] **Step 1: Rewrite operator-facing documentation**

The normal flow must contain only:

```text
1. Commit ทั้งสามโปรเจกต์
2. เปิด release.ps1 แล้วเลือก อัปเดต UAT
3. ทดสอบ UAT
4. เปิด release.ps1 แล้วเลือก นำขึ้น Production
```

The migration section must describe only opening phpMyAdmin, creating the exact displayed database, importing the exact displayed file and returning to press Enter. Move CLI parameters and internal receipts to an `ข้อมูลสำหรับผู้ดูแลระบบ` appendix.

- [ ] **Step 2: Run the complete PowerShell suite**

```powershell
Get-ChildItem tests -Filter 'test_*.ps1' | Sort-Object Name | ForEach-Object {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" }
}
```

Expected: every script exits 0.

- [ ] **Step 3: Run the complete PHP suite**

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: all PHP tests pass.

- [ ] **Step 4: Verify scope and commit**

```powershell
git diff --check
git status --short
git add README.md docs/uat-production-runbook.md
git commit -m "docs: simplify Thai release operator steps"
```

- [ ] **Step 5: Run final verification after the commit**

Run the PowerShell and PHP commands from Steps 2 and 3 again, then:

```powershell
git diff --check
git status --short
```

Expected: all tests pass and the working tree is empty.
