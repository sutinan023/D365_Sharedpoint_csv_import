# Thai Release Deploy Menu Design

## Objective

Provide one Thai-language PowerShell entry point for a small D365 Finance
application. The operator commits code personally, deploys the committed code
to UAT, tests everything in UAT, compares UAT with Production, and promotes the
same Git commit to Production. The script reduces routine typing without
weakening the existing environment, approval, backup, and migration guards.

## Fixed environment map

| Environment | Project root | Database |
|---|---|---|
| UAT | `C:\xampp\htdocs\uat` | `D365_finance` |
| Production | `C:\xampp\htdocs\prod` | `D365_finance_prod` |

Both roots contain:

- `D365_Sharedpoint_csv_import`
- `D365_file_csv_import`
- `finance_report`

The local Git repositories remain the only deployment source. UAT is the
acceptance environment, but files are never copied directly from UAT to
Production.

## Operator interface

Create `release.ps1` at the repository root with a Thai menu:

1. `สร้าง Release และอัปเดต UAT`
2. `เปรียบเทียบ UAT กับ Production`
3. `นำ UAT ที่ทดสอบผ่านแล้วขึ้น Production`
4. `ออก`

The normal operator supplies only a release ID and explicit confirmation
phrases. An optional non-interactive mode is provided for automated tests and
advanced use, but it uses the same validation paths as the menu.

## Release and UAT flow

The UAT action performs these steps in order:

1. Confirm all three local repositories are Git repositories with no tracked,
   staged, or untracked changes.
2. Create an immutable release manifest containing the release ID, all three
   Git SHAs, and the complete sorted list of committed migration files.
3. Run CompareOnly for all three UAT deployments and display every code file
   that will be added, modified, or deleted.
4. Require `APPROVE UAT <release-id>` before copying files.
5. Deploy all three projects from their attested Git trees with the existing
   runtime and secret exclusions.
6. Run each project's config guard and safe test suite.
7. Record the deployed release metadata in UAT. The user then performs the
   business acceptance test manually.

The script does not commit code, edit `.env`, manufacture credentials, or
copy runtime data.

## Environment comparison

The comparison action checks both provenance and file content:

- UAT release metadata must identify a single release ID and the expected Git
  SHA for every project.
- UAT code must match the committed Git tree after applying the deployment
  exclusion rules.
- Production is compared with the same committed Git tree.
- A Thai report lists `เพิ่ม`, `แก้ไข`, and `ลบ` for each project and finishes
  with either `โค้ดตรงกัน` or `โค้ดยังต่างกัน`.

The comparison always excludes `.env`, credentials, `vendor`, CSV files,
logs, uploads, `import`, `download`, `archive`, `processed`, `error`, `temp`,
lock files, deployment metadata, and deployment backups. An excluded runtime
difference can never be presented as a code difference or copied by the
script.

## Production promotion

The Production action performs these gates before any Production write:

1. Verify all three repositories remain clean and their Git SHAs match the
   UAT release metadata.
2. Verify the actual UAT code matches those Git trees.
3. Display the UAT-to-Production code difference.
4. Require the operator to confirm that UAT business testing passed.
5. Create the canonical immutable UAT approval receipt and independently
   calculate its SHA-256.
6. Detect database migrations and dependency or operational changes.
7. Require `APPROVE PRODUCTION <release-id>` immediately before deployment.
8. Deploy all three projects from the attested Git trees.
9. Run Production config guards and read-only HTTP smoke tests.
10. Compare UAT and Production code again. Success requires zero code
    differences and matching release metadata.

Routine code-only releases do not restart Apache or change Scheduled Tasks.
Changes to `.env`, Composer lock files, scheduler installers, Apache settings,
or deployment/security tooling are classified as operational changes and stop
the simple promotion path with a Thai explanation. Classification uses
`git diff --name-only` between the Git SHA in the currently deployed UAT
metadata and the proposed release SHA; it never relies on file timestamps.

## Database migration flow

A migration is a committed, numbered SQL file in
`database/migrations`. Previously applied migration files are immutable.

When the release contains an unapplied migration, the Production action adds
these guarded steps:

1. Confirm the migration is already `APPLIED` in UAT with the committed
   checksum and that the UAT application tests passed.
2. Disable the Production importer tasks and record their prior states.
3. Create a full `D365_finance_prod` checkpoint with routines, triggers, and
   events; record its SHA-256 and critical table counts.
4. Restore the checkpoint to an isolated rehearsal database and verify the
   restored counts. After the evidence passes, require the existing exact
   approval phrase `RESTORE TEST PASSED <release-id>` to create the immutable
   restore-approval receipt.
5. Apply the committed migration set to rehearsal and require all ledger rows
   to be `APPLIED` with matching checksums.
6. Display the migration filenames, target database, checkpoint path, and
   rehearsal result.
7. Require the exact phrase `APPLY MIGRATION <release-id>`.
8. Apply migrations to `D365_finance_prod` with the configured migration
   account, never the application account.
9. Run the migration command a second time. It must report zero newly applied
   migrations.
10. Verify the Production ledger, checksums, schema guard, and critical table
    counts before deploying application code.
11. Restore the importer task states only after Production config and smoke
    checks pass.

The script never asks for or prints a database password. It reads protected
environment configuration and masks secrets in captured output.

If rehearsal fails, a checksum differs, a migration contains a destructive
operation requiring separate approval, or any Production verification fails,
the script stops with Production tasks disabled. It does not automatically
overwrite Production with a restore after new Production writes exist.

## Failure and recovery behavior

- Validation and comparison failures make no Production change.
- A deployment failure uses the existing per-file deployment backup to restore
  code changed in that attempt.
- A migration failure before importers reopen leaves importers disabled and
  reports the checkpoint and failing migration.
- After importers reopen, the script never automatically restores an old
  database backup. The operator must stop processing, take a new snapshot, and
  use a forward fix or compensating migration.
- Every stopped run prints the failed stage, the unchanged or changed systems,
  and the safe next action in Thai.

## Reused components

The menu orchestrates rather than replaces these reviewed tools:

- `tools/new_release_manifest.ps1`
- `tools/sync_to_server.ps1`
- `tools/approve_uat_release.ps1`
- `tools/database_checkpoint.ps1`
- `tools/prepare_restore_rehearsal.ps1`
- `tools/approve_restore_rehearsal.ps1`
- `tools/apply_migrations.php`
- each project's `tools/check_config.php` and safe tests

New code is limited to the menu/orchestrator, environment-code comparison,
small shared output helpers, and their tests.

## Acceptance criteria

- A code-only release can be promoted using the three Thai menu actions.
- The script refuses dirty repositories or a UAT/Git SHA mismatch.
- Compare mode changes no files and reports code-only differences for all
  three projects.
- Production deployment uses the same Git commit that passed UAT.
- UAT and Production `.env` and runtime files remain unchanged.
- Production requires both the UAT acceptance confirmation and the final
  Production approval phrase.
- Unapplied migrations cannot reach Production without checkpoint, restore
  rehearsal, exact migration approval, checksum validation, and idempotence
  verification.
- A successful promotion ends with zero UAT/Production code differences,
  passing config guards, passing smoke tests, and a Thai summary.
- Tests cover menu routing, exclusions, dirty Git refusal, SHA mismatch,
  code-only promotion, migration gating, approval phrases, and failure paths
  without accessing the real UAT or Production environments.
