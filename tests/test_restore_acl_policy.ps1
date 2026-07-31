$ErrorActionPreference = 'Stop'
$policyPath = Join-Path $PSScriptRoot '..\tools\restore_acl_policy.ps1'
. $policyPath
$allowed = @('S-1-5-18','S-1-5-32-544')
$safe = [pscustomobject]@{ owner_sid='S-1-5-18'; allow_aces=@([pscustomobject]@{sid='S-1-5-18';rights_value=2032127;is_inherited=$true},[pscustomobject]@{sid='S-1-5-32-545';rights_value=131241;is_inherited=$true}) }
Assert-RestoreAclEvidence -Evidence $safe -AllowedWriterSids $allowed
Assert-RestoreApproverToken -UserSid 'S-1-5-21-1-2-3-1001' -GroupSids @('S-1-5-32-544')
try { Assert-RestoreApproverToken -UserSid 'S-1-5-21-1-2-3-1001' -GroupSids @('S-1-5-11'); throw 'Expected non-admin producer failure' } catch { if ($_.Exception.Message -eq 'Expected non-admin producer failure') { throw } }
foreach ($bad in @(
  [pscustomobject]@{owner_sid='S-1-5-21-9-9-9-9';allow_aces=@()},
  [pscustomobject]@{owner_sid='S-1-5-18';allow_aces=@([pscustomobject]@{sid='S-1-5-21-9-9-9-9';rights_value=2;is_inherited=$true})},
  [pscustomobject]@{owner_sid='S-1-5-18';allow_aces=@([pscustomobject]@{sid='';rights_value=2;is_inherited=$true})}
)) { try { Assert-RestoreAclEvidence -Evidence $bad -AllowedWriterSids $allowed; throw 'Expected ACL policy failure' } catch { if ($_.Exception.Message -eq 'Expected ACL policy failure') { throw } } }
$helperPath = Join-Path $PSScriptRoot '..\tools\get_file_acl_evidence.ps1'; $aclRoot = Join-Path ([IO.Path]::GetTempPath()) ('restore-acl-' + [guid]::NewGuid()); New-Item -ItemType Directory -Path $aclRoot | Out-Null
try {
  $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; $acl = Get-Acl $aclRoot; $acl.SetAccessRuleProtection($true,$false); $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier($currentSid)))
  foreach ($sid in @('S-1-5-18','S-1-5-32-544',$currentSid)) { $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow); $acl.AddAccessRule($rule) | Out-Null }; Set-Acl -LiteralPath $aclRoot -AclObject $acl
  $actualJson = & $helperPath -Path $aclRoot; $actual = $actualJson | ConvertFrom-Json; Assert-RestoreAclEvidence -Evidence $actual -AllowedWriterSids @('S-1-5-18','S-1-5-32-544',$currentSid)
} finally { Remove-Item -LiteralPath $aclRoot -Force }
Write-Host 'Restore ACL policy checks passed.'
