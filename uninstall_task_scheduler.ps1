$TaskNames = @(
    "D365 SharePoint CSV Import",
    "D365 SharePoint CSV Download Cleanup"
)

foreach ($TaskName in $TaskNames) {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if (-not $Task) {
        Write-Host "Scheduled task not found: $TaskName"
        continue
    }

    if ($Task.State -eq "Running") {
        Stop-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 3
    }

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Scheduled task uninstalled: $TaskName"
}
