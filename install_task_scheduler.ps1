param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('UAT', 'Production')]
    [string] $Environment,

    [string] $ProjectPath,
    [switch] $PlanOnly,
    [switch] $EnableProduction
)

$ErrorActionPreference = 'Stop'
$suffix = if ($Environment -eq 'UAT') { 'UAT' } else { 'PROD' }
$segment = if ($Environment -eq 'UAT') { 'uat' } else { 'prod' }
if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = "C:\xampp\htdocs\$segment\D365_Sharedpoint_csv_import"
}

$importStart = if ($Environment -eq 'UAT') { '00:01' } else { '00:00' }
$cleanupStart = if ($Environment -eq 'UAT') { '01:30' } else { '01:00' }
$importTaskName = "D365 SharePoint CSV Import [$suffix]"
$cleanupTaskName = "D365 SharePoint CSV Download Cleanup [$suffix]"
$batchPath = Join-Path $ProjectPath 'run_import.bat'
$cleanupBatchPath = Join-Path $ProjectPath 'run_download_cleanup.bat'

$plan = [ordered]@{
    environment = $Environment
    project_path = $ProjectPath
    import = [ordered]@{
        name = $importTaskName
        executable = $batchPath
        start_time = $importStart
        repeat_minutes = 5
        multiple_instances = 'IgnoreNew'
        enabled = ($Environment -eq 'UAT' -or $EnableProduction.IsPresent)
    }
    cleanup = [ordered]@{
        name = $cleanupTaskName
        executable = $cleanupBatchPath
        start_time = $cleanupStart
        day = 1
    }
}

if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 5
    return
}

foreach ($path in @($batchPath, $cleanupBatchPath, 'C:\xampp\php\php.exe')) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required path not found: $path"
    }
}

$action = New-ScheduledTaskAction -Execute $batchPath -WorkingDirectory $ProjectPath
$startAt = [datetime]::Today.Add([timespan]::Parse($importStart))
$trigger = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $importTaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "[$suffix] Download CSV from SharePoint and import into the isolated D365 database." -Force | Out-Null

& schtasks.exe /Create /TN $cleanupTaskName /TR $cleanupBatchPath /SC MONTHLY /D 1 /ST $cleanupStart /RL LIMITED /F | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to create scheduled task: $cleanupTaskName"
}
Set-ScheduledTask -TaskName $cleanupTaskName -Settings $settings | Out-Null

if ($Environment -eq 'Production' -and -not $EnableProduction) {
    Disable-ScheduledTask -TaskName $importTaskName | Out-Null
    Disable-ScheduledTask -TaskName $cleanupTaskName | Out-Null
}

$plan | ConvertTo-Json -Depth 5
