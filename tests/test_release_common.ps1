$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\release_common.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('release-common-{0}' -f [guid]::NewGuid())
$sourceParent = Join-Path $testRoot 'source'
$environmentRoot = Join-Path $testRoot 'uat'
$projects = @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Expected, $Actual, [string] $Message) {
    if ($Expected -cne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}

try {
    New-Item -ItemType Directory -Path $sourceParent, $environmentRoot | Out-Null
    $manifestProjects = [ordered]@{}

    foreach ($project in $projects) {
        $source = Join-Path $sourceParent $project
        $destination = Join-Path $environmentRoot $project
        New-Item -ItemType Directory -Path $source, (Join-Path $destination '.deployment') -Force | Out-Null
        Set-Content (Join-Path $source 'app.php') '<?php echo "base";'
        & git -C $source init --quiet
        & git -C $source config core.autocrlf false
        & git -C $source config user.email 'test@example.invalid'
        & git -C $source config user.name 'Test'
        & git -C $source add .
        & git -C $source commit --quiet -m base
        $sha = (& git -C $source rev-parse HEAD).Trim()
        $manifestProjects[$project] = [ordered]@{ git_sha = $sha }
        [ordered]@{
            release_id = 'r1'
            environment = 'UAT'
            project = $project
            git_sha = $sha
        } | ConvertTo-Json | Set-Content (Join-Path $destination '.deployment\current-release.json')
    }

    $map = Get-D365ProjectMap -SourceParent $sourceParent -EnvironmentRoot $environmentRoot
    Assert-True ($map.Count -eq 3) 'Project map must contain exactly three projects.'
    Assert-True ($map.finance_report.SourceRoot -ieq (Join-Path $sourceParent 'finance_report')) 'Project source root is wrong.'
    Assert-True ($map.finance_report.DestinationRoot -ieq (Join-Path $environmentRoot 'finance_report')) 'Project destination root is wrong.'

    Assert-D365CleanReleaseRepositories -Projects $map

    $manifest = [pscustomobject]@{ release_id = 'r1'; projects = [pscustomobject] $manifestProjects }
    $metadata = Get-D365ReleaseMetadata -EnvironmentRoot $environmentRoot -Manifest $manifest
    Assert-True ($metadata.Count -eq 3) 'Release metadata count is wrong.'
    Assert-True (@($metadata.Values | Where-Object release_id -cne 'r1').Count -eq 0) 'Release metadata lost release ID.'

    $financeMetadata = Join-Path $environmentRoot 'finance_report\.deployment\current-release.json'
    $tampered = Get-Content $financeMetadata -Raw | ConvertFrom-Json
    $tampered.git_sha = '0' * 40
    $tampered | ConvertTo-Json | Set-Content $financeMetadata
    try {
        Get-D365ReleaseMetadata -EnvironmentRoot $environmentRoot -Manifest $manifest | Out-Null
        throw 'Mismatched release metadata was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'SHA') { throw }
    }

    Set-Content (Join-Path $sourceParent 'finance_report\dirty.txt') 'dirty'
    try {
        Assert-D365CleanReleaseRepositories -Projects $map
        throw 'Dirty repository was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'clean') { throw }
    }
    Remove-Item (Join-Path $sourceParent 'finance_report\dirty.txt') -Force

    $riskRepo = Join-Path $testRoot 'risk-repo'
    New-Item -ItemType Directory $riskRepo | Out-Null
    & git -C $riskRepo init --quiet
    & git -C $riskRepo config core.autocrlf false
    & git -C $riskRepo config user.email 'test@example.invalid'
    & git -C $riskRepo config user.name 'Test'
    Set-Content (Join-Path $riskRepo 'app.php') 'base'
    & git -C $riskRepo add .
    & git -C $riskRepo commit --quiet -m base
    $baseSha = (& git -C $riskRepo rev-parse HEAD).Trim()

    Set-Content (Join-Path $riskRepo 'app.php') 'code-only'
    & git -C $riskRepo add .
    & git -C $riskRepo commit --quiet -m code
    $codeSha = (& git -C $riskRepo rev-parse HEAD).Trim()

    New-Item -ItemType Directory (Join-Path $riskRepo 'database\migrations') -Force | Out-Null
    Set-Content (Join-Path $riskRepo 'database\migrations\006_test.sql') 'SELECT 1;'
    & git -C $riskRepo add .
    & git -C $riskRepo commit --quiet -m migration
    $migrationSha = (& git -C $riskRepo rev-parse HEAD).Trim()

    Set-Content (Join-Path $riskRepo 'composer.lock') '{}'
    & git -C $riskRepo add .
    & git -C $riskRepo commit --quiet -m operational
    $operationalSha = (& git -C $riskRepo rev-parse HEAD).Trim()

    Assert-True ((Get-D365ReleaseRisk -RepositoryRoot $riskRepo -FromSha $baseSha -ToSha $codeSha).Kind -ceq 'CodeOnly') 'PHP-only change was not CodeOnly.'
    Assert-True ((Get-D365ReleaseRisk -RepositoryRoot $riskRepo -FromSha $codeSha -ToSha $migrationSha).Kind -ceq 'Migration') 'Migration change was not Migration.'
    Assert-True ((Get-D365ReleaseRisk -RepositoryRoot $riskRepo -FromSha $migrationSha -ToSha $operationalSha).Kind -ceq 'Operational') 'Composer lock change was not Operational.'

    Assert-D365Approval -Expected 'APPROVE UAT r1' -Actual 'APPROVE UAT r1'
    try {
        Assert-D365Approval -Expected 'APPROVE UAT r1' -Actual 'approve uat r1'
        throw 'Case-insensitive approval was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'approval') { throw }
    }

    $releaseRoot = Join-Path $testRoot 'releases'
    New-Item -ItemType Directory -Path $releaseRoot | Out-Null
    Assert-Equal '2026-08-02.1' (Get-D365NextReleaseId -ReleaseRoot $releaseRoot -Now ([datetime]'2026-08-02')) 'First daily release ID is wrong.'
    Set-Content -LiteralPath (Join-Path $releaseRoot '2026-08-02.1.json') '{}'
    Set-Content -LiteralPath (Join-Path $releaseRoot '2026-08-02.3.json') '{}'
    Set-Content -LiteralPath (Join-Path $releaseRoot '2026-08-01.99.json') '{}'
    Set-Content -LiteralPath (Join-Path $releaseRoot '2026-08-02.bad.json') '{}'
    Assert-Equal '2026-08-02.4' (Get-D365NextReleaseId -ReleaseRoot $releaseRoot -Now ([datetime]'2026-08-02')) 'Daily release sequence did not use the highest valid number.'

    $currentUatRoot = Join-Path $testRoot 'current-uat'
    foreach ($project in $projects) {
        $metadataDirectory = Join-Path $currentUatRoot "$project\.deployment"
        New-Item -ItemType Directory -Path $metadataDirectory -Force | Out-Null
        [ordered]@{release_id='2026-08-02.4';environment='UAT';project=$project;git_sha=('a'*40)} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $metadataDirectory 'current-release.json') -Encoding UTF8
    }
    Assert-Equal '2026-08-02.4' (Get-D365CurrentUatReleaseId -UatRoot $currentUatRoot) 'Common UAT release was not selected.'
    $mismatchedPath = Join-Path $currentUatRoot 'finance_report\.deployment\current-release.json'
    $mismatched = Get-Content -LiteralPath $mismatchedPath -Raw | ConvertFrom-Json
    $mismatched.release_id = '2026-08-02.3'
    $mismatched | ConvertTo-Json | Set-Content -LiteralPath $mismatchedPath -Encoding UTF8
    try {
        Get-D365CurrentUatReleaseId -UatRoot $currentUatRoot | Out-Null
        throw 'Mismatched UAT releases were accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'คนละ Release') { throw }
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'Shared release state checks passed.'
