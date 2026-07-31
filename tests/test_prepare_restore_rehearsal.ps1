$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\prepare_restore_rehearsal.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw 'Missing restore rehearsal sanitizer.'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('restore-rehearsal-test-{0}' -f [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Get-TestDump {
    param([string] $DatabaseName)

    $references = 1..22 | ForEach-Object { "SELECT $_ AS n FROM ``$DatabaseName``.``table$_``" }
    $viewOne = ($references[0..10] -join " UNION ALL\n")
    $viewTwo = ($references[11..21] -join " UNION ALL\n")
    return @"
-- isolated rehearsal fixture
/*!50001 CREATE ALGORITHM=UNDEFINED */ /*!50013 DEFINER=``kaew``@``%`` SQL SECURITY DEFINER */ /*!50001 VIEW ``vw_one`` AS
$viewOne */;
/*!50001 CREATE ALGORITHM=UNDEFINED */ /*!50013 DEFINER=``kaew``@``%`` SQL SECURITY DEFINER */ /*!50001 VIEW ``vw_two`` AS
$viewTwo */;
"@
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Message)
    try {
        & $Action
        throw "Expected failure: $Message"
    } catch {
        if ($_.Exception.Message -like 'Expected failure:*') { throw }
        if ($_.Exception.Message -notmatch $Message) { throw }
    }
}

try {
    $sourcePath = Join-Path $testRoot 'source.sql'
    $outputPath = Join-Path $testRoot 'sanitized.sql'
    [IO.File]::WriteAllText($sourcePath, (Get-TestDump -DatabaseName 'D365_finance'), (New-Object Text.UTF8Encoding($false)))
    $originalContent = [IO.File]::ReadAllText($sourcePath)
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()

    & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash `
        -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' `
        -OutputPath $outputPath -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 | Out-Null

    if ([IO.File]::ReadAllText($sourcePath) -cne $originalContent) { throw 'Source backup was modified.' }
    $sanitized = [IO.File]::ReadAllText($outputPath)
    if ($sanitized -match 'DEFINER\s*=|SQL SECURITY DEFINER|`D365_finance`\.') { throw 'Sanitized dump retained source-only clauses.' }
    if (([regex]::Matches($sanitized, 'SQL SECURITY INVOKER')).Count -ne 2) { throw 'Sanitized dump has the wrong INVOKER count.' }
    if (([regex]::Matches($sanitized, '`D365_finance_rehearsal_20260731_2130`\.')).Count -ne 22) { throw 'Sanitized dump has the wrong rehearsal qualifier count.' }
    $bytes = [IO.File]::ReadAllBytes($outputPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw 'Sanitized dump has a UTF-8 BOM.' }
    $auditPath = "$outputPath.audit.json"
    if (-not (Test-Path -LiteralPath $auditPath)) { throw 'Sanitizer did not create an audit receipt.' }
    $audit = Get-Content -Raw -LiteralPath $auditPath | ConvertFrom-Json
    if ($audit.source_sha256 -cne $sourceHash -or $audit.definer_count -ne 2 -or $audit.qualified_reference_count -ne 22) { throw 'Audit receipt is incomplete.' }

    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 ('0' * 64) -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath (Join-Path $testRoot 'bad-hash.sql') -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'hash'
    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath (Join-Path $testRoot 'bad-count.sql') -ExpectedDefinerCount 1 -ExpectedQualifiedReferenceCount 22 } 'definer'
    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'bad-name' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath (Join-Path $testRoot 'bad-name.sql') -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'database'
    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance' -OutputPath (Join-Path $testRoot 'alias.sql') -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'different'
    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath $sourcePath -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'different'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'Restore rehearsal sanitizer checks passed.'
