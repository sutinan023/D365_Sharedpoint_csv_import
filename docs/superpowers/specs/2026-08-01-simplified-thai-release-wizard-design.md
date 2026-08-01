# ดีไซน์ Wizard ภาษาไทยสำหรับ Release/Deploy แบบลดงานคน

## เป้าหมาย

ลดขั้นตอนประจำของผู้ใช้งานให้เหลือเฉพาะงานที่ต้องใช้การตัดสินใจของคน โดยยังคง
มาตรการป้องกัน UAT/Production ชี้ข้ามระบบ, Git attestation, backup, restore
rehearsal, migration checksum และการยืนยันก่อนแก้ Production

ผู้ใช้งานทำเองเพียง:

1. แก้โปรแกรมและ commit ทั้งสาม repository
2. ทดสอบผลบน UAT
3. หากมี migration ให้สร้างฐาน rehearsal และ Import ไฟล์ผ่าน phpMyAdmin
4. อ่านผลสรุปและยืนยันก่อน Apply migration/Deploy Production

## เมนูหลัก

เปิดด้วยคำสั่งเดียว:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1
```

เมนูภาษาไทยมีสี่รายการ:

1. อัปเดต UAT
2. นำ Release ที่ผ่าน UAT ขึ้น Production
3. ตรวจสอบสถานะและเปรียบเทียบอย่างเดียว
4. ออก

รายละเอียดเชิงเทคนิคและ parameters ขั้นสูงยังรองรับการเรียกแบบ non-interactive
แต่ไม่แสดงในเส้นทางใช้งานปกติ

## Release ID อัตโนมัติ

เมนูข้อ 1 สร้าง Release ID รูปแบบ `YYYY-MM-DD.N` โดยอ่าน manifest ที่มีอยู่ใน
release artifact root แล้วเลือกเลขลำดับถัดไปของวันนั้น การสร้างต้องเป็น atomic
และห้ามเขียนทับ manifest เดิม ผู้ใช้ไม่ต้องตั้งชื่อ release เอง

## Flow ปกติที่ไม่มี migration

### อัปเดต UAT

Wizard ตรวจว่า repository ทั้งสามสะอาด, สร้าง Release ID/manifest, แสดงสรุป
ไฟล์ code-only ที่จะเปลี่ยน และขอคำยืนยันภาษาไทยหนึ่งครั้ง จากนั้น Deploy UAT
ทั้งสามโปรเจกต์และเขียน release metadata

### นำขึ้น Production

Wizard เลือก Release ล่าสุดที่อยู่บน UAT โดยอัตโนมัติ ตรวจว่า UAT metadata และ
ไฟล์จริงตรง Git ทุกไฟล์ แล้วเปรียบเทียบกับ Production ผู้ใช้ยืนยันว่าได้ทดสอบ
UAT และยืนยัน Production จากหน้าจอเดียวกัน สคริปต์สร้าง UAT receipt, Deploy
Git commit เดิม, ตรวจ config guard, HTTP smoke check และเปรียบเทียบหลัง Deploy

## Flow เมื่อพบ migration

ก่อนแตะ Production Wizard ทำสิ่งต่อไปนี้อัตโนมัติ:

1. แสดง migration ที่ตรวจพบ
2. ปิดเฉพาะ Production Scheduled Tasks และจำสถานะเดิม
3. สร้าง Production checkpoint และ checkpoint manifest
4. สร้างชื่อฐาน rehearsal จาก Release ID
5. สร้างไฟล์ sanitized และ sanitizer audit
6. แสดงกล่องคำแนะนำที่มีเพียงชื่อฐานและ path ไฟล์ที่ต้อง Import

ผู้ใช้เปิด phpMyAdmin, สร้างฐานตามชื่อที่แสดง, เลือกฐานนั้น, Import ไฟล์
`.sanitized.sql` แล้วกลับมากด Enter

Wizard เชื่อมฐาน rehearsal ด้วยบัญชีอ่านอย่างเดียวและทำต่ออัตโนมัติ:

1. ตรวจ row count ของ `import_files`, `payment_outbound`, `payment_mail_log`
   และ `sharepoint_file_queue`
2. ตรวจ `vw_import_report` และ `v_tbpayin_from_payment_outbound` รวมถึง
   `SECURITY_TYPE=INVOKER`
3. ตรวจว่าไม่มี view definition อ้าง `D365_finance_prod`
4. สร้าง restore evidence และ immutable restore receipt
5. ขอคำยืนยัน Apply migration และ Production เป็นภาษาไทย
6. Apply migration รอบแรกและรันซ้ำ รอบที่สองต้องไม่มีรายการถูก Apply เพิ่ม
7. Deploy code, ตรวจ config/HTTP/code และเปิดกลับเฉพาะ Task ที่เคยเปิด

หากขั้นตอนใดล้มเหลวหลังปิด Task จะไม่เปิด Task กลับอัตโนมัติ และจะไม่ข้ามไป
ขั้นต่อไป หน้าจอแสดงขั้นที่หยุด, สาเหตุ และสิ่งที่ผู้ใช้ต้องแก้

## Configuration ครั้งเดียว

Production `.env` เพิ่ม `REHEARSAL_DB_HOST`, `REHEARSAL_DB_USER` และ
`REHEARSAL_DB_PASS` โดยแนะนำชื่อบัญชี `d365_rehearsal_reader`; รหัสผ่านต้อง
สร้างและจัดเก็บตาม ACL ของ `.env` และไม่บันทึกไว้ในเอกสาร

บัญชีนี้ต้องอ่านได้เฉพาะฐานชื่อ `D365_finance_prod_rehearsal_*` และ
`information_schema` ที่จำเป็นสำหรับตรวจ views ห้ามมีสิทธิ์ CREATE, DROP,
ALTER, INSERT, UPDATE, DELETE หรือสิทธิ์บน `D365_finance_prod`

Wizard ไม่บันทึก user/password ลง command line, log, receipt หรือ output

## ภาษาและคำยืนยัน

ข้อความสำหรับผู้ใช้งาน, หัวข้อ, คำแนะนำ และ error ที่เกิดจาก Wizard ใช้ภาษาไทย
ชื่อเทคนิคที่ต้องตรงกับระบบ เช่น UAT, Production, Git, migration, path และ
database name คงรูปเดิมเพื่อป้องกันความคลาดเคลื่อน

คำยืนยัน Production ยังคงผูก Release ID และเปรียบเทียบแบบ case-sensitive
แต่ Wizard แสดงข้อความที่ต้องพิมพ์ให้คัดลอกได้ทันที

## สิ่งที่ไม่ทำ

- ไม่ commit code แทนผู้ใช้
- ไม่คัดลอกไฟล์จาก UAT ไป Production
- ไม่ Restore ฐาน rehearsal อัตโนมัติ
- ไม่ให้สิทธิ์สร้าง/ลบฐานแก่บัญชี verifier
- ไม่เปลี่ยน `.env`, credentials หรือ runtime data ระหว่าง Deploy
- ไม่เปิด Production Tasks เมื่อ migration/deploy/verification ล้มเหลว

## การทดสอบและเกณฑ์รับมอบ

- Release ID รายวันเพิ่มลำดับถูกต้องและสร้างพร้อมกันแล้วไม่ชนกัน
- เมนูปกติไม่ถาม path, manifest hash หรือ Git SHA จากผู้ใช้
- Code-only flow ใช้คำยืนยันเท่าที่จำเป็นและไม่แตะ migration tools
- Migration flow หยุดพร้อมชื่อฐานและ sanitized path ก่อนรอผู้ใช้ Import
- Verifier ปฏิเสธฐานที่ไม่ตรงชื่อ, credentials ข้ามระบบ, view แบบ DEFINER,
  live-schema reference และ row-count query ที่ล้มเหลว
- Evidence/receipt ถูกสร้างจากผล query โดยสคริปต์ ไม่รับตัวเลขที่คนกรอกเอง
- Apply รอบสองต้องว่าง และ Tasks กลับสู่สถานะเดิมหลัง verification ผ่านเท่านั้น
- LocalTestMode จำลองทุก flow โดยไม่เข้าถึง UAT, Production, MySQL หรือ
  Scheduled Tasks จริง
- PowerShell และ PHP regression suites เดิมต้องผ่านทั้งหมด
