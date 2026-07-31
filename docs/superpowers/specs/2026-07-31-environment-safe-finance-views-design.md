# Environment-safe Finance Views Design

## Context

Release `2026-07-31.8` passed UAT, but the Production schema inventory found that
`D365_finance_prod` does not contain `vw_import_report` or
`v_tbpayin_from_payment_outbound`. Finance Report reads
`v_tbpayin_from_payment_outbound` directly. The existing UAT view definition is
bound to `D365_finance`, so copying it verbatim would cross the environment
boundary.

## Decision

Release `2026-07-31.9` will add two forward-only migrations:

1. `004_create_vw_import_report.sql`
2. `005_create_v_tbpayin_from_payment_outbound.sql`

Each migration contains one `CREATE OR REPLACE ALGORITHM=UNDEFINED SQL SECURITY
INVOKER VIEW` statement. All source tables are referenced without a database
qualifier. MySQL therefore binds the view to the database selected by the
migration connection: `D365_finance` in UAT and `D365_finance_prod` in
Production.

The views are split into separate migration files so the migration ledger can
identify and recover a failure at the individual view boundary. Existing views
are replaced intentionally to eliminate schema drift.

## View behavior

`vw_import_report` preserves the current UAT union of payment outbound and
received outbound staging rows. Migration 003 remains responsible for adding
the nullable `stg_received_outbound.effective_date` dependency before this view
is created.

`v_tbpayin_from_payment_outbound` preserves the current Payment Advice grouping,
fee/tax totals, and sent-mail flag behavior. It reads only `payment_outbound`
and `payment_mail_log` in the active database.

`SQL SECURITY INVOKER` avoids a deployment-time dependency on a UAT definer
account. The environment-specific application account must retain `SELECT` on
the underlying tables, which is already part of the application account role.

## Safety and failure handling

- Neither migration contains `D365_finance` or `D365_finance_prod` as a schema
  qualifier.
- No tables, columns, or Production data are deleted or rewritten.
- The existing migration lock, checksum ledger, release ID, and backup/restore
  receipt gates remain mandatory.
- If migration 004 succeeds and 005 fails, 004 remains recorded as applied and
  only 005 requires operator recovery. A failed ledger entry is never retried
  automatically.
- Production migration remains blocked until a fresh backup and restore
  rehearsal are approved for release `2026-07-31.9`.

## Verification

Automated contract tests will fail unless both migration files:

- exist in the expected order;
- use `CREATE OR REPLACE` and `SQL SECURITY INVOKER`;
- avoid environment database names;
- reference the required source tables and expose the expected columns.

UAT verification will then apply the migrations through the real MySQL runner,
confirm both ledger checksums, query both views, rerun schema inventory, rerun
all three project test suites, and repeat the UAT web/config smoke tests.

## Release flow

The immutable `2026-07-31.8` manifest and approval receipt remain audit history.
A new `2026-07-31.9` manifest will reference the new SharePoint importer commit
and the unchanged approved commits for File Importer and Finance Report. After
UAT passes, a new manifest-bound UAT approval receipt is required before
Production CompareOnly or cutover.

## Non-goals

This release does not deploy Production code, create Production credentials,
apply Production migrations, redirect legacy URLs, or enable any Production
scheduled task. Those actions remain behind the explicit cutover approval.
