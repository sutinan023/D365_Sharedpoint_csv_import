# SharePoint CSV Queue Design

Date: 2026-07-24
Project: D365_Sharedpoint_csv_import

## Goal

Improve the current SharePoint CSV import process so it can:

- Sweep every `.csv` file from SharePoint folder `PaymentBeforePost`.
- Download each CSV to the server.
- Move the SharePoint source file immediately after the local download is verified.
- Import all local downloaded files in deterministic order.
- Keep enough state to recover safely after network errors, database errors, duplicate files, or a crash.

The SharePoint processed folder is `PaymentBeforePost_Downloaded`.

## Current Behavior

Current files inspected:

- `import/download_csv.php`
- `import/run_import.php`
- `monitor/index.php`
- `Readme.txt`

The current import flow downloads only the latest CSV from SharePoint, then `run_import.php` imports only the newest local CSV from `download/`. It copies imported files to `archive/`, but the downloaded file remains in `download/`. This can cause repeated attempts against the same newest file and does not support sweeping all CSVs from SharePoint.

## Selected Approach

Use a two-stage queue:

1. Download Queue
2. Import Queue

This keeps SharePoint file movement independent from database import. Once a file is safely downloaded and verified on the server, it can be moved in SharePoint without waiting for the import transaction to finish.

## End-to-End Flow

1. Scheduler starts one pipeline run.
2. Pipeline obtains a lock so overlapping runs do not process the same file.
3. Download Queue lists all children in SharePoint folder `PaymentBeforePost`.
4. Queue filters only `.csv` files, case-insensitive.
5. Queue handles Microsoft Graph pagination until no `@odata.nextLink` remains.
6. Queue records each CSV in `sharepoint_file_queue`.
7. Each CSV is downloaded to `download/<filename>.part`.
8. After download finishes, the system validates local file existence and expected size when SharePoint size is available.
9. The `.part` file is renamed to the final local filename.
10. Queue marks the file as `DOWNLOADED`.
11. Queue moves the SharePoint item to `PaymentBeforePost_Downloaded`.
12. Queue marks the file as `MOVED`.
13. Import Queue selects local files with status `MOVED`, ordered oldest to newest.
14. Each file is imported in its own database transaction.
15. On import success, local file is moved to `archive/` and queue status becomes `IMPORTED`.
16. On import failure, local file stays in `download/`, status becomes `IMPORT_ERROR`, and Import Queue stops for that run so newer files do not overtake the failed older file.

## Status Model

Use these statuses:

- `DISCOVERED`: CSV exists in SharePoint and has been recorded.
- `DOWNLOADING`: local `.part` download is in progress.
- `DOWNLOADED`: local file is complete and verified.
- `MOVING`: SharePoint move is in progress.
- `MOVED`: SharePoint item has been moved to `PaymentBeforePost_Downloaded`; local file is ready for import.
- `IMPORTING`: database import is in progress.
- `IMPORTED`: import succeeded and local file was archived.
- `IMPORT_ERROR`: import failed; file remains local for investigation/retry.
- `SKIPPED_DUPLICATE`: file hash already exists in successful import history.
- `ERROR`: non-import failure that requires retry or operator review.

## Queue Table

Add table `sharepoint_file_queue`.

Suggested fields:

- `id`
- `drive_id`
- `item_id`
- `source_folder`
- `processed_folder`
- `file_name`
- `sharepoint_size`
- `sharepoint_etag`
- `sharepoint_last_modified_at`
- `local_path`
- `local_sha256`
- `status`
- `attempt_count`
- `last_error`
- `next_retry_at`
- `downloaded_at`
- `moved_at`
- `import_started_at`
- `imported_at`
- `created_at`
- `updated_at`

Recommended unique keys:

- `item_id`
- `local_sha256` combined with successful imported state, or reuse existing `import_files` hash logic for final duplicate protection.

Filename alone must not be used as the identity because SharePoint files can be renamed or re-uploaded.

## Components

### SharePointClient

Responsibilities:

- Authenticate with Microsoft Graph.
- Resolve site and drive.
- Resolve source and processed folders.
- List all folder children, including pagination.
- Download item content.
- Move a drive item to the processed folder.

Microsoft Graph notes:

- Listing drive children can return `@odata.nextLink`, so pagination is required.
- Downloading drive item content uses `/content` and may redirect to a preauthenticated download URL.
- Moving a drive item is done by updating its `parentReference`; moving between different drives is not supported by the move API.

### DownloadQueue

Responsibilities:

- Sweep all `.csv` files from `PaymentBeforePost`.
- Insert or update queue rows.
- Download using `.part` files.
- Verify completion before renaming.
- Move SharePoint item immediately after verified local download.
- Retry safe network and Graph failures.

### ImportQueue

Responsibilities:

- Select queue rows with status `MOVED`.
- Import oldest to newest.
- Use one database transaction per file.
- Stop at the first import failure.
- Archive local file only after successful import.
- Preserve existing staging/current/history import behavior as much as possible.

### Pipeline Entrypoint

Create one scheduler target, for example `import/run_pipeline.php`.

Pipeline order:

1. Acquire lock.
2. Run Download Queue.
3. Run Import Queue.
4. Release lock.

The existing scheduler should call the pipeline entrypoint instead of directly calling the current import script.

## Configuration

Add or standardize these `.env` keys:

```env
CSV_FOLDER=PaymentBeforePost
CSV_DOWNLOADED_FOLDER=PaymentBeforePost_Downloaded
CSV_LOCAL_DOWNLOAD_DIR=download
CSV_LOCAL_ARCHIVE_DIR=archive
CSV_LOCAL_ERROR_DIR=error
GRAPH_RETRY_ATTEMPTS=3
```

Do not log `CLIENT_SECRET`, database passwords, tokens, or preauthenticated download URLs.

## Failure Handling

Download failure:

- Delete incomplete `.part` file.
- Leave source file in `PaymentBeforePost`.
- Mark queue row `ERROR` or keep retry metadata.

Downloaded but SharePoint move fails:

- Keep local file.
- Keep status `DOWNLOADED`.
- Retry move next run without downloading again.

Move succeeds but response is lost:

- Before retrying move, check whether the item is already in `PaymentBeforePost_Downloaded`.
- If already moved, mark `MOVED`.

Import failure:

- Roll back database transaction for that file.
- Keep local file in `download/`.
- Mark `IMPORT_ERROR`.
- Stop importing newer files for that run.

Duplicate hash:

- If the same file hash has already been successfully imported, do not import again.
- Mark `SKIPPED_DUPLICATE` and keep an audit trail.

Crash recovery:

- `DOWNLOADING`: remove stale `.part` and retry.
- `DOWNLOADED`: retry SharePoint move.
- `MOVING`: verify current SharePoint location, then continue.
- `IMPORTING`: if process is no longer active, reset to `MOVED` or `IMPORT_ERROR` based on local checks and database import record.

## Safety Rules

- Never move the SharePoint file until local download validation passes.
- Never delete a local downloaded CSV before successful import and archive.
- Never import newer files after an older file failed in the same sequence.
- Never rely on filename alone for idempotency.
- Never expose secrets or Microsoft Graph download URLs in logs.
- Use a lock to prevent overlapping scheduled runs.
- Use pagination when listing SharePoint folder files.
- Filter only `.csv`; ignore folders and other extensions.

## Monitor Updates

Extend `monitor/index.php` to show:

- Queue status counts.
- Latest files by status.
- Last error per file.
- Attempt count.
- Downloaded/moved/imported timestamps.
- A clear warning when the oldest pending file is in `IMPORT_ERROR`.

This should make operations visible without opening log files.

## Testing Plan

Unit or script-level tests:

- CSV extension filter is case-insensitive.
- Non-CSV files and folders are ignored.
- Pagination follows all pages.
- Files are sorted oldest to newest for import.
- `.part` files are not treated as ready.
- Download validates file size when available.
- SharePoint move is not called when download validation fails.
- Import Queue stops after first `IMPORT_ERROR`.
- Duplicate hash is skipped and recorded.
- Retry metadata updates `attempt_count`, `last_error`, and `next_retry_at`.

Integration tests with fake Graph responses:

- Multiple CSV files are discovered, downloaded, moved, and imported in order.
- Download succeeds but move fails, then next run resumes at move.
- Move succeeds but response is lost, then next run detects processed folder state.
- Import fails on older file, newer file remains unimported.

Manual staging acceptance:

- Put 3 CSV files and 1 non-CSV file into `PaymentBeforePost`.
- Run pipeline once.
- Confirm 3 CSV files are downloaded locally.
- Confirm 3 CSV files are moved to `PaymentBeforePost_Downloaded`.
- Confirm non-CSV stays ignored.
- Confirm imports run oldest to newest.
- Confirm successful local files end in `archive/`.
- Force one bad CSV and confirm newer CSVs do not import until the bad file is handled.

## Permissions

The current system was effectively read-only against SharePoint. This feature requires write/move permission for the target SharePoint drive or site.

Use the least permission that works for the tenant policy. Microsoft Graph drive item move documentation lists `Files.ReadWrite.All` as the least application permission for move operations. If the tenant uses a stricter site-scoped model, validate the exact permission in staging before production.

## Rollout Plan

1. Add queue table migration.
2. Add SharePoint client methods for paginated list, download, and move.
3. Add Download Queue.
4. Refactor import logic so it can import one specified local CSV.
5. Add Import Queue.
6. Add pipeline lock and scheduler entrypoint.
7. Update monitor page.
8. Run dry-run or staging test.
9. Enable production scheduler after confirming permissions and folder names.

## Open Decisions

- Whether duplicate imported files should be archived locally or moved to `error/duplicates/`.
- Whether `IMPORT_ERROR` should require manual reset or automatically retry on the next schedule.
- Whether the monitor should include a manual retry button. For first implementation, status visibility is safer than adding manual actions.

## References

- Microsoft Graph list children: https://learn.microsoft.com/en-us/graph/api/driveitem-list-children?view=graph-rest-1.0
- Microsoft Graph download content: https://learn.microsoft.com/en-us/graph/api/driveitem-get-content?view=graph-rest-1.0
- Microsoft Graph move driveItem: https://learn.microsoft.com/en-us/graph/api/driveitem-move?view=graph-rest-1.0
