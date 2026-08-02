# D365 Finance Release/Deploy

หลังแก้โปรแกรมและ Commit ทั้ง 3 โปรเจกต์แล้ว เปิด PowerShell ในโฟลเดอร์
`D365_Sharedpoint_csv_import` และรันคำสั่งเดียว:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1
```

เมนูมี 4 รายการ:

1. อัปเดต UAT
2. นำ Release ที่ผ่าน UAT ขึ้น Production
3. ตรวจสอบสถานะและเปรียบเทียบอย่างเดียว
4. ออก

ขั้นตอนปกติคือเลือกข้อ 1, ทดสอบ UAT, แล้วเลือกข้อ 2 ระบบจะสร้าง Release ID,
เปรียบเทียบโค้ด และจัดการไฟล์ประกอบให้อัตโนมัติ

ถ้าพบ Database migration ระบบจะแสดงชื่อฐาน rehearsal และไฟล์ SQL ที่ต้อง Import
ให้ทำตามข้อความบนหน้าจอแล้วกลับมากด Enter ไม่ต้องกรอก path หรือจำนวนแถวเอง

ดูรายละเอียดสำหรับผู้ใช้งานและผู้ดูแลระบบได้ที่
[`docs\uat-production-runbook.md`](docs/uat-production-runbook.md)

## SharePoint queue recovery

สถานะ `RECOVERY_DOWNLOADING` หมายถึงระบบกำลังดาวน์โหลดไฟล์เดิมซ้ำหลังการกู้คืนไฟล์ในเครื่องไม่สำเร็จ
ระบบจะยังไม่นำเข้าไฟล์ใหม่จนกว่ารายการนี้จะสำเร็จหรือเปลี่ยนเป็น `RECOVERY_ERROR`
