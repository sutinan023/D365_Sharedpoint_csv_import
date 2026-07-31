param([Parameter(Mandatory = $true)] [string] $Path)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path)) { throw 'ACL target does not exist.' }
$acl = Get-Acl -LiteralPath $Path
try { $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { throw 'ACL owner identity could not be translated to SID.' }
$allowAces = @()
foreach ($rule in $acl.Access) {
    if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
    try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { throw 'ACL Allow ACE identity could not be translated to SID.' }
    $allowAces += [ordered]@{ sid=$sid; rights_value=[int64]$rule.FileSystemRights; is_inherited=[bool]$rule.IsInherited }
}
[ordered]@{owner_sid=$ownerSid;allow_aces=$allowAces}|ConvertTo-Json -Depth 5 -Compress
