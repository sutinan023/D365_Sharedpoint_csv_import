========================================================
D365_Sharedpoint_csv_import
Enterprise CSV Integration Service
========================================================

รายละเอียดระบบ
--------------------------------------------------------
ระบบนี้ใช้สำหรับ Download ไฟล์ CSV จาก SharePoint Online
และ Import ข้อมูลเข้าสู่ MySQL Database อัตโนมัติ

ออกแบบสำหรับ:
- Microsoft Dynamics 365
- Financial Before Post
- Workflow Monitoring
- Executive Reporting
- Audit Trail
- Enterprise Integration

Technology Stack
--------------------------------------------------------
- PHP 8
- MySQL / MariaDB
- SharePoint Online
- Microsoft Graph API
- Composer
- XAMPP
- Windows Task Scheduler

Project Structure
--------------------------------------------------------

D365_Sharedpoint_csv_import/
│
├── config/
│   └── .env
│
├── download/
│   └── latest downloaded csv
│
├── archive/
│   └── imported csv archive
│
├── import/
│   ├── download_csv.php
│   └── run_import.php
│
├── logs/
│
├── monitor/
│   └── index.php
│
├── vendor/
│
└── composer.json

Environment Config (.env)
--------------------------------------------------------

TENANT_ID=
CLIENT_ID=
CLIENT_SECRET=

SHAREPOINT_SITE=
SHAREPOINT_FOLDER=

DB_HOST=localhost
DB_NAME=
DB_USER=root
DB_PASS=

ADMIN_USERNAME=admin
ADMIN_PASSWORD=123456

Main Flow
--------------------------------------------------------

SharePoint CSV
    ↓
download_csv.php
    ↓
download/
    ↓
run_import.php
    ↓
stg_payment_before_post
    ↓
payment_before_post
    ↓
payment_before_post_history
    ↓
D365 Import Monitor

Database Tables
--------------------------------------------------------

1. stg_payment_before_post
--------------------------------------------------------
Temporary staging table

ใช้สำหรับ:
- เก็บข้อมูลจาก CSV ล่าสุด
- ตรวจสอบข้อมูลก่อน process
- debug import

ข้อมูลจะถูกล้างทุกครั้งก่อน import ใหม่

--------------------------------------------------------

2. payment_before_post
--------------------------------------------------------
Current State Table

ใช้สำหรับ:
- เก็บข้อมูลสถานะล่าสุด
- ใช้ทำ Dashboard
- ใช้ทำ Report
- ใช้แสดงข้อมูลปัจจุบัน

Logic สำคัญ:
- Workflow Priority
- Import/Export reference ล่าสุด
- Row Hash Change Detection

Workflow Priority:
Approved   = 3
Submitted  = 2
In review  = 1

หาก Workflow เท่ากัน:
จะเลือก Import/Export reference ล่าสุด

--------------------------------------------------------

3. payment_before_post_history
--------------------------------------------------------
Audit Trail Table

ใช้สำหรับ:
- เก็บประวัติการเปลี่ยนแปลง
- เก็บ old_data
- เก็บ new_data
- ตรวจสอบย้อนหลัง

Action Types:
- INSERT
- UPDATE

--------------------------------------------------------

4. import_files
--------------------------------------------------------
Import Log Table

ใช้สำหรับ:
- เก็บประวัติการ import
- ตรวจสอบ error
- ป้องกัน import ซ้ำ
- monitor service

Fields สำคัญ:
- file_type
- file_hash
- status
- imported_at

file_type example:
- PAYMENT BEFORE POST
- PAYMENT OUTBOUND
- RECEIVED OUTBOUND

CSV Import Logic
--------------------------------------------------------

1. Download latest CSV จาก SharePoint
2. ตรวจ file_hash
3. หากเคย import แล้ว → skip
4. ล้าง staging table
5. import เข้า staging
6. เลือก current row ที่ดีที่สุด
7. compare row_hash
8. insert/update current table
9. insert history
10. archive file
11. write import log

Duplicate Protection
--------------------------------------------------------

ระบบป้องกัน import ซ้ำโดยใช้:

- file_hash
- row_hash
- business key

Business Key:
company
journal_batch
voucher_number
invoice_number

Auto Scheduler
--------------------------------------------------------

แนะนำใช้:
Windows Task Scheduler

ตัวอย่าง:
Run every 5 minutes

Command:
php C:\xampp\htdocs\D365_Sharedpoint_csv_import\import\run_import.php

Recommended Folder Lifecycle
--------------------------------------------------------

download/
- temporary processing only

archive/
- imported history files

logs/
- import log
- error log

Do NOT use download/ as archive storage.

Monitor System
--------------------------------------------------------

D365 Import Monitor

Features:
- Admin Login
- Import Status
- Workflow Summary
- Import History
- Duplicate Monitor
- Changed Records
- Error Monitoring
- Auto Refresh

Monitor URL:
http://localhost/D365_Sharedpoint_csv_import/monitor/

Security
--------------------------------------------------------

- SharePoint Read Only
- Admin Login
- File Hash Validation
- Duplicate Protection
- Transaction Rollback

Recommended Future Improvements
--------------------------------------------------------

- Email Notification
- Teams Notification
- Auto Move SharePoint Files
- Multi Service Import
- Queue Worker
- API Integration
- Real-time Dashboard
- PDF Export
- Excel Export

Important Notes
--------------------------------------------------------

1. payment_before_post
   = current latest state

2. payment_before_post_history
   = audit trail

3. SharePoint
   = source of truth

4. archive/
   = local historical backup

5. import_files
   = import manifest / monitor log

========================================================
END OF DOCUMENT
========================================================