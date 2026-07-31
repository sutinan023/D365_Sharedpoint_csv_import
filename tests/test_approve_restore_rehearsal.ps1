$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\approve_restore_rehearsal.ps1'
$scriptSource = Get-Content -Raw $scriptPath
if ($scriptSource -notmatch [regex]::Escape('C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe') -or $scriptSource -match '&\s+powershell\.exe') { throw 'ACL helper invocation is vulnerable to PATH hijacking.' }
$localAdminArgs = @{ LocalTestMode=$true; LocalTestActiveAdministrator=$true }
if ($scriptSource -notmatch 'WindowsPrincipal' -or $scriptSource -notmatch 'IsInRole' -or $scriptSource -notmatch 'WindowsBuiltInRole.*Administrator') { throw 'Restore approver does not require an active elevated Administrator token.' }
$root = Join-Path ([IO.Path]::GetTempPath()) ('approve-restore-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
function Hash([string] $p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Json([string] $p, $o) { [IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false))) }
function Assert-Fails([scriptblock] $a) { try { & $a; throw 'Expected failure' } catch { if ($_.Exception.Message -eq 'Expected failure') { throw } } }
try {
  $backup = Join-Path $root 'backup.sql'; $sanitized = Join-Path $root 'backup.sanitized.sql'; [IO.File]::WriteAllText($backup,'backup'); [IO.File]::WriteAllText($sanitized,'sanitized')
  $manifest = Join-Path $root 'backup.json'; Json $manifest ([ordered]@{database='D365_finance';release_id='r1';backup_file=$backup;sha256=(Hash $backup);size_bytes=(Get-Item $backup).Length})
  $audit = Join-Path $root 'audit.json'; Json $audit ([ordered]@{source_path=$backup;source_database='D365_finance';rehearsal_database='D365_finance_rehearsal_r1';source_sha256=(Hash $backup);sanitized_path=$sanitized;sanitized_sha256=(Hash $sanitized);sanitized_size_bytes=(Get-Item $sanitized).Length})
  $evidence = Join-Path $root 'evidence.json'; Json $evidence ([ordered]@{status='VERIFIED';release_id='r1';database='D365_finance';rehearsal_database='D365_finance_rehearsal_r1';backup_sha256=(Hash $backup);sanitized_sha256=(Hash $sanitized);row_counts=[ordered]@{import_files=1;payment_outbound=2;payment_mail_log=0;sharepoint_file_queue=3};views=[ordered]@{vw_import_report=[ordered]@{row_count=1;security_type='INVOKER'};v_tbpayin_from_payment_outbound=[ordered]@{row_count=2;security_type='INVOKER'}};live_schema_reference_count=0;verified_at='2026-08-01T00:00:00Z';verified_by='tester'})
  $out = Join-Path $root 'receipt.json'; & $scriptPath -BackupManifestPath $manifest -SanitizerAuditPath $audit -RestoreEvidencePath $evidence -OutputPath $out -ApprovalToken 'RESTORE TEST PASSED r1' @localAdminArgs | Out-Null
  $receipt = Get-Content -Raw $out | ConvertFrom-Json; if ($receipt.evidence_sha256 -cne (Hash $evidence) -or $receipt.views.vw_import_report.security_type -cne 'INVOKER' -or [string]::IsNullOrWhiteSpace($receipt.approved_by_sid)) { throw 'Success receipt did not bind durable evidence and approver SID.' }
  foreach ($case in @('backup','sanitized','evidence','count','count-string','count-float','extra-count','view','extra-view','security','live-ref','path','hash','duplicate-key')) {
    $caseOut = Join-Path $root ($case + '.receipt.json'); $caseManifest = Join-Path $root ($case + '.manifest.json'); $caseAudit = Join-Path $root ($case + '.audit.json'); $caseEvidence = Join-Path $root ($case + '.evidence.json'); Copy-Item $manifest $caseManifest; Copy-Item $audit $caseAudit; Copy-Item $evidence $caseEvidence
    switch ($case) { 'backup' { [IO.File]::AppendAllText($backup,'x') } 'sanitized' { [IO.File]::AppendAllText($sanitized,'x') } 'evidence' { [IO.File]::AppendAllText($caseEvidence,'x') } 'count' { $o=Get-Content -Raw $caseEvidence|ConvertFrom-Json; $o.row_counts.import_files=-1; Json $caseEvidence $o } 'count-string' { $raw=Get-Content -Raw $caseEvidence; [IO.File]::WriteAllText($caseEvidence,$raw.Replace('"import_files":  1','"import_files":  "1"')) } 'count-float' { $raw=Get-Content -Raw $caseEvidence; [IO.File]::WriteAllText($caseEvidence,$raw.Replace('"import_files":  1','"import_files":  1.5')) } 'extra-count' { $o=Get-Content -Raw $caseEvidence|ConvertFrom-Json; $o.row_counts | Add-Member extra_table 4; Json $caseEvidence $o } 'view' { $o=Get-Content -Raw $caseEvidence|ConvertFrom-Json; $o.views.vw_import_report=$null; Json $caseEvidence $o } 'extra-view' { $o=Get-Content -Raw $caseEvidence|ConvertFrom-Json; $o.views | Add-Member extra_view ([pscustomobject]@{row_count=0;security_type='INVOKER'}); Json $caseEvidence $o } 'security' { $o=Get-Content -Raw $caseEvidence|ConvertFrom-Json; $o.views.vw_import_report.security_type='DEFINER'; Json $caseEvidence $o } 'live-ref' { $o=Get-Content -Raw $caseEvidence|ConvertFrom-Json; $o.live_schema_reference_count=1; Json $caseEvidence $o } 'path' { $o=Get-Content -Raw $caseAudit|ConvertFrom-Json; $o.sanitized_path=(Join-Path $root 'missing.sql'); Json $caseAudit $o } 'hash' { $o=Get-Content -Raw $caseAudit|ConvertFrom-Json; $o.sanitized_sha256=('0'*64); Json $caseAudit $o } 'duplicate-key' { $raw=Get-Content -Raw $caseEvidence; [IO.File]::WriteAllText($caseEvidence,$raw.Replace('"row_counts":  {','"row_counts":  {"import_files":99,')) } }
    Assert-Fails { & $scriptPath -BackupManifestPath $caseManifest -SanitizerAuditPath $caseAudit -RestoreEvidencePath $caseEvidence -OutputPath $caseOut -ApprovalToken 'RESTORE TEST PASSED r1' @localAdminArgs | Out-Null }; if (Test-Path $caseOut) { throw "Failure case wrote output: $case" }; if ($case -eq 'backup') { [IO.File]::WriteAllText($backup,'backup') }; if ($case -eq 'sanitized') { [IO.File]::WriteAllText($sanitized,'sanitized') }
  }
  foreach ($auditCase in @('missing','mismatch')) {
    $badAudit = Join-Path $root ("audit-$auditCase.json"); $badOutput = Join-Path $root ("audit-$auditCase.receipt.json"); $o = Get-Content -Raw $audit | ConvertFrom-Json
    if ($auditCase -eq 'missing') { $o.PSObject.Properties.Remove('rehearsal_database') } else { $o.rehearsal_database = 'D365_finance_prod_rehearsal_r1' }; Json $badAudit $o
    Assert-Fails { & $scriptPath -BackupManifestPath $manifest -SanitizerAuditPath $badAudit -RestoreEvidencePath $evidence -OutputPath $badOutput -ApprovalToken 'RESTORE TEST PASSED r1' @localAdminArgs | Out-Null }
    if (Test-Path $badOutput) { throw "Invalid sanitizer rehearsal wrote output: $auditCase" }
  }
  $existing = Join-Path $root 'existing.receipt.json'; [IO.File]::WriteAllText($existing,'sentinel')
  Assert-Fails { & $scriptPath -BackupManifestPath $manifest -SanitizerAuditPath $audit -RestoreEvidencePath $evidence -OutputPath $existing -ApprovalToken 'RESTORE TEST PASSED r1' @localAdminArgs | Out-Null }
  if ([IO.File]::ReadAllText($existing) -cne 'sentinel') { throw 'Existing receipt was overwritten.' }
  $outside = Join-Path ([IO.Path]::GetTempPath()) ('outside-' + [guid]::NewGuid() + '.json'); Copy-Item $evidence $outside
  Assert-Fails { & $scriptPath -BackupManifestPath $manifest -SanitizerAuditPath $audit -RestoreEvidencePath $outside -OutputPath (Join-Path $root 'outside.receipt.json') -ApprovalToken 'RESTORE TEST PASSED r1' @localAdminArgs | Out-Null }
  Remove-Item -LiteralPath $outside -Force
  $reparseTarget = Join-Path ([IO.Path]::GetTempPath()) ('restore-reparse-target-' + [guid]::NewGuid()); New-Item -ItemType Directory -Path $reparseTarget | Out-Null
  $reparseEvidence = Join-Path $reparseTarget 'evidence.json'; Copy-Item $evidence $reparseEvidence; $junction = Join-Path $root 'evidence-junction'; $junctionCreated = $false
  try { New-Item -ItemType Junction -Path $junction -Target $reparseTarget | Out-Null; $junctionCreated = $true } catch { Write-Host 'Junction creation unavailable; reparse rejection remains implemented.' }
  if ($junctionCreated) { Assert-Fails { & $scriptPath -BackupManifestPath $manifest -SanitizerAuditPath $audit -RestoreEvidencePath (Join-Path $junction 'evidence.json') -OutputPath (Join-Path $root 'reparse.receipt.json') -ApprovalToken 'RESTORE TEST PASSED r1' @localAdminArgs | Out-Null }; [IO.Directory]::Delete($junction) }
  Remove-Item -LiteralPath $reparseTarget -Recurse -Force
} finally { if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
Write-Host 'Restore approval evidence checks passed.'
