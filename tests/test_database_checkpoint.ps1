$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\tools\database_checkpoint.ps1'
$plan = (& $scriptPath -Environment Production -ReleaseId '2026-07-31.1' -PlanOnly | Out-String | ConvertFrom-Json)

if ($plan.database -cne 'D365_finance_prod') {
    throw 'Production checkpoint selected the wrong database'
}
if ($plan.retention_days -ne 30 -or $plan.requires_restore_rehearsal -ne $true) {
    throw 'Production checkpoint omitted retention or restore rehearsal'
}
if ($plan.backup_file -notmatch 'D365_finance_prod.*2026-07-31.1.*\.sql$') {
    throw 'Backup file does not identify database and release'
}

Write-Host 'Database checkpoint plan checks passed.'
