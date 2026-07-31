@echo off
cd /d "%~dp0"
if not exist logs mkdir logs
C:\xampp\php\php.exe import\run_pipeline.php >> logs\import.log 2>&1
