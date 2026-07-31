$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\tools\prepare_environment.ps1'
$plan = (& $script -Environment UAT -ApacheIdentity 'apache-test' -SchedulerIdentity 'scheduler-test' -PlanOnly | Out-String | ConvertFrom-Json)
if ($plan.root -cne 'C:\xampp\htdocs\uat') { throw 'UAT root is incorrect.' }
if ($plan.directories -notcontains 'C:\xampp\htdocs\uat\D365_file_csv_import\import') {
    # File importer inbound is a required runtime directory.
    throw 'UAT file importer inbound directory is missing.'
}
if ($plan.directories -notcontains 'C:\xampp\statement_storage\uat\statement_imports') {
    throw 'UAT statement storage is missing.'
}
if ($plan.env_files -notcontains 'C:\xampp\htdocs\uat\D365_Sharedpoint_csv_import\config\.env') {
    throw 'SharePoint environment file path is incorrect.'
}
Write-Host 'Environment preparation plan checks passed.'
