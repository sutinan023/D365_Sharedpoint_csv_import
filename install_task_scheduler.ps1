$TaskName = "D365 SharePoint CSV Import"
$CleanupTaskName = "D365 SharePoint CSV Download Cleanup"
$ProjectPath = "C:\xampp\htdocs\D365_Sharedpoint_csv_import"
$BatchPath = Join-Path $ProjectPath "run_import.bat"
$CleanupBatchPath = Join-Path $ProjectPath "run_download_cleanup.bat"

if (-not (Test-Path $BatchPath)) {
    throw "Batch file not found: $BatchPath"
}

if (-not (Test-Path $CleanupBatchPath)) {
    throw "Batch file not found: $CleanupBatchPath"
}

if (-not (Test-Path "C:\xampp\php\php.exe")) {
    throw "PHP not found: C:\xampp\php\php.exe"
}

$Action = New-ScheduledTaskAction -Execute $BatchPath -WorkingDirectory $ProjectPath
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5)
$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Settings $Settings `
    -Description "Download CSV from SharePoint and import to D365 MySQL tables every 5 minutes." `
    -Force

& schtasks.exe /Create /TN $CleanupTaskName /TR $CleanupBatchPath /SC MONTHLY /D 1 /ST 01:00 /RL LIMITED /F
if ($LASTEXITCODE -ne 0) {
    throw "Unable to create scheduled task: $CleanupTaskName"
}
Set-ScheduledTask -TaskName $CleanupTaskName -Settings $Settings

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 10
Get-ScheduledTaskInfo -TaskName $TaskName | Format-List LastRunTime,LastTaskResult,NextRunTime,NumberOfMissedRuns
