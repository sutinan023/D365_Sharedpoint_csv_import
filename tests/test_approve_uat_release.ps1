$ErrorActionPreference = 'Stop'
$approveScript = Join-Path $PSScriptRoot '..\tools\approve_uat_release.ps1'
$syncScript = Join-Path $PSScriptRoot '..\tools\sync_to_server.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('uat-approval-test-{0}' -f [guid]::NewGuid())

function Assert-Throws([scriptblock]$Action,[string]$Pattern) {
    try { & $Action; throw 'Expected failure.' } catch {
        if ($_.Exception.Message -eq 'Expected failure.' -or $_.Exception.Message -notmatch $Pattern) { throw }
    }
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Set-TightAcl([string]$Path) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid,$rights,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
    [void]$acl.AddAccessRule($rule); $acl.SetOwner($sid); Set-Acl -LiteralPath $Path -AclObject $acl
}
function New-ReceiptVariant([string]$Name,[scriptblock]$Transform,[string]$ValidReceipt) {
    $root = Join-Path $testRoot $Name; New-Item -ItemType Directory -Path $root | Out-Null; Set-TightAcl $root
    $path = Join-Path $root (Split-Path -Leaf $ValidReceipt)
    $raw = Get-Content -LiteralPath $ValidReceipt -Raw
    $newRaw = & $Transform $raw
    [IO.File]::WriteAllText($path,$newRaw,[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{Root=$root;Path=$path;Hash=(Hash $path)}
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $repo = Join-Path $testRoot 'source'; New-Item -ItemType Directory -Path $repo | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'app.php') '<?php echo "ok";'
    & git -C $repo init --quiet; & git -C $repo config user.email test@example.invalid; & git -C $repo config user.name Test; & git -C $repo add .; & git -C $repo commit --quiet -m initial
    $sha = (& git -C $repo rev-parse HEAD).Trim()
    $manifest = Join-Path $testRoot 'release.json'
    [ordered]@{release_id='approval-test';projects=[ordered]@{
        D365_Sharedpoint_csv_import=[ordered]@{git_sha=$sha};D365_file_csv_import=[ordered]@{git_sha=$sha};finance_report=[ordered]@{git_sha=$sha}
    }} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifest -Encoding UTF8
    $auditRoot = Join-Path $testRoot 'canonical-audit'; New-Item -ItemType Directory -Path $auditRoot | Out-Null; Set-TightAcl $auditRoot

    # Break caught: approval receipt can be overwritten, lacks SID/project binding, or is written outside protected audit storage.
    $receipt = (& $approveScript -ManifestPath $manifest -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'APPROVE UAT RESULT approval-test' | Out-String).Trim()
    $value = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    if ($value.approved_by_sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'Receipt did not bind approver SID.' }
    if ($value.manifest_sha256 -cne (Hash $manifest)) { throw 'Receipt did not bind manifest hash.' }
    foreach ($project in @('D365_Sharedpoint_csv_import','D365_file_csv_import','finance_report')) { if ($value.projects.$project.git_sha -cne $sha) { throw "Receipt did not bind $project SHA." } }
    Assert-Throws { & $approveScript -ManifestPath $manifest -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'APPROVE UAT RESULT approval-test' | Out-Null } 'already exists|immutable'
    Assert-Throws { & $approveScript -ManifestPath $manifest -AuditRoot $auditRoot -OutputPath (Join-Path $testRoot 'forged.json') -LocalTestMode -ApprovalToken 'APPROVE UAT RESULT approval-test' | Out-Null } 'canonical|audit root'

    $duplicateManifest = Join-Path $testRoot 'duplicate-manifest.json'
    $rawManifest = Get-Content -LiteralPath $manifest -Raw
    [IO.File]::WriteAllText($duplicateManifest,$rawManifest.Replace('"release_id":  "approval-test"','"release_id":  "approval-test", "release_id": "approval-test"'),[Text.UTF8Encoding]::new($false))
    Assert-Throws { & $approveScript -ManifestPath $duplicateManifest -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'APPROVE UAT RESULT approval-test' | Out-Null } 'duplicate'

    $looseApprovalRoot = Join-Path $testRoot 'loose-approval'; New-Item -ItemType Directory -Path $looseApprovalRoot | Out-Null
    Assert-Throws { & $approveScript -ManifestPath $manifest -AuditRoot $looseApprovalRoot -LocalTestMode -ApprovalToken 'APPROVE UAT RESULT approval-test' | Out-Null } 'ACL|protected'

    # Production gate validates the exact immutable receipt bytes, canonical root/path, ACL and all SHAs.
    $destination = Join-Path $testRoot 'destination'; New-Item -ItemType Directory -Path $destination | Out-Null
    $prodArgs = @{Environment='Production';ProjectName='D365_Sharedpoint_csv_import';ReleaseId='approval-test';ManifestPath=$manifest;SourceRoot=$repo;DestinationRoot=$destination;LocalTestMode=$true;ProductionApprovalValidationOnly=$true;ApprovalAuditRoot=$auditRoot;UatApprovalPath=$receipt;ExpectedUatApprovalSha256=(Hash $receipt)}
    & $syncScript @prodArgs | Out-Null
    $wrongHashArgs=$prodArgs.Clone();$wrongHashArgs.ExpectedUatApprovalSha256=('0'*64)
    Assert-Throws { & $syncScript @wrongHashArgs | Out-Null } 'receipt SHA|hash'
    $outside = Join-Path $testRoot 'outside-receipt.json'; Copy-Item -LiteralPath $receipt -Destination $outside
    $outsideArgs=$prodArgs.Clone();$outsideArgs.UatApprovalPath=$outside;$outsideArgs.ExpectedUatApprovalSha256=(Hash $outside)
    Assert-Throws { & $syncScript @outsideArgs | Out-Null } 'canonical|audit root'

    $wrongProject = New-ReceiptVariant 'wrong-project' { param($raw) $raw.Replace($sha,('f'*40)) } $receipt
    $wrongProjectArgs=$prodArgs.Clone();$wrongProjectArgs.ApprovalAuditRoot=$wrongProject.Root;$wrongProjectArgs.UatApprovalPath=$wrongProject.Path;$wrongProjectArgs.ExpectedUatApprovalSha256=$wrongProject.Hash
    Assert-Throws { & $syncScript @wrongProjectArgs | Out-Null } 'project|Git SHA'
    $duplicateReceipt = New-ReceiptVariant 'duplicate-receipt' { param($raw) $raw.Replace('"status":  "APPROVED"','"status":  "APPROVED", "status": "APPROVED"') } $receipt
    $duplicateReceiptArgs=$prodArgs.Clone();$duplicateReceiptArgs.ApprovalAuditRoot=$duplicateReceipt.Root;$duplicateReceiptArgs.UatApprovalPath=$duplicateReceipt.Path;$duplicateReceiptArgs.ExpectedUatApprovalSha256=$duplicateReceipt.Hash
    Assert-Throws { & $syncScript @duplicateReceiptArgs | Out-Null } 'duplicate'
    $looseRoot = Join-Path $testRoot 'loose-sync'; New-Item -ItemType Directory -Path $looseRoot | Out-Null
    $looseReceipt = Join-Path $looseRoot (Split-Path -Leaf $receipt); Copy-Item -LiteralPath $receipt -Destination $looseReceipt
    $looseArgs=$prodArgs.Clone();$looseArgs.ApprovalAuditRoot=$looseRoot;$looseArgs.UatApprovalPath=$looseReceipt;$looseArgs.ExpectedUatApprovalSha256=(Hash $looseReceipt)
    Assert-Throws { & $syncScript @looseArgs | Out-Null } 'ACL|protected'
}
finally { if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force} }
Write-Host 'UAT approval receipt and Production gate checks passed.'
