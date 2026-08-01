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
    [switch] $PlanOnly,
    [switch] $LocalTestMode
)

$ErrorActionPreference = 'Stop'
$toolRoot = Join-Path $PSScriptRoot 'tools'
. (Join-Path $toolRoot 'release_common.ps1')

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
    Assert-ReleaseId
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
    $manifestPath = Join-Path $ReleaseRoot "$ReleaseId.json"
    & (Join-Path $toolRoot 'new_release_manifest.ps1') -ReleaseId $ReleaseId -SourceParent $SourceParent -OutputPath $manifestPath | Out-Null

    foreach ($project in $script:D365ProjectNames) {
        $entry = $projects[$project]
        & (Join-Path $toolRoot 'sync_to_server.ps1') -Environment UAT -ProjectName $project `
            -ReleaseId $ReleaseId -ManifestPath $manifestPath -SourceRoot $entry.SourceRoot `
            -DestinationRoot $entry.DestinationRoot -CompareOnly -LocalTestMode:$LocalTestMode
    }

    $expectedApproval = "APPROVE UAT $ReleaseId"
    $actualApproval = $ApprovalToken
    if ([string]::IsNullOrWhiteSpace($actualApproval)) {
        $actualApproval = Read-Host "พิมพ์ $expectedApproval เพื่อยืนยัน"
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

if ($Action -ceq 'Menu') {
    Write-Host 'D365 Finance - เมนู Release/Deploy'
    Write-Host '1. สร้าง Release และ Deploy ไป UAT'
    Write-Host '2. เปรียบเทียบโค้ด UAT กับ Production'
    Write-Host '3. Promote Release เดิมไป Production'
    Write-Host '4. ออก'
    $selection = Read-Host 'เลือกเมนู 1-4'
    $Action = switch ($selection) {
        '1' { 'DeployUAT' }
        '2' { 'Compare' }
        '3' { 'PromoteProduction' }
        '4' { return }
        default { throw 'กรุณาเลือกเมนู 1-4 เท่านั้น' }
    }
    if ([string]::IsNullOrWhiteSpace($ReleaseId)) {
        $ReleaseId = Read-Host 'ระบุ Release ID'
        if ($ReleaseId -notmatch '^[A-Za-z0-9._-]+$') { throw 'ReleaseId has an invalid format.' }
    }
}

switch ($Action) {
    'DeployUAT' { Invoke-DeployUAT }
    'Compare' { Invoke-Compare }
    'PromoteProduction' { throw 'Production promotion is not implemented yet.' }
}
