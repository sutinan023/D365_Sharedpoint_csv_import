# Server File Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a guarded Windows batch script that mirrors this project to `\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import`.

**Architecture:** A root-level batch script resolves its source from `%~dp0`, confirms that the network destination exists, warns the operator, and invokes `robocopy /MIR` only after explicit `Y` confirmation. A PowerShell test performs static assertions against the script without contacting or changing the network destination.

**Tech Stack:** Windows batch, Robocopy, PowerShell

## Global Constraints

- The destination is exactly `\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import`.
- The source is the directory containing `sync_to_server.bat`.
- Mirror mode deletes files and directories that exist only at the destination.
- The `.git` directory is excluded.
- Any confirmation response other than `Y` cancels before Robocopy runs.
- Robocopy exit codes 0-7 map to script exit code 0; codes 8 and above map to script exit code 1.
- Implementation verification must not run synchronization against the network destination.

---

### Task 1: Guarded Mirror Script

**Files:**
- Create: `sync_to_server.bat`
- Create: `tests/test_sync_to_server.ps1`

**Interfaces:**
- Consumes: Windows `robocopy` and access to the configured UNC destination.
- Produces: `sync_to_server.bat`, an interactive command with process exit code 0 for success and 1 for cancellation, unreachable destination, or Robocopy failure.

- [ ] **Step 1: Write the failing static test**

Create `tests/test_sync_to_server.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\sync_to_server.bat'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing sync_to_server.bat"
}

$content = Get-Content -LiteralPath $scriptPath -Raw
$checks = @{
    'script-relative source' = $content -match 'set "SOURCE=%~dp0"'
    'exact UNC destination' = $content -match [regex]::Escape('set "DESTINATION=\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import"')
    'destination reachability check' = $content -match 'if not exist "%DESTINATION%\\NUL"'
    'explicit Y confirmation' = $content -match 'if /I not "%CONFIRM%"=="Y"'
    'mirror mode' = $content -match '(?i)robocopy[^\r\n]+/MIR'
    'git exclusion' = $content -match '(?i)/XD[^\r\n]+"%SOURCE%\.git"'
    'robocopy failure threshold' = $content -match 'if %ROBOCOPY_EXIT% GEQ 8'
}

$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })
if ($failed.Count -gt 0) {
    throw "Failed checks: $($failed.Name -join ', ')"
}

Write-Host 'sync_to_server.bat static checks passed.'
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
```

Expected: failure containing `Missing sync_to_server.bat`.

- [ ] **Step 3: Write the minimal batch script**

Create `sync_to_server.bat`:

```bat
@echo off
setlocal

set "SOURCE=%~dp0"
set "DESTINATION=\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import"

echo Source:      %SOURCE%
echo Destination: %DESTINATION%
echo.
echo WARNING: Mirror mode will delete destination files that do not exist in the source.
echo The .git directory will not be synchronized.
echo.

if not exist "%DESTINATION%\NUL" (
    echo ERROR: Destination is not reachable.
    exit /b 1
)

set "CONFIRM="
set /p "CONFIRM=Continue? Type Y to start: "
if /I not "%CONFIRM%"=="Y" (
    echo Synchronization cancelled.
    exit /b 1
)

robocopy "%SOURCE%" "%DESTINATION%" /MIR /XD "%SOURCE%.git"
set "ROBOCOPY_EXIT=%ERRORLEVEL%"

echo.
echo Robocopy exit code: %ROBOCOPY_EXIT%
if %ROBOCOPY_EXIT% GEQ 8 (
    echo ERROR: Synchronization failed.
    exit /b 1
)

echo Synchronization completed successfully.
exit /b 0
```

- [ ] **Step 4: Run static and syntax-oriented verification**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_sync_to_server.ps1
```

Expected: `sync_to_server.bat static checks passed.`

Then run:

```powershell
git diff --check
```

Expected: no output and exit code 0.

- [ ] **Step 5: Commit the implementation**

```powershell
git add sync_to_server.bat tests/test_sync_to_server.ps1
git commit -m "feat: add guarded server mirror script"
```
