$ErrorActionPreference = 'Stop'

function Invoke-D365MigrationStage {
    param(
        [Parameter(Mandatory = $true)][string] $Stage,
        [Parameter(Mandatory = $true)][scriptblock] $CommandAdapter,
        [Parameter(Mandatory = $true)][hashtable] $Context
    )
    $result = & $CommandAdapter $Stage $Context
    if ($null -eq $result -or $result.PSObject.Properties.Name -notcontains 'Success' -or $result.Success -ne $true) {
        throw "Migration stage failed closed: $Stage"
    }
    $Context[$Stage] = $result
    return $result
}

function Invoke-D365MigrationPromotion {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $ReleaseId,
        [Parameter(Mandatory = $true)][string] $ManifestPath,
        [Parameter(Mandatory = $true)][string] $ProjectRoot,
        [Parameter(Mandatory = $true)][string] $BackupRoot,
        [Parameter(Mandatory = $true)][string[]] $TaskNames,
        [string] $ApprovalToken,
        [scriptblock] $ApprovalProvider,
        [Parameter(Mandatory = $true)][scriptblock] $CommandAdapter
    )

    $context = @{
        ReleaseId = $ReleaseId
        ManifestPath = $ManifestPath
        ProjectRoot = $ProjectRoot
        BackupRoot = $BackupRoot
        TaskNames = @($TaskNames)
    }

    $disabled = Invoke-D365MigrationStage 'disable-production-tasks' $CommandAdapter $context
    $context.PreviouslyEnabledTasks = @($disabled.PreviouslyEnabledTasks)
    $checkpoint = Invoke-D365MigrationStage 'checkpoint-production' $CommandAdapter $context
    if ($checkpoint.PSObject.Properties.Name -contains 'BackupManifestPath') {
        $context.BackupManifestPath = [string] $checkpoint.BackupManifestPath
    }
    $prepared = Invoke-D365MigrationStage 'prepare-rehearsal' $CommandAdapter $context
    foreach ($name in @('RehearsalDatabase', 'SanitizedPath', 'SanitizerAuditPath')) {
        if ($prepared.PSObject.Properties.Name -contains $name) { $context[$name] = [string] $prepared.$name }
    }
    $instructions = Invoke-D365MigrationStage 'show-manual-restore-instructions' $CommandAdapter $context
    $instructionKeys = @($instructions.PSObject.Properties.Name | Where-Object { $_ -cne 'Success' })
    if ($instructionKeys.Count -ne 2 -or $instructionKeys -notcontains 'RehearsalDatabase' -or
        $instructionKeys -notcontains 'SanitizedPath') {
        throw "Manual restore instructions may contain only the rehearsal database and sanitized SQL path. Found: $($instructionKeys -join ',')"
    }
    [void] (Invoke-D365MigrationStage 'wait-for-manual-restore' $CommandAdapter $context)
    $verification = Invoke-D365MigrationStage 'verify-rehearsal-read-only' $CommandAdapter $context
    if ($verification.PSObject.Properties.Name -contains 'RestoreEvidencePath') {
        $context.RestoreEvidencePath = [string] $verification.RestoreEvidencePath
    }
    $rehearsalApproval = Invoke-D365MigrationStage 'approve-rehearsal-automatically' $CommandAdapter $context
    if ($rehearsalApproval.PSObject.Properties.Name -contains 'RestoreReceiptPath') {
        $context.RestoreReceiptPath = [string] $rehearsalApproval.RestoreReceiptPath
    }

    $expectedApproval = "APPLY MIGRATION $ReleaseId"
    if ([string]::IsNullOrWhiteSpace($ApprovalToken) -and $null -ne $ApprovalProvider) {
        $ApprovalToken = & $ApprovalProvider $ReleaseId
    }
    if ($ApprovalToken -cne $expectedApproval) {
        throw "Migration approval phrase did not match. Expected: $expectedApproval"
    }
    [void] (Invoke-D365MigrationStage 'approve-production-migration' $CommandAdapter $context)

    $firstApply = Invoke-D365MigrationStage 'apply-production' $CommandAdapter $context
    if ($firstApply.PSObject.Properties.Name -notcontains 'Applied') {
        throw 'First migration apply result did not contain an applied list.'
    }
    $secondApply = Invoke-D365MigrationStage 'apply-production-idempotence-check' $CommandAdapter $context
    if ($secondApply.PSObject.Properties.Name -notcontains 'Applied' -or @($secondApply.Applied).Count -ne 0) {
        throw 'Migration idempotence check attempted to apply migrations on the second run.'
    }
    $verification = Invoke-D365MigrationStage 'verify-production' $CommandAdapter $context

    [pscustomobject]@{
        ReleaseId = $ReleaseId
        Checkpoint = $checkpoint
        Instructions = $instructions
        Rehearsal = $rehearsalApproval
        FirstApply = $firstApply
        SecondApply = $secondApply
        Verification = $verification
        PreviouslyEnabledTasks = @($context.PreviouslyEnabledTasks)
        TasksRemainDisabled = $true
        Context = $context
    }
}

function Complete-D365MigrationPromotion {
    param(
        [Parameter(Mandatory = $true)][object] $MigrationResult,
        [Parameter(Mandatory = $true)][scriptblock] $CommandAdapter,
        [Parameter(Mandatory = $true)][switch] $ProductionDeployVerified
    )
    if (-not $ProductionDeployVerified -or $MigrationResult.TasksRemainDisabled -ne $true) {
        throw 'Production deploy/config/smoke verification is required before restoring task states.'
    }
    $context = $MigrationResult.Context
    $restored = Invoke-D365MigrationStage 'restore-production-task-states' $CommandAdapter $context
    [pscustomobject]@{
        ReleaseId = $MigrationResult.ReleaseId
        RestoredTasks = @($restored.RestoredTasks)
        TasksRemainDisabled = $false
    }
}
