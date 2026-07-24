$TaskName = "D365 SharePoint CSV Import"

$Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

if (-not $Task) {
    Write-Host "Scheduled task not found: $TaskName"
    exit 0
}

if ($Task.State -eq "Running") {
    Stop-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Scheduled task uninstalled: $TaskName"
