$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\release_migration.ps1')

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action; throw 'Expected failure.' } catch {
        if ($_.Exception.Message -eq 'Expected failure.' -or $_.Exception.Message -notmatch $Pattern) { throw }
    }
}

$expectedOrder = @(
    'disable-production-tasks', 'checkpoint-production', 'prepare-rehearsal',
    'show-manual-restore-instructions', 'wait-for-manual-restore',
    'verify-rehearsal-read-only', 'approve-rehearsal-automatically',
    'approve-production-migration', 'apply-production',
    'apply-production-idempotence-check', 'verify-production',
    'restore-production-task-states'
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
            'prepare-rehearsal' { return [pscustomobject]@{ Success=$true; RehearsalDatabase='D365_finance_prod_rehearsal_r1'; SanitizedPath='sanitized.sql'; SanitizerAuditPath='sanitized.sql.audit.json' } }
            'show-manual-restore-instructions' { return [pscustomobject]@{ Success=$true; RehearsalDatabase='D365_finance_prod_rehearsal_r1'; SanitizedPath='sanitized.sql' } }
            'verify-rehearsal-read-only' { return [pscustomobject]@{ Success=$true; RestoreEvidencePath='restore-evidence.json' } }
            'approve-rehearsal-automatically' { return [pscustomobject]@{ Success=$true; RestoreReceiptPath='restore-approved.json' } }
            'apply-production' { return [pscustomobject]@{ Success=$true; Applied=@('006_test.sql') } }
            'apply-production-idempotence-check' { return [pscustomobject]@{ Success=$true; Applied=@() } }
            'restore-production-task-states' { return [pscustomobject]@{ Success=$true; RestoredTasks=@('Import A') } }
            default { return [pscustomobject]@{ Success=$true } }
        }
    }.GetNewClosure()
}

$stages = [Collections.Generic.List[string]]::new()
$result = Invoke-D365MigrationPromotion -ReleaseId 'r1' -ManifestPath 'manifest.json' `
    -ProjectRoot 'project' -BackupRoot 'backup' -TaskNames @('Import A') `
    -ApprovalToken 'APPLY MIGRATION r1' -CommandAdapter (New-TestAdapter -Stages $stages)
Assert-True ($result.TasksRemainDisabled -eq $true) 'Tasks must remain disabled until code/config/smoke verification succeeds.'
Assert-True ($result.Cancelled -eq $false) 'Successful migration promotion was incorrectly marked as cancelled.'
Assert-True (@($result.FirstApply.Applied).Count -eq 1) 'First apply result was lost.'
Assert-True (@($result.SecondApply.Applied).Count -eq 0) 'Idempotence result was lost.'
$instructionNames = @($result.Instructions.PSObject.Properties.Name | Where-Object { $_ -cne 'Success' } | Sort-Object)
Assert-True ($instructionNames.Count -eq 2 -and $instructionNames -contains 'RehearsalDatabase' -and
    $instructionNames -contains 'SanitizedPath') 'Manual instructions exposed internal artifacts.'
$completed = Complete-D365MigrationPromotion -MigrationResult $result `
    -CommandAdapter (New-TestAdapter -Stages $stages) -ProductionDeployVerified
Assert-True (($stages -join "`n") -ceq ($expectedOrder -join "`n")) 'Migration stage order is wrong.'
Assert-True ($completed.TasksRemainDisabled -eq $false) 'Tasks were not restored after Production verification.'

$providerStages = [Collections.Generic.List[string]]::new()
$approvalProvider = {
    param([string] $ReleaseId)
    $providerStages.Add('request-migration-approval')
    return "APPLY MIGRATION $ReleaseId"
}.GetNewClosure()
Invoke-D365MigrationPromotion -ReleaseId 'r1' -ManifestPath 'manifest.json' -ProjectRoot 'project' `
    -BackupRoot 'backup' -TaskNames @('Import A') -ApprovalProvider $approvalProvider `
    -CommandAdapter (New-TestAdapter -Stages $providerStages) | Out-Null
$approvalIndex = $providerStages.IndexOf('request-migration-approval')
Assert-True ($approvalIndex -gt $providerStages.IndexOf('approve-rehearsal-automatically') -and
    $approvalIndex -lt $providerStages.IndexOf('approve-production-migration')) `
    'Migration confirmation was not requested immediately before Production apply approval.'

$cancelStages = [Collections.Generic.List[string]]::new()
$cancelReleaseIds = [Collections.Generic.List[string]]::new()
$cancelDecision = {
    param([string] $ReleaseId)
    $cancelReleaseIds.Add($ReleaseId)
    return $false
}.GetNewClosure()
$cancelResult = Invoke-D365MigrationPromotion -ReleaseId 'r1' -ManifestPath 'manifest.json' `
    -ProjectRoot 'project' -BackupRoot 'backup' -TaskNames @('Import A','Import B') `
    -ApprovalDecisionProvider $cancelDecision -CommandAdapter (New-TestAdapter -Stages $cancelStages)
Assert-True $cancelResult.Cancelled 'Migration N did not return a cancellation result.'
Assert-True (($cancelReleaseIds -join ',') -ceq 'r1') 'Migration decision provider did not receive the exact release ID.'
Assert-True ($cancelStages -notcontains 'approve-production-migration') 'Migration N reached Production approval.'
Assert-True ($cancelStages -notcontains 'apply-production') 'Migration N reached Production apply.'
Assert-True ($cancelStages[-1] -ceq 'restore-production-task-states') 'Migration N did not restore task state.'
Assert-True (($cancelResult.RestoredTasks -join ',') -ceq 'Import A') `
    'Migration N did not restore exactly the tasks that were enabled before migration.'
Assert-True ($cancelResult.TasksRemainDisabled -eq $false) 'Successful Migration cancellation reported tasks as disabled.'

$restoreFailureStages = [Collections.Generic.List[string]]::new()
Assert-Throws {
    Invoke-D365MigrationPromotion -ReleaseId 'r1' -ManifestPath 'manifest.json' `
        -ProjectRoot 'project' -BackupRoot 'backup' -TaskNames @('Import A','Import B') `
        -ApprovalDecisionProvider $cancelDecision `
        -CommandAdapter (New-TestAdapter -FailStage 'restore-production-task-states' -Stages $restoreFailureStages) | Out-Null
} 'restore-production-task-states'
Assert-True ($restoreFailureStages -notcontains 'apply-production') `
    'Failed cancellation restoration reached Production apply.'

$wrongApprovalStages = [Collections.Generic.List[string]]::new()
Assert-Throws {
    Invoke-D365MigrationPromotion -ReleaseId 'r1' -ManifestPath 'manifest.json' -ProjectRoot 'project' `
        -BackupRoot 'backup' -TaskNames @('Import A') -ApprovalToken 'apply migration r1' `
        -CommandAdapter (New-TestAdapter -Stages $wrongApprovalStages) | Out-Null
} 'approval'
Assert-True ($wrongApprovalStages -notcontains 'apply-production') 'Incorrect approval reached Production apply.'

foreach ($failureStage in @('prepare-rehearsal', 'show-manual-restore-instructions', 'wait-for-manual-restore', 'verify-rehearsal-read-only', 'approve-rehearsal-automatically', 'apply-production', 'apply-production-idempotence-check', 'verify-production')) {
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
    if ($Stage -ceq 'prepare-rehearsal') { return [pscustomobject]@{ Success=$true; RehearsalDatabase='D365_finance_prod_rehearsal_r1'; SanitizedPath='sanitized.sql'; SanitizerAuditPath='sanitized.sql.audit.json' } }
    if ($Stage -ceq 'show-manual-restore-instructions') { return [pscustomobject]@{ Success=$true; RehearsalDatabase='D365_finance_prod_rehearsal_r1'; SanitizedPath='sanitized.sql' } }
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
