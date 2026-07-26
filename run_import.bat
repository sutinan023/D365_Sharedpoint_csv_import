@echo off
cd /d C:\xampp\htdocs\D365_Sharedpoint_csv_import
php import\run_pipeline.php >> logs\import.log 2>&1
