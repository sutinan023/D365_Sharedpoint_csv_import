param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('UAT', 'Production')]
    [string] $Environment,

    [ValidateSet('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')]
    [string] $ProjectName = 'D365_Sharedpoint_csv_import',

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ReleaseId,

    [Parameter(Mandatory = $true)]
    [string] $ManifestPath,

    [string] $SourceRoot,
    [string] $DestinationRoot,
    [string] $UatApprovalPath,
    [string] $ApprovalToken,
    [switch] $LocalTestMode,
    [switch] $CompareOnly,

    [string[]] $Exclude = @(
        '.git', '.agents', '.worktrees', 'vendor', '.env', 'config\.env',
        '*.log', '*.tmp', 'download', 'archive', 'processed', 'error', 'temp', 'logs',
        '.deploy-backups', '.deployment'
    )
)

$ErrorActionPreference = 'Stop'

function Get-NormalizedFullPath([string] $Path) {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-ExcludedPath {
    param([string] $RelativePath, [string[]] $Patterns)
    $normalizedPath = $RelativePath.Replace('/', '\').TrimStart('\')
    $pathParts = $normalizedPath -split '\\'
    $leafName = $pathParts[-1]
    foreach ($pattern in $Patterns) {
        $normalizedPattern = $pattern.Replace('/', '\').Trim('\')
        if ([string]::IsNullOrWhiteSpace($normalizedPattern)) { continue }
        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($normalizedPattern)) {
            if ($normalizedPath -like $normalizedPattern -or $leafName -like $normalizedPattern) { return $true }
        } elseif ($normalizedPattern.Contains('\')) {
            if ($normalizedPath -ieq $normalizedPattern -or $normalizedPath -ilike "$normalizedPattern\*") { return $true }
        } elseif ($pathParts -icontains $normalizedPattern) {
            return $true
        }
    }
    return $false
}

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path -Parent $PSScriptRoot
}
$source = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\', '/')

$expectedDestination = if ($Environment -eq 'UAT') {
    "\\100.1.1.166\htdocs\uat\$ProjectName"
} else {
    "\\100.1.1.166\htdocs\prod\$ProjectName"
}
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    $DestinationRoot = $expectedDestination
}

if ($LocalTestMode) {
    if ($Environment -ne 'UAT') {
        throw 'LocalTestMode is allowed only for UAT.'
    }
    $tempRoot = Get-NormalizedFullPath ([System.IO.Path]::GetTempPath())
    $candidate = Get-NormalizedFullPath $DestinationRoot
    if (-not $candidate.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'LocalTestMode destination must be below the system temporary directory.'
    }
} elseif ($DestinationRoot.TrimEnd('\') -cne $expectedDestination.TrimEnd('\')) {
    throw "Deployment destination must be exactly $expectedDestination"
}

if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
    throw "Destination directory not found: $DestinationRoot"
}
$destination = (Resolve-Path -LiteralPath $DestinationRoot).Path.TrimEnd('\', '/')

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Release manifest not found: $ManifestPath"
}
$manifestHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($manifest.release_id -cne $ReleaseId) {
    throw 'Release ID does not match the release manifest.'
}
$manifestProject = $manifest.projects.$ProjectName
if ($null -eq $manifestProject -or $manifestProject.git_sha -notmatch '^[0-9a-f]{40}$') {
    throw "Release manifest does not contain a valid Git SHA for $ProjectName."
}
$head = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne $manifestProject.git_sha) {
    throw 'Source Git SHA does not match the release manifest.'
}
$dirty = (& git -C $source status --porcelain --untracked-files=all | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $dirty -ne '') {
    throw 'Source repository must be clean before compare or deployment.'
}

if ($Environment -eq 'Production') {
    if (-not (Test-Path -LiteralPath $UatApprovalPath -PathType Leaf)) {
        throw 'Production deployment requires a UAT approval receipt.'
    }
    $approval = Get-Content -LiteralPath $UatApprovalPath -Raw | ConvertFrom-Json
    if (($approval.status -cne 'APPROVED') -or ($approval.release_id -cne $ReleaseId) -or ($approval.manifest_sha256 -cne $manifestHash)) {
        throw 'UAT approval receipt does not match this immutable release manifest.'
    }
}

$sourceFiles = @{}
foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
    $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
    if (-not (Test-ExcludedPath $relative $Exclude)) {
        $sourceFiles[$relative.ToLowerInvariant()] = $file
    }
}

$changes = [Collections.Generic.List[object]]::new()
foreach ($entry in $sourceFiles.GetEnumerator()) {
    $sourceFile = $entry.Value
    $relative = $sourceFile.FullName.Substring($source.Length).TrimStart('\', '/')
    $target = Join-Path $destination $relative
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        $changes.Add([pscustomobject]@{ Type='New'; RelativePath=$relative; SourcePath=$sourceFile.FullName; DestinationPath=$target })
    } elseif ((Get-FileHash $sourceFile.FullName -Algorithm SHA256).Hash -cne (Get-FileHash $target -Algorithm SHA256).Hash) {
        $changes.Add([pscustomobject]@{ Type='Modified'; RelativePath=$relative; SourcePath=$sourceFile.FullName; DestinationPath=$target })
    }
}
foreach ($file in Get-ChildItem -LiteralPath $destination -File -Recurse -Force) {
    $relative = $file.FullName.Substring($destination.Length).TrimStart('\', '/')
    if (-not (Test-ExcludedPath $relative $Exclude) -and -not $sourceFiles.ContainsKey($relative.ToLowerInvariant())) {
        $changes.Add([pscustomobject]@{ Type='Deleted'; RelativePath=$relative; SourcePath=$null; DestinationPath=$file.FullName })
    }
}

foreach ($change in $changes | Sort-Object Type, RelativePath) {
    Write-Output ('{0}: {1}' -f $change.Type, $change.RelativePath)
}
if ($CompareOnly -or $changes.Count -eq 0) { return }

$label = if ($Environment -eq 'UAT') { 'UAT' } else { 'PRODUCTION' }
$expectedToken = "APPROVE $label $ReleaseId"
if ([string]::IsNullOrWhiteSpace($ApprovalToken)) {
    $ApprovalToken = Read-Host "Type $expectedToken to deploy"
}
if ($ApprovalToken -cne $expectedToken) {
    throw 'Deployment approval token did not match.'
}

$attemptId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path (Split-Path -Parent $destination) ".deploy-backups\$ProjectName\$ReleaseId\$attemptId"
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "d365-deploy-stage-$attemptId"
$createdPaths = [Collections.Generic.List[string]]::new()
$metadataPath = Join-Path $destination '.deployment\current-release.json'

try {
    New-Item -ItemType Directory -Path $stageRoot, $backupRoot -Force | Out-Null
    foreach ($change in $changes | Where-Object Type -ne 'Deleted') {
        $stagePath = Join-Path $stageRoot $change.RelativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $stagePath) -Force | Out-Null
        Copy-Item -LiteralPath $change.SourcePath -Destination $stagePath
        if ((Get-FileHash $change.SourcePath -Algorithm SHA256).Hash -cne (Get-FileHash $stagePath -Algorithm SHA256).Hash) {
            throw "Staging checksum failed: $($change.RelativePath)"
        }
    }

    foreach ($change in $changes) {
        if (Test-Path -LiteralPath $change.DestinationPath -PathType Leaf) {
            $backupPath = Join-Path $backupRoot $change.RelativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
            Copy-Item -LiteralPath $change.DestinationPath -Destination $backupPath
        } else {
            $createdPaths.Add($change.DestinationPath)
        }
    }
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        $metadataBackup = Join-Path $backupRoot '.deployment\current-release.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $metadataBackup) -Force | Out-Null
        Copy-Item -LiteralPath $metadataPath -Destination $metadataBackup
    } else {
        $createdPaths.Add($metadataPath)
    }

    foreach ($change in $changes) {
        if ($change.Type -eq 'Deleted') {
            Remove-Item -LiteralPath $change.DestinationPath -Force
        } else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $change.DestinationPath) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $stageRoot $change.RelativePath) -Destination $change.DestinationPath -Force
        }
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $metadataPath) -Force | Out-Null
    [pscustomobject]@{
        release_id = $ReleaseId
        manifest_sha256 = $manifestHash
        git_sha = $head
        environment = $label
        project = $ProjectName
        deployed_at = (Get-Date).ToString('o')
        deployed_by = [Environment]::UserName
        backup_directory = $backupRoot
    } | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8
} catch {
    foreach ($path in $createdPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    foreach ($backupFile in Get-ChildItem -LiteralPath $backupRoot -File -Recurse -Force -ErrorAction SilentlyContinue) {
        $relative = $backupFile.FullName.Substring($backupRoot.Length).TrimStart('\', '/')
        $target = Join-Path $destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $backupFile.FullName -Destination $target -Force
    }
    throw
} finally {
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
}

Write-Output ('Deployed release {0} to {1}.' -f $ReleaseId, $destination)
