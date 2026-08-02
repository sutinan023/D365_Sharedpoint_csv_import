$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\new_release_manifest.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('release-manifest-test-{0}' -f [guid]::NewGuid())
New-Item -ItemType Directory $testRoot | Out-Null

try {
    foreach ($project in @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')) {
        $root = Join-Path $testRoot $project
        New-Item -ItemType Directory $root | Out-Null
        Set-Content (Join-Path $root 'tracked.txt') $project
        if ($project -eq 'D365_Sharedpoint_csv_import') {
            $migrationDirectory = Join-Path $root 'database\migrations'
            New-Item -ItemType Directory $migrationDirectory -Force | Out-Null
            foreach ($migration in @(
                '000_create_schema_migrations.sql',
                '001_create_sharepoint_file_queue.sql',
                '002_add_pending_archive_to_import_files_status.sql',
                '003_add_effective_date_to_stg_received_outbound.sql',
                '004_create_vw_import_report.sql',
                '005_create_v_tbpayin_from_payment_outbound.sql',
                '006_test.sql'
            )) {
                Set-Content (Join-Path $migrationDirectory $migration) "SELECT '$migration';"
            }
        }
        & git -C $root init --quiet
        & git -C $root config user.email 'test@example.invalid'
        & git -C $root config user.name 'Test'
        & git -C $root add .
        & git -C $root commit --quiet -m initial
    }

    $manifest = (& $scriptPath -ReleaseId '2026-07-31.1' -SourceParent $testRoot -PlanOnly | Out-String | ConvertFrom-Json)
    if ($manifest.release_id -cne '2026-07-31.1') { throw 'Release manifest lost the release ID' }
    foreach ($project in @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')) {
        if ($manifest.projects.$project.git_sha -notmatch '^[0-9a-f]{40}$') {
            throw "Release manifest has an invalid Git SHA for $project"
        }
    }

    $expectedMigrations = @(
        '000_create_schema_migrations.sql',
        '001_create_sharepoint_file_queue.sql',
        '002_add_pending_archive_to_import_files_status.sql',
        '003_add_effective_date_to_stg_received_outbound.sql',
        '004_create_vw_import_report.sql',
        '005_create_v_tbpayin_from_payment_outbound.sql',
        '006_test.sql'
    )
    $actualMigrations = @($manifest.migrations.D365_Sharedpoint_csv_import)
    if ((Compare-Object $expectedMigrations $actualMigrations -SyncWindow 0).Count -ne 0) {
        throw 'Release manifest does not contain the complete ordered migration set'
    }

    $manifestPath = Join-Path $testRoot 'immutable.json'
    & $scriptPath -ReleaseId 'immutable' -SourceParent $testRoot -OutputPath $manifestPath | Out-Null
    try {
        & $scriptPath -ReleaseId 'immutable' -SourceParent $testRoot -OutputPath $manifestPath | Out-Null
        throw 'Existing release manifest was overwritten.'
    } catch {
        if ($_.Exception.Message -notmatch 'immutable') { throw }
    }

    $customManifest = (& $scriptPath -ReleaseId 'custom-roots' `
        -SharePointRoot (Join-Path $testRoot 'D365_Sharedpoint_csv_import') `
        -FileImporterRoot (Join-Path $testRoot 'D365_file_csv_import') `
        -FinanceReportRoot (Join-Path $testRoot 'finance_report') -PlanOnly |
        Out-String | ConvertFrom-Json)
    if ($customManifest.release_id -cne 'custom-roots') {
        throw 'Custom project roots were not accepted.'
    }

    $manifestScriptSource = Get-Content -LiteralPath $scriptPath -Raw
    if ($manifestScriptSource -notmatch 'FileMode\]::CreateNew') {
        throw 'Release manifest is not written atomically with FileMode.CreateNew.'
    }

    Set-Content (Join-Path $testRoot 'finance_report\dirty.txt') 'dirty'
    try {
        & $scriptPath -ReleaseId 'dirty' -SourceParent $testRoot -PlanOnly | Out-Null
        throw 'Dirty repository was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'clean') { throw }
    }
}
finally {
    if (Test-Path $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
Write-Host 'Release manifest generation checks passed.'
