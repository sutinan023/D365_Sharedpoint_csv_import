$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\sync_to_server.ps1'

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sync-to-server-test-{0}' -f [guid]::NewGuid())
$sourceRoot = Join-Path $testRoot 'source'
$destinationRoot = Join-Path $testRoot 'destination'
$customDestinationRoot = Join-Path $testRoot 'custom-destination'
New-Item -ItemType Directory -Path $sourceRoot, $destinationRoot, $customDestinationRoot | Out-Null

try {
    Set-Content (Join-Path $sourceRoot 'new.txt') 'new source file'
    Set-Content (Join-Path $sourceRoot 'modified.txt') 'source version'
    Set-Content (Join-Path $sourceRoot 'equal.txt') 'same content'
    Set-Content (Join-Path $sourceRoot 'hidden.txt') 'hidden source file'
    Set-Content (Join-Path $sourceRoot 'ตัวอย่าง.txt') 'unicode source file'
    Set-Content (Join-Path $sourceRoot '.gitignore') ".env`nlogs/`nignored-artifact.txt"
    Set-Content (Join-Path $sourceRoot '.env') 'DB_PASS=must-not-deploy'
    Set-Content (Join-Path $sourceRoot 'ignored-artifact.txt') 'must-not-deploy'
    New-Item -ItemType Directory (Join-Path $sourceRoot 'logs') | Out-Null
    Set-Content (Join-Path $sourceRoot 'logs\ignored.log') 'excluded log'
    New-Item -ItemType Directory (Join-Path $sourceRoot 'example') | Out-Null
    Set-Content (Join-Path $sourceRoot 'example\tracked-example.csv') 'must-not-deploy'
    Set-Content (Join-Path $sourceRoot 'example\tracked-example.CSV') 'must-not-deploy-case-insensitive'
    New-Item -ItemType Directory (Join-Path $sourceRoot 'payload') | Out-Null
    Set-Content (Join-Path $sourceRoot 'payload\payload.CSV') 'must-remain-excluded-with-caller-overrides'
    Set-Content (Join-Path $sourceRoot 'payload\needed.php') '<?php echo "needed";'

    & git -C $sourceRoot init --quiet
    & git -C $sourceRoot config core.autocrlf false
    & git -C $sourceRoot config user.email 'test@example.invalid'
    & git -C $sourceRoot config user.name 'Test'
    & git -C $sourceRoot add .
    & git -C $sourceRoot commit --quiet -m initial
    $sha = (& git -C $sourceRoot rev-parse HEAD).Trim()

    Set-Content (Join-Path $destinationRoot 'modified.txt') 'destination version'
    Set-Content (Join-Path $destinationRoot 'equal.txt') 'same content'
    Set-Content (Join-Path $destinationRoot 'removed.txt') 'stale destination file'
    New-Item -ItemType Directory (Join-Path $destinationRoot 'tmp') | Out-Null
    Set-Content (Join-Path $destinationRoot 'tmp\uat_config_check.json') 'runtime-only configuration check'

    $manifestPath = Join-Path $testRoot 'release.json'
    [ordered]@{
        release_id = 'test-release-1'
        projects = [ordered]@{
            D365_Sharedpoint_csv_import = [ordered]@{ git_sha = $sha }
            D365_file_csv_import = [ordered]@{ git_sha = $sha }
            finance_report = [ordered]@{ git_sha = $sha }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content $manifestPath

    $arguments = @{
        SourceRoot = $sourceRoot
        DestinationRoot = $destinationRoot
        Environment = 'UAT'
        ProjectName = 'D365_Sharedpoint_csv_import'
        ReleaseId = 'test-release-1'
        ManifestPath = $manifestPath
        LocalTestMode = $true
    }
    $comparison = & $scriptPath @arguments -CompareOnly | Out-String
    Assert-True ($comparison -match '(?m)^New:\s+new\.txt\s*$') 'New file was not listed.'
    Assert-True ($comparison -match '(?m)^New:\s+ตัวอย่าง\.txt\s*$') 'Unicode tracked file was not listed.'
    Assert-True ($comparison -match '(?m)^Modified:\s+modified\.txt\s*$') 'Modified file was not listed.'
    Assert-True ($comparison -match '(?m)^Deleted:\s+removed\.txt\s*$') 'Deleted file was not listed.'
    Assert-True ($comparison -notmatch '(?m)^Deleted:\s+tmp\\uat_config_check\.json\s*$') 'Runtime tmp file was listed for deletion.'
    Assert-True ($comparison -notmatch '(?m)equal\.txt') 'Equal file was listed.'
    Assert-True ($comparison -notmatch '(?m)\.env') 'Environment file was included.'
    Assert-True ($comparison -notmatch 'ignored-artifact') 'Git-ignored artifact was included.'
    Assert-True ($comparison -notmatch '(?mi)^(?:New|Modified|Deleted):\s+.*\.csv\s*$') 'Tracked CSV was included in the deployment payload.'

    $customArguments = $arguments.Clone()
    $customArguments.DestinationRoot = $customDestinationRoot
    $customComparison = & $scriptPath @customArguments -Exclude '*.log' -CompareOnly | Out-String
    Assert-True ($customComparison -match '(?m)^New:\s+payload\\needed\.php\s*$') 'Caller exclusion removed an adjacent required code file.'
    Assert-True ($customComparison -notmatch '(?mi)^(?:New|Modified|Deleted):\s+.*\.csv\s*$') 'Caller exclusion override allowed a CSV into CompareOnly.'
    & $scriptPath @customArguments -Exclude '*.log' -ApprovalToken 'APPROVE UAT test-release-1' | Out-Null
    Assert-True (Test-Path (Join-Path $customDestinationRoot 'payload\needed.php')) 'Adjacent required code file was not deployed with caller exclusions.'
    Assert-True (-not (Test-Path (Join-Path $customDestinationRoot 'payload\payload.CSV'))) 'Caller exclusion override allowed a CSV to deploy.'

    # Break caught: deployment reads mutable worktree bytes even though Git status was attested clean.
    $snapshotDestination = Join-Path $testRoot 'snapshot-destination'
    New-Item -ItemType Directory -Path $snapshotDestination | Out-Null
    & git -C $sourceRoot update-index --assume-unchanged new.txt
    try {
        Set-Content (Join-Path $sourceRoot 'new.txt') 'mutable worktree attack'
        $snapshotArguments = $arguments.Clone(); $snapshotArguments.DestinationRoot = $snapshotDestination
        & $scriptPath @snapshotArguments -ApprovalToken 'APPROVE UAT test-release-1' | Out-Null
        Assert-True ((Get-Content (Join-Path $snapshotDestination 'new.txt') -Raw) -match 'new source file') 'Deployment bytes did not come from the attested Git commit snapshot.'
    } finally {
        & git -C $sourceRoot checkout -- new.txt
        & git -C $sourceRoot update-index --no-assume-unchanged new.txt
    }

    # Break caught: duplicate manifest keys are silently collapsed before release validation.
    $duplicateManifestPath = Join-Path $testRoot 'duplicate-release.json'
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    [IO.File]::WriteAllText($duplicateManifestPath, $manifestText.Replace('"release_id":  "test-release-1"', '"release_id":  "test-release-1", "release_id": "test-release-1"'), [Text.UTF8Encoding]::new($false))
    $duplicateArguments = $arguments.Clone(); $duplicateArguments.ManifestPath = $duplicateManifestPath
    try { & $scriptPath @duplicateArguments -CompareOnly | Out-Null; throw 'Duplicate manifest key was accepted.' } catch { Assert-True ($_.Exception.Message -match 'duplicate') 'Duplicate manifest failed for the wrong reason.' }

    # Break caught: source/manifest changes after initial attestation proceed to destination mutation.
    $raceDestination = Join-Path $testRoot 'race-destination'
    New-Item -ItemType Directory -Path $raceDestination | Out-Null
    $raceArguments = $arguments.Clone(); $raceArguments.DestinationRoot = $raceDestination
    $previousSourceRace = $env:D365_SYNC_TEST_MUTATE_SOURCE_AFTER_ATTESTATION
    try {
        $env:D365_SYNC_TEST_MUTATE_SOURCE_AFTER_ATTESTATION = 'modified.txt'
        try { & $scriptPath @raceArguments -ApprovalToken 'APPROVE UAT test-release-1' | Out-Null; throw 'Post-attestation source mutation was accepted.' } catch { Assert-True ($_.Exception.Message -match 'changed after attestation|clean') 'Source race failed for the wrong reason.' }
    } finally {
        $env:D365_SYNC_TEST_MUTATE_SOURCE_AFTER_ATTESTATION = $previousSourceRace
        & git -C $sourceRoot checkout -- modified.txt
    }
    Assert-True (@(Get-ChildItem -LiteralPath $raceDestination -Force).Count -eq 0) 'Source race mutated the destination before aborting.'

    $manifestBeforeRace = [IO.File]::ReadAllBytes($manifestPath)
    $previousManifestRace = $env:D365_SYNC_TEST_MUTATE_MANIFEST_AFTER_ATTESTATION
    try {
        $env:D365_SYNC_TEST_MUTATE_MANIFEST_AFTER_ATTESTATION = '1'
        try { & $scriptPath @raceArguments -ApprovalToken 'APPROVE UAT test-release-1' | Out-Null; throw 'Post-attestation manifest mutation was accepted.' } catch { Assert-True ($_.Exception.Message -match 'manifest changed after attestation') 'Manifest race failed for the wrong reason.' }
    } finally {
        $env:D365_SYNC_TEST_MUTATE_MANIFEST_AFTER_ATTESTATION = $previousManifestRace
        [IO.File]::WriteAllBytes($manifestPath, $manifestBeforeRace)
    }
    Assert-True (@(Get-ChildItem -LiteralPath $raceDestination -Force).Count -eq 0) 'Manifest race mutated the destination before aborting.'

    Set-Content (Join-Path $sourceRoot 'dirty.txt') 'not committed'
    try {
        & $scriptPath @arguments -CompareOnly | Out-Null
        throw 'Dirty source was accepted.'
    } catch {
        Assert-True ($_.Exception.Message -match 'clean') 'Dirty source failed for the wrong reason.'
    }
    Remove-Item (Join-Path $sourceRoot 'dirty.txt')

    & $scriptPath @arguments -ApprovalToken 'APPROVE UAT test-release-1' | Out-Null
    Assert-True ((Get-Content (Join-Path $destinationRoot 'new.txt') -Raw) -match 'new source file') 'New file was not deployed.'
    Assert-True (-not (Test-Path (Join-Path $destinationRoot 'example\tracked-example.csv'))) 'Tracked CSV was deployed.'
    Assert-True (-not (Test-Path (Join-Path $destinationRoot 'example\tracked-example.CSV'))) 'Uppercase tracked CSV was deployed.'
    Assert-True (-not (Test-Path (Join-Path $destinationRoot 'removed.txt'))) 'Deleted file remained.'
    Assert-True (Test-Path (Join-Path $destinationRoot '.deployment\current-release.json')) 'Deployment metadata missing.'
    $backups = Get-ChildItem (Join-Path $testRoot '.deploy-backups') -Directory -Recurse
    Assert-True ($backups.Count -gt 0) 'Immutable backup directory missing.'

    $noChangeDeployment = & $scriptPath @arguments -ApprovalToken 'APPROVE UAT test-release-1' | Out-String
    Assert-True ($noChangeDeployment -match 'No file changes') 'No-change release did not update metadata.'

    try {
        $productionArguments = $arguments.Clone()
        $productionArguments.Environment = 'Production'
        & $scriptPath @productionArguments -CompareOnly | Out-Null
        throw 'Production LocalTestMode was accepted.'
    } catch {
        Assert-True ($_.Exception.Message -match 'only for UAT') 'Production test mode failed for the wrong reason.'
    }
}
finally {
    if (Test-Path $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'sync_to_server.ps1 safety and deployment checks passed.'
