# Schtasks Three-Field CSV Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the migration safety adapter accept the real server's exact three-field non-verbose `schtasks` CSV record while remaining fail closed.

**Architecture:** Keep the existing remote query command unchanged and replace only the full-record CSV regex. Update the hermetic command fake to emit the observed three fields and add malformed-record regression cases.

**Tech Stack:** Windows PowerShell 5.1, `schtasks.exe /FO CSV /NH`, existing migration-adapter PowerShell test harness.

## Global Constraints

- Modify only `tools/manual_restore_migration_adapter.ps1` and `tests/test_manual_restore_migration_adapter.ps1`.
- Keep scheduler command arguments, remote-server derivation, task mutation behavior, database/import code, credentials, and prompts unchanged.
- Parse exactly `TaskName,NextRunTime,State`; reject missing or extra fields.
- Compare task names with `StringComparison.Ordinal` and accept only `Running`, `Ready`, or `Disabled`.
- Tests remain hermetic and never contact or mutate a real Task Scheduler.
- Release `2026-08-03.5` remains immutable; promotion uses a new release after verification.

---

## File Structure

- Modify `tests/test_manual_restore_migration_adapter.ps1`: use the observed three-field output and add raw-record/malformed-record coverage.
- Modify `tools/manual_restore_migration_adapter.ps1`: parse and consume exactly three CSV fields.

### Task 1: Three-Field Full-Record Parser

**Files:**
- Modify: `tests/test_manual_restore_migration_adapter.ps1`
- Modify: `tools/manual_restore_migration_adapter.ps1`

**Interfaces:**
- Consumes unchanged scheduler output: `"<full-task-name>","<next-run-time>","<state>"`.
- Preserves snapshot result: `[pscustomobject]@{ FullName=string; Enabled=bool; State=string }`.

- [ ] **Step 1: Write failing regression tests from the real server record**

Extend `$schedulerState` with a nullable `CsvOutputOverride`, reset it in `Reset-FakeSchtasks`, and make the fake return the override when present. Otherwise return exactly:

```powershell
return [pscustomobject]@{
    ExitCode = 0
    Output = ('"{0}","N/A","{1}"' -f $taskName, $state)
}
```

The normal success flow therefore exercises the observed record:

```text
"\D365 SharePoint CSV Import [PROD]","N/A","Disabled"
```

Add fail-closed cases by setting `CsvOutputOverride` to each exact value before calling `disable-production-tasks`:

```powershell
'"\D365 File CSV Import [PROD]","N/A"'
'"\D365 File CSV Import [PROD]","N/A","Ready","Interactive/Background"'
'"\Wrong [PROD]","N/A","Ready"'
'"\D365 File CSV Import [PROD]","N/A","Unknown"'
```

For every malformed case, assert the adapter throws and `Assert-NoStateChanges` remains true.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_manual_restore_migration_adapter.ps1
```

Expected: FAIL with `Task Scheduler returned invalid CSV` because the production regex still requires a fourth field.

- [ ] **Step 3: Replace the parser with an exact three-field regex**

In `tools/manual_restore_migration_adapter.ps1`, replace only `$csvMatch` with:

```powershell
$csvMatch = [regex]::Match(
    $csvOutput,
    '^\s*"(?<name>(?:[^"]|"")*)"\s*,\s*"(?:[^"]|"")*"\s*,\s*"(?<state>(?:[^"]|"")*)"\s*(?:\r?\n)?$'
)
```

Keep the existing doubled-quote decoding, ordinal name comparison, allowed-state check, and snapshot return unchanged. The end anchor must reject a fourth field or any other trailing content.

- [ ] **Step 4: Run focused tests and parser checks**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_manual_restore_migration_adapter.ps1
powershell -NoProfile -Command '$errors=$null; [void][Management.Automation.Language.Parser]::ParseFile("tools\manual_restore_migration_adapter.ps1",[ref]$null,[ref]$errors); if($errors.Count){$errors | ForEach-Object Message; exit 1}'
git diff --check
```

Expected: focused checks pass, parser has zero errors, and diff check is empty.

- [ ] **Step 5: Run the full regression suite**

Run every PowerShell test:

```powershell
$tests = Get-ChildItem .\tests -Filter 'test_*.ps1' | Sort-Object Name
foreach ($test in $tests) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "FAILED $($test.Name)" }
}
```

Run PHP tests:

```powershell
C:\xampp\php\php.exe .\tests\run.php
```

Expected: all 16 PowerShell test files pass and PHP reports `Tests passed: 97`.

- [ ] **Step 6: Run one read-only live compatibility check**

Run only:

```powershell
schtasks.exe /Query /S 100.1.1.166 /TN '\D365 SharePoint CSV Import [PROD]' /FO CSV /NH
```

Expected: one three-field record ending in `"Disabled"`. Do not run `/End`, `/Change`, `/Enable`, or `/Disable`.

- [ ] **Step 7: Commit**

```powershell
git add tools/manual_restore_migration_adapter.ps1 tests/test_manual_restore_migration_adapter.ps1
git commit -m "fix: parse three-field schtasks output"
```

- [ ] **Step 8: Promote as a new immutable UAT release**

Push `main`, run release menu option 1, expect release `2026-08-03.6`, update UAT `APP_RELEASE`, run menu option 3, verify UAT totals are zero, and obtain explicit Production cutover approval for `.6` before retrying menu option 2.
