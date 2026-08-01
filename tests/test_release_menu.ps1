$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\release.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('release-menu-{0}' -f [guid]::NewGuid())
$sourceParent = Join-Path $testRoot 'source'
$uatRoot = Join-Path $testRoot 'uat'
$productionRoot = Join-Path $testRoot 'prod'
$releaseRoot = Join-Path $testRoot 'releases'
$projects = @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function New-TestRepository([string] $Path, [string] $Project) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'app.php') -Value "<?php echo '$Project';"
    Set-Content -LiteralPath (Join-Path $Path 'same.php') -Value '<?php echo "same";'
    & git -C $Path init --quiet
    & git -C $Path config core.autocrlf false
    & git -C $Path config user.email 'test@example.invalid'
    & git -C $Path config user.name 'Test'
    & git -C $Path add .
    & git -C $Path commit --quiet -m initial
    return (& git -C $Path rev-parse HEAD).Trim()
}

try {
    New-Item -ItemType Directory -Path $sourceParent, $uatRoot, $productionRoot, $releaseRoot -Force | Out-Null
    $manifestProjects = [ordered]@{}
    foreach ($project in $projects) {
        $source = Join-Path $sourceParent $project
        $sha = New-TestRepository -Path $source -Project $project
        $manifestProjects[$project] = [ordered]@{ git_sha = $sha }
        foreach ($environmentRoot in @($uatRoot, $productionRoot)) {
            $destination = Join-Path $environmentRoot $project
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $source 'same.php') -Destination (Join-Path $destination 'same.php')
        }
    }

    $plan = @(& $scriptPath -Action DeployUAT -ReleaseId '2026-08-01.1' `
        -SourceParent $sourceParent -UatRoot $uatRoot -ProductionRoot $productionRoot `
        -ReleaseRoot $releaseRoot -PlanOnly -LocalTestMode)
    Assert-True (@($plan | Where-Object { $_ -is [string] -and $_ -match 'แผน Deploy UAT' }).Count -eq 1) 'Thai UAT plan heading is missing.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $releaseRoot '2026-08-01.1.json'))) 'PlanOnly wrote a release manifest.'
    foreach ($project in $projects) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $uatRoot "$project\app.php"))) 'PlanOnly copied a source file.'
    }

    try {
        & $scriptPath -Action DeployUAT -ReleaseId 'bad release id' -SourceParent $sourceParent `
            -UatRoot $uatRoot -ProductionRoot $productionRoot -ReleaseRoot $releaseRoot -PlanOnly -LocalTestMode | Out-Null
        throw 'Invalid release ID was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'ReleaseId|pattern') { throw }
    }

    $missingParent = Join-Path $testRoot 'missing-source'
    try {
        & $scriptPath -Action DeployUAT -ReleaseId '2026-08-01.2' -SourceParent $missingParent `
            -UatRoot $uatRoot -ProductionRoot $productionRoot -ReleaseRoot $releaseRoot -PlanOnly -LocalTestMode | Out-Null
        throw 'Missing project directories were accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'not found|ไม่พบ') { throw }
    }

    $manifest = [ordered]@{
        release_id = '2026-08-01.3'
        created_at = (Get-Date).ToString('o')
        projects = $manifestProjects
        migrations = [ordered]@{
            D365_Sharedpoint_csv_import = @()
            D365_file_csv_import = @()
            finance_report = @()
        }
    }
    $manifestPath = Join-Path $releaseRoot '2026-08-01.3.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    foreach ($project in $projects) {
        $destination = Join-Path $uatRoot $project
        Set-Content -LiteralPath (Join-Path $destination 'app.php') -Value 'modified'
        Set-Content -LiteralPath (Join-Path $destination 'deleted.php') -Value 'destination-only'
        $metadataDirectory = Join-Path $destination '.deployment'
        New-Item -ItemType Directory -Path $metadataDirectory -Force | Out-Null
        [ordered]@{
            release_id = '2026-08-01.3'
            environment = 'UAT'
            project = $project
            git_sha = [string] $manifestProjects[$project].git_sha
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $metadataDirectory 'current-release.json') -Encoding UTF8
    }

    $comparison = @(& $scriptPath -Action Compare -ReleaseId '2026-08-01.3' `
        -SourceParent $sourceParent -UatRoot $uatRoot -ProductionRoot $productionRoot `
        -ReleaseRoot $releaseRoot -LocalTestMode | Where-Object { $_.PSObject.Properties.Name -contains 'Environment' })
    $uatResults = @($comparison | Where-Object Environment -ceq 'UAT')
    $productionResults = @($comparison | Where-Object Environment -ceq 'PRODUCTION')
    Assert-True ($uatResults.Count -eq 3) 'Compare did not return all UAT projects.'
    Assert-True ($productionResults.Count -eq 3) 'Compare did not return all Production projects.'
    foreach ($result in $uatResults) {
        Assert-True ($result.New -eq 0) "UAT New count mismatch: $($result.Project)"
        Assert-True ($result.Modified -eq 1) "UAT Modified count mismatch: $($result.Project)"
        Assert-True ($result.Deleted -eq 1) "UAT Deleted count mismatch: $($result.Project)"
    }
    foreach ($result in $productionResults) {
        Assert-True ($result.New -eq 1) "Production New count mismatch: $($result.Project)"
        Assert-True ($result.Modified -eq 0) "Production Modified count mismatch: $($result.Project)"
        Assert-True ($result.Deleted -eq 0) "Production Deleted count mismatch: $($result.Project)"
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'Thai release menu checks passed.'
