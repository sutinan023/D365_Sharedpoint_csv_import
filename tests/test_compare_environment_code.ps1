$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\tools\compare_environment_code.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('compare-environment-code-{0}' -f [guid]::NewGuid())
$source = Join-Path $testRoot 'source'
$destination = Join-Path $testRoot 'environment'

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

try {
    New-Item -ItemType Directory -Path $source, $destination | Out-Null

    Set-Content (Join-Path $source 'new.php') '<?php echo "new";'
    Set-Content (Join-Path $source 'modified.php') '<?php echo "source";'
    Set-Content (Join-Path $source 'equal.php') '<?php echo "equal";'
    Set-Content (Join-Path $source '.env') 'DB_PASS=source-secret'
    Set-Content (Join-Path $source 'tracked.csv') 'must-not-compare'
    foreach ($directory in @('logs', 'vendor', 'download', 'archive', 'processed', 'error', 'temp', '.deployment')) {
        New-Item -ItemType Directory -Path (Join-Path $source $directory) -Force | Out-Null
        Set-Content (Join-Path $source "$directory\ignored.txt") 'source-runtime'
    }
    New-Item -ItemType Directory -Path (Join-Path $source 'import') | Out-Null
    Set-Content (Join-Path $source 'import\run_pipeline.php') '<?php echo "pipeline";'
    Set-Content (Join-Path $source 'import\payload.csv') 'runtime-csv'

    & git -C $source init --quiet
    & git -C $source config core.autocrlf false
    & git -C $source config user.email 'test@example.invalid'
    & git -C $source config user.name 'Test'
    & git -C $source add -f .
    & git -C $source commit --quiet -m initial
    $sha = (& git -C $source rev-parse HEAD).Trim()

    Set-Content (Join-Path $destination 'modified.php') '<?php echo "destination";'
    Set-Content (Join-Path $destination 'equal.php') '<?php echo "equal";'
    Set-Content (Join-Path $destination 'deleted.php') '<?php echo "deleted";'
    Set-Content (Join-Path $destination '.env') 'DB_PASS=environment-secret'
    Set-Content (Join-Path $destination 'environment.csv') 'must-not-compare'
    foreach ($directory in @('logs', 'vendor', 'download', 'archive', 'processed', 'error', 'temp', '.deployment')) {
        New-Item -ItemType Directory -Path (Join-Path $destination $directory) -Force | Out-Null
        Set-Content (Join-Path $destination "$directory\ignored.txt") 'environment-runtime'
    }
    New-Item -ItemType Directory -Path (Join-Path $destination 'import') | Out-Null
    Set-Content (Join-Path $destination 'import\payload.csv') 'environment-runtime-csv'

    $changes = @(& $scriptPath -ProjectName finance_report -SourceRoot $source `
        -DestinationRoot $destination -ExpectedGitSha $sha -LocalTestMode)

    Assert-True (@($changes | Where-Object { $_.Type -eq 'New' -and $_.RelativePath -eq 'new.php' }).Count -eq 1) 'New code file was not reported.'
    Assert-True (@($changes | Where-Object { $_.Type -eq 'Modified' -and $_.RelativePath -eq 'modified.php' }).Count -eq 1) 'Modified code file was not reported.'
    Assert-True (@($changes | Where-Object { $_.Type -eq 'Deleted' -and $_.RelativePath -eq 'deleted.php' }).Count -eq 1) 'Deleted code file was not reported.'
    Assert-True (@($changes | Where-Object { $_.Type -eq 'New' -and $_.RelativePath -eq 'import\run_pipeline.php' }).Count -eq 1) 'PHP code below import was incorrectly excluded.'
    Assert-True (@($changes | Where-Object RelativePath -eq 'equal.php').Count -eq 0) 'Equal code file was reported.'
    Assert-True (@($changes | Where-Object { $_.RelativePath -match '(?i)(\.env|\.csv$|logs|vendor|download|archive|processed|error|temp|\.deployment)' }).Count -eq 0) 'Excluded path leaked into code comparison.'
    Assert-True (@($changes | Where-Object { $_.Project -cne 'finance_report' }).Count -eq 0) 'Project name was not retained.'

    try {
        & $scriptPath -ProjectName finance_report -SourceRoot $source -DestinationRoot $destination `
            -ExpectedGitSha ('0' * 40) -LocalTestMode | Out-Null
        throw 'Git SHA mismatch was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'SHA') { throw }
    }

    Set-Content (Join-Path $source 'dirty.txt') 'dirty'
    try {
        & $scriptPath -ProjectName finance_report -SourceRoot $source -DestinationRoot $destination `
            -ExpectedGitSha $sha -LocalTestMode | Out-Null
        throw 'Dirty source repository was accepted.'
    } catch {
        if ($_.Exception.Message -notmatch 'clean') { throw }
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'Environment code comparison checks passed.'
