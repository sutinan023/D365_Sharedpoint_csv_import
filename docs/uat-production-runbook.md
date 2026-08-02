# คู่มือ UAT และ Production — D365 Finance

## เตรียมครั้งเดียว

- แยก UAT (`C:\xampp\htdocs\uat`, ฐาน `D365_finance`) และ Production
  (`C:\xampp\htdocs\prod`, ฐาน `D365_finance_prod`) รวมทั้ง `.env`, บัญชีฐานข้อมูล,
  runtime folder และ Scheduled Task ห้ามคัดลอก `.env` ข้ามระบบ
- ตั้ง `REHEARSAL_DB_HOST`, `REHEARSAL_DB_USER` และ `REHEARSAL_DB_PASS` ใน Production;
  บัญชี rehearsal มีสิทธิ์เฉพาะ `SELECT` และ `SHOW VIEW`
- เก็บ backup/checkpoint ของ Production ที่ `C:\xampp\backups\d365` อย่างน้อย 30 วัน

## ขั้นตอนปกติ

1. Commit โค้ดของ `D365_Sharedpoint_csv_import`, `D365_file_csv_import` และ
   `finance_report` ให้เรียบร้อย
2. รัน `powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1` แล้วเลือก `1`
   เพื่ออัปเดต UAT
3. ทดสอบ UAT ให้ครบ แล้วเปิดเมนูอีกครั้ง เลือก `2` เพื่อ promote Release เดียวกัน

ทุกจุดยืนยัน ให้ตรวจ Environment, Release ID และรายการไฟล์บนหน้าจอ แล้วตอบ `Y` เพื่อ
ดำเนินการต่อ หรือ `N` เพื่อยกเลิก คำตอบที่ไม่ใช่ `Y`/`N` จะถูกถามใหม่ `N` ยกเลิกอย่าง
ปลอดภัย และ Production จะยังไม่เปลี่ยนแปลงจนกว่าคำยืนยันก่อนดำเนินการทุกข้อจะเป็น `Y`

## เมื่อพบ Operational

Operational ไม่ใช่ Database migration: เป็นการเปลี่ยนไฟล์ที่อาจมีผลต่อการตั้งค่าระบบ เช่น
`config/**`, `composer.json`, scheduler หรือ `.htaccess` ตัวช่วยจะแสดงทุก path ที่ได้รับ
ผลกระทบ ให้ตรวจรายการก่อนตอบ `Y` หากตอบ `N` จะหยุดก่อน Migration และก่อนคัดลอกไป
Production

ไฟล์ `.env`, credentials, CSV, logs, archive, temp, lock, runtime data และ `vendor` ยังเป็น
รายการยกเว้นเสมอและไม่ถูก deploy การอัปเดต `APP_RELEASE` จะรักษา UTF-8 BOM เดิมไว้

## เมื่อพบ Migration

Migration คือไฟล์ SQL ใน `database/migrations` และเป็นคนละขั้นกับ Operational ระบบจะหยุด
Production Task, สร้าง checkpoint และแสดงชื่อฐาน rehearsal กับ path ของไฟล์ `.sanitized.sql`

1. เปิด phpMyAdmin สร้างฐานตามชื่อ rehearsal ที่แสดง ห้ามเลือก `D365_finance` หรือ
   `D365_finance_prod`
2. Import ไฟล์ `.sanitized.sql` ตาม path ที่แสดงในฐาน rehearsal นั้น
3. กลับไปที่ตัวช่วย กด Enter หลัง Import สำเร็จ เพื่อให้ตรวจ rehearsal แบบ read-only
   แล้วตรวจผลบนหน้าจอ
4. ตอบ `Y` เฉพาะเมื่อ rehearsal ผ่านและต้องการ Apply migration; ตอบ `N` เพื่อยกเลิก

เมื่อยกเลิก Migration ระบบคืนสถานะเฉพาะ Production Task ที่เปิดใช้งานอยู่ก่อนเริ่มงาน;
Task ที่เดิมปิดอยู่จะไม่ถูกเปิดขึ้น การยกเลิกจะไม่ Apply migration และไม่ deploy Production
ถ้าเกิดข้อผิดพลาดหลัง Apply migration ให้หยุดงาน เก็บ snapshot ปัจจุบัน และใช้ forward fix
หรือ compensating migration — ห้าม Restore checkpoint ทับทันที

Production Task จะถูกเปิดกลับหลัง deploy, config check, smoke test และการเปรียบเทียบโค้ด
ผ่านทั้งหมดเท่านั้น

## ระบบอัตโนมัติ (ไม่ใช่เมนูปกติ)

ผู้ใช้เมนูปกติไม่ต้องพิมพ์ token งาน CI/non-interactive ใช้พารามิเตอร์ token ตาม Release ID:

```text
ApprovalToken:            APPROVE UAT <release-id>
UatAcceptanceToken:       APPROVE UAT RESULT <release-id>
OperationalApprovalToken: APPROVE OPERATIONAL <release-id>  (เมื่อมี Operational)
ProductionApprovalToken:  APPROVE PRODUCTION <release-id>
MigrationApprovalToken:   APPLY MIGRATION <release-id>      (เมื่อมี Migration)
```

Source ของ Git เป็นแหล่งโค้ดหลัก และ manifest/receipt/hash ใช้ยืนยันว่า UAT กับ Production
ตรงกับ Git commit ที่ผ่านการทดสอบ เมนู `3` เปรียบเทียบ Source, UAT และ Production โดยไม่เปลี่ยนไฟล์
