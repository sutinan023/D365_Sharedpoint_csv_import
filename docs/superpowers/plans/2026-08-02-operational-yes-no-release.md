# Operational Y/N Release Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** เปลี่ยนคำยืนยัน Interactive Release ทั้งหมดเป็น Y/N และอนุญาต Operational Release ผ่านด่านยืนยันที่แสดงไฟล์อย่างชัดเจน โดยไม่ลด fail-closed behavior เดิม

**Architecture:** เพิ่มตัวอ่าน Y/N กลางใน `release.ps1` และเก็บ approval token เดิมไว้สำหรับ non-interactive automation. แยก Operational paths และ migration paths จาก risk object อย่างอิสระ; Production confirmation เกิดก่อน side effect และ migration cancellation คืน Scheduled Task ผ่าน coordinator ก่อนจบงาน

**Tech Stack:** Windows PowerShell 5.1, PHP 8, Git, existing scriptblock adapters and PowerShell test harness

## Global Constraints

- Interactive Menu รับเฉพาะ `Y`, `y`, `N`, `n` หลัง trim; คำตอบอื่นถามซ้ำ
- ทุกคำถามต้องแสดง Environment และ Release ID
- Non-interactive approval tokens เดิมยังทำงานเหมือนเดิม
- Operational gate ต้องแสดงเฉพาะ project/path ห้ามแสดง secret values
- Release ที่มีทั้ง Operational และ migration ต้องผ่านทั้งสอง flow
- Production confirmation ต้องผ่านก่อน checkpoint, Task changes, migration apply หรือ file sync
- ตอบ N ที่ Migration gate ต้องคืนเฉพาะ Scheduled Task ที่เดิมเปิดอยู่
- ข้อผิดพลาดหลังเริ่ม Apply/deploy ยังคงปล่อย Task ปิดแบบ fail-closed
- ห้ามเปลี่ยน deployment exclusion สำหรับ `.env`, credentials, CSV, logs หรือ runtime data
- ไฟล์ PowerShell ที่มีภาษาไทยต้องคง UTF-8 BOM เพื่อรองรับ Windows PowerShell 5.1

---

### Task 1: Central Y/N confirmation for interactive UAT flow

**Files:**
- Modify: `release.ps1`
- Modify: `tests/test_release_menu.ps1`

**Interfaces:**
- Consumes: `Read-WizardAnswer([string] $Prompt)`
- Produces: `Read-WizardConfirmation([string] $Prompt) -> bool`
- Produces: Interactive UAT confirmation using Y/N; non-interactive `APPROVE UAT <release>` remains supported

- [ ] **Step 1: Write failing Y/N tests**

Extend `tests/test_release_menu.ps1` with an input queue that sends an invalid answer followed by `y`. Assert both prompts were observed and the UAT deploy finishes in `LocalTestMode`. Add a second run with `N` and assert no project destination metadata changes.

```powershell
$answers.Enqueue('maybe')
$answers.Enqueue(' y ')
$prompts = [Collections.Generic.List[string]]::new()
$input = {
    param([string] $Prompt)
    $prompts.Add($Prompt)
    $answers.Dequeue()
}.GetNewClosure()

Assert-True (@($prompts | Where-Object { $_ -match '\[Y/N\]' }).Count -eq 2) `
    'Invalid Y/N answer was not asked again.'
```

Also scan the release script and reject the removed interactive phrases `ยืนยันอัปเดต UAT <release>`, `ยืนยันว่าทดสอบ UAT ผ่าน <release>`, `ยืนยันใช้ MIGRATION <release>` and `ยืนยันนำขึ้น PRODUCTION <release>` as expected typed answers.

- [ ] **Step 2: Run test to verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
```

Expected: FAIL because the current wizard compares the full Thai approval phrase and does not re-prompt invalid answers.

- [ ] **Step 3: Implement the shared Y/N reader and UAT gate**

Add after `Read-WizardAnswer`:

```powershell
function Read-WizardConfirmation([string] $Prompt) {
    while ($true) {
        $answer = ([string] (Read-WizardAnswer "$Prompt [Y/N]")).Trim()
        if ($answer -ieq 'Y') { return $true }
        if ($answer -ieq 'N') { return $false }
        Write-Output 'กรุณาตอบ Y หรือ N เท่านั้น'
    }
}
```

In interactive `Invoke-DeployUAT`, replace the exact Thai phrase comparison with:

```powershell
if (-not (Read-WizardConfirmation "ยืนยันอัปเดต UAT Release $ReleaseId หรือไม่?")) {
    Write-Output "ยกเลิกการอัปเดต UAT Release $ReleaseId"
    return
}
$actualApproval = $expectedApproval
```

Do not change the non-interactive `ApprovalToken` branch or `Assert-D365Approval`.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
```

Expected: both pass; UAT `N` produces no destination change.

- [ ] **Step 5: Commit**

```powershell
git add release.ps1 tests/test_release_menu.ps1
git commit -m "feat: use yes-no confirmation for UAT releases"
```

---

### Task 2: Operational gate and pre-side-effect Production confirmation

**Files:**
- Modify: `release.ps1`
- Modify: `tests/test_release_menu.ps1`
- Modify: `tests/test_release_common.ps1`

**Interfaces:**
- Adds parameter: `[string] $OperationalApprovalToken`
- Operational non-interactive token: `APPROVE OPERATIONAL <release-id>`
- Interactive prompts use `Read-WizardConfirmation`
- Risk collections use `OperationalPaths.Count` and `MigrationPaths.Count`, never only `Kind`

- [ ] **Step 1: Write failing operational and mixed-risk tests**

In `tests/test_release_common.ps1`, create one commit containing both `config/runtime.php` and `database/migrations/007_mixed.sql`. Assert the returned risk includes both arrays:

```powershell
$risk = Get-D365ReleaseRisk -RepositoryRoot $riskRepo -FromSha $baseSha -ToSha $mixedSha
Assert-True ($risk.OperationalPaths -contains 'config/runtime.php') 'Operational path was lost.'
Assert-True ($risk.MigrationPaths -contains 'database/migrations/007_mixed.sql') 'Migration path was lost.'
```

In `tests/test_release_menu.ps1`, build an Operational-only release and assert:

- `PlanOnly` prints every `project/path`
- actual non-interactive promotion rejects a missing/wrong `OperationalApprovalToken`
- exact token passes in `LocalTestMode`
- interactive `N` reaches neither migration adapter nor Production sync validation
- interactive prompt sequence asks UAT, Operational and Production before the first migration-adapter stage

- [ ] **Step 2: Run tests to verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_common.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
```

Expected: release common retains both path lists, but menu test fails at the current unconditional `Operational release detected` throw.

- [ ] **Step 3: Implement independent risk lists and Operational approval**

Replace the single-kind project selection with:

```powershell
$operationalProjects = @($risks.Keys | Where-Object { @($risks[$_].OperationalPaths).Count -gt 0 })
$migrationProjects = @($risks.Keys | Where-Object { @($risks[$_].MigrationPaths).Count -gt 0 })
```

Remove the unconditional Operational throw. Print paths grouped by project:

```powershell
if ($operationalProjects.Count -gt 0) {
    Write-Output 'ตรวจพบไฟล์ที่มีผลต่อการตั้งค่าระบบ:'
    foreach ($project in $operationalProjects) {
        foreach ($path in $risks[$project].OperationalPaths) { Write-Output "- $project/$path" }
    }
}
```

After UAT acceptance and before creating `$migrationResult`, enforce Operational approval. Interactive mode uses Y/N and internally assigns `APPROVE OPERATIONAL $ReleaseId`; non-interactive mode validates `-OperationalApprovalToken` with `Assert-D365Approval`.

Move the existing Production confirmation block before the migration coordinator. Interactive UAT-result and Production confirmations use:

```powershell
if (-not (Read-WizardConfirmation "ยืนยันว่าทดสอบ UAT Release $ReleaseId ผ่านแล้วหรือไม่?")) { return }
if (-not (Read-WizardConfirmation "ยืนยันนำ Release $ReleaseId ขึ้น Production หรือไม่?")) { return }
```

Only after all applicable confirmations pass may code call `Invoke-D365MigrationPromotion` or `sync_to_server.ps1` with a non-CompareOnly operation.

- [ ] **Step 4: Run focused regression tests**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_common.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
```

Expected: all pass; Operational-only release reaches Production only after the extra approval, and mixed releases still run migration stages.

- [ ] **Step 5: Commit**

```powershell
git add release.ps1 tests/test_release_menu.ps1 tests/test_release_common.ps1
git commit -m "feat: add operational production approval gate"
```

---

### Task 3: Safe Y/N cancellation at the Migration gate

**Files:**
- Modify: `tools/release_migration.ps1`
- Modify: `release.ps1`
- Modify: `tests/test_release_migration.ps1`
- Modify: `tests/test_release_menu.ps1`

**Interfaces:**
- Adds coordinator parameter: `[scriptblock] $ApprovalDecisionProvider`
- Provider consumes release ID and returns `bool`
- Cancelled result shape: `Cancelled=$true`, `TasksRemainDisabled=$false`, `RestoredTasks=<original enabled tasks>`
- Successful result shape adds `Cancelled=$false` without changing existing fields

- [ ] **Step 1: Write failing cancellation tests**

In `tests/test_release_migration.ps1`, invoke with a decision provider returning `$false`:

```powershell
$decision = { param([string] $ReleaseId) return $false }
$result = Invoke-D365MigrationPromotion -ReleaseId 'r1' -ManifestPath 'manifest.json' `
    -ProjectRoot 'project' -BackupRoot 'backup' -TaskNames @('Import A') `
    -ApprovalDecisionProvider $decision -CommandAdapter (New-TestAdapter -Stages $stages)

Assert-True $result.Cancelled 'Migration N did not return a cancellation result.'
Assert-True ($stages -notcontains 'apply-production') 'Migration N reached Production apply.'
Assert-True ($stages[-1] -ceq 'restore-production-task-states') 'Migration N did not restore task state.'
```

Add a failure adapter for `restore-production-task-states` and assert cancellation fails closed instead of reporting success. In the menu test, answer `N` to the Migration question and assert no Production sync occurs.

- [ ] **Step 2: Run tests to verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_migration.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
```

Expected: FAIL because `ApprovalDecisionProvider` is undefined and current cancellation becomes an approval error with tasks disabled.

- [ ] **Step 3: Implement decision-provider cancellation**

Add `[scriptblock] $ApprovalDecisionProvider` to `Invoke-D365MigrationPromotion`. Immediately after automatic rehearsal approval and before token validation:

```powershell
if ($null -ne $ApprovalDecisionProvider) {
    $approved = & $ApprovalDecisionProvider $ReleaseId
    if ($approved -ne $true) {
        $restored = Invoke-D365MigrationStage 'restore-production-task-states' $CommandAdapter $context
        return [pscustomobject]@{
            ReleaseId = $ReleaseId
            Cancelled = $true
            RestoredTasks = @($restored.RestoredTasks)
            TasksRemainDisabled = $false
            Context = $context
        }
    }
    $ApprovalToken = "APPLY MIGRATION $ReleaseId"
}
```

Add `Cancelled=$false` to the normal result. In interactive `release.ps1`, provide:

```powershell
$migrationDecisionProvider = {
    param([string] $ApprovedReleaseId)
    Read-WizardConfirmation "ยืนยันใช้ Migration กับ Production Release $ApprovedReleaseId หรือไม่?"
}.GetNewClosure()
```

If coordinator returns `Cancelled=$true`, print `ยกเลิก Migration และคืนสถานะ Production Task แล้ว` and return before any sync. Keep non-interactive `MigrationApprovalToken` behavior unchanged.

- [ ] **Step 4: Run migration and menu tests**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_migration.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_manual_restore_migration_adapter.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
```

Expected: all pass; N restores task state and never applies migration or deploys code.

- [ ] **Step 5: Commit**

```powershell
git add tools/release_migration.ps1 release.ps1 tests/test_release_migration.ps1 tests/test_release_menu.ps1
git commit -m "feat: cancel migrations safely from yes-no wizard"
```

---

### Task 4: Thai operator documentation and full verification

**Files:**
- Modify: `README.md`
- Modify: `docs/uat-production-runbook.md`
- Test: every `tests/test_*.ps1`
- Test: `tests/run.php`

**Interfaces:**
- README and runbook show only Y/N interactive instructions
- Runbook explains Operational file review and safe cancellation without exposing approval tokens in the normal user flow

- [ ] **Step 1: Update operator documentation**

Replace instructions that tell users to copy full approval phrases. Document:

```text
ตรวจ Environment, Release ID และรายการไฟล์บนหน้าจอ
ตอบ Y เพื่อดำเนินการต่อ หรือ N เพื่อยกเลิก
```

Add one Operational paragraph: the wizard lists affected paths; `.env` and runtime exclusions remain blocked; Production remains unchanged until all pre-production confirmations are Y.

- [ ] **Step 2: Run the complete PowerShell suite**

Run:

```powershell
Get-ChildItem tests -Filter 'test_*.ps1' | Sort-Object Name | ForEach-Object {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" }
}
```

Expected: every script exits 0.

- [ ] **Step 3: Run the complete PHP suite**

Run:

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: `Tests passed: 87` or a higher count if PHP coverage is added.

- [ ] **Step 4: Verify repository scope**

Run:

```powershell
git diff --check
git status --short
git diff --stat HEAD
```

Expected: only planned files are modified; no `.env`, credentials, CSV, backup, archive, log or runtime file appears.

- [ ] **Step 5: Commit documentation**

```powershell
git add README.md docs/uat-production-runbook.md
git commit -m "docs: explain yes-no operational releases"
```

- [ ] **Step 6: Verify after the final commit**

Run the complete PowerShell and PHP commands from Steps 2-3 again, followed by:

```powershell
git diff --check
git status --short
```

Expected: all tests pass and the worktree is clean.
