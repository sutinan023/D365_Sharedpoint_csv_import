@echo off
cd /d C:\xampp\htdocs\D365_Sharedpoint_csv_import
if not exist logs mkdir logs
C:\xampp\php\php.exe import\run_pipeline.php >> logs\import.log 2>&1
