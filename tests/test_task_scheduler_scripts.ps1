$ErrorActionPreference = 'Stop'

$ProjectPath = Split-Path -Parent $PSScriptRoot
$InstallerPath = Join-Path $ProjectPath 'install_task_scheduler.ps1'
$UninstallerPath = Join-Path $ProjectPath 'uninstall_task_scheduler.ps1'

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ($Expected -cne $Actual) {
        throw "$Message expected=[$Expected] actual=[$Actual]"
    }
}

$uat = (& $InstallerPath -Environment UAT -ProjectPath 'C:\xampp\htdocs\uat\D365_Sharedpoint_csv_import' -PlanOnly | Out-String | ConvertFrom-Json)
$prod = (& $InstallerPath -Environment Production -ProjectPath 'C:\xampp\htdocs\prod\D365_Sharedpoint_csv_import' -PlanOnly | Out-String | ConvertFrom-Json)

Assert-Equal 'D365 SharePoint CSV Import [UAT]' $uat.import.name 'UAT import task name'
Assert-Equal 'D365 SharePoint CSV Download Cleanup [UAT]' $uat.cleanup.name 'UAT cleanup task name'
Assert-Equal '00:01' $uat.import.start_time 'UAT stagger time'
Assert-Equal '01:30' $uat.cleanup.start_time 'UAT cleanup time'
Assert-Equal 'D365 SharePoint CSV Import [PROD]' $prod.import.name 'Production import task name'
Assert-Equal '00:00' $prod.import.start_time 'Production stagger time'
Assert-Equal '01:00' $prod.cleanup.start_time 'Production cleanup time'
Assert-Equal 'IgnoreNew' $prod.import.multiple_instances 'Overlapping run policy'

$uninstall = (& $UninstallerPath -Environment Production -PlanOnly | Out-String | ConvertFrom-Json)
Assert-Equal 'D365 SharePoint CSV Import [PROD]' $uninstall[0] 'Production uninstall import name'
Assert-Equal 'D365 SharePoint CSV Download Cleanup [PROD]' $uninstall[1] 'Production uninstall cleanup name'

Write-Host 'Task scheduler script behavior checks passed.'
