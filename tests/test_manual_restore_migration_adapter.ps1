$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tools\manual_restore_migration_adapter.ps1')

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action; throw 'Expected failure.' } catch {
        if ($_.Exception.Message -eq 'Expected failure.' -or $_.Exception.Message -notmatch $Pattern) { throw }
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('manual-migration-adapter-{0}' -f [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $backup = Join-Path $root 'checkpoint.json'
    $receipt = Join-Path $root 'restore-approved.json'
    $php = Join-Path $root 'php.exe'
    Set-Content -LiteralPath $backup '{}'
    Set-Content -LiteralPath $receipt '{}'
    Set-Content -LiteralPath $php 'fixture'
    $projects = [ordered]@{}
    foreach ($project in @('D365_Sharedpoint_csv_import','D365_file_csv_import','finance_report')) {
        $source = Join-Path $root $project
        New-Item -ItemType Directory -Path $source | Out-Null
        $projects[$project] = [pscustomobject]@{SourceRoot=$source}
    }
    $manifest = [pscustomobject]@{release_id='r1';migrations=[pscustomobject]@{
        D365_Sharedpoint_csv_import=@('006.sql');D365_file_csv_import=@();finance_report=@()
    }}
    $adapter = New-D365ManualRestoreMigrationAdapter -Manifest $manifest -SourceProjects $projects `
        -ProductionRoot (Join-Path $root 'prod') -BackupManifestPath $backup `
        -RestoreReceiptPath $receipt -PhpPath $php -AppliedBy 'tester'
    if ($adapter -isnot [scriptblock]) { throw 'Manual restore adapter was not created.' }
    Assert-Throws {
        New-D365ManualRestoreMigrationAdapter -Manifest $manifest -SourceProjects $projects `
            -ProductionRoot (Join-Path $root 'prod') -BackupManifestPath (Join-Path $root 'missing.json') `
            -RestoreReceiptPath $receipt -PhpPath $php -AppliedBy 'tester' | Out-Null
    } 'not found'
    Assert-Throws {
        New-D365ManualRestoreMigrationAdapter -Manifest $manifest -SourceProjects $projects `
            -ProductionRoot (Join-Path $root 'prod') -BackupManifestPath $backup `
            -RestoreReceiptPath $receipt -PhpPath $php -AppliedBy 'bad user;argument' | Out-Null
    } 'unsafe'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

Write-Host 'Manual restore migration adapter checks passed.'
