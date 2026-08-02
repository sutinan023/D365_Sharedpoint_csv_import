param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ReleaseId,

    [string] $SourceParent = 'C:\xampp\htdocs',
    [string] $SharePointRoot,
    [string] $FileImporterRoot,
    [string] $FinanceReportRoot,
    [string] $OutputPath,
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
$projectNames = @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')
$projectRoots = @{
    D365_Sharedpoint_csv_import = if ($SharePointRoot) { $SharePointRoot } else { Join-Path $SourceParent 'D365_Sharedpoint_csv_import' }
    D365_file_csv_import = if ($FileImporterRoot) { $FileImporterRoot } else { Join-Path $SourceParent 'D365_file_csv_import' }
    finance_report = if ($FinanceReportRoot) { $FinanceReportRoot } else { Join-Path $SourceParent 'finance_report' }
}
$projects = [ordered]@{}
$migrations = [ordered]@{}

function Get-CommittedMigrationFiles {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectRoot,
        [Parameter(Mandatory = $true)][string] $Head
    )

    $paths = @(& git -C $ProjectRoot ls-tree -r --name-only $Head -- database/migrations)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect committed migrations in $ProjectRoot"
    }

    return @($paths |
        Where-Object { $_ -match '^database/migrations/[^/]+\.sql$' } |
        ForEach-Object { Split-Path -Leaf $_ } |
        Sort-Object)
}

foreach ($projectName in $projectNames) {
    $projectRoot = $projectRoots[$projectName]
    $dirty = (& git -C $projectRoot status --porcelain --untracked-files=all | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to inspect Git status for $projectName"
    }
    if ($dirty -ne '') {
        throw "Repository must be clean before creating a release manifest: $projectName"
    }
    $sha = (& git -C $projectRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sha -notmatch '^[0-9a-f]{40}$') {
        throw "Unable to resolve Git SHA for $projectName"
    }
    $projects[$projectName] = [ordered]@{ git_sha = $sha }
    $migrations[$projectName] = @(Get-CommittedMigrationFiles -ProjectRoot $projectRoot -Head $sha)
}

$manifest = [ordered]@{
    release_id = $ReleaseId
    created_at = (Get-Date).ToString('o')
    projects = $projects
    migrations = $migrations
}

$json = $manifest | ConvertTo-Json -Depth 6
if ($PlanOnly) {
    $json
    return
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $PSScriptRoot) "deployment\releases\$ReleaseId.json"
}
$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
try {
    $stream = [IO.FileStream]::new($OutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
} catch [IO.IOException] {
    throw "Release manifest already exists and is immutable: $OutputPath"
}
Write-Output $OutputPath
