param(
    [Parameter(Mandatory=$true)][string]$BackupManifestPath,
    [Parameter(Mandatory=$true)][string]$SanitizerAuditPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][ValidateRange(0,[int]::MaxValue)][int]$ImportFilesCount,
    [Parameter(Mandatory=$true)][ValidateRange(0,[int]::MaxValue)][int]$PaymentOutboundCount,
    [Parameter(Mandatory=$true)][ValidateRange(0,[int]::MaxValue)][int]$PaymentMailLogCount,
    [Parameter(Mandatory=$true)][ValidateRange(0,[int]::MaxValue)][int]$SharePointFileQueueCount,
    [Parameter(Mandatory=$true)][ValidateRange(0,[int]::MaxValue)][int]$VwImportReportCount,
    [Parameter(Mandatory=$true)][ValidateRange(0,[int]::MaxValue)][int]$VTbPayinFromPaymentOutboundCount,
    [Parameter(Mandatory=$true)][ValidateSet('INVOKER')][string]$VwImportReportSecurityType,
    [Parameter(Mandatory=$true)][ValidateSet('INVOKER')][string]$VTbPayinFromPaymentOutboundSecurityType,
    [Parameter(Mandatory=$true)][ValidateRange(0,0)][int]$LiveSchemaReferenceCount,
    [string]$ApprovalToken
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'release_security.ps1')
foreach($path in @($BackupManifestPath,$SanitizerAuditPath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Required restore artifact not found: $path"}}
$manifest=(Read-D365StrictJsonSnapshot $BackupManifestPath 'Backup manifest').Value
$audit=(Read-D365StrictJsonSnapshot $SanitizerAuditPath 'Sanitizer audit').Value
$release=[string]$manifest.release_id;$database=[string]$manifest.database;$rehearsal=[string]$audit.rehearsal_database
if($release-notmatch'^[A-Za-z0-9._-]+$'){throw'Restore evidence release ID is invalid.'}
if($database-cne'D365_finance_prod'){throw'Restore evidence must be created from a Production checkpoint.'}
if($rehearsal-notmatch'^D365_finance_prod_rehearsal_[A-Za-z0-9_]+$'){throw'Rehearsal database name is invalid.'}
$backupFull=(Resolve-Path -LiteralPath ([string]$manifest.backup_file)).ProviderPath
$sanitizedFull=(Resolve-Path -LiteralPath ([string]$audit.sanitized_path)).ProviderPath
if((Get-FileHash -LiteralPath $backupFull -Algorithm SHA256).Hash.ToLowerInvariant()-cne([string]$manifest.sha256).ToLowerInvariant()){throw'Production checkpoint hash mismatch.'}
if((Get-FileHash -LiteralPath $sanitizedFull -Algorithm SHA256).Hash.ToLowerInvariant()-cne([string]$audit.sanitized_sha256).ToLowerInvariant()){throw'Sanitized backup hash mismatch.'}
$expected="CREATE RESTORE EVIDENCE $release";if([string]::IsNullOrWhiteSpace($ApprovalToken)){$ApprovalToken=Read-Host "Type $expected after checking the rehearsal database"};if($ApprovalToken-cne$expected){throw'Restore evidence approval token did not match.'}
if(Test-Path -LiteralPath $OutputPath){throw'Restore evidence already exists and is immutable.'}
$evidence=[ordered]@{
    status='VERIFIED';release_id=$release;database=$database;rehearsal_database=$rehearsal
    backup_sha256=([string]$manifest.sha256).ToLowerInvariant();sanitized_sha256=([string]$audit.sanitized_sha256).ToLowerInvariant()
    row_counts=[ordered]@{import_files=$ImportFilesCount;payment_outbound=$PaymentOutboundCount;payment_mail_log=$PaymentMailLogCount;sharepoint_file_queue=$SharePointFileQueueCount}
    views=[ordered]@{vw_import_report=[ordered]@{row_count=$VwImportReportCount;security_type=$VwImportReportSecurityType};v_tbpayin_from_payment_outbound=[ordered]@{row_count=$VTbPayinFromPaymentOutboundCount;security_type=$VTbPayinFromPaymentOutboundSecurityType}}
    live_schema_reference_count=$LiveSchemaReferenceCount;verified_at=(Get-Date).ToUniversalTime().ToString('o');verified_by=[Environment]::UserName
}
$parent=Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath));if(-not(Test-Path -LiteralPath $parent)){throw'Restore evidence output directory not found.'}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($evidence|ConvertTo-Json -Depth 7))
try {
    $stream=[IO.FileStream]::new($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
} catch [IO.IOException] {
    throw 'Restore evidence already exists or could not be created immutably.'
}
Write-Output ([IO.Path]::GetFullPath($OutputPath))
