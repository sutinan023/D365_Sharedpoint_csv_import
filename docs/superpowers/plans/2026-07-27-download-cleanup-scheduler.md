# Download Cleanup Scheduler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install and uninstall a separate monthly Windows task for safe download cleanup.

**Architecture:** Extend the existing installer with a second action and monthly trigger pointing at `run_download_cleanup.bat`. Refactor the uninstaller to iterate over the import and cleanup task names. A PowerShell static test checks script intent without registering tasks.

**Tech Stack:** PowerShell 5+, Windows Task Scheduler

## Global Constraints

- Keep `D365 SharePoint CSV Import` scheduled every five minutes.
- Create `D365 SharePoint CSV Download Cleanup` for day 1 at 01:00 monthly.
- Cleanup executes `run_download_cleanup.bat` from the project root.
- Both tasks use a one-hour execution limit and ignore overlapping instances.
- The uninstaller stops and removes either task if it exists.
- Tests do not register, start, stop, or remove Windows Scheduled Tasks.

---

### Task 1: Cleanup Task Installation and Removal

**Files:**
- Modify: `install_task_scheduler.ps1`
- Modify: `uninstall_task_scheduler.ps1`
- Create: `tests/test_task_scheduler_scripts.ps1`

**Interfaces:**
- Consumes: project root, `run_import.bat`, `run_download_cleanup.bat`, and `C:\xampp\php\php.exe`.
- Produces: an installer for both named tasks and an uninstaller that removes both tasks safely.

- [ ] **Step 1: Write the failing static test**

Create `tests\test_task_scheduler_scripts.ps1` that reads both installer scripts and requires these exact strings:

```powershell
$requiredInstallerText = @(
    'D365 SharePoint CSV Download Cleanup',
    'run_download_cleanup.bat',
    'schtasks.exe',
    '/SC MONTHLY',
    '/D 1',
    '/ST 01:00',
    'New-TimeSpan -Hours 1',
    'MultipleInstances IgnoreNew'
)
```

The uninstaller assertions require both task names and `Stop-ScheduledTask` plus `Unregister-ScheduledTask`.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_task_scheduler_scripts.ps1
```

Expected: failure because the cleanup task text is absent.

- [ ] **Step 3: Implement the installer and uninstaller**

In `install_task_scheduler.ps1`, keep the existing import task and add:

```powershell
$CleanupTaskName = 'D365 SharePoint CSV Download Cleanup'
$CleanupBatchPath = Join-Path $ProjectPath 'run_download_cleanup.bat'
& schtasks.exe /Create /TN $CleanupTaskName /TR $CleanupBatchPath /SC MONTHLY /D 1 /ST 01:00 /RL LIMITED /F
if ($LASTEXITCODE -ne 0) {
    throw "Unable to create scheduled task: $CleanupTaskName"
}
Set-ScheduledTask -TaskName $CleanupTaskName -Settings $Settings
```

Validate `run_download_cleanup.bat` before registering either task. In `uninstall_task_scheduler.ps1`, replace the single name with an array of both names and retain the existing running-task stop and safe missing-task behavior for each name.

- [ ] **Step 4: Run focused verification**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_task_scheduler_scripts.ps1
git diff --check
```

Expected: test prints success and `git diff --check` has no output.

- [ ] **Step 5: Commit**

```powershell
git add install_task_scheduler.ps1 uninstall_task_scheduler.ps1 tests/test_task_scheduler_scripts.ps1
git commit -m "feat: schedule monthly download cleanup"
```
