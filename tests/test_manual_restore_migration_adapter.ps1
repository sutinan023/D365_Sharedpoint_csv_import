$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\manual_restore_migration_adapter.ps1')

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action; throw 'Expected failure.' } catch {
        if ($_.Exception.Message -eq 'Expected failure.' -or $_.Exception.Message -notmatch $Pattern) { throw }
    }
}
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$schedulerState = [pscustomobject]@{
    Commands = [Collections.Generic.List[object]]::new()
    TaskDefinitions = @{}
    XmlOverride = $null
    CsvStateOverride = $null
    FailStateChange = $false
}
$script:schedulerCommands = $schedulerState.Commands

function Reset-FakeSchtasks {
    $schedulerState.Commands.Clear()
    $schedulerState.TaskDefinitions = @{
        '\D365 SharePoint CSV Import [PROD]' = @{ Enabled=$false; State='Disabled' }
        '\D365 File CSV Import [PROD]' = @{ Enabled=$true; State='Ready' }
        '\D365 SharePoint CSV Download Cleanup [PROD]' = @{ Enabled=$true; State='Running' }
    }
    $schedulerState.XmlOverride = $null
    $schedulerState.CsvStateOverride = $null
    $schedulerState.FailStateChange = $false
}

$fakeSchtasks = {
    param([string[]] $Arguments)

    $schedulerState.Commands.Add(@($Arguments))
    $taskIndex = [Array]::IndexOf($Arguments, '/TN')
    $taskName = if ($taskIndex -ge 0 -and $taskIndex + 1 -lt $Arguments.Count) { $Arguments[$taskIndex + 1] } else { '' }
    if (-not $schedulerState.TaskDefinitions.ContainsKey($taskName)) {
        return [pscustomobject]@{ ExitCode=1; Output='Task was not found.' }
    }
    $task = $schedulerState.TaskDefinitions[$taskName]
    if ($Arguments -contains '/Query' -and $Arguments -contains '/XML') {
        if ($null -ne $schedulerState.XmlOverride) { return [pscustomobject]@{ ExitCode=0; Output=$schedulerState.XmlOverride } }
        $enabled = if ($task.Enabled) { 'true' } else { 'false' }
        $xml = '<Task><RegistrationInfo><URI>{0}</URI></RegistrationInfo><Settings><Enabled>{1}</Enabled></Settings></Task>' -f $taskName, $enabled
        return [pscustomobject]@{ ExitCode=0; Output=$xml }
    }
    if ($Arguments -contains '/Query' -and $Arguments -contains '/FO') {
        $state = if ($null -ne $schedulerState.CsvStateOverride) { $schedulerState.CsvStateOverride } else { $task.State }
        return [pscustomobject]@{ ExitCode=0; Output=('"{0}","N/A","{1}","Interactive/Background"' -f $taskName, $state) }
    }
    if ($Arguments -contains '/End') {
        if ($schedulerState.FailStateChange) { return [pscustomobject]@{ ExitCode=1; Output='State change failed.' } }
        $task.State = 'Ready'
        return [pscustomobject]@{ ExitCode=0; Output='' }
    }
    if ($Arguments -contains '/Change') {
        if ($schedulerState.FailStateChange) { return [pscustomobject]@{ ExitCode=1; Output='State change failed.' } }
        if ($Arguments -contains '/Disable') { $task.Enabled = $false; $task.State = 'Disabled' }
        if ($Arguments -contains '/Enable') { $task.Enabled = $true; $task.State = 'Ready' }
        return [pscustomobject]@{ ExitCode=0; Output='' }
    }
    return [pscustomobject]@{ ExitCode=1; Output='Unsupported command.' }
}.GetNewClosure()

function Assert-NoStateChanges([string] $Message) {
    Assert-True (@($schedulerState.Commands | Where-Object { $_ -contains '/End' -or $_ -contains '/Change' }).Count -eq 0) $Message
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
    Assert-True ((Get-D365TaskSchedulerComputerName '\\100.1.1.166\htdocs\prod') -ceq '100.1.1.166') 'UNC scheduler computer derivation is wrong.'
    Assert-True ((Get-D365TaskSchedulerComputerName $root) -ceq [string] $env:COMPUTERNAME) 'Local scheduler computer derivation is wrong.'
    Assert-Throws { Get-D365TaskSchedulerComputerName 'relative\production' | Out-Null } 'absolute local path or UNC'
    Assert-Throws { Get-D365TaskSchedulerComputerName '\\server\' | Out-Null } 'absolute local path or UNC'
    Assert-Throws { Get-D365TaskSchedulerComputerName '\\?\C:\prod' | Out-Null } 'absolute local path or UNC'
    Reset-FakeSchtasks
    $adapter = New-D365ManualRestoreMigrationAdapter -Manifest $manifest -SourceProjects $projects `
        -ProductionRoot '\\100.1.1.166\D365' -BackupRoot (Join-Path $root 'backup') `
        -PhpPath $php -AppliedBy 'tester' -WaitForManualRestore $wait `
        -TaskSchedulerComputerName '100.1.1.166' -ScheduledTaskCommandAdapter $fakeSchtasks
    if ($adapter -isnot [scriptblock]) { throw 'Manual restore adapter was not created.' }
    $context = @{RehearsalDatabase='D365_finance_prod_rehearsal_r1';SanitizedPath=(Join-Path $root 'sanitized.sql')}
    $instructions = & $adapter 'show-manual-restore-instructions' $context
    $userKeys = @($instructions.PSObject.Properties.Name | Where-Object { $_ -cne 'Success' })
    Assert-True ($userKeys.Count -eq 2 -and $userKeys -contains 'RehearsalDatabase' -and $userKeys -contains 'SanitizedPath') `
        'Manual restore instructions exposed internal artifacts.'
    & $adapter 'wait-for-manual-restore' $context | Out-Null
    Assert-True ($waitEvents.Count -eq 1) 'Manual restore wait callback was not invoked.'

    $disabled = & $adapter 'disable-production-tasks' @{TaskNames=@(
        'D365 SharePoint CSV Import [PROD]',
        'D365 File CSV Import [PROD]',
        'D365 SharePoint CSV Download Cleanup [PROD]'
    )}
    Assert-True (@($disabled.PreviouslyEnabledTasks).Count -eq 2 -and
        $disabled.PreviouslyEnabledTasks -ccontains '\D365 File CSV Import [PROD]' -and
        $disabled.PreviouslyEnabledTasks -ccontains '\D365 SharePoint CSV Download Cleanup [PROD]') `
        'Only initially enabled full task names should be saved.'
    $firstMutation = @($schedulerState.Commands | ForEach-Object -Begin { $i = 0 } -Process { $result = [pscustomobject]@{Index=$i; Command=$_}; $i++; $result } | Where-Object { $_.Command -contains '/End' -or $_.Command -contains '/Change' } | Select-Object -First 1).Index
    Assert-True (@($schedulerState.Commands | Select-Object -First $firstMutation | Where-Object { $_ -notcontains '/Query' }).Count -eq 0) `
        'Every task query must finish before the first state-changing command.'
    Assert-True (@($schedulerState.Commands | Where-Object { [Array]::IndexOf($_, '/S') -lt 0 -or $_[[Array]::IndexOf($_, '/S') + 1] -cne '100.1.1.166' }).Count -eq 0) `
        'Every scheduler command must target 100.1.1.166.'
    foreach ($fullTaskName in @(
        '\D365 SharePoint CSV Import [PROD]',
        '\D365 File CSV Import [PROD]',
        '\D365 SharePoint CSV Download Cleanup [PROD]'
    )) {
        Assert-True (@($schedulerState.Commands | Where-Object { $_ -contains '/Query' -and $_ -contains '/XML' -and $_ -contains $fullTaskName }).Count -eq 1) `
            "Task XML query was not recorded exactly once: $fullTaskName"
        Assert-True (@($schedulerState.Commands | Where-Object { $_ -contains '/Query' -and $_ -contains '/FO' -and $_ -contains 'CSV' -and $_ -contains '/NH' -and $_ -contains $fullTaskName }).Count -eq 1) `
            "Task CSV query was not recorded exactly once: $fullTaskName"
    }
    Assert-True (@($schedulerState.Commands | Where-Object { $_ -contains '/End' -and $_ -contains '\D365 SharePoint CSV Download Cleanup [PROD]' }).Count -eq 1) `
        'The running task was not ended.'
    Assert-True (@($schedulerState.Commands | Where-Object { $_ -contains '/Change' -and $_ -contains '/Disable' }).Count -eq 2) `
        'Exactly the initially enabled tasks must be disabled.'
    $restored = & $adapter 'restore-production-task-states' @{}
    Assert-True (@($restored.RestoredTasks).Count -eq 2) 'Restore result did not preserve initially enabled full task names.'
    Assert-True (@($schedulerState.Commands | Where-Object { $_ -contains '/Change' -and $_ -contains '/Enable' }).Count -eq 2) `
        'Restore must enable only tasks that were initially enabled.'
    Assert-True (-not $schedulerState.TaskDefinitions['\D365 SharePoint CSV Import [PROD]'].Enabled) `
        'A task initially disabled must remain disabled after restoration.'

    foreach ($failure in @('missing-task','invalid-xml','uri-mismatch','unknown-state')) {
        Reset-FakeSchtasks
        if ($failure -ceq 'invalid-xml') { $schedulerState.XmlOverride = '<not xml' }
        if ($failure -ceq 'uri-mismatch') { $schedulerState.XmlOverride = '<Task><RegistrationInfo><URI>\Wrong [PROD]</URI></RegistrationInfo><Settings><Enabled>true</Enabled></Settings></Task>' }
        if ($failure -ceq 'unknown-state') { $schedulerState.CsvStateOverride = 'Unknown' }
        $taskNames = if ($failure -ceq 'missing-task') { @('Missing [PROD]') } else { @('D365 File CSV Import [PROD]') }
        Assert-Throws { & $adapter 'disable-production-tasks' @{TaskNames=$taskNames} | Out-Null } 'task|Task|XML|XML|state|State'
        Assert-NoStateChanges "State-changing command ran for pre-validation failure: $failure"
    }

    Reset-FakeSchtasks
    $schedulerState.FailStateChange = $true
    Assert-Throws { & $adapter 'disable-production-tasks' @{TaskNames=@('D365 File CSV Import [PROD]')} | Out-Null } 'failed|Failed|exit|Exit'
    Assert-True (@($schedulerState.Commands | Where-Object { $_ -contains '/Change' }).Count -eq 1) 'A failing state-changing command was not invoked exactly once.'
    Assert-Throws {
        New-D365ManualRestoreMigrationAdapter -Manifest $manifest -SourceProjects $projects `
            -ProductionRoot (Join-Path $root 'prod') -BackupRoot (Join-Path $root 'backup') `
            -PhpPath $php -AppliedBy 'tester' -WaitForManualRestore $wait `
            -TaskSchedulerComputerName ' ' -ScheduledTaskCommandAdapter $fakeSchtasks | Out-Null
    } 'computer'
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
