@echo off
cd /d "%~dp0"
if not exist logs mkdir logs
C:\xampp\php\php.exe maintenance\cleanup_download.php --run >> logs\download_cleanup.log 2>&1
