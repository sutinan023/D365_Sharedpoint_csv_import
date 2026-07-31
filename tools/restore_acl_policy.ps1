function Assert-RestoreAclEvidence {
    param(
        [Parameter(Mandatory = $true)] $Evidence,
        [Parameter(Mandatory = $true)] [string[]] $AllowedWriterSids
    )
    $writeLikeMask = [int64](2 -bor 4 -bor 16 -bor 64 -bor 256 -bor 65536 -bor 262144 -bor 524288)
    $sidPattern = '^S-1-(?:[0-9]+-)+[0-9]+$'
    $ownerSid = [string]$Evidence.owner_sid
    if ($ownerSid -notmatch $sidPattern -or $ownerSid -notin $AllowedWriterSids) { throw 'ACL owner SID is missing or not explicitly allowed.' }
    if ($null -eq $Evidence.allow_aces) { throw 'ACL evidence is missing Allow ACEs.' }
    foreach ($ace in @($Evidence.allow_aces)) {
        $sid = [string]$ace.sid
        if ($sid -notmatch $sidPattern) { throw 'ACL Allow ACE SID could not be translated.' }
        if ($ace.rights_value -isnot [int] -and $ace.rights_value -isnot [int64]) { throw 'ACL Allow ACE rights are not a native integer.' }
        if (([int64]$ace.rights_value -band $writeLikeMask) -ne 0 -and $sid -notin $AllowedWriterSids) { throw "ACL grants write-like rights to an unapproved SID: $sid" }
    }
}

function Assert-RestoreApproverToken {
    param([Parameter(Mandatory = $true)][string]$UserSid,[Parameter(Mandatory = $true)][bool]$ActiveAdministrator)
    if ($UserSid -notmatch '^S-1-(?:[0-9]+-)+[0-9]+$' -or -not $ActiveAdministrator) { throw 'Restore approval requires an active elevated Administrator token.' }
}
