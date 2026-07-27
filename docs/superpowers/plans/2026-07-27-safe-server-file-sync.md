# Safe Server File Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace destructive mirror synchronization with an approval-gated copy of only new and modified project files.

**Architecture:** The batch launcher calls a PowerShell script located under `tools`. The script builds a hash-based change list, displays it, and copies only after exact `APPROVE` input. It never removes destination content.

**Tech Stack:** Windows batch, PowerShell 5+, SHA-256

## Global Constraints

- The destination is exactly `\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import`.
- Do not delete files or directories from the destination.
- Copy only files that are new or have a different SHA-256 hash.
- Require exact `APPROVE` before copying.
- Exclude `.git`, `.agents`, `*.log`, `*.tmp`, `download`, `archive`, `error`, `temp`, `logs`, `vendor`, `.env`, and `config\.env`.
- Tests must use local temporary directories and must not access the UNC destination.

---

### Task 1: Safe Synchronization Script and Local Tests

**Files:**
- Modify: `sync_to_server.bat`
- Create: `tools/sync_to_server.ps1`
- Modify: `tests/test_sync_to_server.ps1`

**Interfaces:**
- Consumes: source root from the batch script directory and the fixed UNC destination.
- Produces: an interactive safe-copy command; `-CompareOnly` lists changes without copying.

- [ ] **Step 1: Write failing PowerShell tests**

Add local temporary-directory tests that call `tools/sync_to_server.ps1` with `-SourceRoot`, `-DestinationRoot`, `-CompareOnly`, and `-Exclude @()`. Verify a missing destination file is listed as `New`, a different file is listed as `Modified`, an equal-hash file produces no change, and an excluded `logs\ignored.log` file is not listed.

- [ ] **Step 2: Run the test to verify it fails**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
```

Expected: failure because `tools\sync_to_server.ps1` does not exist.

- [ ] **Step 3: Implement the PowerShell sync script and launcher**

Create `tools\sync_to_server.ps1` with these parameters:

```powershell
param(
    [string] $SourceRoot,
    [string] $DestinationRoot = '\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import',
    [string[]] $Exclude = @('.git', '.agents', '*.log', '*.tmp', 'download', 'archive', 'error', 'temp', 'logs', 'vendor', '.env', 'config\.env'),
    [switch] $CompareOnly
)
```

Resolve both roots, scan source files recursively, exclude matching relative paths, compare SHA-256 hashes, print changes, and copy only after `Read-Host` returns exactly `APPROVE`. Do not call `Remove-Item` or Robocopy `/MIR`.

Replace `sync_to_server.bat` with:

```bat
@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\sync_to_server.ps1"
pause
```

- [ ] **Step 4: Run focused verification**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
git diff --check
```

Expected: local safe-sync tests pass and `git diff --check` has no output.

- [ ] **Step 5: Commit**

```powershell
git add sync_to_server.bat tools/sync_to_server.ps1 tests/test_sync_to_server.ps1
git commit -m "feat: add safe server file sync"
```
