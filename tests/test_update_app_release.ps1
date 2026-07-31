$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\tools\update_app_release.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('update-app-release-test-{0}' -f [guid]::NewGuid())
$auditRoot = Join-Path $testRoot 'audit'
$secret = 'never-print-this-secret-7dd3'

function New-TestEnvironment {
    param([string] $Name = 'uat', [string] $Release = '2026-07-31.8', [string] $DbName = 'D365_finance', [string] $AppEnv = 'UAT')
    $root = Join-Path $testRoot $Name
    foreach ($project in @('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')) {
        $config = Join-Path $root "$project\config"
        New-Item -ItemType Directory -Path $config -Force | Out-Null
        $text = "# retained comment`r`nAPP_ENV=$AppEnv`r`nAPP_RELEASE=$Release`r`nDB_NAME=$DbName`r`nDB_PASS=$secret`r`n"
        [IO.File]::WriteAllText((Join-Path $config '.env'), $text, [Text.UTF8Encoding]::new($false))
    }
    return $root
}

function Invoke-ExpectedFailure {
    param([scriptblock] $Action, [string] $Matches)
    try { & $Action; throw 'Expected command to fail.' } catch {
        if ($_.Exception.Message -notmatch $Matches) { throw }
    }
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $uatRoot = New-TestEnvironment
    $beforePath = Join-Path $uatRoot 'D365_Sharedpoint_csv_import\config\.env'
    $before = [IO.File]::ReadAllBytes($beforePath)
    $resultText = (& $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $uatRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' | Out-String)
    $result = $resultText | ConvertFrom-Json
    if ($result.status -cne 'UPDATED') { throw 'Expected UPDATED status.' }
    $after = [IO.File]::ReadAllBytes($beforePath)
    $beforeText = [Text.Encoding]::UTF8.GetString($before)
    $afterText = [Text.Encoding]::UTF8.GetString($after)
    if (($afterText -replace 'APP_RELEASE=2026-07-31.9', 'APP_RELEASE=2026-07-31.8') -cne $beforeText) { throw 'Updater changed more than the APP_RELEASE line.' }
    if ($resultText -match [regex]::Escape($secret)) { throw 'Secret appeared in command output.' }
    $audit = Get-Content -LiteralPath $result.audit_file -Raw
    if ($audit -match [regex]::Escape($secret) -or $audit -match 'DB_PASS') { throw 'Secret appeared in audit.' }

    $second = (& $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $uatRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' | Out-String | ConvertFrom-Json)
    if ($second.status -cne 'NO_CHANGE') { throw 'Idempotent rerun did not report NO_CHANGE.' }

    $wrongTokenRoot = New-TestEnvironment -Name wrong-token
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $wrongTokenRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'wrong' } 'approval'
    if ((Get-Content (Join-Path $wrongTokenRoot 'D365_Sharedpoint_csv_import\config\.env') -Raw) -notmatch 'APP_RELEASE=2026-07-31.8') { throw 'Wrong token changed a file.' }

    $badEnvRoot = New-TestEnvironment -Name bad-env -AppEnv PRODUCTION
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $badEnvRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'APP_ENV'
    $badDbRoot = New-TestEnvironment -Name bad-db -DbName D365_finance_prod
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $badDbRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'DB_NAME'
    $mismatchRoot = New-TestEnvironment -Name mismatch
    [IO.File]::WriteAllText((Join-Path $mismatchRoot 'finance_report\config\.env'), "APP_ENV=UAT`r`nAPP_RELEASE=different`r`nDB_NAME=D365_finance`r`nDB_PASS=$secret`r`n")
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $mismatchRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'identical'
    $duplicateRoot = New-TestEnvironment -Name duplicate
    Add-Content (Join-Path $duplicateRoot 'D365_file_csv_import\config\.env') 'APP_RELEASE=duplicate'
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $duplicateRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'exactly one'
    $missingRoot = New-TestEnvironment -Name missing
    Remove-Item -LiteralPath (Join-Path $missingRoot 'finance_report\config\.env') -Force
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot $missingRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'not found'
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '../unsafe' -EnvironmentRoot $uatRoot -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE ../unsafe' } 'ReleaseId'
    Invoke-ExpectedFailure { & $scriptPath -Environment UAT -ReleaseId '2026-07-31.9' -EnvironmentRoot 'C:\xampp\htdocs\uat' -AuditRoot $auditRoot -LocalTestMode -ApprovalToken 'UPDATE UAT APP_RELEASE 2026-07-31.9' } 'LocalTestMode'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Write-Host 'APP_RELEASE updater checks passed.'
