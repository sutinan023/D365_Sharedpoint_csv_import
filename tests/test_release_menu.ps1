$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\release.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('release-menu-{0}' -f [guid]::NewGuid())
$sourceParent = Join-Path $testRoot 'source'
$uatRoot = Join-Path $testRoot 'uat'
$productionRoot = Join-Path $testRoot 'prod'
$releaseRoot = Join-Path $testRoot 'releases'
$projects = @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$releaseScriptBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $scriptPath))
Assert-True ($releaseScriptBytes.Length -ge 3 -and $releaseScriptBytes[0] -eq 0xEF -and
    $releaseScriptBytes[1] -eq 0xBB -and $releaseScriptBytes[2] -eq 0xBF) `
    'release.ps1 must use UTF-8 BOM so Windows PowerShell 5.1 parses Thai text correctly.'
$releaseScriptText = [Text.Encoding]::UTF8.GetString($releaseScriptBytes)
foreach ($thaiPrompt in @('ยืนยันว่าทดสอบ UAT ผ่าน','ยืนยันใช้ MIGRATION','ยืนยันนำขึ้น PRODUCTION','กด Enter หลัง Import สำเร็จ')) {
    Assert-True ($releaseScriptText.Contains($thaiPrompt)) "Thai confirmation is missing: $thaiPrompt"
}
foreach ($removedPrompt in @('ระบุ path ของ checkpoint manifest','ระบุ path ของ restore-approved receipt')) {
    Assert-True (-not $releaseScriptText.Contains($removedPrompt)) "Old technical prompt is still visible: $removedPrompt"
}
Assert-True (-not $releaseScriptText.Contains('พิมพ์ $thaiApproval')) `
    'Interactive UAT deployment still expects the former Thai typed approval.'

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action; throw 'Expected failure.' } catch {
        if ($_.Exception.Message -eq 'Expected failure.' -or $_.Exception.Message -notmatch $Pattern) { throw }
    }
}

function Set-TightAcl([string] $Path) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void] $acl.RemoveAccessRuleSpecific($rule) }
    $accessRule = New-Object Security.AccessControl.FileSystemAccessRule(
        $sid, [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)
    [void] $acl.AddAccessRule($accessRule)
    $acl.SetOwner($sid)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function New-TestRepository([string] $Path, [string] $Project) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'app.php') -Value "<?php echo '$Project';"
    Set-Content -LiteralPath (Join-Path $Path 'same.php') -Value '<?php echo "same";'
    & git -C $Path init --quiet
    & git -C $Path config core.autocrlf false
    & git -C $Path config user.email 'test@example.invalid'
    & git -C $Path config user.name 'Test'
    & git -C $Path add .
    & git -C $Path commit --quiet -m initial
    return (& git -C $Path rev-parse HEAD).Trim()
}

try {
    New-Item -ItemType Directory -Path $sourceParent, $uatRoot, $productionRoot, $releaseRoot -Force | Out-Null
    $manifestProjects = [ordered]@{}
    foreach ($project in $projects) {
        $source = Join-Path $sourceParent $project
        $sha = New-TestRepository -Path $source -Project $project
        $manifestProjects[$project] = [ordered]@{ git_sha = $sha }
        foreach ($environmentRoot in @($uatRoot, $productionRoot)) {
            $destination = Join-Path $environmentRoot $project
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $source 'same.php') -Destination (Join-Path $destination 'same.php')
        }
    }

    $plan = @(& $scriptPath -Action DeployUAT -ReleaseId '2026-08-01.1' `
        -SourceParent $sourceParent -UatRoot $uatRoot -ProductionRoot $productionRoot `
        -ReleaseRoot $releaseRoot -PlanOnly -LocalTestMode)
    Assert-True (@($plan | Where-Object { $_ -is [string] -and $_ -match 'แผน Deploy UAT' }).Count -eq 1) 'Thai UAT plan heading is missing.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $releaseRoot '2026-08-01.1.json'))) 'PlanOnly wrote a release manifest.'
    foreach ($project in $projects) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $uatRoot "$project\app.php"))) 'PlanOnly copied a source file.'
    }

    $wizardAnswers = [Collections.Generic.Queue[string]]::new()
    $wizardAnswers.Enqueue('1')
    $wizardInput = { param([string]$Prompt) $wizardAnswers.Dequeue() }.GetNewClosure()
    $wizardOutput = @(& $scriptPath -Action Menu -SourceParent $sourceParent -UatRoot $uatRoot `
        -ProductionRoot $productionRoot -ReleaseRoot $releaseRoot -PlanOnly -LocalTestMode `
        -WizardNow ([datetime]'2026-08-02') -WizardInputAdapter $wizardInput 6>&1)
    foreach ($label in @('อัปเดต UAT','นำ Release ที่ผ่าน UAT ขึ้น Production','ตรวจสอบสถานะและเปรียบเทียบอย่างเดียว','ออก')) {
        Assert-True (@($wizardOutput | Where-Object { [string]$_ -match [regex]::Escape($label) }).Count -eq 1) "Thai wizard label is missing: $label"
    }
    Assert-True (@($wizardOutput | Where-Object { [string]$_ -match '2026-08-02\.1' }).Count -gt 0) 'Wizard did not generate the next release ID.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $releaseRoot '2026-08-02.1.json'))) 'Wizard PlanOnly created a manifest.'

    $answers = [Collections.Generic.Queue[string]]::new()
    $answers.Enqueue('1')
    $answers.Enqueue('maybe')
    $answers.Enqueue(' y ')
    $prompts = [Collections.Generic.List[string]]::new()
    $input = {
        param([string] $Prompt)
        $prompts.Add($Prompt)
        $answers.Dequeue()
    }.GetNewClosure()
    $uatWizardOutput = @(& $scriptPath -Action Menu -SourceParent $sourceParent -UatRoot $uatRoot `
        -ProductionRoot $productionRoot -ReleaseRoot $releaseRoot -LocalTestMode `
        -WizardNow ([datetime]'2026-08-02') -WizardInputAdapter $input 6>&1)
    Assert-True (@($prompts | Where-Object { $_ -match '\[Y/N\]' }).Count -eq 2) `
        'Invalid Y/N answer was not asked again.'
    Assert-True (@($uatWizardOutput | Where-Object { [string]$_ -match 'Deploy UAT release 2026-08-02\.1 สำเร็จ' }).Count -eq 1) `
        'Interactive UAT deployment did not finish in LocalTestMode.'

    $metadataBeforeCancellation = [ordered]@{}
    foreach ($project in $projects) {
        $metadataPath = Join-Path $uatRoot "$project\.deployment\current-release.json"
        Assert-True (Test-Path -LiteralPath $metadataPath -PathType Leaf) "Interactive UAT deployment did not create metadata: $project"
        $metadataBeforeCancellation[$project] = Get-Content -LiteralPath $metadataPath -Raw
    }
    $cancelAnswers = [Collections.Generic.Queue[string]]::new()
    $cancelAnswers.Enqueue('1')
    $cancelAnswers.Enqueue('maybe')
    $cancelAnswers.Enqueue('N')
    $cancelPrompts = [Collections.Generic.List[string]]::new()
    $cancelInput = {
        param([string] $Prompt)
        $cancelPrompts.Add($Prompt)
        $cancelAnswers.Dequeue()
    }.GetNewClosure()
    $cancelOutput = @(& $scriptPath -Action Menu -SourceParent $sourceParent -UatRoot $uatRoot `
        -ProductionRoot $productionRoot -ReleaseRoot $releaseRoot -LocalTestMode `
        -WizardNow ([datetime]'2026-08-02') -WizardInputAdapter $cancelInput 6>&1)
    Assert-True (@($cancelPrompts | Where-Object { $_ -match '\[Y/N\]' }).Count -eq 2) `
        'Invalid input followed by N was not asked again.'
    Assert-True (@($cancelOutput | Where-Object { [string]$_ -match 'ยกเลิกการอัปเดต UAT Release 2026-08-02\.2' }).Count -eq 1) `
        'N did not cancel the interactive UAT deployment.'
    foreach ($project in $projects) {
        $metadataPath = Join-Path $uatRoot "$project\.deployment\current-release.json"
        Assert-True ((Get-Content -LiteralPath $metadataPath -Raw) -ceq $metadataBeforeCancellation[$project]) `
            "UAT cancellation changed destination metadata: $project"
    }

    try {
        & $scriptPath -Action DeployUAT -ReleaseId 'bad release id' -SourceParent $sourceParent `
            -UatRoot $uatRoot -ProductionRoot $productionRoot -ReleaseRoot $releaseRoot -PlanOnly -LocalTestMode | Out-Null
        throw 'Invalid release ID was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'ReleaseId|pattern') { throw }
    }

    $missingParent = Join-Path $testRoot 'missing-source'
    try {
        & $scriptPath -Action DeployUAT -ReleaseId '2026-08-01.2' -SourceParent $missingParent `
            -UatRoot $uatRoot -ProductionRoot $productionRoot -ReleaseRoot $releaseRoot -PlanOnly -LocalTestMode | Out-Null
        throw 'Missing project directories were accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'not found|ไม่พบ') { throw }
    }

    $manifest = [ordered]@{
        release_id = '2026-08-01.3'
        created_at = (Get-Date).ToString('o')
        projects = $manifestProjects
        migrations = [ordered]@{
            D365_Sharedpoint_csv_import = @()
            D365_file_csv_import = @()
            finance_report = @()
        }
    }
    $manifestPath = Join-Path $releaseRoot '2026-08-01.3.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    foreach ($project in $projects) {
        $destination = Join-Path $uatRoot $project
        Set-Content -LiteralPath (Join-Path $destination 'app.php') -Value 'modified'
        Set-Content -LiteralPath (Join-Path $destination 'deleted.php') -Value 'destination-only'
        $metadataDirectory = Join-Path $destination '.deployment'
        New-Item -ItemType Directory -Path $metadataDirectory -Force | Out-Null
        [ordered]@{
            release_id = '2026-08-01.3'
            environment = 'UAT'
            project = $project
            git_sha = [string] $manifestProjects[$project].git_sha
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $metadataDirectory 'current-release.json') -Encoding UTF8
    }

    $statusAnswers = [Collections.Generic.Queue[string]]::new()
    $statusAnswers.Enqueue('3')
    $statusInput = { param([string]$Prompt) $statusAnswers.Dequeue() }.GetNewClosure()
    $statusComparison = @(& $scriptPath -Action Menu -SourceParent $sourceParent -UatRoot $uatRoot `
        -ProductionRoot $productionRoot -ReleaseRoot $releaseRoot -LocalTestMode `
        -WizardInputAdapter $statusInput | Where-Object { $_.PSObject.Properties.Name -contains 'Environment' })
    Assert-True ($statusComparison.Count -eq 6) 'Status wizard did not select the common UAT release automatically.'

    $comparison = @(& $scriptPath -Action Compare -ReleaseId '2026-08-01.3' `
        -SourceParent $sourceParent -UatRoot $uatRoot -ProductionRoot $productionRoot `
        -ReleaseRoot $releaseRoot -LocalTestMode | Where-Object { $_.PSObject.Properties.Name -contains 'Environment' })
    $uatResults = @($comparison | Where-Object Environment -ceq 'UAT')
    $productionResults = @($comparison | Where-Object Environment -ceq 'PRODUCTION')
    Assert-True ($uatResults.Count -eq 3) 'Compare did not return all UAT projects.'
    Assert-True ($productionResults.Count -eq 3) 'Compare did not return all Production projects.'
    foreach ($result in $uatResults) {
        Assert-True ($result.New -eq 0) "UAT New count mismatch: $($result.Project)"
        Assert-True ($result.Modified -eq 1) "UAT Modified count mismatch: $($result.Project)"
        Assert-True ($result.Deleted -eq 1) "UAT Deleted count mismatch: $($result.Project)"
    }
    foreach ($result in $productionResults) {
        Assert-True ($result.New -eq 1) "Production New count mismatch: $($result.Project)"
        Assert-True ($result.Modified -eq 0) "Production Modified count mismatch: $($result.Project)"
        Assert-True ($result.Deleted -eq 0) "Production Deleted count mismatch: $($result.Project)"
    }

    # Prepare a second, code-only release: UAT exactly matches it, while Production remains on the prior SHA.
    $priorProjects = [ordered]@{}
    foreach ($project in $projects) {
        $priorProjects[$project] = [string] $manifestProjects[$project].git_sha
        $source = Join-Path $sourceParent $project
        Set-Content -LiteralPath (Join-Path $source 'app.php') -Value "<?php echo '$project release-2';"
        & git -C $source add app.php
        & git -C $source commit --quiet -m release-2
        $manifestProjects[$project].git_sha = (& git -C $source rev-parse HEAD).Trim()

        $uatDestination = Join-Path $uatRoot $project
        Copy-Item -LiteralPath (Join-Path $source 'app.php') -Destination (Join-Path $uatDestination 'app.php') -Force
        Remove-Item -LiteralPath (Join-Path $uatDestination 'deleted.php') -Force
        $uatMetadataPath = Join-Path $uatDestination '.deployment\current-release.json'
        [ordered]@{ release_id='2026-08-01.4'; environment='UAT'; project=$project; git_sha=[string]$manifestProjects[$project].git_sha } |
            ConvertTo-Json | Set-Content -LiteralPath $uatMetadataPath -Encoding UTF8

        $prodMetadataDirectory = Join-Path $productionRoot "$project\.deployment"
        New-Item -ItemType Directory -Path $prodMetadataDirectory -Force | Out-Null
        [ordered]@{ release_id='prior'; environment='PRODUCTION'; project=$project; git_sha=[string]$priorProjects[$project] } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $prodMetadataDirectory 'current-release.json') -Encoding UTF8
    }
    $releaseId = '2026-08-01.4'
    $releaseManifestPath = Join-Path $releaseRoot "$releaseId.json"
    [ordered]@{ release_id=$releaseId; created_at=(Get-Date).ToString('o'); projects=$manifestProjects; migrations=[ordered]@{
        D365_Sharedpoint_csv_import=@(); D365_file_csv_import=@(); finance_report=@()
    }} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $releaseManifestPath -Encoding UTF8

    $promotionBase = @{ Action='PromoteProduction'; ReleaseId=$releaseId; SourceParent=$sourceParent; UatRoot=$uatRoot
        ProductionRoot=$productionRoot; ReleaseRoot=$releaseRoot; LocalTestMode=$true }
    $promotionPlan = @(& $scriptPath @promotionBase -PlanOnly)
    Assert-True (@($promotionPlan | Where-Object { $_ -is [string] -and $_ -match 'code-only' }).Count -eq 1) 'Successful code-only Production plan was not reported.'

    $financeMetadataPath = Join-Path $uatRoot 'finance_report\.deployment\current-release.json'
    $financeMetadata = Get-Content -LiteralPath $financeMetadataPath -Raw | ConvertFrom-Json
    $financeMetadata.git_sha = '0' * 40
    $financeMetadata | ConvertTo-Json | Set-Content -LiteralPath $financeMetadataPath -Encoding UTF8
    Assert-Throws { & $scriptPath @promotionBase -PlanOnly | Out-Null } 'SHA'
    $financeMetadata.git_sha = [string] $manifestProjects.finance_report.git_sha
    $financeMetadata | ConvertTo-Json | Set-Content -LiteralPath $financeMetadataPath -Encoding UTF8

    $uatFinanceApp = Join-Path $uatRoot 'finance_report\app.php'
    Add-Content -LiteralPath $uatFinanceApp -Value 'drift'
    Assert-Throws { & $scriptPath @promotionBase -PlanOnly | Out-Null } 'drift'
    Copy-Item -LiteralPath (Join-Path $sourceParent 'finance_report\app.php') -Destination $uatFinanceApp -Force

    $auditRoot = Join-Path $testRoot 'approval-audit'
    New-Item -ItemType Directory -Path $auditRoot | Out-Null
    Set-TightAcl $auditRoot
    $beforeProductionFiles = @(Get-ChildItem -LiteralPath $productionRoot -File -Recurse -Force | ForEach-Object { $_.FullName })
    Assert-Throws {
        & $scriptPath @promotionBase -ApprovalAuditRoot $auditRoot -UatAcceptanceToken 'wrong' -ProductionApprovalToken "APPROVE PRODUCTION $releaseId" | Out-Null
    } 'approval'
    Assert-Throws {
        & $scriptPath @promotionBase -ApprovalAuditRoot $auditRoot -UatApprovalPath (Join-Path $auditRoot 'missing.json') `
            -ExpectedUatApprovalSha256 ('0' * 64) -ProductionApprovalToken "APPROVE PRODUCTION $releaseId" | Out-Null
    } 'not found'

    Assert-Throws {
        & $scriptPath @promotionBase -ApprovalAuditRoot $auditRoot -UatAcceptanceToken "APPROVE UAT RESULT $releaseId" `
            -ProductionApprovalToken 'wrong-production-approval' | Out-Null
    } 'approval'
    $manifestHash = (Get-FileHash -LiteralPath $releaseManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $receiptPath = Join-Path $auditRoot "uat-approval-$releaseId-$manifestHash.json"
    Assert-True (Test-Path -LiteralPath $receiptPath -PathType Leaf) 'UAT acceptance receipt was not created.'
    $receiptHash = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Throws {
        & $scriptPath @promotionBase -ApprovalAuditRoot $auditRoot -UatApprovalPath $receiptPath `
            -ExpectedUatApprovalSha256 ('0' * 64) -ProductionApprovalToken "APPROVE PRODUCTION $releaseId" | Out-Null
    } 'SHA-256'

    $success = @(& $scriptPath @promotionBase -ApprovalAuditRoot $auditRoot -UatApprovalPath $receiptPath `
        -ExpectedUatApprovalSha256 $receiptHash -ProductionApprovalToken "APPROVE PRODUCTION $releaseId")
    Assert-True (@($success | Where-Object { $_ -is [string] -and $_ -match 'Production gates passed' }).Count -eq 1) 'Local Production gate success was not reported.'
    $afterProductionFiles = @(Get-ChildItem -LiteralPath $productionRoot -File -Recurse -Force | ForEach-Object { $_.FullName })
    Assert-True (($beforeProductionFiles -join "`n") -ceq ($afterProductionFiles -join "`n")) 'A rejected or local Production plan changed Production files.'

    # A migration release is visible in PlanOnly and requires the guarded coordinator before promotion.
    $migrationReleaseId = '2026-08-01.5'
    $sharePointSource = Join-Path $sourceParent 'D365_Sharedpoint_csv_import'
    $migrationDirectory = Join-Path $sharePointSource 'database\migrations'
    New-Item -ItemType Directory -Path $migrationDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $migrationDirectory '006_test.sql') -Value 'SELECT 1;'
    & git -C $sharePointSource add .
    & git -C $sharePointSource commit --quiet -m migration-release
    $manifestProjects.D365_Sharedpoint_csv_import.git_sha = (& git -C $sharePointSource rev-parse HEAD).Trim()
    $uatSharePointMigration = Join-Path $uatRoot 'D365_Sharedpoint_csv_import\database\migrations'
    New-Item -ItemType Directory -Path $uatSharePointMigration -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $migrationDirectory '006_test.sql') -Destination (Join-Path $uatSharePointMigration '006_test.sql')
    [ordered]@{ release_id=$migrationReleaseId; environment='UAT'; project='D365_Sharedpoint_csv_import'; git_sha=[string]$manifestProjects.D365_Sharedpoint_csv_import.git_sha } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $uatRoot 'D365_Sharedpoint_csv_import\.deployment\current-release.json') -Encoding UTF8
    foreach ($project in @('D365_file_csv_import','finance_report')) {
        $metadataPath = Join-Path $uatRoot "$project\.deployment\current-release.json"
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        $metadata.release_id = $migrationReleaseId
        $metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    }
    $migrationManifestPath = Join-Path $releaseRoot "$migrationReleaseId.json"
    [ordered]@{ release_id=$migrationReleaseId; projects=$manifestProjects; migrations=[ordered]@{
        D365_Sharedpoint_csv_import=@('006_test.sql'); D365_file_csv_import=@(); finance_report=@()
    }} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $migrationManifestPath -Encoding UTF8
    $migrationPromotion = @{ Action='PromoteProduction'; ReleaseId=$migrationReleaseId; SourceParent=$sourceParent; UatRoot=$uatRoot
        ProductionRoot=$productionRoot; ReleaseRoot=$releaseRoot; LocalTestMode=$true }
    $migrationPlan = @(& $scriptPath @migrationPromotion -PlanOnly)
    Assert-True (@($migrationPlan | Where-Object { $_ -is [string] -and $_ -match '006_test.sql' }).Count -eq 1) 'Migration PlanOnly did not list the migration.'
    Assert-Throws {
        & $scriptPath @migrationPromotion -ApprovalAuditRoot $auditRoot `
            -UatAcceptanceToken "APPROVE UAT RESULT $migrationReleaseId" | Out-Null
    } 'MigrationCommandAdapter'
    $migrationManifestHash = (Get-FileHash -LiteralPath $migrationManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $migrationReceiptPath = Join-Path $auditRoot "uat-approval-$migrationReleaseId-$migrationManifestHash.json"
    $migrationReceiptHash = (Get-FileHash -LiteralPath $migrationReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $migrationStages = [Collections.Generic.List[string]]::new()
    $migrationAdapter = {
        param([string] $Stage, [hashtable] $Context)
        $migrationStages.Add($Stage)
        switch ($Stage) {
            'disable-production-tasks' { [pscustomobject]@{Success=$true;PreviouslyEnabledTasks=@('Import A')} }
            'prepare-rehearsal' { [pscustomobject]@{Success=$true;RehearsalDatabase="D365_finance_prod_rehearsal_$($migrationReleaseId.Replace('-','_').Replace('.','_'))";SanitizedPath='sanitized.sql';SanitizerAuditPath='sanitized.sql.audit.json'} }
            'show-manual-restore-instructions' { [pscustomobject]@{Success=$true;RehearsalDatabase="D365_finance_prod_rehearsal_$($migrationReleaseId.Replace('-','_').Replace('.','_'))";SanitizedPath='sanitized.sql'} }
            'verify-rehearsal-read-only' { [pscustomobject]@{Success=$true;RestoreEvidencePath='restore-evidence.json'} }
            'approve-rehearsal-automatically' { [pscustomobject]@{Success=$true;RestoreReceiptPath='restore-approved.json'} }
            'apply-production' { [pscustomobject]@{Success=$true;Applied=@('006_test.sql')} }
            'apply-production-idempotence-check' { [pscustomobject]@{Success=$true;Applied=@()} }
            'restore-production-task-states' { [pscustomobject]@{Success=$true;RestoredTasks=@('Import A')} }
            default { [pscustomobject]@{Success=$true} }
        }
    }.GetNewClosure()
    $migrationSuccess = @(& $scriptPath @migrationPromotion -ApprovalAuditRoot $auditRoot `
        -UatApprovalPath $migrationReceiptPath -ExpectedUatApprovalSha256 $migrationReceiptHash `
        -ProductionApprovalToken "APPROVE PRODUCTION $migrationReleaseId" `
        -MigrationApprovalToken "APPLY MIGRATION $migrationReleaseId" -MigrationCommandAdapter $migrationAdapter)
    Assert-True ($migrationStages -contains 'apply-production-idempotence-check') 'Migration promotion skipped the idempotence check.'
    Assert-True ($migrationStages[-1] -ceq 'restore-production-task-states') 'Migration promotion did not restore task states last.'
    Assert-True (@($migrationSuccess | Where-Object { $_ -is [string] -and $_ -match 'Production gates passed' }).Count -eq 1) 'Migration promotion did not complete its local gates.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'Thai release menu checks passed.'
