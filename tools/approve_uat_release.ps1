[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ManifestPath,
    [string]$AuditRoot='C:\xampp\backups\d365\release-approvals',
    [string]$OutputPath,
    [string]$ApprovalToken,
    [switch]$LocalTestMode
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'release_security.ps1')
if(-not(Test-Path -LiteralPath $ManifestPath -PathType Leaf)){throw "Release manifest not found: $ManifestPath"}
$auditRootFull=Get-D365FullPath $AuditRoot
if(-not(Test-Path -LiteralPath $auditRootFull -PathType Container)){throw 'Canonical approval audit root does not exist.'}
if($LocalTestMode){$temp=Get-D365FullPath([IO.Path]::GetTempPath());if(-not$auditRootFull.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'LocalTestMode audit root must be under system temp.'};$allowed=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')}
else{if($null-eq(Get-D365ApprovalRootKind $auditRootFull)){throw 'Approval AuditRoot is not an approved canonical local or UNC root.'};$allowed=@('S-1-5-18','S-1-5-32-544')}
Assert-D365NoReparse $auditRootFull;Assert-D365ProtectedAcl $auditRootFull $allowed -RequireProtected
$snapshot=Read-D365StrictJsonSnapshot $ManifestPath 'Release manifest';$manifest=$snapshot.Value;$releaseId=[string]$manifest.release_id
if($releaseId-notmatch'^[A-Za-z0-9._-]+$'){throw 'Release manifest has an invalid release ID.'}
$projects=Get-D365ManifestProjects $manifest
$expected="APPROVE UAT RESULT $releaseId";if([string]::IsNullOrWhiteSpace($ApprovalToken)){$ApprovalToken=Read-Host "Type $expected after UAT acceptance is complete"};if($ApprovalToken-cne$expected){throw 'UAT approval token did not match.'}
$expectedOutput=Join-Path $auditRootFull ("uat-approval-{0}-{1}.json" -f $releaseId,$snapshot.Hash)
if([string]::IsNullOrWhiteSpace($OutputPath)){$OutputPath=$expectedOutput}
$outputFull=Assert-D365DirectChild $OutputPath $auditRootFull;Assert-D365NoReparse $outputFull -AllowMissingLeaf
if(-not(Test-D365PathEqual $outputFull $expectedOutput)){throw 'Approval receipt OutputPath is not the canonical immutable audit filename.'}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$receipt=[ordered]@{status='APPROVED';release_id=$releaseId;manifest_sha256=$snapshot.Hash;projects=$projects;approved_at=(Get-Date).ToUniversalTime().ToString('o');approved_by=[Environment]::UserName;approved_by_sid=$sid}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($receipt|ConvertTo-Json -Depth 7))
try{$stream=[IO.FileStream]::new($outputFull,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}} catch [IO.IOException] {throw 'UAT approval receipt already exists or could not be created immutably.'}
Assert-D365ProtectedAcl $outputFull $allowed
Write-Output $outputFull
