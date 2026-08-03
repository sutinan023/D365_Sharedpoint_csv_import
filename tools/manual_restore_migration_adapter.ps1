$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_security.ps1')

function Start-D365ManualRestoreWizard {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $ReleaseId,
        [Parameter(Mandatory = $true)][string] $BackupManifestPath
    )

    $checkpoint = Read-D365StrictJsonSnapshot -Path $BackupManifestPath -Label 'Checkpoint manifest'
    if ([string] $checkpoint.Value.release_id -cne $ReleaseId -or
        [string] $checkpoint.Value.database -cne 'D365_finance_prod') {
        throw 'Checkpoint manifest does not match this Production release.'
    }
    $backupPath = [IO.Path]::GetFullPath([string] $checkpoint.Value.backup_file)
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        throw "Checkpoint SQL not found: $backupPath"
    }
    $safeRelease = $ReleaseId.Replace('-', '_').Replace('.', '_')
    $rehearsalDatabase = "D365_finance_prod_rehearsal_$safeRelease"
    $sanitizedPath = if ($backupPath.EndsWith('.sql', [StringComparison]::OrdinalIgnoreCase)) {
        $backupPath.Substring(0, $backupPath.Length - 4) + '.sanitized.sql'
    } else {
        "$backupPath.sanitized.sql"
    }
    & (Join-Path $PSScriptRoot 'prepare_restore_rehearsal.ps1') -BackupPath $backupPath `
        -ExpectedSourceSha256 ([string] $checkpoint.Value.sha256) -SourceDatabase 'D365_finance_prod' `
        -RehearsalDatabase $rehearsalDatabase -OutputPath $sanitizedPath `
        -UseCheckpointBaseline -BackupManifestPath $checkpoint.Path | Out-Null

    [pscustomobject]@{
        BackupManifestPath = $checkpoint.Path
        RehearsalDatabase = $rehearsalDatabase
        SanitizedPath = $sanitizedPath
        SanitizerAuditPath = "$sanitizedPath.audit.json"
    }
}

function Complete-D365ManualRestoreWizard {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $ReleaseId,
        [Parameter(Mandatory = $true)][string] $ProductionProjectRoot,
        [Parameter(Mandatory = $true)][string] $PhpPath,
        [Parameter(Mandatory = $true)][string] $BackupManifestPath,
        [Parameter(Mandatory = $true)][string] $RehearsalDatabase,
        [Parameter(Mandatory = $true)][string] $SanitizedPath,
        [Parameter(Mandatory = $true)][string] $SanitizerAuditPath
    )

    $verifyScript = Join-Path $ProductionProjectRoot 'tools\verify_restore_rehearsal.php'
    foreach ($path in @($PhpPath, $verifyScript, $BackupManifestPath, $SanitizedPath, $SanitizerAuditPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required rehearsal artifact not found: $path" }
    }
    $raw = (& $PhpPath $verifyScript "--database=$RehearsalDatabase" "--checkpoint=$BackupManifestPath" `
        "--sanitizer-audit=$SanitizerAuditPath" | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw 'Read-only rehearsal verification failed.'
    }
    try { $evidence = $raw | ConvertFrom-Json } catch { throw 'Rehearsal verifier returned invalid JSON.' }
    if ([string] $evidence.status -cne 'VERIFIED' -or [string] $evidence.release_id -cne $ReleaseId -or
        [string] $evidence.rehearsal_database -cne $RehearsalDatabase) {
        throw 'Rehearsal verifier result does not match this release.'
    }

    $evidencePath = "$SanitizedPath.restore-evidence.json"
    $utf8 = New-Object Text.UTF8Encoding($false)
    $bytes = $utf8.GetBytes($raw)
    try {
        $stream = New-Object IO.FileStream($evidencePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    } catch [IO.IOException] {
        throw 'Restore evidence already exists or could not be created atomically.'
    }

    $checkpoint = Read-D365StrictJsonSnapshot -Path $BackupManifestPath -Label 'Checkpoint manifest'
    $receiptPath = [string] $checkpoint.Value.restore_receipt_file
    if ([string]::IsNullOrWhiteSpace($receiptPath)) { throw 'Checkpoint manifest is missing restore_receipt_file.' }
    $approvedPath = (& (Join-Path $PSScriptRoot 'approve_restore_rehearsal.ps1') `
        -BackupManifestPath $BackupManifestPath -SanitizerAuditPath $SanitizerAuditPath `
        -RestoreEvidencePath $evidencePath -OutputPath $receiptPath `
        -ApprovalToken "RESTORE TEST PASSED $ReleaseId" | Out-String).Trim()
    if ([IO.Path]::GetFullPath($approvedPath) -ine [IO.Path]::GetFullPath($receiptPath)) {
        throw 'Restore approval returned an unexpected receipt path.'
    }
    [pscustomobject]@{ RestoreEvidencePath=$evidencePath; RestoreReceiptPath=$receiptPath }
}

function Get-D365TaskSchedulerComputerName([string] $ProductionRoot) {
    if ($ProductionRoot -match '^\\\\[?.]\\') { throw 'ProductionRoot must be an absolute local path or UNC path.' }
    if ($ProductionRoot -match '^\\\\(?<computer>[^\\/:*?"<>|]+)\\(?<share>[^\\/:*?"<>|]+)(?:\\|$)') {
        return [string] $Matches['computer']
    }
    if ($ProductionRoot.StartsWith('\\')) { throw 'ProductionRoot must be an absolute local path or UNC path.' }
    if ([IO.Path]::IsPathRooted($ProductionRoot)) { return [string] $env:COMPUTERNAME }
    throw 'ProductionRoot must be an absolute local path or UNC path.'
}

function New-D365ManualRestoreMigrationAdapter {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $SourceProjects,
        [Parameter(Mandatory = $true)][string] $ProductionRoot,
        [Parameter(Mandatory = $true)][string] $BackupRoot,
        [Parameter(Mandatory = $true)][string] $PhpPath,
        [Parameter(Mandatory = $true)][string] $AppliedBy,
        [Parameter(Mandatory = $true)][scriptblock] $WaitForManualRestore,
        [string] $TaskSchedulerComputerName,
        [scriptblock] $ScheduledTaskCommandAdapter = $null
    )

    if (-not (Test-Path -LiteralPath $PhpPath -PathType Leaf)) { throw "PHP executable not found: $PhpPath" }
    if ($AppliedBy -notmatch '^[A-Za-z0-9_.@-]+$') { throw 'Migration applied-by value contains unsafe characters.' }
    if (-not $PSBoundParameters.ContainsKey('TaskSchedulerComputerName')) {
        $TaskSchedulerComputerName = Get-D365TaskSchedulerComputerName $ProductionRoot
    }
    if ([string]::IsNullOrWhiteSpace($TaskSchedulerComputerName)) { throw 'Task Scheduler computer name is required.' }
    if ($null -eq $ScheduledTaskCommandAdapter) {
        $ScheduledTaskCommandAdapter = {
            param([string[]] $Arguments)
            $lines = @(& schtasks.exe @Arguments 2>&1)
            [pscustomobject]@{ ExitCode=[int] $LASTEXITCODE; Output=($lines -join [Environment]::NewLine) }
        }
    }

    $invokeCheckedSchtasks = {
        param([string[]] $Arguments, [string] $Operation, [string] $TaskName)

        $result = & $ScheduledTaskCommandAdapter -Arguments $Arguments
        if ($null -eq $result -or $null -eq $result.PSObject.Properties['ExitCode'] -or
            $result.ExitCode -isnot [int] -or $null -eq $result.PSObject.Properties['Output'] -or
            $result.Output -isnot [string]) {
            throw "Task Scheduler command returned an invalid result for ${Operation}: $TaskName"
        }
        if ($result.ExitCode -ne 0) { throw "Task Scheduler command failed for ${Operation}: $TaskName" }
        return $result.Output
    }.GetNewClosure()

    $getTaskSnapshot = {
        param([string] $TaskName)

        $fullTaskName = '\' + $TaskName.TrimStart([char[]]@([char]'\'))
        $xmlOutput = & $invokeCheckedSchtasks -Arguments @('/Query','/S',$TaskSchedulerComputerName,'/TN',$fullTaskName,'/XML') -Operation 'query XML' -TaskName $fullTaskName
        try { [xml] $xml = $xmlOutput } catch { throw "Task Scheduler returned invalid XML for task: $fullTaskName" }
        $uri = [string] $xml.Task.RegistrationInfo.URI
        if (-not [string]::Equals($uri, $fullTaskName, [StringComparison]::Ordinal)) {
            throw "Task Scheduler XML URI does not match requested task: $fullTaskName"
        }
        $enabledValue = [string] $xml.Task.Settings.Enabled
        if ($enabledValue -cne 'true' -and $enabledValue -cne 'false') {
            throw "Task Scheduler XML has an invalid Enabled value for task: $fullTaskName"
        }

        $csvOutput = & $invokeCheckedSchtasks -Arguments @('/Query','/S',$TaskSchedulerComputerName,'/TN',$fullTaskName,'/FO','CSV','/NH') -Operation 'query CSV' -TaskName $fullTaskName
        $csvMatch = [regex]::Match(
            $csvOutput,
            '^\s*"(?<name>(?:[^"]|"")*)"\s*,\s*"(?:[^"]|"")*"\s*,\s*"(?<state>(?:[^"]|"")*)"\s*(?:\r?\n)?$'
        )
        if (-not $csvMatch.Success) { throw "Task Scheduler returned invalid CSV for task: $fullTaskName" }
        $returnedName = $csvMatch.Groups['name'].Value.Replace('""', '"')
        $stateName = $csvMatch.Groups['state'].Value.Replace('""', '"')
        if (-not [string]::Equals($returnedName, $fullTaskName, [StringComparison]::Ordinal)) {
            throw "Task Scheduler CSV task name does not match requested task: $fullTaskName"
        }
        if ($stateName -cnotin @('Running','Ready','Disabled')) {
            throw "Task Scheduler returned an invalid state for task: $fullTaskName"
        }
        [pscustomobject]@{ FullName=$fullTaskName; Enabled=($enabledValue -ceq 'true'); State=$stateName }
    }.GetNewClosure()

    $productionProjectRoot = Join-Path $ProductionRoot 'D365_Sharedpoint_csv_import'
    $state = @{ PreviouslyEnabledTasks=@(); ApplyResults=@() }
    return {
        param([string] $Stage, [hashtable] $Context)
        switch ($Stage) {
            'disable-production-tasks' {
                $snapshots = @($Context.TaskNames | ForEach-Object { & $getTaskSnapshot ([string] $_) })
                $enabled = @($snapshots | Where-Object Enabled | ForEach-Object FullName)
                foreach ($snapshot in $snapshots) {
                    if ($snapshot.State -ceq 'Running') {
                        & $invokeCheckedSchtasks -Arguments @('/End','/S',$TaskSchedulerComputerName,'/TN',$snapshot.FullName) -Operation 'end task' -TaskName $snapshot.FullName | Out-Null
                    }
                    if ($snapshot.Enabled) {
                        & $invokeCheckedSchtasks -Arguments @('/Change','/S',$TaskSchedulerComputerName,'/TN',$snapshot.FullName,'/Disable') -Operation 'disable task' -TaskName $snapshot.FullName | Out-Null
                    }
                }
                $state.PreviouslyEnabledTasks = $enabled
                return [pscustomobject]@{Success=$true;PreviouslyEnabledTasks=$enabled}
            }
            'checkpoint-production' {
                $raw = (& (Join-Path $PSScriptRoot 'database_checkpoint.ps1') -Environment Production `
                    -ReleaseId $Context.ReleaseId -ProjectRoot $productionProjectRoot -BackupRoot $BackupRoot `
                    -ApprovalToken "CHECKPOINT PRODUCTION $($Context.ReleaseId)" | Out-String).Trim()
                try { $checkpointPlan = $raw | ConvertFrom-Json } catch { throw 'Database checkpoint returned invalid JSON.' }
                $manifestPath = "$($checkpointPlan.backup_file).json"
                if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Database checkpoint manifest was not created.' }
                return [pscustomobject]@{Success=$true;BackupManifestPath=(Resolve-Path -LiteralPath $manifestPath).ProviderPath}
            }
            'prepare-rehearsal' {
                $prepared = Start-D365ManualRestoreWizard -ReleaseId $Context.ReleaseId -BackupManifestPath $Context.BackupManifestPath
                return [pscustomobject]@{Success=$true;RehearsalDatabase=$prepared.RehearsalDatabase;SanitizedPath=$prepared.SanitizedPath;SanitizerAuditPath=$prepared.SanitizerAuditPath}
            }
            'show-manual-restore-instructions' {
                Write-Host ''
                Write-Host 'สิ่งที่คุณต้องทำ'
                Write-Host "1. เปิด phpMyAdmin และสร้างฐาน: $($Context.RehearsalDatabase)"
                Write-Host "2. เลือกฐานนี้และ Import ไฟล์: $($Context.SanitizedPath)"
                Write-Host '3. เมื่อ Import สำเร็จ กลับมาหน้านี้แล้วกด Enter'
                return [pscustomobject]@{Success=$true;RehearsalDatabase=$Context.RehearsalDatabase;SanitizedPath=$Context.SanitizedPath}
            }
            'wait-for-manual-restore' {
                & $WaitForManualRestore $Context.RehearsalDatabase $Context.SanitizedPath
                return [pscustomobject]@{Success=$true}
            }
            'verify-rehearsal-read-only' {
                $completed = Complete-D365ManualRestoreWizard -ReleaseId $Context.ReleaseId `
                    -ProductionProjectRoot $productionProjectRoot -PhpPath $PhpPath `
                    -BackupManifestPath $Context.BackupManifestPath -RehearsalDatabase $Context.RehearsalDatabase `
                    -SanitizedPath $Context.SanitizedPath -SanitizerAuditPath $Context.SanitizerAuditPath
                $state.RestoreReceiptPath = $completed.RestoreReceiptPath
                return [pscustomobject]@{Success=$true;RestoreEvidencePath=$completed.RestoreEvidencePath;RestoreReceiptPath=$completed.RestoreReceiptPath}
            }
            'approve-rehearsal-automatically' {
                if ([string]::IsNullOrWhiteSpace([string] $state.RestoreReceiptPath)) { throw 'Restore receipt was not created.' }
                return [pscustomobject]@{Success=$true;RestoreReceiptPath=$state.RestoreReceiptPath}
            }
            'approve-production-migration' { return [pscustomobject]@{Success=$true} }
            { $_ -in @('apply-production','apply-production-idempotence-check') } {
                $allApplied = [Collections.Generic.List[string]]::new()
                foreach ($project in @('D365_Sharedpoint_csv_import','D365_file_csv_import','finance_report')) {
                    if (@($Manifest.migrations.$project).Count -eq 0) { continue }
                    $runner = Join-Path $ProductionRoot "$project\tools\apply_migrations.php"
                    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Migration runner not found in Production: $project" }
                    $directory = Join-Path $SourceProjects[$project].SourceRoot 'database\migrations'
                    $arguments = @('--apply', "--project=$project", "--directory=$directory", "--release=$($Manifest.release_id)",
                        "--applied-by=$AppliedBy", "--backup-manifest=$($Context.BackupManifestPath)", "--restore-receipt=$($Context.RestoreReceiptPath)")
                    $raw = (& $PhpPath $runner @arguments | Out-String).Trim()
                    if ($LASTEXITCODE -ne 0) { throw "Migration runner failed: $project" }
                    try { $value = $raw | ConvertFrom-Json } catch { throw "Migration runner returned invalid JSON: $project" }
                    if ([string] $value.environment -cne 'PRODUCTION' -or [string] $value.database -cne 'D365_finance_prod' -or
                        [string] $value.release -cne [string] $Manifest.release_id) { throw "Migration runner environment result is invalid: $project" }
                    foreach ($version in @($value.applied)) { $allApplied.Add("$project/$version") }
                }
                return [pscustomobject]@{Success=$true;Applied=@($allApplied)}
            }
            'verify-production' { return [pscustomobject]@{Success=$true} }
            'restore-production-task-states' {
                foreach ($fullTaskName in $state.PreviouslyEnabledTasks) {
                    & $getTaskSnapshot $fullTaskName | Out-Null
                    & $invokeCheckedSchtasks -Arguments @('/Change','/S',$TaskSchedulerComputerName,'/TN',$fullTaskName,'/Enable') -Operation 'enable task' -TaskName $fullTaskName | Out-Null
                }
                return [pscustomobject]@{Success=$true;RestoredTasks=@($state.PreviouslyEnabledTasks)}
            }
            default { throw "Unsupported migration stage: $Stage" }
        }
    }.GetNewClosure()
}
