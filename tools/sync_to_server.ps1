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
    [string] $ApprovalAuditRoot = 'C:\xampp\backups\d365\release-approvals',
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedUatApprovalSha256,
    [string] $ApprovalToken,
    [switch] $LocalTestMode,
    [switch] $ProductionApprovalValidationOnly,
    [switch] $CompareOnly,

    [string[]] $Exclude = @(
        '.git', '.agents', '.worktrees', 'vendor', '.env', 'config\.env',
        '*.log', '*.tmp', 'download', 'archive', 'processed', 'error', 'temp', 'tmp', 'logs',
        '.deploy-backups', '.deployment'
    )
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_security.ps1')

function Assert-AttestedRepositoryState([string]$Root,[string]$ExpectedHead) {
    $current=(& git -C $Root rev-parse HEAD).Trim();if($LASTEXITCODE-ne0-or$current-cne$ExpectedHead){throw 'Source Git HEAD changed after attestation.'}
    $state=(& git -C $Root status --porcelain --untracked-files=all|Out-String).Trim();if($LASTEXITCODE-ne0-or$state-ne''){throw 'Source repository changed after attestation and is no longer clean.'}
}
function Invoke-GitBytes([string]$Root,[string]$Arguments) {
    $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName='git.exe';$start.WorkingDirectory=$Root;$start.Arguments=$Arguments;$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.CreateNoWindow=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$start;[void]$process.Start();$memory=New-Object IO.MemoryStream;try{$process.StandardOutput.BaseStream.CopyTo($memory);$errorText=$process.StandardError.ReadToEnd();$process.WaitForExit();if($process.ExitCode-ne0){throw "Git snapshot command failed: $errorText"};$memory.ToArray()}finally{$memory.Dispose();$process.Dispose()}
}
function Export-GitBlob([string]$Root,[string]$ObjectId,[string]$Path) {
    $bytes=Invoke-GitBytes $Root "cat-file blob $ObjectId";$parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null};$stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}

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

$mandatoryExclude = @('*.csv')
$effectiveExclude = @($Exclude) + $mandatoryExclude

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path -Parent $PSScriptRoot
}
$source = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath.TrimEnd('\', '/')

$expectedDestination = if ($Environment -eq 'UAT') {
    "\\100.1.1.166\htdocs\uat\$ProjectName"
} else {
    "\\100.1.1.166\htdocs\prod\$ProjectName"
}
if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    $DestinationRoot = $expectedDestination
}

if ($LocalTestMode) {
    if ($Environment -ne 'UAT' -and -not ($Environment -eq 'Production' -and $ProductionApprovalValidationOnly)) {
        throw 'LocalTestMode is allowed only for UAT or Production approval validation.'
    }
    $tempRoot = Get-NormalizedFullPath ([System.IO.Path]::GetTempPath())
    $candidate = Get-NormalizedFullPath $DestinationRoot
    if (-not $candidate.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'LocalTestMode destination must be below the system temporary directory.'
    }
} elseif ($ProductionApprovalValidationOnly) {
    throw 'ProductionApprovalValidationOnly is available only in LocalTestMode.'
} elseif ($DestinationRoot.TrimEnd('\') -cne $expectedDestination.TrimEnd('\')) {
    throw "Deployment destination must be exactly $expectedDestination"
}

if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
    throw "Destination directory not found: $DestinationRoot"
}
$destination = (Resolve-Path -LiteralPath $DestinationRoot).ProviderPath.TrimEnd('\', '/')

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Release manifest not found: $ManifestPath"
}
$manifestSnapshot = Read-D365StrictJsonSnapshot $ManifestPath 'Release manifest'
$manifestHash = $manifestSnapshot.Hash
$manifest = $manifestSnapshot.Value
if ($manifest.release_id -cne $ReleaseId) {
    throw 'Release ID does not match the release manifest.'
}
$manifestProjects = Get-D365ManifestProjects $manifest
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
    if ([string]::IsNullOrWhiteSpace($ExpectedUatApprovalSha256)) { throw 'Production deployment requires the exact expected UAT approval receipt SHA-256.' }
    if (-not (Test-Path -LiteralPath $UatApprovalPath -PathType Leaf)) {
        throw 'Production deployment requires a UAT approval receipt.'
    }
    $approvalRootFull=Get-D365FullPath $ApprovalAuditRoot
    if($LocalTestMode){$temp=Get-D365FullPath([IO.Path]::GetTempPath());if(-not$approvalRootFull.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'LocalTestMode approval audit root must be under system temp.'};$allowedWriters=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')}
    else{if($null-eq(Get-D365ApprovalRootKind $approvalRootFull)){throw 'Approval audit root is not an approved canonical local or UNC root.'};$allowedWriters=@('S-1-5-18','S-1-5-32-544')}
    Assert-D365NoReparse $approvalRootFull;Assert-D365ProtectedAcl $approvalRootFull $allowedWriters -RequireProtected
    $approvalFull=Assert-D365DirectChild $UatApprovalPath $approvalRootFull;Assert-D365NoReparse $approvalFull
    $expectedApprovalLeaf="uat-approval-{0}-{1}.json" -f $ReleaseId,$manifestHash
    if((Split-Path -Leaf $approvalFull)-cne$expectedApprovalLeaf){throw 'UAT approval receipt is not at the canonical immutable audit path.'}
    Assert-D365ProtectedAcl $approvalFull $allowedWriters
    $approvalSnapshot=Read-D365StrictJsonSnapshot $approvalFull 'UAT approval receipt'
    if($approvalSnapshot.Hash-cne$ExpectedUatApprovalSha256.ToLowerInvariant()){throw 'UAT approval receipt SHA-256 does not match the exact expected hash.'}
    $approval = $approvalSnapshot.Value
    if (($approval.status -cne 'APPROVED') -or ($approval.release_id -cne $ReleaseId) -or ($approval.manifest_sha256 -cne $manifestHash)) {
        throw 'UAT approval receipt does not match this immutable release manifest.'
    }
    if([string]$approval.approved_by_sid-notmatch'^S-1-(?:[0-9]+-)+[0-9]+$'){throw 'UAT approval receipt does not contain a valid approver SID.'}
    $approvalProjectNames=@($approval.projects.PSObject.Properties.Name|Sort-Object);$manifestProjectNames=@($manifestProjects.Keys|Sort-Object)
    if(($approvalProjectNames-join"`n")-cne($manifestProjectNames-join"`n")){throw 'UAT approval receipt project set does not match the release manifest.'}
    foreach($project in $manifestProjectNames){if([string]$approval.projects.$project.git_sha-cne[string]$manifest.projects.$project.git_sha){throw "UAT approval receipt Git SHA does not match project $project."}}
    if($ProductionApprovalValidationOnly){Write-Output '{"status":"VALID"}';return}
}

$attemptId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N'))
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "d365-deploy-stage-$attemptId"
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
try {
$sourceFiles = @{}
$treeBytes=Invoke-GitBytes $source ("-c core.quotepath=false ls-tree -r -z {0}" -f $head)
$treeText=[Text.UTF8Encoding]::new($false,$true).GetString($treeBytes)
foreach($treeEntry in @($treeText.Split([char[]]@([char]0),[StringSplitOptions]::RemoveEmptyEntries))){
    if($treeEntry-notmatch'^\d+\s+blob\s+(?<sha>[0-9a-f]{40})\t(?<path>.+)$'){throw 'Unable to parse attested Git tree entry.'}
    $relative=$matches.path.Replace('/','\')
    if(-not(Test-ExcludedPath $relative $effectiveExclude)){$stagePath=Join-Path $stageRoot $relative;Export-GitBlob $source $matches.sha $stagePath;$sourceFiles[$relative.ToLowerInvariant()]=[pscustomobject]@{FullName=$stagePath;RelativePath=$relative}}
}
if($LocalTestMode-and-not[string]::IsNullOrWhiteSpace($env:D365_SYNC_TEST_MUTATE_SOURCE_AFTER_ATTESTATION)){[IO.File]::AppendAllText((Join-Path $source $env:D365_SYNC_TEST_MUTATE_SOURCE_AFTER_ATTESTATION),'# post-attestation mutation',[Text.UTF8Encoding]::new($false))}
if($LocalTestMode-and$env:D365_SYNC_TEST_MUTATE_MANIFEST_AFTER_ATTESTATION-ceq'1'){[IO.File]::AppendAllText($ManifestPath,"`n",[Text.UTF8Encoding]::new($false))}

$changes = [Collections.Generic.List[object]]::new()
foreach ($entry in $sourceFiles.GetEnumerator()) {
    $sourceFile = $entry.Value
    $relative = $sourceFile.RelativePath
    $target = Join-Path $destination $relative
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
        $changes.Add([pscustomobject]@{ Type='New'; RelativePath=$relative; SourcePath=$sourceFile.FullName; DestinationPath=$target })
    } elseif ((Get-FileHash $sourceFile.FullName -Algorithm SHA256).Hash -cne (Get-FileHash $target -Algorithm SHA256).Hash) {
        $changes.Add([pscustomobject]@{ Type='Modified'; RelativePath=$relative; SourcePath=$sourceFile.FullName; DestinationPath=$target })
    }
}
foreach ($file in Get-ChildItem -LiteralPath $destination -File -Recurse -Force) {
    $relative = $file.FullName.Substring($destination.Length).TrimStart('\', '/')
    if (-not (Test-ExcludedPath $relative $effectiveExclude) -and -not $sourceFiles.ContainsKey($relative.ToLowerInvariant())) {
        $changes.Add([pscustomobject]@{ Type='Deleted'; RelativePath=$relative; SourcePath=$null; DestinationPath=$file.FullName })
    }
}

foreach ($change in $changes | Sort-Object Type, RelativePath) {
    Write-Output ('{0}: {1}' -f $change.Type, $change.RelativePath)
}
if ($CompareOnly) { return }
if ($changes.Count -eq 0) {
    Write-Output 'No file changes; release metadata will be updated.'
}

$label = if ($Environment -eq 'UAT') { 'UAT' } else { 'PRODUCTION' }
$expectedToken = "APPROVE $label $ReleaseId"
if ([string]::IsNullOrWhiteSpace($ApprovalToken)) {
    $ApprovalToken = Read-Host "Type $expectedToken to deploy"
}
if ($ApprovalToken -cne $expectedToken) {
    throw 'Deployment approval token did not match.'
}

$currentManifestHash=Get-D365Sha256([IO.File]::ReadAllBytes($ManifestPath))
if($currentManifestHash-cne$manifestHash){throw 'Release manifest changed after attestation.'}
Assert-AttestedRepositoryState $source $head
$backupRoot = Join-Path (Split-Path -Parent $destination) ".deploy-backups\$ProjectName\$ReleaseId\$attemptId"
$createdPaths = [Collections.Generic.List[string]]::new()
$metadataPath = Join-Path $destination '.deployment\current-release.json'

try {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

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
}

Write-Output ('Deployed release {0} to {1}.' -f $ReleaseId, $destination)
} finally {
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
}
