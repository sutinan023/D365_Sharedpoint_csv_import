# Thai Release Deploy Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one Thai-language PowerShell menu that deploys committed code to UAT, compares UAT with Production, and promotes the same attested Git release to Production with a guarded database-migration path.

**Architecture:** Keep the existing deployment, approval, backup, restore, and migration scripts as the security boundary. Add small orchestration modules for shared release state, code-only environment comparison, migration coordination, and the root menu; every production mutation still flows through the existing guarded tools.

**Tech Stack:** Windows PowerShell 5.1, Git, PHP 8, MySQL/MariaDB tools bundled with XAMPP, existing D365 PowerShell/PHP deployment tools.

## Global Constraints

- The operator commits code; the script never stages or commits application changes.
- Deployment source is the clean, attested Git tree, never the UAT filesystem.
- UAT is `D365_finance`; Production is `D365_finance_prod`.
- UAT and Production `.env`, credentials, CSV files, logs, runtime folders, lock files, deployment metadata, and deployment backups are never compared as code or copied.
- Production requires the exact UAT release Git SHAs and canonical immutable approval receipt.
- Routine code-only promotion does not restart Apache or modify Scheduled Tasks.
- Unapplied Production migrations require checkpoint, restore rehearsal, restore receipt, exact `APPLY MIGRATION <release-id>` approval, checksum verification, and an idempotent second run.
- Tests must use temporary local directories and must not access real UAT, Production, SharePoint, Task Scheduler, or `D365_finance_prod`.

---

## File structure

- Create `release.ps1`: Thai menu and non-interactive action router only.
- Create `tools/release_common.ps1`: project map, clean Git checks, release metadata, approval phrase, risk classification, and safe command execution.
- Create `tools/compare_environment_code.ps1`: compare an attested Git tree with UAT or Production using the canonical deployment exclusions.
- Create `tools/release_migration.ps1`: coordinate existing checkpoint, rehearsal, restore approval, migration, and task-state gates.
- Modify `tools/new_release_manifest.ps1`: enumerate committed migration files instead of a hard-coded list.
- Create `tests/test_release_common.ps1`: pure shared-function tests.
- Create `tests/test_compare_environment_code.ps1`: code inventory and exclusion tests.
- Create `tests/test_release_menu.ps1`: menu/action orchestration tests in local mode.
- Create `tests/test_release_migration.ps1`: migration gate/order/failure tests using injected local command adapters.
- Modify `tests/test_release_manifest.ps1`: dynamic migration inventory regression tests.
- Modify `docs/uat-production-runbook.md`: operator instructions for the new menu.

---

### Task 1: Generate migration inventory from the committed Git tree

**Files:**
- Modify: `tools/new_release_manifest.ps1`
- Modify: `tests/test_release_manifest.ps1`

**Interfaces:**
- Consumes: project roots and `ReleaseId` already accepted by `new_release_manifest.ps1`.
- Produces: `manifest.migrations.<project>` as a naturally sorted array of committed `database/migrations/*.sql` paths represented by filename.

- [ ] **Step 1: Write the failing dynamic-inventory test**

Add a committed `database/migrations/006_test.sql` to the temporary SharePoint repository in `tests/test_release_manifest.ps1`, generate the plan, and assert:

```powershell
$actualMigrations = @($manifest.migrations.D365_Sharedpoint_csv_import)
if ($actualMigrations[-1] -cne '006_test.sql') {
    throw 'Committed migration 006_test.sql was not discovered dynamically.'
}
```

Also create an untracked `007_untracked.sql` and assert it is absent.

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_manifest.ps1
```

Expected: FAIL because the manifest still contains the hard-coded `000–005` list.

- [ ] **Step 3: Implement committed migration discovery**

Use Git rather than filesystem enumeration:

```powershell
function Get-CommittedMigrationFiles([string] $ProjectRoot, [string] $Head) {
    @(& git -C $ProjectRoot ls-tree -r --name-only $Head -- database/migrations |
        Where-Object { $_ -match '^database/migrations/[^/]+\.sql$' } |
        ForEach-Object { Split-Path -Leaf $_ } |
        Sort-Object { [regex]::Replace($_, '\d+', { param($m) $m.Value.PadLeft(12, '0') }) })
}
```

Populate every project migration array through this function; projects with no committed migration directory return an empty array.

- [ ] **Step 4: Run manifest tests and verify GREEN**

Run the command from Step 2. Expected: `Release manifest generation checks passed.`

- [ ] **Step 5: Commit**

```powershell
git add tools/new_release_manifest.ps1 tests/test_release_manifest.ps1
git commit -m "feat: inventory committed release migrations"
```

---

### Task 2: Compare attested Git code with an environment

**Files:**
- Create: `tools/compare_environment_code.ps1`
- Create: `tests/test_compare_environment_code.ps1`

**Interfaces:**
- Consumes: `ProjectName`, `SourceRoot`, `DestinationRoot`, `ExpectedGitSha`, and optional `LocalTestMode`.
- Produces: objects with exact properties `Project`, `Type`, and `RelativePath`; `Type` is `New`, `Modified`, or `Deleted` from the perspective of the Git source.

- [ ] **Step 1: Write failing comparison tests**

Build a temporary Git repository and destination containing one new, modified, deleted, and equal file. Add excluded `.env`, CSV, log, runtime, `vendor`, and `.deployment` files. Invoke the missing script and assert:

```powershell
$changes = @(& $scriptPath -ProjectName finance_report -SourceRoot $source `
    -DestinationRoot $destination -ExpectedGitSha $sha -LocalTestMode)
Assert-True (@($changes | Where-Object Type -eq 'New').Count -eq 1) 'New count mismatch.'
Assert-True (@($changes | Where-Object Type -eq 'Modified').Count -eq 1) 'Modified count mismatch.'
Assert-True (@($changes | Where-Object Type -eq 'Deleted').Count -eq 1) 'Deleted count mismatch.'
Assert-True (@($changes | Where-Object RelativePath -match '\.env|\.csv|logs|vendor').Count -eq 0) 'Excluded path leaked.'
```

Add assertions that a dirty source and a SHA mismatch are rejected.

- [ ] **Step 2: Run the test and verify RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_compare_environment_code.ps1
```

Expected: FAIL because `compare_environment_code.ps1` does not exist.

- [ ] **Step 3: Implement the comparison script**

Reuse the same mandatory exclusion semantics as `sync_to_server.ps1`. Enumerate the attested tree with `git ls-tree`, materialize tracked blobs into a temporary staging directory, hash source and destination files with SHA-256, and emit only code differences. Reject a dirty repository and delete the staging directory in `finally`.

The final output object is:

```powershell
[pscustomobject]@{
    Project = $ProjectName
    Type = $changeType
    RelativePath = $relativePath
}
```

- [ ] **Step 4: Run comparison and existing deployment tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_compare_environment_code.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
```

Expected: both pass with no warnings.

- [ ] **Step 5: Commit**

```powershell
git add tools/compare_environment_code.ps1 tests/test_compare_environment_code.ps1
git commit -m "feat: compare environment code with attested Git"
```

---

### Task 3: Add shared release state and risk classification

**Files:**
- Create: `tools/release_common.ps1`
- Create: `tests/test_release_common.ps1`

**Interfaces:**
- Produces `Get-D365ProjectMap([string] $SourceParent, [string] $EnvironmentRoot)`.
- Produces `Assert-D365CleanReleaseRepositories([hashtable] $Projects)`.
- Produces `Get-D365ReleaseMetadata([string] $EnvironmentRoot, [hashtable] $Manifest)`.
- Produces `Get-D365ReleaseRisk([string] $RepositoryRoot, [string] $FromSha, [string] $ToSha)` returning `CodeOnly`, `Migration`, or `Operational` plus changed paths.
- Produces `Assert-D365Approval([string] $Expected, [string] $Actual)` using ordinal case-sensitive equality.

- [ ] **Step 1: Write failing shared-function tests**

Cover clean/dirty repositories, three matching metadata files, one mismatched SHA, exact approval phrase case, and risk classification:

```powershell
Assert-Equal 'CodeOnly' (Get-D365ReleaseRisk $repo $baseSha $phpSha).Kind
Assert-Equal 'Migration' (Get-D365ReleaseRisk $repo $phpSha $migrationSha).Kind
Assert-Equal 'Operational' (Get-D365ReleaseRisk $repo $migrationSha $composerSha).Kind
```

Operational paths are exactly `.env.example`, `composer.json`, `composer.lock`, `install_task_scheduler.ps1`, `uninstall_task_scheduler.ps1`, `.htaccess`, `config/**`, `deployment/**`, and `tools/release_security.ps1`.

- [ ] **Step 2: Run and verify RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_common.ps1
```

Expected: FAIL because the shared functions do not exist.

- [ ] **Step 3: Implement minimal shared functions**

Use `git status --porcelain --untracked-files=all`, `git rev-parse`, `git diff --name-only <from>..<to>`, strict JSON loading, and exact project sets. Do not read credentials in this module.

- [ ] **Step 4: Run and verify GREEN**

Run the command from Step 2. Expected: all shared release checks pass.

- [ ] **Step 5: Commit**

```powershell
git add tools/release_common.ps1 tests/test_release_common.ps1
git commit -m "feat: add release state and risk guards"
```

---

### Task 4: Implement UAT deploy and compare actions

**Files:**
- Create: `release.ps1`
- Create: `tests/test_release_menu.ps1`

**Interfaces:**
- `release.ps1` parameters:

```powershell
param(
    [ValidateSet('Menu','DeployUAT','Compare','PromoteProduction')]
    [string] $Action = 'Menu',
    [string] $ReleaseId,
    [string] $SourceParent = 'C:\xampp\htdocs',
    [string] $UatRoot = '\\100.1.1.166\htdocs\uat',
    [string] $ProductionRoot = '\\100.1.1.166\htdocs\prod',
    [switch] $PlanOnly,
    [switch] $LocalTestMode
)
```

- `DeployUAT` creates a manifest and invokes `sync_to_server.ps1` for all three projects.
- `Compare` validates UAT metadata and invokes `compare_environment_code.ps1` for UAT and Production.

- [ ] **Step 1: Write failing action-routing tests**

Use temporary repositories and environment roots. Verify `-Action DeployUAT -PlanOnly` returns a Thai plan without copying, invalid release IDs fail, missing directories fail, and `-Action Compare` reports the exact per-project counts.

- [ ] **Step 2: Run and verify RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
```

Expected: FAIL because `release.ps1` does not exist.

- [ ] **Step 3: Implement Thai menu and UAT/Compare routing**

Map numeric input to the four actions. Keep the root script focused on prompting and routing. Invoke existing scripts with splatted parameter hashtables and check `$LASTEXITCODE` after external commands. Print Thai headings and retain machine-readable objects in non-interactive mode.

The UAT confirmation is exactly:

```text
APPROVE UAT <release-id>
```

- [ ] **Step 4: Run menu, comparison, manifest, and sync tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_compare_environment_code.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_manifest.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
```

Expected: all pass.

- [ ] **Step 5: Commit**

```powershell
git add release.ps1 tests/test_release_menu.ps1
git commit -m "feat: add Thai UAT deploy and compare menu"
```

---

### Task 5: Implement code-only Production promotion

**Files:**
- Modify: `release.ps1`
- Modify: `tests/test_release_menu.ps1`

**Interfaces:**
- `PromoteProduction` consumes the UAT manifest and canonical approval audit root.
- Produces a summary with `ReleaseId`, project SHAs, pre-deploy change counts, config status, HTTP status, and post-deploy difference count.

- [ ] **Step 1: Write failing Production gate tests**

Cover: UAT SHA mismatch, actual UAT code drift, missing UAT acceptance phrase, missing receipt, incorrect receipt hash, rejected Production phrase, and successful code-only plan. Assert no Production file changes on every rejected path.

- [ ] **Step 2: Run and verify RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
```

Expected: FAIL because `PromoteProduction` is not implemented.

- [ ] **Step 3: Implement code-only promotion**

Before any copy, run UAT/Git comparison and require zero differences. Create the receipt through `approve_uat_release.ps1` only after:

```text
APPROVE UAT RESULT <release-id>
```

Calculate its SHA-256, run Production CompareOnly for all projects, then require:

```text
APPROVE PRODUCTION <release-id>
```

Invoke `sync_to_server.ps1` with the exact receipt path and hash. Run each config guard, read-only HTTP endpoints, and post-deploy UAT/Production comparison. Stop if risk classification is `Operational`.

- [ ] **Step 4: Run all menu tests and deployment security tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_approve_uat_release.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
```

Expected: all pass.

- [ ] **Step 5: Commit**

```powershell
git add release.ps1 tests/test_release_menu.ps1
git commit -m "feat: promote accepted UAT release to Production"
```

---

### Task 6: Add guarded migration coordination

**Files:**
- Create: `tools/release_migration.ps1`
- Create: `tests/test_release_migration.ps1`
- Modify: `release.ps1`
- Modify: `tests/test_release_menu.ps1`

**Interfaces:**
- Produces `Invoke-D365MigrationPromotion` with `ReleaseId`, `ManifestPath`, `ProjectRoot`, `BackupRoot`, `TaskNames`, `ApprovalToken`, and a local-test command adapter.
- Returns checkpoint, rehearsal, receipt, first apply result, second apply result, and restored task states.

- [ ] **Step 1: Write failing migration-order tests**

The local command adapter records stages. Assert the exact successful order:

```text
validate-uat-ledger
disable-production-tasks
checkpoint-production
prepare-rehearsal
restore-rehearsal
verify-rehearsal
approve-rehearsal
approve-production-migration
apply-production
apply-production-idempotence-check
verify-production
```

Assert an incorrect `APPLY MIGRATION <release-id>` phrase stops before `apply-production`. Assert rehearsal, checksum, first apply, second apply, and verification failures leave tasks disabled.

- [ ] **Step 2: Run and verify RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_migration.ps1
```

Expected: FAIL because the migration coordinator does not exist.

- [ ] **Step 3: Implement migration coordination around existing tools**

Read task states before disabling them. Invoke `database_checkpoint.ps1`, `prepare_restore_rehearsal.ps1`, the isolated restore/verification command adapter, `approve_restore_rehearsal.ps1`, and `apply_migrations.php`. Never place passwords in arguments or output. Require:

```text
RESTORE TEST PASSED <release-id>
APPLY MIGRATION <release-id>
```

Parse both migration JSON results. The first may list committed unapplied migrations; the second must contain an empty `applied` array. Restore only previously enabled task states after the caller reports successful Production deploy/config/smoke checks.

- [ ] **Step 4: Connect migration result to Production promotion**

When risk is `Migration`, call the coordinator before code deployment. When risk is `Operational`, stop. Ensure code deployment cannot run if migration verification is absent or failed.

- [ ] **Step 5: Run migration and menu tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_migration.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_release_menu.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_database_checkpoint.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_prepare_restore_rehearsal.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_approve_restore_rehearsal.ps1
```

Expected: all pass and no real database/task access occurs.

- [ ] **Step 6: Commit**

```powershell
git add tools/release_migration.ps1 tests/test_release_migration.ps1 release.ps1 tests/test_release_menu.ps1
git commit -m "feat: guard Production migration promotion"
```

---

### Task 7: Document and verify the complete operator flow

**Files:**
- Modify: `docs/uat-production-runbook.md`
- Modify: `README.md`

**Interfaces:**
- Documents `release.ps1` menu and non-interactive commands.
- Provides recovery instructions tied to the exact stopped stage.

- [ ] **Step 1: Add operator documentation**

Document these commands:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1 -Action DeployUAT -ReleaseId 2026-08-05.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1 -Action Compare -ReleaseId 2026-08-05.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1 -Action PromoteProduction -ReleaseId 2026-08-05.1
```

State that the operator commits first, tests UAT manually, and never copies UAT files directly to Production.

- [ ] **Step 2: Run the complete PowerShell regression suite**

```powershell
Get-ChildItem tests -Filter 'test_*.ps1' | Sort-Object Name | ForEach-Object {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" }
}
```

Expected: every test exits `0` with no warnings.

- [ ] **Step 3: Run PHP regression tests**

```powershell
C:\xampp\php\php.exe tests\run.php
```

Expected: all PHP tests pass.

- [ ] **Step 4: Verify repository scope**

```powershell
git diff --check
git status --short
```

Expected: only the planned documentation files are uncommitted at this step and `git diff --check` prints nothing.

- [ ] **Step 5: Commit**

```powershell
git add docs/uat-production-runbook.md README.md
git commit -m "docs: add Thai release menu runbook"
```

- [ ] **Step 6: Run final verification after the commit**

Run the complete PowerShell and PHP commands from Steps 2 and 3 again. Expected: every test passes, `git status --short` is empty, and the test output contains no access to the real UAT or Production paths.
