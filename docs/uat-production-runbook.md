# คู่มือ UAT และ Production — D365 Finance

## ตั้งค่าครั้งเดียว

ผู้ดูแลระบบต้องเตรียมรายการต่อไปนี้ก่อนใช้งานครั้งแรก:

- UAT อยู่ที่ `C:\xampp\htdocs\uat` และใช้ฐาน `D365_finance`
- Production อยู่ที่ `C:\xampp\htdocs\prod` และใช้ฐาน `D365_finance_prod`
- แต่ละฝั่งมี `D365_Sharedpoint_csv_import`, `D365_file_csv_import` และ `finance_report`
- ตั้งค่า `.env`, บัญชีฐานข้อมูล และ runtime folder แยกกัน ห้ามคัดลอก `.env` ข้ามระบบ
- ตั้งค่า `REHEARSAL_DB_HOST`, `REHEARSAL_DB_USER` และ `REHEARSAL_DB_PASS` ใน Production
  โดยบัญชี rehearsal ให้มีเฉพาะ `SELECT` และ `SHOW VIEW` บนฐาน rehearsal เท่านั้น
- เตรียม Scheduled Task ของ UAT และ Production แยกชื่อและแยก working directory
- สำรองข้อมูลไว้ที่ `C:\xampp\backups\d365` และเก็บ Production checkpoint อย่างน้อย 30 วัน

## ทุกครั้งที่แก้โปรแกรม

สิ่งที่คนทำมีเพียง 4 ขั้นตอน:

1. Commit โค้ดของทั้ง 3 โปรเจกต์ให้เรียบร้อย
2. เปิด `release.ps1` แล้วเลือก `1. อัปเดต UAT`
3. ทดสอบ UAT ให้ครบ
4. เปิด `release.ps1` อีกครั้ง แล้วเลือก `2. นำ Release ที่ผ่าน UAT ขึ้น Production`

คำสั่งเปิดเมนู:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1
```

Release ID จะถูกสร้างอัตโนมัติ เช่น `2026-08-02.1` และเมนู Production จะเลือก Release
ที่ติดตั้งอยู่บน UAT ให้อัตโนมัติ สคริปต์จะถามข้อความยืนยันภาษาไทยตาม Release ที่กำลังทำ
ให้คัดลอกข้อความที่แสดงบนหน้าจอและพิมพ์ให้ตรงทุกตัวอักษร

## เฉพาะเมื่อพบ migration

สคริปต์จะหยุด Production Task, สำรองฐาน, เตรียมไฟล์ที่ปลอดภัยสำหรับ rehearsal
และแสดงข้อความลักษณะนี้:

```text
สิ่งที่คุณต้องทำ
1. เปิด phpMyAdmin และสร้างฐาน: <ชื่อฐานที่สคริปต์แสดง>
2. เลือกฐานนี้และ Import ไฟล์: <ไฟล์ที่สคริปต์แสดง>
3. เมื่อ Import สำเร็จ กลับมาหน้านี้แล้วกด Enter
```

ให้ทำตามนี้เท่านั้น:

1. เปิด phpMyAdmin แล้วกด `New`
2. สร้างฐานด้วยชื่อที่สคริปต์แสดง ห้ามเลือก `D365_finance_prod` หรือ `D365_finance`
3. คลิกฐาน rehearsal ที่เพิ่งสร้าง เลือก `Import`
4. เลือกไฟล์ `.sanitized.sql` ตาม path ที่สคริปต์แสดง แล้วเริ่ม Import
5. เมื่อ phpMyAdmin แจ้งว่าสำเร็จ กลับมาที่ PowerShell และกด Enter

หลังจากนั้นสคริปต์จะตรวจจำนวนข้อมูล, view, สิทธิ์ read-only และการอ้างอิงฐานจริงให้อัตโนมัติ
เมื่อผ่านแล้วจึงถาม `ยืนยันใช้ MIGRATION <release>` ก่อน Apply กับ Production

## เมื่อระบบหยุดเพราะผิดพลาด

- อ่านข้อความ `หยุดที่ขั้นตอน` และรายละเอียดบรรทัดถัดไป
- อย่าเปิด Production Task เองถ้ายังไม่ทราบว่างานหยุดก่อนหรือหลัง Apply migration
- ถ้าผิดตอนสร้างหรือ Import rehearsal ให้แก้สาเหตุ ลบเฉพาะฐาน rehearsal ที่ชื่อสคริปต์แสดง
  แล้วเริ่มเมนู Production ใหม่
- ถ้าผิดหลัง Apply migration ให้หยุดงานและเก็บ snapshot ปัจจุบัน ห้าม Restore checkpoint ทับทันที
  เพราะ Production อาจมีข้อมูลใหม่แล้ว ให้ใช้ forward fix หรือ compensating migration
- เก็บข้อความผิดพลาด, Release ID และเวลาที่เกิดเหตุไว้ให้ผู้ดูแลตรวจสอบ

Production Task จะถูกเปิดกลับเฉพาะเมื่อ Apply, deploy, config check, smoke test และการเปรียบเทียบโค้ด
สำเร็จทั้งหมด หากสคริปต์หยุดก่อนหน้านั้น Task จะยังปิดอยู่เพื่อป้องกันข้อมูลใหม่เข้าระหว่างแก้ไข

## ข้อมูลสำหรับผู้ดูแลระบบ

- Source ของ Git เป็นแหล่งโค้ดหลัก สคริปต์ไม่คัดลอกโค้ดจาก UAT ไป Production
- `.env`, credentials, CSV, logs, archive, temp, lock และ runtime data ไม่ถูก deploy
- Release manifest อยู่ที่ `C:\xampp\backups\d365\releases`
- UAT approval และ hash ใช้ยืนยันว่า Production ได้ Git commit เดียวกับที่ผ่าน UAT
- Production checkpoint manifest ผูกกับ SQL backup และ verification baseline ด้วย SHA-256
- ไฟล์ rehearsal จะเปลี่ยน view เป็น `SQL SECURITY INVOKER` และเปลี่ยน qualified reference
  ให้ชี้ฐาน rehearsal ก่อนอนุญาตให้ Import
- ตัวตรวจ rehearsal ใช้บัญชีแยกที่อ่านอย่างเดียว และสร้าง evidence/receipt แบบเขียนครั้งเดียว
- Migration runner บันทึก project, version, checksum, release, เวลา และผู้ดำเนินการใน `schema_migrations`
- ระบบ Apply ซ้ำอีกหนึ่งรอบเพื่อยืนยัน idempotence; รอบที่สองต้องไม่มี migration ถูก Apply เพิ่ม
- ใช้เมนูข้อ 3 เมื่อต้องการเปรียบเทียบ Source, UAT และ Production โดยไม่เปลี่ยนไฟล์
