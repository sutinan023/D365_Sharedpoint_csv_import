param(
    [Parameter(Mandatory = $true)] [string] $BackupManifestPath,
    [Parameter(Mandatory = $true)] [string] $SanitizerAuditPath,
    [Parameter(Mandatory = $true)] [string] $RestoreEvidencePath,
    [Parameter(Mandatory = $true)] [string] $OutputPath,
    [string] $ApprovalToken
)

$ErrorActionPreference = 'Stop'
$requiredCounts = @('import_files', 'payment_outbound', 'payment_mail_log', 'sharepoint_file_queue')
$requiredViews = @('vw_import_report', 'v_tbpayin_from_payment_outbound')
function Read-Object([string] $Path, [string] $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label not found." }
    try { $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { throw "$Label is not valid JSON." }
    if ($null -eq $value) { throw "$Label is not a JSON object." }; return $value
}
function Need($Object, [string] $Name, [string] $Label) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { throw "$Label is missing $Name." }
    return $property.Value
}
function Hex([string] $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Full([string] $Path) { [IO.Path]::GetFullPath($Path) }
function Assert-HashAndSize([string] $Path, [string] $Hash, $Size, [string] $Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label file does not exist." }
    if ($Hash -notmatch '^[a-fA-F0-9]{64}$' -or (Hex $Path) -cne $Hash.ToLowerInvariant()) { throw "$Label checksum does not match." }
    if ($Size -isnot [int64] -and $Size -isnot [int] -and $Size -isnot [double]) { throw "$Label size is invalid." }
    if ((Get-Item -LiteralPath $Path).Length -ne [int64]$Size) { throw "$Label size does not match." }
}
function Assert-NonNegativeInteger($Value, [string] $Label) {
    if ($Value -isnot [int64] -and $Value -isnot [int]) { throw "$Label must be a nonnegative integer." }
    if ([int64]$Value -lt 0) { throw "$Label must be a nonnegative integer." }
}

$manifestPath = Full $BackupManifestPath; $auditPath = Full $SanitizerAuditPath; $evidencePath = Full $RestoreEvidencePath; $outputFullPath = Full $OutputPath
if (Test-Path -LiteralPath $outputFullPath) { throw 'Restore receipt output already exists and is immutable.' }
$manifest = Read-Object $manifestPath 'Backup manifest'
$releaseId = [string](Need $manifest 'release_id' 'Backup manifest'); $database = [string](Need $manifest 'database' 'Backup manifest')
if ([string]::IsNullOrWhiteSpace($releaseId) -or [string]::IsNullOrWhiteSpace($database)) { throw 'Backup manifest release or database is invalid.' }
$backupPath = Full ([string](Need $manifest 'backup_file' 'Backup manifest')); $backupHash = [string](Need $manifest 'sha256' 'Backup manifest'); $backupSize = Need $manifest 'size_bytes' 'Backup manifest'
Assert-HashAndSize $backupPath $backupHash $backupSize 'Backup'
$audit = Read-Object $auditPath 'Sanitizer audit'
if (([string](Need $audit 'source_database' 'Sanitizer audit')) -cne $database -or ([string](Need $audit 'source_sha256' 'Sanitizer audit')).ToLowerInvariant() -cne $backupHash.ToLowerInvariant()) { throw 'Sanitizer audit does not bind to the backup manifest.' }
$sanitizedPath = Full ([string](Need $audit 'sanitized_path' 'Sanitizer audit')); $sanitizedHash = [string](Need $audit 'sanitized_sha256' 'Sanitizer audit'); $sanitizedSize = Need $audit 'sanitized_size_bytes' 'Sanitizer audit'
Assert-HashAndSize $sanitizedPath $sanitizedHash $sanitizedSize 'Sanitized backup'
$evidence = Read-Object $evidencePath 'Restore evidence'
if (([string](Need $evidence 'status' 'Restore evidence')) -cne 'VERIFIED' -or ([string](Need $evidence 'release_id' 'Restore evidence')) -cne $releaseId -or ([string](Need $evidence 'database' 'Restore evidence')) -cne $database) { throw 'Restore evidence status, release, or database does not match.' }
$rehearsal = [string](Need $evidence 'rehearsal_database' 'Restore evidence')
if ($rehearsal -notmatch '^[A-Za-z0-9_]+$' -or $rehearsal -ieq $database -or $rehearsal -notmatch '(?i)rehearsal') { throw 'Restore evidence rehearsal database is unsafe.' }
if (([string](Need $evidence 'backup_sha256' 'Restore evidence')).ToLowerInvariant() -cne $backupHash.ToLowerInvariant() -or ([string](Need $evidence 'sanitized_sha256' 'Restore evidence')).ToLowerInvariant() -cne $sanitizedHash.ToLowerInvariant()) { throw 'Restore evidence hashes do not match verified artifacts.' }
foreach ($name in $requiredCounts) { Assert-NonNegativeInteger (Need (Need $evidence 'row_counts' 'Restore evidence') $name 'Restore evidence row_counts') "Restore evidence row_counts.$name" }
foreach ($name in $requiredViews) { $view = Need (Need $evidence 'views' 'Restore evidence') $name 'Restore evidence views'; Assert-NonNegativeInteger (Need $view 'row_count' "Restore evidence views.$name") "Restore evidence views.$name.row_count"; if (([string](Need $view 'security_type' "Restore evidence views.$name")) -cne 'INVOKER') { throw "Restore evidence view $name must use INVOKER security." } }
if ((Need $evidence 'live_schema_reference_count' 'Restore evidence') -ne 0) { throw 'Restore evidence has live schema references.' }
if ([string]::IsNullOrWhiteSpace([string](Need $evidence 'verified_at' 'Restore evidence')) -or [string]::IsNullOrWhiteSpace([string](Need $evidence 'verified_by' 'Restore evidence'))) { throw 'Restore evidence verification metadata is incomplete.' }
$expected = "RESTORE TEST PASSED $releaseId"; if ([string]::IsNullOrWhiteSpace($ApprovalToken)) { $ApprovalToken = Read-Host "Type $expected only after a successful restore rehearsal" }; if ($ApprovalToken -cne $expected) { throw 'Restore rehearsal approval token did not match.' }
$receipt = [ordered]@{ status='PASSED'; release_id=$releaseId; database=$database; rehearsal_database=$rehearsal; backup_path=$backupPath; backup_sha256=$backupHash.ToLowerInvariant(); backup_size_bytes=[int64]$backupSize; sanitized_path=$sanitizedPath; sanitized_sha256=$sanitizedHash.ToLowerInvariant(); sanitized_size_bytes=[int64]$sanitizedSize; evidence_path=$evidencePath; evidence_sha256=(Hex $evidencePath); evidence_size_bytes=(Get-Item -LiteralPath $evidencePath).Length; row_counts=$evidence.row_counts; views=$evidence.views; live_schema_reference_count=0; approved_at=(Get-Date).ToUniversalTime().ToString('o'); approved_by=[Environment]::UserName }
[IO.File]::WriteAllText($outputFullPath, ($receipt | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Output $outputFullPath
