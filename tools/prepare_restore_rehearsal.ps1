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

    [Nullable[int]] $ExpectedDefinerCount,

    [Nullable[int]] $ExpectedQualifiedReferenceCount,

    [switch] $UseCheckpointBaseline,
    [string] $BackupManifestPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_security.ps1')

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
if ($SourceDatabase -ieq $RehearsalDatabase) {
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
$checkpointManifestHash = $null
$LiveQualifiedReferenceCount = $null
if ($UseCheckpointBaseline) {
    if ([string]::IsNullOrWhiteSpace($BackupManifestPath) -or -not (Test-Path -LiteralPath $BackupManifestPath -PathType Leaf)) {
        throw 'Checkpoint baseline mode requires BackupManifestPath.'
    }
    $checkpointSnapshot = Read-D365StrictJsonSnapshot -Path $BackupManifestPath -Label 'Checkpoint manifest'
    $checkpoint = $checkpointSnapshot.Value
    if ([string] $checkpoint.database -cne $SourceDatabase -or
        [IO.Path]::GetFullPath([string] $checkpoint.backup_file) -ine $sourceFullPath -or
        [string] $checkpoint.sha256 -ine $actualSourceHash) {
        throw 'Checkpoint manifest does not bind the source backup.'
    }
    $baseline = $checkpoint.verification_baseline
    if ($null -eq $baseline -or $baseline.definer_count -isnot [int] -or
        $baseline.qualified_reference_count -isnot [int] -or
        $baseline.dump_qualified_reference_count -isnot [int] -or
        $baseline.definer_count -lt 0 -or $baseline.qualified_reference_count -lt 0 -or
        $baseline.dump_qualified_reference_count -lt 0) {
        throw 'Checkpoint verification baseline counts are invalid.'
    }
    $ExpectedDefinerCount = [int] $baseline.definer_count
    $LiveQualifiedReferenceCount = [int] $baseline.qualified_reference_count
    $ExpectedQualifiedReferenceCount = [int] $baseline.dump_qualified_reference_count
    $checkpointManifestHash = $checkpointSnapshot.Hash
} elseif ($null -eq $ExpectedDefinerCount -or $null -eq $ExpectedQualifiedReferenceCount -or
          $ExpectedDefinerCount -lt 0 -or $ExpectedQualifiedReferenceCount -lt 0) {
    throw 'Explicit nonnegative counts or UseCheckpointBaseline are required.'
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
function Get-SqlLexicalTokens {
    param([string] $Text, [object[]] $ProtectedSpans)
    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $protectedIndex = 0
    $index = 0
    while ($index -lt $Text.Length) {
        while ($protectedIndex -lt $ProtectedSpans.Count -and ($ProtectedSpans[$protectedIndex].Index + $ProtectedSpans[$protectedIndex].Length) -le $index) { $protectedIndex++ }
        if ($protectedIndex -lt $ProtectedSpans.Count -and $index -ge $ProtectedSpans[$protectedIndex].Index -and $index -lt ($ProtectedSpans[$protectedIndex].Index + $ProtectedSpans[$protectedIndex].Length)) {
            $index = $ProtectedSpans[$protectedIndex].Index + $ProtectedSpans[$protectedIndex].Length
            continue
        }
        $character = $Text[$index]
        if ([char]::IsWhiteSpace($character)) { $index++; continue }
        if ($character -eq '`') {
            $start = $index++
            $builder = New-Object Text.StringBuilder
            while ($index -lt $Text.Length) {
                if ($Text[$index] -eq '`') {
                    if (($index + 1) -lt $Text.Length -and $Text[$index + 1] -eq '`') { [void]$builder.Append('`'); $index += 2; continue }
                    $index++; break
                }
                [void]$builder.Append($Text[$index]); $index++
            }
            [void]$tokens.Add([pscustomobject]@{ Value=$builder.ToString(); Kind='QuotedIdentifier'; Index=$start })
            continue
        }
        if ([char]::IsLetter($character) -or $character -eq '_') {
            $start = $index++
            while ($index -lt $Text.Length -and ([char]::IsLetterOrDigit($Text[$index]) -or $Text[$index] -eq '_' -or $Text[$index] -eq '$')) { $index++ }
            [void]$tokens.Add([pscustomobject]@{ Value=$Text.Substring($start,$index-$start).ToUpperInvariant(); Kind='Word'; Index=$start })
            continue
        }
        [void]$tokens.Add([pscustomobject]@{ Value=[string]$character; Kind='Symbol'; Index=$index })
        $index++
    }
    return [object[]]$tokens.ToArray()
}

$sqlTokens = @(Get-SqlLexicalTokens -Text $sourceText -ProtectedSpans $sourceLexicalSpans.ProtectedSpans)
$ddlObjectTypes = @('DATABASE','SCHEMA','TRIGGER','PROCEDURE','FUNCTION','EVENT','TABLE','VIEW','INDEX','USER','ROLE','SERVER','TABLESPACE','LOGFILE','SEQUENCE','PACKAGE')
for ($tokenIndex = 0; $tokenIndex -lt $sqlTokens.Count; $tokenIndex++) {
    $token = $sqlTokens[$tokenIndex]
    if ($token.Kind -ne 'Word') { continue }
    if ($token.Value -ceq 'USE') { throw 'Source dump contains a dangerous database selection statement and cannot be isolated safely.' }
    if ($token.Value -in @('CREATE','DROP','ALTER')) {
        for ($lookahead = $tokenIndex + 1; $lookahead -lt $sqlTokens.Count -and $sqlTokens[$lookahead].Value -cne ';'; $lookahead++) {
            if ($sqlTokens[$lookahead].Kind -ne 'Word') { continue }
            $objectType = $sqlTokens[$lookahead].Value
            if ($objectType -notin $ddlObjectTypes) { continue }
            if ($objectType -in @('DATABASE','SCHEMA')) { throw 'Source dump contains a dangerous database DDL statement and cannot be isolated safely.' }
            if ($objectType -in @('TRIGGER','PROCEDURE','FUNCTION','EVENT')) { throw 'Source dump contains an executable database object and cannot be isolated safely.' }
            break # A recognized safe object type prevents keywords in its body being treated as DDL targets.
        }
    }
}

$definerIdentityPattern = '(?is)\bDEFINER\s*=\s*`[^`]+`\s*@\s*`[^`]+`'
$definerSecurityPattern = '(?is)\bSQL\s+SECURITY\s+DEFINER\b'
$invokerSecurityPattern = '(?is)\bSQL\s+SECURITY\s+INVOKER\b'
$sourceQualifierPattern = '`' + [regex]::Escape($SourceDatabase) + '`\.'
$sourceQualifierOptions = [Text.RegularExpressions.RegexOptions]::IgnoreCase
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
        [string] $DefinerIdentityPattern,
        [string] $DefinerSecurityPattern,
        [string] $QualifierPattern,
        [string] $ReplacementDatabase
    )

    $protectedSpans = (Get-SqlLexicalSpans -Text $Block).ProtectedSpans
    $builder = New-Object Text.StringBuilder
    $cursor = 0
    foreach ($protectedSpan in $protectedSpans) {
        $nonStringSegment = $Block.Substring($cursor, $protectedSpan.Index - $cursor)
        $nonStringSegment = [regex]::Replace($nonStringSegment, $DefinerIdentityPattern, '')
        $nonStringSegment = [regex]::Replace($nonStringSegment, $DefinerSecurityPattern, 'SQL SECURITY INVOKER')
        $nonStringSegment = [regex]::Replace($nonStringSegment, $QualifierPattern, ('`' + $ReplacementDatabase + '`.'), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        [void] $builder.Append($nonStringSegment)
        [void] $builder.Append($Block.Substring($protectedSpan.Index, $protectedSpan.Length))
        $cursor = $protectedSpan.Index + $protectedSpan.Length
    }
    $remainingSegment = $Block.Substring($cursor)
    $remainingSegment = [regex]::Replace($remainingSegment, $DefinerIdentityPattern, '')
    $remainingSegment = [regex]::Replace($remainingSegment, $DefinerSecurityPattern, 'SQL SECURITY INVOKER')
    $remainingSegment = [regex]::Replace($remainingSegment, $QualifierPattern, ('`' + $ReplacementDatabase + '`.'), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    [void] $builder.Append($remainingSegment)
    return $builder.ToString()
}
$allDefinerIdentities = @([regex]::Matches($sourceText, $definerIdentityPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sourceLexicalSpans.ProtectedSpans) })
$allDefinerSecurityClauses = @([regex]::Matches($sourceText, $definerSecurityPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sourceLexicalSpans.ProtectedSpans) })
$allInvokerSecurityClauses = @([regex]::Matches($sourceText, $invokerSecurityPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sourceLexicalSpans.ProtectedSpans) })
$allQualifiedReferences = @([regex]::Matches($sourceText, $sourceQualifierPattern, $sourceQualifierOptions) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sourceLexicalSpans.ProtectedSpans) })
$outsideDefiners = @($allDefinerIdentities + $allDefinerSecurityClauses + $allInvokerSecurityClauses | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $viewBlocks) })
$outsideQualifiedReferences = @($allQualifiedReferences | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $viewBlocks) })
if ($outsideDefiners.Count -ne 0 -or $outsideQualifiedReferences.Count -ne 0) {
    throw "Source dump contains a definer or source qualifier outside a recognized VIEW DDL block (views=$($viewBlocks.Count), outside_definers=$($outsideDefiners.Count), outside_qualifiers=$($outsideQualifiedReferences.Count))."
}
$definerCount = $allDefinerSecurityClauses.Count
$expectedInvokerCount = $allDefinerSecurityClauses.Count + $allInvokerSecurityClauses.Count
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
    $sanitizedBlock = Convert-ViewBlock -Block $viewBlock.Value -DefinerIdentityPattern $definerIdentityPattern `
        -DefinerSecurityPattern $definerSecurityPattern `
        -QualifierPattern $sourceQualifierPattern -ReplacementDatabase $RehearsalDatabase
    [void] $textBuilder.Append($sanitizedBlock)
    $cursor = $viewBlock.Index + $viewBlock.Length
}
[void] $textBuilder.Append($sourceText.Substring($cursor))
$sanitizedText = $textBuilder.ToString()

$rehearsalQualifierPattern = '`' + [regex]::Escape($RehearsalDatabase) + '`\.'
$sanitizedLexicalSpans = Get-SqlLexicalSpans -Text $sanitizedText
$remainingDefiners = @([regex]::Matches($sanitizedText, '(?i)\bDEFINER\s*=|\bSQL\s+SECURITY\s+DEFINER\b') | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedLexicalSpans.ProtectedSpans) })
$remainingSourceQualifiers = @([regex]::Matches($sanitizedText, $sourceQualifierPattern, $sourceQualifierOptions) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedLexicalSpans.ProtectedSpans) })
if ($remainingDefiners.Count -ne 0) {
    throw 'Sanitized dump retained a definer security clause.'
}
if ($remainingSourceQualifiers.Count -ne 0) {
    throw 'Sanitized dump retained a source database qualifier.'
}
if ((@([regex]::Matches($sanitizedText, $invokerSecurityPattern) | Where-Object { -not (Test-MatchInsideRanges -Match $_ -Ranges $sanitizedLexicalSpans.ProtectedSpans) })).Count -ne $expectedInvokerCount) {
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
    live_qualified_reference_count = $LiveQualifiedReferenceCount
    qualified_reference_count = $qualifiedReferenceCount
    checkpoint_manifest_sha256 = $checkpointManifestHash
}
[IO.File]::WriteAllText($auditFullPath, ($audit | ConvertTo-Json -Depth 4), $utf8WithoutBom)
Write-Output $outputFullPath
