param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ReleaseId,

    [string] $SourceParent = 'C:\xampp\htdocs',
    [string] $OutputPath,
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
$projectNames = @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')
$projects = [ordered]@{}
foreach ($projectName in $projectNames) {
    $projectRoot = Join-Path $SourceParent $projectName
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
}

$manifest = [ordered]@{
    release_id = $ReleaseId
    created_at = (Get-Date).ToString('o')
    projects = $projects
    migrations = [ordered]@{
        D365_Sharedpoint_csv_import = @(
            '000_create_schema_migrations.sql',
            '001_create_sharepoint_file_queue.sql',
            '002_add_pending_archive_to_import_files_status.sql'
        )
        D365_file_csv_import = @()
        finance_report = @()
    }
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
$json | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output $OutputPath
