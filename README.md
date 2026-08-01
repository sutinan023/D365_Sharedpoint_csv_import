# D365_Sharedpoint_csv_import

## เมนู Release/Deploy

Commit โค้ดของทั้งสามโปรเจกต์ให้เรียบร้อยก่อน แล้วเปิดเมนูจากโปรเจกต์นี้:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\release.ps1
```

เมนูใช้ Git commit เป็นแหล่งโค้ด ไม่คัดลอกไฟล์จาก UAT ไป Production และไม่
deploy `.env`, CSV, log, `vendor` หรือ runtime data ดูขั้นตอนเต็มได้ที่
`docs\uat-production-runbook.md`.

## SharePoint queue recovery

`RECOVERY_DOWNLOADING` means an older queue row is being redownloaded after
local recovery failed. The state is durable so a process restart cannot lose
its recovery origin; it blocks newer imports until the redownload succeeds or
returns to `RECOVERY_ERROR`.
