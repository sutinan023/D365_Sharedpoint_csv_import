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

function Assert-NoReparsePointComponent {
    param([string] $Path, [switch] $AllowMissingLeaf)

    $current = [IO.Path]::GetFullPath($Path)
    if ($AllowMissingLeaf -and -not (Test-Path -LiteralPath $current)) {
        $current = Split-Path -Parent $current
    }
    while (-not [string]::IsNullOrWhiteSpace($current) -and (Test-Path -LiteralPath $current)) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Path contains a reparse-point component and is not safe: $current"
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Get-Sha256Hex {
    param([byte[]] $Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}

Assert-SafeDatabaseName -Name $SourceDatabase -Label 'Source'
Assert-SafeDatabaseName -Name $RehearsalDatabase -Label 'Rehearsal'
if ($SourceDatabase -ceq $RehearsalDatabase) {
    throw 'Source and rehearsal database names must be different.'
}

$sourceFullPath = [IO.Path]::GetFullPath($BackupPath)
$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$auditFullPath = "$outputFullPath.audit.json"
if ($sourceFullPath -ieq $outputFullPath -or $sourceFullPath -ieq $auditFullPath) {
    throw 'Source backup and sanitized output paths must be different.'
}
if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Leaf)) {
    throw "Source backup was not found: $sourceFullPath"
}
Assert-NoReparsePointComponent -Path $sourceFullPath
Assert-NoReparsePointComponent -Path $outputFullPath -AllowMissingLeaf
if (Test-Path -LiteralPath $outputFullPath) {
    throw "Sanitized output already exists and is immutable: $outputFullPath"
}
if (Test-Path -LiteralPath $auditFullPath) {
    throw "Sanitized audit output already exists and is immutable: $auditFullPath"
}

$sourceBytes = [IO.File]::ReadAllBytes($sourceFullPath)
$actualSourceHash = Get-Sha256Hex -Bytes $sourceBytes
if ($actualSourceHash -cne $ExpectedSourceSha256.ToLowerInvariant()) {
    throw 'Source backup hash does not match the expected SHA-256 value.'
}
try {
    $sourceText = (New-Object Text.UTF8Encoding($false, $true)).GetString($sourceBytes)
} catch [Text.DecoderFallbackException] {
    throw 'Source backup must be valid UTF-8.'
}
if ($sourceText -match '(?i)\bCREATE\s+DATABASE\b|\bUSE\s+(?:`[^`]+`|[A-Za-z0-9_]+)\b') {
    throw 'Source dump contains CREATE DATABASE or USE statements and cannot be isolated safely.'
}
if ($sourceText -match '(?is)\bCREATE\b[^;]{0,1000}\b(?:TRIGGER|PROCEDURE|FUNCTION|EVENT)\b') {
    throw 'Source dump contains an executable database object and cannot be isolated safely.'
}

$definerPattern = '(?is)\bDEFINER\s*=\s*`[^`]+`\s*@\s*`[^`]+`\s+SQL\s+SECURITY\s+DEFINER\b'
$sourceQualifierPattern = '`' + [regex]::Escape($SourceDatabase) + '`\.'
$viewBlockPattern = '(?is)/\*!\d{5}\s+CREATE\s+ALGORITHM\b.*?\bVIEW\b.*?\*/;'
$viewBlocks = [regex]::Matches($sourceText, $viewBlockPattern)
$sqlStringPattern = "(?s)'(?:''|\\.|[^'\\])*'"
$sqlStrings = [regex]::Matches($sourceText, $sqlStringPattern)
function Test-MatchInsideRanges {
    param([Text.RegularExpressions.Match] $Match, [System.Collections.IEnumerable] $Ranges)

    foreach ($range in $Ranges) {
        if ($Match.Index -ge $range.Index -and ($Match.Index + $Match.Length) -le ($range.Index + $range.Length)) {
            return $true
        }
    }
    return $false
}
$allDefiners = @([regex]::Matches($sourceText, $definerPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sqlStrings) })
$allQualifiedReferences = @([regex]::Matches($sourceText, $sourceQualifierPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sqlStrings) })
$outsideDefiners = @($allDefiners | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $viewBlocks) })
$outsideQualifiedReferences = @($allQualifiedReferences | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $viewBlocks) })
if ($outsideDefiners.Count -ne 0 -or $outsideQualifiedReferences.Count -ne 0) {
    throw "Source dump contains a definer or source qualifier outside a recognized VIEW DDL block (views=$($viewBlocks.Count), outside_definers=$($outsideDefiners.Count), outside_qualifiers=$($outsideQualifiedReferences.Count))."
}
$definerCount = $allDefiners.Count
$qualifiedReferenceCount = $allQualifiedReferences.Count
if ($definerCount -ne $ExpectedDefinerCount) {
    throw "Unexpected definer count: expected $ExpectedDefinerCount, found $definerCount."
}
if ($qualifiedReferenceCount -ne $ExpectedQualifiedReferenceCount) {
    throw "Unexpected qualified reference count: expected $ExpectedQualifiedReferenceCount, found $qualifiedReferenceCount."
}

$textBuilder = New-Object Text.StringBuilder
$cursor = 0
foreach ($viewBlock in $viewBlocks) {
    [void] $textBuilder.Append($sourceText.Substring($cursor, $viewBlock.Index - $cursor))
    $sanitizedBlock = [regex]::Replace($viewBlock.Value, $definerPattern, 'SQL SECURITY INVOKER')
    $sanitizedBlock = [regex]::Replace($sanitizedBlock, $sourceQualifierPattern, ('`' + $RehearsalDatabase + '`.'))
    [void] $textBuilder.Append($sanitizedBlock)
    $cursor = $viewBlock.Index + $viewBlock.Length
}
[void] $textBuilder.Append($sourceText.Substring($cursor))
$sanitizedText = $textBuilder.ToString()

$rehearsalQualifierPattern = '`' + [regex]::Escape($RehearsalDatabase) + '`\.'
$sanitizedStrings = [regex]::Matches($sanitizedText, $sqlStringPattern)
$remainingDefiners = @([regex]::Matches($sanitizedText, '(?i)\bDEFINER\s*=|\bSQL\s+SECURITY\s+DEFINER\b') | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedStrings) })
$remainingSourceQualifiers = @([regex]::Matches($sanitizedText, $sourceQualifierPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedStrings) })
if ($remainingDefiners.Count -ne 0) {
    throw 'Sanitized dump retained a definer security clause.'
}
if ($remainingSourceQualifiers.Count -ne 0) {
    throw 'Sanitized dump retained a source database qualifier.'
}
if ((@([regex]::Matches($sanitizedText, '(?i)\bSQL\s+SECURITY\s+INVOKER\b') | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedStrings) })).Count -ne $ExpectedDefinerCount) {
    throw 'Sanitized dump has an unexpected INVOKER count.'
}
if ((@([regex]::Matches($sanitizedText, $rehearsalQualifierPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedStrings) })).Count -ne $ExpectedQualifiedReferenceCount) {
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
    source_size_bytes = $sourceBytes.Length
    sanitized_size_bytes = (Get-Item -LiteralPath $outputFullPath).Length
    definer_count = $definerCount
    qualified_reference_count = $qualifiedReferenceCount
}
[IO.File]::WriteAllText($auditFullPath, ($audit | ConvertTo-Json -Depth 4), $utf8WithoutBom)
Write-Output $outputFullPath
