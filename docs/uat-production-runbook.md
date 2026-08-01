# D365 Finance UAT/Production Runbook

## Fixed environment map

| Environment | Root | Database | SharePoint parent |
|---|---|---|---|
| UAT | `C:\xampp\htdocs\uat` | `D365_finance` | `D365export/UAT` |
| Production | `C:\xampp\htdocs\prod` | `D365_finance_prod` | `D365export/Production` |

Each root contains `D365_Sharedpoint_csv_import`, `D365_file_csv_import`, and
`finance_report`. Never share `.env`, runtime folders, log folders, or lock
files between the two roots.

Preview and create the directory/ACL layout with
`tools\prepare_environment.ps1`. Supply the actual Windows identities used by
Apache and Task Scheduler; the script never guesses service accounts.

## เมนูภาษาไทยสำหรับงานประจำ

ผู้พัฒนาเป็นผู้ commit โค้ดเอง จากนั้นเรียกเมนู:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1
```

หรือเรียกแบบไม่เปิดเมนู:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1 -Action DeployUAT -ReleaseId 2026-08-05.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1 -Action Compare -ReleaseId 2026-08-05.1
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1 -Action PromoteProduction -ReleaseId 2026-08-05.1 -PlanOnly
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1 -Action PromoteProduction -ReleaseId 2026-08-05.1
```

ลำดับงานปกติคือ Deploy UAT, ทดสอบ UAT ด้วยผู้ใช้งาน, Compare และ Promote
Git commit เดิมไป Production ห้ามคัดลอกไฟล์จาก UAT ไป Production โดยตรง
release manifest ถูกเก็บนอก Git ที่ `C:\xampp\backups\d365\releases`.

ใช้ `-PlanOnly` ก่อนทุกครั้งที่ต้องการทดลอง หน้านี้ไม่สร้าง manifest, ไม่หยุด
Scheduled Task, ไม่แตะฐานข้อมูล และไม่คัดลอกไฟล์ Production.

## Prepare a release

1. Ensure all three repositories are clean, then create an immutable manifest
   with `tools\new_release_manifest.ps1`.
2. Install dependencies inside each deployment from its committed lock file.
3. Create a local `.env` from `.env.example`. Never copy an `.env` from UAT to
   Production.
4. Run the deployment comparison for each project:

   ```powershell
   powershell -File tools\sync_to_server.ps1 -Environment UAT `
     -ProjectName finance_report -ReleaseId 2026-07-31.1 `
     -SourceRoot C:\xampp\htdocs\finance_report `
     -ManifestPath deployment\releases\2026-07-31.1.json -CompareOnly
   ```

5. Review every `New`, `Modified`, and `Deleted` entry. Runtime and secret
   paths must not appear.
6. Deploy UAT with approval token `APPROVE UAT <release-id>`.
7. Run tests, config checks, one SharePoint sample, one outbound sample, and
   Finance Report read/write smoke tests.
8. Create and ACL-harden `C:\xampp\backups\d365\release-approvals` (or the
   matching approved UNC path), then record UAT approval with
   `tools\approve_uat_release.ps1 -AuditRoot <canonical-root>`. The script uses
   an immutable `CreateNew` filename and binds the approver SID, manifest
   SHA-256, release ID, and all three project Git SHAs.
9. Record the receipt SHA-256 independently. Every Production compare/deploy
   must receive `-UatApprovalPath`, `-ApprovalAuditRoot`, and
   `-ExpectedUatApprovalSha256`; promotion rejects non-canonical paths, loose
   ACLs, duplicate JSON keys, or any hash/SHA mismatch.

## Database safety

- Run `php tools\schema_inventory.php > schema-inventory.json` inside each
  deployed environment and review the UAT/Production diff.
- Take a full `D365_finance_prod` backup and perform a restore rehearsal.
- Create the checkpoint with `tools\database_checkpoint.ps1`. After restoring
  it into an isolated rehearsal database, create a hash-bound receipt with
  `tools\approve_restore_rehearsal.ps1`; never edit the checkpoint manifest.
- Apply only reviewed forward migrations. The migration runner records project,
  version, SHA-256 checksum, release, timestamp, and operator.
- Apply a reviewed migration directory with `php tools\apply_migrations.php
  --apply --project=<project> --directory=<path> --release=<release-id>
  --applied-by=<operator> --backup-manifest=<checkpoint-json>
  --restore-receipt=<restore-approved-json>`.
- Never copy UAT data into Production.
- Before schedulers are enabled, a failure may use the pre-release restore
  checkpoint. After new Production writes exist, stop services and take a new
  snapshot; use a forward fix or compensating migration instead of overwriting
  the database.

### ทำ Restore rehearsal เองเมื่อเมนูพบ migration

1. หยุด Production Scheduled Tasks และสร้าง checkpoint:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\database_checkpoint.ps1 `
     -Environment Production -ReleaseId 2026-08-05.1 `
     -ProjectRoot C:\xampp\htdocs\prod\D365_Sharedpoint_csv_import
   ```

   ยืนยันด้วย `CHECKPOINT PRODUCTION 2026-08-05.1` และเก็บทั้งไฟล์ `.sql`
   กับ `.sql.json` ไว้ด้วยกัน ห้ามแก้ไขไฟล์ทั้งสอง

2. ใช้ `prepare_restore_rehearsal.ps1` สร้างไฟล์ `.sanitized.sql` โดยกรอก
   `ExpectedDefinerCount` และ `ExpectedQualifiedReferenceCount` จาก schema
   inventory ที่ตรวจไว้ ห้ามเดาค่า

3. ใน phpMyAdmin สร้างฐานชื่อใหม่ เช่น
   `D365_finance_prod_rehearsal_20260805_1` แล้ว Import เฉพาะไฟล์
   `.sanitized.sql` ห้ามเลือก `D365_finance_prod` หรือ `D365_finance`

4. ตรวจ row count ของ `import_files`, `payment_outbound`,
   `payment_mail_log`, `sharepoint_file_queue`; ตรวจ row count และ
   `SECURITY_TYPE=INVOKER` ของ `vw_import_report` กับ
   `v_tbpayin_from_payment_outbound`; และตรวจว่าจำนวน view definition ที่
   อ้าง `D365_finance_prod` เท่ากับ `0`

5. ใช้ `tools\new_restore_evidence.ps1` บันทึกค่าที่เห็น โดยต้องยืนยัน
   `CREATE RESTORE EVIDENCE <release-id>` ตัวช่วยนี้สร้าง JSON ให้และไม่ยอม
   รับ security type อื่นหรือ live-schema reference ที่มากกว่า `0`

6. สร้าง receipt ด้วย `tools\approve_restore_rehearsal.ps1` โดยส่ง
   checkpoint manifest, sanitizer audit, restore evidence และยืนยัน
   `RESTORE TEST PASSED <release-id>`

7. เปิดเมนูข้อ 3 อีกครั้ง เมนูจะถาม path ของ `.sql.json` และ
   `restore-approved.json` จากนั้นต้องยืนยันตามลำดับ:

   ```text
   APPLY MIGRATION <release-id>
   APPROVE PRODUCTION <release-id>
   ```

   ระบบจะ Apply migration รอบแรกและรันซ้ำอีกครั้ง รอบที่สองต้องไม่มี migration
   ถูก Apply เพิ่ม หากขั้นตอนไหนล้มเหลว Production tasks จะยังคงปิดอยู่

## Scheduler sequence

1. Install UAT tasks and verify their `PlanOnly` output.
2. Install Production tasks without `-EnableProduction`; they remain disabled.
3. Complete Production smoke tests.
4. Enable tasks in this order: SharePoint importer, File importer, cleanup.
5. Check task exit codes and logs after 15 minutes, 1 hour, and the next
   business day.

## Cutover checkpoint

The following actions require an explicit Production approval immediately
before execution:

- copying files to `\\100.1.1.166\htdocs\prod`;
- applying migrations to `D365_finance_prod`;
- replacing legacy redirect stubs;
- enabling Production scheduled tasks.

Retain the pre-release database and file backups for at least 30 days.
