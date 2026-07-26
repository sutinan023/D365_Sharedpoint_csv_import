# D365_Sharedpoint_csv_import

## SharePoint queue recovery

`RECOVERY_DOWNLOADING` means an older queue row is being redownloaded after
local recovery failed. The state is durable so a process restart cannot lose
its recovery origin; it blocks newer imports until the redownload succeeds or
returns to `RECOVERY_ERROR`.
