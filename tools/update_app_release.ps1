[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('UAT', 'Production')]
    [string] $Environment,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string] $ReleaseId,

    [string] $EnvironmentRoot,
    [string] $AuditRoot = 'C:\xampp\backups\d365',
    [string] $ApprovalToken,
    [switch] $LocalTestMode
)

$ErrorActionPreference = 'Stop'

function Test-UnderSystemTemp {
    param([string] $Path)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    return $full.StartsWith($temp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-FileTextState {
    param([string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = [Text.UTF8Encoding]::new($false)
    $preamble = [byte[]]@()
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = [Text.UTF8Encoding]::new($false); $preamble = $bytes[0..2]; $offset = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.UnicodeEncoding]::new($false, $false); $preamble = $bytes[0..1]; $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.UnicodeEncoding]::new($true, $false); $preamble = $bytes[0..1]; $offset = 2
    }
    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    [pscustomobject]@{ Bytes = $bytes; Encoding = $encoding; Preamble = $preamble; Text = $text }
}

function Get-ConfigRecord {
    param([string] $Path, [string] $ExpectedEnvironment, [string] $ExpectedDatabase)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Environment file not found: $Path" }
    $state = Get-FileTextState -Path $Path
    $values = @{}
    foreach ($key in @('APP_ENV', 'APP_RELEASE', 'DB_NAME')) {
        $matches = [regex]::Matches($state.Text, "(?m)^\s*$key\s*=.*$")
        if ($matches.Count -ne 1) { throw "$key must appear exactly one time in every environment file." }
        $raw = $matches[0].Value -replace "^\s*$key\s*=\s*", ''
        $values[$key] = ($raw -replace '\s*(?:#.*)?$', '').Trim().Trim('"').Trim("'")
    }
    if ($values.APP_ENV.ToUpperInvariant() -cne $ExpectedEnvironment) { throw 'APP_ENV does not match the requested environment.' }
    if ($values.DB_NAME -cne $ExpectedDatabase) { throw 'DB_NAME does not match the requested environment.' }
    [pscustomobject]@{ Path = [IO.Path]::GetFullPath($Path); State = $state; Release = $values.APP_RELEASE }
}

function Get-ReplacementBytes {
    param($Record, [string] $NewRelease)
    $linePattern = '(?m)^(\s*APP_RELEASE\s*=\s*)\S*(\s*(?:#.*)?)$'
    $updatedText = [regex]::Replace($Record.State.Text, $linePattern, ('${1}' + $NewRelease + '${2}'), 1)
    if ($updatedText -ceq $Record.State.Text) { throw 'APP_RELEASE line could not be updated safely.' }
    $body = $Record.State.Encoding.GetBytes($updatedText)
    if ($Record.State.Preamble.Length -eq 0) { return $body }
    $combined = New-Object byte[] ($Record.State.Preamble.Length + $body.Length)
    [Array]::Copy($Record.State.Preamble, 0, $combined, 0, $Record.State.Preamble.Length)
    [Array]::Copy($body, 0, $combined, $Record.State.Preamble.Length, $body.Length)
    return $combined
}

$segment = if ($Environment -eq 'UAT') { 'uat' } else { 'prod' }
$expectedEnvironment = if ($Environment -eq 'UAT') { 'UAT' } else { 'PRODUCTION' }
$expectedDatabase = if ($Environment -eq 'UAT') { 'D365_finance' } else { 'D365_finance_prod' }
if ([string]::IsNullOrWhiteSpace($EnvironmentRoot)) { $EnvironmentRoot = "C:\xampp\htdocs\$segment" }
$environmentRootFull = [IO.Path]::GetFullPath($EnvironmentRoot)
$auditRootFull = [IO.Path]::GetFullPath($AuditRoot)
if ($LocalTestMode -and ((-not (Test-UnderSystemTemp $environmentRootFull)) -or (-not (Test-UnderSystemTemp $auditRootFull)))) {
    throw 'LocalTestMode requires EnvironmentRoot and AuditRoot under the system temporary directory.'
}
$expectedApproval = "UPDATE $expectedEnvironment APP_RELEASE $ReleaseId"
if ([string]::IsNullOrWhiteSpace($ApprovalToken)) { $ApprovalToken = Read-Host "Type $expectedApproval to update APP_RELEASE" }
if ($ApprovalToken -cne $expectedApproval) { throw 'APP_RELEASE update approval token did not match.' }

$records = @()
foreach ($project in @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')) {
    $records += Get-ConfigRecord -Path (Join-Path $environmentRootFull "$project\config\.env") -ExpectedEnvironment $expectedEnvironment -ExpectedDatabase $expectedDatabase
}
$oldReleases = @($records | ForEach-Object Release | Select-Object -Unique)
if ($oldReleases.Count -ne 1) { throw 'Current APP_RELEASE values must be identical across all projects.' }
$oldRelease = $oldReleases[0]
if ($oldRelease -ceq $ReleaseId) {
    [pscustomobject]@{ status = 'NO_CHANGE'; environment = $Environment; release_id = $ReleaseId; old_release = $oldRelease; audit_file = $null } | ConvertTo-Json -Compress
    return
}

$updates = @($records | ForEach-Object {
    [pscustomobject]@{ Record = $_; NewBytes = Get-ReplacementBytes -Record $_ -NewRelease $ReleaseId; BeforeHash = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create().ComputeHash($_.State.Bytes))).Replace('-', '').ToLowerInvariant()) }
})
$timestamp = Get-Date
$auditFile = Join-Path $auditRootFull ("app-release-update-{0}-{1}.json" -f $segment, $timestamp.ToString('yyyyMMdd-HHmmssfff'))
$written = @()
try {
    New-Item -ItemType Directory -Path $auditRootFull -Force | Out-Null
    foreach ($update in $updates) {
        [IO.File]::WriteAllBytes($update.Record.Path, $update.NewBytes)
        $afterHash = (Get-FileHash -LiteralPath $update.Record.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedHash = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create().ComputeHash($update.NewBytes))).Replace('-', '').ToLowerInvariant())
        if ($afterHash -cne $expectedHash) { throw 'APP_RELEASE write verification failed.' }
        $update | Add-Member -NotePropertyName AfterHash -NotePropertyValue $afterHash
        $written += $update
    }
    $audit = [ordered]@{ status = 'UPDATED'; environment = $Environment; release_id = $ReleaseId; updated_at = $timestamp.ToString('o'); operator = $env:USERNAME; old_release = $oldRelease; files = @($updates | ForEach-Object { [ordered]@{ path = $_.Record.Path; old_release = $_.Record.Release; new_release = $ReleaseId; sha256_before = $_.BeforeHash; sha256_after = $_.AfterHash } }) }
    [IO.File]::WriteAllText($auditFile, ($audit | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ status = 'UPDATED'; environment = $Environment; release_id = $ReleaseId; old_release = $oldRelease; audit_file = $auditFile } | ConvertTo-Json -Compress
}
catch {
    foreach ($update in $written) { [IO.File]::WriteAllBytes($update.Record.Path, $update.Record.State.Bytes) }
    if (Test-Path -LiteralPath $auditFile -PathType Leaf) { Remove-Item -LiteralPath $auditFile -Force }
    throw
}
