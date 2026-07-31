param(
    [Parameter(Mandatory = $true)]
    [string] $ManifestPath,
    [string] $OutputPath,
    [string] $ApprovalToken
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Release manifest not found: $ManifestPath"
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$releaseId = [string]$manifest.release_id
if ($releaseId -notmatch '^[A-Za-z0-9._-]+$') {
    throw 'Release manifest has an invalid release ID.'
}
$expected = "APPROVE UAT RESULT $releaseId"
if ([string]::IsNullOrWhiteSpace($ApprovalToken)) {
    $ApprovalToken = Read-Host "Type $expected after UAT acceptance is complete"
}
if ($ApprovalToken -cne $expected) {
    throw 'UAT approval token did not match.'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = "$ManifestPath.uat-approved.json"
}
[ordered]@{
    status = 'APPROVED'
    release_id = $releaseId
    manifest_sha256 = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
    approved_at = (Get-Date).ToString('o')
    approved_by = [Environment]::UserName
} | ConvertTo-Json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output $OutputPath
