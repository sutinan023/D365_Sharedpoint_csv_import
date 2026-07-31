param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('UAT', 'Production')]
    [string] $Environment,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $ReleaseId,

    [string] $ProjectRoot,
    [string] $BackupRoot = 'C:\xampp\backups\d365',
    [int] $RetentionDays = 30,
    [string] $ApprovalToken,
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
$segment = if ($Environment -eq 'UAT') { 'uat' } else { 'prod' }
$database = if ($Environment -eq 'UAT') { 'D365_finance' } else { 'D365_finance_prod' }
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = "C:\xampp\htdocs\$segment\D365_Sharedpoint_csv_import"
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$environmentBackupRoot = Join-Path $BackupRoot $segment
$backupFile = Join-Path $environmentBackupRoot "${database}_${ReleaseId}_${timestamp}.sql"
$plan = [ordered]@{
    environment = $Environment
    database = $database
    release_id = $ReleaseId
    backup_file = $backupFile
    retention_days = $RetentionDays
    requires_restore_rehearsal = $true
}

if ($PlanOnly) {
    $plan | ConvertTo-Json
    return
}

$environmentLabel = if ($Environment -eq 'UAT') { 'UAT' } else { 'PRODUCTION' }
$expectedApproval = "CHECKPOINT $environmentLabel $ReleaseId"
if ([string]::IsNullOrWhiteSpace($ApprovalToken)) {
    $ApprovalToken = Read-Host "Type $expectedApproval to create the database checkpoint"
}
if ($ApprovalToken -cne $expectedApproval) {
    throw 'Database checkpoint approval token did not match.'
}

$envPath = Join-Path $ProjectRoot 'config\.env'
if (-not (Test-Path -LiteralPath $envPath)) {
    throw "Environment file not found: $envPath"
}

$values = @{}
foreach ($line in Get-Content -LiteralPath $envPath) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
        $values[$matches[1]] = $matches[2].Trim().Trim('"').Trim("'")
    }
}
if ($values.APP_ENV.ToUpperInvariant() -cne $environmentLabel -or $values.DB_NAME -cne $database) {
    throw 'Environment guard rejected the database checkpoint configuration.'
}
foreach ($key in @('DB_HOST', 'DB_NAME', 'BACKUP_DB_USER', 'BACKUP_DB_PASS')) {
    if ([string]::IsNullOrWhiteSpace($values[$key])) {
        throw "$key is required for backup."
    }
}

$dumpExecutable = 'C:\xampp\mysql\bin\mysqldump.exe'
if (-not (Test-Path -LiteralPath $dumpExecutable)) {
    throw "mysqldump not found: $dumpExecutable"
}

New-Item -ItemType Directory -Path $environmentBackupRoot -Force | Out-Null
$previousPassword = $env:MYSQL_PWD
try {
    $env:MYSQL_PWD = $values.BACKUP_DB_PASS
    $process = Start-Process -FilePath $dumpExecutable -Wait -PassThru -NoNewWindow -ArgumentList @(
        "--host=$($values.DB_HOST)",
        "--user=$($values.BACKUP_DB_USER)",
        '--single-transaction',
        '--routines',
        '--triggers',
        '--events',
        "--result-file=$backupFile",
        $values.DB_NAME
    )
    if ($process.ExitCode -ne 0) {
        throw "mysqldump failed with exit code $($process.ExitCode)."
    }
}
finally {
    $env:MYSQL_PWD = $previousPassword
}

if (-not (Test-Path -LiteralPath $backupFile) -or (Get-Item -LiteralPath $backupFile).Length -eq 0) {
    throw 'Database checkpoint file is missing or empty.'
}

[pscustomobject]@{
    database = $database
    release_id = $ReleaseId
    created_at = (Get-Date).ToString('o')
    backup_file = (Resolve-Path -LiteralPath $backupFile).Path
    sha256 = (Get-FileHash -LiteralPath $backupFile -Algorithm SHA256).Hash
    size_bytes = (Get-Item -LiteralPath $backupFile).Length
    restore_receipt_file = "$backupFile.restore-approved.json"
} | ConvertTo-Json | Set-Content -LiteralPath "$backupFile.json" -Encoding UTF8

$cutoff = (Get-Date).AddDays(-$RetentionDays)
foreach ($expiredBackup in Get-ChildItem -LiteralPath $environmentBackupRoot -File -Filter '*.sql' | Where-Object LastWriteTime -lt $cutoff) {
    foreach ($expiredPath in @($expiredBackup.FullName, "$($expiredBackup.FullName).json", "$($expiredBackup.FullName).restore-approved.json")) {
        if (Test-Path -LiteralPath $expiredPath -PathType Leaf) {
            Remove-Item -LiteralPath $expiredPath -Force
        }
    }
}

$plan | ConvertTo-Json
