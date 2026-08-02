# D365 Finance Release/Deploy

หลัง Commit โค้ดของทั้ง 3 โครงการแล้ว ให้เปิด PowerShell ในโฟลเดอร์
`D365_Sharedpoint_csv_import` และรัน:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1
```

เลือก `1` เพื่ออัปเดต UAT, ทดสอบ UAT ให้ครบ แล้วเลือก `2` เพื่อนำ Release เดิมขึ้น
Production; เมนู `3` ใช้ตรวจสอบและเปรียบเทียบโดยไม่เปลี่ยนไฟล์

## การยืนยันในเมนู

ก่อนตอบทุกครั้ง ให้ตรวจสอบ Environment, Release ID และรายการไฟล์บนหน้าจอ

ตอบ `Y` เพื่อดำเนินการต่อ หรือ `N` เพื่อยกเลิก ทุกคำถามยืนยันรับเฉพาะ `Y`/`N`;
คำตอบอื่นจะถามใหม่ และ `N` ยกเลิกอย่างปลอดภัยโดยไม่ไปยังขั้นถัดไป
Production จะไม่เปลี่ยนแปลงจนกว่าคำยืนยันก่อนดำเนินการทุกข้อจะเป็น `Y`

## Operational และ Migration

**Operational** คือ Release ที่มีไฟล์การตั้งค่าระบบ เช่น `config/**`,
`composer.json`, scheduler หรือ `.htaccess` ตัวช่วยจะแสดงทุก `project/path` ที่ได้รับผลกระทบ
ให้ตรวจรายการนั้นก่อนตอบ `Y` การยกเลิกที่จุดนี้จะไม่เริ่ม Migration หรือคัดลอกไฟล์ไป
Production

**Migration** คือ Release ที่มีไฟล์ SQL ใน `database/migrations` ซึ่งต้อง checkpoint,
สร้างและ Import ฐาน rehearsal ตามชื่อฐานและ path ที่ตัวช่วยแสดง แล้วจึงตอบ `Y` เมื่อ
ตรวจ rehearsal ผ่าน หากตอบ `N` ที่ Migration ระบบจะคืนสถานะเฉพาะ Production Task ที่
ก่อนหน้านี้เปิดใช้งานอยู่; Task ที่เดิมปิดอยู่จะยังปิดอยู่ และจะไม่มีการ Apply migration
หรือ deploy Production

`.env`, credentials, CSV, logs, archive, temp, lock, runtime data และ `vendor` เป็น
รายการยกเว้นที่ไม่ถูก deploy การอัปเดต `APP_RELEASE` รักษา UTF-8 BOM เดิมของไฟล์ไว้

## สำหรับระบบอัตโนมัติเท่านั้น

ผู้ใช้เมนูปกติไม่ต้องพิมพ์ approval token ระบบ CI/งาน non-interactive ต้องส่ง token
ตาม Release ID ผ่านพารามิเตอร์ต่อไปนี้ (ไม่ใช่ขั้นตอนในเมนู):

```text
ApprovalToken:            APPROVE UAT <release-id>
UatAcceptanceToken:       APPROVE UAT RESULT <release-id>
OperationalApprovalToken: APPROVE OPERATIONAL <release-id>  (เมื่อมี Operational)
ProductionApprovalToken:  APPROVE PRODUCTION <release-id>
MigrationApprovalToken:   APPLY MIGRATION <release-id>      (เมื่อมี Migration)
```

ดูขั้นตอน rehearsal และการรับมือเมื่อเกิดข้อผิดพลาดได้ที่
[`docs/uat-production-runbook.md`](docs/uat-production-runbook.md)

## SharePoint queue recovery

สถานะ `RECOVERY_DOWNLOADING` หมายถึงระบบกำลังดาวน์โหลดไฟล์เดิมซ้ำหลังการกู้คืนไฟล์ในเครื่องไม่สำเร็จ
ระบบจะยังไม่นำเข้าไฟล์ใหม่จนกว่ารายการนี้จะสำเร็จหรือเปลี่ยนเป็น `RECOVERY_ERROR`
