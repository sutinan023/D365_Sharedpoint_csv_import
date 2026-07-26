@echo off
cd /d C:\xampp\htdocs\D365_Sharedpoint_csv_import
if not exist logs mkdir logs
C:\xampp\php\php.exe maintenance\cleanup_download.php --run >> logs\download_cleanup.log 2>&1
