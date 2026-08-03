# Live and Dump Qualified-Reference Count Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bind both the live-view reference count and the exact mysqldump reference count so restore rehearsal can safely handle MySQL's normalized view output.

**Architecture:** The checkpoint computes a conservative raw qualifier count from the hashed UTF-8 dump and adds it to the existing live verification baseline. The sanitizer requires the new native integer and uses only it for dump rewriting, while retaining the live count in the audit trail.

**Tech Stack:** Windows PowerShell 5.1, mysqldump UTF-8 SQL, JSON checkpoint manifests, existing PowerShell/PHP test harnesses.

## Global Constraints

- Preserve existing `qualified_reference_count` as the live database count.
- Add required native nonnegative integer `dump_qualified_reference_count` to `verification_baseline`.
- Legacy/malformed checkpoints fail closed before sanitized output creation.
- Explicit non-checkpoint count mode remains unchanged.
- Do not modify migration SQL, import logic, application credentials, scheduler behavior, SharePoint paths, or report code.
- Release `2026-08-03.6` remains immutable; this change promotes as a later release.

---

## File Structure

- Modify `tools/database_checkpoint.ps1`: strict UTF-8 dump reading, raw dump qualifier count, manifest binding.
- Modify `tests/test_database_checkpoint.ps1`: enforce the checkpoint source contract for the new immutable count.
- Modify `tools/prepare_restore_rehearsal.ps1`: require and consume dump count while retaining live count.
- Modify `tests/test_prepare_restore_rehearsal.ps1`: behaviorally cover live 24/dump 22 and malformed legacy manifests.
- Modify `tests/test_manual_restore_migration_adapter.ps1`: update its checkpoint fixture to the new required schema.

### Task 1: Bind Dump Count Into Checkpoint

**Files:**
- Modify: `tools/database_checkpoint.ps1`
- Test: `tests/test_database_checkpoint.ps1`

**Interfaces:**
- Produces: `verification_baseline.dump_qualified_reference_count` as a native JSON integer.
- Preserves: `verification_baseline.qualified_reference_count` from `checkpoint_baseline.php`.

- [ ] **Step 1: Add failing checkpoint source-contract tests**

Require the checkpoint script to contain all of these behaviors:

```powershell
$dumpBytes = [IO.File]::ReadAllBytes($backupFile)
$dumpText = (New-Object Text.UTF8Encoding($false, $true)).GetString($dumpBytes)
$dumpQualifierPattern = '`' + [regex]::Escape($database) + '`\.'
$dumpQualifiedReferenceCount = [regex]::Matches(
    $dumpText,
    $dumpQualifierPattern,
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
).Count
$baseline | Add-Member -NotePropertyName dump_qualified_reference_count `
    -NotePropertyValue ([int] $dumpQualifiedReferenceCount)
```

Also require a `DecoderFallbackException` branch that throws `Database checkpoint dump must be valid UTF-8.` and verify the existing live `qualified_reference_count` is not renamed or overwritten.

- [ ] **Step 2: Run the checkpoint test and verify RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_database_checkpoint.ps1
```

Expected: FAIL because the checkpoint does not bind `dump_qualified_reference_count`.

- [ ] **Step 3: Implement dump counting after the nonempty-file guard**

Read the exact completed dump with strict UTF-8, count case-insensitive exact backtick database qualifiers, reject invalid UTF-8, and add the native integer to `$baseline` before manifest serialization. If the baseline already contains that property, fail instead of overwriting it.

- [ ] **Step 4: Run focused verification and commit**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_database_checkpoint.ps1
powershell -NoProfile -Command '$errors=$null; [void][Management.Automation.Language.Parser]::ParseFile("tools\database_checkpoint.ps1",[ref]$null,[ref]$errors); if($errors.Count){$errors | ForEach-Object Message; exit 1}'
git diff --check
git add tools/database_checkpoint.ps1 tests/test_database_checkpoint.ps1
git commit -m "fix: bind dump reference count to checkpoint"
```

Expected: focused test/parser/diff checks pass.

### Task 2: Consume Dump Count During Sanitization

**Files:**
- Modify: `tools/prepare_restore_rehearsal.ps1`
- Test: `tests/test_prepare_restore_rehearsal.ps1`
- Test: `tests/test_manual_restore_migration_adapter.ps1`

**Interfaces:**
- Consumes: `verification_baseline.qualified_reference_count` as live audit count.
- Consumes: `verification_baseline.dump_qualified_reference_count` as the dump rewrite count.
- Preserves explicit mode parameters `ExpectedDefinerCount` and `ExpectedQualifiedReferenceCount` unchanged.

- [ ] **Step 1: Write failing live-24/dump-22 and malformed-manifest tests**

Change the valid checkpoint fixture to:

```powershell
verification_baseline = [ordered]@{
    definer_count = 2
    qualified_reference_count = 24
    dump_qualified_reference_count = 22
}
```

The fixture dump still contains exactly 22 executable qualifiers. Assert checkpoint mode succeeds, writes 22 rehearsal qualifiers, zero source qualifiers, and audit values:

```powershell
$automaticAudit.live_qualified_reference_count -eq 24
$automaticAudit.qualified_reference_count -eq 22
```

Add fail-closed checkpoint variants where `dump_qualified_reference_count` is missing, `-1`, `'22'`, or `23`. Assert no sanitized SQL or audit file remains. Update the manual adapter checkpoint fixture with `dump_qualified_reference_count=0`.

- [ ] **Step 2: Run both focused tests and verify RED**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_prepare_restore_rehearsal.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_manual_restore_migration_adapter.ps1
```

Expected: FAIL because checkpoint mode still uses live count 24 and accepts legacy manifests.

- [ ] **Step 3: Require both counts and select dump count**

In checkpoint mode, validate native nonnegative integers for all three fields. Store:

```powershell
$ExpectedDefinerCount = [int] $baseline.definer_count
$LiveQualifiedReferenceCount = [int] $baseline.qualified_reference_count
$ExpectedQualifiedReferenceCount = [int] $baseline.dump_qualified_reference_count
```

Initialize `$LiveQualifiedReferenceCount = $null` before the checkpoint branch. In explicit mode, leave it null. Add the following audit field without changing existing fields:

```powershell
live_qualified_reference_count = $LiveQualifiedReferenceCount
```

- [ ] **Step 4: Run focused and full regression suites**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_database_checkpoint.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_prepare_restore_rehearsal.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_manual_restore_migration_adapter.ps1
```

Then run all PowerShell tests:

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
```

Expected: all 16 PowerShell test files pass, PHP reports 97 tests, and diff check is empty.

- [ ] **Step 5: Commit and promote through UAT**

```powershell
git add tools/prepare_restore_rehearsal.ps1 tests/test_prepare_restore_rehearsal.ps1 tests/test_manual_restore_migration_adapter.ps1
git commit -m "fix: use dump count for rehearsal sanitizer"
```

After final review, push `main`, deploy expected release `2026-08-03.7` to UAT, update UAT `APP_RELEASE`, compare to zero, verify UAT, and obtain explicit `.7` Production approval before retrying cutover.
