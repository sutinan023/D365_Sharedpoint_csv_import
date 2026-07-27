$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\sync_to_server.bat'
$configuredDestination = 'set "DESTINATION=\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import"'

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-HarnessCase {
    param(
        [string] $Name,
        [string] $Template,
        [string] $TestRoot
    )

    $casePath = Join-Path $TestRoot $Name
    $destinationPath = Join-Path $casePath 'destination'
    $stubPath = Join-Path $casePath 'stubs'
    New-Item -ItemType Directory -Path $destinationPath, $stubPath -Force | Out-Null

    $localDestination = 'set "DESTINATION={0}"' -f $destinationPath
    $harnessScript = $Template.Replace($configuredDestination, $localDestination)
    Assert-True ($harnessScript -ne $Template) 'Harness could not replace the configured UNC destination.'

    $batchPath = Join-Path $casePath 'sync_to_server.bat'
    Set-Content -LiteralPath $batchPath -Value $harnessScript -Encoding Ascii

    $robocopyStub = @'
@echo off
> "%~dp0..\robocopy-called.txt" echo called
> "%~dp0..\robocopy-args.txt" echo %*
set /p ROBOCOPY_STUB_EXIT=<"%~dp0..\robocopy-exit.txt"
exit /b %ROBOCOPY_STUB_EXIT%
'@
    Set-Content -LiteralPath (Join-Path $stubPath 'robocopy.cmd') -Value $robocopyStub -Encoding Ascii

    $runnerPath = Join-Path $casePath 'run-harness.cmd'
    $runner = @"
@echo off
set "PATH=$stubPath;%PATH%"
call "$batchPath"
exit /b %ERRORLEVEL%
"@
    Set-Content -LiteralPath $runnerPath -Value $runner -Encoding Ascii

    return [pscustomobject] @{
        BatchPath = $batchPath
        CalledFile = Join-Path $casePath 'robocopy-called.txt'
        ArgsFile = Join-Path $casePath 'robocopy-args.txt'
        ExitCodeFile = Join-Path $casePath 'robocopy-exit.txt'
        RunnerPath = $runnerPath
        SourcePath = $casePath
    }
}

function Invoke-HarnessCase {
    param(
        [pscustomobject] $Case,
        [string] $InputText,
        [int] $RobocopyExitCode
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    Set-Content -LiteralPath $Case.ExitCodeFile -Value $RobocopyExitCode -Encoding Ascii

    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = '/d /c ""{0}""' -f $Case.RunnerPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    Assert-True $process.Start() 'Failed to start the local batch test harness.'
    $process.StandardInput.WriteLine($InputText)
    $process.StandardInput.Close()
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject] @{
        ExitCode = $process.ExitCode
        Output = $standardOutput
        ErrorOutput = $standardError
    }
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw 'Missing sync_to_server.bat'
}

$template = Get-Content -LiteralPath $scriptPath -Raw
Assert-True ($template.Contains('set "SOURCE=%~dp0"')) 'The source must remain relative to the batch file.'
Assert-True ($template.Contains($configuredDestination)) 'The configured UNC destination changed unexpectedly.'
Assert-True ($template -match '(?im)^robocopy ') 'Robocopy must be invoked directly; CALL breaks the quoted source and destination arguments.'
Assert-True ($template -notmatch '(?im)^call robocopy ') 'Do not invoke Robocopy with CALL.'
Assert-True ($template -match '(?im)^robocopy .+ /MIR /XD "%SOURCE%\.git" /XF "%SOURCE%\.git"$') 'Robocopy must mirror and exclude .git directories and files.'
Assert-True ($template -match 'set "ROBOCOPY_EXIT=%ERRORLEVEL%"') 'The Robocopy exit code must be captured.'
Assert-True ($template -match 'if %ROBOCOPY_EXIT% GEQ 8') 'Robocopy exit codes 8 and above must fail.'
Assert-True ($template -match 'echo Synchronization completed successfully\.\s*\r?\nexit /b 0') 'Robocopy exit codes below 8 must succeed.'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sync-to-server-test-{0}' -f [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $cancelCase = New-HarnessCase -Name 'cancel' -Template $template -TestRoot $testRoot
    $cancelResult = Invoke-HarnessCase -Case $cancelCase -InputText 'N' -RobocopyExitCode 0
    Assert-True ($cancelResult.ExitCode -eq 1) "Cancellation returned exit code $($cancelResult.ExitCode), expected 1."
    Assert-True ($cancelResult.Output -match 'Synchronization cancelled\.') 'The reachable destination did not reach the cancellation branch.'
    Assert-True (-not (Test-Path -LiteralPath $cancelCase.CalledFile)) 'Robocopy ran before cancellation completed.'

}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'sync_to_server.bat local behavior checks passed.'
