$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\manual_restore_migration_adapter.ps1')

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action; throw 'Expected failure.' } catch {
        if ($_.Exception.Message -eq 'Expected failure.' -or $_.Exception.Message -notmatch $Pattern) { throw }
    }
}
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$script:fakeScheduledTasks = @()
$script:scheduledTaskOperations = [Collections.Generic.List[string]]::new()

function Get-ScheduledTask {
    [CmdletBinding()]
    param([string] $TaskName)

    if ($PSBoundParameters.ContainsKey('TaskName')) {
        return @($script:fakeScheduledTasks | Where-Object { $_.TaskName -like $TaskName })
    }
    return @($script:fakeScheduledTasks)
}

function Stop-ScheduledTask {
    [CmdletBinding(DefaultParameterSetName = 'Name')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Input')][object] $InputObject,
        [Parameter(Mandatory = $true, ParameterSetName = 'Name')][string] $TaskName
    )

    $task = if ($PSCmdlet.ParameterSetName -ceq 'Input') { $InputObject } else { @($script:fakeScheduledTasks | Where-Object { $_.TaskName -like $TaskName })[0] }
    $script:scheduledTaskOperations.Add("$($PSCmdlet.ParameterSetName):Stop:$($task.TaskName)")
    $task.State = 'Ready'
}

function Disable-ScheduledTask {
    [CmdletBinding(DefaultParameterSetName = 'Name')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Input')][object] $InputObject,
        [Parameter(Mandatory = $true, ParameterSetName = 'Name')][string] $TaskName
    )

    $task = if ($PSCmdlet.ParameterSetName -ceq 'Input') { $InputObject } else { @($script:fakeScheduledTasks | Where-Object { $_.TaskName -like $TaskName })[0] }
    $script:scheduledTaskOperations.Add("$($PSCmdlet.ParameterSetName):Disable:$($task.TaskName)")
    $task.State = 'Disabled'
    return $task
}

function Enable-ScheduledTask {
    [CmdletBinding(DefaultParameterSetName = 'Name')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Input')][object] $InputObject,
        [Parameter(Mandatory = $true, ParameterSetName = 'Name')][string] $TaskName
    )

    $task = if ($PSCmdlet.ParameterSetName -ceq 'Input') { $InputObject } else { @($script:fakeScheduledTasks | Where-Object { $_.TaskName -like $TaskName })[0] }
    $script:scheduledTaskOperations.Add("$($PSCmdlet.ParameterSetName):Enable:$($task.TaskName)")
    $task.State = 'Ready'
    return $task
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('manual-migration-adapter-{0}' -f [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $backupSql = Join-Path $root 'D365_finance_prod_r1.sql'
    [IO.File]::WriteAllText($backupSql, 'CREATE TABLE `fixture` (`id` int);', (New-Object Text.UTF8Encoding($false)))
    $backupHash = (Get-FileHash -LiteralPath $backupSql -Algorithm SHA256).Hash.ToLowerInvariant()
    $checkpointPath = "$backupSql.json"
    [ordered]@{
        database='D365_finance_prod';release_id='r1';backup_file=$backupSql;sha256=$backupHash
        verification_baseline=[ordered]@{definer_count=0;qualified_reference_count=0}
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $checkpointPath -Encoding UTF8
    $prepared = Start-D365ManualRestoreWizard -ReleaseId 'r1' -BackupManifestPath $checkpointPath
    Assert-True ($prepared.RehearsalDatabase -ceq 'D365_finance_prod_rehearsal_r1') 'Automatic rehearsal database name is wrong.'
    Assert-True (Test-Path -LiteralPath $prepared.SanitizedPath -PathType Leaf) 'Automatic sanitized SQL was not created.'
    Assert-True (Test-Path -LiteralPath $prepared.SanitizerAuditPath -PathType Leaf) 'Automatic sanitizer audit was not created.'

    $php = Join-Path $root 'php.exe'
    Set-Content -LiteralPath $php 'fixture'
    $projects = [ordered]@{}
    foreach ($project in @('D365_Sharedpoint_csv_import','D365_file_csv_import','finance_report')) {
        $source = Join-Path $root $project
        New-Item -ItemType Directory -Path $source | Out-Null
        $projects[$project] = [pscustomobject]@{SourceRoot=$source}
    }
    $manifest = [pscustomobject]@{release_id='r1';migrations=[pscustomobject]@{
        D365_Sharedpoint_csv_import=@('006.sql');D365_file_csv_import=@();finance_report=@()
    }}
    $waitEvents = [Collections.Generic.List[string]]::new()
    $wait = { param([string]$Database,[string]$Path) $waitEvents.Add("$Database|$Path") }.GetNewClosure()
    $adapter = New-D365ManualRestoreMigrationAdapter -Manifest $manifest -SourceProjects $projects `
        -ProductionRoot (Join-Path $root 'prod') -BackupRoot (Join-Path $root 'backup') `
        -PhpPath $php -AppliedBy 'tester' -WaitForManualRestore $wait
    if ($adapter -isnot [scriptblock]) { throw 'Manual restore adapter was not created.' }
    $context = @{RehearsalDatabase='D365_finance_prod_rehearsal_r1';SanitizedPath=(Join-Path $root 'sanitized.sql')}
    $instructions = & $adapter 'show-manual-restore-instructions' $context
    $userKeys = @($instructions.PSObject.Properties.Name | Where-Object { $_ -cne 'Success' })
    Assert-True ($userKeys.Count -eq 2 -and $userKeys -contains 'RehearsalDatabase' -and $userKeys -contains 'SanitizedPath') `
        'Manual restore instructions exposed internal artifacts.'
    & $adapter 'wait-for-manual-restore' $context | Out-Null
    Assert-True ($waitEvents.Count -eq 1) 'Manual restore wait callback was not invoked.'

    $literalTaskName = 'D365 SharePoint CSV Import [PROD]'
    $decoyTaskName = 'D365 SharePoint CSV Import P'
    $previouslyDisabledTaskName = 'D365 CSV Cleanup [PROD]'
    $previouslyDisabledDecoyTaskName = 'D365 CSV Cleanup P'
    $script:fakeScheduledTasks = @(
        [pscustomobject]@{TaskName=$literalTaskName;TaskPath='\';State='Running'},
        [pscustomobject]@{TaskName=$decoyTaskName;TaskPath='\';State='Ready'},
        [pscustomobject]@{TaskName=$previouslyDisabledTaskName;TaskPath='\';State='Disabled'},
        [pscustomobject]@{TaskName=$previouslyDisabledDecoyTaskName;TaskPath='\';State='Ready'}
    )
    $script:scheduledTaskOperations.Clear()
    $disabled = & $adapter 'disable-production-tasks' @{TaskNames=@($literalTaskName, $previouslyDisabledTaskName)}
    Assert-True (@($disabled.PreviouslyEnabledTasks).Count -eq 1 -and $disabled.PreviouslyEnabledTasks[0] -ceq $literalTaskName) `
        'Literal [PROD] task was not resolved before the wildcard decoy.'
    Assert-True ($script:fakeScheduledTasks[0].State -ceq 'Disabled' -and $script:fakeScheduledTasks[1].State -ceq 'Ready') `
        'Literal task was not stopped and disabled without changing its decoy.'
    Assert-True ($script:fakeScheduledTasks[2].State -ceq 'Disabled' -and $script:fakeScheduledTasks[3].State -ceq 'Ready') `
        'Previously disabled literal task or its decoy changed state.'
    Assert-True (@($script:scheduledTaskOperations | Where-Object { $_ -notmatch '^Input:' }).Count -eq 0) `
        'Scheduled Task control did not use resolved task objects.'
    $restored = & $adapter 'restore-production-task-states' @{}
    Assert-True (@($restored.RestoredTasks).Count -eq 1 -and $restored.RestoredTasks[0] -ceq $literalTaskName) `
        'Restore result did not preserve the previously enabled literal task.'
    Assert-True ($script:fakeScheduledTasks[0].State -ceq 'Ready' -and $script:fakeScheduledTasks[2].State -ceq 'Disabled') `
        'Restore did not re-enable only the task enabled before cutover.'
    Assert-True (@($script:scheduledTaskOperations | Where-Object { $_ -notmatch '^Input:' }).Count -eq 0) `
        'Scheduled Task restore did not use resolved task objects.'

    $script:fakeScheduledTasks = @()
    $script:scheduledTaskOperations.Clear()
    Assert-Throws { & $adapter 'disable-production-tasks' @{TaskNames=@($literalTaskName)} | Out-Null } 'exactly one'
    Assert-True ($script:scheduledTaskOperations.Count -eq 0) 'Task controls ran when a requested task had no exact match.'

    $script:fakeScheduledTasks = @(
        [pscustomobject]@{TaskName=$literalTaskName;TaskPath='\One\';State='Ready'},
        [pscustomobject]@{TaskName=$literalTaskName;TaskPath='\Two\';State='Ready'}
    )
    $script:scheduledTaskOperations.Clear()
    Assert-Throws { & $adapter 'disable-production-tasks' @{TaskNames=@($literalTaskName)} | Out-Null } 'exactly one'
    Assert-True ($script:scheduledTaskOperations.Count -eq 0) 'Task controls ran when a requested task had duplicate exact matches.'
    Assert-Throws {
        New-D365ManualRestoreMigrationAdapter -Manifest $manifest -SourceProjects $projects `
            -ProductionRoot (Join-Path $root 'prod') -BackupRoot (Join-Path $root 'backup') `
            -PhpPath (Join-Path $root 'missing-php.exe') -AppliedBy 'tester' -WaitForManualRestore $wait | Out-Null
    } 'not found'
    Assert-Throws {
        New-D365ManualRestoreMigrationAdapter -Manifest $manifest -SourceProjects $projects `
            -ProductionRoot (Join-Path $root 'prod') -BackupRoot (Join-Path $root 'backup') `
            -PhpPath $php -AppliedBy 'bad user;argument' -WaitForManualRestore $wait | Out-Null
    } 'unsafe'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

Write-Host 'Manual restore migration adapter checks passed.'
