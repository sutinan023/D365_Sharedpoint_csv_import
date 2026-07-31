$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\sync_to_server.ps1'

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sync-to-server-test-{0}' -f [guid]::NewGuid())
$sourceRoot = Join-Path $testRoot 'source'
$destinationRoot = Join-Path $testRoot 'destination'
New-Item -ItemType Directory -Path $sourceRoot, $destinationRoot | Out-Null

try {
    Set-Content (Join-Path $sourceRoot 'new.txt') 'new source file'
    Set-Content (Join-Path $sourceRoot 'modified.txt') 'source version'
    Set-Content (Join-Path $sourceRoot 'equal.txt') 'same content'
    Set-Content (Join-Path $sourceRoot 'hidden.txt') 'hidden source file'
    Set-Content (Join-Path $sourceRoot '.gitignore') ".env`nlogs/"
    Set-Content (Join-Path $sourceRoot '.env') 'DB_PASS=must-not-deploy'
    New-Item -ItemType Directory (Join-Path $sourceRoot 'logs') | Out-Null
    Set-Content (Join-Path $sourceRoot 'logs\ignored.log') 'excluded log'

    & git -C $sourceRoot init --quiet
    & git -C $sourceRoot config user.email 'test@example.invalid'
    & git -C $sourceRoot config user.name 'Test'
    & git -C $sourceRoot add .
    & git -C $sourceRoot commit --quiet -m initial
    $sha = (& git -C $sourceRoot rev-parse HEAD).Trim()

    Set-Content (Join-Path $destinationRoot 'modified.txt') 'destination version'
    Set-Content (Join-Path $destinationRoot 'equal.txt') 'same content'
    Set-Content (Join-Path $destinationRoot 'removed.txt') 'stale destination file'

    $manifestPath = Join-Path $testRoot 'release.json'
    [ordered]@{
        release_id = 'test-release-1'
        projects = [ordered]@{
            D365_Sharedpoint_csv_import = [ordered]@{ git_sha = $sha }
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
    Assert-True ($comparison -match '(?m)^Modified:\s+modified\.txt\s*$') 'Modified file was not listed.'
    Assert-True ($comparison -match '(?m)^Deleted:\s+removed\.txt\s*$') 'Deleted file was not listed.'
    Assert-True ($comparison -notmatch '(?m)equal\.txt') 'Equal file was listed.'
    Assert-True ($comparison -notmatch '(?m)\.env') 'Environment file was included.'

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
    Assert-True (-not (Test-Path (Join-Path $destinationRoot 'removed.txt'))) 'Deleted file remained.'
    Assert-True (Test-Path (Join-Path $destinationRoot '.deployment\current-release.json')) 'Deployment metadata missing.'
    $backups = Get-ChildItem (Join-Path $testRoot '.deploy-backups') -Directory -Recurse
    Assert-True ($backups.Count -gt 0) 'Immutable backup directory missing.'

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
