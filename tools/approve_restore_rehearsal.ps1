param(
    [Parameter(Mandatory = $true)]
    [string] $BackupManifestPath,
    [string] $OutputPath,
    [string] $ApprovalToken
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $BackupManifestPath -PathType Leaf)) {
    throw "Backup manifest not found: $BackupManifestPath"
}
$manifest = Get-Content -LiteralPath $BackupManifestPath -Raw | ConvertFrom-Json
$backupFile = [string]$manifest.backup_file
if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) {
    throw 'The backup file referenced by the manifest does not exist.'
}
$actualHash = (Get-FileHash -LiteralPath $backupFile -Algorithm SHA256).Hash
if ($actualHash -cne $manifest.sha256) {
    throw 'Backup checksum does not match its manifest.'
}
$expected = "RESTORE TEST PASSED $($manifest.release_id)"
if ([string]::IsNullOrWhiteSpace($ApprovalToken)) {
    $ApprovalToken = Read-Host "Type $expected only after a successful restore rehearsal"
}
if ($ApprovalToken -cne $expected) {
    throw 'Restore rehearsal approval token did not match.'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = "$backupFile.restore-approved.json"
}
[ordered]@{
    status = 'PASSED'
    release_id = $manifest.release_id
    database = $manifest.database
    backup_sha256 = $actualHash
    approved_at = (Get-Date).ToString('o')
    approved_by = [Environment]::UserName
} | ConvertTo-Json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output $OutputPath
