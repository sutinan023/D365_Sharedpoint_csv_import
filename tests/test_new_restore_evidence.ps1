$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\new_restore_evidence.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('restore-evidence-{0}' -f [guid]::NewGuid())
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-Throws([scriptblock]$Action,[string]$Pattern){try{&$Action;throw'Expected failure.'}catch{if($_.Exception.Message-eq'Expected failure.'-or$_.Exception.Message-notmatch$Pattern){throw}}}
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $backup=Join-Path $root 'backup.sql';Set-Content $backup 'backup'
    $sanitized=Join-Path $root 'backup.sanitized.sql';Set-Content $sanitized 'sanitized'
    $manifest=Join-Path $root 'backup.sql.json';[ordered]@{release_id='r1';database='D365_finance_prod';backup_file=$backup;sha256=(Hash $backup);size_bytes=(Get-Item $backup).Length}|ConvertTo-Json|Set-Content $manifest
    $audit=Join-Path $root 'backup.sanitized.sql.audit.json';[ordered]@{source_path=$backup;source_database='D365_finance_prod';rehearsal_database='D365_finance_prod_rehearsal_r1';source_sha256=(Hash $backup);sanitized_path=$sanitized;sanitized_sha256=(Hash $sanitized);sanitized_size_bytes=(Get-Item $sanitized).Length}|ConvertTo-Json|Set-Content $audit
    $output=Join-Path $root 'restore-evidence.json'
    & $scriptPath -BackupManifestPath $manifest -SanitizerAuditPath $audit -OutputPath $output `
        -ImportFilesCount 1 -PaymentOutboundCount 2 -PaymentMailLogCount 3 -SharePointFileQueueCount 4 `
        -VwImportReportCount 5 -VTbPayinFromPaymentOutboundCount 6 -VwImportReportSecurityType INVOKER `
        -VTbPayinFromPaymentOutboundSecurityType INVOKER -LiveSchemaReferenceCount 0 -ApprovalToken 'CREATE RESTORE EVIDENCE r1' | Out-Null
    $value=Get-Content -Raw $output|ConvertFrom-Json
    if($value.status-cne'VERIFIED'-or$value.database-cne'D365_finance_prod'-or$value.live_schema_reference_count-ne0){throw'Restore evidence identity is wrong.'}
    if($value.row_counts.sharepoint_file_queue-ne4-or$value.views.vw_import_report.security_type-cne'INVOKER'){throw'Restore evidence counts/views are wrong.'}
    $common=@{BackupManifestPath=$manifest;SanitizerAuditPath=$audit;ImportFilesCount=1;PaymentOutboundCount=2;PaymentMailLogCount=3;SharePointFileQueueCount=4;VwImportReportCount=5;VTbPayinFromPaymentOutboundCount=6;VwImportReportSecurityType='INVOKER';VTbPayinFromPaymentOutboundSecurityType='INVOKER';LiveSchemaReferenceCount=0}
    Assert-Throws { & $scriptPath @common -OutputPath $output -ApprovalToken 'CREATE RESTORE EVIDENCE r1'|Out-Null } 'immutable|exists'
    Assert-Throws { & $scriptPath @common -OutputPath (Join-Path $root 'wrong.json') -ApprovalToken 'wrong'|Out-Null } 'approval'
} finally { if(Test-Path $root){Remove-Item -LiteralPath $root -Recurse -Force} }
Write-Host 'Restore evidence helper checks passed.'
