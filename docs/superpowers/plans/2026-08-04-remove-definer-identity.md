# Remove DEFINER Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sanitize MySQL view dumps that contain a `DEFINER=<user>@<host>` identity with either INVOKER or DEFINER security while preserving all fail-closed rehearsal protections.

**Architecture:** Split the current combined regular expression into independent identity and security-mode patterns. Validate both against recognized view ranges, strip identities only inside those views, convert DEFINER security to INVOKER, and verify the final executable security-mode count against the source view clauses.

**Tech Stack:** Windows PowerShell 5.1, .NET regular expressions, repository-native PowerShell test scripts, PHP CLI regression suite.

## Global Constraints

- Modify only `tools/prepare_restore_rehearsal.ps1`, `tests/test_prepare_restore_rehearsal.ps1`, and a directly affected adapter fixture if a regression requires it.
- Do not change migration SQL, checkpoint contents, credentials, import logic, Scheduled Tasks, SharePoint data, UAT data, or Production data.
- Matching text inside SQL strings and non-executable comments must not be transformed or counted.
- An executable identity or definer-security clause outside a recognized view block must fail before output creation.
- The failed `2026-08-03.7` release remains immutable; deployment uses the next generated release ID and a fresh checkpoint.

---

### Task 1: Separate view identity sanitization from security-mode validation

**Files:**
- Modify: `tests/test_prepare_restore_rehearsal.ps1:10-180`
- Modify: `tools/prepare_restore_rehearsal.ps1:277-360`

**Interfaces:**
- Consumes: the existing `prepare_restore_rehearsal.ps1` parameters, view-block recognition, lexical protected spans, checkpoint counts, and audit receipt.
- Produces: sanitized view DDL containing no executable `DEFINER=` or `SQL SECURITY DEFINER`, with every original view security clause represented as `SQL SECURITY INVOKER`.

- [ ] **Step 1: Add the failing Production-format test**

Add a fixture derived from the real dump, with an identity attached to an already-Invoker view and `ExpectedDefinerCount 0`:

```powershell
$invokerIdentitySourcePath = Join-Path $testRoot 'invoker-identity-source.sql'
$invokerIdentityOutputPath = Join-Path $testRoot 'invoker-identity-sanitized.sql'
$invokerIdentityDump = (Get-TestDump -DatabaseName 'D365_finance').Replace(
    'DEFINER=`kaew`@`%` SQL SECURITY DEFINER',
    'DEFINER=`d365_finance_prod_migrator`@`%` SQL SECURITY INVOKER'
)
[IO.File]::WriteAllText($invokerIdentitySourcePath, $invokerIdentityDump, (New-Object Text.UTF8Encoding($false)))
$invokerIdentityHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $invokerIdentitySourcePath).Hash.ToLowerInvariant()
& $scriptPath -BackupPath $invokerIdentitySourcePath -ExpectedSourceSha256 $invokerIdentityHash `
    -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260804_1' `
    -OutputPath $invokerIdentityOutputPath -ExpectedDefinerCount 0 -ExpectedQualifiedReferenceCount 22 | Out-Null
$invokerIdentitySanitized = [IO.File]::ReadAllText($invokerIdentityOutputPath)
if ($invokerIdentitySanitized -match 'DEFINER\s*=|SQL SECURITY DEFINER') { throw 'INVOKER fixture retained a definer.' }
if (([regex]::Matches($invokerIdentitySanitized, 'SQL SECURITY INVOKER')).Count -ne 2) { throw 'INVOKER fixture changed its security count.' }
```

Also add two fail-closed cases before output creation:

```powershell
foreach ($outsideDefinerSql in @(
    'SELECT DEFINER=`outside`@`%`;',
    'SELECT SQL SECURITY DEFINER;'
)) {
    $outsideDefinerPath = Join-Path $testRoot ('outside-definer-{0}.sql' -f [guid]::NewGuid())
    [IO.File]::WriteAllText($outsideDefinerPath, ((Get-TestDump -DatabaseName 'D365_finance') + "`n$outsideDefinerSql`n"), (New-Object Text.UTF8Encoding($false)))
    $outsideDefinerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $outsideDefinerPath).Hash.ToLowerInvariant()
    Assert-Throws { & $scriptPath -BackupPath $outsideDefinerPath -ExpectedSourceSha256 $outsideDefinerHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260804_1' -OutputPath "$outsideDefinerPath.out" -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'outside a recognized VIEW'
    if (Test-Path -LiteralPath "$outsideDefinerPath.out") { throw 'Outside definer left sanitized output.' }
}
```

Add protected literal coverage and assert it remains byte-for-byte unchanged:

```powershell
$protectedDefinerText = @"
INSERT INTO ``audit_log`` VALUES ('literal DEFINER=``keep``@``%`` SQL SECURITY DEFINER');
-- DEFINER=``comment``@``%`` SQL SECURITY DEFINER
/* DEFINER=``block_comment``@``%`` SQL SECURITY DEFINER */
"@
$protectedDefinerSourcePath = Join-Path $testRoot 'protected-definer-source.sql'
$protectedDefinerOutputPath = Join-Path $testRoot 'protected-definer-sanitized.sql'
[IO.File]::WriteAllText($protectedDefinerSourcePath, ((Get-TestDump -DatabaseName 'D365_finance') + "`n$protectedDefinerText"), (New-Object Text.UTF8Encoding($false)))
$protectedDefinerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $protectedDefinerSourcePath).Hash.ToLowerInvariant()
& $scriptPath -BackupPath $protectedDefinerSourcePath -ExpectedSourceSha256 $protectedDefinerHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260804_1' -OutputPath $protectedDefinerOutputPath -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 | Out-Null
if ([IO.File]::ReadAllText($protectedDefinerOutputPath) -notmatch [regex]::Escape($protectedDefinerText.Trim())) { throw 'Sanitizer changed protected definer text.' }
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_prepare_restore_rehearsal.ps1
```

Expected: FAIL on the INVOKER-identity fixture because the current combined pattern does not remove its identity.

- [ ] **Step 3: Implement independent identity and security patterns**

Replace the combined `$definerPattern` with:

```powershell
$definerIdentityPattern = '(?is)\bDEFINER\s*=\s*`[^`]+`\s*@\s*`[^`]+`'
$definerSecurityPattern = '(?is)\bSQL\s+SECURITY\s+DEFINER\b'
$invokerSecurityPattern = '(?is)\bSQL\s+SECURITY\s+INVOKER\b'
```

Update `Convert-ViewBlock` so each non-protected segment applies transformations in this order:

```powershell
$nonStringSegment = [regex]::Replace($nonStringSegment, $DefinerIdentityPattern, '')
$nonStringSegment = [regex]::Replace($nonStringSegment, $DefinerSecurityPattern, 'SQL SECURITY INVOKER')
$nonStringSegment = [regex]::Replace($nonStringSegment, $QualifierPattern, ('`' + $ReplacementDatabase + '`.'), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
```

Apply the same order to `$remainingSegment`. Pass both patterns as named parameters to `Convert-ViewBlock`.

Collect executable matches independently:

```powershell
$allDefinerIdentities = @([regex]::Matches($sourceText, $definerIdentityPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sourceLexicalSpans.ProtectedSpans) })
$allDefinerSecurityClauses = @([regex]::Matches($sourceText, $definerSecurityPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sourceLexicalSpans.ProtectedSpans) })
$allInvokerSecurityClauses = @([regex]::Matches($sourceText, $invokerSecurityPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sourceLexicalSpans.ProtectedSpans) })
```

Require every identity and both security-mode clause types to be inside `$viewBlocks`. Set `$definerCount = $allDefinerSecurityClauses.Count`, compare it with `ExpectedDefinerCount`, and set:

```powershell
$expectedInvokerCount = $allDefinerSecurityClauses.Count + $allInvokerSecurityClauses.Count
```

The final sanitized INVOKER count must equal `$expectedInvokerCount`, rather than `ExpectedDefinerCount`. Keep the existing final rejection of any executable `DEFINER=` identity or `SQL SECURITY DEFINER` clause.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test_prepare_restore_rehearsal.ps1
```

Expected: `Restore rehearsal preparation tests passed.`

- [ ] **Step 5: Run all regression suites**

Run every repository PowerShell test in a fresh process:

```powershell
Get-ChildItem .\tests -Filter 'test_*.ps1' | Sort-Object Name | ForEach-Object {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $_.FullName
    if ($LASTEXITCODE -ne 0) { throw "PowerShell test failed: $($_.Name)" }
}
```

Then run the PHP suite:

```powershell
C:\xampp\php\php.exe .\tests\run.php
```

Expected: all 16 PowerShell test files exit 0 and PHP reports `Tests passed: 97` (or a larger current total).

- [ ] **Step 6: Inspect the diff and commit the implementation**

Run:

```powershell
git diff --check
git diff -- tools/prepare_restore_rehearsal.ps1 tests/test_prepare_restore_rehearsal.ps1
git status --short
```

Confirm that only the planned implementation/test files changed, then commit:

```powershell
git add -- tools/prepare_restore_rehearsal.ps1 tests/test_prepare_restore_rehearsal.ps1
git commit -m "fix: sanitize invoker view definer identities"
```

Do not run `release.ps1`, create a Production checkpoint, apply a migration, deploy, retry queue item 44, or enable Scheduled Tasks as part of this implementation task.
