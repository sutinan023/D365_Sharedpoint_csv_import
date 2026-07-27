param(
    [string] $SourceRoot,
    [string] $DestinationRoot = '\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import',
    [string[]] $Exclude = @('.git', '.agents', '*.log', '*.tmp', 'download', 'archive', 'error', 'temp', 'logs', 'vendor', '.env', 'config\.env'),
    [switch] $CompareOnly
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = Split-Path -Parent $PSScriptRoot
}

$resolvedSourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\', '/')
$resolvedDestinationRoot = (Resolve-Path -LiteralPath $DestinationRoot).Path.TrimEnd('\', '/')

function Test-ExcludedPath {
    param(
        [string] $RelativePath,
        [string[]] $Patterns
    )

    $normalizedPath = $RelativePath.Replace('/', '\').TrimStart('\')
    $pathParts = $normalizedPath -split '\\'
    $leafName = $pathParts[-1]

    foreach ($pattern in $Patterns) {
        $normalizedPattern = $pattern.Replace('/', '\').Trim('\')
        if ([string]::IsNullOrWhiteSpace($normalizedPattern)) {
            continue
        }

        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($normalizedPattern)) {
            if ($normalizedPath -like $normalizedPattern -or $leafName -like $normalizedPattern) {
                return $true
            }
        }
        elseif ($normalizedPattern.Contains('\')) {
            if ($normalizedPath -ieq $normalizedPattern -or $normalizedPath -ilike "$normalizedPattern\*") {
                return $true
            }
        }
        elseif ($pathParts -icontains $normalizedPattern) {
            return $true
        }
    }

    return $false
}

$changes = @(
    foreach ($sourceFile in Get-ChildItem -LiteralPath $resolvedSourceRoot -File -Recurse -Force) {
        $relativePath = $sourceFile.FullName.Substring($resolvedSourceRoot.Length).TrimStart('\', '/')
        if (Test-ExcludedPath -RelativePath $relativePath -Patterns $Exclude) {
            continue
        }

        $destinationPath = Join-Path $resolvedDestinationRoot $relativePath
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            [pscustomobject] @{
                Type = 'New'
                RelativePath = $relativePath
                SourcePath = $sourceFile.FullName
                DestinationPath = $destinationPath
            }
            continue
        }

        $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
        if ($sourceHash -cne $destinationHash) {
            [pscustomobject] @{
                Type = 'Modified'
                RelativePath = $relativePath
                SourcePath = $sourceFile.FullName
                DestinationPath = $destinationPath
            }
        }
    }
)

foreach ($change in $changes) {
    Write-Output ('{0}: {1}' -f $change.Type, $change.RelativePath)
}

if ($CompareOnly) {
    return
}

if ($changes.Count -eq 0) {
    Write-Output 'No changes.'
    return
}

$approval = Read-Host 'Type APPROVE to copy these files'
if ($approval -cne 'APPROVE') {
    Write-Output 'Synchronization cancelled.'
    return
}

foreach ($change in $changes) {
    $destinationDirectory = Split-Path -Parent $change.DestinationPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    Copy-Item -LiteralPath $change.SourcePath -Destination $change.DestinationPath -Force
}

Write-Output ('Copied {0} file(s).' -f $changes.Count)
