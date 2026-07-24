$TaskName = "D365 SharePoint CSV Import"
$ProjectPath = "C:\xampp\htdocs\D365_Sharedpoint_csv_import"
$BatchPath = Join-Path $ProjectPath "run_import.bat"

if (-not (Test-Path $BatchPath)) {
    throw "Batch file not found: $BatchPath"
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

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 10
Get-ScheduledTaskInfo -TaskName $TaskName | Format-List LastRunTime,LastTaskResult,NextRunTime,NumberOfMissedRuns
