# Design: ขยาย `invoice_number` ใน Payment Before Post staging

## ปัญหาและหลักฐาน

- Production queue ID `44`, ไฟล์ `GLB_20260803101939_before_post.csv`, SHA-256 `3605a718e95097fe1c90e3d7892a20d23f5b7b3d8c48050e92be7ff146039cd8` อยู่สถานะ `IMPORT_ERROR`
- CSV มี 1,074 แถว; `Invoice number` เป็นข้อความรายการเลขที่คั่นด้วย comma
- มี 2 แถวที่ยาว 129 ตัวอักษร ขณะที่ `stg_payment_before_post.invoice_number` เป็น `VARCHAR(100)`
- ตารางหลัก `payment_before_post.invoice_number` เป็น `VARCHAR(255)` อยู่แล้ว
- Import transaction rollback สมบูรณ์: ไม่มีข้อมูลจาก hash นี้ใน staging, ตารางหลัก หรือ history; มีเพียง `import_files` สถานะ `ERROR`

## แนวทางที่เลือก

เพิ่ม migration แบบ forward-only และ non-destructive เพื่อเปลี่ยน:

```sql
ALTER TABLE stg_payment_before_post
    MODIFY COLUMN invoice_number VARCHAR(255) NULL;
```

ไม่เปลี่ยนชนิดข้อมูลเป็นตัวเลข, ไม่ตัดข้อความ, ไม่แก้ตารางหลัก และไม่ลบ business data

## ลำดับดำเนินงาน

1. เพิ่ม migration ลำดับถัดไปและ contract test ที่ยืนยันว่าแก้เฉพาะ staging เป็น `VARCHAR(255)`
2. รัน test suite ทั้งหมดใน worktree แยก
3. Deploy release เดียวกันไป UAT และ apply migration ผ่าน migration runner เพื่อบันทึก checksum/release ID
4. ทดสอบไฟล์จริงใน UAT และยืนยันว่าค่า 129 ตัวอักษรผ่านโดยไม่ truncate
5. ก่อน Production ให้ตรวจว่า queue ID `44` ยังเป็น `IMPORT_ERROR` และไม่มี business rows จาก hash นี้
6. สำรอง schema/metadata ที่เกี่ยวข้อง แล้ว apply migration เดียวกันใน Production ผ่าน migration runner
7. เปลี่ยนเฉพาะ queue ID `44` กลับเป็น `MOVED` ด้วยเงื่อนไข filename, hash และสถานะเดิมต้องตรงทั้งหมด
8. เปิด `D365 SharePoint CSV Import [PROD]` คืน และติดตามจน ID `44` เป็น `IMPORTED`; จากนั้นตรวจว่า backlog เดินต่อ

## Failure handling

- หาก UAT ไม่ผ่าน ห้าม apply Production
- หาก schema หรือ queue precondition ไม่ตรง ให้หยุดโดยไม่แก้ข้อมูล
- การขยาย `VARCHAR` ไม่ต้อง rollback ข้อมูล; หาก migration ล้มเหลวให้ task คง Disabled และใช้ forward fix
- ห้าม reset queue ก่อน Production schema เป็น `VARCHAR(255)`
- ห้ามลบ `import_files`/queue history; ให้การ retry อัปเดตสถานะตาม flow ปกติ

## เกณฑ์รับมอบ

- UAT และ Production staging เป็น `VARCHAR(255)` และ main table ยังคง `VARCHAR(255)`
- Migration ถูกบันทึกใน `schema_migrations` ด้วย checksum และ release ID
- ไฟล์จริงนำเข้า UAT ได้ครบโดยไม่มี truncation
- Production queue ID `44` สำเร็จโดยใช้ SHA-256 เดิม
- ไม่มีการลบหรือ truncate invoice number
- Production task ถูกเปิดคืน และ queue ที่รออยู่ทำงานต่อได้
