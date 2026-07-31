param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('UAT', 'Production')]
    [string] $Environment,
    [Parameter(Mandatory = $true)]
    [string] $ApacheIdentity,
    [Parameter(Mandatory = $true)]
    [string] $SchedulerIdentity,
    [string] $AdminIdentity = "$env:USERDOMAIN\$env:USERNAME",
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
$segment = if ($Environment -eq 'UAT') { 'uat' } else { 'prod' }
$environmentRoot = "C:\xampp\htdocs\$segment"
$projects = @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')
$directories = [Collections.Generic.List[string]]::new()

foreach ($project in $projects) {
    $projectRoot = Join-Path $environmentRoot $project
    $directories.Add($projectRoot)
    foreach ($runtime in @('import', 'download', 'archive', 'processed', 'error', 'logs', 'temp')) {
        $directories.Add((Join-Path $projectRoot $runtime))
    }
}
$directories.Add("C:\xampp\statement_storage\$segment\statement_imports")

$plan = [ordered]@{
    environment = $Environment
    root = $environmentRoot
    apache_identity = $ApacheIdentity
    scheduler_identity = $SchedulerIdentity
    admin_identity = $AdminIdentity
    directories = $directories
    env_files = @($projects | ForEach-Object { Join-Path (Join-Path $environmentRoot $_) '.env' })
}
if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 4
    return
}

foreach ($directory in $directories) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

foreach ($envFile in $plan.env_files) {
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        Write-Warning "Create and review the environment file before ACL hardening: $envFile"
        continue
    }
    & icacls.exe $envFile /inheritance:r /grant:r "${ApacheIdentity}:(R)" "${SchedulerIdentity}:(R)" "${AdminIdentity}:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to apply ACL to $envFile"
    }
}

$plan | ConvertTo-Json -Depth 4
