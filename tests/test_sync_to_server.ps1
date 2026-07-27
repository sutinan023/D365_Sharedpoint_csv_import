$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\sync_to_server.bat'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing sync_to_server.bat"
}

$content = Get-Content -LiteralPath $scriptPath -Raw
$checks = @{
    'script-relative source' = $content -match 'set "SOURCE=%~dp0"'
    'exact UNC destination' = $content -match [regex]::Escape('set "DESTINATION=\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import"')
    'destination reachability check' = $content -match 'if not exist "%DESTINATION%\\NUL"'
    'explicit Y confirmation' = $content -match 'if /I not "%CONFIRM%"=="Y"'
    'mirror mode' = $content -match '(?i)robocopy[^\r\n]+/MIR'
    'git exclusion' = $content -match '(?i)/XD[^\r\n]+"%SOURCE%\.git"'
    'robocopy failure threshold' = $content -match 'if %ROBOCOPY_EXIT% GEQ 8'
}

$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })
if ($failed.Count -gt 0) {
    throw "Failed checks: $($failed.Name -join ', ')"
}

Write-Host 'sync_to_server.bat static checks passed.'
