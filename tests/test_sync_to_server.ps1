$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\tools\sync_to_server.ps1'

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sync-to-server-test-{0}' -f [guid]::NewGuid())
$sourceRoot = Join-Path $testRoot 'source'
$destinationRoot = Join-Path $testRoot 'destination'

New-Item -ItemType Directory -Path $sourceRoot, $destinationRoot | Out-Null

try {
    Set-Content -LiteralPath (Join-Path $sourceRoot 'new.txt') -Value 'new source file'
    Set-Content -LiteralPath (Join-Path $sourceRoot 'modified.txt') -Value 'source version'
    Set-Content -LiteralPath (Join-Path $destinationRoot 'modified.txt') -Value 'destination version'
    Set-Content -LiteralPath (Join-Path $sourceRoot 'equal.txt') -Value 'same content'
    Set-Content -LiteralPath (Join-Path $destinationRoot 'equal.txt') -Value 'same content'
    $hiddenPath = Join-Path $sourceRoot 'hidden.txt'
    Set-Content -LiteralPath $hiddenPath -Value 'hidden source file'
    (Get-Item -LiteralPath $hiddenPath).Attributes = (Get-Item -LiteralPath $hiddenPath).Attributes -bor [System.IO.FileAttributes]::Hidden

    $logsRoot = Join-Path $sourceRoot 'logs'
    New-Item -ItemType Directory -Path $logsRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $logsRoot 'ignored.log') -Value 'excluded log'

    $comparison = & $scriptPath `
        -SourceRoot $sourceRoot `
        -DestinationRoot $destinationRoot `
        -CompareOnly `
        -Exclude @() | Out-String

    Assert-True ($comparison -match '(?m)^New:\s+new\.txt\s*$') 'A source-only file was not listed as New.'
    Assert-True ($comparison -match '(?m)^New:\s+hidden\.txt\s*$') 'A hidden source file was not listed as New.'
    Assert-True ($comparison -match '(?m)^Modified:\s+modified\.txt\s*$') 'A file with a different hash was not listed as Modified.'
    Assert-True ($comparison -notmatch '(?m)equal\.txt') 'A file with an equal hash was incorrectly listed as changed.'

    $excludedComparison = & $scriptPath `
        -SourceRoot $sourceRoot `
        -DestinationRoot $destinationRoot `
        -CompareOnly `
        -Exclude @('logs') | Out-String

    Assert-True ($excludedComparison -notmatch 'logs[\\/]ignored\.log') 'A file below an excluded directory was listed as changed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'sync_to_server.ps1 local comparison checks passed.'
