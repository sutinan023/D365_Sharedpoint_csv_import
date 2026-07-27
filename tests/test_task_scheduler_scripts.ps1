$ProjectPath = Split-Path -Parent $PSScriptRoot
$InstallerPath = Join-Path $ProjectPath 'install_task_scheduler.ps1'
$UninstallerPath = Join-Path $ProjectPath 'uninstall_task_scheduler.ps1'

$InstallerText = Get-Content -Raw -LiteralPath $InstallerPath
$UninstallerText = Get-Content -Raw -LiteralPath $UninstallerPath

$requiredInstallerText = @(
    'D365 SharePoint CSV Download Cleanup',
    'run_download_cleanup.bat',
    'schtasks.exe',
    '/SC MONTHLY',
    '/D 1',
    '/ST 01:00',
    'New-TimeSpan -Hours 1',
    'MultipleInstances IgnoreNew'
)

foreach ($RequiredText in $requiredInstallerText) {
    if (-not $InstallerText.Contains($RequiredText)) {
        throw "Installer is missing required text: $RequiredText"
    }
}

$requiredUninstallerText = @(
    'D365 SharePoint CSV Import',
    'D365 SharePoint CSV Download Cleanup',
    'Stop-ScheduledTask',
    'Unregister-ScheduledTask'
)

foreach ($RequiredText in $requiredUninstallerText) {
    if (-not $UninstallerText.Contains($RequiredText)) {
        throw "Uninstaller is missing required text: $RequiredText"
    }
}

Write-Host 'Task scheduler script tests passed.'
