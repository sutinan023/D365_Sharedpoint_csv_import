$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\tools\update_app_release.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('update-app-release-test-{0}' -f [guid]::NewGuid())
$auditRoot = Join-Path $testRoot 'audit'
$secret = 'never-print-this-secret-7dd3'

function Get-EnvironmentFilePath {
    param([string] $Root, [string] $Project)
    if ($Project -ceq 'D365_Sharedpoint_csv_import') { return Join-Path $Root "$Project\config\.env" }
    return Join-Path $Root "$Project\.env"
}

function New-TestEnvironment {
    param([string] $Name = 'uat', [string] $Release = '2026-07-31.8', [string] $DbName = 'D365_finance', [string] $AppEnv = 'UAT')
    $root = Join-Path $testRoot $Name
    foreach ($project in @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')) {
        $envPath = Get-EnvironmentFilePath $root $project
        New-Item -ItemType Directory -Path (Split-Path -Parent $envPath) -Force | Out-Null
        $text = "# retained comment`r`nAPP_ENV=$AppEnv`r`nAPP_RELEASE=$Release`r`nDB_NAME=$DbName`r`nDB_PASS=$secret`r`n"
        [IO.File]::WriteAllText($envPath, $text, [Text.UTF8Encoding]::new($false))
    }
    return $root
}

function Invoke-ExpectedFailure {
    param([scriptblock] $Action, [string] $Matches)
    try { & $Action; throw 'Expected command to fail.' } catch {
        if ($_.Exception.Message -notmatch $Matches) { throw }
    }
}

function Get-EnvironmentSnapshots {
    param([string] $Root)
    $snapshots = @{}
    foreach ($project in @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')) {
        $path = Get-EnvironmentFilePath $Root $project
        $snapshots[$path] = [IO.File]::ReadAllBytes($path)
    }
    return $snapshots
}

function Assert-SnapshotsUnchanged {
    param([hashtable] $Snapshots)
    foreach ($path in $Snapshots.Keys) {
        $actual = [IO.File]::ReadAllBytes($path)
        if ([Convert]::ToBase64String($actual) -cne [Convert]::ToBase64String($Snapshots[$path])) {
            throw "Rollback did not restore original bytes: $path"
        }
    }
}

function Assert-RootPairPolicy {
    param([string] $Environment, [string] $EnvironmentRoot, [string] $AuditRoot, [bool] $Expected, [string] $ExpectedKind = '')
    $previousPolicyMode = $env:D365_APP_RELEASE_POLICY_TEST_ONLY
    try {
        $env:D365_APP_RELEASE_POLICY_TEST_ONLY = '1'
        $policy = (& $scriptPath -Environment $Environment -ReleaseId 'policy-check' -EnvironmentRoot $EnvironmentRoot -AuditRoot $AuditRoot -LocalTestMode -ApprovalToken 'unused' | Out-String | ConvertFrom-Json)
    } finally { $env:D365_APP_RELEASE_POLICY_TEST_ONLY = $previousPolicyMode }
    if ([bool]$policy.accepted -ne $Expected) { throw "Unexpected root-pair policy for $EnvironmentRoot and $AuditRoot" }
    if ($Expected -and $policy.kind -cne $ExpectedKind) { throw "Expected root-pair kind $ExpectedKind, got $($policy.kind)" }
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
New-Item -ItemType Directory -Path $auditRoot | Out-Null
try {
    Assert-RootPairPolicy UAT 'C:\xampp\htdocs\uat' 'C:\xampp\backups\d365' $true LOCAL
    Assert-RootPairPolicy UAT '\\100.1.1.166\c$\xampp\htdocs\uat' '\\100.1.1.166\c$\xampp\backups\d365' $true UNC
    Assert-RootPairPolicy Production '\\100.1.1.166\C$\XAMPP\HTDOCS\PROD' '\\100.1.1.166\C$\XAMPP\BACKUPS\D365' $true UNC
    Assert-RootPairPolicy UAT '\\100.1.1.167\c$\xampp\htdocs\uat' '\\100.1.1.167\c$\xampp\backups\d365' $false
    Assert-RootPairPolicy UAT '\\100.1.1.166\d$\xampp\htdocs\uat' '\\100.1.1.166\d$\xampp\backups\d365' $false
    Assert-RootPairPolicy UAT '\\100.1.1.166\c$\xampp\htdocs\uat' '\\100.1.1.166\c$\xampp\backups\d365-other' $false
    Assert-RootPairPolicy UAT 'C:\xampp\htdocs\uat' '\\100.1.1.166\c$\xampp\backups\d365' $false
    Assert-RootPairPolicy UAT '\\100.1.1.166\c$\xampp\htdocs\uat' 'C:\xampp\backups\d365' $false
    Assert-RootPairPolicy UAT '\\100.1.1.166\c$\xampp\htdocs\prod' '\\100.1.1.166\c$\xampp\backups\d365' $false

    $uatRoot = New-TestEnvironment
    $beforePath = Join-Path $uatRoot 'D365_Sharedpoint_csv_import\config\.env'
    $before = [IO.File]::ReadAllBytes($beforePath)
    $resultText = (& $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $uatRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' | Out-String)
    $result = $resultText | ConvertFrom-Json
    if ($result.status -cne 'UPDATED') { throw 'Expected UPDATED status.' }
    $after = [IO.File]::ReadAllBytes($beforePath)
    $beforeText = [Text.Encoding]::UTF8.GetString($before)
    $afterText = [Text.Encoding]::UTF8.GetString($after)
    if (($afterText -replace 'APP_RELEASE=2026-07-31.9', 'APP_RELEASE=2026-07-31.8') -cne $beforeText) {
        $differencePositions = @(for ($i = 0; $i -lt $beforeText.Length; $i++) { if ($beforeText[$i] -cne $afterText[$i]) { $i } })
        throw "Updater changed more than the APP_RELEASE line (difference positions: $($differencePositions -join ','))."
    }
    if ($resultText -match [regex]::Escape($secret)) { throw 'Secret appeared in command output.' }
    $audit = Get-Content -LiteralPath $result.audit_file -Raw
    if ($audit -match [regex]::Escape($secret) -or $audit -match 'DB_PASS') { throw 'Secret appeared in audit.' }

    $second = (& $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $uatRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' | Out-String | ConvertFrom-Json)
    if ($second.status -cne 'NO_CHANGE') { throw 'Idempotent rerun did not report NO_CHANGE.' }

    $exactRoot = New-TestEnvironment -Name exact-paths
    $allBefore = @{}
    foreach ($project in @('D365_file_csv_import', 'finance_report')) {
        $decoy = Join-Path $exactRoot "$project\config\.env"
        New-Item -ItemType Directory -Path (Split-Path -Parent $decoy) -Force | Out-Null
        [IO.File]::WriteAllText($decoy, "APP_ENV=UAT`r`nAPP_RELEASE=decoy`r`nDB_NAME=D365_finance`r`nDB_PASS=$secret`r`n", [Text.UTF8Encoding]::new($false))
    }
    foreach ($file in Get-ChildItem -LiteralPath $exactRoot -Filter '.env' -File -Recurse) { $allBefore[$file.FullName] = [IO.File]::ReadAllBytes($file.FullName) }
    & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $exactRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' | Out-Null
    $expectedChanged = @(
        (Get-EnvironmentFilePath $exactRoot 'D365_Sharedpoint_csv_import'),
        (Get-EnvironmentFilePath $exactRoot 'D365_file_csv_import'),
        (Get-EnvironmentFilePath $exactRoot 'finance_report')
    )
    foreach ($path in $allBefore.Keys) {
        $changed = [Convert]::ToBase64String($allBefore[$path]) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
        $shouldChange = $expectedChanged -contains $path
        if ($changed -ne $shouldChange) { throw "Updater changed the wrong environment path: $path" }
    }

    $secondUpdateRoot = New-TestEnvironment -Name second-success
    $secondUpdate = (& $scriptPath -Environment UAT -ReleaseId '2026-07-31.10' -EnvironmentRoot $secondUpdateRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.10' | Out-String | ConvertFrom-Json)
    if ($secondUpdate.audit_file -ceq $result.audit_file) { throw 'Audit filenames collided.' }
    if ((Split-Path $secondUpdate.audit_file -Leaf) -notmatch '^app-release-update-uat-\d{8}-\d{9}-[0-9a-f]{32}\.json$') { throw 'Audit filename is not collision resistant.' }
    $scriptSource = Get-Content -LiteralPath $scriptPath -Raw
    if ($scriptSource -notmatch 'FileMode\]::CreateNew') { throw 'Audit is not opened with CreateNew.' }
    if ($scriptSource -notmatch 'function Test-CanonicalPathEqual') { throw 'Canonical path comparison is not explicitly case insensitive.' }
    if ($scriptSource -notmatch 'Test-Path -LiteralPath \$environmentRootFull -PathType Container' -or $scriptSource -notmatch 'Test-Path -LiteralPath \$auditRootFull -PathType Container') { throw 'Normal execution no longer requires both roots to exist.' }

    foreach ($fault in @('AfterFirstWrite', 'AfterVerification', 'DuringAudit')) {
        $faultRoot = New-TestEnvironment -Name ("fault-{0}" -f $fault.ToLowerInvariant())
        $snapshots = Get-EnvironmentSnapshots $faultRoot
        $previousFault = $env:D365_APP_RELEASE_TEST_FAULT
        try {
            $env:D365_APP_RELEASE_TEST_FAULT = $fault
            Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $faultRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'simulated'
        } finally { $env:D365_APP_RELEASE_TEST_FAULT = $previousFault }
        Assert-SnapshotsUnchanged $snapshots
    }

    foreach ($suffix in @('trailing text')) {
        $malformedRoot = New-TestEnvironment -Name ('malformed-' + [guid]::NewGuid())
        $malformedPath = Join-Path $malformedRoot 'D365_Sharedpoint_csv_import\config\.env'
        $malformed = (Get-Content -LiteralPath $malformedPath -Raw) -replace 'APP_RELEASE=2026-07-31.8', "APP_RELEASE=2026-07-31.8 $suffix"
        [IO.File]::WriteAllText($malformedPath, $malformed, [Text.UTF8Encoding]::new($false))
        $snapshots = Get-EnvironmentSnapshots $malformedRoot
        Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $malformedRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'APP_RELEASE.*safe'
        Assert-SnapshotsUnchanged $snapshots
    }

    $hashDbRoot = New-TestEnvironment -Name hash-in-db
    $hashDbPath = Join-Path $hashDbRoot 'D365_Sharedpoint_csv_import\config\.env'
    [IO.File]::WriteAllText($hashDbPath, ((Get-Content -LiteralPath $hashDbPath -Raw) -replace 'DB_NAME=D365_finance', 'DB_NAME=D365_finance#evil'), [Text.UTF8Encoding]::new($false))
    $hashDbSnapshots = Get-EnvironmentSnapshots $hashDbRoot
    $hashDbAuditCount = @(Get-ChildItem -LiteralPath $auditRoot -Filter '*.json').Count
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $hashDbRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'DB_NAME'
    Assert-SnapshotsUnchanged $hashDbSnapshots
    if (@(Get-ChildItem -LiteralPath $auditRoot -Filter '*.json').Count -ne $hashDbAuditCount) { throw 'Rejected DB_NAME created an audit file.' }

    foreach ($hashCase in @(
        @{ Key = 'APP_ENV'; Old = 'APP_ENV=UAT'; New = 'APP_ENV=UAT#evil' },
        @{ Key = 'APP_RELEASE'; Old = 'APP_RELEASE=2026-07-31.8'; New = 'APP_RELEASE=2026-07-31.8#evil' }
    )) {
        $hashRoot = New-TestEnvironment -Name ('hash-in-' + $hashCase.Key.ToLowerInvariant())
        $hashPath = Get-EnvironmentFilePath $hashRoot 'finance_report'
        [IO.File]::WriteAllText($hashPath, ((Get-Content -LiteralPath $hashPath -Raw) -replace [regex]::Escape($hashCase.Old), $hashCase.New), [Text.UTF8Encoding]::new($false))
        $hashSnapshots = Get-EnvironmentSnapshots $hashRoot
        Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $hashRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } $hashCase.Key
        Assert-SnapshotsUnchanged $hashSnapshots
    }

    foreach ($key in @('APP_ENV', 'APP_RELEASE', 'DB_NAME')) {
        $quoteRoot = New-TestEnvironment -Name ('mismatched-quote-' + $key.ToLowerInvariant())
        $quotePath = Get-EnvironmentFilePath $quoteRoot 'D365_file_csv_import'
        $quoteText = Get-Content -LiteralPath $quotePath -Raw
        $quoteText = $quoteText -replace "(?m)^$key=(.*)$", "$key=`"`$1'"
        [IO.File]::WriteAllText($quotePath, $quoteText, [Text.UTF8Encoding]::new($false))
        $quoteSnapshots = Get-EnvironmentSnapshots $quoteRoot
        Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $quoteRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } $key
        Assert-SnapshotsUnchanged $quoteSnapshots
    }

    $escapeRoot = New-TestEnvironment -Name escaped-scalar
    $escapePath = Get-EnvironmentFilePath $escapeRoot 'D365_file_csv_import'
    [IO.File]::WriteAllText($escapePath, ((Get-Content -LiteralPath $escapePath -Raw) -replace 'DB_NAME=D365_finance', 'DB_NAME="D365_finance\""'), [Text.UTF8Encoding]::new($false))
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $escapeRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'DB_NAME'

    $caseReleaseRoot = New-TestEnvironment -Name case-release -Release Release-A
    $caseReleasePath = Get-EnvironmentFilePath $caseReleaseRoot 'finance_report'
    [IO.File]::WriteAllText($caseReleasePath, ((Get-Content -LiteralPath $caseReleasePath -Raw) -replace 'APP_RELEASE=Release-A', 'APP_RELEASE=release-a'), [Text.UTF8Encoding]::new($false))
    $caseReleaseSnapshots = Get-EnvironmentSnapshots $caseReleaseRoot
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId 'Release-B' -EnvironmentRoot $caseReleaseRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE Release-B' } 'identical'
    Assert-SnapshotsUnchanged $caseReleaseSnapshots

    $commentRoot = New-TestEnvironment -Name quoted-comments
    foreach ($project in @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')) {
        $commentPath = Get-EnvironmentFilePath $commentRoot $project
        $commentText = Get-Content -LiteralPath $commentPath -Raw
        $commentText = $commentText -replace 'APP_ENV=UAT', 'APP_ENV="UAT" # environment'
        $commentText = $commentText -replace 'APP_RELEASE=2026-07-31.8', "APP_RELEASE='2026-07-31.8' # release"
        $commentText = $commentText -replace 'DB_NAME=D365_finance', 'DB_NAME=D365_finance # database'
        [IO.File]::WriteAllText($commentPath, $commentText, [Text.UTF8Encoding]::new($false))
    }
    $commentResult = (& $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $commentRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' | Out-String | ConvertFrom-Json)
    if ($commentResult.status -cne 'UPDATED') { throw 'Valid paired quotes and outside comments were rejected.' }
    $commentAfter = Get-Content -LiteralPath (Get-EnvironmentFilePath $commentRoot 'finance_report') -Raw
    if ($commentAfter -notmatch "APP_RELEASE='2026-07-31\.9' # release" -or $commentAfter -notmatch 'APP_ENV="UAT" # environment') { throw 'Quoted release update did not preserve quotes/comments.' }

    $lowerEnvRoot = New-TestEnvironment -Name lowercase-env -AppEnv uat
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $lowerEnvRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'APP_ENV'

    $bomRoot = New-TestEnvironment -Name utf8-bom
    $bomPath = Get-EnvironmentFilePath $bomRoot 'finance_report'
    $bomBody = [IO.File]::ReadAllBytes($bomPath)
    $bomBytes = [byte[]](0xEF, 0xBB, 0xBF) + $bomBody
    [IO.File]::WriteAllBytes($bomPath, $bomBytes)
    & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $bomRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' | Out-Null
    $bomAfter = [IO.File]::ReadAllBytes($bomPath)
    if ($bomAfter[0] -ne 0xEF -or $bomAfter[1] -ne 0xBB -or $bomAfter[2] -ne 0xBF) { throw 'UTF-8 BOM was not preserved.' }

    $invalidUtf8Root = New-TestEnvironment -Name invalid-utf8
    $invalidUtf8Path = Get-EnvironmentFilePath $invalidUtf8Root 'finance_report'
    $validBytes = [IO.File]::ReadAllBytes($invalidUtf8Path)
    [IO.File]::WriteAllBytes($invalidUtf8Path, ($validBytes + [byte[]](0xC3, 0x28)))
    $invalidSnapshots = Get-EnvironmentSnapshots $invalidUtf8Root
    $invalidAuditCount = @(Get-ChildItem -LiteralPath $auditRoot -Filter '*.json').Count
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $invalidUtf8Root -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'UTF-8'
    Assert-SnapshotsUnchanged $invalidSnapshots
    if (@(Get-ChildItem -LiteralPath $auditRoot -Filter '*.json').Count -ne $invalidAuditCount) { throw 'Invalid UTF-8 created an audit file.' }

    $wrongTokenRoot = New-TestEnvironment -Name wrong-token
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $wrongTokenRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'wrong' } 'approval'
    if ((Get-Content (Join-Path $wrongTokenRoot 'D365_Sharedpoint_csv_import\config\.env') -Raw) -notmatch 'APP_RELEASE=2026-07-31.8') { throw 'Wrong token changed a file.' }

    $badEnvRoot = New-TestEnvironment -Name bad-env -AppEnv PRODUCTION
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $badEnvRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'APP_ENV'
    $badDbRoot = New-TestEnvironment -Name bad-db -DbName D365_finance_prod
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $badDbRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'DB_NAME'
    $mismatchRoot = New-TestEnvironment -Name mismatch
    [IO.File]::WriteAllText((Get-EnvironmentFilePath $mismatchRoot 'finance_report'), "APP_ENV=UAT`r`nAPP_RELEASE=different`r`nDB_NAME=D365_finance`r`nDB_PASS=$secret`r`n")
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $mismatchRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'identical'
    $duplicateRoot = New-TestEnvironment -Name duplicate
    Add-Content (Get-EnvironmentFilePath $duplicateRoot 'D365_file_csv_import') 'APP_RELEASE=duplicate'
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $duplicateRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'exactly one'
    $missingRoot = New-TestEnvironment -Name missing
    Remove-Item -LiteralPath (Get-EnvironmentFilePath $missingRoot 'finance_report') -Force
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $missingRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'not found'
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '../unsafe' -EnvironmentRoot $uatRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE ../unsafe' } 'ReleaseId'
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot 'C:\xampp\htdocs\uat' -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'LocalTestMode'

    $normalCustomRoot = New-TestEnvironment -Name normal-custom
    $normalSnapshots = Get-EnvironmentSnapshots $normalCustomRoot
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $normalCustomRoot -AuditRoot 'C:\xampp\backups\d365' -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'canonical'
    Assert-SnapshotsUnchanged $normalSnapshots
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot 'C:\xampp\htdocs\uat' -AuditRoot $auditRoot -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'canonical'

    $junctionTarget = New-TestEnvironment -Name junction-target
    $junctionRoot = Join-Path $testRoot 'junction-root'
    New-Item -ItemType Junction -Path $junctionRoot -Target $junctionTarget | Out-Null
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $junctionRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'reparse'
    [IO.Directory]::Delete($junctionRoot)

    $envPathRoot = New-TestEnvironment -Name env-path-junction
    $linkedProject = Join-Path $envPathRoot 'finance_report'
    $linkedTarget = Join-Path $testRoot 'env-path-junction-target'
    [IO.Directory]::Move($linkedProject, $linkedTarget)
    New-Item -ItemType Junction -Path $linkedProject -Target $linkedTarget | Out-Null
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $envPathRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'reparse'
    [IO.Directory]::Delete($linkedProject)

    $auditTarget = Join-Path $testRoot 'audit-target'
    New-Item -ItemType Directory -Path $auditTarget | Out-Null
    $auditJunction = Join-Path $testRoot 'audit-junction'
    New-Item -ItemType Junction -Path $auditJunction -Target $auditTarget | Out-Null
    $auditJunctionRoot = New-TestEnvironment -Name audit-junction-env
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $auditJunctionRoot -AuditRoot $auditJunction -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'reparse'
    [IO.Directory]::Delete($auditJunction)

    $lockRoot = New-TestEnvironment -Name locked
    $lockPath = Join-Path $auditRoot 'app-release-update-uat.lock'
    $heldLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $lockRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'already running|lock'
    } finally { $heldLock.Dispose() }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'APP_RELEASE updater checks passed.'
