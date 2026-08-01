param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('D365_Sharedpoint_csv_import', 'D365_file_csv_import', 'finance_report')]
    [string] $ProjectName,

    [Parameter(Mandatory = $true)]
    [string] $SourceRoot,

    [Parameter(Mandatory = $true)]
    [string] $DestinationRoot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedGitSha,

    [switch] $LocalTestMode
)

$ErrorActionPreference = 'Stop'

$exclude = @(
    '.git', '.agents', '.worktrees', 'vendor', '.env', 'config\.env',
    '*.log', '*.tmp', '*.csv', 'download', 'archive', 'processed', 'error',
    'temp', 'tmp', 'logs', '.deploy-backups', '.deployment'
)

function Get-NormalizedFullPath([string] $Path) {
    [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-ExcludedPath([string] $RelativePath) {
    $normalizedPath = $RelativePath.Replace('/', '\').TrimStart('\')
    $parts = $normalizedPath -split '\\'
    $leaf = $parts[-1]

    foreach ($pattern in $exclude) {
        $normalizedPattern = $pattern.Replace('/', '\').Trim('\')
        if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($normalizedPattern)) {
            if ($normalizedPath -like $normalizedPattern -or $leaf -like $normalizedPattern) { return $true }
        } elseif ($normalizedPattern.Contains('\')) {
            if ($normalizedPath -ieq $normalizedPattern -or $normalizedPath -ilike "$normalizedPattern\*") { return $true }
        } elseif ($parts -icontains $normalizedPattern) {
            return $true
        }
    }

    return $false
}

function Invoke-GitBytes([string] $Root, [string] $Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git.exe'
    $start.WorkingDirectory = $Root
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void] $process.Start()
    $memory = [IO.MemoryStream]::new()
    try {
        $process.StandardOutput.BaseStream.CopyTo($memory)
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Git command failed: $errorText" }
        return $memory.ToArray()
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Export-GitBlob([string] $Root, [string] $ObjectId, [string] $Path) {
    $bytes = Invoke-GitBytes $Root "cat-file blob $ObjectId"
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllBytes($Path, $bytes)
}

$source = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath.TrimEnd('\', '/')
$destination = (Resolve-Path -LiteralPath $DestinationRoot).ProviderPath.TrimEnd('\', '/')

if ($LocalTestMode) {
    $tempRoot = Get-NormalizedFullPath ([IO.Path]::GetTempPath())
    if (-not (Get-NormalizedFullPath $destination).StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LocalTestMode destination must be below the system temporary directory.'
    }
} else {
    $approved = @(
        "\\100.1.1.166\htdocs\uat\$ProjectName",
        "\\100.1.1.166\htdocs\prod\$ProjectName",
        "C:\xampp\htdocs\uat\$ProjectName",
        "C:\xampp\htdocs\prod\$ProjectName"
    ) | ForEach-Object { Get-NormalizedFullPath $_ }
    if ($approved -inotcontains (Get-NormalizedFullPath $destination)) {
        throw 'Destination is not an approved UAT or Production project root.'
    }
}

$head = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne $ExpectedGitSha) {
    throw 'Source Git SHA does not match the expected SHA.'
}
$dirty = (& git -C $source status --porcelain --untracked-files=all | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $dirty -ne '') {
    throw 'Source repository must be clean before comparison.'
}

$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('d365-code-compare-{0}' -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageRoot | Out-Null
try {
    $sourceFiles = @{}
    $treeBytes = Invoke-GitBytes $source "-c core.quotepath=false ls-tree -r -z $head"
    $treeText = [Text.UTF8Encoding]::new($false, $true).GetString($treeBytes)
    foreach ($treeEntry in $treeText.Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($treeEntry -notmatch '^\d+\s+blob\s+(?<sha>[0-9a-f]{40})\t(?<path>.+)$') {
            throw 'Unable to parse attested Git tree entry.'
        }
        $relative = $matches.path.Replace('/', '\')
        if (Test-ExcludedPath $relative) { continue }
        $stagePath = Join-Path $stageRoot $relative
        Export-GitBlob $source $matches.sha $stagePath
        $sourceFiles[$relative.ToLowerInvariant()] = [pscustomobject]@{ RelativePath = $relative; FullName = $stagePath }
    }

    $destinationFiles = @{}
    foreach ($file in Get-ChildItem -LiteralPath $destination -Recurse -File -Force) {
        $relative = $file.FullName.Substring($destination.Length).TrimStart('\', '/')
        if (-not (Test-ExcludedPath $relative)) {
            $destinationFiles[$relative.ToLowerInvariant()] = [pscustomobject]@{ RelativePath = $relative; FullName = $file.FullName }
        }
    }

    $changes = [Collections.Generic.List[object]]::new()
    foreach ($entry in $sourceFiles.GetEnumerator()) {
        $relative = $entry.Value.RelativePath
        if (-not $destinationFiles.ContainsKey($entry.Key)) {
            $changes.Add([pscustomobject]@{ Project = $ProjectName; Type = 'New'; RelativePath = $relative })
        } elseif ((Get-FileHash -LiteralPath $entry.Value.FullName -Algorithm SHA256).Hash -cne
                  (Get-FileHash -LiteralPath $destinationFiles[$entry.Key].FullName -Algorithm SHA256).Hash) {
            $changes.Add([pscustomobject]@{ Project = $ProjectName; Type = 'Modified'; RelativePath = $relative })
        }
    }
    foreach ($entry in $destinationFiles.GetEnumerator()) {
        if (-not $sourceFiles.ContainsKey($entry.Key)) {
            $changes.Add([pscustomobject]@{ Project = $ProjectName; Type = 'Deleted'; RelativePath = $entry.Value.RelativePath })
        }
    }

    $changes | Sort-Object Project, Type, RelativePath
} finally {
    if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
}
