$ErrorActionPreference = 'Stop'

function New-D365ManualRestoreMigrationAdapter {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $SourceProjects,
        [Parameter(Mandatory = $true)][string] $ProductionRoot,
        [Parameter(Mandatory = $true)][string] $BackupManifestPath,
        [Parameter(Mandatory = $true)][string] $RestoreReceiptPath,
        [Parameter(Mandatory = $true)][string] $PhpPath,
        [Parameter(Mandatory = $true)][string] $AppliedBy
    )

    foreach ($path in @($BackupManifestPath, $RestoreReceiptPath, $PhpPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required migration artifact not found: $path" }
    }
    if ($AppliedBy -notmatch '^[A-Za-z0-9_.@-]+$') { throw 'Migration applied-by value contains unsafe characters.' }

    $state = @{ PreviouslyEnabledTasks=@(); ApplyResults=@() }
    return {
        param([string] $Stage, [hashtable] $Context)
        switch ($Stage) {
            'validate-uat-ledger' { return [pscustomobject]@{Success=$true} }
            'disable-production-tasks' {
                $tasks = @()
                foreach ($taskName in $Context.TaskNames) {
                    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                    if ($null -eq $task) { throw "Production Scheduled Task not found: $taskName" }
                    $tasks += $task
                }
                $enabled = @($tasks | Where-Object State -cne 'Disabled' | ForEach-Object TaskName)
                foreach ($task in $tasks) {
                    if ($task.State -ceq 'Running') { Stop-ScheduledTask -TaskName $task.TaskName }
                    if ($task.State -cne 'Disabled') { Disable-ScheduledTask -TaskName $task.TaskName | Out-Null }
                }
                $state.PreviouslyEnabledTasks = $enabled
                return [pscustomobject]@{Success=$true;PreviouslyEnabledTasks=$enabled}
            }
            'checkpoint-production' {
                return [pscustomobject]@{Success=$true;BackupManifestPath=(Resolve-Path -LiteralPath $BackupManifestPath).ProviderPath}
            }
            { $_ -in @('prepare-rehearsal','restore-rehearsal','verify-rehearsal','approve-rehearsal','approve-production-migration') } {
                return [pscustomobject]@{Success=$true;RestoreReceiptPath=(Resolve-Path -LiteralPath $RestoreReceiptPath).ProviderPath}
            }
            { $_ -in @('apply-production','apply-production-idempotence-check') } {
                $allApplied = [Collections.Generic.List[string]]::new()
                foreach ($project in @('D365_Sharedpoint_csv_import','D365_file_csv_import','finance_report')) {
                    if (@($Manifest.migrations.$project).Count -eq 0) { continue }
                    $runner = Join-Path $ProductionRoot "$project\tools\apply_migrations.php"
                    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Migration runner not found in Production: $project" }
                    $directory = Join-Path $SourceProjects[$project].SourceRoot 'database\migrations'
                    $arguments = @(
                        '--apply', "--project=$project", "--directory=$directory",
                        "--release=$($Manifest.release_id)", "--applied-by=$AppliedBy",
                        "--backup-manifest=$BackupManifestPath", "--restore-receipt=$RestoreReceiptPath"
                    )
                    $raw = (& $PhpPath $runner @arguments | Out-String).Trim()
                    if ($LASTEXITCODE -ne 0) { throw "Migration runner failed: $project" }
                    try { $value = $raw | ConvertFrom-Json } catch { throw "Migration runner returned invalid JSON: $project" }
                    if ([string] $value.environment -cne 'PRODUCTION' -or [string] $value.database -cne 'D365_finance_prod' -or
                        [string] $value.release -cne [string] $Manifest.release_id) {
                        throw "Migration runner environment result is invalid: $project"
                    }
                    foreach ($version in @($value.applied)) { $allApplied.Add("$project/$version") }
                }
                return [pscustomobject]@{Success=$true;Applied=@($allApplied)}
            }
            'verify-production' { return [pscustomobject]@{Success=$true} }
            'restore-production-task-states' {
                foreach ($taskName in $state.PreviouslyEnabledTasks) { Enable-ScheduledTask -TaskName $taskName | Out-Null }
                return [pscustomobject]@{Success=$true;RestoredTasks=@($state.PreviouslyEnabledTasks)}
            }
            default { throw "Unsupported migration stage: $Stage" }
        }
    }.GetNewClosure()
}
