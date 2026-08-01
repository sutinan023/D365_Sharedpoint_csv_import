$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_security.ps1')

$script:D365ProjectNames = @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')

function Get-D365ProjectMap {
    param(
        [Parameter(Mandatory = $true)][string] $SourceParent,
        [Parameter(Mandatory = $true)][string] $EnvironmentRoot
    )

    $map = [ordered]@{}
    foreach ($project in $script:D365ProjectNames) {
        $map[$project] = [pscustomobject]@{
            Project = $project
            SourceRoot = [IO.Path]::GetFullPath((Join-Path $SourceParent $project)).TrimEnd('\')
            DestinationRoot = [IO.Path]::GetFullPath((Join-Path $EnvironmentRoot $project)).TrimEnd('\')
        }
    }
    return $map
}

function Assert-D365CleanReleaseRepositories {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary] $Projects)

    $actualNames = @($Projects.Keys | Sort-Object)
    $expectedNames = @($script:D365ProjectNames | Sort-Object)
    if (($actualNames -join "`n") -cne ($expectedNames -join "`n")) {
        throw 'Release project map must contain exactly the three approved projects.'
    }

    foreach ($project in $script:D365ProjectNames) {
        $root = [string] $Projects[$project].SourceRoot
        if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
            & git -C $root rev-parse --git-dir *> $null
            if ($LASTEXITCODE -ne 0) { throw "Source is not a Git repository: $project" }
        }
        $dirty = (& git -C $root status --porcelain --untracked-files=all | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $dirty -ne '') {
            throw "Repository must be clean before release: $project"
        }
    }
}

function Get-D365ManifestProjects([object] $Manifest) {
    if ($null -eq $Manifest -or $null -eq $Manifest.projects) {
        throw 'Release manifest has no projects.'
    }
    $properties = @($Manifest.projects.PSObject.Properties)
    $actualNames = @($properties.Name | Sort-Object)
    $expectedNames = @($script:D365ProjectNames | Sort-Object)
    if (($actualNames -join "`n") -cne ($expectedNames -join "`n")) {
        throw 'Release manifest project set is invalid.'
    }
    return $properties
}

function Get-D365ReleaseMetadata {
    param(
        [Parameter(Mandatory = $true)][string] $EnvironmentRoot,
        [Parameter(Mandatory = $true)][object] $Manifest
    )

    $manifestProjects = Get-D365ManifestProjects $Manifest
    $metadata = [ordered]@{}
    foreach ($project in $script:D365ProjectNames) {
        $path = Join-Path $EnvironmentRoot "$project\.deployment\current-release.json"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Release metadata is missing for $project"
        }
        $snapshot = Read-D365StrictJsonSnapshot $path "Release metadata for $project"
        $value = $snapshot.Value
        $expectedSha = [string] $Manifest.projects.$project.git_sha
        if ([string] $value.project -cne $project) { throw "Release metadata project mismatch: $project" }
        if ([string] $value.release_id -cne [string] $Manifest.release_id) { throw "Release metadata release mismatch: $project" }
        if ([string] $value.git_sha -cne $expectedSha) { throw "Release metadata SHA mismatch: $project" }
        if ([string] $value.environment -notin @('UAT', 'PRODUCTION')) { throw "Release metadata environment is invalid: $project" }
        $metadata[$project] = $value
    }
    return $metadata
}

function Get-D365ReleaseRisk {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $FromSha,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string] $ToSha
    )

    foreach ($sha in @($FromSha, $ToSha)) {
        & git -C $RepositoryRoot cat-file -e "$sha^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Release risk SHA is not a commit: $sha" }
    }

    $changedPaths = @(& git -C $RepositoryRoot -c core.quotepath=false diff --name-only $FromSha $ToSha)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect release risk paths.' }
    $changedPaths = @($changedPaths | ForEach-Object { $_.Replace('\', '/') } | Where-Object { $_ -ne '' } | Sort-Object -Unique)

    $operationalPaths = @($changedPaths | Where-Object {
        $_ -in @('.env.example', 'composer.json', 'composer.lock', 'install_task_scheduler.ps1', 'uninstall_task_scheduler.ps1', '.htaccess', 'tools/release_security.ps1') -or
        $_ -like 'config/*' -or $_ -like 'deployment/*'
    })
    $migrationPaths = @($changedPaths | Where-Object { $_ -match '^database/migrations/[^/]+\.sql$' })

    $kind = if ($operationalPaths.Count -gt 0) { 'Operational' }
        elseif ($migrationPaths.Count -gt 0) { 'Migration' }
        else { 'CodeOnly' }

    [pscustomobject]@{
        Kind = $kind
        ChangedPaths = $changedPaths
        MigrationPaths = $migrationPaths
        OperationalPaths = $operationalPaths
    }
}

function Assert-D365Approval {
    param(
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Actual
    )

    if ($Actual -cne $Expected) {
        throw "Release approval phrase did not match. Expected: $Expected"
    }
}
