@echo off
setlocal

set "SOURCE=%~dp0"
set "DESTINATION=\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import"

echo Source:      %SOURCE%
echo Destination: %DESTINATION%
echo.
echo WARNING: Mirror mode will delete destination files that do not exist in the source.
echo The .git directory will not be synchronized.
echo.

if not exist "%DESTINATION%\NUL" (
    echo ERROR: Destination is not reachable.
    exit /b 1
)

set "CONFIRM="
set /p "CONFIRM=Continue? Type Y to start: "
if /I not "%CONFIRM%"=="Y" (
    echo Synchronization cancelled.
    exit /b 1
)

robocopy "%SOURCE%" "%DESTINATION%" /MIR /XD "%SOURCE%.git"
set "ROBOCOPY_EXIT=%ERRORLEVEL%"

echo.
echo Robocopy exit code: %ROBOCOPY_EXIT%
if %ROBOCOPY_EXIT% GEQ 8 (
    echo ERROR: Synchronization failed.
    exit /b 1
)

echo Synchronization completed successfully.
exit /b 0
