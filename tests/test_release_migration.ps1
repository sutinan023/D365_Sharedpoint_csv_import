$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\release_migration.ps1')

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action; throw 'Expected failure.' } catch {
        if ($_.Exception.Message -eq 'Expected failure.' -or $_.Exception.Message -notmatch $Pattern) { throw }
    }
}

$expectedOrder = @(
    'validate-uat-ledger', 'disable-production-tasks', 'checkpoint-production',
    'prepare-rehearsal', 'restore-rehearsal', 'verify-rehearsal',
    'approve-rehearsal', 'approve-production-migration', 'apply-production',
    'apply-production-idempotence-check', 'verify-production'
)

function New-TestAdapter {
    param([string] $FailStage, [System.Collections.Generic.List[string]] $Stages)
    return {
        param([string] $Stage, [hashtable] $Context)
        $Stages.Add($Stage)
        if ($Stage -ceq $FailStage) { throw "Injected failure: $Stage" }
        switch ($Stage) {
            'disable-production-tasks' { return [pscustomobject]@{ Success=$true; PreviouslyEnabledTasks=@('Import A') } }
            'checkpoint-production' { return [pscustomobject]@{ Success=$true; BackupManifestPath='checkpoint.json' } }
            'approve-rehearsal' { return [pscustomobject]@{ Success=$true; RestoreReceiptPath='restore-approved.json' } }
            'apply-production' { return [pscustomobject]@{ Success=$true; Applied=@('006_test.sql') } }
            'apply-production-idempotence-check' { return [pscustomobject]@{ Success=$true; Applied=@() } }
            default { return [pscustomobject]@{ Success=$true } }
        }
    }.GetNewClosure()
}

$stages = [Collections.Generic.List[string]]::new()
$result = Invoke-D365MigrationPromotion -ReleaseId 'r1' -ManifestPath 'manifest.json' `
    -ProjectRoot 'project' -BackupRoot 'backup' -TaskNames @('Import A') `
    -ApprovalToken 'APPLY MIGRATION r1' -CommandAdapter (New-TestAdapter -Stages $stages)
Assert-True (($stages -join "`n") -ceq ($expectedOrder -join "`n")) 'Migration stage order is wrong.'
Assert-True ($result.TasksRemainDisabled -eq $true) 'Tasks must remain disabled until code/config/smoke verification succeeds.'
Assert-True (@($result.FirstApply.Applied).Count -eq 1) 'First apply result was lost.'
Assert-True (@($result.SecondApply.Applied).Count -eq 0) 'Idempotence result was lost.'

$wrongApprovalStages = [Collections.Generic.List[string]]::new()
Assert-Throws {
    Invoke-D365MigrationPromotion -ReleaseId 'r1' -ManifestPath 'manifest.json' -ProjectRoot 'project' `
        -BackupRoot 'backup' -TaskNames @('Import A') -ApprovalToken 'apply migration r1' `
        -CommandAdapter (New-TestAdapter -Stages $wrongApprovalStages) | Out-Null
} 'approval'
Assert-True ($wrongApprovalStages -notcontains 'apply-production') 'Incorrect approval reached Production apply.'

foreach ($failureStage in @('restore-rehearsal', 'verify-rehearsal', 'approve-rehearsal', 'apply-production', 'apply-production-idempotence-check', 'verify-production')) {
    $failureStages = [Collections.Generic.List[string]]::new()
    Assert-Throws {
        Invoke-D365MigrationPromotion -ReleaseId 'r1' -ManifestPath 'manifest.json' -ProjectRoot 'project' `
            -BackupRoot 'backup' -TaskNames @('Import A') -ApprovalToken 'APPLY MIGRATION r1' `
            -CommandAdapter (New-TestAdapter -FailStage $failureStage -Stages $failureStages) | Out-Null
    } $failureStage
    Assert-True ($failureStages -notcontains 'restore-production-task-states') "Failure at $failureStage restored tasks unsafely."
}

$badIdempotenceStages = [Collections.Generic.List[string]]::new()
$badIdempotenceAdapter = {
    param([string] $Stage, [hashtable] $Context)
    $badIdempotenceStages.Add($Stage)
    if ($Stage -ceq 'disable-production-tasks') { return [pscustomobject]@{ Success=$true; PreviouslyEnabledTasks=@('Import A') } }
    if ($Stage -ceq 'apply-production') { return [pscustomobject]@{ Success=$true; Applied=@('006.sql') } }
    if ($Stage -ceq 'apply-production-idempotence-check') { return [pscustomobject]@{ Success=$true; Applied=@('006.sql') } }
    return [pscustomobject]@{ Success=$true }
}.GetNewClosure()
Assert-Throws {
    Invoke-D365MigrationPromotion -ReleaseId 'r1' -ManifestPath 'manifest.json' -ProjectRoot 'project' `
        -BackupRoot 'backup' -TaskNames @('Import A') -ApprovalToken 'APPLY MIGRATION r1' `
        -CommandAdapter $badIdempotenceAdapter | Out-Null
} 'idempotence'

Write-Host 'Guarded migration coordination checks passed.'
