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
8. Record UAT approval with `tools\approve_uat_release.ps1`. Production must
   receive this receipt with `-UatApprovalPath`; the receipt is bound to the
   manifest SHA-256 and release ID.

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
