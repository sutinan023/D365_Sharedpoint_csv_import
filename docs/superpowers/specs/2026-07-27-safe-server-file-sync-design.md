# Safe Server File Sync Design

## Goal

Replace the destructive mirror synchronization with a safe, reviewable copy
operation to `\\100.1.1.166\htdocs\D365_Sharedpoint_csv_import`.

## Structure

- `sync_to_server.bat` is a small launcher that resolves its own directory,
  runs `tools\sync_to_server.ps1`, and pauses so an interactive user can read
  the result.
- `tools\sync_to_server.ps1` contains the synchronization logic.

## Behavior

- Compare source files with destination files by SHA-256.
- List files that are new or modified before any copy happens.
- Require the exact approval text `APPROVE` before copying.
- Copy only listed files, creating destination directories as needed.
- Never delete files or directories from the destination.
- Exclude `.git`, `.agents`, `*.log`, `*.tmp`, `download`, `archive`, `error`,
  `temp`, `logs`, `vendor`, `.env`, and `config\.env`.
- Fail clearly when the source or destination is not accessible.

## Verification

- Automated tests cover exclusion matching and change detection with local
  temporary source/destination directories.
- Verification does not connect to or write to the UNC destination.
