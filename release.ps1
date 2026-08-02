param(
    [ValidateSet('Menu', 'DeployUAT', 'Compare', 'PromoteProduction')]
    [string] $Action = 'Menu',

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ReleaseId,

    [string] $SourceParent = 'C:\xampp\htdocs',
    [string] $UatRoot = '\\100.1.1.166\htdocs\uat',
    [string] $ProductionRoot = '\\100.1.1.166\htdocs\prod',
    [string] $ReleaseRoot = 'C:\xampp\backups\d365\releases',
    [string] $ApprovalToken,
    [string] $UatAcceptanceToken,
    [string] $OperationalApprovalToken,
    [string] $ProductionApprovalToken,
    [string] $ApprovalAuditRoot = 'C:\xampp\backups\d365\release-approvals',
    [string] $UatApprovalPath,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedUatApprovalSha256,
    [string] $PhpPath = 'C:\xampp\php\php.exe',
    [string] $MigrationApprovalToken,
    [string] $MigrationBackupRoot = 'C:\xampp\backups\d365',
    [string] $MigrationAppliedBy = $env:USERNAME,
    [string[]] $ProductionTaskNames = @(
        'D365 SharePoint CSV Import [PROD]',
        'D365 File CSV Import [PROD]',
        'D365 SharePoint CSV Download Cleanup [PROD]'
    ),
    [scriptblock] $MigrationCommandAdapter,
    [datetime] $WizardNow = (Get-Date),
    [scriptblock] $WizardInputAdapter,
    [switch] $PlanOnly,
    [switch] $LocalTestMode
)

$ErrorActionPreference = 'Stop'
$interactiveMenu = $Action -ceq 'Menu'
$automaticReleaseRequested = $false
$toolRoot = Join-Path $PSScriptRoot 'tools'
. (Join-Path $toolRoot 'release_common.ps1')
. (Join-Path $toolRoot 'release_migration.ps1')
. (Join-Path $toolRoot 'manual_restore_migration_adapter.ps1')

if ($null -ne $WizardInputAdapter -and -not $LocalTestMode) {
    throw 'WizardInputAdapter ใช้ได้เฉพาะ LocalTestMode'
}

function Read-WizardAnswer([string] $Prompt) {
    if ($LocalTestMode -and $null -ne $WizardInputAdapter) { return & $WizardInputAdapter $Prompt }
    return Read-Host $Prompt
}

function Read-WizardConfirmation([string] $Prompt) {
    while ($true) {
        $answer = ([string] (Read-WizardAnswer "$Prompt [Y/N]")).Trim()
        if ($answer -ieq 'Y') { return $true }
        if ($answer -ieq 'N') { return $false }
        Write-Host 'กรุณาตอบ Y หรือ N เท่านั้น'
    }
}

function New-AutomaticReleaseManifest {
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $candidate = Get-D365NextReleaseId -ReleaseRoot $ReleaseRoot -Now $WizardNow
        $path = Join-Path $ReleaseRoot "$candidate.json"
        try {
            & (Join-Path $toolRoot 'new_release_manifest.ps1') -ReleaseId $candidate `
                -SourceParent $SourceParent -OutputPath $path | Out-Null
            return [pscustomobject]@{ ReleaseId=$candidate; ManifestPath=$path }
        } catch {
            if ($_.Exception.Message -notmatch 'immutable|already exists') { throw }
        }
    }
    throw 'ไม่สามารถสร้างหมายเลข Release ที่ไม่ซ้ำได้'
}

function Assert-ReleaseId {
    if ([string]::IsNullOrWhiteSpace($ReleaseId)) {
        throw 'ReleaseId is required for this action.'
    }
}

function Assert-Directory([string] $Path, [string] $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label directory not found: $Path"
    }
}

function Assert-LocalTestPath([string] $Path, [string] $Label) {
    if (-not $LocalTestMode) { return }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $full.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "LocalTestMode $Label must be below the system temporary directory."
    }
}

function Get-SourceProjects([string] $EnvironmentRoot) {
    $projects = Get-D365ProjectMap -SourceParent $SourceParent -EnvironmentRoot $EnvironmentRoot
    foreach ($entry in $projects.GetEnumerator()) {
        Assert-Directory -Path $entry.Value.SourceRoot -Label "Source $($entry.Key)"
    }
    return $projects
}

function Read-ReleaseManifest {
    Assert-ReleaseId
    $path = Join-Path $ReleaseRoot "$ReleaseId.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Release manifest not found: $path"
    }
    $snapshot = Read-D365StrictJsonSnapshot -Path $path -Label 'Release manifest'
    if ([string] $snapshot.Value.release_id -cne $ReleaseId) {
        throw 'Release ID does not match the release manifest.'
    }
    [pscustomobject]@{ Path = $path; Manifest = $snapshot.Value; Hash = $snapshot.Hash }
}

function Invoke-EnvironmentComparison {
    param(
        [Parameter(Mandatory = $true)][string] $Environment,
        [Parameter(Mandatory = $true)][string] $EnvironmentRoot,
        [Parameter(Mandatory = $true)][object] $Manifest
    )

    Assert-Directory -Path $EnvironmentRoot -Label $Environment
    $projects = Get-SourceProjects -EnvironmentRoot $EnvironmentRoot
    foreach ($project in $script:D365ProjectNames) {
        $entry = $projects[$project]
        Assert-Directory -Path $entry.DestinationRoot -Label "$Environment $project"
        $parameters = @{
            ProjectName = $project
            SourceRoot = $entry.SourceRoot
            DestinationRoot = $entry.DestinationRoot
            ExpectedGitSha = [string] $Manifest.projects.$project.git_sha
            LocalTestMode = $LocalTestMode
        }
        $changes = @(& (Join-Path $toolRoot 'compare_environment_code.ps1') @parameters)
        [pscustomobject]@{
            Environment = $Environment
            Project = $project
            New = @($changes | Where-Object Type -ceq 'New').Count
            Modified = @($changes | Where-Object Type -ceq 'Modified').Count
            Deleted = @($changes | Where-Object Type -ceq 'Deleted').Count
            Total = $changes.Count
        }
    }
}

function Invoke-DeployUAT {
    if ($automaticReleaseRequested) {
        $ReleaseId = Get-D365NextReleaseId -ReleaseRoot $ReleaseRoot -Now $WizardNow
    } else {
        Assert-ReleaseId
    }
    Assert-Directory -Path $UatRoot -Label 'UAT'
    Assert-LocalTestPath -Path $UatRoot -Label 'UAT root'
    Assert-LocalTestPath -Path $ReleaseRoot -Label 'release root'
    $projects = Get-SourceProjects -EnvironmentRoot $UatRoot
    Assert-D365CleanReleaseRepositories -Projects $projects

    Write-Output "แผน Deploy UAT สำหรับ release $ReleaseId"
    foreach ($project in $script:D365ProjectNames) {
        Write-Output "- ${project}: $($projects[$project].SourceRoot) -> $($projects[$project].DestinationRoot)"
    }
    if ($PlanOnly) {
        & (Join-Path $toolRoot 'new_release_manifest.ps1') -ReleaseId $ReleaseId -SourceParent $SourceParent -PlanOnly | Out-Null
        Write-Output 'PlanOnly: ยังไม่มีการสร้าง manifest หรือคัดลอกไฟล์'
        return
    }

    if (-not (Test-Path -LiteralPath $ReleaseRoot)) {
        New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null
    }
    if ($automaticReleaseRequested) {
        $automaticRelease = New-AutomaticReleaseManifest
        $ReleaseId = $automaticRelease.ReleaseId
        $manifestPath = $automaticRelease.ManifestPath
    } else {
        $manifestPath = Join-Path $ReleaseRoot "$ReleaseId.json"
        & (Join-Path $toolRoot 'new_release_manifest.ps1') -ReleaseId $ReleaseId -SourceParent $SourceParent -OutputPath $manifestPath | Out-Null
    }

    foreach ($project in $script:D365ProjectNames) {
        $entry = $projects[$project]
        & (Join-Path $toolRoot 'sync_to_server.ps1') -Environment UAT -ProjectName $project `
            -ReleaseId $ReleaseId -ManifestPath $manifestPath -SourceRoot $entry.SourceRoot `
            -DestinationRoot $entry.DestinationRoot -CompareOnly -LocalTestMode:$LocalTestMode
    }

    $expectedApproval = "APPROVE UAT $ReleaseId"
    $actualApproval = $ApprovalToken
    if ([string]::IsNullOrWhiteSpace($actualApproval)) {
        if ($interactiveMenu) {
            if (-not (Read-WizardConfirmation "ยืนยันอัปเดต UAT Release $ReleaseId หรือไม่?")) {
                Write-Output "ยกเลิกการอัปเดต UAT Release $ReleaseId"
                return
            }
            $actualApproval = $expectedApproval
        } else {
            $actualApproval = Read-Host "พิมพ์ $expectedApproval เพื่อยืนยัน"
        }
    }
    Assert-D365Approval -Expected $expectedApproval -Actual $actualApproval

    foreach ($project in $script:D365ProjectNames) {
        $entry = $projects[$project]
        & (Join-Path $toolRoot 'sync_to_server.ps1') -Environment UAT -ProjectName $project `
            -ReleaseId $ReleaseId -ManifestPath $manifestPath -SourceRoot $entry.SourceRoot `
            -DestinationRoot $entry.DestinationRoot -ApprovalToken $expectedApproval -LocalTestMode:$LocalTestMode
    }
    Write-Output "Deploy UAT release $ReleaseId สำเร็จ"
}

function Invoke-Compare {
    $release = Read-ReleaseManifest
    Assert-LocalTestPath -Path $UatRoot -Label 'UAT root'
    Assert-LocalTestPath -Path $ProductionRoot -Label 'Production root'
    Assert-LocalTestPath -Path $ReleaseRoot -Label 'release root'
    $uatMetadata = Get-D365ReleaseMetadata -EnvironmentRoot $UatRoot -Manifest $release.Manifest
    foreach ($value in $uatMetadata.Values) {
        if ([string] $value.environment -cne 'UAT') {
            throw "Release metadata environment mismatch: $($value.project)"
        }
    }
    Invoke-EnvironmentComparison -Environment 'UAT' -EnvironmentRoot $UatRoot -Manifest $release.Manifest
    Invoke-EnvironmentComparison -Environment 'PRODUCTION' -EnvironmentRoot $ProductionRoot -Manifest $release.Manifest
}

function Get-CurrentEnvironmentMetadata {
    param(
        [Parameter(Mandatory = $true)][string] $EnvironmentRoot,
        [Parameter(Mandatory = $true)][string] $ExpectedEnvironment
    )
    $result = [ordered]@{}
    foreach ($project in $script:D365ProjectNames) {
        $path = Join-Path $EnvironmentRoot "$project\.deployment\current-release.json"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Release metadata is missing for $ExpectedEnvironment $project"
        }
        $value = (Read-D365StrictJsonSnapshot -Path $path -Label "$ExpectedEnvironment metadata for $project").Value
        if ([string] $value.project -cne $project -or [string] $value.environment -cne $ExpectedEnvironment) {
            throw "Release metadata environment or project mismatch: $project"
        }
        if ([string] $value.git_sha -notmatch '^[0-9a-f]{40}$') {
            throw "Release metadata SHA is invalid: $project"
        }
        $result[$project] = $value
    }
    return $result
}

function Invoke-ProductionPostDeployChecks {
    param([Parameter(Mandatory = $true)][object] $Manifest)
    if (-not (Test-Path -LiteralPath $PhpPath -PathType Leaf)) {
        throw "PHP executable not found: $PhpPath"
    }
    foreach ($project in $script:D365ProjectNames) {
        $checkScript = Join-Path $ProductionRoot "$project\tools\check_config.php"
        if (-not (Test-Path -LiteralPath $checkScript -PathType Leaf)) {
            throw "Production config check script not found: $project"
        }
        $raw = (& $PhpPath $checkScript | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "Production config check failed: $project" }
        try { $config = $raw | ConvertFrom-Json } catch { throw "Production config check returned invalid JSON: $project" }
        if ([string] $config.status -cne 'OK' -or [string] $config.app_env -cne 'PRODUCTION' -or
            [string] $config.db_name -cne 'D365_finance_prod' -or
            [string] $config.app_release -cne [string] $Manifest.release_id) {
            throw "Production config guard result is invalid: $project"
        }
        $response = Invoke-WebRequest -Uri ([string] $config.app_base_url) -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 20
        if ([int] $response.StatusCode -lt 200 -or [int] $response.StatusCode -ge 400) {
            throw "Production HTTP smoke check failed: $project"
        }
    }
}

function Invoke-PromoteProduction {
    $release = Read-ReleaseManifest
    Assert-LocalTestPath -Path $UatRoot -Label 'UAT root'
    Assert-LocalTestPath -Path $ProductionRoot -Label 'Production root'
    Assert-LocalTestPath -Path $ReleaseRoot -Label 'release root'
    Assert-Directory -Path $UatRoot -Label 'UAT'
    Assert-Directory -Path $ProductionRoot -Label 'Production'

    $uatMetadata = Get-D365ReleaseMetadata -EnvironmentRoot $UatRoot -Manifest $release.Manifest
    foreach ($value in $uatMetadata.Values) {
        if ([string] $value.environment -cne 'UAT') { throw "UAT metadata environment mismatch: $($value.project)" }
    }
    $uatComparison = @(Invoke-EnvironmentComparison -Environment 'UAT' -EnvironmentRoot $UatRoot -Manifest $release.Manifest)
    if ((@($uatComparison | Measure-Object -Property Total -Sum).Sum) -ne 0) {
        throw 'UAT code drift detected. Production promotion requires UAT to match the attested Git release exactly.'
    }

    $productionMetadata = Get-CurrentEnvironmentMetadata -EnvironmentRoot $ProductionRoot -ExpectedEnvironment 'PRODUCTION'
    $sourceProjects = Get-SourceProjects -EnvironmentRoot $ProductionRoot
    $risks = [ordered]@{}
    foreach ($project in $script:D365ProjectNames) {
        $risks[$project] = Get-D365ReleaseRisk -RepositoryRoot $sourceProjects[$project].SourceRoot `
            -FromSha ([string] $productionMetadata[$project].git_sha) `
            -ToSha ([string] $release.Manifest.projects.$project.git_sha)
    }
    $operationalProjects = @($risks.Keys | Where-Object { @($risks[$_].OperationalPaths).Count -gt 0 })
    $migrationProjects = @($risks.Keys | Where-Object { @($risks[$_].MigrationPaths).Count -gt 0 })

    $productionComparison = @(Invoke-EnvironmentComparison -Environment 'PRODUCTION' -EnvironmentRoot $ProductionRoot -Manifest $release.Manifest)
    Write-Output "แผน Promote Production สำหรับ release $ReleaseId"
    foreach ($result in $productionComparison) { Write-Output $result }
    if ($operationalProjects.Count -gt 0) {
        Write-Output 'ตรวจพบไฟล์ที่มีผลต่อการตั้งค่าระบบ:'
        foreach ($project in $operationalProjects) {
            foreach ($path in $risks[$project].OperationalPaths) { Write-Output "- $project/$path" }
        }
    }
    if ($migrationProjects.Count -gt 0) {
        Write-Output 'ตรวจพบ Database migration:'
        foreach ($project in $migrationProjects) {
            foreach ($path in $risks[$project].MigrationPaths) { Write-Output "- $project/$path" }
        }
        Write-Output 'ต้องทำ checkpoint และ Restore rehearsal ให้ผ่านก่อน Apply Production'
    }
    if ($PlanOnly) {
        if ($operationalProjects.Count -gt 0 -and $migrationProjects.Count -eq 0) {
            Write-Output 'PlanOnly: พบไฟล์ Operational และหยุดก่อนการอนุมัติหรือคัดลอก Production'
        } elseif ($migrationProjects.Count -eq 0) {
            Write-Output 'PlanOnly: ผ่านด่าน UAT และเป็น code-only; ยังไม่มีการสร้าง receipt หรือคัดลอกไฟล์ Production'
        } else {
            Write-Output 'PlanOnly: พบ migration และหยุดก่อน checkpoint, restore, apply หรือคัดลอก Production'
        }
        return
    }

    if ($LocalTestMode) { Assert-LocalTestPath -Path $ApprovalAuditRoot -Label 'approval audit root' }

    if ([string]::IsNullOrWhiteSpace($UatApprovalPath)) {
        $expectedAcceptance = "APPROVE UAT RESULT $ReleaseId"
        $actualAcceptance = $UatAcceptanceToken
        if ([string]::IsNullOrWhiteSpace($actualAcceptance)) {
            if ($interactiveMenu) {
                if (-not (Read-WizardConfirmation "ยืนยันว่าทดสอบ UAT Release $ReleaseId ผ่านแล้วหรือไม่?")) {
                    Write-Output "ยกเลิกการนำ Release $ReleaseId ขึ้น Production"
                    return
                }
                $actualAcceptance = $expectedAcceptance
            } else {
                $actualAcceptance = Read-Host "พิมพ์ $expectedAcceptance หลังผู้ใช้รับรอง UAT"
            }
        }
        Assert-D365Approval -Expected $expectedAcceptance -Actual $actualAcceptance
        $UatApprovalPath = (& (Join-Path $toolRoot 'approve_uat_release.ps1') -ManifestPath $release.Path `
            -AuditRoot $ApprovalAuditRoot -ApprovalToken $expectedAcceptance -LocalTestMode:$LocalTestMode | Out-String).Trim()
        $ExpectedUatApprovalSha256 = (Get-FileHash -LiteralPath $UatApprovalPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } else {
        if (-not (Test-Path -LiteralPath $UatApprovalPath -PathType Leaf)) { throw 'UAT approval receipt not found.' }
        if ([string]::IsNullOrWhiteSpace($ExpectedUatApprovalSha256)) { throw 'Expected UAT approval receipt SHA-256 is required.' }
        $actualReceiptHash = (Get-FileHash -LiteralPath $UatApprovalPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualReceiptHash -cne $ExpectedUatApprovalSha256.ToLowerInvariant()) {
            throw 'UAT approval receipt SHA-256 does not match the exact expected hash.'
        }
    }

    if ($operationalProjects.Count -gt 0) {
        $expectedOperationalApproval = "APPROVE OPERATIONAL $ReleaseId"
        $actualOperationalApproval = $OperationalApprovalToken
        if ($interactiveMenu) {
            if (-not (Read-WizardConfirmation "ยืนยันดำเนินการไฟล์ตั้งค่าระบบสำหรับ Release $ReleaseId หรือไม่?")) {
                Write-Output "ยกเลิก Operational Release $ReleaseId ก่อนดำเนินการ Production"
                return
            }
            $actualOperationalApproval = $expectedOperationalApproval
        } elseif ([string]::IsNullOrWhiteSpace($actualOperationalApproval)) {
            $actualOperationalApproval = '<missing>'
        }
        Assert-D365Approval -Expected $expectedOperationalApproval -Actual $actualOperationalApproval
    }

    $expectedProductionApproval = "APPROVE PRODUCTION $ReleaseId"
    $actualProductionApproval = $ProductionApprovalToken
    if ([string]::IsNullOrWhiteSpace($actualProductionApproval)) {
        if ($interactiveMenu) {
            if (-not (Read-WizardConfirmation "ยืนยันนำ Release $ReleaseId ขึ้น Production หรือไม่?")) {
                Write-Output "ยกเลิกการนำ Release $ReleaseId ขึ้น Production"
                return
            }
            $actualProductionApproval = $expectedProductionApproval
        } else {
            $actualProductionApproval = Read-Host "พิมพ์ $expectedProductionApproval เพื่อยืนยัน"
        }
    }
    Assert-D365Approval -Expected $expectedProductionApproval -Actual $actualProductionApproval

    $migrationResult = $null
    if ($migrationProjects.Count -gt 0) {
        if ($null -eq $MigrationCommandAdapter) {
            if ($LocalTestMode) {
                throw 'LocalTestMode migration requires MigrationCommandAdapter and will not access real tasks or databases.'
            }
            $waitForManualRestore = {
                param([string] $RehearsalDatabase, [string] $SanitizedPath)
                [void] (Read-WizardAnswer 'กด Enter หลัง Import สำเร็จ')
            }.GetNewClosure()
            $MigrationCommandAdapter = New-D365ManualRestoreMigrationAdapter -Manifest $release.Manifest `
                -SourceProjects $sourceProjects -ProductionRoot $ProductionRoot `
                -BackupRoot $MigrationBackupRoot -PhpPath $PhpPath -AppliedBy $MigrationAppliedBy `
                -WaitForManualRestore $waitForManualRestore
        }
        $migrationApprovalProvider = $null
        $migrationDecisionProvider = $null
        if ([string]::IsNullOrWhiteSpace($MigrationApprovalToken)) {
            if ($interactiveMenu) {
                $migrationConfirmationReader = ${function:Read-WizardConfirmation}
                $migrationDecisionProvider = {
                    param([string] $ApprovedReleaseId)
                    & $migrationConfirmationReader "ยืนยันใช้ Migration กับ Production Release $ApprovedReleaseId หรือไม่?"
                }.GetNewClosure()
            } else {
                $migrationApprovalProvider = {
                    param([string] $ApprovedReleaseId)
                    Read-Host "พิมพ์ APPLY MIGRATION $ApprovedReleaseId หลัง Restore rehearsal ผ่าน"
                }
            }
        }
        $migrationArguments = @{
            ReleaseId=$ReleaseId; ManifestPath=$release.Path
            ProjectRoot=$sourceProjects.D365_Sharedpoint_csv_import.SourceRoot; BackupRoot=$MigrationBackupRoot
            TaskNames=$ProductionTaskNames; ApprovalToken=$MigrationApprovalToken
            CommandAdapter=$MigrationCommandAdapter
        }
        if ($null -ne $migrationApprovalProvider) { $migrationArguments.ApprovalProvider = $migrationApprovalProvider }
        if ($null -ne $migrationDecisionProvider) { $migrationArguments.ApprovalDecisionProvider = $migrationDecisionProvider }
        $migrationResult = Invoke-D365MigrationPromotion @migrationArguments
        if ($migrationResult.Cancelled -eq $true) {
            Write-Output 'ยกเลิก Migration และคืนสถานะ Production Task แล้ว'
            return
        }
    }

    foreach ($project in $script:D365ProjectNames) {
        $entry = $sourceProjects[$project]
        $validation = @{
            Environment = 'Production'; ProjectName = $project; ReleaseId = $ReleaseId
            ManifestPath = $release.Path; SourceRoot = $entry.SourceRoot; DestinationRoot = $entry.DestinationRoot
            UatApprovalPath = $UatApprovalPath; ApprovalAuditRoot = $ApprovalAuditRoot
            ExpectedUatApprovalSha256 = $ExpectedUatApprovalSha256; CompareOnly = $true
            LocalTestMode = $LocalTestMode; ProductionApprovalValidationOnly = $LocalTestMode
        }
        & (Join-Path $toolRoot 'sync_to_server.ps1') @validation | Out-Null
    }

    if ($LocalTestMode) {
        if ($null -ne $migrationResult) {
            Complete-D365MigrationPromotion -MigrationResult $migrationResult -CommandAdapter $MigrationCommandAdapter -ProductionDeployVerified | Out-Null
        }
        Write-Output 'LocalTestMode: Production gates passed; Production files were not changed.'
        return
    }
    foreach ($project in $script:D365ProjectNames) {
        $entry = $sourceProjects[$project]
        & (Join-Path $toolRoot 'sync_to_server.ps1') -Environment Production -ProjectName $project `
            -ReleaseId $ReleaseId -ManifestPath $release.Path -SourceRoot $entry.SourceRoot `
            -DestinationRoot $entry.DestinationRoot -UatApprovalPath $UatApprovalPath `
            -ApprovalAuditRoot $ApprovalAuditRoot -ExpectedUatApprovalSha256 $ExpectedUatApprovalSha256 `
            -ApprovalToken $expectedProductionApproval
    }
    Invoke-ProductionPostDeployChecks -Manifest $release.Manifest
    $postComparison = @(Invoke-EnvironmentComparison -Environment 'PRODUCTION' -EnvironmentRoot $ProductionRoot -Manifest $release.Manifest)
    if ((@($postComparison | Measure-Object -Property Total -Sum).Sum) -ne 0) {
        throw 'Production code differs from the attested Git release after deployment.'
    }
    if ($null -ne $migrationResult) {
        Complete-D365MigrationPromotion -MigrationResult $migrationResult -CommandAdapter $MigrationCommandAdapter -ProductionDeployVerified | Out-Null
    }
    [pscustomobject]@{ ReleaseId = $ReleaseId; Status = 'DEPLOYED'; PostDeployDifferenceCount = 0 }
}

if ($Action -ceq 'Menu') {
    Write-Output 'D365 Finance - เมนู Release/Deploy'
    Write-Output '1. อัปเดต UAT'
    Write-Output '2. นำ Release ที่ผ่าน UAT ขึ้น Production'
    Write-Output '3. ตรวจสอบสถานะและเปรียบเทียบอย่างเดียว'
    Write-Output '4. ออก'
    $selection = Read-WizardAnswer 'เลือกเมนู 1-4'
    $Action = switch ($selection) {
        '1' { $automaticReleaseRequested=$true; 'DeployUAT' }
        '2' { 'PromoteProduction' }
        '3' { 'Compare' }
        '4' { return }
        default { throw 'กรุณาเลือกเมนู 1-4 เท่านั้น' }
    }
    if ([string]::IsNullOrWhiteSpace($ReleaseId)) {
        if ($Action -ceq 'DeployUAT') {
            $ReleaseId = Get-D365NextReleaseId -ReleaseRoot $ReleaseRoot -Now $WizardNow
        } else {
            $ReleaseId = Get-D365CurrentUatReleaseId -UatRoot $UatRoot
        }
    }
}

switch ($Action) {
    'DeployUAT' { Invoke-DeployUAT }
    'Compare' { Invoke-Compare }
    'PromoteProduction' { Invoke-PromoteProduction }
}
