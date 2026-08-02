# ดีไซน์เมนูยืนยัน Y/N และ Operational Release

วันที่: 2026-08-02

## เป้าหมาย

ลดการพิมพ์ข้อความยืนยันยาว ๆ ในเมนู `release.ps1` โดยเปลี่ยนคำยืนยันสำหรับผู้ใช้งานเป็น
`Y/N` และเพิ่มเส้นทางที่ปลอดภัยสำหรับ Release ที่มีไฟล์ประเภท Operational แทนการหยุดแบบไม่มีทางไปต่อ

## ขอบเขต

- เปลี่ยนเฉพาะคำถามแบบ Interactive Menu เป็น `Y/N`
- การเรียกแบบ non-interactive ยังคงใช้ approval token เดิม เพื่อรักษาความเข้ากันได้กับ Automation
- เพิ่ม Operational gate ที่แสดงโปรเจกต์และไฟล์ก่อนถามยืนยัน
- Release เดียวกันที่มีทั้ง Operational และ migration ต้องผ่านทั้งสอง gate
- ไม่เปลี่ยนกฎ exclude สำหรับ `.env`, credentials, runtime data, logs หรือ CSV

## รูปแบบคำถาม

ใช้ฟังก์ชันกลางสำหรับถามคำถาม โดยแสดง Environment และ Release ID ทุกครั้ง:

```text
ยืนยันอัปเดต UAT Release 2026-08-02.3 หรือไม่? [Y/N]
ยืนยันว่าทดสอบ UAT Release 2026-08-02.3 ผ่านแล้วหรือไม่? [Y/N]
ยืนยันการเปลี่ยนแปลงระบบ Production Release 2026-08-02.3 หรือไม่? [Y/N]
ยืนยันใช้ Migration กับ Production Release 2026-08-02.3 หรือไม่? [Y/N]
ยืนยันนำ Release 2026-08-02.3 ขึ้น Production หรือไม่? [Y/N]
```

- รับ `Y`, `y`, `N`, `n` หลังตัดช่องว่างหัวท้าย
- คำตอบอื่นต้องถามซ้ำและไม่เปลี่ยนระบบ
- `N` คือการยกเลิกโดยตั้งใจ ไม่ใช่ approval failure

## ลำดับการทำงาน

### อัปเดต UAT

1. สร้าง Release manifest และแสดงผลเปรียบเทียบ
2. ถามยืนยัน UAT แบบ `Y/N`
3. ตอบ `Y` จึงคัดลอกไฟล์; ตอบ `N` ยกเลิกโดยไม่คัดลอก

Manifest ที่สร้างก่อนยกเลิกยังคง immutable และหมายเลขครั้งถัดไปเพิ่มตามปกติ

### นำขึ้น Production

1. ตรวจว่า UAT ทั้งสามโปรเจกต์ใช้ Release และ Git SHA ตาม manifest
2. เปรียบเทียบ Source, UAT และ Production
3. แยกรายการความเสี่ยงเป็น Operational และ migration อย่างอิสระ
4. ถามยืนยันว่าทดสอบ UAT ผ่าน
5. ถ้ามี Operational ให้แสดงเฉพาะ path ที่ตรวจพบ แล้วถาม Operational confirmation
6. ถาม Production confirmation ก่อนเริ่ม checkpoint, หยุด Task, Apply migration หรือคัดลอกไฟล์
7. ถ้ามี migration ให้ทำ checkpoint และ rehearsal; หลังตรวจ rehearsal ผ่านจึงถาม Migration confirmation
8. Apply migration, deploy code, ตรวจ config/smoke/code equality แล้วจึงเปิด Task กลับ

## การยกเลิกและข้อผิดพลาด

- ตอบ `N` ก่อนเริ่ม Production side effect: ยกเลิกทันทีและไม่เปลี่ยน Production
- ตอบ `N` ที่ Migration gate: ยังไม่มี migration ถูก Apply ระบบต้องคืนสถานะ Scheduled Task เดิมแล้วจบ
- ข้อผิดพลาดหลังเริ่ม Apply หรือระหว่าง deploy: คง Task ไว้ในสถานะปิดตาม fail-closed behavior เดิม
- การยกเลิกต้องแสดงข้อความภาษาไทยที่ไม่ทำให้เข้าใจว่าเป็นระบบเสีย

## การตรวจและทดสอบ

- ทดสอบ `Y/y/N/n`, ช่องว่าง และคำตอบไม่ถูกต้องที่ต้องถามซ้ำ
- ทดสอบว่า `N` ก่อน UAT/Production ไม่เรียกคำสั่งเปลี่ยนปลายทาง
- ทดสอบ Operational-only, migration-only และ Operational พร้อม migration
- ทดสอบว่า Operational paths ถูกแสดงครบ แต่ไม่แสดง secret values
- ทดสอบว่า `N` ที่ Migration gate คืน Task เฉพาะรายการที่เดิมเปิดอยู่
- ทดสอบ non-interactive approval token เดิมเพื่อป้องกัน regression
- รัน PowerShell tests ทั้งหมดและ PHP tests ทั้งหมดก่อนส่งมอบ

## สิ่งที่คนทำหลังเปลี่ยน

งานปกติยังคงมี 4 ขั้นตอน: Commit, อัปเดต UAT, ทดสอบ UAT และนำขึ้น Production
เมื่อหน้าจอถาม ให้ตรวจ Environment/Release/รายการไฟล์ แล้วตอบ `Y` หรือ `N` เท่านั้น
