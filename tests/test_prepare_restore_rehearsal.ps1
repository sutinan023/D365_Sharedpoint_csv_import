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

    $checkpointPath = Join-Path $testRoot 'checkpoint.json'
    [ordered]@{
        database = 'D365_finance'
        backup_file = $sourcePath
        sha256 = $sourceHash
        verification_baseline = [ordered]@{
            definer_count = 2
            qualified_reference_count = 24
            dump_qualified_reference_count = 22
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8
    $automaticOutputPath = Join-Path $testRoot 'automatic-sanitized.sql'
    & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash `
        -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260802_1' `
        -OutputPath $automaticOutputPath -UseCheckpointBaseline -BackupManifestPath $checkpointPath | Out-Null
    if (-not (Test-Path -LiteralPath $automaticOutputPath -PathType Leaf)) { throw 'Checkpoint baseline mode did not create sanitized SQL.' }
    $automaticSanitized = [IO.File]::ReadAllText($automaticOutputPath)
    if (([regex]::Matches($automaticSanitized, '`D365_finance_rehearsal_20260802_1`\.')).Count -ne 22) { throw 'Checkpoint baseline mode wrote the wrong rehearsal qualifier count.' }
    if ($automaticSanitized -match '`D365_finance`\.') { throw 'Checkpoint baseline mode retained source qualifiers.' }
    $automaticAudit = Get-Content -Raw -LiteralPath "$automaticOutputPath.audit.json" | ConvertFrom-Json
    if ($automaticAudit.checkpoint_manifest_sha256 -cne (Get-FileHash -LiteralPath $checkpointPath -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Sanitizer audit did not bind the checkpoint manifest.'
    }
    if ($automaticAudit.live_qualified_reference_count -ne 24 -or $automaticAudit.qualified_reference_count -ne 22) {
        throw 'Sanitizer audit did not preserve separate live and dump qualifier counts.'
    }

    foreach ($invalidDumpCount in @(
        [pscustomobject]@{ Name='missing'; Include=$false; Value=$null; ExpectedError='baseline counts are invalid' },
        [pscustomobject]@{ Name='negative'; Include=$true; Value=-1; ExpectedError='baseline counts are invalid' },
        [pscustomobject]@{ Name='string'; Include=$true; Value='22'; ExpectedError='baseline counts are invalid' },
        [pscustomobject]@{ Name='mismatch'; Include=$true; Value=23; ExpectedError='Unexpected qualified reference count' }
    )) {
        $invalidCheckpointPath = Join-Path $testRoot ("invalid-dump-count-{0}.json" -f $invalidDumpCount.Name)
        $invalidBaseline = [ordered]@{ definer_count=2; qualified_reference_count=24 }
        if ($invalidDumpCount.Include) { $invalidBaseline.dump_qualified_reference_count = $invalidDumpCount.Value }
        [ordered]@{
            database = 'D365_finance'
            backup_file = $sourcePath
            sha256 = $sourceHash
            verification_baseline = $invalidBaseline
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $invalidCheckpointPath -Encoding UTF8
        $invalidOutputPath = Join-Path $testRoot ("invalid-dump-count-{0}.sql" -f $invalidDumpCount.Name)
        Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260802_1' -OutputPath $invalidOutputPath -UseCheckpointBaseline -BackupManifestPath $invalidCheckpointPath } $invalidDumpCount.ExpectedError
        if ((Test-Path -LiteralPath $invalidOutputPath) -or (Test-Path -LiteralPath "$invalidOutputPath.audit.json")) {
            throw "Invalid dump count checkpoint left rehearsal artifacts behind: $($invalidDumpCount.Name)"
        }
    }

    $badCheckpointPath = Join-Path $testRoot 'bad-checkpoint.json'
    $badCheckpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
    $badCheckpoint.verification_baseline.definer_count = 1
    $badCheckpoint | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $badCheckpointPath -Encoding UTF8
    $badAutomaticOutput = Join-Path $testRoot 'bad-automatic-sanitized.sql'
    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260802_1' -OutputPath $badAutomaticOutput -UseCheckpointBaseline -BackupManifestPath $badCheckpointPath } 'definer'
    if (Test-Path -LiteralPath $badAutomaticOutput) { throw 'Failed checkpoint baseline mode left sanitized SQL behind.' }

    $lowercaseSourcePath = Join-Path $testRoot 'lowercase-source.sql'
    $lowercaseOutputPath = Join-Path $testRoot 'lowercase-sanitized.sql'
    [IO.File]::WriteAllText($lowercaseSourcePath, (Get-TestDump -DatabaseName 'd365_finance'), (New-Object Text.UTF8Encoding($false)))
    $lowercaseHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $lowercaseSourcePath).Hash.ToLowerInvariant()
    & $scriptPath -BackupPath $lowercaseSourcePath -ExpectedSourceSha256 $lowercaseHash `
        -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' `
        -OutputPath $lowercaseOutputPath -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 | Out-Null
    $lowercaseSanitized = [IO.File]::ReadAllText($lowercaseOutputPath)
    if (([regex]::Matches($lowercaseSanitized, '`D365_finance_rehearsal_20260731_2130`\.')).Count -ne 22) { throw 'Lowercase source qualifiers did not receive the exact rehearsal spelling.' }
    if ($lowercaseSanitized -match '`d365_finance`\.') { throw 'Lowercase source qualifiers remained after sanitization.' }

    $mixedOutsidePath = Join-Path $testRoot 'mixed-outside.sql'
    [IO.File]::WriteAllText($mixedOutsidePath, ((Get-TestDump -DatabaseName 'd365_finance') + "`nSELECT * FROM ``D365_Finance``.``outside_source``;`n"), (New-Object Text.UTF8Encoding($false)))
    $mixedOutsideHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $mixedOutsidePath).Hash.ToLowerInvariant()
    Assert-Throws { & $scriptPath -BackupPath $mixedOutsidePath -ExpectedSourceSha256 $mixedOutsideHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath "$mixedOutsidePath.out" -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'outside a recognized VIEW'

    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 ('0' * 64) -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath (Join-Path $testRoot 'bad-hash.sql') -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'hash'
    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath (Join-Path $testRoot 'bad-count.sql') -ExpectedDefinerCount 1 -ExpectedQualifiedReferenceCount 22 } 'definer'
    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'bad-name' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath (Join-Path $testRoot 'bad-name.sql') -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'database'
    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance' -OutputPath (Join-Path $testRoot 'alias.sql') -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'different'
    Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath $sourcePath -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'different'

    $dataSourcePath = Join-Path $testRoot 'data-source.sql'
    $dataOutputPath = Join-Path $testRoot 'data-sanitized.sql'
    $dataLiteral = "INSERT INTO ``audit_log`` VALUES ('literal ``D365_finance``.``do_not_rewrite``');"
    [IO.File]::WriteAllText($dataSourcePath, ((Get-TestDump -DatabaseName 'D365_finance') + "`n$dataLiteral`n"), (New-Object Text.UTF8Encoding($false)))
    $dataHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dataSourcePath).Hash.ToLowerInvariant()
    & $scriptPath -BackupPath $dataSourcePath -ExpectedSourceSha256 $dataHash `
        -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' `
        -OutputPath $dataOutputPath -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 | Out-Null
    if (([IO.File]::ReadAllText($dataOutputPath)) -notmatch [regex]::Escape($dataLiteral)) {
        throw 'Sanitizer changed table data outside a view DDL block.'
    }

    $viewLiteralSourcePath = Join-Path $testRoot 'view-literal-source.sql'
    $viewLiteralOutputPath = Join-Path $testRoot 'view-literal-sanitized.sql'
    $viewLiteral = "'``D365_finance``.``do_not_rewrite``'"
    $viewLiteralDump = (Get-TestDump -DatabaseName 'D365_finance').Replace(
        'SELECT 1 AS n FROM `D365_finance`.`table1`',
        "SELECT $viewLiteral AS literal_value FROM ``D365_finance``.``table1``"
    )
    [IO.File]::WriteAllText($viewLiteralSourcePath, $viewLiteralDump, (New-Object Text.UTF8Encoding($false)))
    $viewLiteralHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $viewLiteralSourcePath).Hash.ToLowerInvariant()
    & $scriptPath -BackupPath $viewLiteralSourcePath -ExpectedSourceSha256 $viewLiteralHash `
        -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' `
        -OutputPath $viewLiteralOutputPath -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 | Out-Null
    $viewLiteralSanitized = [IO.File]::ReadAllText($viewLiteralOutputPath)
    if ($viewLiteralSanitized -notmatch [regex]::Escape($viewLiteral)) { throw 'Sanitizer changed a quoted VIEW string literal.' }
    if ($viewLiteralSanitized -notmatch 'FROM `D365_finance_rehearsal_20260731_2130`\.`table1`') { throw 'Sanitizer did not transform the real VIEW reference.' }

    $commentTrapPath = Join-Path $testRoot 'comment-trap.sql'
    $commentTrapDump = (Get-TestDump -DatabaseName 'D365_finance') + "`n/* ' */ INSERT INTO target SELECT * FROM ``D365_finance``.``outside_source``; /* ' */`n"
    [IO.File]::WriteAllText($commentTrapPath, $commentTrapDump, (New-Object Text.UTF8Encoding($false)))
    $commentTrapHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $commentTrapPath).Hash.ToLowerInvariant()
    Assert-Throws { & $scriptPath -BackupPath $commentTrapPath -ExpectedSourceSha256 $commentTrapHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath "$commentTrapPath.out" -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'outside a recognized VIEW'

    foreach ($outsideSql in @(
        "CREATE TABLE ``a'foo`` AS SELECT * FROM ``D365_finance``.``outside_source`` AS ``b'bar``;",
        'CREATE TABLE `a"foo``bar` AS SELECT * FROM `D365_finance`.`outside_source`;'
    )) {
        $backtickPath = Join-Path $testRoot ('backtick-{0}.sql' -f [guid]::NewGuid())
        [IO.File]::WriteAllText($backtickPath, ((Get-TestDump -DatabaseName 'D365_finance') + "`n$outsideSql`n"), (New-Object Text.UTF8Encoding($false)))
        $backtickHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $backtickPath).Hash.ToLowerInvariant()
        Assert-Throws { & $scriptPath -BackupPath $backtickPath -ExpectedSourceSha256 $backtickHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath "$backtickPath.out" -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'outside a recognized VIEW'
    }

    foreach ($unterminatedSuffix in @('/* missing end', "'missing end")) {
        $unterminatedPath = Join-Path $testRoot ('unterminated-{0}.sql' -f [guid]::NewGuid())
        [IO.File]::WriteAllText($unterminatedPath, ((Get-TestDump -DatabaseName 'D365_finance') + "`n$unterminatedSuffix"), (New-Object Text.UTF8Encoding($false)))
        $unterminatedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $unterminatedPath).Hash.ToLowerInvariant()
        Assert-Throws { & $scriptPath -BackupPath $unterminatedPath -ExpectedSourceSha256 $unterminatedHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath "$unterminatedPath.out" -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'unterminated'
    }
    $unterminatedBacktickPath = Join-Path $testRoot 'unterminated-backtick.sql'
    [IO.File]::WriteAllText($unterminatedBacktickPath, ((Get-TestDump -DatabaseName 'D365_finance') + "`nSELECT * FROM ``unterminated"), (New-Object Text.UTF8Encoding($false)))
    $unterminatedBacktickHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $unterminatedBacktickPath).Hash.ToLowerInvariant()
    Assert-Throws { & $scriptPath -BackupPath $unterminatedBacktickPath -ExpectedSourceSha256 $unterminatedBacktickHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath "$unterminatedBacktickPath.out" -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'unterminated backtick'

    foreach ($objectSql in @(
        'CREATE TRIGGER `t` BEFORE INSERT ON `x` FOR EACH ROW SET @x = 1;',
        '/*!50003 CREATE*/ /*!50020 PROCEDURE `p`() SELECT 1 */;',
        'CREATE FUNCTION `f`() RETURNS INT RETURN 1;',
        'CREATE OR REPLACE PROCEDURE `p`() SELECT 1;',
        'CREATE/**/OR/**/REPLACE/**/FUNCTION `f`() RETURNS INT RETURN 1;',
        '/*!50106 CREATE*/ /*!50117 EVENT `e` ON SCHEDULE EVERY 1 DAY DO SELECT 1 */;',
        '/*!50003 DROP*/ /*!50032 TRIGGER `t` */;',
        'ALTER PROCEDURE `p` COMMENT ''unsafe'';',
        '/*!50106 ALTER*/ /*!50117 EVENT `e` ON SCHEDULE EVERY 1 DAY */;'
    )) {
        $objectSourcePath = Join-Path $testRoot ('object-{0}.sql' -f [guid]::NewGuid())
        [IO.File]::WriteAllText($objectSourcePath, ((Get-TestDump -DatabaseName 'D365_finance') + "`n$objectSql`n"), (New-Object Text.UTF8Encoding($false)))
        $objectHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $objectSourcePath).Hash.ToLowerInvariant()
        Assert-Throws { & $scriptPath -BackupPath $objectSourcePath -ExpectedSourceSha256 $objectHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath "$objectSourcePath.out" -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'executable'
    }

    # Break caught: comments/quotes split dangerous database-selection/DDL tokens and bypass regex guards.
    foreach ($dangerousSql in @(
        'USE/**/`D365_finance`;',
        'USE /* separator */ "D365_finance";',
        'DROP/**/DATABASE/**/`D365_finance`;',
        'CREATE/* separator */SCHEMA `D365_finance_shadow`;',
        'ALTER/**/DATABASE `D365_finance` CHARACTER SET utf8mb4;',
        '/*!50003 DROP*/ /**/ /*!50003 DATABASE*/ `D365_finance`;'
    )) {
        $dangerousPath = Join-Path $testRoot ('dangerous-{0}.sql' -f [guid]::NewGuid())
        [IO.File]::WriteAllText($dangerousPath, ((Get-TestDump -DatabaseName 'D365_finance') + "`n$dangerousSql`n"), (New-Object Text.UTF8Encoding($false)))
        $dangerousHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dangerousPath).Hash.ToLowerInvariant()
        Assert-Throws { & $scriptPath -BackupPath $dangerousPath -ExpectedSourceSha256 $dangerousHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath "$dangerousPath.out" -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'dangerous database|CREATE DATABASE or USE'
    }

    $junctionPath = Join-Path $testRoot 'junction-output'
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionPath -Target $testRoot | Out-Null
        $junctionCreated = $true
    } catch {
        Write-Host 'Junction creation unavailable; path-component detection is covered by implementation.'
    }
    if ($junctionCreated) {
        Assert-Throws { & $scriptPath -BackupPath $sourcePath -ExpectedSourceSha256 $sourceHash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath (Join-Path $junctionPath 'new-output.sql') -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'reparse'
    }

    $invalidUtf8Path = Join-Path $testRoot 'invalid-utf8.sql'
    $invalidBytes = [IO.File]::ReadAllBytes($sourcePath) + [byte[]](0xFF)
    [IO.File]::WriteAllBytes($invalidUtf8Path, $invalidBytes)
    $invalidUtf8Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $invalidUtf8Path).Hash.ToLowerInvariant()
    Assert-Throws { & $scriptPath -BackupPath $invalidUtf8Path -ExpectedSourceSha256 $invalidUtf8Hash -SourceDatabase 'D365_finance' -RehearsalDatabase 'D365_finance_rehearsal_20260731_2130' -OutputPath "$invalidUtf8Path.out" -ExpectedDefinerCount 2 -ExpectedQualifiedReferenceCount 22 } 'UTF-8'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'Restore rehearsal sanitizer checks passed.'
