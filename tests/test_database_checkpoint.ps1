$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\tools\database_checkpoint.ps1'
$plan = (& $scriptPath -Environment Production -ReleaseId '2026-07-31.1' -PlanOnly | Out-String | ConvertFrom-Json)

if ($plan.database -cne 'D365_finance_prod') {
    throw 'Production checkpoint selected the wrong database'
}
if ($plan.retention_days -ne 30 -or $plan.requires_restore_rehearsal -ne $true) {
    throw 'Production checkpoint omitted retention or restore rehearsal'
}
if ($plan.backup_file -notmatch 'D365_finance_prod.*2026-07-31.1.*\.sql$') {
    throw 'Backup file does not identify database and release'
}
$scriptSource = Get-Content -LiteralPath $scriptPath -Raw
if ($scriptSource -notmatch 'BACKUP_DB_USER' -or $scriptSource -notmatch 'BACKUP_DB_PASS') {
    throw 'Database checkpoint does not use the dedicated backup account'
}
if ($scriptSource -notmatch '\.ProviderPath') {
    throw 'Database checkpoint does not store a PHP-compatible filesystem path'
}
if ($scriptSource -notmatch 'checkpoint_baseline\.php' -or $scriptSource -notmatch 'verification_baseline') {
    throw 'Database checkpoint does not bind an automatic verification baseline.'
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\tools\checkpoint_baseline.php'))) {
    throw 'Checkpoint baseline CLI is missing.'
}
if ($scriptSource -notmatch '\$dumpBytes\s*=\s*\[IO\.File\]::ReadAllBytes\(\$backupFile\)') {
    throw 'Database checkpoint does not read the completed dump as bytes.'
}
if ($scriptSource -notmatch '\$dumpText\s*=\s*\(New-Object Text\.UTF8Encoding\(\$false,\s*\$true\)\)\.GetString\(\$dumpBytes\)') {
    throw 'Database checkpoint does not decode the dump as strict UTF-8.'
}
if ($scriptSource -notmatch '\$dumpQualifierPattern\s*=\s*\x27\x60\x27\s*\+\s*\[regex\]::Escape\(\$database\)\s*\+\s*\x27\x60\\\.\x27') {
    throw 'Database checkpoint does not build the exact dump qualifier pattern.'
}
if ($scriptSource -notmatch '\$dumpQualifiedReferenceCount\s*=\s*\[regex\]::Matches\(' -or
    $scriptSource -notmatch '\$dumpText,\s*\$dumpQualifierPattern,\s*\[Text\.RegularExpressions\.RegexOptions\]::IgnoreCase\s*\)\.Count') {
    throw 'Database checkpoint does not count dump qualifiers case-insensitively.'
}
if ($scriptSource -notmatch '\$baseline\s*\|\s*Add-Member\s+-NotePropertyName\s+dump_qualified_reference_count\s+`?\s*-NotePropertyValue\s+\(\[int\]\s*\$dumpQualifiedReferenceCount\)') {
    throw 'Database checkpoint does not bind dump_qualified_reference_count as a native integer.'
}
if ($scriptSource -notmatch 'catch\s+\[Text\.DecoderFallbackException\]\s*\{\s*throw\s+[\x27\x22]Database checkpoint dump must be valid UTF-8\.[\x27\x22]\s*\}') {
    throw 'Database checkpoint does not reject invalid dump UTF-8.'
}
if ($scriptSource -notmatch 'verification_baseline\s*=\s*\$baseline') {
    throw 'Database checkpoint does not preserve the baseline object in the manifest.'
}
if ($scriptSource -match 'Add-Member\s+-NotePropertyName\s+qualified_reference_count' -or
    $scriptSource -match '\$baseline\.qualified_reference_count\s*=') {
    throw 'Database checkpoint overwrites the live qualified_reference_count baseline.'
}

Write-Host 'Database checkpoint plan checks passed.'
