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

function Add-SqlLexicalSpans {
    param(
        [string] $Text,
        [int] $Start,
        [int] $End,
        [System.Collections.Generic.List[object]] $StringSpans,
        [System.Collections.Generic.List[object]] $ProtectedSpans
    )

    $index = $Start
    while ($index -lt $End) {
        $character = $Text[$index]
        if ($character -eq '/' -and ($index + 1) -lt $End -and $Text[$index + 1] -eq '*') {
            $commentEnd = $Text.IndexOf('*/', $index + 2, [StringComparison]::Ordinal)
            if ($commentEnd -lt 0 -or $commentEnd -ge $End) { throw 'Source dump contains an unterminated block comment.' }
            if (($index + 2) -lt $End -and $Text[$index + 2] -eq '!') {
                $contentStart = $index + 3
                while ($contentStart -lt $commentEnd -and [char]::IsDigit($Text[$contentStart])) { $contentStart++ }
                Add-SqlLexicalSpans -Text $Text -Start $contentStart -End $commentEnd -StringSpans $StringSpans -ProtectedSpans $ProtectedSpans
            } else {
                $span = [pscustomobject]@{ Index = $index; Length = ($commentEnd + 2 - $index) }
                [void] $ProtectedSpans.Add($span)
            }
            $index = $commentEnd + 2
            continue
        }
        if ($character -eq '#' -or ($character -eq '-' -and ($index + 2) -lt $End -and $Text[$index + 1] -eq '-' -and [char]::IsWhiteSpace($Text[$index + 2]))) {
            $commentStart = $index
            while ($index -lt $End -and $Text[$index] -ne "`r" -and $Text[$index] -ne "`n") { $index++ }
            [void] $ProtectedSpans.Add([pscustomobject]@{ Index = $commentStart; Length = ($index - $commentStart) })
            continue
        }
        if ($character -eq '`') {
            $index++
            $closed = $false
            while ($index -lt $End) {
                if ($Text[$index] -eq '`') {
                    if (($index + 1) -lt $End -and $Text[$index + 1] -eq '`') {
                        $index += 2
                        continue
                    }
                    $index++
                    $closed = $true
                    break
                }
                $index++
            }
            if (-not $closed) { throw 'Source dump contains an unterminated backtick identifier.' }
            continue
        }
        if ($character -eq "'" -or $character -eq '"') {
            $quote = $character
            $stringStart = $index
            $index++
            $closed = $false
            while ($index -lt $End) {
                if ($Text[$index] -eq '\') {
                    $index += 2
                    continue
                }
                if ($Text[$index] -eq $quote) {
                    if (($index + 1) -lt $End -and $Text[$index + 1] -eq $quote) {
                        $index += 2
                        continue
                    }
                    $index++
                    $closed = $true
                    break
                }
                $index++
            }
            if (-not $closed) { throw 'Source dump contains an unterminated quoted string.' }
            $span = [pscustomobject]@{ Index = $stringStart; Length = ($index - $stringStart) }
            [void] $StringSpans.Add($span)
            [void] $ProtectedSpans.Add($span)
            continue
        }
        $index++
    }
}

function Get-SqlLexicalSpans {
    param([string] $Text)

    $stringSpans = New-Object 'System.Collections.Generic.List[object]'
    $protectedSpans = New-Object 'System.Collections.Generic.List[object]'
    Add-SqlLexicalSpans -Text $Text -Start 0 -End $Text.Length -StringSpans $stringSpans -ProtectedSpans $protectedSpans
    return [pscustomobject]@{ StringSpans = [object[]] $stringSpans.ToArray(); ProtectedSpans = [object[]] $protectedSpans.ToArray() }
}

$sourceLexicalSpans = Get-SqlLexicalSpans -Text $sourceText
if ($sourceText -match '(?i)\bCREATE\s+DATABASE\b|\bUSE\s+(?:`[^`]+`|[A-Za-z0-9_]+)\b') {
    throw 'Source dump contains CREATE DATABASE or USE statements and cannot be isolated safely.'
}
if ($sourceText -match '(?is)\b(?:CREATE|DROP|ALTER)\b[^;]{0,1000}\b(?:TRIGGER|PROCEDURE|FUNCTION|EVENT)\b') {
    throw 'Source dump contains an executable database object and cannot be isolated safely.'
}

$definerPattern = '(?is)\bDEFINER\s*=\s*`[^`]+`\s*@\s*`[^`]+`\s+SQL\s+SECURITY\s+DEFINER\b'
$sourceQualifierPattern = '`' + [regex]::Escape($SourceDatabase) + '`\.'
$viewBlockPattern = '(?is)/\*!\d{5}\s+CREATE\s+ALGORITHM\b.*?\bVIEW\b.*?\*/;'
$viewBlocks = [regex]::Matches($sourceText, $viewBlockPattern)
function Test-MatchInsideRanges {
    param([Text.RegularExpressions.Match] $Match, [System.Collections.IEnumerable] $Ranges)

    foreach ($range in $Ranges) {
        if ($Match.Index -ge $range.Index -and ($Match.Index + $Match.Length) -le ($range.Index + $range.Length)) {
            return $true
        }
    }
    return $false
}

function Convert-ViewBlock {
    param(
        [string] $Block,
        [string] $DefinerPattern,
        [string] $QualifierPattern,
        [string] $ReplacementDatabase
    )

    $protectedSpans = (Get-SqlLexicalSpans -Text $Block).ProtectedSpans
    $builder = New-Object Text.StringBuilder
    $cursor = 0
    foreach ($protectedSpan in $protectedSpans) {
        $nonStringSegment = $Block.Substring($cursor, $protectedSpan.Index - $cursor)
        $nonStringSegment = [regex]::Replace($nonStringSegment, $DefinerPattern, 'SQL SECURITY INVOKER')
        $nonStringSegment = [regex]::Replace($nonStringSegment, $QualifierPattern, ('`' + $ReplacementDatabase + '`.'))
        [void] $builder.Append($nonStringSegment)
        [void] $builder.Append($Block.Substring($protectedSpan.Index, $protectedSpan.Length))
        $cursor = $protectedSpan.Index + $protectedSpan.Length
    }
    $remainingSegment = $Block.Substring($cursor)
    $remainingSegment = [regex]::Replace($remainingSegment, $DefinerPattern, 'SQL SECURITY INVOKER')
    $remainingSegment = [regex]::Replace($remainingSegment, $QualifierPattern, ('`' + $ReplacementDatabase + '`.'))
    [void] $builder.Append($remainingSegment)
    return $builder.ToString()
}
$allDefiners = @([regex]::Matches($sourceText, $definerPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sourceLexicalSpans.ProtectedSpans) })
$allQualifiedReferences = @([regex]::Matches($sourceText, $sourceQualifierPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sourceLexicalSpans.ProtectedSpans) })
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
    $sanitizedBlock = Convert-ViewBlock -Block $viewBlock.Value -DefinerPattern $definerPattern `
        -QualifierPattern $sourceQualifierPattern -ReplacementDatabase $RehearsalDatabase
    [void] $textBuilder.Append($sanitizedBlock)
    $cursor = $viewBlock.Index + $viewBlock.Length
}
[void] $textBuilder.Append($sourceText.Substring($cursor))
$sanitizedText = $textBuilder.ToString()

$rehearsalQualifierPattern = '`' + [regex]::Escape($RehearsalDatabase) + '`\.'
$sanitizedLexicalSpans = Get-SqlLexicalSpans -Text $sanitizedText
$remainingDefiners = @([regex]::Matches($sanitizedText, '(?i)\bDEFINER\s*=|\bSQL\s+SECURITY\s+DEFINER\b') | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedLexicalSpans.ProtectedSpans) })
$remainingSourceQualifiers = @([regex]::Matches($sanitizedText, $sourceQualifierPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedLexicalSpans.ProtectedSpans) })
if ($remainingDefiners.Count -ne 0) {
    throw 'Sanitized dump retained a definer security clause.'
}
if ($remainingSourceQualifiers.Count -ne 0) {
    throw 'Sanitized dump retained a source database qualifier.'
}
if ((@([regex]::Matches($sanitizedText, '(?i)\bSQL\s+SECURITY\s+INVOKER\b') | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedLexicalSpans.ProtectedSpans) })).Count -ne $ExpectedDefinerCount) {
    throw 'Sanitized dump has an unexpected INVOKER count.'
}
if ((@([regex]::Matches($sanitizedText, $rehearsalQualifierPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedLexicalSpans.ProtectedSpans) })).Count -ne $ExpectedQualifiedReferenceCount) {
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
