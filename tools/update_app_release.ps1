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
$safeReleasePattern = '[A-Za-z0-9][A-Za-z0-9._-]{0,127}'
$effectiveTestFault = if ($LocalTestMode -and -not [string]::IsNullOrWhiteSpace($env:D365_APP_RELEASE_TEST_FAULT)) { $env:D365_APP_RELEASE_TEST_FAULT } else { 'None' }
if ($effectiveTestFault -notin @('None', 'AfterFirstWrite', 'AfterVerification', 'DuringAudit')) { throw 'Unknown TestFault value.' }

function Get-CanonicalPath {
    param([string] $Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-UnderSystemTemp {
    param([string] $Path)
    $temp = (Get-CanonicalPath ([IO.Path]::GetTempPath()))
    $full = Get-CanonicalPath $Path
    return $full.StartsWith($temp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Test-CanonicalPathEqual {
    param([string] $Left, [string] $Right)
    return [string]::Equals((Get-CanonicalPath $Left), (Get-CanonicalPath $Right), [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparseComponent {
    param([string] $Path)
    $cursor = Get-CanonicalPath $Path
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Path safety check rejected a reparse point or junction.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) { break }
        $cursor = $parent
    }
}

function Get-Sha256 {
    param([byte[]] $Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileTextState {
    param([string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $preamble = [byte[]]@()
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $preamble = $bytes[0..2]; $offset = 3
    }
    try { $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset) }
    catch [Text.DecoderFallbackException] { throw 'Environment file is not valid UTF-8.' }
    [pscustomobject]@{ Bytes = $bytes; Encoding = $encoding; Preamble = $preamble; Text = $text }
}

function Get-DotEnvScalar {
    param([string] $Line, [string] $Key)
    $prefix = [regex]::Match($Line, ('^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*'))
    if (-not $prefix.Success) { throw "$Key is not a valid dotenv assignment." }
    $scalar = $Line.Substring($prefix.Length)
    if ($scalar.StartsWith('"') -or $scalar.StartsWith("'")) {
        $quote = $scalar.Substring(0, 1)
        $quotedPattern = if ($quote -ceq '"') { '^"(?<value>[^"\\\r\n]*)"(?<suffix>[ \t]*(?:#.*)?)$' } else { "^'(?<value>[^'\\\r\n]*)'(?<suffix>[ \t]*(?:#.*)?)$" }
        $match = [regex]::Match($scalar, $quotedPattern)
        if (-not $match.Success) { throw "$Key must use paired quotes with no escapes or trailing content." }
    } else {
        $match = [regex]::Match($scalar, '^(?<value>[A-Za-z0-9._:/#-]+)(?<suffix>[ \t]*(?:#.*)?)$')
        if (-not $match.Success) { throw "$Key must contain one safe unquoted dotenv value." }
    }
    [pscustomobject]@{
        Value = $match.Groups['value'].Value
        ValueIndex = $prefix.Length + $match.Groups['value'].Index
        ValueLength = $match.Groups['value'].Length
    }
}

function Get-ConfigRecord {
    param([string] $Path, [string] $ExpectedEnvironment, [string] $ExpectedDatabase)
    Assert-NoReparseComponent $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Environment file not found: $Path" }
    $state = Get-FileTextState $Path
    $values = @{}
    $releaseValueIndex = $null
    $releaseValueLength = $null
    foreach ($key in @('APP_ENV', 'APP_RELEASE', 'DB_NAME')) {
        $matches = [regex]::Matches($state.Text, ("(?m)^[ \t]*" + [regex]::Escape($key) + "[ \t]*=[^\r\n]*"))
        if ($matches.Count -ne 1) { throw "$key must appear exactly one time in every environment file." }
        $lineMatch = $matches.Item(0)
        $scalar = Get-DotEnvScalar $lineMatch.Value $key
        $values[$key] = $scalar.Value
        if ($key -eq 'APP_RELEASE') {
            if ($scalar.Value -notmatch "^$safeReleasePattern$") { throw 'APP_RELEASE must contain exactly one safe release ID.' }
            $releaseValueIndex = $lineMatch.Index + $scalar.ValueIndex
            $releaseValueLength = $scalar.ValueLength
        }
    }
    if ($values.APP_ENV -cne $ExpectedEnvironment) { throw 'APP_ENV does not match the requested environment.' }
    if ($values.DB_NAME -cne $ExpectedDatabase) { throw 'DB_NAME does not match the requested environment.' }
    [pscustomobject]@{ Path = Get-CanonicalPath $Path; State = $state; Release = $values.APP_RELEASE; ReleaseValueIndex = $releaseValueIndex; ReleaseValueLength = $releaseValueLength }
}

function Get-ReplacementBytes {
    param($Record, [string] $NewRelease)
    $updatedText = $Record.State.Text.Substring(0, $Record.ReleaseValueIndex) + $NewRelease + $Record.State.Text.Substring($Record.ReleaseValueIndex + $Record.ReleaseValueLength)
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
$canonicalEnvironmentRoot = "C:\xampp\htdocs\$segment"
$canonicalAuditRoot = 'C:\xampp\backups\d365'
if ([string]::IsNullOrWhiteSpace($EnvironmentRoot)) { $EnvironmentRoot = $canonicalEnvironmentRoot }
$environmentRootFull = Get-CanonicalPath $EnvironmentRoot
$auditRootFull = Get-CanonicalPath $AuditRoot

if ($LocalTestMode) {
    if ((-not (Test-UnderSystemTemp $environmentRootFull)) -or (-not (Test-UnderSystemTemp $auditRootFull))) {
        throw 'LocalTestMode requires EnvironmentRoot and AuditRoot under the system temporary directory.'
    }
} else {
    if ((-not (Test-CanonicalPathEqual $environmentRootFull $canonicalEnvironmentRoot)) -or (-not (Test-CanonicalPathEqual $auditRootFull $canonicalAuditRoot))) {
        throw 'Normal mode requires the canonical environment and audit roots.'
    }
}
Assert-NoReparseComponent $environmentRootFull
Assert-NoReparseComponent $auditRootFull
if (-not (Test-Path -LiteralPath $environmentRootFull -PathType Container)) { throw 'Environment root not found.' }
if (-not (Test-Path -LiteralPath $auditRootFull -PathType Container)) { throw 'Audit root not found.' }

$expectedApproval = "UPDATE $expectedEnvironment APP_RELEASE $ReleaseId"
if ([string]::IsNullOrWhiteSpace($ApprovalToken)) { $ApprovalToken = Read-Host "Type $expectedApproval to update APP_RELEASE" }
if ($ApprovalToken -cne $expectedApproval) { throw 'APP_RELEASE update approval token did not match.' }

$lockPath = Join-Path $auditRootFull "app-release-update-$segment.lock"
$lockStream = $null
try {
    try {
        $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw 'Another APP_RELEASE updater is already running or the exclusive lock cannot be acquired.'
    }

    $environmentFiles = @(
        (Join-Path $environmentRootFull 'D365_Sharedpoint_csv_import\config\.env'),
        (Join-Path $environmentRootFull 'D365_file_csv_import\.env'),
        (Join-Path $environmentRootFull 'finance_report\.env')
    )
    $records = @()
    foreach ($environmentFile in $environmentFiles) {
        $records += Get-ConfigRecord -Path $environmentFile -ExpectedEnvironment $expectedEnvironment -ExpectedDatabase $expectedDatabase
    }
    $oldReleases = @($records | ForEach-Object Release | Select-Object -Unique)
    if ($oldReleases.Count -ne 1) { throw 'Current APP_RELEASE values must be identical across all projects.' }
    $oldRelease = $oldReleases[0]
    if ($oldRelease -ceq $ReleaseId) {
        [pscustomobject]@{ status = 'NO_CHANGE'; environment = $Environment; release_id = $ReleaseId; old_release = $oldRelease; audit_file = $null } | ConvertTo-Json -Compress
        return
    }

    $updates = @($records | ForEach-Object {
        [pscustomobject]@{ Record = $_; NewBytes = Get-ReplacementBytes $_ $ReleaseId; BeforeHash = Get-Sha256 $_.State.Bytes; AfterHash = $null }
    })
    $auditFile = Join-Path $auditRootFull ("app-release-update-{0}-{1}-{2}.json" -f $segment, (Get-Date -Format 'yyyyMMdd-HHmmssfff'), ([guid]::NewGuid().ToString('N')))
    $mutationStarted = $false
    try {
        for ($index = 0; $index -lt $updates.Count; $index++) {
            $mutationStarted = $true
            [IO.File]::WriteAllBytes($updates[$index].Record.Path, $updates[$index].NewBytes)
            if ($effectiveTestFault -ceq 'AfterFirstWrite' -and $index -eq 0) { throw 'Simulated failure after first write.' }
            $actualHash = (Get-FileHash -LiteralPath $updates[$index].Record.Path -Algorithm SHA256).Hash.ToLowerInvariant()
            $expectedHash = Get-Sha256 $updates[$index].NewBytes
            if ($actualHash -cne $expectedHash) { throw 'APP_RELEASE write verification failed.' }
            $updates[$index].AfterHash = $actualHash
        }
        if ($effectiveTestFault -ceq 'AfterVerification') { throw 'Simulated failure after write verification.' }

        $audit = [ordered]@{ status = 'UPDATED'; environment = $Environment; release_id = $ReleaseId; updated_at = (Get-Date).ToString('o'); operator = $env:USERNAME; old_release = $oldRelease; files = @($updates | ForEach-Object { [ordered]@{ path = $_.Record.Path; old_release = $_.Record.Release; new_release = $ReleaseId; sha256_before = $_.BeforeHash; sha256_after = $_.AfterHash } }) }
        $auditBytes = [Text.UTF8Encoding]::new($false).GetBytes(($audit | ConvertTo-Json -Depth 5))
        $auditStream = [IO.File]::Open($auditFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            if ($effectiveTestFault -ceq 'DuringAudit') {
                $auditStream.Write($auditBytes, 0, [Math]::Min(16, $auditBytes.Length))
                throw 'Simulated failure during audit write.'
            }
            $auditStream.Write($auditBytes, 0, $auditBytes.Length)
            $auditStream.Flush($true)
        } finally { $auditStream.Dispose() }

        [pscustomobject]@{ status = 'UPDATED'; environment = $Environment; release_id = $ReleaseId; old_release = $oldRelease; audit_file = $auditFile } | ConvertTo-Json -Compress
    } catch {
        $failure = $_
        if ($mutationStarted) {
            $rollbackErrors = @()
            foreach ($update in $updates) {
                try { [IO.File]::WriteAllBytes($update.Record.Path, $update.Record.State.Bytes) }
                catch { $rollbackErrors += $update.Record.Path }
            }
            if (Test-Path -LiteralPath $auditFile -PathType Leaf) {
                try { Remove-Item -LiteralPath $auditFile -Force } catch { $rollbackErrors += $auditFile }
            }
            if ($rollbackErrors.Count -gt 0) { throw 'APP_RELEASE update failed and rollback could not restore every target.' }
        }
        throw $failure
    }
}
finally {
    if ($null -ne $lockStream) { $lockStream.Dispose() }
}
