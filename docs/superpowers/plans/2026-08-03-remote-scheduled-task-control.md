# Remote Scheduled Task Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the local release controller validate and control the literal Production Scheduled Tasks on `100.1.1.166` before database migration.

**Architecture:** Derive the scheduler computer from the UNC Production root, then execute exact-name `schtasks.exe /S` commands through a narrow injectable adapter. Parse XML for task identity/enabled state and the first four CSV fields for runtime state; validate every configured task before any state-changing command.

**Tech Stack:** Windows PowerShell 5.1, `schtasks.exe`, Task Scheduler XML, existing release/migration adapters and PowerShell test harness.

## Global Constraints

- Do not enable WinRM or modify TrustedHosts.
- Do not accept, print, or persist passwords; use the Windows identity running elevated PowerShell.
- Treat `[PROD]` as literal text and compare task URI/name with `StringComparison.Ordinal`.
- Validate all configured tasks before stopping or disabling any task.
- Fail closed on missing tasks, malformed output, mismatched URI, unknown state, or non-zero command exit.
- Restore only tasks that were enabled before cutover; pre-disabled tasks remain disabled.
- Tests must never contact or modify a real Task Scheduler.
- Keep releases immutable; this change must be promoted as a release after `2026-08-03.4`.

---

## File Structure

- Modify `tools/manual_restore_migration_adapter.ps1`: derive the scheduler computer, wrap `schtasks.exe`, validate snapshots, and perform exact remote state changes.
- Modify `tests/test_manual_restore_migration_adapter.ps1`: fake scheduler command responses and verify query-first/fail-closed/state-restoration behavior.
- Modify `release.ps1`: derive and pass the scheduler computer to the migration adapter.
- Modify `tests/test_release_menu.ps1`: enforce the release wiring contract without contacting a server.

### Task 1: Exact Remote Scheduler Adapter

**Files:**
- Modify: `tools/manual_restore_migration_adapter.ps1`
- Test: `tests/test_manual_restore_migration_adapter.ps1`

**Interfaces:**
- Produces: `Get-D365TaskSchedulerComputerName([string] $ProductionRoot) -> string`.
- Extends: `New-D365ManualRestoreMigrationAdapter([object] $Manifest, [IDictionary] $SourceProjects, [string] $ProductionRoot, [string] $BackupRoot, [string] $PhpPath, [string] $AppliedBy, [scriptblock] $WaitForManualRestore, [string] $TaskSchedulerComputerName, [scriptblock] $ScheduledTaskCommandAdapter = $null) -> scriptblock`.
- Scheduler command adapter consumes one `string[]` argument and returns an object with integer `ExitCode` and string `Output`.

- [ ] **Step 1: Replace local Scheduler fakes with a command-level fake and write failing tests**

Add a fake command adapter that records every argument array and returns deterministic XML/CSV responses:

```powershell
$script:schedulerCommands = [Collections.Generic.List[object]]::new()
$taskDefinitions = @{
    '\D365 SharePoint CSV Import [PROD]' = @{ Enabled=$false; State='Disabled' }
    '\D365 File CSV Import [PROD]' = @{ Enabled=$true; State='Ready' }
    '\D365 SharePoint CSV Download Cleanup [PROD]' = @{ Enabled=$true; State='Running' }
}
$fakeSchtasks = {
    param([string[]] $Arguments)
    $script:schedulerCommands.Add(@($Arguments))
    # Return exact Task Scheduler XML for /XML, four-field CSV for /FO CSV,
    # and ExitCode=0 for /End or /Change. Return ExitCode=1 for unknown names.
}.GetNewClosure()
```

Assert all `/Query` operations occur before the first `/End` or `/Change`, every command contains `/S 100.1.1.166`, exact `[PROD]` names are preserved, the running task is ended, enabled tasks are disabled, and restoration enables only the two initially enabled tasks.

Add isolated failure cases for missing task, invalid XML, URI mismatch, unknown CSV state, and a failing state-changing command. For each pre-validation failure, assert no `/End` or `/Change` command was recorded.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_manual_restore_migration_adapter.ps1
```

Expected: FAIL because `TaskSchedulerComputerName` and `ScheduledTaskCommandAdapter` do not exist and production code still invokes local ScheduledTasks cmdlets.

- [ ] **Step 3: Add computer-name derivation and strict command result validation**

Implement the derivation boundary:

```powershell
function Get-D365TaskSchedulerComputerName([string] $ProductionRoot) {
    if ($ProductionRoot -match '^\\\\([^\\]+)\\') { return [string] $Matches[1] }
    if ([IO.Path]::IsPathRooted($ProductionRoot)) { return [string] $env:COMPUTERNAME }
    throw 'ProductionRoot must be an absolute local path or UNC path.'
}
```

Inside `New-D365ManualRestoreMigrationAdapter`, default the command adapter to:

```powershell
if ($null -eq $ScheduledTaskCommandAdapter) {
    $ScheduledTaskCommandAdapter = {
        param([string[]] $Arguments)
        $lines = @(& schtasks.exe @Arguments 2>&1)
        [pscustomobject]@{ ExitCode=[int] $LASTEXITCODE; Output=($lines -join [Environment]::NewLine) }
    }
}
```

Reject a blank scheduler computer, a null result, missing/non-integer `ExitCode`, non-string `Output`, or any non-zero exit code. Error messages may contain the operation and task name but must not contain command output that could expose environment details.

- [ ] **Step 4: Implement exact task snapshots and validate-all-before-change**

For each task, normalize exactly one leading `\`, then run:

```powershell
@('/Query','/S',$TaskSchedulerComputerName,'/TN',$fullTaskName,'/XML')
@('/Query','/S',$TaskSchedulerComputerName,'/TN',$fullTaskName,'/FO','CSV','/NH')
```

Parse XML and require `Task.RegistrationInfo.URI` to equal `$fullTaskName` with ordinal comparison. Parse only the first four quoted CSV fields and require the returned task name to be ordinal-equal and status to be one of `Running`, `Ready`, or `Disabled`. Read `Task.Settings.Enabled` only as the exact strings `true` or `false`.

Collect all snapshots first. Then, for each snapshot:

```powershell
if ($snapshot.State -ceq 'Running') {
    Invoke-CheckedSchtasks @('/End','/S',$TaskSchedulerComputerName,'/TN',$snapshot.FullName)
}
if ($snapshot.Enabled) {
    Invoke-CheckedSchtasks @('/Change','/S',$TaskSchedulerComputerName,'/TN',$snapshot.FullName,'/Disable')
}
```

Store only initially enabled full names. During restoration, re-query each saved name and invoke `@('/Change','/S',$TaskSchedulerComputerName,'/TN',$fullTaskName,'/Enable')`; do not restore pre-disabled tasks.

- [ ] **Step 5: Run focused tests and parser validation**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_manual_restore_migration_adapter.ps1
powershell -NoProfile -Command '$errors=$null; [void][Management.Automation.Language.Parser]::ParseFile("tools\manual_restore_migration_adapter.ps1",[ref]$null,[ref]$errors); if($errors.Count){$errors | ForEach-Object Message; exit 1}'
```

Expected: adapter checks pass and parser returns exit code 0.

- [ ] **Step 6: Commit Task 1**

```powershell
git add tools/manual_restore_migration_adapter.ps1 tests/test_manual_restore_migration_adapter.ps1
git commit -m "fix: control production tasks on remote server"
```

### Task 2: Release Wiring and Regression Verification

**Files:**
- Modify: `release.ps1`
- Test: `tests/test_release_menu.ps1`

**Interfaces:**
- Consumes: `Get-D365TaskSchedulerComputerName([string])` from Task 1.
- Consumes: the new `-TaskSchedulerComputerName` argument of `New-D365ManualRestoreMigrationAdapter`.
- Produces: automatic remote scheduler targeting for interactive Production promotion without a new user prompt.

- [ ] **Step 1: Add a failing release wiring contract test**

Extend the release-menu source contract to require:

```powershell
Assert-True ($releaseScriptText.Contains(
    '$taskSchedulerComputerName = Get-D365TaskSchedulerComputerName -ProductionRoot $ProductionRoot')) `
    'Production promotion does not derive the remote scheduler computer.'
Assert-True ($releaseScriptText.Contains(
    '-TaskSchedulerComputerName $taskSchedulerComputerName')) `
    'Production promotion does not pass the remote scheduler computer to the migration adapter.'
```

Keep LocalTestMode hermetic: when a custom `MigrationCommandAdapter` is injected, neither derivation nor any real scheduler command is invoked.

- [ ] **Step 2: Run the release-menu test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_release_menu.ps1
```

Expected: FAIL because `release.ps1` does not pass the scheduler computer.

- [ ] **Step 3: Wire the derived computer into the real migration adapter**

Immediately before constructing the default migration adapter, add:

```powershell
$taskSchedulerComputerName = Get-D365TaskSchedulerComputerName -ProductionRoot $ProductionRoot
$MigrationCommandAdapter = New-D365ManualRestoreMigrationAdapter `
    -Manifest $release.Manifest -SourceProjects $sourceProjects `
    -ProductionRoot $ProductionRoot -BackupRoot $MigrationBackupRoot `
    -PhpPath $PhpPath -AppliedBy $MigrationAppliedBy `
    -TaskSchedulerComputerName $taskSchedulerComputerName `
    -WaitForManualRestore $waitForManualRestore
```

Do not add a menu question, credentials, or a second server setting.

- [ ] **Step 4: Run focused and full regression tests**

Run the focused tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_manual_restore_migration_adapter.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_release_menu.ps1
```

Run every PowerShell test:

```powershell
$tests = Get-ChildItem .\tests -Filter 'test_*.ps1' | Sort-Object Name
foreach ($test in $tests) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "FAILED $($test.Name)" }
}
```

Run PHP and repository checks:

```powershell
C:\xampp\php\php.exe .\tests\run.php
git diff --check
git status --short
```

Expected: all 16 PowerShell test files pass, PHP reports 97 passing tests, `git diff --check` is empty, and status contains only the intended Task 2 files before commit.

- [ ] **Step 5: Perform a read-only live server query**

From elevated local PowerShell, run only query operations for all three exact names:

```powershell
$names = @(
  'D365 SharePoint CSV Import [PROD]',
  'D365 File CSV Import [PROD]',
  'D365 SharePoint CSV Download Cleanup [PROD]'
)
foreach ($name in $names) {
  schtasks.exe /Query /S 100.1.1.166 /TN "\$name" /FO CSV /NH
  if ($LASTEXITCODE -ne 0) { throw "Remote task query failed: $name" }
}
```

Expected: each task is returned once with state `Disabled`. Do not run `/End`, `/Change`, `/Enable`, or `/Disable` during this verification.

- [ ] **Step 6: Commit Task 2**

```powershell
git add release.ps1 tests/test_release_menu.ps1
git commit -m "fix: target server scheduler during migration"
```

- [ ] **Step 7: Promote as a new immutable UAT release**

Push `main`, run release menu option 1, and expect automatic release `2026-08-03.5`. Update UAT `APP_RELEASE` to `.5`, run menu option 3, verify all UAT totals are zero, and obtain explicit `Production cutover 2026-08-03.5` approval before retrying menu option 2.
