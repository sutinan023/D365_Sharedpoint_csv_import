param(
    [Parameter(Mandatory = $true)]
    [string] $BackupPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string] $ExpectedSourceSha256,

    [Parameter(Mandatory = $true)]
    [string] $SourceDatabase,

    [Parameter(Mandatory = $true)]
    [string] $RehearsalDatabase,

    [Parameter(Mandatory = $true)]
    [string] $OutputPath,

    [Parameter(Mandatory = $true)]
    [ValidateRange(0, [int]::MaxValue)]
    [int] $ExpectedDefinerCount,

    [Parameter(Mandatory = $true)]
    [ValidateRange(0, [int]::MaxValue)]
    [int] $ExpectedQualifiedReferenceCount
)

$ErrorActionPreference = 'Stop'

function Assert-SafeDatabaseName {
    param([string] $Name, [string] $Label)

    if ($Name -notmatch '^[A-Za-z0-9_]+$') {
        throw "$Label database name is unsafe."
    }
}

Assert-SafeDatabaseName -Name $SourceDatabase -Label 'Source'
Assert-SafeDatabaseName -Name $RehearsalDatabase -Label 'Rehearsal'
if ($SourceDatabase -ceq $RehearsalDatabase) {
    throw 'Source and rehearsal database names must be different.'
}

$sourceFullPath = [IO.Path]::GetFullPath($BackupPath)
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
if ($sourceFullPath -ceq $outputFullPath) {
    throw 'Source backup and sanitized output paths must be different.'
}
if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Leaf)) {
    throw "Source backup was not found: $sourceFullPath"
}
if (Test-Path -LiteralPath $outputFullPath) {
    throw "Sanitized output already exists and is immutable: $outputFullPath"
}

$actualSourceHash = (Get-FileHash -LiteralPath $sourceFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSourceHash -cne $ExpectedSourceSha256.ToLowerInvariant()) {
    throw 'Source backup hash does not match the expected SHA-256 value.'
}

$sourceText = [IO.File]::ReadAllText($sourceFullPath)
if ($sourceText -match '(?i)\bCREATE\s+DATABASE\b|\bUSE\s+(?:`[^`]+`|[A-Za-z0-9_]+)\b') {
    throw 'Source dump contains CREATE DATABASE or USE statements and cannot be isolated safely.'
}

$definerPattern = '(?is)\bDEFINER\s*=\s*`[^`]+`\s*@\s*`[^`]+`\s+SQL\s+SECURITY\s+DEFINER\b'
$sourceQualifierPattern = '`' + [regex]::Escape($SourceDatabase) + '`\.'
$definerCount = ([regex]::Matches($sourceText, $definerPattern)).Count
$qualifiedReferenceCount = ([regex]::Matches($sourceText, $sourceQualifierPattern)).Count
if ($definerCount -ne $ExpectedDefinerCount) {
    throw "Unexpected definer count: expected $ExpectedDefinerCount, found $definerCount."
}
if ($qualifiedReferenceCount -ne $ExpectedQualifiedReferenceCount) {
    throw "Unexpected qualified reference count: expected $ExpectedQualifiedReferenceCount, found $qualifiedReferenceCount."
}

$sanitizedText = [regex]::Replace($sourceText, $definerPattern, 'SQL SECURITY INVOKER')
$sanitizedText = [regex]::Replace($sanitizedText, $sourceQualifierPattern, ('`' + $RehearsalDatabase + '`.'))

$rehearsalQualifierPattern = '`' + [regex]::Escape($RehearsalDatabase) + '`\.'
if ($sanitizedText -match '(?i)\bDEFINER\s*=|\bSQL\s+SECURITY\s+DEFINER\b') {
    throw 'Sanitized dump retained a definer security clause.'
}
if (($sourceText -ne $sanitizedText) -and $sanitizedText -match $sourceQualifierPattern) {
    throw 'Sanitized dump retained a source database qualifier.'
}
if (([regex]::Matches($sanitizedText, '(?i)\bSQL\s+SECURITY\s+INVOKER\b')).Count -ne $ExpectedDefinerCount) {
    throw 'Sanitized dump has an unexpected INVOKER count.'
}
if (([regex]::Matches($sanitizedText, $rehearsalQualifierPattern)).Count -ne $ExpectedQualifiedReferenceCount) {
    throw 'Sanitized dump has an unexpected rehearsal qualifier count.'
}

$outputDirectory = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Output directory does not exist: $outputDirectory"
}
$utf8WithoutBom = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($outputFullPath, $sanitizedText, $utf8WithoutBom)
$sanitizedHash = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
$audit = [ordered]@{
    created_at = (Get-Date).ToUniversalTime().ToString('o')
    source_path = $sourceFullPath
    sanitized_path = $outputFullPath
    source_database = $SourceDatabase
    rehearsal_database = $RehearsalDatabase
    source_sha256 = $actualSourceHash
    sanitized_sha256 = $sanitizedHash
    source_size_bytes = (Get-Item -LiteralPath $sourceFullPath).Length
    sanitized_size_bytes = (Get-Item -LiteralPath $outputFullPath).Length
    definer_count = $definerCount
    qualified_reference_count = $qualifiedReferenceCount
}
[IO.File]::WriteAllText("$outputFullPath.audit.json", ($audit | ConvertTo-Json -Depth 4), $utf8WithoutBom)
Write-Output $outputFullPath
